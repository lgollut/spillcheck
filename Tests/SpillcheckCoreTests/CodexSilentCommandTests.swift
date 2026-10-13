import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor SilentCommandCheckpoints {
    var values: [UUID: SourceCheckpoint] = [:]
    func save(_ value: SourceCheckpoint) { values[value.sourceDocumentID] = value }
    func get(_ id: UUID) -> SourceCheckpoint? { values[id] }
}
private actor SilentCommandDetector: SecretDetector {
    private(set) var calls = 0
    func scan(_ source: SourceRecord) -> DetectorOutput {
        calls += 1
        return .init(detectorVersion: "fake-silent-command-detector", findings: [], unlocated: [])
    }
}

@Suite("Codex native silent command results")
struct CodexSilentCommandTests {
    @Test func explicitTerminalNullIsEmptyButMissingOutputRemainsMalformed() async throws {
        let entries = [
            try codexItem("silent-success", type: "commandExecution", body: ["status": "completed", "exitCode": 0, "aggregatedOutput": NSNull()]),
            try codexItem("silent-error", type: "commandExecution", body: ["status": "completed", "exitCode": 7, "aggregatedOutput": NSNull()]),
            try codexItem("failed-before-execution", type: "commandExecution", body: ["status": "failed", "exitCode": NSNull(), "aggregatedOutput": NSNull()]),
            try codexItem("declined", type: "commandExecution", body: ["status": "declined", "exitCode": NSNull(), "aggregatedOutput": NSNull()]),
            try codexItem("missing", type: "commandExecution", body: ["status": "completed", "exitCode": 0]),
            try codexItem("unaffected-sibling")]
        let batch = try await codexTestAdapter().importPublicItems(.init(data: entries), thread: codexThread(),
            observedAt: Date(), cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(batch.sources.map(\.record.metadata.identity.itemID) == ["unaffected-sibling"])
        #expect(Set(batch.recoveredReferences.compactMap(\.itemID)) ==
            ["silent-success", "silent-error", "failed-before-execution", "declined", "unaffected-sibling"])
        #expect(batch.coverageGaps.count == 1)
        let gap = try #require(batch.coverageGaps.first { $0.recovery?.itemID == "missing" })
        #expect(gap.reason == .malformedSource && gap.isRequiredFormatFailure == true)
    }

    @Test func emptyStringAndNullHaveNoLocationsWhileNonemptyOutputKeepsItsCategoryAndBytes() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        for (status, exit, expected): (String, Any, ContentType) in [
            ("completed", 0, .toolOutput), ("completed", 7, .toolError),
            ("failed", NSNull(), .toolError), ("declined", NSNull(), .toolError)] {
            for output: Any in [NSNull(), "", "é🙂\r\nexact output"] {
                let entry = try codexItem("same-original", type: "commandExecution", body: [
                    "status": status, "exitCode": exit, "aggregatedOutput": output])
                let batch = try await adapter.importPublicItems(.init(data: [entry]), thread: codexThread(),
                    observedAt: Date(), cryptography: crypto)
                #expect(batch.coverageGaps.isEmpty && batch.recoveredReferences.count == 1)
                if output as? String == "é🙂\r\nexact output" {
                    let source = try #require(batch.sources.first)
                    #expect(batch.sources.count == 1 && source.record.metadata.contentType == expected)
                    #expect(source.record.metadata.identity.itemID == "same-original")
                    #expect(source.record.segments.map(\.id) == ["/aggregatedOutput"])
                    #expect(source.record.segments.map(\.utf8) == [Data("é🙂\r\nexact output".utf8)])
                } else { #expect(batch.sources.isEmpty) }
            }
        }
    }

    @Test func missingOrInvalidOutputNeverRecoversAnyTerminalCommand() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        for status in ["completed", "failed", "declined"] {
            for output: Any? in [nil, false, 0, ["unexpected"], ["text": "not aggregate text"]] {
                var body: [String: Any] = ["status": status, "exitCode": 0]
                body["aggregatedOutput"] = output
                let batch = try await adapter.importPublicItems(.init(data: [codexItem("bad", type: "commandExecution", body: body)]),
                    thread: codexThread(), observedAt: Date(), cryptography: crypto)
                #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty)
                #expect(batch.coverageGaps.count == 1 && batch.coverageGaps.first?.reason == .malformedSource)
                #expect(batch.coverageGaps.first?.isRequiredFormatFailure == true)
            }
        }
    }

    @Test func nullOutputDoesNotWaiveCompletedExitCodeOrKnownStatus() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        for code: Any? in [nil, NSNull(), false, "0", 1.5] {
            var body: [String: Any] = ["status": "completed", "aggregatedOutput": NSNull()]
            body["exitCode"] = code
            let batch = try await adapter.importPublicItems(.init(data: [codexItem("bad-exit", type: "commandExecution", body: body)]),
                thread: codexThread(), observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty)
            #expect(batch.coverageGaps.first?.reason == .malformedSource && batch.coverageGaps.first?.isRequiredFormatFailure == true)
        }
        for status: Any? in [nil, NSNull(), false, "future-terminal-status"] {
            var body: [String: Any] = ["exitCode": 0, "aggregatedOutput": NSNull()]
            body["status"] = status
            let batch = try await adapter.importPublicItems(.init(data: [codexItem("bad-status", type: "commandExecution", body: body)]),
                thread: codexThread(), observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty)
            #expect(batch.coverageGaps.first?.reason == .malformedSource && batch.coverageGaps.first?.isRequiredFormatFailure == true)
        }
    }

    @Test func unfinishedNullRemainsRetryableUntilOriginalCommandReturnsText() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let pending = try codexItem("same-command", type: "commandExecution", body: [
            "status": "inProgress", "exitCode": NSNull(), "aggregatedOutput": NSNull()])
        let first = try await adapter.importPublicItems(.init(data: [pending]), thread: codexThread(),
            observedAt: Date(), cryptography: crypto)
        #expect(first.sources.isEmpty && first.recoveredReferences.isEmpty)
        #expect(first.coverageGaps.count == 1 && first.coverageGaps.first?.reason == .incompleteMessage)
        let completed = try codexItem("same-command", type: "commandExecution", body: [
            "status": "completed", "exitCode": 7, "aggregatedOutput": "late error output"])
        let second = try await adapter.importPublicItems(.init(data: [completed]), thread: codexThread(),
            observedAt: Date(), cryptography: crypto)
        #expect(second.coverageGaps.isEmpty && second.sources.count == 1)
        #expect(second.sources.first?.record.metadata.identity.itemID == "same-command")
        #expect(second.sources.first?.record.metadata.contentType == .toolError)
        #expect(second.sources.first.map(codexText) == "late error output")
        #expect(second.recoveredReferences.map(\.itemID) == ["same-command"])
    }

    @Test func v9CompletedAuditReconsidersUnchangedSilentOriginal() async throws {
        let history = CodexTestHistory(), checkpoints = SilentCommandCheckpoints()
        let crypto = try BackgroundCryptography.ephemeralForTesting(), now = Date(timeIntervalSince1970: 1_791_434_500)
        await history.configure("parent", thread: try codexThread(updatedAt: 1_791_434_400), pages: [.init(data: [try codexItem(
            "silent-original", type: "commandExecution", body: ["status": "completed", "exitCode": 0, "aggregatedOutput": NSNull()])])])
        let adapter = try codexTestAdapter(history: history, checkpoints: { await checkpoints.get($0) })
        let firstAudit = try HistoricalAuditContext(reason: .firstLaunch, endingAt: now)
        let first = try await adapter.normalize(adapter.packet(.init(audit: firstAudit, threads: ["parent"])),
            capturedAt: now, cryptography: crypto)
        let checkpoint = try #require(first.checkpoints.first), bytes = try #require(checkpoint.adapterState)
        var state = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        state["parserContract"] = "codex-content-contract-v9"
        await checkpoints.save(.init(capabilityID: checkpoint.capabilityID, sourceDocumentID: checkpoint.sourceDocumentID,
            revision: checkpoint.revision, byteOffset: checkpoint.byteOffset, lastContentTime: checkpoint.lastContentTime,
            adapterState: try JSONSerialization.data(withJSONObject: state)))
        let nextAudit = try HistoricalAuditContext(reason: .restart, endingAt: now.addingTimeInterval(30))
        let next = try await adapter.normalize(adapter.packet(.init(audit: nextAudit, threads: ["parent"])),
            capturedAt: now, cryptography: crypto)
        #expect(next.sources.isEmpty && next.coverageGaps.isEmpty)
        #expect(next.recoveredReferences.contains { $0.itemID == "silent-original" && $0.parserContract == CodexAdapter.parserContract })
    }

    @Test func falseWarningRecoversWithoutFabricatedScanOrReceiptAndColdReplayIsEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-silent-command-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting(), detector = SilentCommandDetector()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), contentTime = now.addingTimeInterval(-30)
        let history = CodexTestHistory()
        let session = try SessionIdentity(provider: .codex, profileID: "test", sessionID: "silent-session")
        let scope = CollectionScope(provider: .codex, profileID: "test", interface: .standaloneCLI, path: .publicHistory)
        await history.configure(session.sessionID, thread: try codexThread(session.sessionID), pages: [.init(data: [try codexItem(
            "silent-original", type: "commandExecution", timestamp: contentTime.timeIntervalSince1970 * 1000,
            body: ["status": "completed", "exitCode": 0, "aggregatedOutput": NSNull()])])])
        func oldGap(_ item: String) -> CoverageGap {
            .init(reason: .malformedSource, scope: scope, contentType: .toolOutput, operation: .liveRead,
                recovery: .init(session: session, locator: .upstreamItem, itemID: item, contentTime: contentTime,
                    parserContract: "codex-content-contract-v9"), isRequiredFormatFailure: true,
                sourceKind: .codexCommandExecution, observedAt: contentTime)
        }
        let packet = try codexPacket(thread: session.sessionID, interface: .standaloneCLI)
        let context = try CollectionCaptureRoute(scope: scope, readerVersion: "0.162.1").context(for: packet, trigger: .activePoll)
        for replay in [false, true] {
            let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
            if !replay {
                try await store.recordCoverageGap(oldGap("silent-original"), at: contentTime)
                try await store.recordCoverageGap(oldGap("unrelated-command"), at: contentTime)
            }
            let adapter = try CodexAdapter(profileID: "test", agentVersion: "0.162.1", history: history,
                authorityLookup: { try await store.authority(for: $0) }, authorityRecorder: { choice in
                    let permit = try #require(await store.processingPermit())
                    try await store.selectAuthority(choice, permit: permit)
                })
            let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
                detector: detector, detectorVersion: "fake-silent-command-detector")
            let permit = try #require(await store.processingPermit())
            _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, workContext: context)
            #expect(try await pipeline.processNext(at: now) == .processed)
            #expect(try await store.queueStatistics().count == 0)
            let omissions = try await store.coverageOmissions()
            #expect(omissions.count == 1 && omissions.first?.gap.recovery?.itemID == "unrelated-command")
            let snapshot = await store.snapshot()
            #expect(snapshot.records.isEmpty && snapshot.occurrences.isEmpty && snapshot.analysisReceipts.isEmpty)
            #expect(snapshot.sourceKinds.isEmpty && snapshot.alertDecisions.isEmpty)
            try await store.close()
        }
        #expect(await detector.calls == 0)
    }
}
