import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor EmittedGapSink {
    private var gaps: [CoverageGap] = []
    func receive(_ gap: CoverageGap) { gaps.append(gap) }
    func values() -> [CoverageGap] { gaps }
}
private enum EmissionFailure: Error { case unavailable }
private actor EmissionCheckpoints {
    private var values: [UUID: SourceCheckpoint] = [:]
    func save(_ batch: CollectionBatch) { for checkpoint in batch.checkpoints { values[checkpoint.sourceDocumentID] = checkpoint } }
    func get(_ id: UUID) -> SourceCheckpoint? { values[id] }
}
private func emissionDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-emission-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func emissionRow(text: String, id: String = "row") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["type": "user", "uuid": id, "sessionId": "selected",
        "timestamp": "2026-10-09T12:00:00Z", "message": ["role": "user", "content": text]]) + Data([10])
}
private let emissionTime = Date(timeIntervalSince1970: 1_791_676_800)

@Suite("Collection failure scope and original-source retry")
struct CollectionEmissionTests {
    @Test func malformedRequestsKeepKnownRouteAndObservationButUnknownContentPeriod() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let claude = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [])
        let codex = try codexTestAdapter(selectedAuthority: .nativeRolloutTranscript)
        for provider in [AgentProvider.claudeCode, .codex] {
            let packet = try CapturePacket(metadata: .init(agent: provider, interface: .t3, profileID: "test"),
                eventJSON: Data("{}".utf8))
            let batch = try await (provider == .claudeCode
                ? claude.normalize(packet, capturedAt: emissionTime, cryptography: crypto)
                : codex.normalize(packet, capturedAt: emissionTime, cryptography: crypto))
            let gap = try #require(batch.coverageGaps.first)
            #expect(gap.scope == .init(provider: provider, profileID: "test", interface: .t3, path: .versionedTranscript))
            #expect(gap.observedAt == emissionTime && gap.operation == .hookDelivery)
            #expect(gap.interval == nil && gap.recovery?.contentTime == nil && gap.diagnosticCode == .malformedRecord)
        }
    }

    @Test func missingAndFailedMonitorSourcesRetainEachExactRoute() async throws {
        let root = try emissionDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing.jsonl"), present = root.appendingPathComponent("present.jsonl")
        try emissionRow(text: "fake").write(to: present)
        let sink = EmittedGapSink()
        let claude = try ClaudeActiveTranscriptMonitor(profileID: "test", sources: [
            .init(sessionID: "selected", transcriptURL: missing, interface: .standaloneCLI),
            .init(sessionID: "selected", transcriptURL: present, interface: .t3)],
            enqueue: { _, _ in throw EmissionFailure.unavailable }, onGap: { await sink.receive($0) })
        await #expect(throws: EmissionFailure.self) { try await claude.pollOnce(at: emissionTime) }
        let codexTranscript = try CodexActiveSource(threadID: "selected", interface: .t3,
            authority: .nativeRolloutTranscript, transcriptURL: missing)
        let codex = try CodexActiveHistoryMonitor(profileID: "test", sources: [
            codexTranscript,
            .init(threadID: "selected-public", interface: .standaloneCLI, authority: .publicNativeItems)],
            enqueue: { _, _ in throw EmissionFailure.unavailable }, onGap: { await sink.receive($0) })
        try await codex.addSource(.init(threadID: "selected-public", interface: .standaloneCLI, authority: .publicNativeItems), at: emissionTime)
        await #expect(throws: EmissionFailure.self) { try await codex.pollOnce(at: emissionTime) }
        let gaps = await sink.values()
        #expect(gaps.count == 4)
        #expect(gaps.map(\.reason) == [.sourceUnavailable, .deliveryUncertain, .sourceUnavailable, .deliveryUncertain])
        #expect(gaps.map { $0.scope?.path } == [.versionedTranscript, .versionedTranscript, .versionedTranscript, .publicHistory])
        #expect(gaps.map { $0.scope?.interface } == [.standaloneCLI, .t3, .t3, .standaloneCLI])
        #expect(gaps.allSatisfy { $0.scope?.profileID == "test" && $0.operation == .liveRead && $0.observedAt == emissionTime && $0.interval == nil })
        // Codex normalizes its selected URL at admission, including macOS /var aliases.
        // Recovery must retain that exact admitted URL rather than the caller's spelling.
        #expect(gaps.map { $0.recovery?.sourceURL } == [missing, present, codexTranscript.transcriptURL, nil])
        #expect(gaps.allSatisfy { $0.recovery?.session != nil })
    }

    @Test func changedIncrementalSourceKeepsFailureTimeSeparateFromOriginalRows() async throws {
        let root = try emissionDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("selected.jsonl")
        try emissionRow(text: "aaaa").write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [root])
        let initial = try await adapter.readIncremental(path: file.path, interface: .t3, observedAt: emissionTime, cryptography: crypto)
        try emissionRow(text: "bbbb").write(to: file)
        let checkpoint: SourceCheckpoint = try #require(initial.batch.checkpoints.first)
        let after = try await adapter.readIncremental(path: file.path, interface: .t3,
            checkpoint: checkpoint, observedAt: emissionTime.addingTimeInterval(30), cryptography: crypto)
        let gap = try #require(after.batch.coverageGaps.first { $0.reason == .sourceChanged })
        #expect(gap.scope?.path == .versionedTranscript && gap.scope?.interface == .t3 && gap.operation == .liveRead)
        #expect(gap.observedAt == emissionTime.addingTimeInterval(30) && gap.interval == nil)
        #expect(gap.recovery?.contentTime == nil && gap.recovery?.sourceURL == file && gap.diagnosticCode == .changedSource)
        #expect(after.batch.sources.first?.record.metadata.contentTime != gap.observedAt)
    }

    @Test func historyDiscoveryFailureRetainsRouteWithoutInventingContentPeriod() async throws {
        let root = try emissionDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing")
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [missing])
        let audit = try HistoricalAuditContext(reason: .resume, endingAt: emissionTime)
        let packet = try await adapter.initialHistoricalCapture(audit: audit)
        let batch = try await adapter.normalize(packet, capturedAt: emissionTime, cryptography: .ephemeralForTesting())
        let gap = try #require(batch.coverageGaps.first)
        #expect(gap.reason == .sourceUnavailable && gap.scope?.profileID == "test")
        #expect(gap.scope?.path == .versionedTranscript && gap.operation == .historicalRead)
        #expect(gap.observedAt == emissionTime && gap.interval == nil && batch.historicalProgress?.hasUnreadContent == true)
    }

    @Test func exactClaudeRetryDoesNotEnumerateReadableSibling() async throws {
        let root = try emissionDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected.jsonl")
        try emissionRow(text: "selected").write(to: selected)
        try emissionRow(text: "must not read", id: "sibling").write(to: root.appendingPathComponent("sibling.jsonl"))
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [root])
        let retry = CoverageSourceRetryDescriptor(scope: .init(provider: .claudeCode, profileID: "test", interface: .t3, path: .versionedTranscript),
            session: try .init(provider: .claudeCode, profileID: "test", sessionID: "selected"), sourceURL: selected)
        let packet = try await adapter.initialHistoricalCapture(audit: .init(reason: .resume, endingAt: emissionTime), source: retry)
        let batch = try await adapter.normalize(packet, capturedAt: emissionTime, cryptography: .ephemeralForTesting())
        #expect(batch.sources.map(\.record.metadata.identity.itemID) == ["prompt:row:block:0"])
        #expect(batch.continuation == nil && batch.historicalProgress?.hasUnreadContent == false)
        let foreign = CoverageSourceRetryDescriptor(scope: retry.scope, sourceURL: root.deletingLastPathComponent().appendingPathComponent("foreign.jsonl"))
        await #expect(throws: ClaudeCollectionError.unsafeTranscriptPath) {
            try await adapter.initialHistoricalCapture(audit: .init(reason: .resume, endingAt: emissionTime), source: foreign)
        }
    }

    @Test func exactCodexRetryDoesNotListThreadsOrFollowChildren() async throws {
        let history = CodexTestHistory(), adapter = try codexTestAdapter(history: history)
        await history.configure("parent", thread: try codexThread(), pages: [.init(data: [
            try codexItem("selected", timestamp: emissionTime.addingTimeInterval(-60).timeIntervalSince1970 * 1000),
            try codexItem("link", type: "collabAgentToolCall", timestamp: emissionTime.addingTimeInterval(-60).timeIntervalSince1970 * 1000,
                body: ["agentThreadId": "child", "status": "completed"])
        ])])
        let retry = CoverageSourceRetryDescriptor(scope: adapter.collectionScope,
            session: try .init(provider: .codex, profileID: "test", sessionID: "parent"))
        let packet = try await adapter.initialHistoricalCapture(audit: .init(reason: .resume, endingAt: emissionTime), source: retry)
        let batch = try await adapter.normalize(packet, capturedAt: emissionTime, cryptography: .ephemeralForTesting())
        #expect(batch.continuation == nil)
        #expect(batch.sources.map(\.record.metadata.identity.itemID) == ["selected"])
        let calls = await history.recordedCalls()
        #expect(calls.contains("read:parent") && !calls.contains("read:child") && !calls.contains { $0.hasPrefix("list:") })
        let wrongRoute = CoverageSourceRetryDescriptor(scope: .init(provider: .codex, profileID: "test", interface: .t3, path: .versionedTranscript), session: retry.session)
        await #expect(throws: CodexCollectionError.invalidConfiguration) {
            try await adapter.initialHistoricalCapture(audit: .init(reason: .resume, endingAt: emissionTime), source: wrongRoute)
        }
    }

    @Test func explicitSourceRetriesReparseCompletedCheckpointsWithStableNativeIdentities() async throws {
        let root = try emissionDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected.jsonl")
        try emissionRow(text: "selected").write(to: selected)
        let checkpoints = EmissionCheckpoints(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let claude = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [root],
            checkpointLookup: { await checkpoints.get($0) })
        let audit = try HistoricalAuditContext(reason: .resume, endingAt: emissionTime)
        let first = try await claude.normalize(claude.initialHistoricalCapture(audit: audit), capturedAt: emissionTime, cryptography: crypto)
        await checkpoints.save(first)
        let descriptor = CoverageSourceRetryDescriptor(scope: .init(provider: .claudeCode, profileID: "test", interface: .t3, path: .versionedTranscript),
            sourceURL: selected)
        let reread = try await claude.normalize(claude.initialHistoricalCapture(audit: audit, source: descriptor),
            capturedAt: emissionTime, cryptography: crypto)
        #expect(reread.sources.count == 1 && reread.sources.map(\.record.metadata.identity) == first.sources.map(\.record.metadata.identity))
        #expect(reread.sources.map(\.record.revision) == first.sources.map(\.record.revision))

        let history = CodexTestHistory(), codex = try codexTestAdapter(history: history, checkpoints: { await checkpoints.get($0) })
        // Covers-thread metadata is deliberately settled in the past; a normal repeat can skip it.
        let end = Date(), recent = end.addingTimeInterval(-60)
        await history.configure("parent", thread: try codexThread(updatedAt: recent.timeIntervalSince1970),
            pages: [.init(data: [try codexItem("selected", timestamp: recent.timeIntervalSince1970 * 1000)])])
        let publicAudit = try HistoricalAuditContext(reason: .resume, endingAt: end)
        let publicFirst = try await codex.normalize(codex.packet(.init(audit: publicAudit, threads: ["parent"])), capturedAt: end, cryptography: crypto)
        await checkpoints.save(publicFirst)
        let skipped = try await codex.normalize(codex.packet(.init(audit: publicAudit, threads: ["parent"])), capturedAt: end, cryptography: crypto)
        #expect(skipped.sources.isEmpty)
        let publicRetry = CoverageSourceRetryDescriptor(scope: codex.collectionScope,
            session: try .init(provider: .codex, profileID: "test", sessionID: "parent"))
        let publicReread = try await codex.normalize(codex.initialHistoricalCapture(audit: publicAudit, source: publicRetry),
            capturedAt: end, cryptography: crypto)
        #expect(publicReread.sources.count == 1 && publicReread.sources.map(\.record.metadata.identity) == publicFirst.sources.map(\.record.metadata.identity))
        #expect(publicReread.sources.map(\.record.revision) == publicFirst.sources.map(\.record.revision))
    }

    @Test func onlyACompletedCodexEmptyPollCarriesReadEvidence() async throws {
        let history = CodexTestHistory(), adapter = try codexTestAdapter(history: history)
        await history.configure("parent", thread: try codexThread(), pages: [.init(data: [], bytesRead: 32)])
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let empty = try await adapter.normalize(codexPacket(thread: "parent"), capturedAt: emissionTime, cryptography: crypto)
        #expect(empty.sources.isEmpty && empty.checkpoints.isEmpty && empty.coverageGaps.isEmpty && empty.observedRead)
        await #expect(throws: CodexCollectionError.awaitingHistory) {
            try await adapter.normalize(codexPacket(thread: "parent", event: "Stop"), capturedAt: emissionTime, cryptography: crypto)
        }
        let malformed = try CapturePacket(metadata: .init(agent: .codex, interface: .t3, profileID: "test"), eventJSON: Data("{}".utf8))
        let unknown = try await adapter.normalize(malformed, capturedAt: emissionTime, cryptography: crypto)
        #expect(!unknown.observedRead && !unknown.coverageGaps.isEmpty)
    }

    @Test func admissionUsesConfiguredAuthorityAndRejectsMetadataMismatch() throws {
        let publicScope = CollectionScope(provider: .codex, profileID: "test", interface: .t3, path: .publicHistory)
        let publicRoute = CollectionCaptureRoute(scope: publicScope, readerVersion: "reader-fixture", hostVersion: "host-fixture")
        let packet = try codexPacket(thread: "selected", extra: ["transcript_path": "/fake/must-not-select.jsonl"])
        let context = try publicRoute.context(for: packet, trigger: .activePoll)
        #expect(context.scope == publicScope && context.operation == .liveRead && context.trigger == .activePoll)
        #expect(context.retry?.session?.sessionID == "selected" && context.retry?.sourceURL == nil)
        #expect(context.readerVersion == "reader-fixture" && context.hostVersion == "host-fixture")
        let foreign = try CapturePacket(metadata: .init(agent: .codex, interface: .t3, profileID: "foreign"), eventJSON: packet.eventJSON)
        #expect(throws: CaptureTransportError.invalidMetadata) { try publicRoute.context(for: foreign, trigger: .activePoll) }
        let wrongHost = try codexPacket(thread: "selected", interface: .standaloneCLI)
        #expect(throws: CaptureTransportError.invalidMetadata) { try publicRoute.context(for: wrongHost, trigger: .helperDelivery) }
    }

    @Test func transcriptAdmissionKeepsOnlyItsOriginalSelectionAndHistoryIsExplicit() throws {
        let scope = CollectionScope(provider: .claudeCode, profileID: "test", interface: .t3, path: .versionedTranscript)
        let route = CollectionCaptureRoute(scope: scope)
        func packet(_ path: String?) throws -> CapturePacket {
            var event = ["session_id": "selected", "hook_event_name": "SpillcheckTranscriptPoll"]
            event["transcript_path"] = path
            return try CapturePacket(metadata: .init(agent: .claudeCode, interface: .t3, profileID: "test"),
                eventJSON: JSONSerialization.data(withJSONObject: event))
        }
        let selected = try route.context(for: packet("/fake/selected.jsonl"), trigger: .activePoll)
        #expect(selected.retry?.scope == scope && selected.retry?.sourceURL == URL(fileURLWithPath: "/fake/selected.jsonl"))
        #expect(try route.context(for: packet(nil), trigger: .activePoll).retry == nil)
        #expect(try route.context(for: packet("relative.jsonl"), trigger: .activePoll).retry == nil)
        let audit = try HistoricalAuditContext(reason: .resume, endingAt: emissionTime)
        let profileHistory = try route.context(for: packet("/fake/selected.jsonl"), trigger: .historyRequest, audit: audit)
        #expect(profileHistory.retry == nil && profileHistory.operation == .historicalRead && profileHistory.audit?.auditID == audit.id)
        let exactHistory = try route.context(for: packet("/fake/selected.jsonl"), trigger: .historyRequest, audit: audit, retry: selected.retry)
        #expect(exactHistory.retry == selected.retry)
        let wrongRoute = CoverageSourceRetryDescriptor(scope: .init(provider: .claudeCode, profileID: "test", interface: .standaloneCLI, path: .versionedTranscript), sourceURL: selected.retry?.sourceURL)
        #expect(throws: CaptureTransportError.invalidMetadata) {
            try route.context(for: packet("/fake/selected.jsonl"), trigger: .historyRequest, audit: audit, retry: wrongRoute)
        }
    }

    @Test func authoritativeRouteMappingAndLegacyGapDecodeStayHonest() throws {
        #expect(CodexCollectionAuthority.t3VersionedTranscript.collectionPath == .versionedTranscript)
        #expect(CollectionCompatibility.collectionPath(provider: .codex, authorityID: CodexCollectionAuthority.publicNativeItems.rawValue) == .publicHistory)
        #expect(CollectionCompatibility.collectionPath(provider: .codex, authorityID: "unknown") == nil)
        let firstFile = CoverageRecoveryReference(session: try .init(provider: .claudeCode, profileID: "test", sessionID: "same"),
            parserContract: "fixture", sourceURL: URL(fileURLWithPath: "/fake/first.jsonl"))
        let otherFile = CoverageRecoveryReference(session: firstFile.session,
            parserContract: "fixture", sourceURL: URL(fileURLWithPath: "/fake/other.jsonl"))
        #expect(!firstFile.identifiesSameLocation(as: otherFile))
        let scope = CollectionScope(provider: .claudeCode, profileID: "test", interface: .t3, path: .versionedTranscript)
        let before = CoverageSourceRetryDescriptor(scope: scope, session: firstFile.session, sourceURL: firstFile.sourceURL)
        let document = UUID()
        let row = CoverageRecoveryReference(session: firstFile.session, locator: .transcriptByteOffset(documentID: document, byteOffset: 42),
            parserContract: "fixture", sourceURL: firstFile.sourceURL)
        #expect(row.sourceDocumentID == nil && row.retrySourceDocumentID == document)
        let enriched = CoverageSourceRetryDescriptor(scope: scope, session: firstFile.session,
            sourceDocumentID: row.retrySourceDocumentID, sourceURL: row.sourceURL)
        #expect(before.identifiesSameSource(as: enriched) && enriched.identifiesSameSource(as: before))
        #expect(!before.identifiesSameSource(as: .init(scope: scope, session: before.session, sourceURL: otherFile.sourceURL)))
        #expect(!before.identifiesSameSource(as: .init(scope: scope, session: before.session)))
        let legacy = try JSONDecoder().decode(CoverageGap.self, from: Data("{\"reason\":\"sourceUnavailable\"}".utf8))
        #expect(legacy.observedAt == nil && legacy.interval == nil && legacy.requiresAnalysis)
        let excluded = CoverageGap(reason: .unsupportedContent, excludedContent: true)
        #expect(!excluded.requiresAnalysis)
    }
}
