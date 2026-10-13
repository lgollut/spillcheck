import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private enum ChildToolHook: CaseIterable, Sendable {
    case success, failure, successBatch, failureBatch

    var event: String {
        switch self {
        case .success: "PostToolUse"
        case .failure: "PostToolUseFailure"
        case .successBatch, .failureBatch: "PostToolBatch"
        }
    }
    var isFailure: Bool { self == .failure || self == .failureBatch }
    var toolID: String { isFailure ? "child-error-call" : "child-output-call" }
    var text: String { isFailure ? "canonical child error" : "canonical child output" }
    var isBatch: Bool { self == .successBatch || self == .failureBatch }
}

private actor ChildHookCheckpoints {
    private var values: [UUID: SourceCheckpoint] = [:]
    func get(_ id: UUID) -> SourceCheckpoint? { values[id] }
    func save(_ checkpoints: [SourceCheckpoint]) {
        for checkpoint in checkpoints { values[checkpoint.sourceDocumentID] = checkpoint }
    }
}

private struct ChildHookFixture {
    let root: URL
    let parent: URL
    let child: URL
    let childSession: String
    let timestamp = "2026-10-12T12:00:00Z"
    let parentSession = "parent-session"
    let agentID = "child-worker"

    init(distinctSession: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spillcheck-child-hooks-\(UUID())").resolvingSymlinksInPath()
        parent = root.appendingPathComponent("parent-session.jsonl")
        child = root.appendingPathComponent("parent-session/subagents/agent-child-worker.jsonl")
        childSession = distinctSession ? "child-session" : "parent-session"
        try FileManager.default.createDirectory(at: child.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try row(session: parentSession, id: "parent-prompt", content: "parent only").write(to: parent)
        try writeChild()
    }

    func row(session: String, id: String, content: Any, isChild: Bool = false) throws -> Data {
        var row: [String: Any] = ["type": "user", "uuid": id, "sessionId": session,
            "version": "2.1.296", "timestamp": timestamp, "cwd": root.path,
            "isSidechain": isChild, "message": ["role": "user", "content": content]]
        if isChild { row["agentId"] = agentID }
        return try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])
    }

    func resultRow(_ hook: ChildToolHook, session: String? = nil, text: String? = nil,
                   toolID: String? = nil) throws -> Data {
        try row(session: session ?? childSession, id: "row-\(hook.toolID)",
            content: [["type": "tool_result", "tool_use_id": toolID ?? hook.toolID,
                "content": text ?? hook.text, "is_error": hook.isFailure]], isChild: session == nil)
    }

    func writeChild(outputID: String = "child-output-call") throws {
        try (resultRow(.success, toolID: outputID) + resultRow(.failure)).write(to: child)
    }

    func packet(_ hook: ChildToolHook, agentID override: String? = nil,
                explicitChild: URL? = nil, response: String? = nil,
                interface: AgentInterface = .standaloneCLI) throws -> CapturePacket {
        // Static inspection of installed Claude Code 2.1.296 (SHA256
        // c9b5341637becbd423ddffc5b254afb645682a3868cb708bbc6cc0e7bb419937):
        // common builder at byte 198192307 emits parent session/path + context.agentId;
        // tool builders at 198296306/198296779/198297203 add no agent_transcript_path.
        // These are constructed regression inputs, not retained live hook payloads.
        var hookInput: [String: Any] = ["hook_event_name": hook.event,
            "session_id": parentSession, "transcript_path": parent.path,
            "agent_id": override ?? agentID, "agent_type": "general-purpose", "cwd": root.path]
        let call: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "owned fixture"],
            "tool_use_id": hook.toolID, "tool_response": response ?? hook.text]
        if hook.isBatch { hookInput["tool_calls"] = [call] }
        else {
            hookInput["tool_name"] = call["tool_name"]
            hookInput["tool_input"] = call["tool_input"]
            hookInput["tool_use_id"] = hook.toolID
            hookInput[hook.isFailure ? "error" : "tool_response"] = response ?? hook.text
        }
        if let explicitChild { hookInput["agent_transcript_path"] = explicitChild.path }
        return try CapturePacket(metadata: .init(agent: .claudeCode, interface: interface, profileID: "test"),
            eventJSON: JSONSerialization.data(withJSONObject: hookInput, options: [.sortedKeys]))
    }
}

@Suite("Claude child tool hook routing")
struct ClaudeChildHookRoutingTests {
    @Test(arguments: ChildToolHook.allCases, [false, true])
    fileprivate func ordinaryChildToolHooksUseOwnCanonicalRowsAndReplay(
        hook: ChildToolHook, distinctSession: Bool
    ) async throws {
        let fixture = try ChildHookFixture(distinctSession: distinctSession)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cache = ChildHookCheckpoints()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296",
            allowedTranscriptRoots: [fixture.root], checkpointLookup: { await cache.get($0) })
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let originalBytes = try Data(contentsOf: fixture.child)
        let original = try await adapter.importTranscript(originalBytes, documentID: UUID(),
            interface: .standaloneCLI, observedAt: Date(), cryptography: crypto)
        let batch = try await adapter.normalize(fixture.packet(hook), capturedAt: Date(), cryptography: crypto)
        #expect(batch.coverageGaps.isEmpty && batch.continuation == nil)
        #expect(batch.sources.count == 2)
        for source in batch.sources {
            let canonical = try #require(original.sources.first { $0.record.metadata.identity == source.record.metadata.identity })
            #expect(source.record.revision == canonical.record.revision)
            #expect(source.record.segments == canonical.record.segments)
            #expect(source.record.metadata.contentTime == canonical.record.metadata.contentTime)
            #expect(source.record.metadata.contentType == canonical.record.metadata.contentType)
            #expect(source.record.metadata.identity.session.sessionID == fixture.childSession)
            #expect(source.context?.sessionIdentifier == fixture.childSession)
            #expect(source.context?.transcriptPath == fixture.child.path)
        }
        let selected = try #require(batch.sources.first { $0.record.metadata.identity.itemID == "tool:\(hook.toolID)" })
        #expect(selected.record.metadata.contentType == (hook.isFailure ? .toolError : .toolOutput))
        await cache.save(batch.checkpoints)
        // Child replay must not depend on the parent's file remaining readable.
        try FileManager.default.removeItem(at: fixture.parent)
        for interface in [AgentInterface.standaloneCLI, .t3] {
            let replay = try await adapter.normalize(fixture.packet(hook, interface: interface),
                capturedAt: Date(), cryptography: crypto)
            #expect(replay.sources.isEmpty && replay.coverageGaps.isEmpty && replay.continuation == nil)
            await cache.save(replay.checkpoints)
        }
        #expect(try Data(contentsOf: fixture.child) == originalBytes)
    }

    @Test(arguments: ["../escape", "child/../../escape", "/absolute", "child\0suffix", ""])
    func invalidAgentIDCannotReadParentOrEscape(_ agentID: String) async throws {
        let fixture = try ChildHookFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.resultRow(.success, session: fixture.parentSession, text: "parent decoy").write(to: fixture.parent)
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [fixture.root])
        let batch = try await adapter.normalize(fixture.packet(.success, agentID: agentID),
            capturedAt: Date(), cryptography: .ephemeralForTesting())
        #expect(batch.sources.isEmpty && batch.checkpoints.isEmpty && !batch.coverageGaps.isEmpty)
    }

    @Test func explicitConflictingChildPathCannotRedirectOrdinaryHook() async throws {
        let fixture = try ChildHookFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unrelated = fixture.root.appendingPathComponent("other/subagents/agent-child-worker.jsonl")
        try FileManager.default.createDirectory(at: unrelated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture.resultRow(.success, text: "unrelated decoy").write(to: unrelated)
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [fixture.root])
        let batch = try await adapter.normalize(fixture.packet(.success, explicitChild: unrelated),
            capturedAt: Date(), cryptography: .ephemeralForTesting())
        #expect(batch.sources.isEmpty && batch.checkpoints.isEmpty && !batch.coverageGaps.isEmpty)
    }

    @Test func missingChildDoesNotUseMatchingParentToolResult() async throws {
        let fixture = try ChildHookFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.child)
        try fixture.resultRow(.success, session: fixture.parentSession, text: "parent decoy").write(to: fixture.parent)
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [fixture.root])
        await #expect(throws: ClaudeCollectionError.awaitingTranscript) {
            try await adapter.normalize(fixture.packet(.success), capturedAt: Date(), cryptography: .ephemeralForTesting())
        }
    }

    @Test func childSymlinkDoesNotReadAnotherAllowedTranscript() async throws {
        let fixture = try ChildHookFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unrelated = fixture.root.appendingPathComponent("unrelated.jsonl")
        try fixture.resultRow(.success, text: "unrelated decoy").write(to: unrelated)
        try FileManager.default.removeItem(at: fixture.child)
        try FileManager.default.createSymbolicLink(at: fixture.child, withDestinationURL: unrelated)
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [fixture.root])
        await #expect(throws: ClaudeCollectionError.awaitingTranscript) {
            try await adapter.normalize(fixture.packet(.success), capturedAt: Date(), cryptography: .ephemeralForTesting())
        }
    }

    @Test(arguments: [ChildToolHook.success, .successBatch])
    fileprivate func absentChildToolIDStaysRetryableDespiteMatchingParent(_ hook: ChildToolHook) async throws {
        let fixture = try ChildHookFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeChild(outputID: "another-child-call")
        try fixture.resultRow(.success, session: fixture.parentSession, text: "parent decoy").write(to: fixture.parent)
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [fixture.root])
        await #expect(throws: ClaudeCollectionError.awaitingTranscript) {
            try await adapter.normalize(fixture.packet(hook), capturedAt: Date(), cryptography: .ephemeralForTesting())
        }
    }

    @Test func mismatchedChildBatchKeepsCanonicalBytesAndVisibleCorrelationGap() async throws {
        let fixture = try ChildHookFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [fixture.root])
        let batch = try await adapter.normalize(fixture.packet(.successBatch, response: "different hook bytes"),
            capturedAt: Date(), cryptography: .ephemeralForTesting())
        let source = try #require(batch.sources.first { $0.record.metadata.identity.itemID == "tool:child-output-call" })
        #expect(source.record.segments.map { String(decoding: $0.utf8, as: UTF8.self) } == [ChildToolHook.success.text])
        #expect(source.record.metadata.identity.session.sessionID == fixture.childSession)
        #expect(batch.coverageGaps.contains { $0.reason == .unresolvedCorrelation && $0.operation == .liveRead })
    }
}
