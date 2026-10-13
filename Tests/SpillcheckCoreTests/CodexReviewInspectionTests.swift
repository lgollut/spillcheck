import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private let inspectionValue = "SPILLCHECK_FAKE_PAGINATED_REVIEW_42"
private let inspectionVersion = "fake-review-inspection-v1"

private actor ReviewInspectionHistory: CodexHistoryReading {
    var thread: CodexJSON
    var main: [CodexHistoryPage]
    var selected: [CodexHistoryPage]
    var turns: CodexHistoryPage
    var selectedCalls = 0
    var mainCalls = 0
    var turnCalls = 0
    var mutationAt: Int?
    var mutated: [CodexHistoryPage]?
    var timeoutCalls: Set<Int> = []
    var byteBudgets: [Int] = []
    var durationBudgets: [TimeInterval] = []
    var requestedTurnIDs: [String] = []
    init(main: [CodexHistoryPage], selected: [CodexHistoryPage], turns: CodexHistoryPage = .init(data: []),
         thread: CodexJSON? = nil) throws {
        self.main = main; self.selected = selected; self.turns = turns
        self.thread = try thread ?? codexThread(producer: "0.162.1")
    }
    func mutate(at call: Int, pages: [CodexHistoryPage]) { mutationAt = call; mutated = pages }
    func timeOut(at calls: Set<Int>) { timeoutCalls = calls }
    func readThread(_ id: String) throws -> CodexThreadRead {
        guard id == "parent" else { throw CodexHistoryError.unavailable }
        return .init(thread: thread, bytesRead: 10, readerVersion: "0.162.1")
    }
    func listThreads(cursor: String?, limit: Int, archived: Bool) throws -> CodexHistoryPage {
        throw CodexHistoryError.unavailable
    }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection) throws -> CodexHistoryPage {
        guard threadID == "parent" else { throw CodexHistoryError.unavailable }
        turnCalls += 1; return turns
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int,
                   direction: CodexHistoryDirection) throws -> CodexHistoryPage {
        try page(threadID: threadID, turnID: turnID, cursor: cursor, limit: limit, direction: direction)
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int,
                   direction: CodexHistoryDirection, budget: CodexRPCBudget) throws -> CodexHistoryPage {
        byteBudgets.append(budget.maximumBytes); durationBudgets.append(budget.timeout)
        return try page(threadID: threadID, turnID: turnID, cursor: cursor, limit: limit, direction: direction)
    }
    private func page(threadID: String, turnID: String?, cursor: String?, limit: Int,
                      direction: CodexHistoryDirection) throws -> CodexHistoryPage {
        guard threadID == "parent" else { throw CodexHistoryError.unavailable }
        let index = Int(cursor ?? "0") ?? -1
        if let turnID {
            requestedTurnIDs.append(turnID); selectedCalls += 1
            guard turnID == "turn", direction == .ascending else { throw CodexHistoryError.rejectedParameters("unexpected exact-turn request") }
            if timeoutCalls.contains(selectedCalls) { throw CodexHistoryError.timedOut }
            let pages = mutationAt.map { selectedCalls >= $0 } == true ? (mutated ?? selected) : selected
            guard pages.indices.contains(index) else { throw CodexHistoryError.malformedResponse }
            return pages[index]
        }
        mainCalls += 1
        guard main.indices.contains(index) else { throw CodexHistoryError.malformedResponse }
        return main[index]
    }
    func counts() -> (Int, Int, Int) { (mainCalls, selectedCalls, turnCalls) }
    func budgets() -> ([Int], [TimeInterval]) { (byteBudgets, durationBudgets) }
}

private actor InspectionDetector: SecretDetector {
    var calls = 0
    let partial: Bool
    init(partial: Bool = false) { self.partial = partial }
    func scan(_ source: SourceRecord) throws -> DetectorOutput {
        calls += 1
        var findings: [DetectorFinding] = []
        for segment in source.segments {
            if let range = segment.utf8.range(of: Data(inspectionValue.utf8)) {
                let location = try CanonicalLocation(segmentID: segment.id, range: .init(range.lowerBound, range.upperBound))
                findings.append(try .init(extraction: .init(valueUTF8: Data(inspectionValue.utf8), location: location,
                    in: source), evidence: [evidence()]))
            }
        }
        return .init(detectorVersion: inspectionVersion, findings: findings, unlocated: [],
            coverageGaps: partial ? [.init(reason: .scannerUnavailable)] : [])
    }
}

@Suite("Codex fresh paginated review inspection", .timeLimit(.minutes(1)))
struct CodexReviewInspectionTests {
    private let now = Date(timeIntervalSince1970: 1_791_434_500)
    private func row(_ id: String, exit: Bool = false, text: String = inspectionValue,
                     timestamp: Double? = 1_791_434_400_000) throws -> CodexJSON {
        try codexItem(id, type: exit ? "exitedReviewMode" : "agentMessage", timestamp: timestamp,
            body: exit ? ["review": text] : ["phase": NSNull(), "text": text])
    }
    private func page(_ rows: [CodexJSON], next: String? = nil, bytes: Int = 80) -> CodexHistoryPage {
        .init(data: rows, nextCursor: next, bytesRead: bytes, readerVersion: "0.162.1")
    }
    private func adapter(_ history: ReviewInspectionHistory, budget: HistoryReadBudget = .init(),
                         limits: CodexReadLimits = .init(), authority: CodexTestAuthority = .init()) throws -> CodexAdapter {
        try .init(profileID: "test", agentVersion: "0.162.1", interface: .standaloneCLI,
            authority: .publicNativeItems, history: history, limits: limits, historyBudget: budget,
            authorityLookup: { await authority.lookup($0) }, authorityRecorder: { try await authority.record($0) })
    }
    private func request(_ adapter: CodexAdapter, now: Date? = nil) throws -> CapturePacket {
        var request = CodexHistoryRequest(audit: try .init(reason: .restart, endingAt: now ?? self.now), threads: ["parent"])
        request.selectedSourceOnly = true
        return try adapter.packet(request)
    }
    private func untilDependency(_ adapter: CodexAdapter, packet: CapturePacket, crypto: BackgroundCryptography,
                                 observedAt: Date? = nil) async throws -> [CollectionBatch] {
        var packet: CapturePacket? = packet, batches: [CollectionBatch] = []
        for _ in 0..<30 {
            guard let selected = packet else { return batches }
            let batch = try await adapter.normalize(selected, capturedAt: observedAt ?? now, cryptography: crypto)
            batches.append(batch)
            if !batch.pendingRecoveryDependencies.isEmpty { return batches }
            packet = batch.continuation
        }
        Issue.record("inspection did not terminate within its fixture bound")
        return batches
    }

    @Test(arguments: [false, true])
    func bothPageOrdersRereadExactOriginalWithoutPersistedText(originalFirst: Bool) async throws {
        let original = try row("original"), exit = try row("exit", exit: true)
        let selected = originalFirst ? [page([original], next: "1"), page([exit])] : [page([exit], next: "1"), page([original])]
        let history = try ReviewInspectionHistory(main: [page([exit], next: "1"), page([original])], selected: selected)
        let adapter = try adapter(history), crypto = try BackgroundCryptography.ephemeralForTesting()
        let batches = try await untilDependency(adapter, packet: request(adapter), crypto: crypto)
        let final = try #require(batches.last)
        #expect(final.pendingRecoveryDependencies.count == 1)
        #expect(final.sources.map(\.record.metadata.identity.itemID) == ["original"])
        #expect(final.sources.first?.record.segments.first?.utf8 == Data(inspectionValue.utf8))
        #expect(final.continuation != nil && final.unresolvedRecoveryContinuation != nil)
        #expect(await history.counts().1 == 6) // two complete passes and two current page reads
        for batch in batches.dropLast() {
            let next = try #require(batch.continuation)
            #expect(next.eventJSON.range(of: Data(inspectionValue.utf8)) == nil)
            let decoded = try JSONDecoder().decode(CodexHistoryRequest.self, from: next.eventJSON)
            #expect(decoded.partial == false && decoded.threadPartial == false)
            #expect(batch.checkpoints.isEmpty && batch.historicalProgress?.hasUnreadContent == true)
        }
        let resumed = try await adapter.normalize(#require(final.continuation), capturedAt: now, cryptography: crypto)
        #expect(resumed.continuation == nil && resumed.historicalProgress?.hasUnreadContent == false)
        let failed = try await adapter.normalize(#require(final.unresolvedRecoveryContinuation), capturedAt: now, cryptography: crypto)
        #expect(failed.continuation == nil && failed.historicalProgress?.hasUnreadContent == true)
    }

    @Test func wholeTurnInOneResponseNeedsOnlyOneFreshInspection() async throws {
        let original = try row("original"), exit = try row("exit", exit: true)
        let history = try ReviewInspectionHistory(main: [page([exit], next: "1"), page([original])],
            selected: [page([original, exit])])
        let adapter = try adapter(history), crypto = try BackgroundCryptography.ephemeralForTesting()
        let batches = try await untilDependency(adapter, packet: request(adapter), crypto: crypto)
        #expect(batches.count == 2 && batches.last?.pendingRecoveryDependencies.count == 1)
        #expect(await history.counts().1 == 1)
    }

    @Test func currentPageMutationCannotHideNewAmbiguousOriginal() async throws {
        let original = try row("original"), exit = try row("exit", exit: true)
        let initial = [page([original], next: "1"), page([exit])]
        let history = try ReviewInspectionHistory(main: [page([exit])], selected: initial)
        await history.mutate(at: 5, pages: [page([original, try row("new-copy")], next: "1"), page([exit])])
        let adapter = try adapter(history), crypto = try BackgroundCryptography.ephemeralForTesting()
        let batches = try await untilDependency(adapter, packet: request(adapter), crypto: crypto)
        #expect(batches.allSatisfy { $0.pendingRecoveryDependencies.isEmpty })
        #expect(batches.last?.continuation == nil && batches.last?.historicalProgress?.hasUnreadContent == true)
        #expect(batches.last?.coverageGaps.contains { $0.reason == .sourceChanged && $0.recovery?.itemID == "exit" } == true)
    }

    @Test(arguments: ["duplicate", "changed", "cycle", "foreign-turn"])
    func invalidOrChangingPassNeverBecomesProof(kind: String) async throws {
        let original = try row("original"), exit = try row("exit", exit: true)
        var selected = [page([original], next: "1"), page([exit])]
        if kind == "duplicate" { selected = [page([original], next: "1"), page([original, exit])] }
        if kind == "cycle" { selected = [page([original], next: "1"), page([exit], next: "1")] }
        if kind == "foreign-turn" {
            selected = [page([try codexJSON(["turnId": "foreign", "completedAtMs": 1_791_434_400_000,
                "item": ["type": "agentMessage", "id": "original", "phase": NSNull(), "text": inspectionValue]])]), page([exit])]
        }
        let history = try ReviewInspectionHistory(main: [page([exit])], selected: selected)
        if kind == "changed" { await history.mutate(at: 3, pages: [page([try row("original", text: "changed")], next: "1"), page([exit])]) }
        let adapter = try adapter(history), crypto = try BackgroundCryptography.ephemeralForTesting()
        let batches = try await untilDependency(adapter, packet: request(adapter), crypto: crypto)
        #expect(batches.allSatisfy { $0.pendingRecoveryDependencies.isEmpty })
        #expect(batches.last?.continuation == nil && batches.last?.historicalProgress?.hasUnreadContent == true)
        #expect(batches.last?.coverageGaps.contains { $0.recovery?.itemID == "exit" } == true)
    }

    @Test func timeoutsRetryBoundedlyWithoutPoisoningARecoveredInspection() async throws {
        let original = try row("original"), exit = try row("exit", exit: true)
        for recover in [false, true] {
            let history = try ReviewInspectionHistory(main: [page([exit])], selected: [page([original, exit])])
            await history.timeOut(at: recover ? [1, 2] : [1, 2, 3])
            let adapter = try adapter(history), crypto = try BackgroundCryptography.ephemeralForTesting()
            let batches = try await untilDependency(adapter, packet: request(adapter), crypto: crypto)
            #expect((batches.last?.pendingRecoveryDependencies.count == 1) == recover)
            #expect(await history.counts().1 == 3)
            if !recover { #expect(batches.last?.historicalProgress?.hasUnreadContent == true) }
        }
    }

    @Test func finalTwoPageReadsShareRemainingByteAndTimeBudget() async throws {
        let original = try row("original"), exit = try row("exit", exit: true)
        let history = try ReviewInspectionHistory(main: [page([exit])], selected: [page([original], next: "1"), page([exit])])
        let adapter = try adapter(history, budget: .init(maximumBytes: 1000, maximumDuration: 2, maximumSources: 6))
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let batches = try await untilDependency(adapter, packet: request(adapter), crypto: crypto)
        #expect(batches.last?.pendingRecoveryDependencies.count == 1)
        let (bytes, times) = await history.budgets()
        #expect(Array(bytes.suffix(2)) == [990, 910])
        #expect(times.allSatisfy { $0 > 0 && $0 <= 2 })
        #expect(times.last! < times[times.count - 2])
        #expect(batches.last?.historicalProgress?.bytesRead == 170)
    }

    @Test func finalAggregateLimitCannotGrantProofFromIndividuallyBoundedPages() async throws {
        let original = try row("original"), exit = try row("exit", exit: true)
        let history = try ReviewInspectionHistory(main: [page([exit])], selected: [page([original], next: "1"), page([exit])])
        let adapter = try adapter(history, budget: .init(maximumBytes: 100, maximumDuration: 2, maximumSources: 6))
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let batches = try await untilDependency(adapter, packet: request(adapter), crypto: crypto)
        #expect(batches.allSatisfy { $0.pendingRecoveryDependencies.isEmpty })
        #expect(batches.last?.continuation == nil && batches.last?.historicalProgress?.hasUnreadContent == true)
        #expect(batches.last?.coverageGaps.contains { $0.reason == .budgetExhausted && $0.recovery?.itemID == "exit" } == true)
    }

    @Test func malformedExpiredOrReboundContinuationStopsWithoutFurtherRead() async throws {
        let original = try row("original"), exit = try row("exit", exit: true)
        for invalid in ["empty", "no-thread", "audit", "target", "expired", "version"] {
            let history = try ReviewInspectionHistory(main: [page([exit])], selected: [page([original], next: "1"), page([exit])])
            let adapter = try adapter(history), crypto = try BackgroundCryptography.ephemeralForTesting()
            let initial = try await adapter.normalize(request(adapter), capturedAt: now, cryptography: crypto)
            let started = try await adapter.normalize(#require(initial.continuation), capturedAt: now, cryptography: crypto)
            let continuation = try #require(started.continuation)
            var json = try #require(JSONSerialization.jsonObject(with: continuation.eventJSON) as? [String: Any])
            var work = try #require(json["reviewWork"] as? [String: Any])
            var state = try #require(work["inspection"] as? [String: Any])
            if invalid == "empty" { work["targets"] = [] }
            if invalid == "no-thread" { json["threads"] = []; json["selectedSourceOnly"] = false }
            if invalid == "audit" { state["audit"] = nil }
            if invalid == "target" { state["targetItemID"] = "other" }
            if invalid == "expired" { state["startedAt"] = 0 }
            if invalid == "version" { state["parserContract"] = "codex-content-contract-v12" }
            work["inspection"] = state; json["reviewWork"] = work
            let packet = try CapturePacket(metadata: continuation.metadata, eventJSON: JSONSerialization.data(withJSONObject: json))
            let rejected = try await adapter.normalize(packet, capturedAt: now, cryptography: crypto)
            #expect(rejected.continuation == nil && rejected.pendingRecoveryDependencies.isEmpty)
            #expect(rejected.historicalProgress?.hasUnreadContent == true)
            #expect(await history.counts().1 == 1)
        }
    }

    @Test func freshCompletedTurnTimestampFallbackIsPreserved() async throws {
        let original = try row("original", timestamp: nil), exit = try row("exit", exit: true, timestamp: nil)
        let turns = page([try codexJSON(["id": "turn", "startedAt": 1_791_434_390, "completedAt": 1_791_434_400])])
        let history = try ReviewInspectionHistory(main: [page([exit])], selected: [page([original, exit])], turns: turns)
        let adapter = try adapter(history), crypto = try BackgroundCryptography.ephemeralForTesting()
        let batches = try await untilDependency(adapter, packet: request(adapter), crypto: crypto)
        #expect(batches.last?.pendingRecoveryDependencies.count == 1)
        #expect(batches.last?.sources.first?.record.metadata.contentTime == Date(timeIntervalSince1970: 1_791_434_400))
        #expect(await history.counts().2 == 2)
    }

    @Test(arguments: [false, true])
    func completeFreshRootGroupEnablesEntryThroughNormalHistory(laterThread: Bool) async throws {
        let input = try codexJSON(["turnId": "input-turn", "completedAtMs": 1_791_434_400_000,
            "item": ["id": "input", "type": "userMessage", "content": [["type": "text", "text": "Review only"]]]])
        let entry = try codexItem("entry", type: "enteredReviewMode", body: ["review": "Review only"])
        let turns = page([try codexJSON(["id": "turn", "rootTurnId": "turn"]),
                          try codexJSON(["id": "input-turn", "rootTurnId": "turn"])])
        let history = try ReviewInspectionHistory(main: [page([entry, input])], selected: [], turns: turns)
        let adapter = try adapter(history), crypto = try BackgroundCryptography.ephemeralForTesting()
        var inputRequest = CodexHistoryRequest(audit: try .init(reason: .restart, endingAt: now),
            threads: laterThread ? ["parent", "another"] : ["parent"])
        inputRequest.discovering = laterThread
        let batch = try await adapter.normalize(adapter.packet(inputRequest), capturedAt: now, cryptography: crypto)
        #expect(batch.pendingRecoveryDependencies.count == 1)
        #expect((batch.continuation != nil) == laterThread)
        if laterThread {
            let successPacket = try #require(batch.continuation)
            let failurePacket = try #require(batch.unresolvedRecoveryContinuation)
            let success = try JSONDecoder().decode(CodexHistoryRequest.self, from: successPacket.eventJSON)
            let failure = try JSONDecoder().decode(CodexHistoryRequest.self, from: failurePacket.eventJSON)
            #expect(success.threads == ["another"] && failure.threads == success.threads)
            #expect(success.partial == false && failure.partial == true)
            #expect(success.threadPartial == false && failure.threadPartial == false)
        }
        #expect(batch.pendingRecoveryDependencies.first?.provisionalGap.recovery?.itemID == "entry")
        #expect(batch.sources.first?.record.metadata.identity.itemID == "input")
        #expect(batch.checkpoints.isEmpty && batch.historicalProgress?.hasUnreadContent == laterThread)
        #expect(await history.counts().2 == 1)
    }

    @Test func encryptedQueuedInspectionSurvivesRestartAndFullReceiptSettlesOnlyExit() async throws {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let time = now.addingTimeInterval(-30).timeIntervalSince1970 * 1000
        let original = try row("original", timestamp: time), exit = try row("exit", exit: true, timestamp: time)
        let history = try ReviewInspectionHistory(main: [page([exit], next: "1"), page([original])],
            selected: [page([original], next: "1"), page([exit])])
        let adapter = try adapter(history), crypto = try BackgroundCryptography.ephemeralForTesting()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-review-inspection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let packet = try request(adapter, now: now)
        let audit = try #require(JSONDecoder().decode(CodexHistoryRequest.self, from: packet.eventJSON).audit)
        let scope = CollectionScope(provider: .codex, profileID: "test", interface: .standaloneCLI, path: .publicHistory)
        let context = try CollectionCaptureRoute(scope: scope).context(for: packet, trigger: .historyRequest, audit: audit)
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now,
            historicalAudit: audit, workContext: context)
        let unrelated = CoverageGap(reason: .sourceUnavailable, scope: scope, operation: .historicalRead,
            recovery: .init(session: try SessionIdentity(provider: .codex, profileID: "test", sessionID: "parent"), itemID: "unrelated", parserContract: CodexAdapter.parserContract))
        try await store.recordCoverageGap(unrelated, at: now)
        let detector = InspectionDetector()
        var pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
            detector: detector, detectorVersion: inspectionVersion, liveSince: now)
        #expect(try await pipeline.processNext(at: now) == .processed)
        #expect(try await store.coverageOmissions().contains { $0.gap.recovery?.itemID == "exit" })
        #expect(try await store.queueStatistics().count == 1)
        #expect(await store.snapshot().analysisReceipts.isEmpty)
        try await store.close()
        // Neither source plaintext nor proof summaries escape the encrypted queue/database.
        for file in try inspectionFiles(in: directory) {
            #expect(try Data(contentsOf: file).range(of: Data(inspectionValue.utf8)) == nil)
        }
        store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
            detector: detector, detectorVersion: inspectionVersion, liveSince: now)
        for _ in 0..<12 {
            if try await store.queueStatistics().count == 0 { break }
            #expect(try await pipeline.processNext(at: now.addingTimeInterval(1)) == .processed)
        }
        #expect(try await store.queueStatistics().count == 0)
        let snapshot = await store.snapshot()
        #expect(snapshot.occurrences.count == 1 && snapshot.analysisReceipts.count == 1)
        #expect(snapshot.occurrences.values.first?.source.identity.itemID == "original")
        #expect(await detector.calls == 1)
        #expect(try await store.coverageOmissions().map { $0.gap.recovery?.itemID } == ["unrelated"])
        #expect(try await store.historicalProgress().first?.progress.hasUnreadContent == false)
        try await store.close()
    }
}

private func inspectionFiles(in directory: URL) throws -> [URL] {
    let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    return try files.compactMap { $0 as? URL }.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
}
