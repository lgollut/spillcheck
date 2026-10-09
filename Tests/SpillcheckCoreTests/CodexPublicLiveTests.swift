import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private struct CodexLiveThreadReport: Codable {
    var threadID: String
    var metadataMatches = false
    var cliVersion: String?
    var metadataBytes = 0
    var itemBytes = 0
    var turnBytes = 0
    var nativeItemIDs: [String] = []
    var itemTypes: [String: Int] = [:]
    var datedItems = 0
    var undatedItems = 0
    var turnCount = 0
    var datedTurns = 0
    var markerCounts: [String: Int] = [:]
    var typedMarkerCounts: [String: Int] = [:]
    var contentTypeCounts: [String: Int] = [:]
    var mappedGapReasons: [String] = []
    var cursorProbeDescendingIDs: [String] = []
    var cursorProbeAscendingIDs: [String] = []
    var cursorProbeFromNextIDs: [String] = []
    var cursorProbeBackwardsCursorPresent = false
    var status = "unverified"
    var errorCode: Int?
}
private struct CodexLiveReadReport: Encodable {
    let schemaVersion = 2
    let readerVersion = "0.161.0"
    let byteAccounting = "JSON-RPC wire bytes including cold initialize; version CLI control output excluded"
    let passive = true
    let resumeCalls = 0
    let startCalls = 0
    let networkDenied = true
    let forkDenied = true
    var threads: [CodexLiveThreadReport]
}

@Suite("Opt-in original-store public Codex history")
struct CodexPublicLiveTests {
    @Test func exactOwnedThreadsAreReadPassivelyThroughProductionClient() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let home = env["SPILLCHECK_CODEX_PROBE_HOME"],
              let configuredIDs = env["SPILLCHECK_CODEX_PROBE_THREAD_IDS"],
              let reportPath = env["SPILLCHECK_CODEX_PROBE_REPORT"] else { return }
        let executable = try #require(env["SPILLCHECK_CODEX_PROBE_EXECUTABLE"],
            "Set SPILLCHECK_CODEX_PROBE_EXECUTABLE when enabling the live Codex probe")
        let ids = configuredIDs.split(separator: ",").map(String.init)
        #expect(!ids.isEmpty && ids.count <= 4)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-codex-public-probe-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let client = CodexAppServerHistoryClient(configuration: try .init(
            executableURL: URL(fileURLWithPath: executable),
            codexHomeURL: URL(fileURLWithPath: home), workingDirectoryURL: work))
        var results: [CodexLiveThreadReport] = []
        let markers = ["PROMPT", "INTERMEDIATE", "FINAL", "SHELL_OK", "SHELL_ERROR", "MCP_OK", "MCP_ERROR", "CHILD_PROMPT", "CHILD_FINAL"]
        for id in ids {
            var result = CodexLiveThreadReport(threadID: id)
            do {
                let thread = try await client.readThread(id)
                result.metadataMatches = thread.thread["id"].string == id
                result.cliVersion = thread.thread["cliVersion"].string
                result.metadataBytes = thread.bytesRead
                var recordedItems: [CodexJSON] = []
                var cursor: String?
                var count = 0
                repeat {
                    let page = try await client.listItems(threadID: id, cursor: cursor, limit: 64)
                    result.itemBytes += page.bytesRead
                    recordedItems += page.data
                    for entry in page.data {
                        let item = entry["item"]
                        if let identity = item["id"].string { result.nativeItemIDs.append(identity) }
                        if let type = item["type"].string { result.itemTypes[type, default: 0] += 1 }
                        if entry["completedAtMs"].number != nil || entry["startedAtMs"].number != nil { result.datedItems += 1 }
                        else { result.undatedItems += 1 }
                        let segments = try codexTextSegments(item, pointer: "/item")
                        for suffix in markers {
                            let marker = Data("LEAKRET_M4_\(suffix)".utf8)
                            result.markerCounts[suffix, default: 0] += segments.reduce(0) { $0 + ($1.utf8.range(of: marker) == nil ? 0 : 1) }
                        }
                    }
                    count += 1
                    guard page.nextCursor != cursor || page.nextCursor == nil else { throw CodexHistoryError.malformedResponse }
                    cursor = page.nextCursor
                } while cursor != nil && count < 16 && result.itemBytes < 100 * 1024 * 1024
                let turns = try await client.listTurns(threadID: id, cursor: nil, limit: 256)
                result.turnBytes += turns.bytesRead
                result.turnCount = turns.data.count
                result.datedTurns = turns.data.filter { $0["startedAt"].number != nil }.count
                let crypto = try BackgroundCryptography.ephemeralForTesting()
                let isT3 = thread.thread["cliVersion"].string == CodexAdapter.validatedT3ProducerVersion
                let adapter = try codexTestAdapter(interface: isT3 ? .t3 : .standaloneCLI)
                let mapped = try await adapter.importPublicItems(.init(data: recordedItems), thread: thread.thread,
                    observedAt: Date(), cryptography: crypto)
                result.contentTypeCounts = Dictionary(grouping: mapped.sources, by: { $0.record.metadata.contentType.rawValue }).mapValues(\.count)
                result.mappedGapReasons = mapped.coverageGaps.map(\.reason.rawValue).sorted()
                let expected: [(ContentType, String)] = [(.userPrompt, "PROMPT"), (.intermediateResponse, "INTERMEDIATE"),
                    (.finalResponse, "FINAL"), (.toolOutput, "SHELL_OK"), (.toolError, "SHELL_ERROR"),
                    (.toolOutput, "MCP_OK"), (.toolError, "MCP_ERROR"), (.finalResponse, "CHILD_FINAL")]
                for (type, marker) in expected {
                    result.typedMarkerCounts[marker] = mapped.sources.filter {
                        $0.record.metadata.contentType == type && codexText($0).contains("LEAKRET_M4_\(marker)")
                    }.count
                }
                if env["SPILLCHECK_CODEX_CURSOR_PROBE"] == "1" {
                    let tail = try await client.listItems(threadID: id, cursor: nil, limit: 2, direction: .descending)
                    result.cursorProbeDescendingIDs = tail.data.compactMap { $0["item"]["id"].string }
                    result.cursorProbeBackwardsCursorPresent = tail.backwardsCursor != nil
                    if let boundary = tail.backwardsCursor {
                        let newer = try await client.listItems(threadID: id, cursor: boundary, limit: 2, direction: .ascending)
                        result.cursorProbeAscendingIDs = newer.data.compactMap { $0["item"]["id"].string }
                    }
                    if let boundary = tail.nextCursor {
                        let replay = try await client.listItems(threadID: id, cursor: boundary, limit: 64, direction: .ascending)
                        result.cursorProbeFromNextIDs = replay.data.compactMap { $0["item"]["id"].string }
                    }
                    if let fixtureDirectory = env["SPILLCHECK_CODEX_PROBE_FIXTURE_DIRECTORY"] {
                        let cursorFixture = CodexJSON.object(["thread": .object(["id": .string(id),
                            "cliVersion": thread.thread["cliVersion"]]), "descendingItems": .array(tail.data),
                            "backwardsCursor": tail.backwardsCursor.map(CodexJSON.string) ?? .null,
                            "nextCursor": tail.nextCursor.map(CodexJSON.string) ?? .null,
                            "ascendingItems": .array(result.cursorProbeAscendingIDs.map(CodexJSON.string))])
                        try JSONEncoder().encode(cursorFixture).write(to: URL(fileURLWithPath: fixtureDirectory)
                            .appendingPathComponent("\(id)-cursor.json"), options: .atomic)
                    }
                }
                if let fixtureDirectory = env["SPILLCHECK_CODEX_PROBE_FIXTURE_DIRECTORY"] {
                    // Opt-in, explicitly owned synthetic sessions only. User history is never
                    // enumerated. Metadata paths and titles are excluded from checked-in fixtures.
                    let fixture = CodexJSON.object([
                        "thread": .object(["id": .string(id), "cliVersion": thread.thread["cliVersion"]]),
                        "items": .array(recordedItems), "turns": .array(turns.data)
                    ])
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(fixture).write(to: URL(fileURLWithPath: fixtureDirectory)
                        .appendingPathComponent("\(id).json"), options: .atomic)
                }
                result.status = cursor == nil ? "read-complete" : "bounded-partial"
            } catch CodexHistoryError.remoteFailure(let code) {
                result.status = "public-route-error"; result.errorCode = code
            } catch let error as CodexHistoryError {
                switch error {
                case .timedOut: result.status = "timed-out"
                case .unsupportedVersion: result.status = "unsupported-version"
                case .unsafeMethod: result.status = "unexpected-server-request"
                default: result.status = "client-unavailable"
                }
            }
            results.append(result)
        }
        await client.close()
        let report = CodexLiveReadReport(threads: results)
        let data = try JSONEncoder().encode(report)
        try data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        #expect(results.allSatisfy { $0.metadataMatches })
    }
}
