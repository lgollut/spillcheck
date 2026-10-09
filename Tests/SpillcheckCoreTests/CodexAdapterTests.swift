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
    func configure(_ id: String, thread: CodexJSON, pages: [CodexHistoryPage], turns: CodexHistoryPage = .init(data: [])) {
        metadata[id] = thread; items[id] = pages; self.turns[id] = turns
    }
    func configureListings(_ pages: [CodexHistoryPage], archived: Bool) { listings[archived] = pages }
    func configureDescending(_ id: String, page: CodexHistoryPage) { descending[id] = page }
    func readThread(_ threadID: String) throws -> CodexThreadRead {
        calls.append("read:\(threadID)")
        guard let thread = metadata[threadID] else { throw CodexHistoryError.unavailable }
        return .init(thread: thread, bytesRead: 64)
    }
    func listThreads(cursor: String?, limit: Int, archived: Bool) -> CodexHistoryPage {
        calls.append("list:\(archived)")
        return listings[archived]?[Int(cursor ?? "0") ?? 0] ?? .init(data: [])
    }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection) -> CodexHistoryPage {
        calls.append("turns:\(threadID)"); return turns[threadID] ?? .init(data: [])
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int,
                   direction: CodexHistoryDirection) -> CodexHistoryPage {
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

@Suite("Codex measured canonical public collection")
struct CodexAdapterTests {
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
        #expect(batch.coverageGaps.isEmpty && childBatch.coverageGaps.isEmpty)
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

    @Test func producerVersionsAndT3TupleAreExclusiveRatherThanMinimumVersionClaims() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting(), page = CodexHistoryPage(data: [try codexItem()])
        for adapter in [try codexTestAdapter(version: "0.161.1"), try codexTestAdapter(t3Version: nil),
                        try codexTestAdapter(t3Version: "other"), try codexTestAdapter(interface: .desktopCode)] {
            #expect(adapter.capabilities().allSatisfy { $0.validation == .unsupported })
            let result = try await adapter.normalize(codexPacket(thread: "parent", interface: adapter.interface), capturedAt: Date(), cryptography: crypto)
            #expect(result.coverageGaps == [.init(reason: .unsupportedVersion)])
        }
        let standalone = try codexTestAdapter(interface: .standaloneCLI)
        #expect(try await standalone.importPublicItems(page, thread: codexThread(producer: "0.160.1"), observedAt: Date(), cryptography: crypto).sources.isEmpty)
        let valid = try await standalone.importPublicItems(page, thread: codexThread(producer: "0.161.0"), observedAt: Date(), cryptography: crypto)
        #expect(valid.sources.count == 1 && valid.sources[0].record.metadata.origin.agentVersion == "0.161.0")
        let t3 = try codexTestAdapter()
        #expect(try await t3.importPublicItems(page, thread: codexThread(producer: "0.161.0"), observedAt: Date(), cryptography: crypto).sources.isEmpty)
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

    @Test func exactDecodedUnicodeStructuredFieldsAndBinaryExclusion() async throws {
        let item = try codexItem("mcp", type: "mcpToolCall", body: ["status": "completed", "error": NSNull(),
            "result": ["content": [["type": "text", "text": "é🙂\r\n"]],
                       "structuredContent": ["a/b": "synthetic", "blob": ["type": "image", "data": "excluded"]]]])
        let batch = try await codexTestAdapter().importPublicItems(.init(data: [item]), thread: codexThread(), observedAt: Date(),
            cryptography: BackgroundCryptography.ephemeralForTesting())
        let source = try #require(batch.sources.first)
        #expect(source.record.segments.map(\.id) == ["/result/content/0/text", "/result/structuredContent/a~1b"])
        #expect(source.record.segments.map(\.utf8) == [Data("é🙂\r\n".utf8), Data("synthetic".utf8)])
    }

    @Test func coarseTurnTimesDoNotInventCoverageAcrossSevenDayBoundary() async throws {
        let end = Date(timeIntervalSince1970: 1_791_434_400), audit = try HistoricalAuditContext(reason: .firstLaunch, endingAt: end)
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let coarse = try codexItem(timestamp: nil)
        let crossing = try await adapter.importPublicItems(.init(data: [coarse]), thread: codexThread(), observedAt: end,
            provenance: .historical(audit), turnTimes: ["turn": DateInterval(start: audit.start.addingTimeInterval(-1), end: audit.start.addingTimeInterval(1))],
            cryptography: crypto)
        #expect(crossing.sources.isEmpty && crossing.coverageGaps == [.init(reason: .missingTimestamp)])
        let inside = try await adapter.importPublicItems(.init(data: [coarse]), thread: codexThread(), observedAt: end,
            provenance: .historical(audit), turnTimes: ["turn": DateInterval(start: audit.start.addingTimeInterval(1), end: audit.start.addingTimeInterval(2))],
            cryptography: crypto)
        #expect(inside.sources.count == 1)
    }
}
