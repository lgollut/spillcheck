import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor ReviewHistoryCheckpoints {
    var values: [UUID: SourceCheckpoint] = [:]
    func save(_ checkpoints: [SourceCheckpoint]) { for checkpoint in checkpoints { values[checkpoint.sourceDocumentID] = checkpoint } }
    func get(_ id: UUID) -> SourceCheckpoint? { values[id] }
}

@Suite("Codex bounded review presentation recovery")
struct CodexReviewHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_791_434_500)
    private func entries() throws -> [CodexJSON] {
        [try codexItem("original-review", body: ["phase": NSNull(), "text": "Original review é🙂\r\n"]),
         try codexItem("exit-review", type: "exitedReviewMode", body: ["review": "Original review é🙂\r\n"])]
    }
    private func request(_ adapter: CodexAdapter, threads: [String] = ["parent"], discovering: Bool = false) throws -> CapturePacket {
        var request = CodexHistoryRequest(audit: try .init(reason: .firstLaunch, endingAt: now), threads: threads)
        request.discovering = discovering
        return try adapter.packet(request)
    }

    @Test func completeTerminalReadDefersOnlyTheExactExitAndCannotCacheCleanAudit() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        await history.configure("parent", thread: try codexThread(producer: "0.162.1", updatedAt: now.timeIntervalSince1970 - 60),
            pages: [.init(data: try entries())])
        let adapter = try codexTestAdapter(history: history)
        let batch = try await adapter.normalize(request(adapter), capturedAt: now, cryptography: crypto)
        #expect(batch.continuation == nil && batch.historicalProgress?.hasUnreadContent == false)
        #expect(batch.sources.count == 1 && batch.coverageGaps.count == 1)
        #expect(batch.pendingRecoveryDependencies.count == 1 && batch.checkpoints.isEmpty)
        let dependency = try #require(batch.pendingRecoveryDependencies.first)
        #expect(dependency.provisionalGap == batch.coverageGaps.first)
        #expect(dependency.originalMetadata == batch.sources.first?.record.metadata)
        #expect(dependency.originalRevision == batch.sources.first?.record.revision)
        #expect(batch.recoveredReferences.map(\.itemID) == ["original-review"])
    }

    @Test func nativeInputInAnotherTurnAndEntryWarningStaySeparate() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        var rows = try entries()
        rows.append(try codexJSON(["turnId": "internal-review-turn", "completedAtMs": 1_791_434_400_000,
            "item": ["id": "original-input", "type": "userMessage", "content": [["type": "text", "text": "Review instructions"]]]]))
        rows.append(try codexItem("enter-review", type: "enteredReviewMode", body: ["review": "Review instructions"]))
        await history.configure("parent", thread: try codexThread(producer: "0.162.1"), pages: [.init(data: rows)])
        let adapter = try codexTestAdapter(history: history)
        let batch = try await adapter.normalize(request(adapter), capturedAt: now, cryptography: crypto)
        #expect(batch.sources.count == 2 && batch.pendingRecoveryDependencies.count == 1)
        #expect(batch.pendingRecoveryDependencies.first?.provisionalGap.recovery?.itemID == "exit-review")
        #expect(batch.coverageGaps.contains { $0.recovery?.itemID == "enter-review" })
        #expect(batch.historicalProgress?.hasUnreadContent == true)
    }

    @Test func pendingExitRecoveryCannotHideNativeChildInputRequirement() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let thread = try codexJSON(["id": "parent", "cliVersion": "0.162.1", "parentThreadId": "native-parent"])
        await history.configure("parent", thread: thread, pages: [.init(data: try entries())])
        let adapter = try codexTestAdapter(history: history)
        let batch = try await adapter.normalize(request(adapter), capturedAt: now, cryptography: crypto)
        #expect(batch.pendingRecoveryDependencies.count == 1)
        #expect(batch.coverageGaps.contains { $0.recovery?.itemID == CodexAdapter.nativeChildInputRequirementID
            && $0.diagnosticCode == .nativeChildInputUnavailable && $0.isRequiredFormatFailure == true })
        #expect(batch.historicalProgress?.hasUnreadContent == true)
    }

    @Test func paginatedReadAndItsFinalPageRetainWarningAcrossContinuation() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        await history.configure("parent", thread: try codexThread(), pages: [
            .init(data: try entries(), nextCursor: "1"), .init(data: try entries())])
        let adapter = try codexTestAdapter(history: history)
        let first = try await adapter.normalize(request(adapter), capturedAt: now, cryptography: crypto)
        let queued = try #require(first.continuation)
        #expect(try JSONDecoder().decode(CodexHistoryRequest.self, from: queued.eventJSON).reviewWork != nil)
        var next: CapturePacket? = queued
        var all = [first]
        for _ in 0..<8 {
            guard let packet = next else { break }
            let batch = try await adapter.normalize(packet, capturedAt: now, cryptography: crypto)
            all.append(batch); next = batch.continuation
        }
        // This legacy fake supplies no observed reader version, so its fresh inspection
        // fails closed. The production-shaped reader is exercised by the new suite.
        #expect(all.allSatisfy { $0.pendingRecoveryDependencies.isEmpty })
        #expect(next == nil && all.last?.historicalProgress?.hasUnreadContent == true)
        #expect(all.contains { $0.coverageGaps.contains { $0.recovery?.itemID == "exit-review" } })
    }

    @Test func additionalThreadOrDiscoveryCannotLoseDeniedReceiptOutcome() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        await history.configure("parent", thread: try codexThread(), pages: [.init(data: try entries())])
        let adapter = try codexTestAdapter(history: history)
        for packet in [try request(adapter, threads: ["parent", "another"]), try request(adapter, discovering: true)] {
            let batch = try await adapter.normalize(packet, capturedAt: now, cryptography: crypto)
            #expect(batch.pendingRecoveryDependencies.count == 1 && batch.continuation != nil)
            #expect(batch.unresolvedRecoveryContinuation != nil && batch.historicalProgress?.hasUnreadContent == true)
            let failedPacket = try #require(batch.unresolvedRecoveryContinuation)
            let failed = try JSONDecoder().decode(CodexHistoryRequest.self, from: failedPacket.eventJSON)
            #expect(failed.partial == true && failed.threadPartial == false)
        }
    }

    @Test func warmCheckpointNeverReusesCompleteReadProof() async throws {
        let history = CodexTestHistory(), checkpoints = ReviewHistoryCheckpoints()
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        await history.configure("parent", thread: try codexThread(), pages: [.init(data: try entries())])
        let adapter = try codexTestAdapter(history: history, checkpoints: { await checkpoints.get($0) })
        let first = try await adapter.normalize(codexPacket(thread: "parent"), capturedAt: now, cryptography: crypto)
        #expect(first.pendingRecoveryDependencies.count == 1)
        await checkpoints.save(first.checkpoints)
        let completeReplay = try await adapter.normalize(codexPacket(thread: "parent"), capturedAt: now, cryptography: crypto)
        #expect(completeReplay.pendingRecoveryDependencies.count == 1)
        let checkpoint = try #require(first.checkpoints.first)
        let stateData = try #require(checkpoint.adapterState)
        var state = try #require(JSONSerialization.jsonObject(with: stateData) as? [String: Any])
        state["pollCursor"] = "0"
        await checkpoints.save([.init(capabilityID: checkpoint.capabilityID, sourceDocumentID: checkpoint.sourceDocumentID,
            revision: checkpoint.revision, byteOffset: 0, adapterState: try JSONSerialization.data(withJSONObject: state))])
        let second = try await adapter.normalize(codexPacket(thread: "parent"), capturedAt: now, cryptography: crypto)
        #expect(second.pendingRecoveryDependencies.isEmpty)
        #expect(second.coverageGaps.contains { $0.recovery?.itemID == "exit-review" })
    }

    @Test func versionTwelveCleanCheckpointCannotSkipNewInspection() async throws {
        let history = CodexTestHistory(), checkpoints = ReviewHistoryCheckpoints()
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let rows = try entries(), thread = try codexThread(updatedAt: now.timeIntervalSince1970 - 60)
        await history.configure("parent", thread: thread, pages: [.init(data: [rows[0]])])
        let adapter = try codexTestAdapter(history: history, checkpoints: { await checkpoints.get($0) })
        let original = try await adapter.normalize(request(adapter), capturedAt: now, cryptography: crypto)
        let checkpoint = try #require(original.checkpoints.first)
        let stateData = try #require(checkpoint.adapterState)
        var state = try #require(JSONSerialization.jsonObject(with: stateData) as? [String: Any])
        state["parserContract"] = "codex-content-contract-v12"
        await checkpoints.save([.init(capabilityID: checkpoint.capabilityID, sourceDocumentID: checkpoint.sourceDocumentID,
            revision: checkpoint.revision, byteOffset: 0, adapterState: try JSONSerialization.data(withJSONObject: state))])
        await history.configure("parent", thread: thread, pages: [.init(data: rows)])
        let replay = try await adapter.normalize(request(adapter), capturedAt: now, cryptography: crypto)
        #expect(replay.pendingRecoveryDependencies.count == 1)
        #expect(replay.sources.first?.record.metadata.identity == original.sources.first?.record.metadata.identity)
        #expect(replay.sources.first?.record.revision == original.sources.first?.record.revision)
    }
}
