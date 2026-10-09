import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor CodexCheckpoints {
    var values: [UUID: SourceCheckpoint] = [:]
    func save(_ checkpoints: [SourceCheckpoint]) { for checkpoint in checkpoints { values[checkpoint.sourceDocumentID] = checkpoint } }
    func get(_ id: UUID) -> SourceCheckpoint? { values[id] }
}
private struct CodexTailCheckpointFixture: Decodable {
    let bootstrapped: Bool?
    let coldPageLimit: Int?
}
private actor CodexOversizedTailHistory: CodexHistoryReading {
    var requestedLimits: [Int] = []
    func readThread(_ threadID: String) throws -> CodexThreadRead {
        .init(thread: try codexThread(threadID), bytesRead: 64)
    }
    func listThreads(cursor: String?, limit: Int, archived: Bool) -> CodexHistoryPage { .init(data: []) }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection) -> CodexHistoryPage { .init(data: []) }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int, direction: CodexHistoryDirection) throws -> CodexHistoryPage {
        requestedLimits.append(limit)
        guard limit == 1 else { throw CodexHistoryReadFailure(reason: .responseLimitExceeded, bytesRead: 512) }
        return .init(data: [try codexItem("newest-small-item")], nextCursor: "unread-oversized-prefix", backwardsCursor: "exclusive-newest", bytesRead: 96)
    }
    func limits() -> [Int] { requestedLimits }
}
@Suite("Codex bounded public history and active replay")
struct CodexHistoryTests {
    @Test func oversizedColdTailRetriesOneItemWithoutReadingItsOversizedSentinel() async throws {
        let history = CodexOversizedTailHistory(), authority = CodexTestAuthority()
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try CodexAdapter(profileID: "test", agentVersion: "0.161.0", interface: .t3,
            t3Version: CodexAdapter.validatedT3Version, history: history, limits: .init(pageSize: 256),
            authorityLookup: { await authority.lookup($0) }, authorityRecorder: { try await authority.record($0) })
        let first = try await adapter.normalize(codexPacket(thread: "parent"), capturedAt: Date(), cryptography: crypto)
        #expect(first.sources.isEmpty && first.continuation != nil)
        let recovered = try await adapter.normalize(#require(first.continuation), capturedAt: Date(), cryptography: crypto)
        #expect(recovered.sources.map(\.record.metadata.identity.itemID) == ["newest-small-item"])
        #expect(recovered.continuation == nil)
        #expect(recovered.coverageGaps.contains { $0.reason == .unresolvedCorrelation })
        #expect(recovered.coverageGaps.contains { $0.reason == .budgetExhausted })
        #expect(await history.limits() == [256, 1])
        let saved = try JSONDecoder().decode(CodexTailCheckpointFixture.self, from: #require(recovered.checkpoints.first?.adapterState))
        #expect(saved.bootstrapped == false && saved.coldPageLimit == 1)
    }
    @Test func olderLargeSessionReadsRecentTailWithoutExpandingThroughOldPrefix() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: 1_791_434_400), audit = try HistoricalAuditContext(reason: .firstLaunch, endingAt: now)
        let thread = try codexJSON(["id": "old-created-recent-content", "cliVersion": "0.160.1",
            "createdAt": now.addingTimeInterval(-365*86400).timeIntervalSince1970, "updatedAt": now.timeIntervalSince1970])
        let recent = try codexItem("recent", timestamp: now.addingTimeInterval(-1).timeIntervalSince1970 * 1000)
        let old = try codexItem("old", timestamp: audit.start.addingTimeInterval(-1).timeIntervalSince1970 * 1000)
        await history.configure("old-created-recent-content", thread: thread,
            pages: [.init(data: [recent, old], nextCursor: "1", bytesRead: 128), .init(data: [try codexItem("never-read")], bytesRead: 128)])
        await history.configureListings([.init(data: [thread], bytesRead: 64)], archived: false)
        let adapter = try codexTestAdapter(history: history)
        let batch = try await adapter.normalize(adapter.initialHistoricalCapture(audit: audit), capturedAt: now, cryptography: crypto)
        #expect(batch.sources.map(\.record.metadata.identity.itemID) == ["recent"])
        #expect(batch.coverageGaps.contains { $0.reason == .budgetExhausted && $0.interval == DateInterval(start: audit.start, end: audit.end) })
        #expect(batch.historicalProgress?.oldestContentTime == now.addingTimeInterval(-1))
        #expect(!(await history.recordedCalls()).contains("items:old-created-recent-content:1"))
        #expect((await history.recordedCalls()).contains("direction:desc"))
        let terminal = try await adapter.normalize(#require(batch.continuation), capturedAt: now, cryptography: crypto)
        #expect(terminal.continuation == nil && terminal.historicalProgress?.hasUnreadContent == true)
    }

    @Test func liveAndHistoricalCheckpointsNeverOverwriteEachOther() async throws {
        let history = CodexTestHistory(), checkpoints = CodexCheckpoints(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: 1_791_434_400)
        await history.configure("parent", thread: try codexThread(updatedAt: 1_791_434_000),
            pages: [.init(data: [try codexItem("first")], nextCursor: "1"),
                    .init(data: [try codexItem("tail")])])
        await history.configureDescending("parent", page: .init(data: [try codexItem("tail"), try codexItem("first")]))
        let adapter = try codexTestAdapter(history: history, checkpoints: { await checkpoints.get($0) })
        let cold = try await adapter.normalize(codexPacket(thread: "parent"), capturedAt: now, cryptography: crypto)
        await checkpoints.save(cold.checkpoints)
        let first = try await adapter.normalize(codexPacket(thread: "parent"), capturedAt: now, cryptography: crypto)
        let last = try await adapter.normalize(#require(first.continuation), capturedAt: now, cryptography: crypto)
        await checkpoints.save(last.checkpoints)
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        var request = CodexHistoryRequest(audit: audit, threads: ["parent"]); request.discovering = false
        let historical = try await adapter.normalize(adapter.packet(request), capturedAt: now, cryptography: crypto)
        await checkpoints.save(historical.checkpoints)
        #expect(last.checkpoints[0].sourceDocumentID != historical.checkpoints[0].sourceDocumentID)
        let warm = try await adapter.normalize(codexPacket(thread: "parent"), capturedAt: now, cryptography: crypto)
        #expect(warm.sources.map(\.record.metadata.identity.itemID) == ["tail"])
    }

    @Test func earliestUnfinishedPageSurvivesPaginationAndCatchesLaterCompletion() async throws {
        let history = CodexTestHistory(), checkpoints = CodexCheckpoints(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let unfinished = try codexJSON(["turnId": "turn", "startedAtMs": 1_791_434_400_000,
            "item": ["id": "tool", "type": "commandExecution", "status": "inProgress", "aggregatedOutput": ""]])
        await history.configure("parent", thread: try codexThread(), pages: [.init(data: [unfinished], nextCursor: "1"),
            .init(data: [try codexItem("later")])])
        await history.configureDescending("parent", page: .init(data: [try codexItem("later"), unfinished]))
        let adapter = try codexTestAdapter(history: history, checkpoints: { await checkpoints.get($0) })
        let cold = try await adapter.normalize(codexPacket(thread: "parent"), capturedAt: Date(), cryptography: crypto)
        await checkpoints.save(cold.checkpoints)
        await history.configure("parent", thread: try codexThread(), pages: [.init(data: [try codexItem("tool", type: "commandExecution",
            body: ["status": "completed", "aggregatedOutput": "late synthetic", "exitCode": 0])], nextCursor: "1"),
            .init(data: [try codexItem("later")])])
        let warm = try await adapter.normalize(codexPacket(thread: "parent"), capturedAt: Date(), cryptography: crypto)
        #expect(warm.sources.contains { $0.record.metadata.identity.itemID == "tool" && codexText($0) == "late synthetic" })
    }
    @Test func coldLiveReadsBoundedTailAndRestartReplaysUnfinishedTailFromNativeBoundary() async throws {
        let history = CodexTestHistory(), checkpoints = CodexCheckpoints(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let unfinished = try codexJSON(["turnId": "turn", "startedAtMs": 1_791_434_400_000,
            "item": ["id": "pending", "type": "commandExecution", "status": "inProgress", "aggregatedOutput": ""]])
        await history.configure("old-session", thread: try codexThread("old-session"),
            pages: [.init(data: [try codexItem("pending", type: "commandExecution",
                body: ["status": "completed", "exitCode": 0, "aggregatedOutput": "late output"]), try codexItem("latest")])])
        await history.configureDescending("old-session", page: .init(data: [try codexItem("latest"), unfinished, try codexItem("old-prefix-sentinel")],
            nextCursor: "old-prefix", backwardsCursor: "0"))
        let adapter = try codexTestAdapter(history: history, limits: .init(pageSize: 2), checkpoints: { await checkpoints.get($0) })
        let cold = try await adapter.normalize(codexPacket(thread: "old-session"), capturedAt: Date(), cryptography: crypto)
        #expect(cold.sources.map(\.record.metadata.identity.itemID) == ["latest"] && cold.continuation == nil)
        #expect(cold.coverageGaps.contains { $0.reason == .budgetExhausted })
        await checkpoints.save(cold.checkpoints)
        let restarted = try codexTestAdapter(history: history, limits: .init(pageSize: 2), checkpoints: { await checkpoints.get($0) })
        let warm = try await restarted.normalize(codexPacket(thread: "old-session"), capturedAt: Date(), cryptography: crypto)
        #expect(warm.sources.contains { $0.record.metadata.identity.itemID == "pending" && codexText($0) == "late output" })
        #expect(!(await history.recordedCalls()).contains("items:old-session:old-prefix"))
    }

    @Test func preflushEmptyHistoryRemainsRetryableAndAppendedSourceIsCanonical() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        await history.configure("parent", thread: try codexThread(), pages: [.init(data: [])])
        let adapter = try codexTestAdapter(history: history), capture = try codexPacket(thread: "parent", event: "UserPromptSubmit")
        await #expect(throws: CodexCollectionError.awaitingHistory) {
            try await adapter.normalize(capture, capturedAt: Date(), cryptography: crypto)
        }
        await history.configure("parent", thread: try codexThread(), pages: [.init(data: [try codexItem("flushed")])])
        #expect(try await adapter.normalize(capture, capturedAt: Date(), cryptography: crypto).sources[0].record.metadata.identity.itemID == "flushed")
    }

    @Test func budgetExhaustionKeepsUnreadContinuationAndCannotWriteAFullProgressClaim() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        await history.configure("parent", thread: try codexThread(), pages: [.init(data: [try codexItem()], bytesRead: 128)])
        let adapter = try codexTestAdapter(history: history, budget: .init(maximumBytes: 64, maximumDuration: 1, maximumSources: 1))
        let audit = try HistoricalAuditContext(reason: .resume, endingAt: Date())
        let request = CodexHistoryRequest(audit: audit, threads: ["parent"])
        let batch = try await adapter.normalize(adapter.packet(request), capturedAt: Date(), cryptography: crypto)
        #expect(batch.sources.isEmpty && batch.checkpoints.isEmpty && batch.continuation != nil)
        #expect(batch.historicalProgress?.bytesRead == 64 && batch.historicalProgress?.hasUnreadContent == true)
        #expect(batch.coverageGaps.contains(.init(reason: .budgetExhausted)))
    }

    @Test func exactNativeChildReferencesAreBoundedAndCyclesDoNotReopenParent() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let reference = try codexItem("ref", type: "subAgentActivity", body: ["agentThreadId": "child", "kind": "spawned"])
        let back = try codexItem("back", type: "subAgentActivity", body: ["agentThreadId": "parent", "kind": "spawned"])
        await history.configure("parent", thread: try codexThread(), pages: [.init(data: [reference])])
        await history.configure("child", thread: try codexThread("child"), pages: [.init(data: [back, try codexItem("own-final")])])
        let adapter = try codexTestAdapter(history: history)
        let parent = try await adapter.normalize(codexPacket(thread: "parent"), capturedAt: Date(), cryptography: crypto)
        let child = try await adapter.normalize(#require(parent.continuation), capturedAt: Date(), cryptography: crypto)
        #expect(child.continuation == nil)
        #expect(child.sources.count == 1 && child.sources[0].record.metadata.identity.session.sessionID == "child")
        #expect((await history.recordedCalls()).filter { $0 == "read:parent" }.count == 1)
    }

    @Test func idlePollIsCurrentWhileHookCaptureStillAwaitsFlush() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        await history.configure("parent", thread: try codexThread(), pages: [.init(data: [])])
        let adapter = try codexTestAdapter(history: history)
        let polled = try await adapter.normalize(codexPacket(thread: "parent"), capturedAt: Date(), cryptography: crypto)
        #expect(polled.sources.isEmpty && polled.checkpoints.isEmpty && polled.coverageGaps.isEmpty)
        await #expect(throws: CodexCollectionError.awaitingHistory) {
            try await adapter.normalize(codexPacket(thread: "parent", event: "UserPromptSubmit"), capturedAt: Date(), cryptography: crypto)
        }
    }

    @Test func missingItemMethodIsBlockedScopedAndLeavesAnotherNativeThreadUsable() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        await history.configure("blocked", thread: try codexThread("blocked"), pages: [])
        await history.configureFailure("items:blocked", error: .missingMethod("thread/items/list"))
        await history.configure("working", thread: try codexThread("working"), pages: [.init(data: [try codexItem("readable")])])
        let adapter = try codexTestAdapter(history: history)
        let request = CodexHistoryRequest(audit: nil, threads: ["blocked", "working"])
        let blocked = try await adapter.normalize(adapter.packet(request), capturedAt: Date(), cryptography: crypto)
        let gap = try #require(blocked.coverageGaps.first)
        #expect(gap.reason == .unsupportedContent && gap.scope?.interface == .t3)
        #expect(gap.operation == .liveRead)
        #expect(gap.recovery?.session?.sessionID == "blocked" && gap.isRequiredFormatFailure == true)
        #expect(blocked.sources.isEmpty && blocked.recoveredReferences.isEmpty)
        let working = try await adapter.normalize(#require(blocked.continuation), capturedAt: Date(), cryptography: crypto)
        #expect(working.sources.map(\.record.metadata.identity.itemID) == ["readable"] && working.coverageGaps.isEmpty)
        let historical = CodexHistoryRequest(audit: try HistoricalAuditContext(reason: .restart, endingAt: Date()), threads: ["blocked"])
        let failedAudit = try await adapter.normalize(adapter.packet(historical), capturedAt: Date(), cryptography: crypto)
        #expect(failedAudit.coverageGaps.first?.operation == .historicalRead)
    }

    @Test func missingDiscoveryMethodReportsRouteFailureWithoutInventingRecoveryIdentity() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        await history.configureFailure("list", error: .missingMethod("thread/list"))
        let adapter = try codexTestAdapter(history: history)
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: Date())
        let batch = try await adapter.normalize(adapter.initialHistoricalCapture(audit: audit), capturedAt: Date(), cryptography: crypto)
        let gap = try #require(batch.coverageGaps.first)
        #expect(gap.reason == .unsupportedContent && gap.scope?.path == .publicHistory)
        #expect(gap.operation == .historicalRead)
        #expect(gap.isRequiredFormatFailure == true && gap.recovery == nil)
        #expect(batch.sources.isEmpty && batch.continuation == nil)
        #expect(batch.historicalProgress?.hasUnreadContent == true)
    }

    @Test func missingTurnMethodKeepsDatedItemsCollectingAndLeavesUndatedItemOmitted() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        await history.configure("parent", thread: try codexThread(), pages: [.init(data: [try codexItem("dated"), try codexItem("undated", timestamp: nil)])])
        await history.configureFailure("turns:parent", error: .missingMethod("thread/turns/list"))
        let batch = try await codexTestAdapter(history: history).normalize(codexPacket(thread: "parent"), capturedAt: Date(), cryptography: crypto)
        #expect(batch.sources.map(\.record.metadata.identity.itemID) == ["dated"])
        #expect(batch.coverageGaps.contains { $0.reason == .missingTimestamp && $0.recovery?.itemID == "undated" })
        #expect(!batch.recoveredReferences.contains { $0.itemID == "undated" || $0.locator == .unavailable })
    }

    @Test func unchangedThreadWithAnOmissionIsReparsedAndOnlyItsRecoveredItemResolves() async throws {
        let history = CodexTestHistory(), checkpoints = CodexCheckpoints(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: 1_791_434_400)
        await history.configure("parent", thread: try codexThread(updatedAt: 1_791_434_000),
            pages: [.init(data: [try codexItem("broken", body: ["phase": "final_answer", "text": 42]), try codexItem("readable")])])
        let adapter = try codexTestAdapter(history: history, checkpoints: { await checkpoints.get($0) })
        let request = CodexHistoryRequest(audit: try HistoricalAuditContext(reason: .restart, endingAt: now), threads: ["parent"])
        let first = try await adapter.normalize(adapter.packet(request), capturedAt: now, cryptography: crypto)
        #expect(first.sources.map(\.record.metadata.identity.itemID) == ["readable"])
        #expect(first.coverageGaps.contains { $0.recovery?.itemID == "broken" && $0.isRequiredFormatFailure == true })
        await checkpoints.save(first.checkpoints)
        await history.configure("parent", thread: try codexThread(updatedAt: 1_791_434_000),
            pages: [.init(data: [try codexItem("broken"), try codexItem("readable")])])
        let recovered = try await adapter.normalize(adapter.packet(request), capturedAt: now, cryptography: crypto)
        #expect(recovered.sources.count == 2 && recovered.coverageGaps.isEmpty)
        #expect(recovered.recoveredReferences.contains { $0.itemID == "broken" })
        #expect((await history.recordedCalls()).filter { $0.hasPrefix("items:") }.count == 2)
    }

    @Test func finalReadableAuditPageCannotResolveAnEarlierSessionOmission() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: 1_791_434_400)
        await history.configure("parent", thread: try codexThread(updatedAt: 1_791_434_000),
            pages: [.init(data: [try codexItem("broken", body: ["phase": "final_answer", "text": 42])], nextCursor: "1"),
                .init(data: [try codexItem("readable")])])
        let adapter = try codexTestAdapter(history: history)
        let request = CodexHistoryRequest(audit: try HistoricalAuditContext(reason: .restart, endingAt: now), threads: ["parent"])
        let first = try await adapter.normalize(adapter.packet(request), capturedAt: now, cryptography: crypto)
        #expect(first.coverageGaps.contains { $0.recovery?.itemID == "broken" })
        let last = try await adapter.normalize(#require(first.continuation), capturedAt: now, cryptography: crypto)
        #expect(last.sources.map(\.record.metadata.identity.itemID) == ["readable"] && last.coverageGaps.isEmpty)
        #expect(last.historicalProgress?.hasUnreadContent == true)
        #expect(last.recoveredReferences.contains { $0.itemID == "readable" })
        #expect(!last.recoveredReferences.contains { $0.locator == .unavailable && $0.itemID == nil })
    }

    @Test func earlierThreadOmissionCannotBlockTheNextThreadsSessionRecovery() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: 1_791_434_400)
        await history.configure("broken-thread", thread: try codexThread("broken-thread", updatedAt: 1_791_434_000),
            pages: [.init(data: [try codexItem("broken", body: ["phase": "final_answer", "text": 42])])])
        await history.configure("clean-thread", thread: try codexThread("clean-thread", updatedAt: 1_791_434_000),
            pages: [.init(data: [try codexItem("readable")])])
        let adapter = try codexTestAdapter(history: history)
        let request = CodexHistoryRequest(audit: try HistoricalAuditContext(reason: .restart, endingAt: now),
            threads: ["broken-thread", "clean-thread"])
        let first = try await adapter.normalize(adapter.packet(request), capturedAt: now, cryptography: crypto)
        #expect(first.coverageGaps.contains { $0.recovery?.itemID == "broken" })
        #expect(!first.recoveredReferences.contains { $0.locator == .unavailable && $0.itemID == nil })
        let next = try await adapter.normalize(#require(first.continuation), capturedAt: now, cryptography: crypto)
        #expect(next.coverageGaps.isEmpty)
        #expect(next.recoveredReferences.contains {
            $0.locator == .unavailable && $0.itemID == nil && $0.session?.sessionID == "clean-thread"
        })
        // The audit as a whole still reports the earlier thread's omission.
        #expect(next.historicalProgress?.hasUnreadContent == true)
    }

    @Test func restoredMissingNativeItemIDResolvesOnlyAfterCompleteNoGapPass() async throws {
        let history = CodexTestHistory(), checkpoints = CodexCheckpoints(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: 1_791_434_400)
        await history.configure("parent", thread: try codexThread(updatedAt: 1_791_434_000), pages: [.init(data: [try codexItem("")])])
        let adapter = try codexTestAdapter(history: history, checkpoints: { await checkpoints.get($0) })
        let request = CodexHistoryRequest(audit: try HistoricalAuditContext(reason: .restart, endingAt: now), threads: ["parent"])
        let first = try await adapter.normalize(adapter.packet(request), capturedAt: now, cryptography: crypto)
        let missing = try #require(first.coverageGaps.first?.recovery)
        #expect(missing.locator == .unavailable && missing.itemID == nil)
        await checkpoints.save(first.checkpoints)
        await history.configure("parent", thread: try codexThread(updatedAt: 1_791_434_000), pages: [.init(data: [try codexItem("restored-native")])])
        let restored = try await adapter.normalize(adapter.packet(request), capturedAt: now, cryptography: crypto)
        #expect(restored.coverageGaps.isEmpty && restored.sources.count == 1)
        #expect(restored.recoveredReferences.contains { $0.identifiesSameLocation(as: missing) })
    }

    @Test func warmLiveSuffixDoesNotClaimWholeSessionRecovery() async throws {
        let history = CodexTestHistory(), checkpoints = CodexCheckpoints(), crypto = try BackgroundCryptography.ephemeralForTesting()
        await history.configure("parent", thread: try codexThread(), pages: [.init(data: [try codexItem("readable")])])
        let adapter = try codexTestAdapter(history: history, checkpoints: { await checkpoints.get($0) })
        let cold = try await adapter.normalize(codexPacket(thread: "parent"), capturedAt: Date(), cryptography: crypto)
        #expect(cold.recoveredReferences.contains { $0.locator == .unavailable && $0.itemID == nil })
        await checkpoints.save(cold.checkpoints)
        let warm = try await adapter.normalize(codexPacket(thread: "parent"), capturedAt: Date(), cryptography: crypto)
        #expect(warm.sources.count == 1 && warm.coverageGaps.isEmpty)
        #expect(warm.recoveredReferences.contains { $0.itemID == "readable" })
        #expect(!warm.recoveredReferences.contains { $0.locator == .unavailable && $0.itemID == nil })
    }

    @Test func auditSkipsThreadsUnchangedSinceAnEarlierCompletedRead() async throws {
        let history = CodexTestHistory(), checkpoints = CodexCheckpoints(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: 1_791_434_400)
        await history.configure("parent", thread: try codexThread(updatedAt: 1_791_434_000), pages: [.init(data: [try codexItem("only")])])
        await history.configureDescending("parent", page: .init(data: [try codexItem("only")]))
        let adapter = try codexTestAdapter(history: history, checkpoints: { await checkpoints.get($0) })
        func audit(endingAt end: Date) async throws -> CollectionBatch {
            let request = CodexHistoryRequest(audit: try HistoricalAuditContext(reason: .resume, endingAt: end), threads: ["parent"])
            let batch = try await adapter.normalize(adapter.packet(request), capturedAt: now, cryptography: crypto)
            await checkpoints.save(batch.checkpoints)
            return batch
        }
        func itemReads() async -> Int { await history.recordedCalls().filter { $0.hasPrefix("items:") }.count }
        #expect(try await audit(endingAt: now).sources.count == 1)
        #expect(await itemReads() == 1)
        let unchanged = try await audit(endingAt: now.addingTimeInterval(60))
        #expect(unchanged.sources.isEmpty && unchanged.historicalProgress?.hasUnreadContent == false)
        #expect(await itemReads() == 1)
        await history.configure("parent", thread: try codexThread(updatedAt: 1_791_434_100), pages: [.init(data: [try codexItem("only")])])
        _ = try await audit(endingAt: now.addingTimeInterval(120))
        #expect(await itemReads() == 2)
        // Content updated after an audit's end was outside that audit, so the next audit rereads it.
        await history.configure("parent", thread: try codexThread(updatedAt: 1_791_434_590), pages: [.init(data: [try codexItem("only")])])
        _ = try await audit(endingAt: now.addingTimeInterval(180))
        _ = try await audit(endingAt: now.addingTimeInterval(240))
        #expect(await itemReads() == 4)
        _ = try await audit(endingAt: now.addingTimeInterval(300))
        #expect(await itemReads() == 4)
    }
}
