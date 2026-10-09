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
                            "message": ["content": content, "stop_reason": stop as Any? ?? NSNull()]]
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
        #expect(batch.coverageGaps.contains(.init(reason: .unresolvedCorrelation)))
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
        #expect(bounded.coverageGaps.contains(.init(reason:.budgetExhausted)))
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

    @Test func unsupportedVersionAndForeignRootCannotClaimConnectedCoverage() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID:"test",agentVersion:"2.1.294",allowedTranscriptRoots:[])
        let batch = try await adapter.importTranscript(claudeRow(content:"synthetic"),documentID:UUID(),interface:.t3,observedAt:Date(),cryptography:crypto)
        #expect(batch.coverageGaps == [.init(reason:.unsupportedVersion)])
        #expect(adapter.capabilities(interface:.t3).allSatisfy { $0.validation == .unsupported })
        let supported = try ClaudeAdapter(profileID:"test",agentVersion:"2.1.293",allowedTranscriptRoots:[])
        let unsafe = try await supported.normalize(claudePacket(["session_id":"session","hook_event_name":"Stop","transcript_path":"/not/allowed.jsonl"]),capturedAt:Date(),cryptography:crypto)
        #expect(unsafe.coverageGaps == [.init(reason:.sourceUnavailable)])
    }

    @Test func SDKTranscriptVersionCannotBorrowStandaloneCompatibilityClaim() async throws {
        let crypto=try BackgroundCryptography.ephemeralForTesting()
        let adapter=try ClaudeAdapter(profileID:"test",agentVersion:"2.1.293",allowedTranscriptRoots:[])
        var row=try JSONSerialization.jsonObject(with:claudeRow(content:"synthetic")) as! [String:Any]
        row["version"]="2.1.294"
        let data=try JSONSerialization.data(withJSONObject:row)+Data([10])
        let batch=try await adapter.importTranscript(data,documentID:UUID(),interface:.t3,observedAt:Date(),cryptography:crypto)
        #expect(batch.sources.isEmpty)
        #expect(batch.coverageGaps == [.init(reason:.unsupportedVersion)])
    }
}
