import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private func claudeFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/Claude"))
    return try Data(contentsOf: url)
}
private func claudeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-claude-test-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
}
private func claudeRow(session: String = "session", uuid: String = "row", type: String = "user",
                       content: Any, timestamp: String? = "2026-10-07T20:59:13.159Z", stop: String? = nil) throws -> Data {
    var row: [String: Any] = ["type": type, "uuid": uuid, "sessionId": session,
                            "message": ["role": type, "content": content, "stop_reason": stop as Any? ?? NSNull()]]
    if let timestamp { row["timestamp"] = timestamp }
    return try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])
}
private func claudePacket(_ hook: [String: Any], profile: String = "test", interface: AgentInterface = .standaloneCLI) throws -> CapturePacket {
    try CapturePacket(metadata: .init(agent: .claudeCode, interface: interface, profileID: profile),
                      eventJSON: JSONSerialization.data(withJSONObject: hook))
}
private func claudeText(_ source: CollectedSource) -> String { source.record.segments.map { String(decoding: $0.utf8, as: UTF8.self) }.joined(separator: "\n") }
private actor ClaudeCheckpointStore {
    private var saved: [UUID: SourceCheckpoint] = [:]
    func lookup(_ id: UUID) -> SourceCheckpoint? { saved[id] }
    func keep(_ batch: CollectionBatch) { for checkpoint in batch.checkpoints { saved[checkpoint.sourceDocumentID] = checkpoint } }
}

@Suite("Claude validated collection")
struct ClaudeAdapterTests {
    @Test func malformedQueuedUserPromptIsRequiredContentLoss() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.295", allowedTranscriptRoots: [])
        let data = try JSONSerialization.data(withJSONObject: ["type": "attachment", "uuid": "queued",
            "sessionId": "session", "timestamp": "2026-10-09T12:00:00Z",
            "attachment": ["type": "queued_command", "commandMode": "prompt", "prompt": 42]]) + Data([10])
        let batch = try await adapter.importTranscript(data, documentID: UUID(), interface: .standaloneCLI,
            observedAt: Date(), cryptography: crypto)
        #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty)
        let gap = try #require(batch.coverageGaps.first)
        #expect(gap.reason == .malformedSource && gap.isRequiredFormatFailure == true && gap.contentType == .userPrompt)
        #expect(gap.sourceKind == .claudeQueuedPrompt && gap.diagnosticCode == .invalidFieldType)
    }

    @Test func observedSessionMetadataHasNoContentAndPreservesCanonicalMessages() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.295", allowedTranscriptRoots: [])
        let document = UUID(), prompt = try claudeRow(content: "required prompt")
        let original = try await adapter.importTranscript(prompt, documentID: document,
            interface: .standaloneCLI, observedAt: Date(), cryptography: crypto)
        var metadata = try JSONSerialization.data(withJSONObject: ["type": "attachment", "sessionId": "session",
            "attachment": ["type": "total_tokens_reminder", "text": "non-message fixture"]]) + Data([10])
        for type in ["ai-title", "atis-latch", "cost-state", "last-prompt", "agent-name", "custom-title"] {
            metadata += try JSONSerialization.data(withJSONObject: ["type": type, "sessionId": "session",
                "metadata": ["value": "non-message fixture"]]) + Data([10])
        }
        let current = try await adapter.importTranscript(metadata + prompt, documentID: document,
            interface: .t3, observedAt: Date(), cryptography: crypto)
        #expect(current.coverageGaps.isEmpty && current.sources.count == 1)
        #expect(current.recoveredReferences.count == 8)
        #expect(current.sources.map(\.record.metadata.identity) == original.sources.map(\.record.metadata.identity))
        #expect(current.sources.map(\.record.revision) == original.sources.map(\.record.revision))
        #expect(current.sources.map(\.record.segments) == original.sources.map(\.record.segments))

        // Metadata recognition must not conceal an unfamiliar content-bearing shape or block.
        let changed = Data("{\"type\":\"attachment\",\"message\":{\"content\":\"new content shape\"}}\n{\"type\":\"agent-name\",\"content\":\"new content shape\"}\n{\"type\":\"custom-title\",\"message\":{\"content\":\"new content shape\"}}\n{\"type\":\"future_metadata\"}\n".utf8)
            + (try claudeRow(content: [["type": "future_output", "payload": "unknown block"],
                ["type": "text", "text": "required sibling"]]))
        let visible = try await adapter.importTranscript(changed, documentID: document,
            interface: .t3, observedAt: Date(), cryptography: crypto)
        #expect(visible.coverageGaps.count == 5)
        #expect(visible.coverageGaps.allSatisfy { $0.reason == .unsupportedContent })
        #expect(visible.sources.map(claudeText) == ["required sibling"])
        #expect(visible.recoveredReferences.isEmpty)
    }

    @Test func observedNormalModeControlsRecoverWithoutContent() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [])
        let document = UUID()
        // The owned T3 parent emitted this exact three-field shape twice, without timestamps or UUIDs.
        let control = try JSONSerialization.data(withJSONObject: ["type": "mode", "sessionId": "session",
            "mode": "normal"]) + Data([10])
        let batch = try await adapter.importTranscript(control + control, documentID: document,
            interface: .t3, observedAt: Date(), cryptography: crypto)
        #expect(batch.sources.isEmpty && batch.coverageGaps.isEmpty)
        #expect(batch.recoveredReferences.map(\.locator) == [
            .transcript(documentID: document, recordIndex: 0),
            .transcript(documentID: document, recordIndex: 1),
        ])
        let session = try SessionIdentity(provider: .claudeCode, profileID: "test", sessionID: "session")
        #expect(batch.recoveredReferences.allSatisfy {
            $0.session == session && $0.contentTime == nil && $0.parserContract == ClaudeAdapter.parserContractVersion
        })
    }

    @Test func changedModeControlsRemainVisibleAsGaps() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [])
        let control: [String: Any] = ["type": "mode", "sessionId": "session", "mode": "normal"]
        var changes: [[String: Any]] = []
        for (key, value) in [("message", ["content": "required text"] as Any),
                             ("content", "required text"), ("unknownPayload", "required text"),
                             ("message", NSNull()), ("content", NSNull()),
                             ("mode", "future_mode"), ("mode", "normal "), ("mode", ""),
                             ("mode", 1), ("mode", false), ("mode", NSNull()),
                             ("sessionId", 1), ("sessionId", false), ("sessionId", ""),
                             ("sessionId", NSNull()), ("type", false)] {
            var changed = control
            changed[key] = value
            changes.append(changed)
        }
        for key in ["type", "sessionId", "mode"] {
            var changed = control
            changed.removeValue(forKey: key)
            changes.append(changed)
        }
        for changed in changes {
            let data = try JSONSerialization.data(withJSONObject: changed) + Data([10])
            let batch = try await adapter.importTranscript(data, documentID: UUID(),
                interface: .t3, observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty)
            #expect(batch.coverageGaps.count == 1)
            #expect(batch.coverageGaps.allSatisfy { [.unsupportedContent, .malformedSource].contains($0.reason) })
        }
    }

    @Test func observedPermissionModeControlsRecoverWithoutLosingMessages() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [])
        let document = UUID(), observedAt = Date()
        // The setup transcript emitted this exact control three times, without timestamps or UUIDs.
        let control = try JSONSerialization.data(withJSONObject: ["type": "permission-mode",
            "permissionMode": "dontAsk", "sessionId": "session"]) + Data([10])
        let prompt = try claudeRow(content: "required prompt")
        let original = try await adapter.importTranscript(prompt, documentID: document,
            interface: .standaloneCLI, observedAt: observedAt, cryptography: crypto)
        let batch = try await adapter.importTranscript(control + control + control + prompt, documentID: document,
            interface: .standaloneCLI, observedAt: observedAt, cryptography: crypto)
        #expect(batch.coverageGaps.isEmpty)
        #expect(batch.recoveredReferences.map(\.locator) == (0..<4).map {
            .transcript(documentID: document, recordIndex: UInt64($0))
        })
        let session = try SessionIdentity(provider: .claudeCode, profileID: "test", sessionID: "session")
        #expect(batch.recoveredReferences.prefix(3).allSatisfy {
            $0.session == session && $0.contentTime == nil && $0.parserContract == ClaudeAdapter.parserContractVersion
        })
        #expect(batch.sources.map(\.record.metadata.identity) == original.sources.map(\.record.metadata.identity))
        #expect(batch.sources.map(\.record.revision) == original.sources.map(\.record.revision))
        #expect(batch.sources.map(\.record.segments) == original.sources.map(\.record.segments))
    }

    @Test func changedPermissionModeControlsRemainVisibleAsGaps() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [])
        let control: [String: Any] = ["type": "permission-mode", "sessionId": "session", "permissionMode": "dontAsk"]
        var changes: [[String: Any]] = []
        for (key, value) in [("message", ["content": "required text"] as Any),
                             ("content", "required text"), ("unknownPayload", "required text"),
                             ("message", NSNull()), ("content", NSNull()),
                             ("permissionMode", "future_mode"), ("permissionMode", "dontAsk "), ("permissionMode", ""),
                             ("permissionMode", 1), ("permissionMode", false), ("permissionMode", NSNull()),
                             ("sessionId", 1), ("sessionId", false), ("sessionId", ""),
                             ("sessionId", NSNull()), ("sessionId", "different-session"), ("type", false)] {
            var changed = control
            changed[key] = value
            changes.append(changed)
        }
        for key in ["type", "sessionId", "permissionMode"] {
            var changed = control
            changed.removeValue(forKey: key)
            changes.append(changed)
        }
        for changed in changes {
            let data = try JSONSerialization.data(withJSONObject: changed) + Data([10])
            let batch = try await adapter.importTranscript(data, documentID: UUID(),
                interface: .t3, observedAt: Date(), cryptography: crypto, expectedSessionID: "session")
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty)
            #expect(batch.coverageGaps.count == 1)
            #expect(batch.coverageGaps.allSatisfy { [.unsupportedContent, .malformedSource].contains($0.reason) })
        }
    }

    @Test func queuedPromptsAreCollectedAndContentBearingAttachmentsStayVisible() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.295", allowedTranscriptRoots: [])
        let batch = try await adapter.importTranscript(claudeFixture("claude-attachment-envelopes"), documentID: UUID(),
            interface: .standaloneCLI, observedAt: Date(), cryptography: crypto)
        let prompts = batch.sources.filter { $0.record.metadata.contentType == .userPrompt }
        #expect(prompts.map(claudeText) == ["SPILLCHECK_ATTACHMENT_PROMPT", "SPILLCHECK_QUEUED_PROMPT", "SPILLCHECK_QUEUED_BLOCK"])
        #expect(prompts.map(\.record.metadata.identity.itemID)
            == ["prompt:prompt-row:block:0", "prompt:queued-string:block:0", "prompt:queued-blocks:block:0"])
        #expect(batch.sources.contains { $0.record.metadata.contentType == .finalResponse && claudeText($0) == "SPILLCHECK_ATTACHMENT_FINAL" })
        // Context is recognized without content; notification, file and hook payloads stay unscanned gaps.
        #expect(!batch.sources.contains { claudeText($0).contains("SPILLCHECK_CONTEXT") })
        #expect(batch.coverageGaps.count == 3)
        #expect(batch.coverageGaps.allSatisfy { $0.reason == .unsupportedContent && $0.isRequiredFormatFailure != true })
        #expect(batch.recoveredReferences.count == 6)
    }

    @Test func numericBudgetAttachmentsAreMetadataButChangedPayloadsStayVisible() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [])
        func row(_ attachment: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "attachment", "sessionId": "session",
                "uuid": "budget-row", "timestamp": "2026-10-10T18:00:00Z", "attachment": attachment]) + Data([10])
        }
        let budget: [String: Any] = ["type": "budget_usd", "used": 0.25, "total": 3, "remaining": 2.75]
        let recognized = try await adapter.importTranscript(row(budget), documentID: UUID(),
            interface: .standaloneCLI, observedAt: Date(), cryptography: crypto)
        #expect(recognized.sources.isEmpty && recognized.coverageGaps.isEmpty)
        #expect(recognized.recoveredReferences.count == 1)

        var textAmount = budget, newContent = budget, missingAmount = budget, booleanAmount = budget, negativeAmount = budget
        textAmount["used"] = "unexpected text"
        newContent["content"] = "new required text"
        missingAmount.removeValue(forKey: "remaining")
        booleanAmount["used"] = true
        negativeAmount["used"] = -1
        for changed in [textAmount, newContent, missingAmount, booleanAmount, negativeAmount] {
            let batch = try await adapter.importTranscript(row(changed), documentID: UUID(),
                interface: .t3, observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty)
            #expect(batch.coverageGaps.map(\.reason) == [.unsupportedContent])
        }
    }

    @Test func emptyHookControlResponsesRecoverButOutputAndUnknownShapesRemainGaps() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [])
        func row(_ attachment: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "attachment", "sessionId": "session",
                "uuid": "hook-row", "timestamp": "2026-10-10T18:00:00Z", "attachment": attachment]) + Data([10])
        }
        let control: [String: Any] = ["type": "hook_success", "hookName": "PostToolUse", "toolUseID": "tool",
            "hookEvent": "PostToolUse", "command": "owned-fixture-hook", "durationMs": 12.5,
            "exitCode": 0, "content": "", "stdout": "{}\n", "stderr": ""]
        var batchControl = control
        batchControl["accountMemoryBatch"] = false
        for attachment in [control, batchControl] {
            let batch = try await adapter.importTranscript(row(attachment), documentID: UUID(),
                interface: .standaloneCLI, observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.coverageGaps.isEmpty)
            #expect(batch.recoveredReferences.count == 1)
        }

        var changes: [[String: Any]] = []
        for key in ["content", "stdout", "stderr"] {
            var changed = control
            changed[key] = "required hook output"
            changes.append(changed)
        }
        for (key, value) in [("stdout", "{\"additionalContext\":\"required text\"}" as Any),
                             ("exitCode", 1), ("exitCode", false), ("durationMs", false),
                             ("accountMemoryBatch", "unknown"), ("accountMemoryBatch", true), ("newPayload", "required text")] {
            var changed = control
            changed[key] = value
            changes.append(changed)
        }
        var missingOutput = control
        missingOutput.removeValue(forKey: "stdout")
        changes.append(missingOutput)
        for changed in changes {
            let batch = try await adapter.importTranscript(row(changed), documentID: UUID(),
                interface: .t3, observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty)
            #expect(batch.coverageGaps.map(\.reason) == [.unsupportedContent])
        }
    }

    @Test func recordedCLIHasEveryTypedContentIncludingNativeChild() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [])
        let batch = try await adapter.importTranscript(claudeFixture("claude-cli-recorded"), documentID: UUID(),
            interface: .standaloneCLI, observedAt: Date(), cryptography: crypto)
        #expect(batch.coverageGaps.isEmpty)
        let expected: [(ContentType, String)] = [(.userPrompt,"LEAKRET_SYNTHETIC_PROMPT"),
            (.intermediateResponse,"LEAKRET_SYNTHETIC_INTERMEDIATE"), (.finalResponse,"LEAKRET_SYNTHETIC_FINAL"),
            (.toolOutput,"LEAKRET_SYNTHETIC_SHELL_OK"),(.toolError,"LEAKRET_SYNTHETIC_SHELL_ERROR"),
            (.toolOutput,"LEAKRET_SYNTHETIC_MCP_OK"),(.toolError,"LEAKRET_SYNTHETIC_MCP_ERROR"),
            (.userPrompt,"LEAKRET_SYNTHETIC_CHILD_PROMPT"),(.finalResponse,"LEAKRET_SYNTHETIC_CHILD_FINAL")]
        for (kind, marker) in expected { #expect(batch.sources.contains { $0.record.metadata.contentType == kind && claudeText($0).contains(marker) }) }
        let shell = try #require(batch.sources.first { $0.record.metadata.contentType == .toolOutput && claudeText($0) == "LEAKRET_SYNTHETIC_SHELL_OK" })
        #expect(shell.record.metadata.identity.itemID == "tool:toolu_012erLjhTLTHij3fuVTcUM5a")
        #expect(shell.record.segments[0].id == "/result")
        let intermediate = try #require(batch.sources.first { $0.record.metadata.contentType == .intermediateResponse })
        #expect(intermediate.record.metadata.identity.itemID == "message:2ed8b897-f612-47da-be26-adb242c41669:block:0")
    }

    @Test func recordedT3HasTypedErrorsResponsesAndIndependentChild() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [])
        let parent = try await adapter.importTranscript(claudeFixture("claude-t3-recorded"), documentID: UUID(),
            interface: .t3, observedAt: Date(), cryptography: crypto)
        let child = try await adapter.importTranscript(claudeFixture("claude-t3-subagent-recorded"), documentID: UUID(),
            interface: .t3, observedAt: Date(), cryptography: crypto)
        let expected: [(ContentType,String)] = [(.userPrompt,"LEAKRET_T3_CLAUDE_PROMPT"),
            (.intermediateResponse,"LEAKRET_T3_CLAUDE_INTERMEDIATE"),(.finalResponse,"LEAKRET_T3_CLAUDE_FINAL"),
            (.toolOutput,"LEAKRET_T3_CLAUDE_SHELL_OK"),(.toolError,"LEAKRET_T3_CLAUDE_SHELL_ERROR"),
            (.toolOutput,"LEAKRET_T3_CLAUDE_MCP_OK"),(.toolError,"LEAKRET_T3_CLAUDE_MCP_ERROR")]
        for (kind, marker) in expected { #expect(parent.sources.contains { $0.record.metadata.contentType == kind && claudeText($0).contains(marker) }) }
        #expect(child.sources.contains { $0.record.metadata.contentType == .finalResponse && claudeText($0).contains("LEAKRET_T3_CLAUDE_SUBAGENT") })
        #expect(child.sources.allSatisfy { $0.record.metadata.identity.session.sessionID == "ba2f49c1-c827-4cb9-a6c3-a1820714ff07" })
        #expect(parent.sources.allSatisfy { $0.record.metadata.identity.session.sessionID == "dcff7474-9a41-42dd-96fc-f5d711641853" })
    }

    @Test func realBatchReplayUsesCanonicalBytesDatesAndIDsAcrossInterfaces() async throws {
        let directory = try claudeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.jsonl"); let transcript = try claudeFixture("claude-cli-recorded")
        try transcript.write(to: file)
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory])
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let history = try await adapter.importTranscript(transcript, documentID: UUID(), interface: .t3, observedAt: Date(), cryptography: crypto)
        let hooks = try claudeFixture("claude-cli-hooks-recorded").split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
        for var hook in hooks where hook["hook_event_name"] as? String == "PostToolBatch" {
            hook["transcript_path"] = file.path
            let batch = try await adapter.normalize(claudePacket(hook), capturedAt: Date(timeIntervalSince1970: 1_900_000_000), cryptography: crypto)
            #expect(batch.coverageGaps.isEmpty)
            for source in batch.sources {
                let original = try #require(history.sources.first { $0.record.metadata.identity == source.record.metadata.identity })
                #expect(source.record.revision == original.record.revision)
                #expect(source.record.segments == original.record.segments)
                #expect(source.record.metadata.contentTime == original.record.metadata.contentTime)
            }
        }
    }

    @Test func displayIDsAndIndividualOutputObjectsNeverInventAppearances() async throws {
        let directory = try claudeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.jsonl")
        try claudeRow(type: "assistant", content: [["type":"text","text":"synthetic"]], stop: "end_turn").write(to: file)
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory])
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let result = try await adapter.normalize(claudePacket(["session_id":"session","hook_event_name":"MessageDisplay",
            "transcript_path":file.path,"message_id":"unrelated-display-id","delta":"synthetic","final":true]), capturedAt: Date(), cryptography: crypto)
        #expect(result.sources.count == 1)
        #expect(result.sources[0].record.metadata.identity.itemID == "message:row:block:0")
    }

    @Test func mismatchedBatchFallsBackToHistoryWithVisibleCorrelationGap() async throws {
        let directory = try claudeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.jsonl")
        try claudeRow(content: [["type":"tool_result","tool_use_id":"call","content":"canonical","is_error":true]]).write(to: file)
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory])
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let batch = try await adapter.normalize(claudePacket(["session_id":"session","hook_event_name":"PostToolBatch","transcript_path":file.path,
            "tool_calls":[["tool_use_id":"call","tool_response":"different"]]]), capturedAt: Date(), cryptography: crypto)
        #expect(batch.coverageGaps.contains { $0.reason == .unresolvedCorrelation && $0.scope?.path == .versionedTranscript && $0.operation == .liveRead && $0.observedAt != nil })
        #expect(batch.sources.map(claudeText) == ["canonical"])
        #expect(batch.sources[0].record.metadata.contentType == .toolError)
    }

    @Test func hookBeforeTranscriptRowRemainsRetryable() async throws {
        let directory = try claudeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.jsonl"); try Data().write(to: file)
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory])
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        await #expect(throws: ClaudeCollectionError.awaitingTranscript) {
            try await adapter.normalize(claudePacket(["session_id":"session","hook_event_name":"PostToolBatch","transcript_path":file.path,
                "tool_calls":[["tool_use_id":"pending","tool_response":"not flushed"]]]), capturedAt: Date(), cryptography: crypto)
        }
    }

    @Test func individualSuccessAndFailureWaitForExactCallDespiteOldNonemptyTranscript() async throws {
        let directory = try claudeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
        let file=directory.appendingPathComponent("source.jsonl")
        try claudeRow(content:"old prompt").write(to:file)
        let adapter=try ClaudeAdapter(profileID:"test",agentVersion:"2.1.293",allowedTranscriptRoots:[directory])
        let crypto=try BackgroundCryptography.ephemeralForTesting()
        for event in ["PostToolUse","PostToolUseFailure"] {
            let packet=try claudePacket(["session_id":"session","hook_event_name":event,"transcript_path":file.path,"tool_use_id":"pending"])
            await #expect(throws:ClaudeCollectionError.awaitingTranscript) { try await adapter.normalize(packet,capturedAt:Date(),cryptography:crypto) }
        }
        try claudeRow(content:[["type":"tool_result","tool_use_id":"pending","content":[["type":"tool_reference","tool_name":"not output"]]]]).write(to:file)
        let batch=try await adapter.normalize(claudePacket(["session_id":"session","hook_event_name":"PostToolUse","transcript_path":file.path,"tool_use_id":"pending"]),capturedAt:Date(),cryptography:crypto)
        #expect(batch.sources.isEmpty)
        #expect(batch.coverageGaps.isEmpty)
    }

    /// A long session has more tool calls than the cursor remembers. A hook processed after a poll
    /// already read its row, as happens with any backlog, must still find its newest call.
    @Test(arguments: [false, true])
    func lateHookFindsTheNewestCallInALongSession(pollReadsItFirst: Bool) async throws {
        let directory = try claudeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.jsonl")
        let checkpoints = ClaudeCheckpointStore()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory],
            checkpointLookup: { await checkpoints.lookup($0) })
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        func result(_ id: String) throws -> Data {
            try claudeRow(uuid: "row-\(id)", content: [["type": "tool_result", "tool_use_id": id, "content": "synthetic output"]])
        }
        func poll() async throws -> CollectionBatch {
            let batch = try await adapter.normalize(claudePacket(["session_id": "session",
                "hook_event_name": "SpillcheckTranscriptPoll", "transcript_path": file.path]), capturedAt: Date(), cryptography: crypto)
            await checkpoints.keep(batch)
            return batch
        }
        // 2,100 earlier calls whose IDs sort after the newest one.
        try (0..<2100).map { try result("toolu_z\(String(format: "%05d", $0))") }.reduce(Data(), +).write(to: file)
        for _ in 0..<8 where try await poll().continuation != nil {}
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: result("toolu_a-newest")); try handle.close()
        if pollReadsItFirst { _ = try await poll() }
        let batch = try await adapter.normalize(claudePacket(["session_id": "session", "hook_event_name": "PostToolUse",
            "transcript_path": file.path, "tool_use_id": "toolu_a-newest"]), capturedAt: Date(), cryptography: crypto)
        #expect(batch.coverageGaps.isEmpty)
        #expect(batch.sources.contains { $0.record.metadata.identity.itemID == "tool:toolu_a-newest" } == !pollReadsItFirst)
    }

    @Test func subagentNudgeValidatesIndependentSessionAndRetainsItsOwnContext() async throws {
        let directory=try claudeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
        let parent=directory.appendingPathComponent("parent.jsonl"), child=directory.appendingPathComponent("child.jsonl")
        try claudeRow(session:"parent",content:"parent prompt").write(to:parent)
        try claudeRow(session:"child",type:"assistant",content:[["type":"text","text":"own child response"]],stop:"end_turn").write(to:child)
        let adapter=try ClaudeAdapter(profileID:"test",agentVersion:"2.1.293",allowedTranscriptRoots:[directory])
        let crypto=try BackgroundCryptography.ephemeralForTesting()
        let batch=try await adapter.normalize(claudePacket(["session_id":"parent","hook_event_name":"SubagentStop","transcript_path":parent.path,"agent_transcript_path":child.path]),capturedAt:Date(),cryptography:crypto)
        let source=try #require(batch.sources.first { $0.record.metadata.contentType == .finalResponse })
        #expect(source.record.metadata.identity.session.sessionID == "child")
        #expect(source.context?.sessionIdentifier == "child")
        #expect(source.context?.transcriptPath == child.path)
        #expect(batch.checkpoints.count == 2)
        #expect(batch.coverageGaps.isEmpty)
    }

    @Test func selectedChildPollRejectsAFileOutsideItsParentsSubagentDirectory() async throws {
        let directory = try claudeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("parent.jsonl"), unrelated = directory.appendingPathComponent("other.jsonl")
        try claudeRow(session: "parent", content: "FAKE_PARENT_PROMPT").write(to: parent)
        try claudeRow(session: "other", content: "FAKE_UNRELATED_PROMPT").write(to: unrelated)
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory])
        let batch = try await adapter.normalize(claudePacket(["session_id": "parent", "hook_event_name": "SpillcheckTranscriptPoll",
            "transcript_path": parent.path, "agent_transcript_path": unrelated.path]), capturedAt: Date(), cryptography: .ephemeralForTesting())
        #expect(batch.sources.isEmpty && batch.checkpoints.isEmpty)
        #expect(batch.coverageGaps.map(\.reason) == [.unresolvedCorrelation])
    }

    @Test func completeJSONWithoutNewlineCannotSatisfyToolOrPromptPreflushGuard() async throws {
        let directory=try claudeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
        let file=directory.appendingPathComponent("source.jsonl")
        let adapter=try ClaudeAdapter(profileID:"test",agentVersion:"2.1.293",allowedTranscriptRoots:[directory])
        let crypto=try BackgroundCryptography.ephemeralForTesting()
        let tool=try claudeRow(content:[["type":"tool_result","tool_use_id":"pending","content":"synthetic"]]).dropLast()
        try Data(tool).write(to:file)
        await #expect(throws:ClaudeCollectionError.awaitingTranscript) {
            try await adapter.normalize(claudePacket(["session_id":"session","hook_event_name":"PostToolUse","transcript_path":file.path,"tool_use_id":"pending"]),capturedAt:Date(),cryptography:crypto)
        }
        var prompt=try JSONSerialization.jsonObject(with:claudeRow(content:"prompt")) as! [String:Any]
        prompt["promptId"]="pending-prompt"
        try JSONSerialization.data(withJSONObject:prompt).write(to:file)
        await #expect(throws:ClaudeCollectionError.awaitingTranscript) {
            try await adapter.normalize(claudePacket(["session_id":"session","hook_event_name":"UserPromptSubmit","transcript_path":file.path,"prompt_id":"pending-prompt"]),capturedAt:Date(),cryptography:crypto)
        }
    }

    @Test func physicalRowBudgetAndChildFinalPersistenceRemainHeld() async throws {
        let directory=try claudeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
        let parent=directory.appendingPathComponent("parent.jsonl"), child=directory.appendingPathComponent("child.jsonl")
        let crypto=try BackgroundCryptography.ephemeralForTesting()
        try (Data([10])+claudeRow(content:[["type":"tool_result","tool_use_id":"pending","content":"text"]])).write(to:parent)
        let bounded=try ClaudeAdapter(profileID:"test",agentVersion:"2.1.293",allowedTranscriptRoots:[directory],limits:.init(maximumRows:1))
        let held = try await bounded.normalize(claudePacket(["session_id":"session","hook_event_name":"PostToolUse","tool_use_id":"pending","transcript_path":parent.path]),capturedAt:Date(),cryptography:crypto)
        #expect(held.sources.isEmpty && held.continuation != nil)
        try claudeRow(content:"parent prompt").write(to:parent)
        try claudeRow(content:"child prompt").write(to:child)
        let adapter=try ClaudeAdapter(profileID:"test",agentVersion:"2.1.293",allowedTranscriptRoots:[directory])
        await #expect(throws:ClaudeCollectionError.awaitingTranscript) {
            try await adapter.normalize(claudePacket(["session_id":"session","hook_event_name":"SubagentStop","transcript_path":parent.path,"agent_transcript_path":child.path]),capturedAt:Date(),cryptography:crypto)
        }
    }

    @Test func malformedMissingDatePartialWriteAndBudgetAreVisible() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [])
        let missing = try claudeRow(content:"do not fabricate",timestamp:nil)
        let data = Data("{broken}\n".utf8) + missing + Data("{\"type\":\"user\"".utf8)
        let batch = try await adapter.importTranscript(data, documentID: UUID(), interface: .standaloneCLI, observedAt: Date(), cryptography: crypto)
        #expect(batch.sources.isEmpty)
        #expect(Set(batch.coverageGaps.map(\.reason)) == [.malformedSource,.missingTimestamp,.incompleteMessage])
        #expect(batch.checkpoints[0].byteOffset == UInt64(data.count - 14))
        let small = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [], limits: .init(maximumBytes:32,maximumRowBytes:32))
        let bounded = try await small.importTranscript(missing, documentID: UUID(), interface:.standaloneCLI, observedAt: Date(), cryptography: crypto)
        #expect(bounded.coverageGaps.contains { $0.reason == .budgetExhausted && $0.scope?.path == .versionedTranscript && $0.observedAt != nil })
    }

    @Test func structuredStringsPreserveExactUTF8AndBinaryIsExcluded() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [])
        let output: [String:Any] = ["id":"é🙂", "data":"value\r\n", "binary":["type":"image","source":["data":"ignore"]]]
        let batch = try await adapter.importTranscript(claudeRow(content:[["type":"tool_result","tool_use_id":"call","content":output]]),
            documentID:UUID(),interface:.standaloneCLI,observedAt:Date(),cryptography:crypto)
        let segments = try #require(batch.sources.first).record.segments
        #expect(segments.map(\.id) == ["/result/data","/result/id"])
        #expect(segments.map(\.utf8) == [Data("value\r\n".utf8),Data("é🙂".utf8)])
    }

    @Test func distinctTranscriptUUIDsAndRangesRemainDistinctDespiteSameAPIMessageID() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID:"test",agentVersion:"2.1.293",allowedTranscriptRoots:[])
        let first = try claudeRow(uuid:"a",type:"assistant",content:[["type":"text","text":"same same"]],stop:"tool_use")
        let second = try claudeRow(uuid:"b",type:"assistant",content:[["type":"text","text":"same same"]],stop:"end_turn")
        let batch = try await adapter.importTranscript(first+second,documentID:UUID(),interface:.t3,observedAt:Date(),cryptography:crypto)
        #expect(Set(batch.sources.map(\.record.metadata.identity)).count == 2)
        #expect(batch.sources[0].record.metadata.contentType == .intermediateResponse)
        #expect(batch.sources[1].record.metadata.contentType == .finalResponse)
    }

    @Test func unfamiliarVersionCollectsKnownContentAndForeignRootRemainsRejected() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID:"test",agentVersion:"2.1.294",allowedTranscriptRoots:[])
        let batch = try await adapter.importTranscript(claudeRow(content:"synthetic"),documentID:UUID(),interface:.t3,observedAt:Date(),cryptography:crypto)
        #expect(batch.coverageGaps.isEmpty && batch.sources.count == 1)
        #expect(adapter.capabilities(interface:.t3).allSatisfy { $0.validation == .unverified && $0.canObserveActiveSession })
        let supported = try ClaudeAdapter(profileID:"test",agentVersion:"2.1.293",allowedTranscriptRoots:[])
        let unsafe = try await supported.normalize(claudePacket(["session_id":"session","hook_event_name":"Stop","transcript_path":"/not/allowed.jsonl"]),capturedAt:Date(),cryptography:crypto)
        #expect(unsafe.coverageGaps.count == 1 && unsafe.coverageGaps.first?.reason == .sourceUnavailable
            && unsafe.coverageGaps.first?.scope?.profileID == "test" && unsafe.coverageGaps.first?.observedAt != nil)
    }

    @Test func producerVersionIsIndependentFromSelectedExecutableAndAcceptanceEvidence() async throws {
        let crypto=try BackgroundCryptography.ephemeralForTesting()
        let adapter=try ClaudeAdapter(profileID:"test",agentVersion:"2.1.293",allowedTranscriptRoots:[])
        var row=try JSONSerialization.jsonObject(with:claudeRow(content:"synthetic")) as! [String:Any]
        row["version"]="2.1.294"
        let data=try JSONSerialization.data(withJSONObject:row)+Data([10])
        let batch=try await adapter.importTranscript(data,documentID:UUID(),interface:.t3,observedAt:Date(),cryptography:crypto)
        #expect(batch.sources.count == 1 && batch.coverageGaps.isEmpty)
        #expect(batch.sources.first?.record.metadata.origin.agentVersion == "2.1.294")
        #expect(CollectionCompatibility.recordedEvidence(provider:.claudeCode,interface:.t3,producerVersion:"2.1.294") == .unverified)
    }

    @Test(arguments: ["2.1.295", "2.2.0", "3.0.0"])
    func releaseMetadataChangesPreserveCanonicalIdentitiesAndBytes(version: String) async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting(), document = UUID()
        let original = try ClaudeAdapter(profileID:"test",agentVersion:"2.1.293",allowedTranscriptRoots:[])
        let updated = try ClaudeAdapter(profileID:"test",agentVersion:version,allowedTranscriptRoots:[])
        var row = try JSONSerialization.jsonObject(with:claudeRow(content:"é🙂 exact\r\n")) as! [String:Any]
        row["version"] = "2.1.293"
        let first = try await original.importTranscript(JSONSerialization.data(withJSONObject:row)+Data([10]),documentID:document,
            interface:.standaloneCLI,observedAt:Date(),cryptography:crypto)
        row["version"] = version; row["newEnvelope"] = ["metadata":"not model-visible"]
        let second = try await updated.importTranscript(JSONSerialization.data(withJSONObject:row)+Data([10]),documentID:document,
            interface:.t3,observedAt:Date(),cryptography:crypto)
        let a = try #require(first.sources.first).record, b = try #require(second.sources.first).record
        #expect(first.coverageGaps.isEmpty && second.coverageGaps.isEmpty)
        #expect(a.metadata.identity == b.metadata.identity && a.revision == b.revision && a.segments == b.segments)
        #expect(b.metadata.origin.agentVersion == version)
    }

    @Test func mixedProducerHistoryRetainsActualAndUnknownProvenance() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID:"test",agentVersion:"2.1.295",allowedTranscriptRoots:[])
        let batch = try await adapter.importTranscript(claudeFixture("claude-mixed-producers"),documentID:UUID(),
            interface:.standaloneCLI,observedAt:Date(),cryptography:crypto)
        #expect(batch.coverageGaps.isEmpty && batch.sources.count == 3)
        #expect(batch.sources.map { $0.record.metadata.origin.agentVersion } == ["2.1.293", "2.1.295", "unknown"])
        #expect(Set(batch.sources.map { $0.record.metadata.identity.itemID }).count == 3)
    }

    @Test func unknownAndMalformedBlocksDoNotSuppressReadableSiblingContent() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID:"test",agentVersion:"2.1.295",allowedTranscriptRoots:[])
        let data = try claudeRow(content:[["type":"future_output","payload":"unrecognized"],
            ["type":"tool_result","tool_use_id":"bad","is_error":"true","content":"bad semantics"],
            ["type":"tool_result","tool_use_id":"changed-payload","content":42],
            ["type":"text","text":"readable prompt"]])
            + claudeRow(uuid:"final",type:"assistant",content:[["type":"text","text":"readable final"]],stop:"end_turn")
        let batch = try await adapter.importTranscript(data,documentID:UUID(),interface:.t3,observedAt:Date(),cryptography:crypto)
        #expect(Set(batch.coverageGaps.map(\.reason)) == [.unsupportedContent, .malformedSource])
        #expect(batch.sources.map(claudeText) == ["readable prompt", "readable final"])
    }

    @Test func missingConflictingRoleAndChangedStopTypeProduceControlledGaps() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID:"test",agentVersion:"2.1.295",allowedTranscriptRoots:[])
        var bytes = Data()
        for role in [NSNull(), "assistant"] as [Any] {
            var row = try JSONSerialization.jsonObject(with:claudeRow(content:"cannot attribute")) as! [String:Any]
            row["message"] = ["role":role,"content":"cannot attribute"]
            bytes += try JSONSerialization.data(withJSONObject:row)+Data([10])
        }
        var changed = try JSONSerialization.jsonObject(with:claudeRow(type:"assistant",content:"cannot classify")) as! [String:Any]
        changed["message"] = ["role":"assistant","content":"cannot classify","stop_reason":42]
        bytes += try JSONSerialization.data(withJSONObject:changed)+Data([10])
        let batch = try await adapter.importTranscript(bytes,documentID:UUID(),interface:.standaloneCLI,observedAt:Date(),cryptography:crypto)
        #expect(batch.sources.isEmpty && Set(batch.coverageGaps.map(\.reason)) == [.malformedSource])
    }

    @Test func additiveToolPayloadTextKeepsOriginalRangesAndScansNewStrings() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID:"test",agentVersion:"2.1.295",allowedTranscriptRoots:[])
        let payload: [String:Any] = ["type":"text","text":"é🙂 original","extra/output":"new exact\r\n"]
        let batch = try await adapter.importTranscript(claudeRow(content:[["type":"tool_result","tool_use_id":"call","content":payload]]),
            documentID:UUID(),interface:.standaloneCLI,observedAt:Date(),cryptography:crypto)
        let record = try #require(batch.sources.first).record
        #expect(batch.coverageGaps.isEmpty)
        #expect(record.segments.map(\.id) == ["/result/extra~1output", "/result/text"])
        #expect(record.segments.map(\.utf8) == [Data("new exact\r\n".utf8), Data("é🙂 original".utf8)])
        let range = try CanonicalLocation(segmentID:"/result/text",range:.init(0,Data("é🙂".utf8).count))
        #expect(try range.extract(from:record) == Data("é🙂".utf8))
    }

    @Test func conflictingToolResultsLeaveOtherContentCollecting() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID:"test",agentVersion:"2.1.295",allowedTranscriptRoots:[])
        let data = try claudeRow(uuid:"a",content:[["type":"tool_result","tool_use_id":"same","content":"first"]])
            + claudeRow(uuid:"b",content:[["type":"tool_result","tool_use_id":"same","content":"second"]])
            + claudeRow(uuid:"c",content:"readable prompt")
        let batch = try await adapter.importTranscript(data,documentID:UUID(),interface:.standaloneCLI,observedAt:Date(),cryptography:crypto)
        #expect(batch.sources.map(claudeText) == ["readable prompt"])
        #expect(Set(batch.coverageGaps.map(\.reason)) == [.unresolvedCorrelation])
    }

    @Test func emptyInitialPromptDisplayAndStopRemainRetryableUntilTranscriptExists() async throws {
        let directory = try claudeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
        let file = directory.appendingPathComponent("source.jsonl"); try Data().write(to:file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID:"test",agentVersion:"2.1.295",allowedTranscriptRoots:[directory])
        for event in ["UserPromptSubmit", "MessageDisplay", "Stop"] {
            let packet = try claudePacket(["hook_event_name":event,"session_id":"session","transcript_path":file.path])
            await #expect(throws:ClaudeCollectionError.awaitingTranscript) {
                try await adapter.normalize(packet,capturedAt:Date(),cryptography:crypto)
            }
        }
        try claudeRow(content:"persisted prompt").write(to:file)
        let batch = try await adapter.normalize(claudePacket(["hook_event_name":"UserPromptSubmit","session_id":"session","transcript_path":file.path]),
            capturedAt:Date(),cryptography:crypto)
        #expect(batch.sources.map(claudeText) == ["persisted prompt"])
    }

    @Test func readableSiblingCannotResolveAnOmittedBlockButFullRowReparseCan() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting(), document = UUID()
        let adapter = try ClaudeAdapter(profileID:"test",agentVersion:"2.1.295",allowedTranscriptRoots:[])
        let omitted = try claudeRow(content:[["type":"text","text":"readable sibling"],
            ["type":"tool_result","tool_use_id":"native-call","is_error":"changed","content":"omitted output"]])
        let before = try await adapter.importTranscript(omitted,documentID:document,interface:.standaloneCLI,
            observedAt:Date(),cryptography:crypto)
        let gap = try #require(before.coverageGaps.first)
        #expect(before.sources.count == 1 && before.recoveredReferences.isEmpty)
        #expect(gap.scope?.profileID == "test" && gap.contentType == .toolOutput && gap.isRequiredFormatFailure == true)
        let originalReference = try #require(gap.recovery)
        let complete = try claudeRow(content:[["type":"text","text":"readable sibling"],
            ["type":"tool_result","tool_use_id":"native-call","is_error":false,"content":"omitted output"]])
        let after = try await adapter.importTranscript(complete,documentID:document,interface:.t3,
            observedAt:Date(),cryptography:crypto)
        #expect(after.coverageGaps.isEmpty && after.sources.count == 2)
        #expect(after.recoveredReferences.contains { $0.identifiesSameLocation(as:originalReference) })
        #expect(before.sources.first?.record.metadata.identity == after.sources.first?.record.metadata.identity)
        #expect(before.sources.first?.record.revision == after.sources.first?.record.revision)
    }
}
