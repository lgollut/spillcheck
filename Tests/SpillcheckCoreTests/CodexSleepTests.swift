import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor SleepCheckpoints {
    var values: [UUID: SourceCheckpoint] = [:]
    func save(_ value: SourceCheckpoint) { values[value.sourceDocumentID] = value }
    func get(_ id: UUID) -> SourceCheckpoint? { values[id] }
}
private actor SleepDetector: SecretDetector {
    private(set) var calls = 0
    func scan(_ source: SourceRecord) -> DetectorOutput {
        calls += 1
        return .init(detectorVersion: "fake-sleep-detector", findings: [], unlocated: [])
    }
}

@Suite("Codex native sleep display metadata")
struct CodexSleepTests {
    @Test func knownDurationOnlyItemsHaveNoContentOrExecutionOutcome() async throws {
        let entries = try [1, 1_000, 43_200_000].map { duration in
            try codexItem("sleep-\(duration)", type: "sleep", body: ["durationMs": duration])
        }
        let batch = try await codexTestAdapter().importPublicItems(.init(data: entries), thread: codexThread(),
            observedAt: Date(), cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(batch.sources.isEmpty && batch.coverageGaps.isEmpty)
        #expect(batch.recoveredReferences.count == 3)
        #expect(batch.recoveredReferences.allSatisfy { $0.constraint == .unclassifiedMetadata })
        #expect(Set(batch.recoveredReferences.compactMap(\.itemID)) == ["sleep-1", "sleep-1000", "sleep-43200000"])
        #expect(batch.recoveredReferences.allSatisfy { $0.locator == .upstreamItem && $0.session?.sessionID == "parent" })
    }

    @Test func missingInvalidAndOutOfProducerRangeDurationsRemainRequiredGaps() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        for duration: Any? in [nil, NSNull(), false, "1000", -1, 0, 0.5, 43_200_001, 1e30, [], ["milliseconds": 1000]] {
            var body: [String: Any] = [:]
            body["durationMs"] = duration
            let batch = try await adapter.importPublicItems(.init(data: [codexItem("invalid", type: "sleep", body: body)]),
                thread: codexThread(), observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty)
            #expect(batch.coverageGaps.count == 1)
            #expect(batch.coverageGaps.first?.reason == .malformedSource)
            #expect(batch.coverageGaps.first?.isRequiredFormatFailure == true)
            #expect(batch.coverageGaps.first?.contentType == nil)
        }
    }

    @Test func newFieldsNeverSilentlyDiscardReturnedOrUnknownContent() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        for (field, value): (String, Any) in [
            ("output", "SPILLCHECK_FAKE_SLEEP_OUTPUT_42"), ("text", "new content"),
            ("result", ["text": "new result"]), ("status", "completed"),
            ("success", true), ("futureMetadata", NSNull())] {
            let item = try codexItem("extended", type: "sleep", body: ["durationMs": 1_000, field: value])
            let batch = try await adapter.importPublicItems(.init(data: [item]), thread: codexThread(),
                observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty)
            #expect(batch.coverageGaps.count == 1 && batch.coverageGaps.first?.reason == .unsupportedContent)
            #expect(batch.coverageGaps.first?.isRequiredFormatFailure == true)
        }
    }

    @Test func separateReturnedTextAndMissingOutputKeepTheirOwnIdentityAndCoverage() async throws {
        let text = "Wall time: 0.0100 seconds\nSleep interrupted by new input.\né🙂"
        let entries = [
            try codexItem("sleep-call", type: "sleep", body: ["durationMs": 1_000]),
            try codexItem("returned-original", type: "functionCallOutput", body: ["output": text]),
            try codexItem("missing-return", type: "functionCallOutput", body: [:])]
        let batch = try await codexTestAdapter().importPublicItems(.init(data: entries), thread: codexThread(),
            observedAt: Date(), cryptography: BackgroundCryptography.ephemeralForTesting())
        let source = try #require(batch.sources.first)
        #expect(batch.sources.count == 1 && source.record.metadata.identity.itemID == "returned-original")
        #expect(source.record.metadata.contentType == .toolOutput)
        #expect(source.record.segments.map(\.id) == ["/output"])
        #expect(source.record.segments.map(\.utf8) == [Data(text.utf8)])
        #expect(batch.recoveredReferences.first { $0.itemID == "sleep-call" }?.constraint == .unclassifiedMetadata)
        #expect(batch.recoveredReferences.first { $0.itemID == "returned-original" }?.constraint == nil)
        #expect(batch.coverageGaps.count == 1 && batch.coverageGaps.first?.recovery?.itemID == "missing-return")
        #expect(batch.coverageGaps.first?.isRequiredFormatFailure == true)
    }

    @Test func rowIdentityTimestampAndAuditBoundsStillApplyToMetadata() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting(), adapter = try codexTestAdapter()
        for entry in [try codexItem("", type: "sleep", body: ["durationMs": 1]),
                      try codexItem("untimed", type: "sleep", timestamp: nil, body: ["durationMs": 1])] {
            let batch = try await adapter.importPublicItems(.init(data: [entry]), thread: codexThread(),
                observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty && batch.coverageGaps.count == 1)
        }
        let limited = try codexTestAdapter(limits: .init(maximumRowBytes: 1024))
        let oversized = try codexItem("bounded", type: "sleep", body: ["durationMs": 1, "text": String(repeating: "x", count: 2048)])
        let bounded = try await limited.importPublicItems(.init(data: [oversized]), thread: codexThread(),
            observedAt: Date(), cryptography: crypto)
        #expect(bounded.sources.isEmpty && bounded.recoveredReferences.isEmpty)
        #expect(bounded.coverageGaps.first?.reason == .budgetExhausted)
        let now = Date(timeIntervalSince1970: 1_791_434_500), audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let expired = try codexItem("outside", type: "sleep", timestamp: audit.start.addingTimeInterval(-1).timeIntervalSince1970 * 1000,
            body: ["durationMs": 1])
        let outside = try await adapter.importPublicItems(.init(data: [expired]), thread: codexThread(), observedAt: now,
            provenance: .historical(audit), cryptography: crypto)
        #expect(outside.sources.isEmpty && outside.recoveredReferences.isEmpty && outside.coverageGaps.isEmpty)
    }

    @Test func v14CompletedAuditReconsidersUnchangedSleepItem() async throws {
        let history = CodexTestHistory(), checkpoints = SleepCheckpoints()
        let crypto = try BackgroundCryptography.ephemeralForTesting(), now = Date(timeIntervalSince1970: 1_791_434_500)
        await history.configure("parent", thread: try codexThread(updatedAt: 1_791_434_400), pages: [.init(data: [try codexItem(
            "sleep-original", type: "sleep", body: ["durationMs": 1_000])])])
        let adapter = try codexTestAdapter(history: history, checkpoints: { await checkpoints.get($0) })
        let audit = try HistoricalAuditContext(reason: .firstLaunch, endingAt: now)
        let first = try await adapter.normalize(adapter.packet(.init(audit: audit, threads: ["parent"])),
            capturedAt: now, cryptography: crypto)
        let checkpoint = try #require(first.checkpoints.first), bytes = try #require(checkpoint.adapterState)
        var state = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        state["parserContract"] = "codex-content-contract-v14"
        await checkpoints.save(.init(capabilityID: checkpoint.capabilityID, sourceDocumentID: checkpoint.sourceDocumentID,
            revision: checkpoint.revision, byteOffset: checkpoint.byteOffset, lastContentTime: checkpoint.lastContentTime,
            adapterState: try JSONSerialization.data(withJSONObject: state)))
        let previousReads = await history.recordedCalls().filter { $0.hasPrefix("items:") }.count
        let nextAudit = try HistoricalAuditContext(reason: .restart, endingAt: now.addingTimeInterval(30))
        let next = try await adapter.normalize(adapter.packet(.init(audit: nextAudit, threads: ["parent"])),
            capturedAt: now, cryptography: crypto)
        #expect(await history.recordedCalls().filter { $0.hasPrefix("items:") }.count == previousReads + 1)
        #expect(next.sources.isEmpty && next.coverageGaps.isEmpty)
        #expect(next.recoveredReferences.contains { $0.itemID == "sleep-original" && $0.constraint == .unclassifiedMetadata })
    }

    @Test(arguments: [false, true])
    func encryptedRecoveryClearsOnlyOldMetadataAndCurrentUnreadContentVetoesIt(currentSameIDGap: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-sleep-metadata-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting(), detector = SleepDetector()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), contentTime = now.addingTimeInterval(-30)
        let history = CodexTestHistory(), session = try SessionIdentity(provider: .codex, profileID: "test", sessionID: "sleep-session")
        let scope = CollectionScope(provider: .codex, profileID: "test", interface: .standaloneCLI, path: .publicHistory)
        var rows = [try codexItem("sleep-original", type: "sleep", timestamp: contentTime.timeIntervalSince1970 * 1000,
            body: ["durationMs": 1_000])]
        if currentSameIDGap {
            rows.append(try codexItem("sleep-original", type: "functionCallOutput",
                timestamp: contentTime.timeIntervalSince1970 * 1000, body: [:]))
        }
        await history.configure(session.sessionID, thread: try codexThread(session.sessionID), pages: [.init(data: rows)])
        func gap(_ item: String = "sleep-original", reason: CoverageGapReason = .unsupportedContent,
                 type: ContentType? = nil, required: Bool = false, kind: CoverageSourceKind = .codexUnknownItem) -> CoverageGap {
            .init(reason: reason, scope: scope, contentType: type, operation: .liveRead,
                recovery: .init(session: session, locator: .upstreamItem, itemID: item, contentTime: contentTime,
                    parserContract: "codex-content-contract-v14"), isRequiredFormatFailure: required,
                sourceKind: kind, diagnosticCode: reason.defaultDiagnosticCode, observedAt: contentTime)
        }
        let preserved = [
            gap(reason: .unsupportedContent, type: .toolOutput, required: true, kind: .codexFunctionCallOutput),
            gap(reason: .scannerUnavailable, type: .toolOutput, required: true, kind: .codexFunctionCallOutput),
            gap(reason: .malformedSource, type: .toolOutput, required: true, kind: .codexFunctionCallOutput),
            gap("separate-return", reason: .malformedSource, type: .toolOutput, required: true, kind: .codexFunctionCallOutput)]
        let packet = try codexPacket(thread: session.sessionID, interface: .standaloneCLI)
        let context = try CollectionCaptureRoute(scope: scope, readerVersion: "0.162.1").context(for: packet, trigger: .activePoll)
        for replay in [false, true] {
            let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
            if !replay {
                try await store.recordCoverageGap(gap(), at: contentTime)
                for retained in preserved { try await store.recordCoverageGap(retained, at: contentTime) }
            }
            let adapter = try CodexAdapter(profileID: "test", agentVersion: "0.162.1", history: history,
                authorityLookup: { try await store.authority(for: $0) }, authorityRecorder: { choice in
                    let permit = try #require(await store.processingPermit())
                    try await store.selectAuthority(choice, permit: permit)
                })
            let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
                detector: detector, detectorVersion: "fake-sleep-detector")
            let permit = try #require(await store.processingPermit())
            _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, workContext: context)
            #expect(try await pipeline.processNext(at: now) == .processed)
            #expect(try await store.queueStatistics().count == 0)
            let omissions = try await store.coverageOmissions()
            #expect(omissions.contains { $0.gap.recovery?.itemID == "sleep-original" && $0.gap.contentType == nil } == currentSameIDGap)
            for retained in preserved {
                #expect(omissions.contains { $0.gap.recovery?.itemID == retained.recovery?.itemID
                    && $0.gap.reason == retained.reason && $0.gap.contentType == retained.contentType })
            }
            let snapshot = await store.snapshot()
            #expect(snapshot.records.isEmpty && snapshot.occurrences.isEmpty && snapshot.analysisReceipts.isEmpty)
            #expect(snapshot.sourceKinds.isEmpty && snapshot.alertDecisions.isEmpty)
            try await store.close()
        }
        #expect(await detector.calls == 0)
    }
}
