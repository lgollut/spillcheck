import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private let hookToolTime = Date(timeIntervalSince1970: 1_791_720_000)
private let hookToolMarker = "SPILLCHECK_FAKE_TOOL_RESULT_91"

private actor HookToolBindings {
    private var revisions: [SourceIdentity: (ContentRevision, Date)] = [:]
    func authority(_ session: SessionIdentity) throws -> CollectionAuthorityChoice {
        try .init(session: session, adapterVersion: "1", authorityID: CodexHookContentAdapter.authorityID)
    }
    func bind(_ source: SourceIdentity, _ revision: ContentRevision, _ observedAt: Date) -> CodexHookContentBinding {
        if let previous = revisions[source] {
            return previous.0 == revision ? .accepted(firstObservedAt: previous.1) : .conflict
        }
        revisions[source] = (revision, observedAt)
        return .accepted(firstObservedAt: observedAt)
    }
    var count: Int { revisions.count }
}

private struct HookToolFixture {
    let crypto: BackgroundCryptography
    let bindings: HookToolBindings
    let adapter: CodexHookContentAdapter
    init() throws {
        crypto = try .ephemeralForTesting()
        let bindings = HookToolBindings()
        self.bindings = bindings
        adapter = try .init(profileID: "synthetic", interface: .desktopCode,
            authorityLookup: { try await bindings.authority($0) },
            bind: { await bindings.bind($0, $1, $2) })
    }
    func normalize(_ response: Any, call: String = "call-1", tool: String = "Bash",
                   extra: [String: Any] = [:], omitting: Set<String> = []) async throws -> CollectionBatch {
        var event: [String: Any] = ["hook_event_name": "PostToolUse", "session_id": "session", "turn_id": "turn",
            "tool_use_id": call, "tool_name": tool, "tool_response": response,
            "tool_input": ["command": "INPUT_MUST_NOT_BE_SCANNED"], "cwd": "/DO_NOT_SCAN_ENVELOPE"]
        event.merge(extra) { _, new in new }
        for key in omitting { event.removeValue(forKey: key) }
        let packet = try CapturePacket(metadata: .init(agent: .codex, interface: .desktopCode, profileID: "synthetic"),
            eventJSON: JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
        return try await adapter.normalize(packet, capturedAt: hookToolTime, cryptography: crypto)
    }
}

private func hookToolTexts(_ batch: CollectionBatch) -> [String: String] {
    Dictionary(uniqueKeysWithValues: batch.sources.flatMap { $0.record.segments }.map {
        ($0.id, String(decoding: $0.utf8, as: UTF8.self))
    })
}

@Suite("Codex hook tool response contract")
struct CodexHookToolContentTests {
    @Test func shellOutputAndFailureRetainOnlyResponseText() async throws {
        let fixture = try HookToolFixture()
        let success = try await fixture.normalize(["stdout": hookToolMarker, "stderr": "", "exit_code": 0])
        let source = try #require(success.sources.first?.record)
        #expect(source.metadata.contentType == .toolOutput)
        #expect(source.metadata.timeBasis == .firstObservation)
        #expect(hookToolTexts(success) == ["/tool_response/stdout": hookToolMarker, "/tool_response/stderr": ""])
        #expect(success.coverageGaps.isEmpty)
        let failure = try await fixture.normalize(["output": hookToolMarker, "exitCode": 1], call: "call-2")
        #expect(failure.sources.first?.record.metadata.contentType == .toolError)
        #expect(hookToolTexts(failure)["/tool_response/output"] == hookToolMarker)
        let wrapped = try await fixture.normalize(["output": hookToolMarker, "metadata": ["exit_code": -9]], call: "call-3")
        #expect(wrapped.sources.first?.record.metadata.contentType == .toolError)
        let unknownStatus = try await fixture.normalize(["stderr": hookToolMarker], call: "call-4")
        #expect(unknownStatus.sources.first?.record.metadata.contentType == .toolOutput)
        #expect(hookToolTexts(unknownStatus) == ["/tool_response/stderr": hookToolMarker])
    }

    @Test func mcpContentStructuredResultsAndResourcesKeepTheirExactLocations() async throws {
        let fixture = try HookToolFixture()
        let response: [String: Any] = ["isError": true,
            "content": [["type": "text", "text": hookToolMarker],
                ["type": "resource", "resource": ["uri": "synthetic://resource", "text": "resource " + hookToolMarker]]],
            "structuredContent": ["nested": [["key/~": "structured " + hookToolMarker]],
                "data": ["isError": false, "error": "ordinary result data"]]]
        let batch = try await fixture.normalize(response, tool: "mcp__fixture__read")
        #expect(batch.sources.first?.record.metadata.contentType == .toolError)
        let texts = hookToolTexts(batch)
        #expect(texts["/tool_response/content/0/text"] == hookToolMarker)
        #expect(texts["/tool_response/content/1/resource/text"] == "resource " + hookToolMarker)
        #expect(texts["/tool_response/structuredContent/nested/0/key~1~0"] == "structured " + hookToolMarker)
        #expect(batch.coverageGaps.isEmpty)
        let dataError = try await fixture.normalize(["isError": false,
            "structuredContent": ["error": "application data", "isError": true]], call: "call-2", tool: "mcp__fixture__read")
        #expect(dataError.sources.first?.record.metadata.contentType == .toolOutput)
    }

    @Test func plainAndJSONEncodedStringsPreserveBytesWithoutInventingStatus() async throws {
        let fixture = try HookToolFixture()
        let plain = "Process exited with code 9\nError: " + hookToolMarker + "\\n literal"
        let unknown = try await fixture.normalize(plain, tool: "some_local_function")
        // toolOutput means returned content, not a claim that the operation succeeded.
        #expect(unknown.sources.first?.record.metadata.contentType == .toolOutput)
        #expect(unknown.coverageGaps.isEmpty)
        #expect(hookToolTexts(unknown) == ["/tool_response": plain])
        let encoded = "{\"output\":\"escaped \\u0041 " + hookToolMarker + "\",\"exit_code\":1}"
        let wrapped = try await fixture.normalize(encoded, call: "call-2")
        #expect(wrapped.sources.first?.record.metadata.contentType == .toolOutput)
        #expect(hookToolTexts(wrapped) == ["/tool_response": encoded])
        #expect(wrapped.sources.first?.record.segments.count == 1)
        #expect(wrapped.coverageGaps.isEmpty)
    }

    @Test func printedJSONCannotSpoofShellOrMCPExecutionStatus() async throws {
        let fixture = try HookToolFixture()
        let printed = [
            "{\"exit_code\":7,\"exitCode\":9,\"metadata\":{\"exit_code\":3},\"isError\":true,\"text\":\"" + hookToolMarker + "\"}\n",
            "{\"exit_code\":\"failed\",\"exitCode\":false,\"isError\":\"true\",\"text\":\"" + hookToolMarker + "\"}",
            "{\"result\":{\"exit_code\":7,\"isError\":true,\"text\":\"" + hookToolMarker + "\"}}"
        ]
        let tools = ["Bash", "functions.Bash", "exec_command", "functions.exec_command",
            "write_stdin", "functions.write_stdin", "mcp__fixture__read"]
        for (toolIndex, tool) in tools.enumerated() {
            for (textIndex, text) in printed.enumerated() {
                let batch = try await fixture.normalize(text, call: "printed-\(toolIndex)-\(textIndex)", tool: tool)
                #expect(batch.sources.first?.record.metadata.contentType == .toolOutput)
                #expect(hookToolTexts(batch) == ["/tool_response": text])
                #expect(batch.sources.first?.record.segments.first?.utf8 == Data(text.utf8))
                #expect(batch.coverageGaps.isEmpty)
            }
        }
    }

    @Test func nestedBusinessStatusDoesNotOverrideTheResponseEnvelope() async throws {
        let fixture = try HookToolFixture()
        let printed = "{\"exit_code\":7,\"secret\":\"" + hookToolMarker + "\"}"
        let shell = try await fixture.normalize(["exit_code": 0, "output": printed,
            "result": ["exit_code": 9, "text": hookToolMarker]])
        #expect(shell.sources.first?.record.metadata.contentType == .toolOutput)
        #expect(hookToolTexts(shell)["/tool_response/output"] == printed)
        #expect(hookToolTexts(shell)["/tool_response/result/text"] == hookToolMarker)
        #expect(shell.coverageGaps.isEmpty)
        let mcp = try await fixture.normalize(["isError": false,
            "output": "{\"isError\":true,\"text\":\"" + hookToolMarker + "\"}",
            "error": ["isError": true, "text": hookToolMarker],
            "result": ["isError": true, "content": [["type": "image", "caption": hookToolMarker]]]],
            call: "mcp", tool: "mcp__fixture__read")
        #expect(mcp.sources.first?.record.metadata.contentType == .toolOutput)
        #expect(hookToolTexts(mcp)["/tool_response/error/text"] == hookToolMarker)
        #expect(hookToolTexts(mcp)["/tool_response/result/content/0/caption"] == hookToolMarker)
        #expect(mcp.coverageGaps.isEmpty)
    }

    @Test func multipleCallsAreDistinctAndSemanticChangesCannotOverwriteAnExistingCall() async throws {
        let fixture = try HookToolFixture()
        let response: [String: Any] = ["output": hookToolMarker, "exit_code": 0]
        let first = try await fixture.normalize(response), replay = try await fixture.normalize(response)
        let second = try await fixture.normalize(response, call: "another-call")
        let original = try #require(first.sources.first?.record)
        #expect(replay.sources.first?.record.revision == original.revision)
        #expect(second.sources.first?.record.metadata.identity != original.metadata.identity)
        #expect(await fixture.bindings.count == 2)
        let changedStatus = try await fixture.normalize(["output": hookToolMarker, "exit_code": 1])
        #expect(changedStatus.sources.isEmpty)
        #expect(changedStatus.coverageGaps.first?.diagnosticCode == .hookIdentityConflict)
        let changedName = try await fixture.normalize(response, tool: "another_tool")
        #expect(changedName.sources.isEmpty)
        #expect(changedName.coverageGaps.first?.diagnosticCode == .hookIdentityConflict)
        let changedBytes = try await fixture.normalize(["output": "prefix " + hookToolMarker, "exit_code": 0])
        #expect(changedBytes.coverageGaps.first?.diagnosticCode == .hookIdentityConflict)
    }

    @Test func malformedStatusPreservesReadableTextAndReportsRequiredGap() async throws {
        let fixture = try HookToolFixture()
        let responses: [[String: Any]] = [
            ["output": hookToolMarker, "exit_code": "1"],
            ["output": hookToolMarker, "exit_code": 1.5],
            ["output": hookToolMarker, "exit_code": Double(Int32.max) + 1],
            ["output": hookToolMarker, "exitCode": false]
        ]
        for (index, response) in responses.enumerated() {
            let batch = try await fixture.normalize(response, call: "call-\(index)")
            #expect(hookToolTexts(batch).values.contains(hookToolMarker))
            #expect(batch.coverageGaps.contains { $0.diagnosticCode == .invalidFieldType && $0.requiresAnalysis })
        }
        let mcp = try await fixture.normalize(["content": [["type": "text", "text": hookToolMarker]], "isError": "false"],
            call: "mcp", tool: "mcp__fixture__read")
        #expect(hookToolTexts(mcp).values.contains(hookToolMarker))
        #expect(mcp.coverageGaps.contains { $0.diagnosticCode == .invalidFieldType && $0.requiresAnalysis })
    }

    @Test func missingResponseOrCallIdentityCannotConsumeTheSlot() async throws {
        let fixture = try HookToolFixture()
        for omitted: Set<String> in [["tool_response"], ["tool_use_id"], ["tool_name"]] {
            let batch = try await fixture.normalize(hookToolMarker, omitting: omitted)
            #expect(batch.sources.isEmpty && batch.coverageGaps.first?.requiresAnalysis == true)
        }
        for call in ["", "bad/call", String(repeating: "x", count: 257)] {
            let batch = try await fixture.normalize(hookToolMarker, call: call)
            #expect(batch.sources.isEmpty && batch.coverageGaps.first?.diagnosticCode == .unresolvedIdentity)
        }
        #expect(await fixture.bindings.count == 0)
        #expect(try await fixture.normalize(hookToolMarker).sources.count == 1)
        #expect(await fixture.bindings.count == 1)
    }

    @Test func childContextCannotClaimTheEnrolledSessionsToolSlot() async throws {
        let fixture = try HookToolFixture()
        for extra: [String: Any] in [["agent_id": "child"], ["agent_type": "worker"],
            ["agent_id": NSNull(), "agent_type": "worker"], ["agent_id": "child", "agent_type": NSNull()]] {
            let batch = try await fixture.normalize(hookToolMarker, extra: extra)
            #expect(batch.sources.isEmpty)
            #expect(batch.coverageGaps.first?.diagnosticCode == .unresolvedIdentity)
            #expect(batch.coverageGaps.first?.requiresAnalysis == true)
        }
        #expect(await fixture.bindings.count == 0)
        let owned = try await fixture.normalize(hookToolMarker, extra: ["agent_id": NSNull(), "agent_type": NSNull()])
        #expect(owned.sources.count == 1)
        #expect(await fixture.bindings.count == 1)
    }

    @Test func binaryEncryptedAndUnknownBlocksDoNotHideReadableSiblings() async throws {
        let fixture = try HookToolFixture()
        let response: [String: Any] = ["content": [
            ["type": "text", "text": hookToolMarker],
            ["type": "image", "data": "BINARY_MUST_NOT_BE_SCANNED"],
            ["type": "encrypted_content", "encrypted_content": "CIPHERTEXT_MUST_NOT_BE_SCANNED"],
            ["type": "futureBlock", "text": "future " + hookToolMarker],
            ["type": "resource", "resource": ["blob": "RESOURCE_BLOB_MUST_NOT_BE_SCANNED", "mimeType": "image/png"]]
        ], "isError": false]
        let batch = try await fixture.normalize(response, tool: "mcp__fixture__read")
        let texts = hookToolTexts(batch)
        #expect(texts["/tool_response/content/0/text"] == hookToolMarker)
        #expect(texts["/tool_response/content/3/text"] == "future " + hookToolMarker)
        #expect(!texts.values.contains { $0.contains("MUST_NOT_BE_SCANNED") })
        #expect(batch.coverageGaps.contains { $0.diagnosticCode == .excludedBinaryContent && !$0.requiresAnalysis })
        #expect(batch.coverageGaps.contains { $0.diagnosticCode == .encryptedContentUnavailable && $0.requiresAnalysis })
        #expect(batch.coverageGaps.contains { $0.diagnosticCode == .unknownBlockKind && $0.requiresAnalysis })
    }

    @Test func genericNestedJSONAndTextFreeResultsHaveStableReceipts() async throws {
        let fixture = try HookToolFixture()
        let response: [String: Any] = ["result": ["a": ["content": [["answer": hookToolMarker]]]],
            "blob": "ordinary string", "type": "application kind"]
        let batch = try await fixture.normalize(response, tool: "some_local_function")
        #expect(hookToolTexts(batch)["/tool_response/result/a/content/0/answer"] == hookToolMarker)
        #expect(hookToolTexts(batch)["/tool_response/blob"] == "ordinary string")
        #expect(hookToolTexts(batch)["/tool_response/type"] == "application kind")
        #expect(batch.coverageGaps.isEmpty)
        let textFreeResponses: [Any] = [NSNull(), true, 42, [:] as [String: Any]]
        for (index, response) in textFreeResponses.enumerated() {
            let empty = try await fixture.normalize(response, call: "empty-\(index)")
            #expect(empty.sources.count == 1 && empty.coverageGaps.isEmpty)
            #expect(empty.sources.first?.record.segments.first?.utf8.isEmpty == true)
            let replay = try await fixture.normalize(response, call: "empty-\(index)")
            #expect(replay.sources.first?.record.revision == empty.sources.first?.record.revision)
        }
    }

    @Test func arbitraryBusinessJSONDoesNotBecomeMediaOrExecutionStatus() async throws {
        let fixture = try HookToolFixture()
        for (index, type) in ["image", "audio", "tool_reference", "encrypted_content", "text"].enumerated() {
            let batch = try await fixture.normalize(["type": type, "caption": hookToolMarker,
                "encrypted_content": "ordinary application field", "resource": ["blob": "ordinary application blob"],
                "error": "business error field", "status": "failed", "success": false, "isError": true, "exit_code": 1],
                call: "business-\(index)", tool: "some_local_function")
            #expect(batch.sources.first?.record.metadata.contentType == .toolOutput)
            #expect(hookToolTexts(batch)["/tool_response/type"] == type)
            #expect(hookToolTexts(batch)["/tool_response/caption"] == hookToolMarker)
            #expect(hookToolTexts(batch)["/tool_response/encrypted_content"] == "ordinary application field")
            #expect(hookToolTexts(batch)["/tool_response/resource/blob"] == "ordinary application blob")
            #expect(batch.coverageGaps.isEmpty)
        }
        let ordinaryArray = try await fixture.normalize([["type": "image", "caption": hookToolMarker]], call: "array")
        #expect(hookToolTexts(ordinaryArray)["/tool_response/0/caption"] == hookToolMarker)
        #expect(ordinaryArray.coverageGaps.isEmpty)
        let nativeBlocks = try await fixture.normalize([
            ["type": "input_text", "text": hookToolMarker],
            ["type": "input_image", "image_url": "BINARY_MUST_NOT_BE_SCANNED"],
            ["type": "encrypted_content", "encrypted_content": "CIPHERTEXT_MUST_NOT_BE_SCANNED"]
        ], call: "native-blocks")
        #expect(hookToolTexts(nativeBlocks) == ["/tool_response/0/text": hookToolMarker])
        #expect(nativeBlocks.coverageGaps.contains { $0.diagnosticCode == .excludedBinaryContent })
        #expect(nativeBlocks.coverageGaps.contains { $0.diagnosticCode == .encryptedContentUnavailable && $0.requiresAnalysis })
    }

    @Test func excessiveDepthAndSegmentsProduceBoundedPartialCoverage() async throws {
        let fixture = try HookToolFixture()
        var nested: Any = hookToolMarker
        for _ in 0..<40 { nested = ["next": nested] }
        let depth = try await fixture.normalize(["first": hookToolMarker, "nested": nested])
        #expect(hookToolTexts(depth)["/tool_response/first"] == hookToolMarker)
        #expect(depth.coverageGaps.contains { $0.diagnosticCode == .readBudgetExceeded && $0.requiresAnalysis })
        let many = try await fixture.normalize(Array(repeating: hookToolMarker, count: 1100), call: "many")
        #expect(many.sources.first?.record.segments.count == 1024)
        #expect(many.coverageGaps.contains { $0.reason == .budgetExhausted && $0.requiresAnalysis })
    }

    @Test func longSharedKeyCannotAmplifySegmentIdentifiersBeyondTheEventBudget() async throws {
        let fixture = try HookToolFixture()
        let longKey = String(repeating: "k", count: 200 * 1024) // Sorts after "a".
        for (call, children) in [("strings", Array(repeating: "x", count: 300) as [Any]),
                                 ("nulls", Array(repeating: NSNull(), count: 2000) as [Any])] {
            let batch = try await fixture.normalize(["a": hookToolMarker, longKey: children], call: call,
                tool: "some_local_function")
            let segments = try #require(batch.sources.first?.record.segments)
            #expect(segments.reduce(0) { $0 + $1.id.utf8.count } <= 1024 * 1024)
            #expect(hookToolTexts(batch)["/tool_response/a"] == hookToolMarker)
            #expect(batch.coverageGaps.contains {
                $0.reason == .budgetExhausted && $0.diagnosticCode == .readBudgetExceeded && $0.requiresAnalysis })
        }
    }

    @Test func promptAndFinalRevisionRepresentationRemainsCompatibleWithVersionOne() async throws {
        let fixture = try HookToolFixture()
        for (event, field) in [("UserPromptSubmit", "prompt"), ("Stop", "last_assistant_message")] {
            let data = try JSONSerialization.data(withJSONObject: ["hook_event_name": event, "session_id": "session",
                "turn_id": "turn", field: hookToolMarker, "stop_hook_active": false])
            let packet = try CapturePacket(metadata: .init(agent: .codex, interface: .desktopCode, profileID: "synthetic"), eventJSON: data)
            let batch = try await fixture.adapter.normalize(packet, capturedAt: hookToolTime, cryptography: fixture.crypto)
            let source = try #require(batch.sources.first?.record)
            let oldItem = "codex-hook-v1:" + (try JSONEncoder().encode(["turn", event])).base64EncodedString()
            var oldCanonical = Data("codex-hook-content-v1".utf8)
            for bytes in [Data(("/" + field).utf8), Data(hookToolMarker.utf8)] {
                var length = UInt64(bytes.count).bigEndian
                withUnsafeBytes(of: &length) { oldCanonical.append(contentsOf: $0) }
                oldCanonical.append(bytes)
            }
            #expect(source.metadata.identity.itemID == oldItem)
            #expect(source.revision == (try await fixture.crypto.revision(canonicalBytes: oldCanonical)))
        }
    }
}
