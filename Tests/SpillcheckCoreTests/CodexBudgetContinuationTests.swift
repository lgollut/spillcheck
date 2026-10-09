import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor CodexBudgetHistory: CodexHistoryReading {
    struct Call: Sendable { let method: String; let maximumBytes: Int; let timeout: TimeInterval }
    enum Mode: Sendable, Equatable { case timestampFallback, metadataExhaustion }
    private let mode: Mode
    private let thread: CodexJSON
    private let item: CodexJSON
    private let turn: CodexJSON
    private var calls: [Call] = []

    init(_ mode: Mode, date: Date) throws {
        self.mode = mode
        thread = try codexThread("selected", producer: "0.161.0")
        item = try codexItem("dated-by-turn", timestamp: nil)
        turn = try codexJSON(["id": "turn", "startedAt": date.addingTimeInterval(-2).timeIntervalSince1970,
            "completedAt": date.addingTimeInterval(-1).timeIntervalSince1970])
    }
    func recordedCalls() -> [Call] { calls }
    private func record(_ method: String, _ budget: CodexRPCBudget) {
        calls.append(.init(method: method, maximumBytes: budget.maximumBytes, timeout: budget.timeout))
    }
    func readThread(_ id: String, budget: CodexRPCBudget) async throws -> CodexThreadRead {
        record("thread", budget)
        return .init(thread: thread, bytesRead: mode == .metadataExhaustion ? 64 : 40)
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int,
                   direction: CodexHistoryDirection, budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        record("items", budget)
        return .init(data: [item], bytesRead: 50)
    }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection,
                   budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        record("turns", budget)
        return .init(data: [turn], bytesRead: 30)
    }
    func listThreads(cursor: String?, limit: Int, archived: Bool, budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        throw CodexHistoryError.unsafeMethod
    }
    // A production normalizer must use the budgeted protocol, rather than checking totals
    // after an unbounded implementation has already read the response.
    func readThread(_ id: String) async throws -> CodexThreadRead { throw CodexHistoryError.unsafeMethod }
    func listThreads(cursor: String?, limit: Int, archived: Bool) async throws -> CodexHistoryPage {
        throw CodexHistoryError.unsafeMethod
    }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection) async throws -> CodexHistoryPage {
        throw CodexHistoryError.unsafeMethod
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int,
                   direction: CodexHistoryDirection) async throws -> CodexHistoryPage { throw CodexHistoryError.unsafeMethod }
}

private func budgetAdapter(_ history: CodexBudgetHistory, maximumBytes: Int) throws -> CodexAdapter {
    let authority = CodexTestAuthority()
    return try CodexAdapter(profileID: "budget-test", agentVersion: "0.161.0", interface: .standaloneCLI,
        history: history, historyBudget: .init(maximumBytes: maximumBytes, maximumDuration: 1, maximumSources: 1),
        authorityLookup: { await authority.lookup($0) }, authorityRecorder: { try await authority.record($0) })
}

private actor CodexBudgetCheckpoints {
    private var values: [UUID: SourceCheckpoint] = [:]
    func save(_ checkpoints: [SourceCheckpoint]) {
        for checkpoint in checkpoints { values[checkpoint.sourceDocumentID] = checkpoint }
    }
    func get(_ id: UUID) -> SourceCheckpoint? { values[id] }
}

@Suite("Codex remaining budget and bounded stalled continuations")
struct CodexBudgetContinuationTests {
    @Test func metadataItemsAndTimestampFallbackShareOneShrinkingBudget() async throws {
        let now = Date(timeIntervalSince1970: 1_791_434_400)
        let history = try CodexBudgetHistory(.timestampFallback, date: now)
        let adapter = try budgetAdapter(history, maximumBytes: 120)
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let request = CodexHistoryRequest(audit: audit, threads: ["selected"])
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let batch = try await adapter.normalize(adapter.packet(request), capturedAt: now, cryptography: crypto)
        let calls = await history.recordedCalls()
        #expect(calls.map(\.method) == ["thread", "items", "turns"])
        #expect(calls.map(\.maximumBytes) == [120, 80, 30])
        #expect(calls.allSatisfy { $0.timeout > 0 && $0.timeout <= 1 })
        #expect(zip(calls, calls.dropFirst()).allSatisfy { pair in pair.1.timeout <= pair.0.timeout })
        #expect(batch.sources.count == 1)
        #expect(batch.sources.first?.record.metadata.contentTime == now.addingTimeInterval(-1))
        #expect(batch.historicalProgress?.bytesRead == 120)
        #expect(batch.historicalProgress?.hasUnreadContent == false)
        #expect(batch.continuation == nil && batch.coverageGaps.isEmpty)
    }

    @Test func repeatedMetadataOnlyPassesStopWithoutScanningOrDeclaringUnreadContentCovered() async throws {
        let now = Date(timeIntervalSince1970: 1_791_434_400)
        let history = try CodexBudgetHistory(.metadataExhaustion, date: now)
        let adapter = try budgetAdapter(history, maximumBytes: 64)
        let audit = try HistoricalAuditContext(reason: .resume, endingAt: now)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        var packet: CapturePacket? = try adapter.packet(CodexHistoryRequest(audit: audit, threads: ["selected"]))
        var terminal: CollectionBatch?
        for _ in 0..<3 {
            guard let current = packet else { break }
            let batch = try await adapter.normalize(current, capturedAt: now, cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.checkpoints.isEmpty)
            #expect(batch.historicalProgress?.audit == audit)
            #expect(batch.historicalProgress?.bytesRead == 64)
            #expect(batch.historicalProgress?.hasUnreadContent == true)
            if let continuation = batch.continuation {
                let saved = try JSONDecoder().decode(CodexHistoryRequest.self, from: continuation.eventJSON)
                #expect(saved.consecutiveBudgetFailures > 0 && saved.consecutiveBudgetFailures < 3)
                #expect(saved.pageLimit == nil) // No item RPC was attempted; shrinking it cannot help.
            }
            packet = batch.continuation
            terminal = batch
        }
        #expect(packet == nil)
        #expect(terminal?.coverageGaps.contains { $0.reason == .budgetExhausted } == true)
        let calls = await history.recordedCalls()
        #expect(calls.count <= 3)
        #expect(calls.allSatisfy { $0.method == "thread" && $0.maximumBytes == 64 })
    }

    @Test func unsupportedThreadClearsPriorReplayStateAndPromotesItsSelectedChild() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        await history.configure("changed", thread: try codexThread("changed", producer: "unsupported"), pages: [])
        await history.configure("child", thread: try codexThread("child"), pages: [])
        await history.configureDescending("child", page: .init(data: [try codexItem("own-final")]))
        let adapter = try codexTestAdapter(history: history)
        var request = CodexHistoryRequest(audit: nil, threads: ["changed"])
        request.children = ["child"]
        request.itemCursor = "prior-boundary"
        request.liveBootstrapped = true
        request.hasReplayCursor = true
        request.replayCursor = "prior-unfinished-boundary"
        request.consecutiveBudgetFailures = 2
        request.pageLimit = 1
        let rejected = try await adapter.normalize(adapter.packet(request), capturedAt: Date(), cryptography: crypto)
        #expect(rejected.sources.isEmpty && rejected.checkpoints.isEmpty)
        #expect(rejected.coverageGaps.contains { $0.reason == .unsupportedVersion })
        let continuation = try #require(rejected.continuation)
        let next = try JSONDecoder().decode(CodexHistoryRequest.self, from: continuation.eventJSON)
        #expect(next.threads == ["child"] && next.children.isEmpty)
        #expect(next.itemCursor == nil && !next.liveBootstrapped)
        #expect(!next.hasReplayCursor && next.replayCursor == nil)
        #expect(next.consecutiveBudgetFailures == 0 && next.pageLimit == nil)
        let child = try await adapter.normalize(continuation, capturedAt: Date(), cryptography: crypto)
        #expect(child.continuation == nil)
        #expect(child.sources.count == 1 && child.sources[0].record.metadata.identity.session.sessionID == "child")
        let calls = await history.recordedCalls()
        #expect(calls.contains("direction:desc") && !calls.contains("direction:asc"))
        #expect(!calls.contains { $0.contains("prior-boundary") || $0.contains("prior-unfinished-boundary") })
    }

    @Test func singleUnfinishedTailRestartsDescendingAndCapturesItsLaterCompletionWithVisibleGap() async throws {
        let history = CodexTestHistory(), checkpoints = CodexBudgetCheckpoints()
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let unfinished = try codexJSON(["turnId": "turn", "startedAtMs": 1_791_434_400_000,
            "item": ["id": "pending", "type": "commandExecution", "status": "inProgress", "aggregatedOutput": ""]])
        await history.configure("parent", thread: try codexThread(), pages: [])
        await history.configureDescending("parent", page: .init(data: [unfinished], nextCursor: "unread-prefix",
            backwardsCursor: "exclusive-boundary"))
        let adapter = try codexTestAdapter(history: history, checkpoints: { await checkpoints.get($0) })
        let cold = try await adapter.normalize(codexPacket(thread: "parent"), capturedAt: Date(), cryptography: crypto)
        #expect(cold.continuation == nil)
        #expect(cold.coverageGaps.contains { $0.reason == .unresolvedCorrelation })
        #expect(cold.coverageGaps.contains { $0.reason == .budgetExhausted })
        await checkpoints.save(cold.checkpoints)
        let completed = try codexItem("pending", type: "commandExecution",
            body: ["status": "completed", "aggregatedOutput": "late singleton output", "exitCode": 0])
        await history.configureDescending("parent", page: .init(data: [completed], nextCursor: "unread-prefix",
            backwardsCursor: "exclusive-boundary"))
        let restarted = try codexTestAdapter(history: history, checkpoints: { await checkpoints.get($0) })
        let later = try await restarted.normalize(codexPacket(thread: "parent"), capturedAt: Date(), cryptography: crypto)
        #expect(later.sources.contains { $0.record.metadata.identity.itemID == "pending" && codexText($0) == "late singleton output" })
        #expect(later.coverageGaps.contains { $0.reason == .unresolvedCorrelation })
        let calls = await history.recordedCalls()
        #expect(calls.filter { $0 == "direction:desc" }.count == 2 && !calls.contains("direction:asc"))
        #expect(!calls.contains("items:parent:unread-prefix") && !calls.contains("items:parent:exclusive-boundary"))
    }
}
