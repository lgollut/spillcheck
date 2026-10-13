import CryptoKit
import Darwin
import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

// Disposable fake material only. These controls never create or open Keychain keys.
private let mcpValue = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
private let mcpVersion = "0.162.1"
private let mcpProfile = "disposable-native-mcp-pipeline"
private enum MCPPipelineError: Error { case boundary, evidence, budget }
private func demand(_ condition: Bool) throws { guard condition else { throw MCPPipelineError.evidence } }
private func boundedID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
}
private func tokenCount(_ data: Data) -> Int {
    String(decoding: data, as: UTF8.self).components(separatedBy: mcpValue).count - 1
}
private func privateDirectory(_ url: URL) throws {
    var s = stat()
    guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR, s.st_uid == getuid(),
          s.st_mode & 0o077 == 0, let path = realpath(url.path, nil) else { throw MCPPipelineError.boundary }
    defer { free(path) }
    guard String(cString: path) == url.path else { throw MCPPipelineError.boundary }
}
private func absent(_ url: URL) -> Bool { var s = stat(); return lstat(url.path, &s) == -1 && errno == ENOENT }
private func makeDirectory(_ url: URL) throws {
    guard mkdir(url.path, 0o700) == 0 else { throw MCPPipelineError.boundary }
    try privateDirectory(url)
}
private func privateBytes(_ url: URL, limit: Int = 512 * 1024) throws -> Data {
    try privateDirectory(url.deletingLastPathComponent())
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw MCPPipelineError.boundary }
    defer { close(fd) }
    var first = stat(), last = stat(), named = stat()
    guard fstat(fd, &first) == 0, first.st_mode & S_IFMT == S_IFREG, first.st_uid == getuid(),
          first.st_nlink == 1, first.st_mode & 0o077 == 0, first.st_size >= 0, first.st_size <= limit else {
        throw MCPPipelineError.boundary
    }
    var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n == 0 { break }
        guard n > 0, bytes.count <= limit - n else { throw MCPPipelineError.boundary }
        bytes.append(contentsOf: buffer.prefix(n))
    }
    guard fstat(fd, &last) == 0, lstat(url.path, &named) == 0,
          first.st_dev == last.st_dev, first.st_ino == last.st_ino, first.st_size == last.st_size,
          first.st_mtimespec.tv_sec == last.st_mtimespec.tv_sec,
          first.st_mtimespec.tv_nsec == last.st_mtimespec.tv_nsec,
          named.st_dev == first.st_dev, named.st_ino == first.st_ino,
          named.st_nlink == 1, named.st_mode == first.st_mode, bytes.count == first.st_size else {
        throw MCPPipelineError.boundary
    }
    return bytes
}
private func writePrivate(_ bytes: Data, to url: URL) throws {
    try privateDirectory(url.deletingLastPathComponent())
    guard bytes.count <= 512 * 1024 else { throw MCPPipelineError.boundary }
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw MCPPipelineError.boundary }
    defer { close(fd) }
    try bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            guard n > 0 else { throw MCPPipelineError.boundary }
            offset += n
        }
    }
    guard fsync(fd) == 0 else { throw MCPPipelineError.boundary }
}
private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}
private func load<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
    try JSONDecoder().decode(type, from: privateBytes(url))
}

private struct InventoryCommitment: Codable, Equatable {
    let counts: [String: Int]
    let digests: [String: [String]]
    let schemaVersion: Int, nextValueLabel: Int, payloadCount: Int
}
private struct Pair<K: Encodable, V: Encodable>: Encodable { let key: K; let value: V }

private func canonical<T: Encodable>(_ value: T) throws -> Data {
    let raw = try encoded(value)
    try demand(raw.count <= 256 * 1024)
    let json = try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])
    func normalize(_ value: Any, key: String? = nil) throws -> Any {
        if let object = value as? [String: Any] {
            return try Dictionary(uniqueKeysWithValues: object.map { ($0.key, try normalize($0.value, key: $0.key)) })
        }
        if let array = value as? [Any] {
            let values = try array.map { try normalize($0) }
            if ["categories", "origins", "evidence", "locations"].contains(key ?? "") {
                return try values.map { (try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]), $0) }
                    .sorted { $0.0.lexicographicallyPrecedes($1.0) }.map(\.1)
            }
            return values
        }
        return value
    }
    return try JSONSerialization.data(withJSONObject: normalize(json), options: [.sortedKeys, .fragmentsAllowed])
}
private func commitment<T: Encodable>(_ domain: String, _ value: T, crypto: BackgroundCryptography) async throws -> String {
    var bytes = Data(("mcp-pipeline-probe-v1/" + domain + "\n").utf8)
    bytes.append(try canonical(value))
    return try await crypto.revision(canonicalBytes: bytes).keyedDigest.base64EncodedString()
}
private func inventoryCommitment(_ snapshot: InventorySnapshot, store: ProtectedStore,
                                 crypto: BackgroundCryptography) async throws -> InventoryCommitment {
    var counts: [String: Int] = [:], digests: [String: [String]] = [:]
    func rows<T: Encodable>(_ name: String, _ values: [T]) async throws {
        try demand(values.count <= 256); counts[name] = values.count
        var result: [String] = []
        for value in values { result.append(try await commitment(name, value, crypto: crypto)) }
        digests[name] = result.sorted()
    }
    func pairs<K: Encodable, V: Encodable>(_ name: String, _ values: [K: V]) async throws {
        try await rows(name, values.map { Pair(key: $0.key, value: $0.value) })
    }
    try await pairs("records", snapshot.records); try await pairs("occurrences", snapshot.occurrences)
    try await pairs("obsoleteMarkers", snapshot.obsoleteMarkers); try await pairs("obsoleteAppearances", snapshot.obsoleteAppearances)
    try await pairs("alerts", snapshot.alertDecisions); try await pairs("historicalNotifications", snapshot.historicalNotificationDecisions)
    try await pairs("unlocatedResults", snapshot.unlocatedResults); try await rows("analysisReceipts", Array(snapshot.analysisReceipts))
    try await pairs("locationReceipts", snapshot.locationReceipts); try await pairs("strongSignalReceipts", snapshot.strongSignalReceipts)
    try await rows("unlocatedReceipts", Array(snapshot.unlocatedReceipts)); try await pairs("sourceKinds", snapshot.sourceKinds)
    try await pairs("sourceTimes", snapshot.sourceTimes); try await pairs("conversationLabels", snapshot.conversationLabels)
    try await pairs("valueLabels", snapshot.valueLabels); try await pairs("unlocatedLabels", snapshot.unlocatedLabels)
    return .init(counts: counts, digests: digests, schemaVersion: snapshot.schemaVersion,
        nextValueLabel: snapshot.nextValueLabel, payloadCount: try await store.protectedPayloadCountForTesting())
}

private func verifyCiphertextFiles(_ controls: URL) throws {
    let manager = FileManager.default
    for directory in [controls.appendingPathComponent("store"), controls.appendingPathComponent("scanner")] {
        guard let files = manager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw MCPPipelineError.boundary
        }
        var count = 0
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            try demand(values.isSymbolicLink != true)
            if values.isRegularFile == true {
                count += 1; try demand(count <= 128)
                let bytes = try privateBytes(file, limit: 16 * 1024 * 1024)
                try demand(bytes.range(of: Data(mcpValue.utf8)) == nil)
            }
        }
    }
}

private let mcpSegments: [String: String] = [
    "/result/content/0/text": "SPILLCHECK_MCP_PROTOCOL_TEXT_42 " + mcpValue,
    "/result/structuredContent/type": "image",
    "/result/structuredContent/caption": "SPILLCHECK_MCP_BUSINESS_IMAGE_42 é🙂\r\n " + mcpValue,
    "/result/structuredContent/content/0/type": "encrypted_content",
    "/result/structuredContent/content/0/caption": "ordinary business encrypted label",
    "/result/structuredContent/content/0/encrypted_content": "ordinary business field " + mcpValue,
    "/result/structuredContent/content/0/a~1b~0": "escaped pointer text",
    "/result/structuredContent/resource/blob": "ordinary business blob " + mcpValue,
    "/result/structuredContent/printed": #"{"type":"image","caption":"literal\nbytes"}"#,
    "/result/structuredContent/error": "business error",
    "/result/structuredContent/status": "failed"
]
private func fixtureResult() throws -> CodexJSON {
    let value: [String: Any] = [
        "content": [["type": "text", "text": mcpSegments["/result/content/0/text"]!]],
        "structuredContent": ["type": "image", "caption": mcpSegments["/result/structuredContent/caption"]!,
            "content": [["type": "encrypted_content", "caption": "ordinary business encrypted label",
                "encrypted_content": mcpSegments["/result/structuredContent/content/0/encrypted_content"]!,
                "a/b~": "escaped pointer text"]],
            "resource": ["blob": mcpSegments["/result/structuredContent/resource/blob"]!],
            "printed": mcpSegments["/result/structuredContent/printed"]!, "error": "business error",
            "status": "failed", "exit_code": 7, "isError": true], "_meta": NSNull()]
    return try JSONDecoder().decode(CodexJSON.self, from: JSONSerialization.data(withJSONObject: value))
}
private func fixtureLocations() throws -> Set<CanonicalLocation> {
    try Set(mcpSegments.compactMap { pointer, text in
        let bytes = Data(text.utf8)
        guard let range = bytes.range(of: Data(mcpValue.utf8)) else { return nil }
        try demand(tokenCount(bytes) == 1)
        return try CanonicalLocation(segmentID: pointer, range: .init(range.lowerBound, range.upperBound))
    })
}
private struct MCPConfiguration: Sendable {
    let stage: String, root: URL, home: URL, executable: URL, report: URL, scanner: URL, rules: URL
    let thread: String, turn: String, item: String
    var controls: URL { root.appendingPathComponent("pipeline") }
    var store: URL { controls.appendingPathComponent("store") }
    init(_ environment: [String: String]) throws {
        func field(_ name: String) throws -> String {
            guard let value = environment["SPILLCHECK_MCP_PIPELINE_" + name], !value.isEmpty else { throw MCPPipelineError.boundary }
            return value
        }
        stage = try field("STAGE"); root = URL(fileURLWithPath: try field("ROOT"))
        home = URL(fileURLWithPath: try field("HOME")); executable = URL(fileURLWithPath: try field("EXECUTABLE"))
        report = URL(fileURLWithPath: try field("REPORT")); scanner = URL(fileURLWithPath: try field("SCANNER_EXECUTABLE"))
        rules = URL(fileURLWithPath: try field("SCANNER_RULES")); thread = try field("THREAD")
        turn = try field("TURN"); item = try field("ITEM")
        try demand(["collect", "cold", "replay"].contains(stage)
            && root.deletingLastPathComponent().path == "/private/tmp"
            && root.lastPathComponent.hasPrefix("spillcheck-native-mcp-pipeline-")
            && home == root.appendingPathComponent("home")
            && report.lastPathComponent == stage + "-report.json" && absent(report)
            && UUID(uuidString: thread)?.uuidString.lowercased() == thread && boundedID(turn) && boundedID(item))
        try privateDirectory(root); try privateDirectory(home); try privateDirectory(report.deletingLastPathComponent())
        try demand(absent(home.appendingPathComponent("auth.json")))
    }
}
private struct MCPKeys: Codable { let schemaVersion: Int; let seed: Data; let manifest: ProtectionManifest }
private struct MCPBinding: Codable, Equatable, Sendable {
    let identity: SourceIdentity
    let turnID: String
    let revision: ContentRevision
    let contentTime: Date
    let locations: Set<CanonicalLocation>
    let nativeRowDigest: String
    let resultDigest: String
}
private struct MCPBaseline: Codable {
    let schemaVersion: Int, parserContract: String, detectorVersion: String
    let binding: MCPBinding
    let inventory: InventoryCommitment
    let receipts: Set<AnalysisReceipt>
    let initialCapture: UUID
    let fullScannerEvidence: Bool
}
private func saveBaseline(_ value: MCPBaseline, to url: URL, crypto: BackgroundCryptography, owner: UUID) async throws {
    let binding = PayloadBinding(reference: .init(), ownerID: owner, kind: .sourceCheckpoint)
    let payload = try await crypto.sealBackground(encoded(value), binding: binding)
    try writePrivate(payload.encoded(), to: url)
}
private func loadBaseline(_ url: URL, crypto: BackgroundCryptography, owner: UUID) async throws -> MCPBaseline {
    let payload = try ProtectedPayload.decode(privateBytes(url))
    try demand(payload.binding.ownerID == owner && payload.binding.kind == .sourceCheckpoint)
    return try JSONDecoder().decode(MCPBaseline.self, from: await crypto.openBackground(payload, binding: payload.binding))
}

// These are pass-through responses from the production reader. No separate pre-read
// manufactures the source proof, and no response is rewritten before normalization.
private actor MCPHistory: CodexHistoryReading {
    let client: CodexAppServerHistoryClient, config: MCPConfiguration
    var threadCalls = 0, itemCalls = 0, turnCalls = 0, listCalls = 0, targetCalls = 0
    var targetRow: CodexJSON?, turnTimes: [String: DateInterval] = [:]
    init(client: CodexAppServerHistoryClient, config: MCPConfiguration) { self.client = client; self.config = config }
    func counts() -> [String: Int] {
        ["threadReadCalls": threadCalls, "itemReadCalls": itemCalls, "turnReadCalls": turnCalls,
         "threadListCalls": listCalls, "nativeTargetReadCount": targetCalls]
    }
    func readThread(_ id: String) async throws -> CodexThreadRead {
        try await readThread(id, budget: .init(maximumBytes: 2 * 1024 * 1024, timeout: 8))
    }
    func readThread(_ id: String, budget: CodexRPCBudget) async throws -> CodexThreadRead {
        try demand(id == config.thread && threadCalls < 16)
        threadCalls += 1
        let value = try await client.readThread(id, budget: budget)
        try demand(value.readerVersion == mcpVersion && value.thread["id"].string == id
            && value.thread["cliVersion"].string == mcpVersion && value.thread["parentThreadId"] == .null
            && value.thread["forkedFromId"] == .null && value.thread["ephemeral"].bool == false
            && value.thread["cwd"].string == config.root.appendingPathComponent("work").path)
        return value
    }
    func listThreads(cursor: String?, limit: Int, archived: Bool) throws -> CodexHistoryPage {
        listCalls += 1; throw MCPPipelineError.boundary
    }
    func listThreads(cursor: String?, limit: Int, archived: Bool, budget: CodexRPCBudget) throws -> CodexHistoryPage {
        listCalls += 1; throw MCPPipelineError.boundary
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int,
                   direction: CodexHistoryDirection) async throws -> CodexHistoryPage {
        try await listItems(threadID: threadID, turnID: turnID, cursor: cursor, limit: limit,
            direction: direction, budget: .init(maximumBytes: 2 * 1024 * 1024, timeout: 8))
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int,
                   direction: CodexHistoryDirection, budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        try demand(threadID == config.thread && turnID == nil && cursor == nil && itemCalls < 16 && limit <= 256)
        itemCalls += 1
        let page = try await client.listItems(threadID: threadID, turnID: turnID, cursor: cursor, limit: limit,
            direction: direction, budget: budget)
        try demand(page.readerVersion == mcpVersion && page.nextCursor == nil && !page.data.isEmpty
            && page.data.count <= 256 && page.bytesRead > 0)
        var ids = Set<String>(), targets: [CodexJSON] = []
        for row in page.data {
            guard let id = row["item"]["id"].string, boundedID(id), ids.insert(id).inserted else { throw MCPPipelineError.evidence }
            try demand(row["turnId"].string == config.turn)
            let kind = row["item"]["type"].string ?? ""
            try demand(["userMessage", "agentMessage", "mcpToolCall", "reasoning"].contains(kind))
            if kind == "mcpToolCall" { targets.append(row) }
            else { try demand(tokenCount(try encoded(row)) == 0) }
        }
        try demand(targets.count == 1)
        let row = targets[0], item = row["item"]
        try demand(item["id"].string == config.item && item["server"].string == "spillcheck_opaque_fixture"
            && item["tool"].string == "opaque_business_result" && item["arguments"] == .object([:])
            && item["status"].string == "completed" && item["error"] == .null && item["result"] == fixtureResult()
            && tokenCount(try encoded(row)) == 4)
        if let targetRow { try demand(targetRow == row) }
        targetRow = row; targetCalls += 1
        return page
    }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection) async throws -> CodexHistoryPage {
        try await listTurns(threadID: threadID, cursor: cursor, limit: limit, direction: direction,
            budget: .init(maximumBytes: 2 * 1024 * 1024, timeout: 8))
    }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection,
                   budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        try demand(threadID == config.thread && cursor == nil && turnCalls < 16 && limit <= 256)
        turnCalls += 1
        let page = try await client.listTurns(threadID: threadID, cursor: cursor, limit: limit, direction: direction, budget: budget)
        try demand(page.readerVersion == mcpVersion && page.nextCursor == nil && page.data.count == 1)
        let row = page.data[0]
        guard row["id"].string == config.turn, let start = row["startedAt"].number,
              let end = row["completedAt"].number, start.isFinite, end.isFinite,
              abs(start) < 1e12, abs(end) < 1e12, end >= start else { throw MCPPipelineError.evidence }
        let interval = DateInterval(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
        if let prior = turnTimes[config.turn] { try demand(prior == interval) }
        turnTimes[config.turn] = interval
        return page
    }
    func original() throws -> (CodexJSON, Date) {
        guard let targetRow else { throw MCPPipelineError.evidence }
        if let ms = targetRow["completedAtMs"].number ?? targetRow["startedAtMs"].number,
           ms.isFinite, abs(ms) < 1e15 { return (targetRow, Date(timeIntervalSince1970: ms / 1000)) }
        guard targetRow["completedAtMs"] == .null, targetRow["startedAtMs"] == .null,
              let time = turnTimes[config.turn]?.end else { throw MCPPipelineError.evidence }
        return (targetRow, time)
    }
}

private func checkTarget(_ source: SourceRecord, config: MCPConfiguration, row: CodexJSON, time: Date,
                         crypto: BackgroundCryptography) async throws -> MCPBinding {
    let m = source.metadata
    try demand(m.identity.session.provider == .codex && m.identity.session.profileID == mcpProfile
        && m.identity.session.sessionID == config.thread && m.identity.itemID == config.item
        && m.contentType == .toolOutput && m.contentTime == time && m.locator == .upstreamItem && m.timeBasis == nil
        && m.origin.adapterID == "codex" && m.origin.adapterVersion == CodexAdapter.adapterVersion
        && m.origin.agentVersion == mcpVersion && m.origin.interface == .standaloneCLI
        && m.origin.canonicalization == .exclusiveAuthority && source.segments.count == mcpSegments.count
        && Set(source.segments.map(\.id)) == Set(mcpSegments.keys))
    var bytes = Data("codex-segments-v1".utf8)
    for segment in source.segments {
        try demand(mcpSegments[segment.id].map { Data($0.utf8) } == segment.utf8)
        for part in [Data(segment.id.utf8), segment.utf8] {
            var size = UInt64(part.count).bigEndian
            bytes.append(Data(bytes: &size, count: MemoryLayout<UInt64>.size)); bytes.append(part)
        }
    }
    try demand(try await crypto.revision(canonicalBytes: bytes) == source.revision)
    return .init(identity: m.identity, turnID: config.turn, revision: source.revision, contentTime: time,
        locations: try fixtureLocations(), nativeRowDigest: try await commitment("native-row", row, crypto: crypto),
        resultDigest: try await commitment("native-result", row["item"]["result"], crypto: crypto))
}
private actor MCPNormalizer: CaptureNormalizer {
    let adapter: CodexAdapter, history: MCPHistory, config: MCPConfiguration
    let expected: MCPBinding?
    var binding: MCPBinding?, sources = Set<SourceIdentity>()
    init(adapter: CodexAdapter, history: MCPHistory, config: MCPConfiguration, expected: MCPBinding?) {
        self.adapter = adapter; self.history = history; self.config = config; self.expected = expected
    }
    func normalize(_ packet: CapturePacket, capturedAt: Date, cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        let batch = try await adapter.normalize(packet, capturedAt: capturedAt, cryptography: cryptography)
        try demand(batch.continuation == nil && batch.coverageGaps.isEmpty && batch.readEvidenceEligible
            && batch.sources.count <= 256)
        var count = 0
        for collected in batch.sources {
            let source = collected.record
            try demand(source.metadata.identity.session.sessionID == config.thread
                && source.metadata.identity.session.profileID == mcpProfile)
            if source.metadata.identity.itemID == config.item {
                let (row, time) = try await history.original()
                let actual = try await checkTarget(source, config: config, row: row, time: time, crypto: cryptography)
                if let expected { try demand(expected == actual) }
                if let binding { try demand(binding == actual) }
                binding = actual; count += 1
            } else { try demand(source.segments.allSatisfy { tokenCount($0.utf8) == 0 }) }
            try demand(sources.insert(source.metadata.identity).inserted)
        }
        try demand(count == 1)
        return batch
    }
}
private func validateDetectorOutput(_ output: DetectorOutput, source: SourceRecord, target: Bool) throws {
    try demand(output.detectorVersion == BetterleaksSecretDetector.version && output.scannerFailure == nil
        && output.coverageGaps.isEmpty && output.unlocated.isEmpty)
    if target {
        try demand(output.findings.count == 4 && Set(output.findings.map { $0.extraction.location }) == fixtureLocations())
        for finding in output.findings {
            try finding.extraction.validate(in: source)
            try demand(finding.extraction.valueUTF8 == Data(mcpValue.utf8) && finding.extraction.transform == .identity)
        }
    } else { try demand(output.findings.isEmpty) }
}
private actor MCPDetector: SecretDetector {
    let real: BetterleaksSecretDetector, targetID: String
    var calls = 0, targetCalls = 0
    init(configuration: BetterleaksConfiguration, targetID: String) { real = .init(configuration: configuration); self.targetID = targetID }
    func scan(_ source: SourceRecord) async throws -> DetectorOutput {
        calls += 1
        let output = try await real.scan(source)
        let target = source.metadata.identity.itemID == targetID
        try validateDetectorOutput(output, source: source, target: target)
        if target { targetCalls += 1 }
        return output
    }
}
private actor MCPCompletions {
    var ids = Set<UUID>(), failures = 0
    func completed(_ id: UUID) { ids.insert(id) }
    func failed() { failures += 1 }
}

private func validateInventory(_ snapshot: InventorySnapshot, binding: MCPBinding, config: MCPConfiguration,
                               crypto: BackgroundCryptography, store: ProtectedStore, payloadCount: Int) async throws -> AnalysisReceipt {
    let receipt = AnalysisReceipt(source: binding.identity, revision: binding.revision, detectorVersion: BetterleaksSecretDetector.version)
    let fingerprint = try await crypto.fingerprint(exactBytes: Data(mcpValue.utf8))
    guard let record = snapshot.records[fingerprint], let value = record.protectedValue else { throw MCPPipelineError.evidence }
    try demand(snapshot.records.count == 1 && snapshot.occurrences.count == 4 && snapshot.locationReceipts.count == 4
        && binding.locations == fixtureLocations() && snapshot.analysisReceipts.contains(receipt)
        && snapshot.analysisReceipts.filter { $0.source == binding.identity }.count == 1
        && snapshot.analysisReceipts.count == snapshot.sourceKinds.count && (1...256).contains(snapshot.sourceKinds.count)
        && Set(snapshot.analysisReceipts.map(\.source)) == Set(snapshot.sourceKinds.keys)
        && Set(snapshot.sourceKinds.keys) == Set(snapshot.sourceTimes.keys)
        && snapshot.analysisReceipts.allSatisfy { $0.detectorVersion == BetterleaksSecretDetector.version
            && $0.source.session.sessionID == config.thread && $0.source.session.profileID == mcpProfile }
        && snapshot.unlocatedResults.isEmpty && snapshot.unlocatedReceipts.isEmpty
        && snapshot.obsoleteMarkers.isEmpty && snapshot.obsoleteAppearances.isEmpty
        && snapshot.sourceKinds[binding.identity] == .toolOutput && snapshot.sourceTimes[binding.identity] == binding.contentTime)
    var references: Set<ProtectedPayloadReference> = [value]
    var excerpts = Set<ProtectedPayloadReference>(), metadata = Set<ProtectedPayloadReference>()
    var locations = Set<CanonicalLocation>()
    for occurrence in snapshot.occurrences.values {
        guard let excerpt = occurrence.protectedExcerpt, let context = occurrence.source.protectedMetadata else { throw MCPPipelineError.evidence }
        try demand(occurrence.source.identity == binding.identity && occurrence.valueID == record.id
            && occurrence.source.contentType == .toolOutput && occurrence.source.contentTime == binding.contentTime
            && occurrence.source.locator == .upstreamItem && occurrence.source.origin.agentVersion == mcpVersion
            && occurrence.source.origin.adapterVersion == CodexAdapter.adapterVersion
            && occurrence.source.origin.canonicalization == .exclusiveAuthority
            && snapshot.locationReceipts[occurrence.identity] == .occurrence(occurrence.id))
        locations.insert(occurrence.identity.location); excerpts.insert(excerpt); metadata.insert(context)
    }
    references.formUnion(excerpts); references.formUnion(metadata)
    try demand(locations == binding.locations && excerpts.count == 4 && metadata.count == 1
        && references.count == 6 && payloadCount == references.count)
    for reference in references {
        guard let payload = try await store.payload(reference) else { throw MCPPipelineError.evidence }
        let kind: ProtectedPayloadKind = reference == value ? .value : (excerpts.contains(reference) ? .excerpt : .sourceMetadata)
        try demand(payload.binding.reference == reference && payload.binding.ownerID == reference.id
            && payload.binding.kind == kind && payload.algorithm == .inventoryECIESAESGCM)
    }
    return receipt
}

private func makeAdapter(_ history: MCPHistory, store: ProtectedStore) throws -> CodexAdapter {
    try .init(profileID: mcpProfile, agentVersion: mcpVersion, interface: .standaloneCLI,
        authority: .publicNativeItems, history: history, limits: .init(pageSize: 256),
        historyBudget: .init(maximumBytes: 2 * 1024 * 1024, maximumDuration: 8, maximumSources: 256),
        authorityLookup: { try await store.authority(for: $0) }, authorityRecorder: { choice in
            guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
            try await store.selectAuthority(choice, permit: permit)
        }, checkpointLookup: { try await store.checkpoint(documentID: $0) })
}
private func enqueueAudit(_ adapter: CodexAdapter, store: ProtectedStore, config: MCPConfiguration) async throws -> UUID {
    let now = Date(), audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
    var request = CodexHistoryRequest(audit: audit, threads: [config.thread]); request.selectedSourceOnly = true
    let packet = try adapter.packet(request)
    let scope = CollectionScope(provider: .codex, profileID: mcpProfile, interface: .standaloneCLI, path: .publicHistory)
    let context = try CollectionCaptureRoute(scope: scope, readerVersion: mcpVersion).context(for: packet, trigger: .historyRequest, audit: audit)
    guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
    let id = UUID()
    _ = try await store.enqueue(packet.body, id: id, capturedAt: now, permit: permit, at: now,
        historicalAudit: audit, workContext: context)
    return id
}

@Suite("Opt-in genuine Codex MCP encrypted production pipeline")
struct CodexMCPPipelineLiveTests {
    @Test func privateFilesAreExclusiveAndDanglingAuthIsNotAbsent() throws {
        let root = URL(fileURLWithPath: "/private/tmp/spillcheck-mcp-pipeline-boundary-\(UUID())")
        try makeDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state")
        try writePrivate(Data("{}".utf8), to: file)
        #expect(try privateBytes(file) == Data("{}".utf8))
        #expect(throws: MCPPipelineError.self) { try writePrivate(Data(), to: file) }
        let link = root.appendingPathComponent("auth.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: root.appendingPathComponent("missing").path)
        #expect(!absent(link))
        #expect(throws: MCPPipelineError.self) { _ = try privateBytes(link) }
    }
    @Test func fixtureHasFourExactByteLocationsAndElevenOpaqueStrings() throws {
        #expect(mcpSegments.count == 11)
        #expect(try fixtureLocations().count == 4)
        #expect(mcpSegments.values.reduce(0) { $0 + tokenCount(Data($1.utf8)) } == 4)
        #expect(mcpSegments["/result/structuredContent/caption"]?.contains("é🙂\r\n ") == true)
        #expect(!boundedID("item\nforged") && !boundedID(String(repeating: "a", count: 257)))
        let result = try fixtureResult()
        #expect(result["structuredContent"]["isError"].bool == true)
        #expect(result["_meta"] == .null)
    }
    @Test func fullScannerEvidenceRejectsPartialMissingAndForeignFindings() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting(), adapter = try codexTestAdapter(version: mcpVersion)
        let result = try fixtureResult()
        let resultObject = try JSONSerialization.jsonObject(with: encoded(result))
        let row = try codexItem("mcp", type: "mcpToolCall", body: ["status": "completed", "error": NSNull(), "result": resultObject])
        let batch = try await adapter.importPublicItems(.init(data: [row]), thread: codexThread("owned", producer: mcpVersion),
            observedAt: Date(), cryptography: crypto)
        let source = try #require(batch.sources.first?.record)
        let findings = try fixtureLocations().map { location in
            try DetectorFinding(extraction: .init(valueUTF8: Data(mcpValue.utf8), location: location, in: source), evidence: [evidence()])
        }
        let full = DetectorOutput(detectorVersion: BetterleaksSecretDetector.version, findings: findings, unlocated: [])
        try validateDetectorOutput(full, source: source, target: true)
        #expect(throws: MCPPipelineError.self) { try validateDetectorOutput(full, source: source, target: false) }
        for version in [BetterleaksSecretDetector.version + "+partial", BetterleaksSecretDetector.version + "+reduced", "wrong-detector"] {
            #expect(throws: MCPPipelineError.self) {
                try validateDetectorOutput(.init(detectorVersion: version, findings: findings, unlocated: []), source: source, target: true)
            }
        }
        #expect(throws: MCPPipelineError.self) {
            try validateDetectorOutput(.init(detectorVersion: BetterleaksSecretDetector.version,
                findings: Array(findings.dropLast()), unlocated: []), source: source, target: true)
        }
        #expect(throws: MCPPipelineError.self) {
            try validateDetectorOutput(.init(detectorVersion: BetterleaksSecretDetector.version,
                findings: findings, unlocated: [], coverageGaps: [.init(reason: .unsupportedContent)]), source: source, target: true)
        }
    }
    @Test func rowCommitmentsBindReceiptRevisionAndCiphertextRejectsOtherOwner() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let session = try SessionIdentity(provider: .codex, profileID: mcpProfile, sessionID: "owned")
        let identity = try SourceIdentity(session: session, itemID: "native-item")
        let one = AnalysisReceipt(source: identity, revision: try .init(keyedDigest: Data(repeating: 1, count: 32)),
            detectorVersion: BetterleaksSecretDetector.version)
        let two = AnalysisReceipt(source: identity, revision: try .init(keyedDigest: Data(repeating: 2, count: 32)),
            detectorVersion: BetterleaksSecretDetector.version)
        let first = try await commitment("analysisReceipts", one, crypto: crypto)
        let changed = try await commitment("analysisReceipts", two, crypto: crypto)
        #expect(first != changed)
        let binding = PayloadBinding(reference: .init(), ownerID: UUID(), kind: .sourceCheckpoint)
        let sealed = try await crypto.sealBackground(Data(mcpValue.utf8), binding: binding)
        #expect(try sealed.encoded().range(of: Data(mcpValue.utf8)) == nil)
        let other = PayloadBinding(reference: binding.reference, ownerID: UUID(), kind: .sourceCheckpoint)
        do { _ = try await crypto.openBackground(sealed, binding: other); Issue.record("Foreign owner accepted") }
        catch { /* An authenticated envelope cannot be rebound by its consumer. */ }
    }

    @Test func genuineResultScansRestoresAndRereadsWithoutDuplicateDetections() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SPILLCHECK_MCP_PIPELINE_STAGE"] != nil else { return }
        let config = try MCPConfiguration(environment)
        var report: [String: Any] = ["schemaVersion": 1, "stage": config.stage, "passed": false,
            "parserContract": CodexAdapter.parserContract, "readerVersion": mcpVersion, "producerVersion": mcpVersion,
            "detectorVersion": BetterleaksSecretDetector.version, "scannerSHA256": BetterleaksConfiguration.pinnedExecutableSHA256,
            "rulesSHA256": BetterleaksConfiguration.pinnedConfigurationSHA256, "cryptoScope": "disposable-deterministic-test-keys",
            "historyClientCreated": false, "readerVersionMeasured": false, "observedReaderVersions": [String](),
            "versionBinding": "saved-evidence", "readerShutdown": NSNull(), "readerShutdownNotNeeded": true]
        for key in ["signedAcceptance", "keychainAcceptance", "desktopAcceptance", "t3Acceptance", "nativeChildCoverage",
                    "providerUpgradeAcceptance", "fullHostAcceptance"] { report[key] = false }
        var checks: [String: Bool] = [:], stage = "preflight", failed = false
        var store: ProtectedStore?, client: CodexAppServerHistoryClient?, history: MCPHistory?, detector: MCPDetector?
        do {
            if config.stage == "collect" { try makeDirectory(config.controls) } else { try privateDirectory(config.controls) }
            let keyURL = config.controls.appendingPathComponent("crypto.json"), baselineURL = config.controls.appendingPathComponent("baseline.enc")
            let keys: MCPKeys
            if config.stage == "collect" {
                keys = .init(schemaVersion: 1, seed: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }),
                    manifest: .fresh(identifierPrefix: "com.spillcheck.test.mcp-pipeline"))
                try writePrivate(encoded(keys), to: keyURL)
            } else { keys = try load(MCPKeys.self, keyURL) }
            try demand(keys.schemaVersion == 1 && keys.seed.count == 32)
            let crypto = try BackgroundCryptography.deterministicForTesting(seed: keys.seed, manifest: keys.manifest)
            let scannerDirectory = config.controls.appendingPathComponent("scanner")
            if config.stage == "collect" { try makeDirectory(scannerDirectory) } else { try privateDirectory(scannerDirectory) }
            let scannerConfig = BetterleaksConfiguration(executableURL: config.scanner, configurationURL: config.rules, workingDirectoryURL: scannerDirectory)
            _ = try ScannerProcess.verifyArtifacts(scannerConfig)
            stage = "opening-encrypted-store"
            if config.stage == "collect" { try demand(absent(config.store)) }
            let opened = try await ProtectedStore.open(at: config.store, cryptography: crypto); store = opened
            let before = await opened.snapshot(), beforeQueue = try await opened.queueStatistics()
            let beforeCommitment = try await inventoryCommitment(before, store: opened, crypto: crypto)
            let baseline: MCPBaseline?
            if config.stage == "collect" {
                try demand(beforeCommitment.counts.values.allSatisfy { $0 == 0 } && beforeCommitment.payloadCount == 0
                    && beforeQueue.count == 0 && beforeQueue.claimedCount == 0)
                checks["emptyBeforeAdmission"] = true; baseline = nil
            } else {
                stage = "checking-cold-inventory"
                let saved = try await loadBaseline(baselineURL, crypto: crypto, owner: keys.manifest.vaultID)
                try demand(saved.schemaVersion == 1 && saved.parserContract == CodexAdapter.parserContract
                    && saved.detectorVersion == BetterleaksSecretDetector.version && saved.fullScannerEvidence
                    && saved.binding.identity.session.sessionID == config.thread && saved.binding.identity.itemID == config.item
                    && saved.binding.turnID == config.turn && beforeCommitment == saved.inventory
                    && before.analysisReceipts == saved.receipts && beforeQueue.count == 0 && beforeQueue.claimedCount == 0)
                _ = try await validateInventory(before, binding: saved.binding, config: config, crypto: crypto,
                    store: opened, payloadCount: beforeCommitment.payloadCount)
                checks["coldInventoryUnchanged"] = true; checks["coldVerifiedBeforeReads"] = true; baseline = saved
            }
            let binding: MCPBinding
            var admission: UUID?
            if config.stage == "cold" {
                guard let baseline else { throw MCPPipelineError.evidence }
                binding = baseline.binding
                checks["noSourceReads"] = true; checks["noDetectorScans"] = true
            } else {
                let readerDirectory = config.controls.appendingPathComponent("reader-" + config.stage)
                try makeDirectory(readerDirectory)
                let passive = CodexAppServerHistoryClient(configuration: try .init(executableURL: config.executable,
                    codexHomeURL: config.home, workingDirectoryURL: readerDirectory, requestTimeout: 8, maximumResponseBytes: 2 * 1024 * 1024))
                client = passive; report["historyClientCreated"] = true; report["readerShutdownNotNeeded"] = false
                let measured = MCPHistory(client: passive, config: config); history = measured
                let adapter = try makeAdapter(measured, store: opened)
                let normalizer = MCPNormalizer(adapter: adapter, history: measured, config: config, expected: baseline?.binding)
                let scanner = MCPDetector(configuration: scannerConfig, targetID: config.item); detector = scanner
                let pipeline = DetectionPipeline(store: opened, cryptography: crypto, normalizer: normalizer,
                    detector: scanner, detectorVersion: BetterleaksSecretDetector.version, liveSince: Date())
                let completions = MCPCompletions()
                await pipeline.observeCaptureCompletionsForTesting { await completions.completed($0) }
                await pipeline.observeFailuresForTesting { _ in await completions.failed() }
                let id = try await enqueueAudit(adapter, store: opened, config: config); admission = id
                if let baseline { try demand(id != baseline.initialCapture) }
                stage = "processing-production-history"
                let deadline = ProcessInfo.processInfo.systemUptime + 145
                for _ in 0..<16 {
                    try demand(ProcessInfo.processInfo.systemUptime < deadline && absent(config.home.appendingPathComponent("auth.json")))
                    if try await opened.queueStatistics().count == 0 { break }
                    try demand(try await pipeline.processNext() == .processed)
                }
                stage = "checking-native-result"
                guard let observed = await normalizer.binding else { throw MCPPipelineError.evidence }
                binding = observed
                let ids = try await opened.captureIdentitiesForTesting(), completed = await completions.ids
                let failures = await completions.failures, counters = await measured.counts(), calls = await scanner.calls
                let snapshot = await opened.snapshot(), observedSources = await normalizer.sources
                try demand(ids.pending.isEmpty && ids.consumed.contains(id) && completed.contains(id) && failures == 0
                    && counters["threadReadCalls", default: 0] > 0 && counters["itemReadCalls", default: 0] > 0
                    && counters["nativeTargetReadCount", default: 0] > 0 && counters["threadListCalls", default: 0] == 0
                    && observedSources == Set(snapshot.sourceKinds.keys))
                if config.stage == "collect" {
                    let targetScans = await scanner.targetCalls
                    try demand(calls == snapshot.sourceKinds.count && targetScans == 1)
                    checks["initialCaptureConsumed"] = true; checks["initialCaptureSuccessfullyProcessed"] = true
                } else {
                    try demand(calls == 0)
                    checks["newCaptureConsumed"] = true; checks["newCaptureSuccessfullyProcessed"] = true
                    checks["freshAuditRead"] = true; checks["noAdditionalDetectorScans"] = true
                }
                checks["sameResponseNativeBinding"] = true
                report["readerVersionMeasured"] = true; report["observedReaderVersions"] = [mcpVersion]
                report["versionBinding"] = "same-response"
            }
            stage = "checking-full-receipts"
            let snapshot = await opened.snapshot(), queue = try await opened.queueStatistics()
            let inventory = try await inventoryCommitment(snapshot, store: opened, crypto: crypto)
            let targetReceipt = try await validateInventory(snapshot, binding: binding, config: config, crypto: crypto,
                store: opened, payloadCount: inventory.payloadCount)
            let gaps = try await opened.coverageOmissions()
            try demand(queue.count == 0 && queue.claimedCount == 0 && gaps.isEmpty)
            if let baseline {
                try demand(inventory == baseline.inventory && snapshot.analysisReceipts == baseline.receipts)
                if config.stage == "replay" { checks["inventoryUnchanged"] = true; checks["receiptsUnchanged"] = true }
            } else {
                guard let admission else { throw MCPPipelineError.evidence }
                try await saveBaseline(.init(schemaVersion: 1, parserContract: CodexAdapter.parserContract,
                    detectorVersion: BetterleaksSecretDetector.version, binding: binding, inventory: inventory,
                    receipts: snapshot.analysisReceipts, initialCapture: admission, fullScannerEvidence: true),
                    to: baselineURL, crypto: crypto, owner: keys.manifest.vaultID)
            }
            for key in ["originalBindingVerified", "targetOccurrencesExact", "fullCurrentTargetReceipt", "noFindingsOutsideTarget",
                        "allReceiptsFull", "zeroTargetGaps"] { report[key] = true }
            report["bindingDigest"] = try await commitment("binding", binding, crypto: crypto)
            report["targetReceiptDigest"] = try await commitment("analysisReceipts", targetReceipt, crypto: crypto)
            report["targetSourceDigest"] = try await commitment("sourceKinds", Pair(key: binding.identity, value: ContentType.toolOutput), crypto: crypto)
            report["targetResultDigest"] = binding.resultDigest
            report["inventory"] = try JSONSerialization.jsonObject(with: encoded(inventory))
            report["targetSegmentCount"] = mcpSegments.count; report["targetTextBytes"] = mcpSegments.values.reduce(0) { $0 + $1.utf8.count }
            report["targetOccurrenceCount"] = 4; report["targetReceiptCount"] = 1; report["payloadRowCount"] = inventory.payloadCount
            report["analysisReceiptCount"] = snapshot.analysisReceipts.count; report["sourceCount"] = snapshot.sourceKinds.count
            report["valueCount"] = snapshot.records.count; report["occurrenceCount"] = snapshot.occurrences.count
            report["queueCount"] = queue.count; report["gapCount"] = gaps.count; report["targetGapCount"] = 0; report["gapReasons"] = [String]()
        } catch { failed = true; report["failureStage"] = stage }
        report["checks"] = checks
        let counters = await history?.counts() ?? [:]
        for key in ["threadReadCalls", "itemReadCalls", "turnReadCalls", "threadListCalls", "nativeTargetReadCount"] { report[key] = counters[key] ?? 0 }
        report["detectorScanCalls"] = await detector?.calls ?? 0
        if let client {
            await client.close()
            let closed = await client.lastShutdownCompletedWithinDeadline == true
            report["readerShutdown"] = closed; report["readerClosedOrNotStarted"] = closed
            if !closed { if !failed { report["failureStage"] = "closing-reader" }; failed = true }
        } else { report["readerClosedOrNotStarted"] = true }
        if let store {
            do { try await store.close(); report["storeClosed"] = true }
            catch { if !failed { report["failureStage"] = "closing-store" }; failed = true; report["storeClosed"] = false }
        } else { report["storeClosed"] = true }
        do { try verifyCiphertextFiles(config.controls); report["ciphertextVerified"] = true }
        catch { if !failed { report["failureStage"] = "checking-ciphertext" }; failed = true; report["ciphertextVerified"] = false }
        report["authAbsent"] = absent(config.home.appendingPathComponent("auth.json"))
        report["passed"] = !failed && report["authAbsent"] as? Bool == true
        try writePrivate(JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), to: config.report)
        #expect(report["passed"] as? Bool == true)
    }
}
