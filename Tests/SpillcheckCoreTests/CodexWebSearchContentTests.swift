import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

@Suite("Codex native web result content")
struct CodexWebSearchContentTests {
    @Test func nativeResultsRetainExactStringsAndPointersWithoutRequestText() async throws {
        let printedJSON = "{\"snippet\":\"literal\\nbytes\"}"
        let entry = try codexItem("web-native", type: "webSearch", body: [
            "query": "request-only-marker", "action": ["type": "search", "query": "other-request-marker"],
            "results": [["title": "Result title", "a/b~": "Unicode 🧪", "content": [
                ["type": "custom-result", "body": "readable body"]], "type": "image", "caption": "readable caption"],
                printedJSON]])
        let adapter = try codexTestAdapter(version: "0.162.1")
        let batch = try await adapter.importPublicItems(.init(data: [entry]), thread: codexThread("native-thread"),
            observedAt: Date(), cryptography: BackgroundCryptography.ephemeralForTesting())
        let source = try #require(batch.sources.first)
        #expect(source.record.metadata.contentType == .toolOutput)
        #expect(source.record.metadata.identity.session.sessionID == "native-thread")
        #expect(source.record.metadata.identity.itemID == "web-native")
        #expect(source.record.metadata.locator == .upstreamItem)
        let strings = Dictionary(uniqueKeysWithValues: source.record.segments.map { ($0.id, String(decoding: $0.utf8, as: UTF8.self)) })
        #expect(strings["/results/0/a~1b~0"] == "Unicode 🧪")
        #expect(strings["/results/0/content/0/body"] == "readable body")
        #expect(strings["/results/0/caption"] == "readable caption")
        #expect(strings["/results/0/type"] == "image")
        #expect(strings["/results/1"] == printedJSON)
        #expect(source.record.segments.allSatisfy { $0.id.hasPrefix("/results/") })
        #expect(!codexText(source).contains("request-marker") && !codexText(source).contains("request-only-marker"))
        #expect(batch.coverageGaps.isEmpty && batch.recoveredReferences.count == 1)
    }

    @Test func unavailableResultsCannotBecomeRequestOrFinalReplyCoverage() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1")
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        for payload: [String: Any] in [[:], ["results": NSNull()], ["results": "malformed-result"], ["results": ["text": "malformed-shape"]]] {
            var body = payload
            body["query"] = "not-an-output"
            let batch = try await adapter.importPublicItems(.init(data: [codexItem(type: "webSearch", body: body)]),
                thread: codexThread(), observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty)
            let gap = try #require(batch.coverageGaps.first)
            #expect(gap.isRequiredFormatFailure == true && gap.requiresAnalysis)
            #expect(gap.contentType == .toolOutput && gap.sourceKind == .codexWebSearch)
            #expect(gap.recovery?.itemID == "native" && gap.recovery?.session?.sessionID == "parent")
            #expect(gap.diagnosticCode == (payload["results"] == nil || payload["results"] is NSNull ? .missingPayload : .invalidFieldType))
        }
    }

    @Test func explicitEmptyOrTextFreeResultsDoNotInventMissingText() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1")
        for result: [Any] in [[], [NSNull(), 12, false, "", [:]]] {
            let batch = try await adapter.importPublicItems(.init(data: [codexItem(type: "webSearch", body: ["results": result])]),
                thread: codexThread(), observedAt: Date(), cryptography: BackgroundCryptography.ephemeralForTesting())
            #expect(batch.sources.isEmpty && batch.coverageGaps.isEmpty)
            #expect(batch.recoveredReferences.count == 1)
        }
    }

    @Test func resultRevisionsRemainStableAcrossReplayAndRequestMetadataChanges() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1")
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        var sources: [CollectedSource] = []
        for (query, snippet) in [("first query", "result"), ("updated query", "result"), ("updated query", "changed result")] {
            let batch = try await adapter.importPublicItems(.init(data: [codexItem(type: "webSearch", body: [
                "query": query, "results": [["snippet": snippet, "url": "https://example.invalid/fake"]]])]),
                thread: codexThread(), observedAt: Date(), cryptography: crypto)
            sources.append(try #require(batch.sources.first))
        }
        #expect(sources[0].record.metadata.identity == sources[1].record.metadata.identity)
        #expect(sources[0].record.revision == sources[1].record.revision)
        #expect(sources[0].record.segments == sources[1].record.segments)
        #expect(sources[0].record.metadata.identity == sources[2].record.metadata.identity)
        #expect(sources[0].record.revision != sources[2].record.revision)
    }

    @Test func arbitraryResultDiscriminantsDoNotImportAgentMessageEncryptionSemantics() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1")
        let batch = try await adapter.importPublicItems(.init(data: [codexItem(type: "webSearch", body: ["results": [
            ["type": "encrypted_content", "encrypted_content": "ordinary result string", "caption": "readable sibling"],
            ["encrypted_content": "ordinary business field"]]])]), thread: codexThread(), observedAt: Date(),
            cryptography: BackgroundCryptography.ephemeralForTesting())
        let source = try #require(batch.sources.first)
        #expect(codexText(source).contains("readable sibling") && codexText(source).contains("ordinary business field"))
        #expect(codexText(source).contains("ordinary result string"))
        #expect(batch.recoveredReferences.count == 1 && batch.coverageGaps.isEmpty)
    }

    @Test func arbitraryResultFieldTypesDoNotInventMalformedProviderContent() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1")
        let batch = try await adapter.importPublicItems(.init(data: [codexItem(type: "webSearch", body: ["results": [
            ["type": "encrypted_content", "encrypted_content": 42, "caption": "readable sibling"]]])]),
            thread: codexThread(), observedAt: Date(), cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(batch.sources.count == 1 && batch.recoveredReferences.count == 1)
        #expect(batch.coverageGaps.isEmpty)
    }

    @Test func depthAndSegmentBudgetsKeepReadableContentAndRequiredGap() async throws {
        var deep: CodexJSON = .string("beyond-depth-budget")
        for _ in 0..<34 { deep = .array([deep]) }
        let many = CodexJSON.array((0..<1025).map { .string("fake result \($0)") })
        let adapter = try codexTestAdapter(version: "0.162.1")
        for results in [CodexJSON.array([.string("readable sibling"), deep]), many] {
            let entry: CodexJSON = .object(["turnId": .string("turn"), "completedAtMs": .number(1_791_434_400_000),
                "item": .object(["type": .string("webSearch"), "id": .string("web-budget"), "results": results])])
            let batch = try await adapter.importPublicItems(.init(data: [entry]), thread: codexThread(), observedAt: Date(),
                cryptography: BackgroundCryptography.ephemeralForTesting())
            #expect(batch.sources.count == 1 && batch.recoveredReferences.isEmpty)
            #expect(batch.sources[0].record.segments.count <= 1024)
            #expect(!codexText(batch.sources[0]).contains("beyond-depth-budget"))
            #expect(batch.coverageGaps.contains { $0.reason == .budgetExhausted && $0.diagnosticCode == .readBudgetExceeded
                && $0.isRequiredFormatFailure == true && $0.recovery?.itemID == "web-budget" })
        }
    }

    @Test func aggregateNodeAndByteBudgetsBoundOpaqueJSONTraversal() throws {
        var nodeLimited = CodexWebSearchContent(maximumTextBytes: 1024)
        try nodeLimited.collect(.array(Array(repeating: .null, count: 8192)))
        #expect(nodeLimited.budgetExceeded && nodeLimited.segments.isEmpty)
        var byteLimited = CodexWebSearchContent(maximumTextBytes: 5)
        try byteLimited.collect(.array([.string("four"), .string("🧪"), .string("a")]))
        #expect(byteLimited.budgetExceeded)
        #expect(byteLimited.segments.map { String(decoding: $0.utf8, as: UTF8.self) } == ["four", "a"])
        #expect(byteLimited.segments.reduce(0) { $0 + $1.utf8.count } == 5)
    }

    @Test func longSharedKeyCannotAmplifyOneRowIntoThousandsOfLargeCoordinates() async throws {
        let maximumRowBytes = 1024 * 1024
        let longKey = String(repeating: "z", count: 900 * 1024)
        let entry = try codexItem("web-long-key", type: "webSearch", body: ["results": [
            ["a": "readable result", longKey: Array(repeating: "x", count: 1024)]]])
        #expect(try JSONEncoder().encode(entry).count < maximumRowBytes)
        let adapter = try codexTestAdapter(version: "0.162.1")
        let batch = try await adapter.importPublicItems(.init(data: [entry]), thread: codexThread(), observedAt: Date(),
            cryptography: BackgroundCryptography.ephemeralForTesting())
        let source = try #require(batch.sources.first)
        #expect(source.record.segments.map(\.id) == ["/results/0/a"])
        #expect(source.record.segments.reduce(0) { $0 + $1.id.utf8.count } <= maximumRowBytes)
        #expect(codexText(source) == "readable result")
        #expect(batch.recoveredReferences.isEmpty)
        #expect(batch.coverageGaps.contains { $0.diagnosticCode == .readBudgetExceeded
            && $0.isRequiredFormatFailure == true && $0.recovery?.itemID == "web-long-key" })
    }

    @Test func pointerBudgetExhaustionIsTerminalAcrossRemainingSiblings() throws {
        var parsed = CodexWebSearchContent(maximumTextBytes: 1024, maximumPointerBytes: 32)
        try parsed.collect(.object(["a": .string("kept"), "large": .array([.string("not-admitted")]),
            "z": .string("must-not-resume-after-pointer-budget")]))
        #expect(parsed.budgetExceeded)
        #expect(parsed.segments.map { String(decoding: $0.utf8, as: UTF8.self) } == ["kept"])
        try parsed.collect(.string("no-independent-reentry"), pointer: "/a")
        #expect(parsed.segments.count == 1)
    }
}
