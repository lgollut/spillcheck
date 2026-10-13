import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private struct ClaudeCaptureStorageDetector: SecretDetector {
    func scan(_ source: SourceRecord) async throws -> DetectorOutput {
        .init(detectorVersion: "claude-child-storage-fixture", findings: [], unlocated: [])
    }
}

private struct ClaudeCaptureStorageFixture {
    let root: URL
    let sources: URL
    let storeURL: URL
    let parent: URL
    let child: URL
    let sibling: URL
    let crypto: BackgroundCryptography
    let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let scope = CollectionScope(provider: .claudeCode, profileID: "child-storage", interface: .t3,
        path: .versionedTranscript)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-child-storage-\(UUID())")
            .resolvingSymlinksInPath()
        sources = root.appendingPathComponent("sources")
        storeURL = root.appendingPathComponent("store")
        parent = sources.appendingPathComponent("parent.jsonl")
        child = sources.appendingPathComponent("parent/subagents/agent-worker.jsonl")
        sibling = sources.appendingPathComponent("parent/subagents/agent-sibling.jsonl")
        crypto = try .ephemeralForTesting()
        try FileManager.default.createDirectory(at: child.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    var route: CollectionCaptureRoute { .init(scope: scope, readerVersion: "2.1.296") }

    func packet(_ event: String) throws -> CapturePacket {
        var body: [String: Any] = ["session_id": "parent", "transcript_path": parent.path,
            "hook_event_name": event]
        if event.hasSuffix("TranscriptPoll") { body["agent_transcript_path"] = child.path }
        else {
            body["agent_id"] = "worker"
            if event == "PostToolBatch" {
                body["tool_calls"] = [["tool_use_id": "child-call", "tool_response": "fake child output"]]
            } else { body["tool_use_id"] = "child-call" }
        }
        return try CapturePacket(metadata: .init(agent: .claudeCode, interface: .t3, profileID: scope.profileID),
            eventJSON: JSONSerialization.data(withJSONObject: body))
    }

    func row(session: String, id: String, toolID: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "user", "uuid": id, "sessionId": session,
            "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)), "version": "2.1.296",
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": toolID,
                "content": "fake child output", "is_error": false]]]]) + Data([10])
    }

    func open() async throws -> ProtectedStore {
        try await ProtectedStore.open(at: storeURL, cryptography: crypto, limits: .init(maxRetryCount: 0))
    }

    func adapter(store: ProtectedStore) throws -> ClaudeAdapter {
        try ClaudeAdapter(profileID: scope.profileID, agentVersion: "2.1.296", allowedTranscriptRoots: [sources],
            checkpointLookup: { try await store.checkpoint(documentID: $0) })
    }

    func pipeline(store: ProtectedStore, adapter: ClaudeAdapter) -> DetectionPipeline {
        .init(store: store, cryptography: crypto, normalizer: adapter, detector: ClaudeCaptureStorageDetector(),
            detectorVersion: "claude-child-storage-fixture", liveSince: now)
    }
}

@Suite("Claude child capture storage admission")
struct ClaudeCaptureStorageTests {
    @Test(arguments: ["PostToolUse", "PostToolUseFailure", "PostToolBatch", "SpillcheckTranscriptPoll", "LeakretTranscriptPoll"])
    func childFileSelectionEnqueuesAndRoundTripsWithoutInventedSession(event: String) async throws {
        let fixture = try ClaudeCaptureStorageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await fixture.open(), packet = try fixture.packet(event)
        let context = try fixture.route.context(for: packet, trigger: .helperDelivery)
        let retry = try #require(context.retry)
        #expect(retry.sourceURL == fixture.child && retry.session == nil && retry.sourceDocumentID == nil)
        let permit = try #require(await store.processingPermit()), id = UUID()
        let liveScope = try LiveCaptureScope(startedAt: fixture.now)
        _ = try await store.enqueue(packet.body, id: id, capturedAt: fixture.now, permit: permit, at: fixture.now,
            scope: liveScope, workContext: context)
        let stored = try #require(try await store.collectionWork(id: id))
        #expect(stored.context.retry == retry && stored.state == .queued)
        #expect(stored.context.auditWindow == DateInterval(
            start: fixture.now.addingTimeInterval(-HistoricalAuditContext.lookback), end: fixture.now))
        try await store.close()

        let reopened = try await fixture.open()
        let reloaded = try #require(try await reopened.collectionWork(id: id))
        #expect(reloaded.context == stored.context && reloaded.context.retry?.session == nil)
        let nextPermit = try #require(await reopened.processingPermit())
        let capture = try #require(try await reopened.nextPending(at: fixture.now, permit: nextPermit))
        #expect(capture.id == id)
        #expect(try await reopened.openCapturedWork(capture).body == packet.body)
        try await reopened.close()
    }

    @Test func pathOnlyAdmissionDoesNotAuthorizeOtherRoutesOrMalformedURLs() async throws {
        let fixture = try ClaudeCaptureStorageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await fixture.open(), permit = try #require(await store.processingPermit())
        let badURLs: [URL?] = [nil, URL(string: "https://example.invalid/child.jsonl"),
            URL(string: "file:///fake/child.jsonl?query=1"), URL(string: "file:///fake/child.jsonl#fragment"),
            URL(string: "file://remote.invalid/fake/child.jsonl"), URL(string: "file:relative.jsonl"),
            URL(string: "file:"), URL(string: "relative.jsonl"),
            URL(fileURLWithPath: "/fake/" + String(repeating: "x", count: 4096) + ".jsonl")]
        var cases: [(AgentProvider, CollectionPath, URL?)] = [
            (.codex, .publicHistory, fixture.child), (.codex, .hook, fixture.child),
            (.claudeCode, .hook, fixture.child)]
        cases += badURLs.map { (.claudeCode, .versionedTranscript, $0) }
        for (provider, path, url) in cases {
            let scope = CollectionScope(provider: provider, profileID: "invalid-child-selection", interface: .t3, path: path)
            let packet = try CapturePacket(metadata: .init(agent: provider, interface: .t3, profileID: scope.profileID),
                eventJSON: Data("{}".utf8))
            let context = CollectionWorkContext(scope: scope, operation: .liveRead,
                retry: .init(scope: scope, sourceURL: url), trigger: .helperDelivery)
            await #expect(throws: StorageError.invalidPayload) {
                try await store.enqueue(packet.body, capturedAt: fixture.now, permit: permit, at: fixture.now,
                    workContext: context)
            }
        }
        #expect(try await store.queueStatistics().count == 0)
        try await store.close()
    }

    @Test func exactChildRecoverySurvivesRestartAndCommitsOnlyChildReceipts() async throws {
        let fixture = try ClaudeCaptureStorageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.row(session: "parent", id: "parent-row", toolID: "parent-call").write(to: fixture.parent)
        try fixture.row(session: "sibling", id: "sibling-row", toolID: "sibling-call").write(to: fixture.sibling)
        let store = try await fixture.open(), packet = try fixture.packet("PostToolUse")
        let context = try fixture.route.context(for: packet, trigger: .helperDelivery)
        let retry = try #require(context.retry), targetID = UUID()
        let permit = try #require(await store.processingPermit())
        let liveScope = try LiveCaptureScope(startedAt: fixture.now)
        _ = try await store.enqueue(packet.body, id: targetID, capturedAt: fixture.now, permit: permit, at: fixture.now,
            scope: liveScope, workContext: context)
        let pipeline = fixture.pipeline(store: store, adapter: try fixture.adapter(store: store))
        #expect(try await pipeline.processNext(at: fixture.now) == .retryScheduled)
        #expect(try await store.collectionWork(id: targetID)?.state == .terminal)
        #expect(try await store.collectionWork(id: targetID)?.recoveryCertificate == nil)
        #expect(try await store.coverageGaps().map(\.reason) == [.sourceUnavailable])
        #expect(await store.snapshot().analysisReceipts.isEmpty)
        try await store.close()

        let childBytes = try fixture.row(session: "distinct-native-child", id: "child-row", toolID: "child-call")
        try childBytes.write(to: fixture.child)
        try FileManager.default.removeItem(at: fixture.parent)
        let reopened = try await fixture.open(), time = fixture.now.addingTimeInterval(5)
        let restored = try #require(try await reopened.collectionWork(id: targetID))
        #expect(restored.context.retry == retry && restored.context.retry?.session == nil)
        let endings = try await reopened.remainingRecoveryAuditEnds(for: targetID, at: time)
        #expect(endings == [fixture.now])
        let audit = try HistoricalAuditContext(reason: .resume, endingAt: #require(endings.first))
        let nextPermit = try #require(await reopened.processingPermit())
        let adapter = try fixture.adapter(store: reopened)
        let siblingSelection = CoverageSourceRetryDescriptor(scope: fixture.scope, sourceURL: fixture.sibling)
        let siblingPacket = try await adapter.initialHistoricalCapture(audit: audit, source: siblingSelection)
        let siblingContext = try fixture.route.context(for: siblingPacket, trigger: .historyRequest,
            audit: audit, retry: siblingSelection)
        await #expect(throws: StorageError.invalidPayload) {
            try await reopened.enqueue(siblingPacket.body, capturedAt: time, permit: nextPermit, at: time,
                historicalAudit: audit, workContext: siblingContext, recoveryOf: targetID)
        }
        #expect(try await reopened.collectionWork(id: targetID)?.state == .terminal)
        let history = try await adapter.initialHistoricalCapture(audit: audit, source: retry)
        let historicalContext = try fixture.route.context(for: history, trigger: .historyRequest, audit: audit, retry: retry)
        let recoveryID = UUID()
        _ = try await reopened.enqueue(history.body, id: recoveryID, capturedAt: time, permit: nextPermit, at: time,
            historicalAudit: audit, workContext: historicalContext, recoveryOf: targetID)
        let recoveryPipeline = fixture.pipeline(store: reopened, adapter: adapter)
        #expect(try await recoveryPipeline.processNext(at: time) == .processed)
        let completed = try #require(try await reopened.collectionWork(id: recoveryID))
        #expect(completed.recoveryCertificate?.targetWorkID == targetID)
        #expect(try await reopened.collectionWork(id: targetID)?.state == .recovered)
        #expect(try await reopened.remainingRecoveryAuditEnds(for: targetID, at: time).isEmpty)
        let snapshot = await reopened.snapshot()
        #expect(snapshot.analysisReceipts.count == 1)
        #expect(Set(snapshot.sourceKinds.keys.map(\.session.sessionID)) == ["distinct-native-child"])
        #expect(Set(snapshot.sourceKinds.keys.map(\.itemID)) == ["tool:child-call"])
        #expect(try await reopened.queueStatistics().count == 0)
        #expect(try Data(contentsOf: fixture.child) == childBytes)
        try await reopened.close()
    }
}
