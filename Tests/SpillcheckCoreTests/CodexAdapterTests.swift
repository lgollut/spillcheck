import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

actor CodexTestAuthority {
    var choices: [SessionIdentity: CollectionAuthorityChoice] = [:]
    func lookup(_ session: SessionIdentity) -> CollectionAuthorityChoice? { choices[session] }
    func record(_ choice: CollectionAuthorityChoice) throws {
        if let old = choices[choice.session], old.authorityID != choice.authorityID {
            throw CodexCollectionError.authorityConflict
        }
        choices[choice.session] = choice
    }
}
actor CodexTestHistory: CodexHistoryReading {
    var metadata: [String: CodexJSON] = [:]
    var items: [String: [CodexHistoryPage]] = [:]
    var descending: [String: CodexHistoryPage] = [:]
    var turns: [String: CodexHistoryPage] = [:]
    var listings: [Bool: [CodexHistoryPage]] = [:]
    var calls: [String] = []
    var failures: [String: CodexHistoryError] = [:]
    func configureFailure(_ method: String, error: CodexHistoryError?) { failures[method] = error }
    func configure(_ id: String, thread: CodexJSON, pages: [CodexHistoryPage], turns: CodexHistoryPage = .init(data: [])) {
        metadata[id] = thread; items[id] = pages; self.turns[id] = turns
    }
    func configureListings(_ pages: [CodexHistoryPage], archived: Bool) { listings[archived] = pages }
    func configureDescending(_ id: String, page: CodexHistoryPage) { descending[id] = page }
    func readThread(_ threadID: String) throws -> CodexThreadRead {
        calls.append("read:\(threadID)")
        if let failure = failures["read:\(threadID)"] { throw failure }
        guard let thread = metadata[threadID] else { throw CodexHistoryError.unavailable }
        return .init(thread: thread, bytesRead: 64)
    }
    func listThreads(cursor: String?, limit: Int, archived: Bool) throws -> CodexHistoryPage {
        calls.append("list:\(archived)")
        if let failure = failures["list"] { throw failure }
        return listings[archived]?[Int(cursor ?? "0") ?? 0] ?? .init(data: [])
    }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection) throws -> CodexHistoryPage {
        calls.append("turns:\(threadID)")
        if let failure = failures["turns:\(threadID)"] { throw failure }
        return turns[threadID] ?? .init(data: [])
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int,
                   direction: CodexHistoryDirection) throws -> CodexHistoryPage {
        if let failure = failures["items:\(threadID)"] { throw failure }
        calls.append("direction:\(direction.rawValue)")
        calls.append("items:\(threadID):\(cursor ?? "nil")")
        if direction == .descending, let page = descending[threadID] { return page }
        return items[threadID]?[Int(cursor ?? "0") ?? 0] ?? .init(data: [])
    }
    func recordedCalls() -> [String] { calls }
}
func codexTestAdapter(authority: CodexTestAuthority = .init(), history: CodexTestHistory = .init(),
                      interface: AgentInterface = .t3, version: String = "0.161.0",
                      t3Version: String? = CodexAdapter.validatedT3Version,
                      selectedAuthority: CodexCollectionAuthority = .publicNativeItems,
                      roots: [URL] = [], budget: HistoryReadBudget = .init(), limits: CodexReadLimits = .init(),
                      checkpoints: @escaping SourceCheckpointLookup = { _ in nil }) throws -> CodexAdapter {
    try .init(profileID: "test", agentVersion: version, interface: interface, t3Version: t3Version,
        authority: selectedAuthority, history: history, allowedTranscriptRoots: roots, limits: limits, historyBudget: budget,
        authorityLookup: { await authority.lookup($0) }, authorityRecorder: { try await authority.record($0) },
        checkpointLookup: checkpoints)
}
func codexFixture(_ id: String) throws -> CodexJSON {
    let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    return try JSONDecoder().decode(CodexJSON.self, from: Data(contentsOf: root.appendingPathComponent("Codex/\(id).json")))
}
func codexJSON(_ object: Any) throws -> CodexJSON {
    try JSONDecoder().decode(CodexJSON.self, from: JSONSerialization.data(withJSONObject: object))
}
func codexText(_ source: CollectedSource) -> String {
    source.record.segments.map { String(decoding: $0.utf8, as: UTF8.self) }.joined(separator: "\n")
}
func codexItem(_ id: String = "native", type: String = "agentMessage", timestamp: Double? = 1_791_434_400_000,
               body: [String: Any] = ["text": "synthetic", "phase": "final_answer"]) throws -> CodexJSON {
    var item = body; item["id"] = id; item["type"] = type
    var entry: [String: Any] = ["item": item, "turnId": "turn"]
    if let timestamp { entry["completedAtMs"] = timestamp }
    return try codexJSON(entry)
}
func codexThread(_ id: String = "parent", producer: String = "0.160.1", updatedAt: Double? = nil) throws -> CodexJSON {
    var thread: [String: Any] = ["id": id, "cliVersion": producer]
    if let updatedAt { thread["updatedAt"] = updatedAt }
    return try codexJSON(thread)
}
func codexPacket(thread: String, interface: AgentInterface = .t3, event: String = "SpillcheckHistoryPoll",
                 extra: [String: String] = [:]) throws -> CapturePacket {
    var hook = extra; hook["hook_event_name"] = event; hook["session_id"] = thread
    return try .init(metadata: .init(agent: .codex, interface: interface, profileID: "test"),
        eventJSON: JSONSerialization.data(withJSONObject: hook))
}

private func codexNativeChildTranscript(_ body: [String: Any], metadata: [String: Any]? = nil,
                                        timestamp: String? = "2026-10-11T10:00:00Z") throws -> Data {
    let childMetadata: [String: Any] = metadata ?? ["id": "child", "cli_version": "0.162.1",
        "parent_thread_id": "parent", "agent_path": "/root/child",
        "source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent", "agent_path": "/root/child"]]]]
    var row: [String: Any] = ["type": "response_item", "payload": body]
    if let timestamp { row["timestamp"] = timestamp }
    let rows: [[String: Any]] = [["type": "session_meta", "payload": childMetadata], row]
    return try rows.reduce(into: Data()) { data, row in
        data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10)
    }
}

@Suite("Codex measured canonical public collection")
struct CodexAdapterTests {
    @Test func nativeToolOutputKeepsEncryptedLookingBusinessJSONScannableAndReportsRealEncryptedBlocks() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        func importOutput(_ output: Any) async throws -> CollectionBatch {
            try await codexTestAdapter(selectedAuthority: .nativeRolloutTranscript).importTranscript(
                codexNativeChildTranscript(["type": "function_call_output", "call_id": "call", "output": output]),
                documentID: UUID(), observedAt: Date(), expectedSessionID: "child", cryptography: crypto)
        }
        let business: [Any] = [
            ["type": "encrypted_content", "text": "FAKE_SECRET"],
            "{\"type\":\"encrypted_content\",\"text\":\"FAKE_SECRET\"}",
            ["type": "encrypted_content", "encrypted_content": "FAKE_SECRET"]]
        for output in business {
            let batch = try await importOutput(output)
            let source = try #require(batch.sources.first)
            #expect(batch.sources.count == 1 && codexText(source).contains("FAKE_SECRET"))
            #expect(batch.coverageGaps.isEmpty && batch.recoveredReferences.count == 1)
        }
        let blocks = try await importOutput([["type": "input_text", "text": "readable"],
            ["type": "encrypted_content", "encrypted_content": "opaque-fake-payload"]])
        #expect(blocks.sources.count == 1 && codexText(blocks.sources[0]) == "readable")
        let gap = try #require(blocks.coverageGaps.first)
        #expect(blocks.coverageGaps.count == 1 && gap.reason == .unsupportedContent
            && gap.diagnosticCode == .encryptedContentUnavailable)
        #expect(gap.isRequiredFormatFailure == true && gap.requiresAnalysis && blocks.recoveredReferences.isEmpty)
        #expect(!String(decoding: try JSONEncoder().encode(gap), as: UTF8.self).contains("opaque-fake-payload"))
    }

    @Test func nativeTranscriptRecordsExcludedMediaLikeThePublicRoute() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let media: [String: Any] = ["type": "input_image", "image_url": "data:image/png;base64,FAKE"]
        let bodies: [[String: Any]] = [
            ["type": "message", "id": "native-user", "role": "user",
             "content": [["type": "input_text", "text": "readable"], media]],
            ["type": "message", "id": "native-assistant", "role": "assistant", "phase": "final_answer",
             "content": [["type": "output_text", "text": "readable"], media]],
            ["type": "agent_message", "id": "native-child-input", "author": "/root", "recipient": "/root/child",
             "content": [["type": "input_text", "text": "readable"], media]],
            ["type": "function_call_output", "call_id": "call",
             "output": [["type": "input_text", "text": "readable"], media]]]
        for body in bodies {
            let batch = try await codexTestAdapter(selectedAuthority: .nativeRolloutTranscript).importTranscript(
                codexNativeChildTranscript(body), documentID: UUID(), observedAt: Date(),
                expectedSessionID: "child", cryptography: crypto)
            #expect(batch.sources.count == 1 && batch.sources.first.map(codexText) == "readable")
            let gap = try #require(batch.coverageGaps.first)
            #expect(batch.coverageGaps.count == 1 && gap.reason == .unsupportedContent
                && gap.diagnosticCode == .excludedBinaryContent)
            #expect(gap.excludedContent == true && gap.isRequiredFormatFailure == false && !gap.requiresAnalysis)
            #expect(batch.recoveredReferences.isEmpty)
            #expect(!String(decoding: try JSONEncoder().encode(gap), as: UTF8.self).contains("FAKE"))
        }
    }

    @Test func encryptedNativeChildInputRemainsRequiredAndKeepsExactRecordRecovery() async throws {
        let adapter = try codexTestAdapter(selectedAuthority: .nativeRolloutTranscript)
        let document = UUID(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let body: [String: Any] = ["type": "agent_message", "id": "native-child-input",
            "author": "/root", "recipient": "/root/child", "content": [
                ["type": "input_text", "text": "readable wrapper"],
                ["type": "encrypted_content", "encrypted_content": "opaque-fake-payload"]]]
        let batch = try await adapter.importTranscript(codexNativeChildTranscript(body), documentID: document,
            observedAt: Date(), expectedSessionID: "child", cryptography: crypto)
        #expect(batch.sources.count == 1 && batch.sources[0].record.metadata.contentType == .userPrompt)
        #expect(batch.sources[0].record.metadata.identity.itemID == "native-child-input")
        #expect(batch.sources[0].record.segments.map(\.id) == ["/content/0/text"])
        #expect(codexText(batch.sources[0]) == "readable wrapper")
        let gap = try #require(batch.coverageGaps.first)
        #expect(gap.reason == .unsupportedContent && gap.diagnosticCode == .encryptedContentUnavailable)
        #expect(gap.contentType == .userPrompt && gap.isRequiredFormatFailure == true && gap.requiresAnalysis)
        #expect(gap.excludedContent != true && batch.recoveredReferences.isEmpty)
        #expect(gap.recovery?.session?.sessionID == "child")
        #expect(gap.recovery?.locator == .transcript(documentID: document, recordIndex: 1))
        #expect(gap.recovery?.contentTime == codexTimestamp("2026-10-11T10:00:00Z"))
        #expect(gap.recovery?.parserContract == CodexAdapter.parserContract)
        #expect(!String(decoding: try JSONEncoder().encode(gap), as: UTF8.self).contains("opaque-fake-payload"))
    }

    @Test func verifiedPlaintextNativeChildInputUsesOriginalIdentityAndRecoversOnlyThatRow() async throws {
        let adapter = try codexTestAdapter(selectedAuthority: .nativeRolloutTranscript)
        let crypto = try BackgroundCryptography.ephemeralForTesting(), document = UUID()
        let body: [String: Any] = ["type": "agent_message", "id": "native-child-input", "author": "/root",
            "recipient": "/root/child", "content": [["type": "input_text", "text": "exact é🙂 child task"]]]
        let data = try codexNativeChildTranscript(body)
        let first = try await adapter.importTranscript(data, documentID: document,
            observedAt: Date(), expectedSessionID: "child", cryptography: crypto)
        let replay = try await adapter.importTranscript(data, documentID: document,
            observedAt: Date(), expectedSessionID: "child", cryptography: crypto)
        #expect(first.coverageGaps.isEmpty && first.sources.count == 1)
        #expect(first.sources[0].record.metadata.contentType == .userPrompt)
        #expect(first.sources[0].record.metadata.identity.session.sessionID == "child")
        #expect(first.sources[0].record.metadata.identity.itemID == "native-child-input")
        #expect(codexText(first.sources[0]) == "exact é🙂 child task")
        #expect(first.sources[0].record.metadata.identity == replay.sources[0].record.metadata.identity)
        #expect(first.sources[0].record.revision == replay.sources[0].record.revision)
        #expect(first.recoveredReferences.count == 1)
        #expect(first.recoveredReferences[0].locator == .transcript(documentID: document, recordIndex: 1))
    }

    @Test func nativeAgentMessagesWithoutDemonstratedRecipientOrNativeIDStayGaps() async throws {
        let body: [String: Any] = ["type": "agent_message", "id": "input", "author": "/root",
            "recipient": "/root/child", "content": [["type": "input_text", "text": "unattributed"]]]
        for (field, value) in [("author", "/other"), ("recipient", "/root/other"), ("id", ""), ("id", "bad\u{0}id")] {
            var invalid = body; invalid[field] = value
            let batch = try await codexTestAdapter(selectedAuthority: .nativeRolloutTranscript).importTranscript(
                codexNativeChildTranscript(invalid), documentID: UUID(), observedAt: Date(), expectedSessionID: "child",
                cryptography: BackgroundCryptography.ephemeralForTesting())
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty)
            #expect(batch.coverageGaps.count == 1 && batch.coverageGaps[0].isRequiredFormatFailure == true)
            #expect(batch.coverageGaps[0].reason == (field == "id" ? .malformedSource : .unresolvedCorrelation))
        }
        let unknown = try await codexTestAdapter(selectedAuthority: .nativeRolloutTranscript).importTranscript(
            codexNativeChildTranscript(body, metadata: ["id": "child", "cli_version": "0.162.1"]), documentID: UUID(),
            observedAt: Date(), expectedSessionID: "child", cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(unknown.sources.isEmpty && unknown.recoveredReferences.isEmpty)
        #expect(unknown.coverageGaps.first?.reason == .unresolvedCorrelation)
    }

    @Test func malformedAndUnknownNativeInputBlocksCannotEstablishRecovery() async throws {
        let blocks: [[String: Any]] = [["type": "encrypted_content"],
            ["type": "encrypted_content", "encrypted_content": 17],
            ["type": "future-input", "text": "not-recognized"]]
        for block in blocks {
            let body: [String: Any] = ["type": "agent_message", "id": "input", "author": "/root",
                "recipient": "/root/child", "content": [block]]
            let batch = try await codexTestAdapter(selectedAuthority: .nativeRolloutTranscript).importTranscript(
                codexNativeChildTranscript(body), documentID: UUID(), observedAt: Date(), expectedSessionID: "child",
                cryptography: BackgroundCryptography.ephemeralForTesting())
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty)
            #expect(batch.coverageGaps.count == 1 && batch.coverageGaps[0].isRequiredFormatFailure == true)
            #expect(batch.coverageGaps[0].contentType == .userPrompt && batch.coverageGaps[0].excludedContent != true)
        }
    }

    @Test func missingNativeInputTimestampStaysUnknownInsteadOfUsingObservationTime() async throws {
        let body: [String: Any] = ["type": "agent_message", "id": "input", "author": "/root", "recipient": "/root/child",
            "content": [["type": "encrypted_content", "encrypted_content": "opaque"]]]
        let observed = Date()
        let batch = try await codexTestAdapter(selectedAuthority: .nativeRolloutTranscript).importTranscript(
            codexNativeChildTranscript(body, timestamp: nil), documentID: UUID(), observedAt: observed,
            expectedSessionID: "child", cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty)
        let gap = try #require(batch.coverageGaps.first)
        #expect(gap.reason == .missingTimestamp && gap.isRequiredFormatFailure == true && gap.contentType == .userPrompt)
        #expect(gap.recovery?.contentTime == nil && gap.interval == nil && gap.observedAt == observed)
    }

    @Test func publicEncryptedInputAndToolContentAreRequiredWhileMediaAndReasoningRemainExcluded() async throws {
        let encrypted: [String: Any] = ["type": "encrypted_content", "encrypted_content": "opaque-fake-payload"]
        let entries = [
            try codexItem("input", type: "userMessage", body: ["content": [encrypted, ["type": "input_text", "text": "readable"]]]),
            try codexItem("tool", type: "dynamicToolCall", body: ["status": "completed", "success": true, "contentItems": [encrypted]]),
            try codexItem("media", type: "userMessage", body: ["content": [["type": "inputImage", "imageUrl": "fake"]]]),
            try codexItem("reasoning", type: "reasoning", body: ["content": [encrypted]])]
        let batch = try await codexTestAdapter().importPublicItems(.init(data: entries), thread: codexThread(),
            observedAt: Date(), cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(batch.sources.count == 1 && codexText(batch.sources[0]) == "readable")
        #expect(batch.coverageGaps.count == 3 && batch.recoveredReferences.isEmpty)
        let required = batch.coverageGaps.filter { $0.diagnosticCode == .encryptedContentUnavailable }
        #expect(required.count == 2 && Set(required.compactMap(\.contentType)) == [.userPrompt, .toolOutput])
        #expect(required.allSatisfy { $0.isRequiredFormatFailure == true && $0.excludedContent != true })
        #expect(batch.coverageGaps.filter { $0.excludedContent == true }.first?.diagnosticCode == .excludedBinaryContent)
    }

    @Test func nativeHiddenReasoningStillDoesNotBecomeEncryptedInputFailure() async throws {
        let body: [String: Any] = ["type": "reasoning", "encrypted_content": "opaque-reasoning",
            "content": [["type": "encrypted_content", "encrypted_content": "opaque"]]]
        let batch = try await codexTestAdapter(selectedAuthority: .nativeRolloutTranscript).importTranscript(
            codexNativeChildTranscript(body), documentID: UUID(), observedAt: Date(), expectedSessionID: "child",
            cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(batch.sources.isEmpty && batch.coverageGaps.isEmpty && batch.recoveredReferences.isEmpty)
    }

    @Test func currentDynamicToolItemsCollectTextAndErrorSemanticsWithoutChangingLegacyLocations() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting(), adapter = try codexTestAdapter(version: "0.162.1")
        let entries = [
            try codexItem("dynamic-ok", type: "dynamicToolCall", body: ["status": "completed", "success": true,
                "contentItems": [["type": "inputText", "text": "é🙂 exact\r\n"]]]),
            try codexItem("dynamic-error", type: "dynamicToolCall", body: ["status": "completed", "success": false,
                "contentItems": [["type": "inputText", "text": "synthetic failure"]]]),
            try codexItem("legacy", type: "dynamicToolCall", body: ["status": "completed",
                "content": [["type": "inputText", "text": "legacy exact"]]]),
        ]
        let batch = try await adapter.importPublicItems(.init(data: entries), thread: codexThread(producer: "0.162.1"),
            observedAt: Date(), cryptography: crypto)
        #expect(batch.coverageGaps.isEmpty)
        #expect(batch.sources.map(\.record.metadata.identity.itemID) == ["dynamic-ok", "dynamic-error", "legacy"])
        #expect(batch.sources.map(\.record.metadata.contentType) == [.toolOutput, .toolError, .toolOutput])
        #expect(batch.sources.map { $0.record.segments.first?.id } == ["/contentItems/0/text", "/contentItems/0/text", "/content/0/text"])
        #expect(batch.sources.first?.record.segments.first?.utf8 == Data("é🙂 exact\r\n".utf8))
        let replay = try await adapter.importPublicItems(.init(data: entries), thread: codexThread(producer: "0.162.1"),
            observedAt: Date(), cryptography: crypto)
        #expect(batch.sources.map(\.record.metadata.identity) == replay.sources.map(\.record.metadata.identity))
        #expect(batch.sources.map(\.record.revision) == replay.sources.map(\.record.revision))
    }

    @Test func terminalToolsWithoutResultCannotAssertRecoveryAndKeepReadableSiblings() async throws {
        let entries = [
            try codexItem("missing-dynamic", type: "dynamicToolCall", body: ["status": "completed", "success": true]),
            try codexItem("missing-mcp", type: "mcpToolCall", body: ["status": "failed"]),
            try codexItem("malformed-dynamic", type: "dynamicToolCall", body: ["status": "completed", "success": "false",
                "contentItems": [["type": "inputText", "text": "unknown error semantics"]]]),
            try codexItem("good"),
        ]
        let batch = try await codexTestAdapter().importPublicItems(.init(data: entries), thread: codexThread(),
            observedAt: Date(), cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(batch.sources.map(\.record.metadata.identity.itemID) == ["good"])
        #expect(batch.coverageGaps.count == 3)
        #expect(batch.coverageGaps.allSatisfy { $0.isRequiredFormatFailure == true })
        #expect(batch.recoveredReferences.map(\.itemID) == ["good"])
    }

    @Test func currentPublicFunctionOutputPreservesOriginalTextBytes() async throws {
        let entry = try codexItem("function", type: "functionCallOutput", body: ["name": "fixture",
            "output": [["type": "input_text", "text": "é🙂 exact\r\n"]]])
        let batch = try await codexTestAdapter(version: "0.162.1").importPublicItems(.init(data: [entry]),
            thread: codexThread(producer: "0.162.1"), observedAt: Date(), cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(batch.coverageGaps.isEmpty)
        #expect(batch.sources.first?.record.metadata.identity.itemID == "function")
        #expect(batch.sources.first?.record.metadata.contentType == .toolOutput)
        #expect(batch.sources.first?.record.segments.first?.id == "/output/0/text")
        #expect(batch.sources.first?.record.segments.first?.utf8 == Data("é🙂 exact\r\n".utf8))
    }

    @Test func dynamicOutputsAndErrorsReachTheProductionScannerAtExactUTF8Locations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-dynamic-scan-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = BetterleaksConfiguration(executableURL: repo.appendingPathComponent(".build/scanner/betterleaks"),
            configurationURL: repo.appendingPathComponent(".build/scanner/betterleaks.toml"), workingDirectoryURL: root)
        _ = try ScannerProcess.verifyArtifacts(configuration)
        let value = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
        let entries = try [true, false].enumerated().map { index, success in
            try codexItem("dynamic-\(index)", type: "dynamicToolCall", body: ["status": "completed", "success": success,
                "contentItems": [["type": "inputText", "text": "é🙂 token: \(value)\r\n"]]])
        }
        let batch = try await codexTestAdapter().importPublicItems(.init(data: entries), thread: codexThread(),
            observedAt: Date(), cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(batch.sources.count == 2 && batch.coverageGaps.isEmpty)
        let scanner = BetterleaksSecretDetector(configuration: configuration)
        for source in batch.sources {
            let result = try await scanner.scan(source.record)
            #expect(result.scannerFailure == nil && result.coverageGaps.isEmpty)
            let finding = try #require(result.findings.first)
            #expect(result.findings.count == 1)
            #expect(try finding.extraction.location.extract(from: source.record) == Data(value.utf8))
            #expect(finding.extraction.location.components.first?.segmentID == "/contentItems/0/text")
        }
    }

    @Test func excludedMediaAndRequiredUnknownToolBlocksHaveDifferentControlledDiagnostics() async throws {
        let entry = try codexItem("dynamic", type: "dynamicToolCall", body: ["status": "completed", "success": true,
            "contentItems": [["type": "inputText", "text": "readable"], ["type": "inputImage", "imageUrl": "excluded"],
                ["type": "future-confidential-payload", "text": "unknown"]]])
        let batch = try await codexTestAdapter().importPublicItems(.init(data: [entry]), thread: codexThread(),
            observedAt: Date(), cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(batch.sources.map(codexText) == ["readable"] && batch.recoveredReferences.isEmpty)
        #expect(batch.coverageGaps.count == 2)
        #expect(batch.coverageGaps.contains { $0.excludedContent == true && $0.diagnosticCode == .excludedBinaryContent && $0.isRequiredFormatFailure == false })
        #expect(batch.coverageGaps.contains { $0.excludedContent != true && $0.diagnosticCode == .unknownBlockKind && $0.isRequiredFormatFailure == true })
        #expect(batch.coverageGaps.allSatisfy { $0.sourceKind == .codexDynamicToolCall })
        let encoded = try JSONEncoder().encode(batch.coverageGaps)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("future-confidential-payload"))
    }

    @Test func actualStandaloneProducerFixtureMapsSuccessAndFailedShellAndMCPSeparately() async throws {
        let fixture = try codexFixture("01a11a2d-3997-7a80-99a4-bde7806fee8f")
        let adapter = try codexTestAdapter(interface: .standaloneCLI, t3Version: nil)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let batch = try await adapter.importPublicItems(.init(data: #require(fixture["items"].array)),
            thread: fixture["thread"], observedAt: Date(), cryptography: crypto)
        #expect(batch.coverageGaps.isEmpty)
        #expect(Dictionary(grouping: batch.sources, by: { $0.record.metadata.contentType }).mapValues(\.count)
            == [.userPrompt: 1, .intermediateResponse: 1, .finalResponse: 1, .toolOutput: 2, .toolError: 2])
        for (marker, kind) in [("SHELL_OK", ContentType.toolOutput), ("SHELL_ERROR", .toolError),
                               ("MCP_OK", .toolOutput), ("MCP_ERROR", .toolError)] {
            let exact = batch.sources.filter { $0.record.metadata.contentType == kind && codexText($0).contains("LEAKRET_M4_\(marker)") }
            #expect(exact.count == 1)
            #expect(exact.first?.record.metadata.identity.itemID.hasPrefix("exec-") == true)
            #expect(exact.first?.record.metadata.origin.agentVersion == "0.161.0")
        }
    }
    @Test func actualT3ProducerReaderTupleMapsFiveTypesAndIndependentNativeChild() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting(), adapter = try codexTestAdapter()
        let parent = try codexFixture("01a119f4-c91b-7443-bcdf-be4a6a59a579")
        let child = try codexFixture("01a119f5-3a5e-72c1-8ef2-b0b5de83367d")
        let batch = try await adapter.importPublicItems(.init(data: parent["items"].array!), thread: parent["thread"],
            observedAt: Date(), cryptography: crypto)
        let childBatch = try await adapter.importPublicItems(.init(data: child["items"].array!), thread: child["thread"],
            observedAt: Date(), cryptography: crypto)
        #expect(batch.coverageGaps.count == 1 && childBatch.coverageGaps.isEmpty)
        #expect(batch.coverageGaps.allSatisfy { $0.excludedContent == true && $0.diagnosticCode == .excludedBinaryContent
            && $0.isRequiredFormatFailure == false && $0.contentType == .toolOutput })
        let expected: [(ContentType, String)] = [(.userPrompt, "PROMPT"), (.intermediateResponse, "INTERMEDIATE"),
            (.finalResponse, "FINAL"), (.toolOutput, "SHELL_OK"), (.toolError, "SHELL_ERROR"),
            (.toolOutput, "MCP_OK"), (.toolError, "MCP_ERROR")]
        for (type, marker) in expected {
            #expect(batch.sources.contains { $0.record.metadata.contentType == type && codexText($0).contains("LEAKRET_M4_\(marker)") })
        }
        let shell = try #require(batch.sources.first { $0.record.metadata.identity.itemID == "exec-47f244a7-fe77-4056-a8c9-dcfbe22cfa80" })
        #expect(shell.record.segments.first?.id == "/aggregatedOutput")
        #expect(Set(batch.sources.map(\.record.metadata.contentType)) == Set(ContentType.allCases))
        #expect(batch.sources.allSatisfy { $0.record.metadata.origin.agentVersion == "0.160.1" })
        #expect(childBatch.sources.contains { $0.record.metadata.contentType == .finalResponse && codexText($0).contains("LEAKRET_M4_CHILD_FINAL") })
        #expect(childBatch.sources.allSatisfy { $0.record.metadata.identity.session.sessionID == "01a119f5-3a5e-72c1-8ef2-b0b5de83367d" })
        #expect(!childBatch.sources.contains { $0.record.metadata.contentType == .userPrompt })
        let replay = try await adapter.importPublicItems(.init(data: parent["items"].array!), thread: parent["thread"],
            observedAt: Date(timeIntervalSince1970: 1_900_000_000), cryptography: crypto)
        #expect(batch.sources.map(\.record.revision) == replay.sources.map(\.record.revision))
        #expect(batch.sources.map(\.record.metadata.contentTime) == replay.sources.map(\.record.metadata.contentTime))
        let known = Data("ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS".utf8)
        let fingerprint = try await crypto.fingerprint(exactBytes: known)
        let exact = try #require(childBatch.sources.first { codexText($0).contains("LEAKRET_M4_CHILD_FINAL") })
        let segment = try #require(exact.record.segments.first { $0.utf8.range(of: known) != nil })
        let range = try #require(segment.utf8.range(of: known))
        let extraction = try ExactExtraction(valueUTF8: known,
            location: .init(segmentID: segment.id, range: .init(range.lowerBound, range.upperBound)), in: exact.record)
        #expect(try await crypto.fingerprint(exactBytes: extraction.valueUTF8) == fingerprint)
    }

    @Test func unfamiliarVersionsRemainEligibleAndProducerMetadataIsIndependent() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting(), page = CodexHistoryPage(data: [try codexItem()])
        for adapter in [try codexTestAdapter(version: "0.161.1"), try codexTestAdapter(version: "3.0.0", t3Version: nil),
                        try codexTestAdapter(t3Version: "other")] {
            #expect(adapter.capabilities().allSatisfy { $0.validation == .unverified && $0.canObserveActiveSession })
            let result = try await adapter.importPublicItems(page, thread: codexThread(producer: "0.160.1"), observedAt: Date(), cryptography: crypto)
            #expect(result.sources.count == 1 && result.coverageGaps.isEmpty)
            #expect(result.sources[0].record.metadata.origin.agentVersion == "0.160.1")
        }
        let desktop = try codexTestAdapter(interface: .desktopCode)
        #expect(desktop.capabilities().allSatisfy { $0.validation == .unverified && $0.canObserveActiveSession })
        let result = try await desktop.importPublicItems(page, thread: codexThread(), observedAt: Date(), cryptography: crypto)
        #expect(result.sources.count == 1 && result.coverageGaps.isEmpty)
        let standalone = try codexTestAdapter(interface: .standaloneCLI)
        let older = try await standalone.importPublicItems(page, thread: codexThread(producer: "0.160.1"), observedAt: Date(), cryptography: crypto)
        let current = try await standalone.importPublicItems(page, thread: codexThread(producer: "0.161.0"), observedAt: Date(), cryptography: crypto)
        let unknown = try await standalone.importPublicItems(page, thread: codexJSON(["id": "parent"]), observedAt: Date(), cryptography: crypto)
        #expect(older.sources.count == 1 && current.sources.count == 1 && unknown.sources.count == 1)
        #expect(unknown.sources[0].record.metadata.origin.agentVersion == CollectionCompatibility.unknownProducerVersion)
        #expect(older.sources[0].record.metadata.identity == current.sources[0].record.metadata.identity)
        #expect(older.sources[0].record.revision == current.sources[0].record.revision)
    }

    @Test func essentialToolFormatDegradesOnlyToolScopeAndKeepsReadableMessages() async throws {
        let entries = [try codexItem("prompt", type: "userMessage", body: ["content": [["type": "text", "text": "é🙂 synthetic"]]]),
            try codexItem("good"),
            try codexItem("broken", type: "commandExecution", body: ["status": "completed", "aggregatedOutput": "output", "exitCode": "changed"]),
            try codexItem("future", type: "futureType"),
            try codexItem("unknown-block", type: "userMessage", body: ["content": [["type": "text", "text": "readable"], ["type": "future", "text": "unrecognized"]]])]
        let batch = try await codexTestAdapter().importPublicItems(.init(data: entries), thread: codexThread(producer: "4.0.0"),
            observedAt: Date(), cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(batch.sources.map(\.record.metadata.identity.itemID) == ["prompt", "good", "unknown-block"])
        #expect(batch.coverageGaps.filter { $0.isRequiredFormatFailure == true }.count == 2)
        let failed = try #require(batch.coverageGaps.first { $0.recovery?.itemID == "broken" })
        #expect(failed.scope?.profileID == "test" && failed.contentType == .toolError)
        #expect(failed.recovery?.itemID == "broken")
        #expect(!batch.recoveredReferences.contains { $0.itemID == "unknown-block" || $0.itemID == "broken" })
        #expect(!batch.sources.contains { codexText($0).contains("unrecognized") })
    }

    @Test func additiveToolPayloadStringsAreContentButEnvelopeFieldsDoNotChangeRevision() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting(), adapter = try codexTestAdapter()
        let original = try codexItem("tool", type: "mcpToolCall", body: ["status": "completed", "result": ["content": [["type": "text", "text": "first"]]]])
        var envelope = try #require(original.object)
        envelope["newEnvelopeField"] = .string("not model content")
        let first = try await adapter.importPublicItems(.init(data: [original]), thread: codexThread(), observedAt: Date(), cryptography: crypto)
        let same = try await adapter.importPublicItems(.init(data: [.object(envelope)]), thread: codexThread(producer: "future"), observedAt: Date(), cryptography: crypto)
        #expect(first.sources[0].record.revision == same.sources[0].record.revision)
        let extended = try codexItem("tool", type: "mcpToolCall", body: ["status": "completed", "result": ["content": [["type": "text", "text": "first"]], "newContentField": "new synthetic text"]])
        let changed = try await adapter.importPublicItems(.init(data: [extended]), thread: codexThread(), observedAt: Date(), cryptography: crypto)
        #expect(changed.sources[0].record.revision != first.sources[0].record.revision)
        #expect(codexText(changed.sources[0]).contains("new synthetic text"))
    }

    @Test func durableAuthorityMustBeCommittedBeforeSourceEmissionAndCannotSwitchAfterUpgrade() async throws {
        let authority = CodexTestAuthority(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let session = try SessionIdentity(provider: .codex, profileID: "test", sessionID: "parent")
        try await authority.record(.init(session: session, adapterVersion: "older", authorityID: CodexCollectionAuthority.publicNativeItems.rawValue))
        let adapter = try codexTestAdapter(authority: authority)
        #expect(try await adapter.importPublicItems(.init(data: [try codexItem()]), thread: codexThread(), observedAt: Date(), cryptography: crypto).sources.count == 1)
        let conflict = try codexTestAdapter(authority: authority, selectedAuthority: .t3VersionedTranscript)
        await #expect(throws: CodexCollectionError.authorityConflict) { try await conflict.selectAuthority(sessionID: "parent") }
        let missing = try CodexAdapter(profileID: "test", agentVersion: "0.161.0", interface: .standaloneCLI,
            history: CodexTestHistory(), authorityLookup: { _ in nil }, authorityRecorder: { _ in })
        await #expect(throws: CodexCollectionError.missingAuthority) {
            try await missing.importPublicItems(.init(data: [try codexItem()]), thread: codexThread(producer: "0.161.0"),
                observedAt: Date(), cryptography: crypto)
        }
    }

    @Test func malformedIDsIncompleteStatusesUnknownPhasesAndMissingTimesRemainGaps() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let entries = [try codexItem("", body: ["text": "bad", "phase": "final_answer"]),
            try codexItem("phase", body: ["text": "bad", "phase": "unknown"]),
            try codexItem("time", timestamp: nil),
            try codexItem("tool", type: "commandExecution", body: ["aggregatedOutput": "bad", "status": "inProgress"]),
            try codexItem("type", type: "futureType")]
        let batch = try await adapter.importPublicItems(.init(data: entries), thread: codexThread(), observedAt: Date(), cryptography: crypto)
        #expect(batch.sources.isEmpty)
        #expect(Set(batch.coverageGaps.map(\.reason)) == [.malformedSource, .unsupportedContent, .missingTimestamp, .incompleteMessage])
    }

    @Test func missingAndOversizedNativeItemIDsLeaveRecoverableSessionOmission() async throws {
        let entries = [try codexItem(""), try codexItem(String(repeating: "x", count: 4097)),
            try codexItem("invalid\u{0}native"), try codexItem("readable")]
        let batch = try await codexTestAdapter().importPublicItems(.init(data: entries), thread: codexThread(), observedAt: Date(),
            cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(batch.sources.map(\.record.metadata.identity.itemID) == ["readable"])
        #expect(!batch.coverageGaps.isEmpty)
        #expect(batch.coverageGaps.allSatisfy { $0.reason == .malformedSource && $0.isRequiredFormatFailure == true
            && $0.recovery?.session?.sessionID == "parent" && $0.recovery?.locator == .unavailable && $0.recovery?.itemID == nil })
        #expect(batch.recoveredReferences.allSatisfy { $0.itemID == "readable" })
    }

    @Test func exactDecodedUnicodeStructuredFieldsAndBinaryExclusion() async throws {
        let item = try codexItem("mcp", type: "mcpToolCall", body: ["status": "completed", "error": NSNull(),
            "result": ["content": [["type": "text", "text": "é🙂\r\n"]],
                       "structuredContent": ["a/b": "synthetic", "blob": ["type": "image", "data": "ordinary business data"]]]])
        let batch = try await codexTestAdapter().importPublicItems(.init(data: [item]), thread: codexThread(), observedAt: Date(),
            cryptography: BackgroundCryptography.ephemeralForTesting())
        let source = try #require(batch.sources.first)
        #expect(source.record.segments.map(\.id) == ["/result/content/0/text", "/result/structuredContent/a~1b",
            "/result/structuredContent/blob/data", "/result/structuredContent/blob/type"])
        #expect(source.record.segments.map(\.utf8) == [Data("é🙂\r\n".utf8), Data("synthetic".utf8),
            Data("ordinary business data".utf8), Data("image".utf8)])
        #expect(batch.coverageGaps.isEmpty)
    }

    @Test func nativeRolloutUsesRecordedProvenanceAndStableAuthorityAcrossVersionChanges() async throws {
        let adapter = try codexTestAdapter(version: "4.0.0", t3Version: "current-host", selectedAuthority: .nativeRolloutTranscript)
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "native", "cli_version": "3.0.0"]],
            ["type": "response_item", "timestamp": "2026-10-09T10:00:00Z", "payload": ["type": "message", "id": "user", "role": "user", "content": [["type": "input_text", "text": "prompt"]]]],
            ["type": "response_item", "timestamp": "2026-10-09T10:00:01Z", "payload": ["type": "message", "id": "intermediate", "role": "assistant", "phase": "commentary", "content": [["type": "output_text", "text": "intermediate"]]]],
            ["type": "response_item", "timestamp": "2026-10-09T10:00:02Z", "payload": ["type": "message", "id": "final", "role": "assistant", "phase": "final_answer", "content": [["type": "output_text", "text": "final"]]]],
            ["type": "response_item", "timestamp": "2026-10-09T10:00:03Z", "payload": ["type": "function_call_output", "call_id": "success", "output": "{\"output\":\"ok\",\"exit_code\":0,\"additionalText\":\"extra\"}"]],
            ["type": "response_item", "timestamp": "2026-10-09T10:00:04Z", "payload": ["type": "function_call_output", "call_id": "error", "output": "{\"output\":\"error\",\"exit_code\":7}"]]
        ]
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        let document = UUID(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let batch = try await adapter.importTranscript(data, documentID: document, observedAt: Date(), expectedSessionID: "native", cryptography: crypto)
        #expect(batch.coverageGaps.isEmpty && batch.sources.count == 5)
        #expect(Set(batch.sources.map(\.record.metadata.contentType)) == Set(ContentType.allCases))
        #expect(batch.sources.allSatisfy { $0.record.metadata.origin.agentVersion == "3.0.0" })
        #expect(batch.sources.contains { codexText($0).contains("extra") })
        #expect(batch.recoveredReferences.count == 5)
        #expect(CodexCollectionAuthority.nativeRolloutTranscript.rawValue == "codex-t3-transcript-v1")
        let replay = try await adapter.importTranscript(data, documentID: document, observedAt: Date(), expectedSessionID: "native", cryptography: crypto)
        #expect(batch.sources.map(\.record.metadata.identity) == replay.sources.map(\.record.metadata.identity))
        #expect(batch.sources.map(\.record.revision) == replay.sources.map(\.record.revision))
    }

    @Test func coarseTurnTimesDoNotInventCoverageAcrossSevenDayBoundary() async throws {
        let end = Date(timeIntervalSince1970: 1_791_434_400), audit = try HistoricalAuditContext(reason: .firstLaunch, endingAt: end)
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let coarse = try codexItem(timestamp: nil)
        let crossing = try await adapter.importPublicItems(.init(data: [coarse]), thread: codexThread(), observedAt: end,
            provenance: .historical(audit), turnTimes: ["turn": DateInterval(start: audit.start.addingTimeInterval(-1), end: audit.start.addingTimeInterval(1))],
            cryptography: crypto)
        #expect(crossing.sources.isEmpty && crossing.coverageGaps.map(\.reason) == [.missingTimestamp])
        let inside = try await adapter.importPublicItems(.init(data: [coarse]), thread: codexThread(), observedAt: end,
            provenance: .historical(audit), turnTimes: ["turn": DateInterval(start: audit.start.addingTimeInterval(1), end: audit.start.addingTimeInterval(2))],
            cryptography: crypto)
        #expect(inside.sources.count == 1)
    }
}
