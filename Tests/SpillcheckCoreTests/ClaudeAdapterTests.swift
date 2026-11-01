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

    /// Records Claude Code 2.1.306+ writes beside messages, in the exact shapes observed in genuine transcripts.
    private static var observedRequestAndJournalRecords: [[String: Any]] { [
        ["type": "api-request", "sessionId": "session", "id": "req-2", "timestamp": "2026-10-29T10:00:00Z",
         "version": "2.1.312", "querySource": "sdk", "shapeHash": "shape-1", "params": ["max_tokens": 1],
         "keep": 1, "tail": [String(repeating: "a", count: 64)], "cacheControl": [], "requestDigest": "digest",
         "base": "req-1", "agentId": "agent"],
        ["type": "api-request-shape", "sessionId": "session", "shapeHash": "shape-1", "timestamp": "2026-10-29T10:00:00Z",
         "version": "2.1.312", "shape": ["system": [["type": "text", "text": "FAKE_SYSTEM"]],
                                         "tools": [["name": "Read", "description": "FAKE_TOOL", "input_schema": [:]]]]],
        ["type": "api-request-blob", "sessionId": "session", "hash": String(repeating: "b", count: 64), "agentId": "agent",
         "message": ["role": "system", "content": [["type": "text", "text": "FAKE_REMINDER"],
                                                   ["type": "tool_addition", "tools": ["Read"]]]]],
        ["type": "api-request-blob", "sessionId": "session", "hash": String(repeating: "c", count: 64),
         "message": ["role": "assistant", "content": [["type": "thinking", "thinking": "FAKE"],
                                                      ["type": "tool_use", "id": "toolu", "name": "Read", "input": [:]]]]],
        ["type": "api-request-blob", "sessionId": "session", "hash": String(repeating: "d", count: 64),
         "message": ["role": "user", "content": "FAKE_PROMPT_COPY"]],
        ["type": "pr-link", "sessionId": "session", "timestamp": "2026-10-29T10:00:00Z", "prNumber": 1,
         "prRepository": "owner/repo", "prUrl": "https://example.invalid/pull/1"],
        ["type": "tools-used", "sessionId": "session", "tools": ["Read"]],
        ["type": "isolation-latch", "sessionId": "session", "side": "main"],
        ["type": "launched"],
        ["type": "started", "agentId": "agent", "key": "key", "label": "label", "phase": "Phase"],
        ["type": "result", "agentId": "agent", "key": "key", "result": ["summary": "FAKE_RESULT_COPY"], "toolsUsed": ["Read"]],
        ["type": "failed", "agentId": "agent", "key": "key"],
    ] }

    @Test func observedRequestLogsAndWorkflowJournalsAreRecognizedWithoutAnalysis() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.312", allowedTranscriptRoots: [])
        let document = UUID(), prompt = try claudeRow(content: "required prompt")
        let original = try await adapter.importTranscript(prompt, documentID: document,
            interface: .standaloneCLI, observedAt: Date(), cryptography: crypto)
        var data = Data()
        for record in Self.observedRequestAndJournalRecords { data += try JSONSerialization.data(withJSONObject: record) + Data([10]) }
        // Effort-mode reminders arrive beside them as harness context attachments.
        for reminder in [["type": "ultra_effort_enter", "reminderType": "ultra"], ["type": "ultra_effort_exit"]] {
            data += try JSONSerialization.data(withJSONObject: ["type": "attachment", "sessionId": "session", "attachment": reminder]) + Data([10])
        }
        let batch = try await adapter.importTranscript(data + prompt, documentID: document,
            interface: .standaloneCLI, observedAt: Date(), cryptography: crypto)
        #expect(batch.coverageGaps.isEmpty)
        #expect(batch.recoveredReferences.count == Self.observedRequestAndJournalRecords.count + 3)
        #expect(batch.sources.map(\.record.metadata.identity) == original.sources.map(\.record.metadata.identity))
        #expect(batch.sources.map(\.record.segments) == original.sources.map(\.record.segments))
    }

    @Test func changedRequestLogsAndWorkflowJournalsRemainVisibleAsGaps() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.312", allowedTranscriptRoots: [])
        var changes: [[String: Any]] = []
        for record in Self.observedRequestAndJournalRecords {
            var added = record; added["unknownPayload"] = "required text"; changes.append(added)
            if let key = record.keys.first(where: { $0 != "type" && $0 != "agentId" && $0 != "base" && $0 != "toolsUsed" }) {
                var removed = record; removed.removeValue(forKey: key); changes.append(removed)
            }
        }
        changes.append(["type": "api-request-blob", "sessionId": "session", "hash": "e",
                        "message": ["role": "user", "content": [["type": "future_block", "payload": "required text"]]]])
        var inlineTail = Self.observedRequestAndJournalRecords[0]; inlineTail["tail"] = [["role": "user", "content": "required text"]]
        changes.append(inlineTail)
        changes.append(["type": "api-request-blob", "sessionId": "session", "hash": "f",
                        "message": ["role": "developer", "content": "required text"]])
        for changed in changes {
            let data = try JSONSerialization.data(withJSONObject: changed) + Data([10])
            let batch = try await adapter.importTranscript(data, documentID: UUID(),
                interface: .t3, observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty)
            #expect(batch.coverageGaps.count == 1, "\(changed.keys.sorted())")
        }
    }

    @Test func structuredOutputAttachmentIsAnalyzedAsTheAgentsFinalResponse() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.312", allowedTranscriptRoots: [])
        let data = try JSONSerialization.data(withJSONObject: ["type": "attachment", "uuid": "result-row",
            "sessionId": "session", "timestamp": "2026-10-29T10:00:00Z", "version": "2.1.312",
            "attachment": ["type": "structured_output", "toolUseID": "toolu_final",
                           "data": ["summary": "FAKE_STRUCTURED_SUMMARY", "findings": ["FAKE_STRUCTURED_FINDING"],
                                    // A schema may use "type" for its own fields; it is not a media marker here.
                                    "evidence": [["type": "image", "description": "FAKE_TYPED_FIELD"]]]]]) + Data([10])
        let batch = try await adapter.importTranscript(data, documentID: UUID(), interface: .t3,
            observedAt: Date(), cryptography: crypto)
        #expect(batch.coverageGaps.isEmpty)
        let source = try #require(batch.sources.first)
        #expect(batch.sources.count == 1 && source.record.metadata.contentType == .finalResponse)
        #expect(source.record.metadata.identity.itemID == "structured-output:toolu_final")
        #expect(source.record.metadata.identity.session.sessionID == "session")
        #expect(claudeText(source).contains("FAKE_STRUCTURED_SUMMARY") && claudeText(source).contains("FAKE_STRUCTURED_FINDING"))
        #expect(claudeText(source).contains("FAKE_TYPED_FIELD"))
    }

    @Test func changedOrOutOfWindowStructuredOutputIsNeverSilentlyAnalyzed() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.312", allowedTranscriptRoots: [])
        let row: [String: Any] = ["type": "attachment", "uuid": "result-row", "sessionId": "session",
            "timestamp": "2026-10-29T10:00:00Z", "version": "2.1.312",
            "attachment": ["type": "structured_output", "toolUseID": "toolu_final", "data": ["summary": "FAKE_SUMMARY"]]]
        func attachment(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
            var copy = row, value = row["attachment"] as! [String: Any]
            change(&value); copy["attachment"] = value; return copy
        }
        var untimed = row; untimed.removeValue(forKey: "timestamp")
        let changed: [[String: Any]] = [untimed,
            attachment { $0["extra"] = "required text" }, attachment { $0["data"] = "required text" },
            attachment { $0.removeValue(forKey: "toolUseID") }]
        for change in changed {
            let batch = try await adapter.importTranscript(JSONSerialization.data(withJSONObject: change) + Data([10]),
                documentID: UUID(), interface: .t3, observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty)
            #expect(batch.coverageGaps.count == 1 && batch.coverageGaps.allSatisfy { $0.isRequiredFormatFailure == true })
        }
        // An audit reads only content inside its window, and a result outside it is not an omission.
        let audit = try HistoricalAuditContext(reason: .resume, endingAt: ISO8601DateFormatter().date(from: "2026-10-08T00:00:00Z")!)
        let outside = try await adapter.importTranscript(JSONSerialization.data(withJSONObject: row) + Data([10]),
            documentID: UUID(), interface: .t3, observedAt: Date(), provenance: .historical(audit), cryptography: crypto)
        #expect(outside.sources.isEmpty && outside.coverageGaps.isEmpty)
    }

    /// One row of each attachment kind that puts text in front of the model or the user, with the
    /// field shapes of Claude Code 2.1.29x to 2.1.31x transcripts and synthetic values.
    private static var contentAttachments: [(uuid: String, attachment: [String: Any])] { [
        ("hook-context", ["type": "hook_additional_context", "hookName": "SubagentStart", "hookEvent": "SubagentStart",
                          "toolUseID": "toolu_hook", "content": ["FAKE_HOOK_CONTEXT_ONE", "FAKE_HOOK_CONTEXT_TWO"]]),
        ("edited-file", ["type": "edited_text_file", "filename": "/tmp/fixture/FAKE_EDITED_PATH.swift",
                         "snippet": "     1\tlet token = \"FAKE_EDITED_SNIPPET\""]),
        ("edited-file-shown", ["type": "edited_text_file", "filename": "/tmp/fixture/b.swift", "displayPath": "b.swift",
                               "snippet": "FAKE_EDITED_DISPLAYED"]),
        ("mentioned-file", ["type": "file", "filename": "/tmp/fixture/FAKE_FILE_PATH.txt", "displayPath": "FAKE_FILE_PATH.txt",
                            "content": ["type": "text", "file": ["filePath": "/tmp/fixture/FAKE_FILE_PATH.txt",
                                "content": "FAKE_MENTIONED_FILE", "numLines": 1, "startLine": 1, "totalLines": 1]]]),
        ("diagnostics", ["type": "diagnostics", "isNew": true, "files": [["uri": "file:///tmp/FAKE_DIAGNOSTIC_URI.swift",
            "diagnostics": [["message": "FAKE_DIAGNOSTIC_ONE", "severity": "Error", "source": "FAKE_DIAGNOSTIC_SOURCE",
                             "range": ["start": ["line": 1, "character": 2], "end": ["line": 1, "character": 9]]],
                            ["message": "FAKE_DIAGNOSTIC_TWO", "severity": "Warning", "source": "swift", "code": "FAKE_DIAGNOSTIC_CODE",
                             "range": ["start": ["line": 3, "character": 0], "end": ["line": 3, "character": 4]]]]]]]),
        ("task-notification", ["type": "queued_command", "commandMode": "task-notification",
            "prompt": "<task-notification>FAKE_TASK_NOTIFICATION</task-notification>",
            "origin": ["kind": "task-notification", "producer": "session-task"], "delivery_id": "delivery",
            "runId": "run", "source_uuid": "source", "timestamp": "2026-10-31T10:00:00Z",
            "usage": ["durationMs": 1200, "toolUses": 3, "totalTokens": 4096]]),
        ("hook-error", ["type": "hook_non_blocking_error", "hookName": "PostToolUse:Bash", "hookEvent": "PostToolUse",
                        "toolUseID": "toolu_hook", "command": "FAKE_HOOK_COMMAND", "exitCode": 1, "durationMs": 40,
                        "stdout": "", "stderr": "FAKE_HOOK_STDERR", "accountMemoryBatch": false]),
    ] }

    private static func attachmentRow(_ uuid: String, _ attachment: [String: Any]) throws -> Data {
        // Newer versions also save what the model was shown; it repeats the fields already read.
        try JSONSerialization.data(withJSONObject: ["type": "attachment", "uuid": uuid, "sessionId": "session",
            "timestamp": "2026-10-31T10:00:00Z", "version": "2.1.312", "renderedRole": "system",
            "rendered": [["content": "FAKE_RENDERED_COPY"]], "attachment": attachment]) + Data([10])
    }

    @Test func attachmentsThatShowTextAreAnalyzedFromTheirContentFields() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.312", allowedTranscriptRoots: [])
        var data = Data()
        for row in Self.contentAttachments { data += try Self.attachmentRow(row.uuid, row.attachment) }
        // A cancelled hook and an edit notice without a snippet carry no text.
        data += try Self.attachmentRow("hook-cancelled", ["type": "hook_cancelled", "hookName": "PostToolUse:Bash",
            "hookEvent": "PostToolUse", "toolUseID": "toolu_hook"])
        data += try Self.attachmentRow("hook-timed-out", ["type": "hook_cancelled", "hookName": "Stop", "hookEvent": "Stop",
            "toolUseID": "toolu_hook", "command": "fixture-hook", "durationMs": 60000, "timedOut": true, "timeoutMs": 60000,
            "accountMemoryBatch": false])
        data += try Self.attachmentRow("edited-empty", ["type": "edited_text_file", "filename": "/tmp/fixture/c.swift", "snippet": ""])
        let batch = try await adapter.importTranscript(data, documentID: UUID(), interface: .t3,
            observedAt: Date(), cryptography: crypto)
        #expect(batch.coverageGaps.isEmpty)
        #expect(batch.recoveredReferences.count == Self.contentAttachments.count + 3)
        let sources = Dictionary(uniqueKeysWithValues: batch.sources.map { ($0.record.metadata.identity.itemID, $0) })
        func analyzed(_ uuid: String) -> (ContentType?, [String]) {
            guard let source = sources["attachment:\(uuid)"] else { return (nil, []) }
            return (source.record.metadata.contentType, source.record.segments.map { String(decoding: $0.utf8, as: UTF8.self) })
        }
        #expect(sources.count == Self.contentAttachments.count)
        #expect(analyzed("hook-context") == (.userPrompt, ["FAKE_HOOK_CONTEXT_ONE", "FAKE_HOOK_CONTEXT_TWO"]))
        #expect(analyzed("edited-file") == (.toolOutput, ["     1\tlet token = \"FAKE_EDITED_SNIPPET\""]))
        #expect(analyzed("edited-file-shown") == (.toolOutput, ["FAKE_EDITED_DISPLAYED"]))
        #expect(analyzed("mentioned-file") == (.userPrompt, ["FAKE_MENTIONED_FILE"]))
        #expect(analyzed("diagnostics") == (.toolOutput, ["FAKE_DIAGNOSTIC_ONE", "FAKE_DIAGNOSTIC_TWO"]))
        #expect(analyzed("task-notification") == (.toolOutput, ["<task-notification>FAKE_TASK_NOTIFICATION</task-notification>"]))
        #expect(analyzed("hook-error") == (.toolError, ["FAKE_HOOK_STDERR"]))
        #expect(sources["attachment:hook-context"]?.record.segments.map(\.id) == ["/attachment/content/0", "/attachment/content/1"])
        #expect(sources["attachment:mentioned-file"]?.record.segments.map(\.id) == ["/attachment/content/file/content"])
        #expect(sources["attachment:diagnostics"]?.record.segments.map(\.id)
            == ["/attachment/files/0/diagnostics/0/message", "/attachment/files/0/diagnostics/1/message"])
        // Paths, commands, diagnostic labels and the rendered copy are not analyzed.
        let text = batch.sources.map(claudeText).joined()
        for unanalyzed in ["FAKE_EDITED_PATH", "FAKE_FILE_PATH", "FAKE_DIAGNOSTIC_URI", "FAKE_DIAGNOSTIC_SOURCE",
                           "FAKE_DIAGNOSTIC_CODE", "FAKE_HOOK_COMMAND", "FAKE_RENDERED_COPY"] {
            #expect(!text.contains(unanalyzed), "\(unanalyzed)")
        }
        #expect(batch.sources.allSatisfy { $0.record.metadata.identity.session.sessionID == "session" })
    }

    @Test func changedOrUncorrelatedContentAttachmentsRemainVisibleGaps() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.312", allowedTranscriptRoots: [])
        func changed(_ uuid: String, _ change: (inout [String: Any]) -> Void) -> (String, [String: Any]) {
            var attachment = Self.contentAttachments.first { $0.uuid == uuid }!.attachment
            change(&attachment)
            return (uuid, attachment)
        }
        let shapes: [(String, [String: Any])] = [
            changed("hook-context") { $0["content"] = [42] },
            changed("hook-context") { $0["extra"] = "new text" },
            changed("edited-file") { $0["snippet"] = ["FAKE"] },
            changed("edited-file") { $0.removeValue(forKey: "filename") },
            changed("mentioned-file") { $0["content"] = ["type": "image", "file": ["base64": "AAAA"]] },
            changed("mentioned-file") { $0["content"] = "FAKE_FLAT_CONTENT" },
            changed("diagnostics") { $0["files"] = [["uri": "file:///a", "diagnostics": [["message": 7]]]] },
            changed("diagnostics") { $0["files"] = [["uri": "file:///a", "notes": "new text", "diagnostics": []]] },
            changed("task-notification") { $0["isMeta"] = true },
            changed("task-notification") { $0["commandMode"] = "new-mode" },
            changed("task-notification") { $0["origin"] = ["kind": "task-notification", "body": "new text"] },
            changed("hook-error") { $0.removeValue(forKey: "stderr") },
            changed("hook-error") { $0["stdout"] = ["FAKE"] },
            ("hook-cancelled", ["type": "hook_cancelled", "hookName": "Stop", "hookEvent": "Stop",
                                "toolUseID": "toolu_hook", "stderr": "new text"]),
        ]
        for (uuid, attachment) in shapes {
            let batch = try await adapter.importTranscript(Self.attachmentRow(uuid, attachment), documentID: UUID(),
                interface: .t3, observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty, "\(uuid)")
            #expect(batch.coverageGaps.map(\.reason) == [.unsupportedContent], "\(uuid)")
        }
        // Content needs the row's identity and time like any message.
        for removed in ["uuid", "sessionId", "timestamp"] {
            var row = try #require(try JSONSerialization.jsonObject(
                with: Self.attachmentRow("edited-file", Self.contentAttachments[1].attachment)) as? [String: Any])
            row.removeValue(forKey: removed)
            let batch = try await adapter.importTranscript(JSONSerialization.data(withJSONObject: row) + Data([10]),
                documentID: UUID(), interface: .t3, observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty, "\(removed)")
            #expect(batch.coverageGaps.count == 1 && batch.coverageGaps.allSatisfy { $0.isRequiredFormatFailure == true
                && $0.contentType == .toolOutput }, "\(removed)")
        }
        // An audit reads only content inside its window.
        let audit = try HistoricalAuditContext(reason: .resume, endingAt: ISO8601DateFormatter().date(from: "2026-10-08T00:00:00Z")!)
        let outside = try await adapter.importTranscript(Self.attachmentRow("edited-file", Self.contentAttachments[1].attachment),
            documentID: UUID(), interface: .t3, observedAt: Date(), provenance: .historical(audit), cryptography: crypto)
        #expect(outside.sources.isEmpty && outside.coverageGaps.isEmpty)
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

    @Test func queuedPromptsNotificationsAndMentionedFilesAreCollectedAndHookOutputStaysVisible() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.295", allowedTranscriptRoots: [])
        let batch = try await adapter.importTranscript(claudeFixture("claude-attachment-envelopes"), documentID: UUID(),
            interface: .standaloneCLI, observedAt: Date(), cryptography: crypto)
        let prompts = batch.sources.filter { $0.record.metadata.contentType == .userPrompt }
        #expect(prompts.map(claudeText) == ["SPILLCHECK_ATTACHMENT_PROMPT", "SPILLCHECK_QUEUED_PROMPT", "SPILLCHECK_QUEUED_BLOCK",
                                            "SPILLCHECK_MENTIONED_FILE"])
        #expect(prompts.map(\.record.metadata.identity.itemID)
            == ["prompt:prompt-row:block:0", "prompt:queued-string:block:0", "prompt:queued-blocks:block:0",
                "attachment:mentioned-file"])
        #expect(batch.sources.contains { $0.record.metadata.contentType == .finalResponse && claudeText($0) == "SPILLCHECK_ATTACHMENT_FINAL" })
        #expect(batch.sources.contains { $0.record.metadata.contentType == .toolOutput && claudeText($0) == "SPILLCHECK_TASK_NOTIFICATION" })
        // Context is recognized without content. A successful hook's output stays an unscanned gap.
        #expect(!batch.sources.contains { claudeText($0).contains("SPILLCHECK_CONTEXT") })
        #expect(batch.coverageGaps.count == 1)
        #expect(batch.coverageGaps.allSatisfy { $0.reason == .unsupportedContent && $0.isRequiredFormatFailure != true })
        #expect(batch.recoveredReferences.count == 8)
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
