import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private let hookPipelineProfile = "synthetic-hook-profile"
private let hookPipelineSession = "synthetic-hook-session"
private let hookPipelineValue = "SPILLCHECK_FAKE_HOOK_PIPELINE_VALUE_83"
private let hookPipelineDetectorVersion = "synthetic-hook-detector-1"

private func hookPipelineTime() -> Date {
    Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
}

private func hookPipelineDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-hook-pipeline-\(UUID())")
}

private func hookPipelineIdentity(_ session: String = hookPipelineSession) throws -> SessionIdentity {
    try .init(provider: .codex, profileID: hookPipelineProfile, sessionID: session)
}

private func enrollHookPipeline(_ store: ProtectedStore, session: String = hookPipelineSession,
                                authority: String = CodexHookContentAdapter.authorityID) async throws {
    let permit = try #require(await store.processingPermit())
    try await store.selectAuthority(.init(session: hookPipelineIdentity(session), adapterVersion: "1",
        authorityID: authority), permit: permit)
}

private func hookPipelinePacket(_ event: String = "UserPromptSubmit", turn: String = "turn-1",
                                session: String = hookPipelineSession, text: String = hookPipelineValue,
                                extra: [String: Any] = [:], omitting: Set<String> = []) throws -> CapturePacket {
    var payload: [String: Any] = ["hook_event_name": event, "session_id": session, "turn_id": turn,
        "cwd": "/synthetic/project", "transcript_path": NSNull()]
    if event == "UserPromptSubmit" { payload["prompt"] = text }
    if event == "Stop" { payload["last_assistant_message"] = text; payload["stop_hook_active"] = false }
    payload.merge(extra) { _, replacement in replacement }
    for field in omitting { payload.removeValue(forKey: field) }
    return try .init(metadata: .init(agent: .codex, interface: .desktopCode, profileID: hookPipelineProfile),
        eventJSON: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
}

private func hookPipelineAdapter(_ store: ProtectedStore, maximumBytes: Int = 1024 * 1024,
                                 failBinding: Bool = false) throws -> CodexHookContentAdapter {
    try .init(profileID: hookPipelineProfile, interface: .desktopCode, maximumBytes: maximumBytes,
        authorityLookup: { try await store.authority(for: $0) }, bind: { source, revision, observedAt in
            if failBinding { throw StorageError.injectedFailure }
            let permit = try #require(await store.processingPermit())
            return try await store.bindCodexHookContent(source: source, revision: revision,
                observedAt: observedAt, permit: permit)
        })
}

@discardableResult
private func enqueueHookPipeline(_ packet: CapturePacket, store: ProtectedStore, at date: Date,
                                 scope: LiveCaptureScope? = nil) async throws -> UUID {
    let permit = try #require(await store.processingPermit()), id = UUID()
    #expect(try await store.enqueue(packet.body, id: id, capturedAt: date, permit: permit,
        at: date, scope: scope, workContext: hookPipelineContext(packet)) == .inserted(id))
    return id
}

private func hookPipelineContext(_ packet: CapturePacket) throws -> CollectionWorkContext {
    try CollectionCaptureRoute(scope: .init(provider: .codex, profileID: hookPipelineProfile,
        interface: .desktopCode, path: .hook)).context(for: packet, trigger: .helperDelivery)
}

private func hookPipelineRouter(_ hooks: CodexHookContentAdapter,
                                native: HookPipelineNativeSpy? = nil) throws -> CollectionRouter {
    var routes = [CollectionRoute(provider: .codex, profileID: hookPipelineProfile,
        interface: .desktopCode, normalizer: hooks)]
    if let native {
        routes.append(.init(provider: .codex, profileID: hookPipelineProfile,
            interface: .standaloneCLI, normalizer: native))
    }
    return try .init(routes: routes)
}

private actor HookPipelineDetector: SecretDetector {
    private(set) var observed: [SourceRecordMetadata] = []

    func scan(_ source: SourceRecord) throws -> DetectorOutput {
        observed.append(source.metadata)
        let value = Data(hookPipelineValue.utf8)
        var findings: [DetectorFinding] = []
        for segment in source.segments {
            if let range = segment.utf8.range(of: value) {
                let location = try CanonicalLocation(segmentID: segment.id,
                    range: .init(range.lowerBound, range.upperBound))
                findings.append(try .init(extraction: .init(valueUTF8: value, location: location, in: source),
                    evidence: [evidence()]))
            }
        }
        return .init(detectorVersion: hookPipelineDetectorVersion, findings: findings, unlocated: [])
    }
}

private actor HookPipelineNativeSpy: CaptureNormalizer {
    private(set) var calls = 0
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) -> CollectionBatch {
        calls += 1
        return .init(sources: [])
    }
}

private func hookPipeline(store: ProtectedStore, crypto: BackgroundCryptography,
                          detector: HookPipelineDetector, liveSince: Date) throws -> DetectionPipeline {
    try .init(store: store, cryptography: crypto, normalizer: hookPipelineRouter(hookPipelineAdapter(store)),
        detector: detector, detectorVersion: hookPipelineDetectorVersion, liveSince: liveSince)
}

private func hookPipelineFilesAreProtected(_ directory: URL) throws {
    let files = try #require(FileManager.default.enumerator(at: directory,
        includingPropertiesForKeys: [.isRegularFileKey]))
    for case let file as URL in files {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        let bytes = try Data(contentsOf: file)
        for text in [hookPipelineValue, hookPipelineSession, hookPipelineProfile] {
            #expect(bytes.range(of: Data(text.utf8)) == nil)
            #expect(bytes.range(of: Data(Data(text.utf8).base64EncodedString().utf8)) == nil)
        }
    }
}

@Suite("Codex hook content through encrypted admission and detection", .timeLimit(.minutes(1)))
struct CodexHookContentPipelineTests {
    @Test func toolResultsKeepDistinctCallIdentityAndReplayAcrossRestart() async throws {
        let directory = hookPipelineDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting(), first = hookPipelineTime()
        let scope = try LiveCaptureScope(startedAt: first.addingTimeInterval(-1))
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        try await enrollHookPipeline(store)
        let success = try hookPipelinePacket("PostToolUse", extra: ["tool_use_id": "call-success", "tool_name": "Bash",
            "tool_input": ["command": "not retained as result"],
            "tool_response": ["stdout": hookPipelineValue, "stderr": "", "exit_code": 0]])
        let failure = try hookPipelinePacket("PostToolUse", extra: ["tool_use_id": "call-failure", "tool_name": "Bash",
            "tool_response": ["stdout": "", "stderr": hookPipelineValue, "exit_code": 7]])
        let detector = HookPipelineDetector()
        let pipeline = try hookPipeline(store: store, crypto: crypto, detector: detector, liveSince: first)
        for packet in [success, failure] {
            try await enqueueHookPipeline(packet, store: store, at: first, scope: scope)
            #expect(try await pipeline.processNext(at: first) == .processed)
        }
        let before = await store.snapshot(), observed = await detector.observed
        #expect(observed.map(\.contentType) == [.toolOutput, .toolError])
        #expect(Set(observed.map(\.identity)).count == 2)
        #expect(observed.allSatisfy { $0.timeBasis == .firstObservation && $0.contentTime == first })
        #expect(before.records.count == 1 && before.occurrences.count == 2 && before.analysisReceipts.count == 2)
        try hookPipelineFilesAreProtected(directory)
        try await store.close()

        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let replayDetector = HookPipelineDetector(), later = first.addingTimeInterval(30)
        let replayPipeline = try hookPipeline(store: reopened, crypto: crypto, detector: replayDetector, liveSince: later)
        for packet in [failure, success, failure] {
            try await enqueueHookPipeline(packet, store: reopened, at: later, scope: scope)
            #expect(try await replayPipeline.processNext(at: later) == .processed)
        }
        let after = await reopened.snapshot()
        #expect(await replayDetector.observed.isEmpty)
        #expect(after.occurrences == before.occurrences && after.analysisReceipts.count == 2)
        #expect(try await reopened.queueStatistics().count == 0)
        let reads = try await reopened.coverageReport(endingAt: later).successfulReads.items
        #expect(!reads.isEmpty && reads.allSatisfy { $0.scope.path == .hook })
        try hookPipelineFilesAreProtected(directory)
        try await reopened.close()
    }

    @Test func lostAcknowledgementAndNewDeliveryIDReplayOnlyOneAppearance() async throws {
        let directory = hookPipelineDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting(), firstTime = hookPipelineTime()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto, failureInjector: { point in
            // The receiver cannot ACK this call, although its encrypted insert committed.
            if point == .afterEnqueueCommit { throw StorageError.injectedFailure }
        })
        try await enrollHookPipeline(store)
        let packet = try hookPipelinePacket(), firstID = UUID()
        let permit = try #require(await store.processingPermit())
        let scope = try LiveCaptureScope(startedAt: firstTime.addingTimeInterval(-1))
        await #expect(throws: StorageError.injectedFailure) {
            try await store.enqueue(packet.body, id: firstID, capturedAt: firstTime,
                permit: permit, at: firstTime, scope: scope, workContext: hookPipelineContext(packet))
        }
        #expect(try await store.queueStatistics().count == 1)
        try hookPipelineFilesAreProtected(directory)
        try await store.close()

        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let retryTime = firstTime.addingTimeInterval(10)
        let retryID = try await enqueueHookPipeline(packet, store: reopened, at: retryTime, scope: scope)
        #expect(retryID != firstID)
        #expect(try await reopened.queueStatistics().count == 2)
        let detector = HookPipelineDetector()
        let pipeline = try hookPipeline(store: reopened, crypto: crypto, detector: detector, liveSince: retryTime)
        #expect(try await pipeline.processNext(at: retryTime) == .processed)
        #expect(try await pipeline.processNext(at: retryTime) == .processed)
        #expect(try await pipeline.processNext(at: retryTime) == .idle)
        let snapshot = await reopened.snapshot(), observed = await detector.observed
        #expect(observed.count == 1)
        #expect(snapshot.records.count == 1 && snapshot.occurrences.count == 1)
        #expect(snapshot.analysisReceipts.count == 1 && snapshot.alertDecisions.count == 1)
        #expect(try await reopened.queueStatistics().count == 0)
        let occurrence = try #require(snapshot.occurrences.values.first)
        #expect(occurrence.source.contentTime == firstTime)
        #expect(occurrence.source.observedAt == firstTime)
        #expect(occurrence.source.timeBasis == .firstObservation)
        #expect(occurrence.source.protectedMetadata != nil)
        #expect(occurrence.source.origin.provenance == .live)
        #expect(occurrence.source.locator == .unavailable)
        #expect(occurrence.source.identity.itemID.hasPrefix(CodexHookContentAdapter.itemPrefix))
        #expect(occurrence.source.origin.adapterID == "codex-hook-content")
        let report = try await reopened.coverageReport(endingAt: retryTime)
        #expect(report.successfulReads.totalCount == 1)
        #expect(report.successfulReads.items.allSatisfy { $0.scope.path == .hook && $0.operation != .historicalRead })
        #expect(report.work.items.count == 2)
        #expect(report.work.items.allSatisfy { $0.context.scope.path == .hook && $0.context.retry == nil })
        try hookPipelineFilesAreProtected(directory)
        try await reopened.close()
        let verified = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let persisted = try #require(await verified.snapshot().occurrences.values.first)
        #expect(persisted.source.timeBasis == .firstObservation)
        #expect(persisted.source.contentTime == firstTime && persisted.source.observedAt == firstTime)
        try await verified.close()
    }

    @Test func restartAfterBindingBeforeScanningRetainsQueueAndOriginalObservation() async throws {
        let directory = hookPipelineDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting(), firstTime = hookPipelineTime()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        try await enrollHookPipeline(store)
        let packet = try hookPipelinePacket("Stop")
        let scope = try LiveCaptureScope(startedAt: firstTime.addingTimeInterval(-1))
        try await enqueueHookPipeline(packet, store: store, at: firstTime, scope: scope)
        let permit = try #require(await store.processingPermit())
        let claimed = try #require(try await store.nextPending(at: firstTime, permit: permit))
        let opened = try await store.openCapturedWork(claimed)
        let before = try await hookPipelineAdapter(store).normalize(CapturePacket(body: opened.body),
            capturedAt: claimed.capturedAt, cryptography: crypto)
        #expect(before.sources.count == 1)
        #expect(await store.snapshot().analysisReceipts.isEmpty)
        #expect(try await store.queueStatistics().count == 1)
        try await store.close()

        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let restartTime = firstTime.addingTimeInterval(181), detector = HookPipelineDetector()
        let pipeline = try hookPipeline(store: reopened, crypto: crypto, detector: detector, liveSince: restartTime)
        #expect(try await pipeline.processNext(at: restartTime) == .processed)
        let source = try #require(await detector.observed.first)
        #expect(source.contentTime == firstTime && source.observedAt == firstTime)
        #expect(source.timeBasis == .firstObservation && source.origin.provenance == .live)
        #expect(source.identity == before.sources.first?.record.metadata.identity)
        #expect(await reopened.snapshot().analysisReceipts.count == 1)
        #expect(await reopened.snapshot().occurrences.count == 1)
        #expect(try await reopened.queueStatistics().count == 0)
        try hookPipelineFilesAreProtected(directory)
        try await reopened.close()
    }

    @Test func changedSlotCannotRescanReplaceCoordinatesOrClearItsRequiredGap() async throws {
        let directory = hookPipelineDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting(), now = hookPipelineTime()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        try await enrollHookPipeline(store)
        let detector = HookPipelineDetector()
        let pipeline = try hookPipeline(store: store, crypto: crypto, detector: detector, liveSince: now)
        let original = try hookPipelinePacket()
        let scope = try LiveCaptureScope(startedAt: now.addingTimeInterval(-1))
        try await enqueueHookPipeline(original, store: store, at: now, scope: scope)
        #expect(try await pipeline.processNext(at: now) == .processed)
        let first = await store.snapshot()
        let conflicting = try hookPipelinePacket(text: "shifted text " + hookPipelineValue)
        try await enqueueHookPipeline(conflicting, store: store, at: now.addingTimeInterval(1), scope: scope)
        #expect(try await pipeline.processNext(at: now.addingTimeInterval(1)) == .processed)
        #expect(await detector.observed.count == 1)
        let after = await store.snapshot()
        #expect(after.occurrences == first.occurrences)
        #expect(after.analysisReceipts == first.analysisReceipts)
        #expect(after.alertDecisions == first.alertDecisions)
        let gap = try #require(try await store.coverageGaps().first { $0.diagnosticCode == .hookIdentityConflict })
        #expect(gap.requiresAnalysis && gap.isRequiredFormatFailure == true)
        #expect(gap.reason == .sourceChanged && gap.scope?.path == .hook)
        #expect(gap.recovery?.locator == .unavailable)
        // A subsequent byte-identical replay cannot pretend to repair the ambiguous event.
        try await enqueueHookPipeline(original, store: store, at: now.addingTimeInterval(2), scope: scope)
        #expect(try await pipeline.processNext(at: now.addingTimeInterval(2)) == .processed)
        #expect(await detector.observed.count == 1)
        #expect(try await store.coverageGaps().contains { $0.diagnosticCode == .hookIdentityConflict && $0.requiresAnalysis })
        try hookPipelineFilesAreProtected(directory)
        try await store.close()
    }

    @Test func outOfOrderFinalAndPromptRemainSeparateFromSameTextInAnotherTurn() async throws {
        let directory = hookPipelineDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting(), now = hookPipelineTime()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        try await enrollHookPipeline(store)
        let detector = HookPipelineDetector()
        let pipeline = try hookPipeline(store: store, crypto: crypto, detector: detector, liveSince: now)
        let packets = [try hookPipelinePacket("Stop"), try hookPipelinePacket(),
                       try hookPipelinePacket(turn: "turn-2")]
        let scope = try LiveCaptureScope(startedAt: now.addingTimeInterval(-1))
        for (index, packet) in packets.enumerated() {
            let time = now.addingTimeInterval(Double(index))
            try await enqueueHookPipeline(packet, store: store, at: time, scope: scope)
            #expect(try await pipeline.processNext(at: time) == .processed)
        }
        let snapshot = await store.snapshot(), observed = await detector.observed
        #expect(snapshot.records.count == 1 && snapshot.occurrences.count == 3)
        #expect(snapshot.analysisReceipts.count == 3 && snapshot.alertDecisions.count == 1)
        #expect(Set(observed.map(\.identity)).count == 3)
        #expect(observed.map(\.contentType) == [.finalResponse, .userPrompt, .userPrompt])
        #expect(observed.map(\.contentTime) == (0..<3).map { now.addingTimeInterval(Double($0)) })
        #expect(observed.allSatisfy { $0.timeBasis == .firstObservation })
        #expect(try await store.coverageGaps().isEmpty)
        try await store.close()
    }

    @Test func explicitHookRouteRequiresEnrollmentAndNeverFallsBackAfterFailure() async throws {
        let directory = hookPipelineDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting(), now = hookPipelineTime()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let native = HookPipelineNativeSpy(), hooks = try hookPipelineAdapter(store)
        let router = try hookPipelineRouter(hooks, native: native)
        let unknown = try hookPipelinePacket(session: "unknown-without-transcript")
        let refused = try await router.normalize(unknown, capturedAt: now, cryptography: crypto)
        #expect(await native.calls == 0)
        #expect(try await store.authority(for: hookPipelineIdentity("unknown-without-transcript")) == nil)
        #expect(refused.sources.isEmpty && refused.coverageGaps.first?.reason == .unresolvedCorrelation)

        try await enrollHookPipeline(store, session: "native", authority: CodexCollectionAuthority.publicNativeItems.rawValue)
        let nativeOwned = try await router.normalize(hookPipelinePacket(session: "native"), capturedAt: now, cryptography: crypto)
        #expect(nativeOwned.sources.isEmpty && nativeOwned.coverageGaps.first?.reason == .unresolvedCorrelation)
        #expect(await native.calls == 0)
        await #expect(throws: StorageError.invalidPayload) { try await enrollHookPipeline(store, session: "native") }
        try await enrollHookPipeline(store)
        let missingContent = try hookPipelinePacket(omitting: ["prompt"])
        let failed = try await router.normalize(missingContent, capturedAt: now, cryptography: crypto)
        #expect(failed.sources.isEmpty && failed.coverageGaps.first?.requiresAnalysis == true)
        #expect(await native.calls == 0)
        let broken = try hookPipelineRouter(hookPipelineAdapter(store, failBinding: true), native: native)
        await #expect(throws: StorageError.injectedFailure) {
            try await broken.normalize(hookPipelinePacket(), capturedAt: now, cryptography: crypto)
        }
        #expect(await native.calls == 0)
        try await store.close()
    }

    @Test func interruptContinuationAndUnsupportedContentStayUnanalyzedWithExplicitGaps() async throws {
        let directory = hookPipelineDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting(), now = hookPipelineTime()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        try await enrollHookPipeline(store)
        let detector = HookPipelineDetector()
        let pipeline = try hookPipeline(store: store, crypto: crypto, detector: detector, liveSince: now)
        let cases: [(CapturePacket, CoverageDiagnosticCode)] = [
            (try hookPipelinePacket("Interrupt"), .hookInterrupted),
            (try hookPipelinePacket("Stop", extra: ["stop_hook_active": true]), .hookContentUnavailable),
            (try hookPipelinePacket("PreToolUse", extra: ["tool_input": hookPipelineValue]), .hookContentUnavailable),
            (try hookPipelinePacket("Stop", extra: ["agent_id": "child"]), .unresolvedIdentity),
            (try hookPipelinePacket(omitting: ["turn_id"]), .unresolvedIdentity)
        ]
        for (packet, diagnostic) in cases {
            let batch = try await hookPipelineAdapter(store).normalize(packet, capturedAt: now, cryptography: crypto)
            #expect(batch.sources.isEmpty && !batch.observedRead)
            #expect(batch.coverageGaps.contains { $0.diagnosticCode == diagnostic && $0.requiresAnalysis })
            try await enqueueHookPipeline(packet, store: store, at: now)
            #expect(try await pipeline.processNext(at: now) == .processed)
        }
        #expect(await detector.observed.isEmpty)
        #expect(await store.snapshot().analysisReceipts.isEmpty)
        #expect(try await store.queueStatistics().count == 0)
        let gaps = try await store.coverageGaps()
        #expect(gaps.contains { $0.diagnosticCode == .hookInterrupted && $0.requiresAnalysis })
        #expect(gaps.contains { $0.diagnosticCode == .hookContentUnavailable && $0.requiresAnalysis })
        let capabilities = try hookPipelineAdapter(store).capabilities()
        #expect(capabilities.allSatisfy { !$0.canReadHistoricalContent && $0.path == .hook })
        #expect(capabilities.filter(\.canObserveActiveSession).map(\.contentType).sorted { $0.rawValue < $1.rawValue }
            == [.finalResponse, .toolError, .toolOutput, .userPrompt])
        #expect(capabilities.allSatisfy { $0.validation != .validated })
        #expect(CollectionCompatibility.recordedEvidence(provider: .codex, interface: .desktopCode,
            producerVersion: "0.162.1", readerVersion: "0.162.1") == .unverified)
        try await store.close()
    }

    @Test func payloadAndIdentityBoundsRejectBeforeBindingAndEmptyTextRemainsValid() async throws {
        let directory = hookPipelineDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting(), now = hookPipelineTime()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto,
            limits: .init(maxHookContentSlots: 1))
        try await enrollHookPipeline(store)
        let limited = try hookPipelineAdapter(store, maximumBytes: 128)
        let oversized = try await limited.normalize(hookPipelinePacket(), capturedAt: now, cryptography: crypto)
        #expect(oversized.sources.isEmpty && oversized.coverageGaps.first?.reason == .budgetExhausted)
        let hooks = try hookPipelineAdapter(store)
        for turn in ["", String(repeating: "x", count: 257), "bad/turn", "bad\u{0}turn"] {
            let batch = try await hooks.normalize(hookPipelinePacket(turn: turn), capturedAt: now, cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.coverageGaps.first?.requiresAnalysis == true)
        }
        for identifier in ["", String(repeating: "x", count: 257), "bad/identifier", "bad\u{0}identifier"] {
            for packet in [try hookPipelinePacket(session: identifier), try hookPipelinePacket(identifier)] {
                let batch = try await hooks.normalize(packet, capturedAt: now, cryptography: crypto)
                #expect(batch.sources.isEmpty && !batch.observedRead)
                #expect(batch.coverageGaps.first?.reason == .malformedSource)
                #expect(batch.coverageGaps.first?.diagnosticCode == .invalidFieldType)
                #expect(batch.coverageGaps.first?.requiresAnalysis == true)
            }
        }
        let missingFields: [(CapturePacket, CoverageDiagnosticCode)] = [
            (try hookPipelinePacket(omitting: ["session_id"]), .invalidFieldType),
            (try hookPipelinePacket(extra: ["session_id": 42]), .invalidFieldType),
            (try hookPipelinePacket(omitting: ["hook_event_name"]), .invalidFieldType),
            (try hookPipelinePacket(extra: ["hook_event_name": ["Stop"]]), .invalidFieldType),
            (try hookPipelinePacket("Stop", omitting: ["last_assistant_message"]), .missingPayload),
            (try hookPipelinePacket("Stop", extra: ["last_assistant_message": NSNull()]), .missingPayload),
            (try hookPipelinePacket("Stop", omitting: ["stop_hook_active"]), .hookContentUnavailable),
            (try hookPipelinePacket("Stop", extra: ["stop_hook_active": "false"]), .hookContentUnavailable)
        ]
        for (packet, diagnostic) in missingFields {
            let batch = try await hooks.normalize(packet, capturedAt: now, cryptography: crypto)
            #expect(batch.sources.isEmpty && !batch.observedRead)
            #expect(batch.coverageGaps.first?.diagnosticCode == diagnostic)
            #expect(batch.coverageGaps.first?.requiresAnalysis == true)
        }
        let malformed = try CapturePacket(metadata: .init(agent: .codex, interface: .desktopCode,
            profileID: hookPipelineProfile), eventJSON: Data("{invalid".utf8))
        let invalid = try await hooks.normalize(malformed, capturedAt: now, cryptography: crypto)
        #expect(invalid.sources.isEmpty && invalid.coverageGaps.first?.reason == .malformedSource)
        let empty = try await hooks.normalize(hookPipelinePacket(text: ""), capturedAt: now, cryptography: crypto)
        let source = try #require(empty.sources.first?.record)
        #expect(source.segments.count == 1 && source.segments.first?.utf8.isEmpty == true)
        #expect(source.metadata.timeBasis == .firstObservation)
        // The rejected events did not take this slot before the empty event bound it.
        let conflict = try await hooks.normalize(hookPipelinePacket(), capturedAt: now, cryptography: crypto)
        #expect(conflict.sources.isEmpty && conflict.coverageGaps.first?.diagnosticCode == .hookIdentityConflict)
        let full = try await hooks.normalize(hookPipelinePacket(turn: "another-valid-turn"),
            capturedAt: now, cryptography: crypto)
        #expect(full.sources.isEmpty && !full.observedRead)
        #expect(full.coverageGaps.first?.reason == .budgetExhausted)
        #expect(full.coverageGaps.first?.diagnosticCode == .hookStorageLimit)
        #expect(full.coverageGaps.first?.isRequiredFormatFailure == true)
        #expect(full.coverageGaps.first?.requiresAnalysis == true)
        let replay = try await hooks.normalize(hookPipelinePacket(text: ""),
            capturedAt: now.addingTimeInterval(30), cryptography: crypto)
        #expect(replay.coverageGaps.isEmpty && replay.observedRead)
        let repeated = try #require(replay.sources.first?.record)
        #expect(repeated.metadata == source.metadata && repeated.revision == source.revision)
        try await store.close()
    }

    @Test func oldReplayCannotBecomeNewContentAfterAnalysisReceiptsAreCompacted() async throws {
        let directory = hookPipelineDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting(), firstTime = hookPipelineTime()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        try await enrollHookPipeline(store)
        let detector = HookPipelineDetector(), packet = try hookPipelinePacket()
        let pipeline = try hookPipeline(store: store, crypto: crypto, detector: detector, liveSince: firstTime)
        let scope = try LiveCaptureScope(startedAt: firstTime.addingTimeInterval(-1))
        try await enqueueHookPipeline(packet, store: store, at: firstTime, scope: scope)
        #expect(try await pipeline.processNext(at: firstTime) == .processed)
        #expect(await store.snapshot().analysisReceipts.count == 1)
        let later = firstTime.addingTimeInterval(HistoricalAuditContext.receiptHorizon + 1)
        #expect(try await store.compactProcessedSources(at: later))
        #expect(await store.snapshot().analysisReceipts.isEmpty)
        try await store.close()

        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let nextDetector = HookPipelineDetector()
        let nextPipeline = try hookPipeline(store: reopened, crypto: crypto, detector: nextDetector, liveSince: later)
        try await enqueueHookPipeline(packet, store: reopened, at: later)
        #expect(try await nextPipeline.processNext(at: later) == .processed)
        #expect(await nextDetector.observed.isEmpty)
        let snapshot = await reopened.snapshot()
        #expect(snapshot.analysisReceipts.isEmpty)
        #expect(snapshot.occurrences.count == 1)
        #expect(snapshot.occurrences.values.first?.source.contentTime == firstTime)
        #expect(snapshot.occurrences.values.first?.source.timeBasis == .firstObservation)
        #expect(try await reopened.queueStatistics().count == 0)
        try await reopened.close()
    }

    @Test func observationTimeMetadataRoundTripsAndOlderMetadataDecodesWithoutInventingBasis() async throws {
        let directory = hookPipelineDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        try await enrollHookPipeline(store)
        let batch = try await hookPipelineAdapter(store).normalize(hookPipelinePacket(), capturedAt: hookPipelineTime(), cryptography: crypto)
        let metadata = try #require(batch.sources.first?.record.metadata)
        let encoded = try JSONEncoder().encode(metadata)
        #expect(try JSONDecoder().decode(SourceRecordMetadata.self, from: encoded) == metadata)
        var oldFields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        oldFields.removeValue(forKey: "timeBasis")
        let previousEncoding = try JSONSerialization.data(withJSONObject: oldFields)
        let old = try JSONDecoder().decode(SourceRecordMetadata.self, from: previousEncoding)
        #expect(old.timeBasis == nil)
        #expect(old.identity == metadata.identity && old.contentTime == metadata.contentTime)
        try await store.close()
    }
}
