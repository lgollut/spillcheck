import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private let claudeCaptureScope = CollectionScope(provider: .claudeCode, profileID: "test", interface: .t3, path: .versionedTranscript)
private func claudeRoutePacket(_ event: String, extra: [String: Any] = [:]) throws -> CapturePacket {
    var body: [String: Any] = ["session_id": "parent", "hook_event_name": event,
        "transcript_path": "/fake/parent.jsonl"]
    body.merge(extra) { _, value in value }
    return try CapturePacket(metadata: .init(agent: .claudeCode, interface: .t3, profileID: "test"),
        eventJSON: JSONSerialization.data(withJSONObject: body))
}

@Suite("Claude capture recovery source selection")
struct ClaudeCaptureRouteTests {
    @Test(arguments: ["PostToolUse", "PostToolUseFailure", "PostToolBatch"])
    func childToolCaptureRetainsOnlyItsOwnFileWithoutAssumingNativeSession(event: String) throws {
        let route = CollectionCaptureRoute(scope: claudeCaptureScope)
        let child = URL(fileURLWithPath: "/fake/parent/subagents/agent-worker_1-A.jsonl")
        for declared in [false, true] {
            var hints: [String: Any] = ["agent_id": "worker_1-A"]
            if declared { hints["agent_transcript_path"] = child.path }
            let context = try route.context(for: claudeRoutePacket(event, extra: hints), trigger: .helperDelivery)
            let retry = try #require(context.retry)
            #expect(retry.scope == claudeCaptureScope && retry.sourceURL == child && retry.session == nil)
            let native = CoverageSourceRetryDescriptor(scope: claudeCaptureScope,
                session: try .init(provider: .claudeCode, profileID: "test", sessionID: "distinct-child-session"), sourceURL: child)
            #expect(retry.identifiesSameSource(as: native) && native.identifiesSameSource(as: retry))
            let parent = CoverageSourceRetryDescriptor(scope: claudeCaptureScope,
                session: try .init(provider: .claudeCode, profileID: "test", sessionID: "parent"),
                sourceURL: URL(fileURLWithPath: "/fake/parent.jsonl"))
            #expect(!retry.identifiesSameSource(as: parent))
        }
        let parent = try route.context(for: claudeRoutePacket(event), trigger: .helperDelivery)
        #expect(parent.retry?.sourceURL == URL(fileURLWithPath: "/fake/parent.jsonl"))
        #expect(parent.retry?.session?.sessionID == "parent")
    }

    @Test(arguments: ["PostToolUse", "PostToolUseFailure", "PostToolBatch"])
    func invalidChildToolHintsCannotFallBackToParentRecovery(event: String) throws {
        let route = CollectionCaptureRoute(scope: claudeCaptureScope)
        let invalid: [[String: Any]] = [
            ["agent_id": ""], ["agent_id": NSNull()], ["agent_id": 42],
            ["agent_id": "../other"], ["agent_id": "worker/other"], ["agent_id": "wörker"],
            ["agent_id": String(repeating: "a", count: 1024)],
            ["agent_id": "worker", "transcript_path": "relative.jsonl"],
            ["agent_id": "worker", "transcript_path": "/fake/parent.txt"],
            ["agent_id": "worker", "agent_transcript_path": "/fake/other/subagents/agent-worker.jsonl"],
            ["agent_id": "worker", "agent_transcript_path": "/fake/parent/subagents/agent-sibling.jsonl"],
            ["agent_id": "worker", "agent_transcript_path": ""],
            ["agent_id": "worker", "agent_transcript_path": NSNull()]
        ]
        for hints in invalid {
            #expect(try route.context(for: claudeRoutePacket(event, extra: hints), trigger: .helperDelivery).retry == nil)
        }
    }

    @Test(arguments: ["SpillcheckTranscriptPoll", "LeakretTranscriptPoll"])
    func selectedPollRetainsConfinedChildAndOrdinaryPollRetainsParent(event: String) throws {
        let route = CollectionCaptureRoute(scope: claudeCaptureScope)
        let child = URL(fileURLWithPath: "/fake/parent/subagents/agent-worker.jsonl")
        let selected = try route.context(for: claudeRoutePacket(event, extra: ["agent_transcript_path": child.path]), trigger: .activePoll)
        #expect(selected.retry?.sourceURL == child && selected.retry?.session == nil)
        let workflowChild = URL(fileURLWithPath: "/fake/parent/subagents/workflows/wf_run/agent-worker.jsonl")
        let workflow = try route.context(for: claudeRoutePacket(event, extra: ["agent_transcript_path": workflowChild.path]), trigger: .activePoll)
        #expect(workflow.retry?.sourceURL == workflowChild && workflow.retry?.session == nil)
        let invalidHints: [Any] = ["/fake/other/subagents/agent-worker.jsonl", "/fake/parent/subagents/other.jsonl",
            "/fake/parent/subagents/nested/agent-worker.jsonl", "/fake/parent/subagents/workflows/agent-worker.jsonl",
            "/fake/parent/subagents/workflows/wf_run/deeper/agent-worker.jsonl",
            "/fake/parent/subagents/workflows/../agent-worker.jsonl", "/fake/other/subagents/workflows/wf_run/agent-worker.jsonl",
            "/fake/parent/subagents/workflows//wf_run/agent-worker.jsonl", "/fake/parent/subagents/workflows/wf_run//agent-worker.jsonl",
            "/fake/parent/subagents/workflows/wf_run/agent-worker.jsonl/",
            "/fake/parent.jsonl", "relative.jsonl", "", NSNull()]
        for invalid in invalidHints {
            #expect(try route.context(for: claudeRoutePacket(event, extra: ["agent_transcript_path": invalid]), trigger: .activePoll).retry == nil)
        }
        let parent = try route.context(for: claudeRoutePacket(event), trigger: .activePoll)
        #expect(parent.retry?.sourceURL == URL(fileURLWithPath: "/fake/parent.jsonl"))
        #expect(parent.retry?.session?.sessionID == "parent")
    }

    @Test func subagentStopCannotCertifyBothFilesWithASingleParentRetry() throws {
        let route = CollectionCaptureRoute(scope: claudeCaptureScope)
        for hints in [[:], ["agent_transcript_path": "/fake/parent/subagents/agent-worker.jsonl"]] {
            #expect(try route.context(for: claudeRoutePacket("SubagentStop", extra: hints), trigger: .helperDelivery).retry == nil)
        }
    }

    @Test(arguments: ["PostToolUse", "PostToolUseFailure", "PostToolBatch", "SpillcheckTranscriptPoll", "LeakretTranscriptPoll"])
    func retainedChildRetryReadsDistinctNativeSessionWithoutParentOrSibling(event: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-claude-route-\(UUID())").resolvingSymlinksInPath()
        let children = root.appendingPathComponent("parent/subagents")
        try FileManager.default.createDirectory(at: children, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent.jsonl"), child = children.appendingPathComponent("agent-worker.jsonl")
        func row(_ id: String, session: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "user", "uuid": id, "sessionId": session,
                "timestamp": "2026-10-09T12:00:00Z", "message": ["role": "user", "content": "FAKE_\(id)"]]) + Data([10])
        }
        try row("parent-row", session: "parent").write(to: parent)
        try row("child-row", session: "distinct-child-session").write(to: child)
        try row("sibling-row", session: "sibling-session").write(to: children.appendingPathComponent("agent-sibling.jsonl"))
        var hints: [String: Any] = ["transcript_path": parent.path]
        if event.hasSuffix("TranscriptPoll") { hints["agent_transcript_path"] = child.path }
        else { hints["agent_id"] = "worker" }
        let route = CollectionCaptureRoute(scope: claudeCaptureScope)
        let context = try route.context(for: claudeRoutePacket(event, extra: hints), trigger: .helperDelivery)
        let retry = try #require(context.retry)
        try FileManager.default.removeItem(at: parent)
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [root])
        let now = Date(timeIntervalSince1970: 1_791_676_800)
        let packet = try await adapter.initialHistoricalCapture(audit: .init(reason: .resume, endingAt: now), source: retry)
        let batch = try await adapter.normalize(packet, capturedAt: now, cryptography: .ephemeralForTesting())
        #expect(batch.sources.map(\.record.metadata.identity.itemID) == ["prompt:child-row:block:0"])
        #expect(batch.sources.map(\.record.metadata.identity.session.sessionID) == ["distinct-child-session"])
        #expect(batch.coverageGaps.isEmpty && batch.continuation == nil && batch.historicalProgress?.hasUnreadContent == false)
    }
}
