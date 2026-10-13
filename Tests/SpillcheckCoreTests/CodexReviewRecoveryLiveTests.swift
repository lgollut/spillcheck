import CryptoKit
import Darwin
import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

// Disposable fake material only. These controls never create or open Keychain keys.
private let recoveryValue = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
private let recoveryVersion = "0.162.1"
private let recoveryProfile = "disposable-native-review-recovery"
private enum RecoveryProbeError: Error { case boundary, evidence, budget }
private func demand(_ condition: Bool) throws { guard condition else { throw RecoveryProbeError.evidence } }
private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func boundedID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
}
private func hexDigest(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
private func tokenCount(_ data: Data) -> Int {
    String(decoding: data, as: UTF8.self).components(separatedBy: recoveryValue).count - 1
}
private func privateDirectory(_ url: URL) throws {
    var s = stat()
    guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR, s.st_uid == getuid(),
          s.st_mode & 0o077 == 0, let path = realpath(url.path, nil) else { throw RecoveryProbeError.boundary }
    defer { free(path) }
    guard String(cString: path) == url.path else { throw RecoveryProbeError.boundary }
}
private func absent(_ url: URL) -> Bool { var s = stat(); return lstat(url.path, &s) == -1 && errno == ENOENT }
private func makeDirectory(_ url: URL) throws {
    guard mkdir(url.path, 0o700) == 0 else { throw RecoveryProbeError.boundary }
    try privateDirectory(url)
}
private func privateBytes(_ url: URL, limit: Int = 512 * 1024) throws -> Data {
    try privateDirectory(url.deletingLastPathComponent())
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw RecoveryProbeError.boundary }
    defer { close(fd) }
    var first = stat(), last = stat(), named = stat()
    guard fstat(fd, &first) == 0, first.st_mode & S_IFMT == S_IFREG, first.st_uid == getuid(),
          first.st_nlink == 1, first.st_mode & 0o077 == 0, first.st_size >= 0, first.st_size <= limit else {
        throw RecoveryProbeError.boundary
    }
    var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n == 0 { break }
        guard n > 0, bytes.count <= limit - n else { throw RecoveryProbeError.boundary }
        bytes.append(contentsOf: buffer.prefix(n))
    }
    guard fstat(fd, &last) == 0, lstat(url.path, &named) == 0,
          first.st_dev == last.st_dev, first.st_ino == last.st_ino, first.st_size == last.st_size,
          first.st_mtimespec.tv_sec == last.st_mtimespec.tv_sec,
          first.st_mtimespec.tv_nsec == last.st_mtimespec.tv_nsec,
          named.st_dev == first.st_dev, named.st_ino == first.st_ino,
          named.st_nlink == 1, named.st_mode == first.st_mode, bytes.count == first.st_size else {
        throw RecoveryProbeError.boundary
    }
    return bytes
}
private func writePrivate(_ bytes: Data, to url: URL) throws {
    try privateDirectory(url.deletingLastPathComponent())
    guard bytes.count <= 512 * 1024 else { throw RecoveryProbeError.boundary }
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw RecoveryProbeError.boundary }
    defer { close(fd) }
    try bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            guard n > 0 else { throw RecoveryProbeError.boundary }
            offset += n
        }
    }
    guard fsync(fd) == 0 else { throw RecoveryProbeError.boundary }
}
private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}
private func load<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
    try JSONDecoder().decode(type, from: privateBytes(url))
}

private struct RecoveryConfiguration {
    let stage: String, root: URL, home: URL, executable: URL, report: URL, scanner: URL, rules: URL
    let thread: String, turn: String, inputHash: String, outputHash: String, inputBytes: Int, outputBytes: Int
    var controls: URL { root.appendingPathComponent("recovery") }
    var store: URL { controls.appendingPathComponent("store") }
    init(_ env: [String: String]) throws {
        func field(_ name: String) throws -> String {
            guard let value = env["SPILLCHECK_REVIEW_RECOVERY_" + name], !value.isEmpty else { throw RecoveryProbeError.boundary }
            return value
        }
        stage = try field("STAGE"); root = URL(fileURLWithPath: try field("ROOT"))
        home = URL(fileURLWithPath: try field("HOME")); executable = URL(fileURLWithPath: try field("EXECUTABLE"))
        report = URL(fileURLWithPath: try field("REPORT")); scanner = URL(fileURLWithPath: try field("SCANNER_EXECUTABLE"))
        rules = URL(fileURLWithPath: try field("SCANNER_RULES")); thread = try field("THREAD"); turn = try field("TURN")
        inputHash = try field("INPUT_SHA256"); outputHash = try field("OUTPUT_SHA256")
        guard let input = Int(try field("INPUT_BYTES")), let output = Int(try field("OUTPUT_BYTES")) else {
            throw RecoveryProbeError.boundary
        }
        inputBytes = input; outputBytes = output
        try demand(["queue", "resume", "replay"].contains(stage)
            && root.deletingLastPathComponent().path == "/private/tmp"
            && root.lastPathComponent.hasPrefix("spillcheck-native-review-recovery-")
            && home == root.appendingPathComponent("home")
            && report.lastPathComponent == stage + "-report.json" && absent(report)
            && UUID(uuidString: thread)?.uuidString.lowercased() == thread && boundedID(turn)
            && hexDigest(inputHash) && hexDigest(outputHash)
            && (1...16_384).contains(inputBytes) && (1...16_384).contains(outputBytes))
        try privateDirectory(root); try privateDirectory(home)
        try privateDirectory(report.deletingLastPathComponent())
        try demand(absent(home.appendingPathComponent("auth.json")))
    }
}

private struct RecoveryKeys: Codable {
    let schemaVersion: Int
    let seed: Data
    let manifest: ProtectionManifest
}
private struct OriginalBinding: Codable, Equatable {
    let identity: SourceIdentity
    let turnID: String
    let contentType: ContentType
    let contentTime: Date
    let revision: ContentRevision
    let pointer: String
    let textHash: String
    let textBytes: Int
    let expectedLocation: CanonicalLocation
    let nativeRowDigest: String
}
private struct ReviewBinding: Codable, Equatable {
    let schemaVersion: Int
    let thread: String
    let reviewTurn: String
    let inputTurn: String
    let entryID: String
    let exitID: String
    let presentationRowDigests: [String]
    let originals: [OriginalBinding]
    var presentations: Set<String> { [entryID, exitID] }
}
private struct InventoryCommitment: Codable, Equatable {
    let counts: [String: Int]
    let digests: [String: [String]]
    let schemaVersion: Int, nextValueLabel: Int, payloadCount: Int
}
private struct QueueEvidence: Codable {
    let schemaVersion: Int
    let pendingID: UUID
    let pendingDigest: String
    let ciphertextDigest: String
    let encryptedBytes: Int
    let inventory: InventoryCommitment
    let observedPresentationIDs: Set<String>
}
private struct FinalEvidence: Codable {
    let schemaVersion: Int
    let inventory: InventoryCommitment
    let originalReceipts: Set<AnalysisReceipt>
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
            if ["categories", "origins", "evidence"].contains(key ?? "") {
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
    var bytes = Data(("review-recovery-probe-v1/" + domain + "\n").utf8)
    bytes.append(try canonical(value))
    return try await crypto.revision(canonicalBytes: bytes).keyedDigest.base64EncodedString()
}
private func inventoryCommitment(_ snapshot: InventorySnapshot, store: ProtectedStore,
                                 crypto: BackgroundCryptography) async throws -> InventoryCommitment {
    var counts: [String: Int] = [:], digests: [String: [String]] = [:]
    func rows<T: Encodable>(_ name: String, _ values: [T]) async throws {
        try demand(values.count <= 128); counts[name] = values.count
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

private actor RecoveryHistory: CodexHistoryReading {
    let client: CodexAppServerHistoryClient
    let configuration: RecoveryConfiguration
    var threadCalls = 0, itemCalls = 0, turnCalls = 0, listCalls = 0, cursorCalls = 0, exactTurnCalls = 0
    var production = false
    init(client: CodexAppServerHistoryClient, configuration: RecoveryConfiguration) {
        self.client = client; self.configuration = configuration
    }
    func beginProduction() { production = true }
    func counts() -> [String: Int] {
        ["threadReadCalls": threadCalls, "itemReadCalls": itemCalls, "turnReadCalls": turnCalls, "threadListCalls": listCalls,
         "cursorCalls": cursorCalls, "exactTurnCalls": exactTurnCalls]
    }
    func readThread(_ id: String) async throws -> CodexThreadRead {
        try await readThread(id, budget: .init(maximumBytes: 2 * 1024 * 1024, timeout: 8))
    }
    func readThread(_ id: String, budget: CodexRPCBudget) async throws -> CodexThreadRead {
        try demand(id == configuration.thread)
        let result = try await client.readThread(id, budget: budget)
        if production { threadCalls += 1 }
        try demand(result.readerVersion == recoveryVersion && result.thread["id"].string == id
            && result.thread["cliVersion"].string == recoveryVersion
            && result.thread["parentThreadId"] == .null && result.thread["forkedFromId"] == .null
            && result.thread["ephemeral"].bool == false
            && result.thread["cwd"].string == configuration.root.appendingPathComponent("work").path)
        return result
    }
    func listThreads(cursor: String?, limit: Int, archived: Bool) throws -> CodexHistoryPage {
        listCalls += 1; throw RecoveryProbeError.boundary
    }
    func listThreads(cursor: String?, limit: Int, archived: Bool, budget: CodexRPCBudget) throws -> CodexHistoryPage {
        listCalls += 1; throw RecoveryProbeError.boundary
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int,
                   direction: CodexHistoryDirection) async throws -> CodexHistoryPage {
        try await listItems(threadID: threadID, turnID: turnID, cursor: cursor, limit: limit,
            direction: direction, budget: .init(maximumBytes: 2 * 1024 * 1024, timeout: 8))
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int,
                   direction: CodexHistoryDirection, budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        try demand(threadID == configuration.thread && (!production || limit == 1)
            && (turnID.map(boundedID) ?? true))
        let page = try await client.listItems(threadID: threadID, turnID: turnID, cursor: cursor, limit: limit,
            direction: direction, budget: budget)
        try demand(page.readerVersion == recoveryVersion && page.data.count <= limit)
        if production { itemCalls += 1; if cursor != nil { cursorCalls += 1 }; if turnID != nil { exactTurnCalls += 1 } }
        return page
    }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection) async throws -> CodexHistoryPage {
        try await listTurns(threadID: threadID, cursor: cursor, limit: limit, direction: direction,
            budget: .init(maximumBytes: 2 * 1024 * 1024, timeout: 8))
    }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection,
                   budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        try demand(threadID == configuration.thread)
        let page = try await client.listTurns(threadID: threadID, cursor: cursor, limit: limit, direction: direction, budget: budget)
        try demand(page.readerVersion == recoveryVersion && page.data.count <= limit)
        if production { turnCalls += 1; if cursor != nil { cursorCalls += 1 } }
        return page
    }
}

private func originalTime(_ row: CodexJSON, turns: [String: DateInterval], user: Bool) throws -> Date {
    if let ms = row["completedAtMs"].number ?? row["startedAtMs"].number, ms.isFinite, abs(ms) < 1e15 {
        return Date(timeIntervalSince1970: ms / 1000)
    }
    guard row["completedAtMs"] == .null, row["startedAtMs"] == .null,
          let turn = row["turnId"].string, let interval = turns[turn] else { throw RecoveryProbeError.evidence }
    return user ? interval.start : interval.end
}
private func bindOriginals(_ config: RecoveryConfiguration, history: RecoveryHistory, adapter: CodexAdapter,
                           crypto: BackgroundCryptography) async throws -> ReviewBinding {
    let thread = try await history.readThread(config.thread)
    let items = try await history.listItems(threadID: config.thread, turnID: nil, cursor: nil, limit: 256, direction: .ascending)
    let turns = try await history.listTurns(threadID: config.thread, cursor: nil, limit: 256, direction: .ascending)
    return try await buildBinding(config, thread: thread.thread, items: items, turns: turns, adapter: adapter, crypto: crypto)
}
private func buildBinding(_ config: RecoveryConfiguration, thread: CodexJSON, items: CodexHistoryPage,
                          turns: CodexHistoryPage, adapter: CodexAdapter,
                          crypto: BackgroundCryptography) async throws -> ReviewBinding {
    try demand(items.nextCursor == nil && turns.nextCursor == nil && items.data.count == 4 && !turns.data.isEmpty)
    try demand(items.readerVersion == recoveryVersion && turns.readerVersion == recoveryVersion)
    var ids = Set<String>(), turnRows: [String: CodexJSON] = [:], times: [String: DateInterval] = [:]
    for row in items.data {
        guard let id = row["item"]["id"].string, boundedID(id), ids.insert(id).inserted,
              let turn = row["turnId"].string, boundedID(turn) else { throw RecoveryProbeError.evidence }
    }
    for turn in turns.data {
        guard let id = turn["id"].string, boundedID(id), turnRows[id] == nil else { throw RecoveryProbeError.evidence }
        turnRows[id] = turn
        if let start = turn["startedAt"].number, let end = turn["completedAt"].number,
           start.isFinite, end.isFinite, abs(start) < 1e12, abs(end) < 1e12, end >= start {
            times[id] = .init(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
        }
    }
    func one(_ kind: String) throws -> CodexJSON {
        let rows = items.data.filter { $0["item"]["type"].string == kind }
        try demand(rows.count == 1); return rows[0]
    }
    let input = try one("userMessage"), output = try one("agentMessage")
    let entered = try one("enteredReviewMode"), exited = try one("exitedReviewMode")
    guard let inputTurn = input["turnId"].string, let content = input["item"]["content"].array,
          content.count == 1, content[0]["type"].string == "text", let inputText = content[0]["text"].string,
          let outputText = output["item"]["text"].string else { throw RecoveryProbeError.evidence }
    let inputData = Data(inputText.utf8), outputData = Data(outputText.utf8)
    try demand(output["item"].object?["phase"] == .null && output["turnId"].string == config.turn
        && entered["turnId"].string == config.turn && exited["turnId"].string == config.turn
        && turnRows[config.turn]?["rootTurnId"].string == config.turn
        && turnRows[inputTurn]?["rootTurnId"].string == config.turn
        && Data((entered["item"]["review"].string ?? "").utf8) == inputData
        && Data((exited["item"]["review"].string ?? "").utf8) == outputData
        && hash(inputData) == config.inputHash && inputData.count == config.inputBytes
        && hash(outputData) == config.outputHash && outputData.count == config.outputBytes
        && tokenCount(inputData) == 1 && tokenCount(outputData) == 1)
    let batch = try await adapter.importPublicItems(items, thread: thread, observedAt: Date(), turnTimes: times, cryptography: crypto)
    try demand(batch.sources.count == 2 && batch.coverageGaps.count == 2)
    let presentationIDs = Set([entered["item"]["id"].string!, exited["item"]["id"].string!])
    try demand(batch.coverageGaps.allSatisfy { $0.reason == .unsupportedContent && $0.diagnosticCode == .unknownRecordKind
        && $0.recovery?.itemID.map(presentationIDs.contains) == true })
    var originals: [OriginalBinding] = []
    for (row, bytes, kind, pointer, user) in [(input, inputData, ContentType.userPrompt, "/content/0/text", true),
                                             (output, outputData, ContentType.intermediateResponse, "/text", false)] {
        let id = row["item"]["id"].string!
        let candidates = batch.sources.filter { $0.record.metadata.identity.itemID == id }
        try demand(candidates.count == 1)
        let source = candidates[0].record, metadata = source.metadata
        guard let tokenRange = bytes.range(of: Data(recoveryValue.utf8)) else { throw RecoveryProbeError.evidence }
        let location = try CanonicalLocation(segmentID: pointer, range: .init(tokenRange.lowerBound, tokenRange.upperBound))
        try demand(metadata.identity.session.sessionID == config.thread && metadata.identity.session.profileID == recoveryProfile
            && metadata.identity.session.provider == .codex && metadata.contentType == kind
            && metadata.contentTime == originalTime(row, turns: times, user: user)
            && metadata.locator == .upstreamItem && metadata.timeBasis == nil
            && metadata.origin.agentVersion == recoveryVersion && metadata.origin.adapterID == "codex"
            && metadata.origin.adapterVersion == CodexAdapter.adapterVersion && metadata.origin.interface == .standaloneCLI
            && metadata.origin.canonicalization == .exclusiveAuthority
            && source.segments.count == 1 && source.segments[0].id == pointer && source.segments[0].utf8 == bytes)
        originals.append(.init(identity: metadata.identity, turnID: row["turnId"].string!, contentType: kind,
            contentTime: metadata.contentTime, revision: source.revision, pointer: pointer, textHash: hash(bytes),
            textBytes: bytes.count, expectedLocation: location,
            nativeRowDigest: try await commitment("native-row", row, crypto: crypto)))
    }
    let entryDigest = try await commitment("native-row", entered, crypto: crypto)
    let exitDigest = try await commitment("native-row", exited, crypto: crypto)
    return .init(schemaVersion: 1, thread: config.thread, reviewTurn: config.turn, inputTurn: inputTurn,
        entryID: entered["item"]["id"].string!, exitID: exited["item"]["id"].string!,
        presentationRowDigests: [entryDigest, exitDigest], originals: originals)
}

private func successfulInspectionKind(_ work: CodexReviewWork) -> String? {
    if let state = work.entryInspection,
       state.transportFailures == 0, state.readerVersion == recoveryVersion,
       state.parserContract == CodexAdapter.parserContract,
       state.pass.turns.pageCount + state.pass.items.pageCount > 0,
       state.pass.turns.bytesRead + state.pass.items.bytesRead > 0 { return "entry" }
    if let state = work.inspection,
       state.transportFailures == 0, state.readerVersion == recoveryVersion,
       state.parserContract == CodexAdapter.parserContract,
       state.pass.pageCount > 0, state.pass.bytesRead > 0 { return "exit" }
    return nil
}

private actor RecoveryNormalizer: CaptureNormalizer {
    let adapter: CodexAdapter, binding: ReviewBinding
    var inspectionStarted = false
    var inspectionKind: String?
    var observedPresentationIDs = Set<String>()
    var sourceObservations = Set<SourceIdentity>()
    var calls = 0
    init(adapter: CodexAdapter, binding: ReviewBinding) { self.adapter = adapter; self.binding = binding }
    func normalize(_ packet: CapturePacket, capturedAt: Date, cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        let batch = try await adapter.normalize(packet, capturedAt: capturedAt, cryptography: cryptography)
        calls += 1
        for collected in batch.sources {
            let source = collected.record, metadata = source.metadata
            guard let expected = binding.originals.first(where: { $0.identity == metadata.identity }) else {
                throw RecoveryProbeError.evidence
            }
            try demand(source.revision == expected.revision && metadata.contentTime == expected.contentTime
                && metadata.contentType == expected.contentType && metadata.locator == .upstreamItem && metadata.timeBasis == nil
                && metadata.origin.agentVersion == recoveryVersion && metadata.origin.interface == .standaloneCLI
                && metadata.origin.adapterID == "codex" && metadata.origin.adapterVersion == CodexAdapter.adapterVersion
                && metadata.origin.canonicalization == .exclusiveAuthority && source.segments.count == 1
                && source.segments[0].id == expected.pointer && source.segments[0].utf8.count == expected.textBytes
                && hash(source.segments[0].utf8) == expected.textHash && tokenCount(source.segments[0].utf8) == 1)
            sourceObservations.insert(metadata.identity)
        }
        for gap in batch.coverageGaps {
            if gap.reason == .unsupportedContent, gap.diagnosticCode == .unknownRecordKind,
               let id = gap.recovery?.itemID, binding.presentations.contains(id) { observedPresentationIDs.insert(id) }
        }
        if let packet = batch.continuation,
           let work = try JSONDecoder().decode(CodexHistoryRequest.self, from: packet.eventJSON).reviewWork {
            if let kind = successfulInspectionKind(work) { inspectionStarted = true; inspectionKind = kind }
        }
        return batch
    }
}
private actor RecoveryDetector: SecretDetector {
    let real: BetterleaksSecretDetector
    var calls = 0
    var full = true
    init(_ configuration: BetterleaksConfiguration) { real = .init(configuration: configuration) }
    func scan(_ source: SourceRecord) async throws -> DetectorOutput {
        calls += 1
        let output = try await real.scan(source)
        full = full && output.detectorVersion == BetterleaksSecretDetector.version
            && output.scannerFailure == nil && output.coverageGaps.isEmpty
        return output
    }
}
private actor CompletionEvidence {
    var ids = Set<UUID>()
    var failures = 0
    func completed(_ id: UUID) { ids.insert(id) }
    func failed() { failures += 1 }
}

private func makeAdapter(_ history: RecoveryHistory, store: ProtectedStore) throws -> CodexAdapter {
    try .init(profileID: recoveryProfile, agentVersion: recoveryVersion, interface: .standaloneCLI,
        authority: .publicNativeItems, history: history, limits: .init(pageSize: 1),
        historyBudget: .init(maximumBytes: 2 * 1024 * 1024, maximumDuration: 8, maximumSources: 256),
        authorityLookup: { try await store.authority(for: $0) },
        authorityRecorder: { choice in
            guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
            try await store.selectAuthority(choice, permit: permit)
        }, checkpointLookup: { try await store.checkpoint(documentID: $0) })
}
private func enqueueAudit(_ adapter: CodexAdapter, store: ProtectedStore, binding: ReviewBinding) async throws -> UUID {
    let now = Date(), audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
    var request = CodexHistoryRequest(audit: audit, threads: [binding.thread]); request.selectedSourceOnly = true
    let packet = try adapter.packet(request)
    let scope = CollectionScope(provider: .codex, profileID: recoveryProfile, interface: .standaloneCLI, path: .publicHistory)
    let context = try CollectionCaptureRoute(scope: scope, readerVersion: recoveryVersion).context(for: packet, trigger: .historyRequest, audit: audit)
    guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
    let id = UUID()
    _ = try await store.enqueue(packet.body, id: id, capturedAt: now, permit: permit, at: now,
        historicalAudit: audit, workContext: context)
    return id
}
private func captureCiphertext(_ store: ProtectedStore, crypto: BackgroundCryptography) async throws -> String {
    let rows = try await store.legacyMigrationRowsForTesting().rows["captures"] ?? []
    try demand(rows.count == 1)
    return try await commitment("capture-ciphertext", rows[0], crypto: crypto)
}
private func finalInventory(_ snapshot: InventorySnapshot, binding: ReviewBinding,
                            crypto: BackgroundCryptography) async throws {
    let identities = Set(binding.originals.map(\.identity))
    let receipts = Set(binding.originals.map { AnalysisReceipt(source: $0.identity, revision: $0.revision, detectorVersion: BetterleaksSecretDetector.version) })
    let fingerprint = try await crypto.fingerprint(exactBytes: Data(recoveryValue.utf8))
    try demand(snapshot.records.count == 1 && snapshot.records[fingerprint] != nil
        && snapshot.occurrences.count == 2 && snapshot.analysisReceipts == receipts
        && Set(snapshot.sourceKinds.keys) == identities && Set(snapshot.sourceTimes.keys) == identities
        && snapshot.locationReceipts.count == 2 && snapshot.unlocatedResults.isEmpty && snapshot.unlocatedReceipts.isEmpty
        && snapshot.obsoleteAppearances.isEmpty && snapshot.obsoleteMarkers.isEmpty)
    for original in binding.originals {
        let occurrences = snapshot.occurrences.values.filter { $0.source.identity == original.identity }
        try demand(occurrences.count == 1 && snapshot.sourceKinds[original.identity] == original.contentType
            && snapshot.sourceTimes[original.identity] == original.contentTime)
        let occurrence = occurrences[0]
        try demand(occurrence.source.contentTime == original.contentTime && occurrence.source.contentType == original.contentType
            && occurrence.source.origin.agentVersion == recoveryVersion && occurrence.source.locator == .upstreamItem
            && occurrence.valueID == snapshot.records[fingerprint]?.id
            && occurrence.identity.location == original.expectedLocation
            && snapshot.locationReceipts[occurrence.identity] == .occurrence(occurrence.id))
    }
}
private func verifyCiphertextFiles(_ controls: URL) throws {
    let manager = FileManager.default
    for directory in [controls.appendingPathComponent("store"), controls.appendingPathComponent("scanner")] {
        guard let files = manager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw RecoveryProbeError.boundary
        }
        var count = 0
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            try demand(values.isSymbolicLink != true)
            if values.isRegularFile == true {
                count += 1; try demand(count <= 128)
                let bytes = try privateBytes(file, limit: 16 * 1024 * 1024)
                try demand(bytes.range(of: Data(recoveryValue.utf8)) == nil)
            }
        }
    }
}

@Suite("Opt-in genuine Codex review production recovery")
struct CodexReviewRecoveryLiveTests {
    @Test func privateControlsAreExclusiveAndDoNotTreatSymlinksAsAbsent() throws {
        let root = URL(fileURLWithPath: "/private/tmp/spillcheck-review-recovery-boundary-\(UUID())")
        try makeDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state.json")
        try writePrivate(Data("{}".utf8), to: file)
        #expect(try privateBytes(file) == Data("{}".utf8))
        #expect(throws: RecoveryProbeError.self) { try writePrivate(Data("{}".utf8), to: file) }
        let link = root.appendingPathComponent("auth.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: root.appendingPathComponent("missing").path)
        #expect(!absent(link))
        #expect(throws: RecoveryProbeError.self) { _ = try privateBytes(link) }
    }

    @Test func originalTextRequirementsRejectCopiesAndChangedBytes() throws {
        #expect(tokenCount(Data(recoveryValue.utf8)) == 1)
        #expect(tokenCount(Data((recoveryValue + recoveryValue).utf8)) == 2)
        #expect(hash(Data("é".utf8)) != hash(Data("e\u{301}".utf8)))
        #expect(!boundedID("bad\nturn") && !boundedID(String(repeating: "x", count: 257)))
    }

    @Test func queuedInspectionRequiresSuccessfulVersionedPageNotRetryState() throws {
        let revision = try ContentRevision(keyedDigest: Data(repeating: 1, count: 32))
        let target = CodexReviewTarget(turnID: "review", itemID: "entry", producerVersion: recoveryVersion,
            rowRevision: revision, textRevision: revision, gap: .init(reason: .unsupportedContent), kind: .entry)
        var entry = CodexReviewEntryInspectionState(profileID: recoveryProfile, threadID: "owned", target: target,
            audit: nil, pageSize: 1)
        var work = CodexReviewWork(targets: [target], finishThreadAfterInspection: false)
        entry.transportFailures = 1; work.entryInspection = entry
        #expect(successfulInspectionKind(work) == nil)
        entry.transportFailures = 0; entry.readerVersion = recoveryVersion
        entry.pass.turns.pageCount = 1; entry.pass.turns.bytesRead = 40; work.entryInspection = entry
        #expect(successfulInspectionKind(work) == "entry")
        entry.transportFailures = 1; work.entryInspection = entry
        #expect(successfulInspectionKind(work) == nil)
        entry.transportFailures = 0; entry.readerVersion = "0.163.0"; work.entryInspection = entry
        #expect(successfulInspectionKind(work) == nil)
        var exit = CodexReviewInspectionState(profileID: recoveryProfile, threadID: "owned", target: target,
            audit: nil, pageSize: 1)
        work.entryInspection = nil; work.inspection = exit
        #expect(successfulInspectionKind(work) == nil)
        exit.readerVersion = recoveryVersion; exit.pass.pageCount = 1; exit.pass.bytesRead = 40; work.inspection = exit
        #expect(successfulInspectionKind(work) == "exit")
        exit.pass.bytesRead = 0; work.inspection = exit
        #expect(successfulInspectionKind(work) == nil)
    }

    @Test func productionHistoryReceiptsSurviveColdWorkerAndForcedReplay() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SPILLCHECK_REVIEW_RECOVERY_STAGE"] != nil else { return }
        let config = try RecoveryConfiguration(environment)
        var report: [String: Any] = ["schemaVersion": 1, "stage": config.stage, "passed": false,
            "parserContract": CodexAdapter.parserContract, "readerVersion": recoveryVersion, "producerVersion": recoveryVersion,
            "detectorVersion": BetterleaksSecretDetector.version, "scannerSHA256": BetterleaksConfiguration.pinnedExecutableSHA256,
            "rulesSHA256": BetterleaksConfiguration.pinnedConfigurationSHA256, "cryptoScope": "disposable-deterministic-test-keys",
            "inputTextSHA256": config.inputHash, "inputTextBytes": config.inputBytes,
            "outputTextSHA256": config.outputHash, "outputTextBytes": config.outputBytes]
        for key in ["signedAcceptance", "keychainAcceptance", "desktopAcceptance", "t3Acceptance", "nativeChildCoverage", "providerUpgradeAcceptance"] { report[key] = false }
        var checks: [String: Bool] = [:], stage = "preflight"
        var store: ProtectedStore?, client: CodexAppServerHistoryClient?, history: RecoveryHistory?, detector: RecoveryDetector?
        var failed = false
        do {
            if config.stage == "queue" { try makeDirectory(config.controls) }
            else { try privateDirectory(config.controls) }
            let keyURL = config.controls.appendingPathComponent("crypto.json")
            let keys: RecoveryKeys
            if config.stage == "queue" {
                keys = .init(schemaVersion: 1, seed: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }),
                    manifest: .fresh(identifierPrefix: "com.spillcheck.test.review-recovery"))
                try writePrivate(encoded(keys), to: keyURL)
            } else { keys = try load(RecoveryKeys.self, keyURL) }
            try demand(keys.schemaVersion == 1 && keys.seed.count == 32)
            let crypto = try BackgroundCryptography.deterministicForTesting(seed: keys.seed, manifest: keys.manifest)
            let scannerDirectory = config.controls.appendingPathComponent("scanner")
            if config.stage == "queue" { try makeDirectory(scannerDirectory) } else { try privateDirectory(scannerDirectory) }
            let scannerConfig = BetterleaksConfiguration(executableURL: config.scanner, configurationURL: config.rules, workingDirectoryURL: scannerDirectory)
            _ = try ScannerProcess.verifyArtifacts(scannerConfig)
            report["scannerArtifactsVerified"] = true
            stage = "opening-encrypted-store"
            if config.stage == "queue" { try demand(absent(config.store)) }
            let opened = try await ProtectedStore.open(at: config.store, cryptography: crypto)
            store = opened
            let bindingURL = config.controls.appendingPathComponent("binding.json")
            let queueURL = config.controls.appendingPathComponent("queue-state.json")
            let finalURL = config.controls.appendingPathComponent("final-state.json")
            let oldQueue = config.stage == "resume" ? try load(QueueEvidence.self, queueURL) : nil
            let oldFinal = config.stage == "replay" ? try load(FinalEvidence.self, finalURL) : nil
            let cold = await opened.snapshot()
            let coldQueue = try await opened.queueStatistics()
            if config.stage == "queue" {
                try demand(cold.analysisReceipts.isEmpty && cold.sourceKinds.isEmpty && cold.records.isEmpty
                    && cold.occurrences.isEmpty && coldQueue.count == 0)
                checks["emptyBeforeAdmission"] = true
            } else if let oldQueue {
                stage = "checking-cold-pending"
                let ids = try await opened.captureIdentitiesForTesting(), queue = try await opened.queueStatistics()
                let pendingDigest = try await commitment("pending-id", oldQueue.pendingID, crypto: crypto)
                let ciphertext = try await captureCiphertext(opened, crypto: crypto)
                let inventory = try await inventoryCommitment(cold, store: opened, crypto: crypto)
                try demand(oldQueue.schemaVersion == 1 && ids.pending == [oldQueue.pendingID]
                    && queue.count == 1 && queue.claimedCount == 0 && queue.encryptedBytes == oldQueue.encryptedBytes
                    && queue.encryptedBytes > 0
                    && pendingDigest == oldQueue.pendingDigest && ciphertext == oldQueue.ciphertextDigest
                    && inventory == oldQueue.inventory)
                checks["pendingIdentityUnchanged"] = true
            } else if let oldFinal {
                stage = "checking-cold-inventory"
                let inventory = try await inventoryCommitment(cold, store: opened, crypto: crypto)
                try demand(oldFinal.schemaVersion == 1 && coldQueue.count == 0
                    && inventory == oldFinal.inventory
                    && cold.analysisReceipts == oldFinal.originalReceipts)
                checks["coldInventoryUnchanged"] = true
            }
            stage = "binding-original-native-sources"
            let readerDirectory = config.controls.appendingPathComponent("reader-" + config.stage)
            try makeDirectory(readerDirectory)
            let passive = CodexAppServerHistoryClient(configuration: try .init(executableURL: config.executable,
                codexHomeURL: config.home, workingDirectoryURL: readerDirectory, requestTimeout: 8, maximumResponseBytes: 2 * 1024 * 1024))
            client = passive
            let measured = RecoveryHistory(client: passive, configuration: config); history = measured
            let adapter = try makeAdapter(measured, store: opened)
            let binding = try await bindOriginals(config, history: measured, adapter: adapter, crypto: crypto)
            if config.stage == "queue" { try writePrivate(encoded(binding), to: bindingURL) }
            else { try demand(binding == load(ReviewBinding.self, bindingURL)) }
            report["originalBindingVerified"] = true; report["nativeInputRootVerified"] = true
            report["exactOwnedSourceOnly"] = true; report["authAbsent"] = true
            await measured.beginProduction()
            let normalizer = RecoveryNormalizer(adapter: adapter, binding: binding)
            let scanner = RecoveryDetector(scannerConfig); detector = scanner
            let pipeline = DetectionPipeline(store: opened, cryptography: crypto, normalizer: normalizer,
                detector: scanner, detectorVersion: BetterleaksSecretDetector.version, liveSince: Date())
            let completions = CompletionEvidence()
            await pipeline.observeCaptureCompletionsForTesting { await completions.completed($0) }
            await pipeline.observeFailuresForTesting { _ in await completions.failed() }
            var originalAdmission: UUID?
            if config.stage != "resume" { originalAdmission = try await enqueueAudit(adapter, store: opened, binding: binding) }
            stage = "processing-production-history"
            let deadline = ProcessInfo.processInfo.systemUptime + 145
            var observedPresentations = oldQueue?.observedPresentationIDs ?? []
            var stoppedForInspection = false
            for _ in 0..<100 {
                try demand(ProcessInfo.processInfo.systemUptime < deadline && absent(config.home.appendingPathComponent("auth.json")))
                if try await opened.queueStatistics().count == 0 { break }
                try demand(try await pipeline.processNext() == .processed)
                let gaps = try await opened.coverageOmissions()
                observedPresentations.formUnion(gaps.compactMap { $0.gap.recovery?.itemID }.filter(binding.presentations.contains))
                observedPresentations.formUnion(await normalizer.observedPresentationIDs)
                if config.stage == "queue", await normalizer.inspectionStarted {
                    let queue = try await opened.queueStatistics(), ids = try await opened.captureIdentitiesForTesting()
                    let completed = await completions.ids
                    try demand(queue.count == 1 && queue.claimedCount == 0 && queue.encryptedBytes > 0
                        && ids.pending.count == 1 && !observedPresentations.isEmpty)
                    guard let originalAdmission else { throw RecoveryProbeError.evidence }
                    try demand(ids.pending[0] != originalAdmission && ids.consumed.contains(originalAdmission)
                        && completed.contains(originalAdmission))
                    let saved = QueueEvidence(schemaVersion: 1, pendingID: ids.pending[0],
                        pendingDigest: try await commitment("pending-id", ids.pending[0], crypto: crypto),
                        ciphertextDigest: try await captureCiphertext(opened, crypto: crypto), encryptedBytes: queue.encryptedBytes,
                        inventory: try await inventoryCommitment(await opened.snapshot(), store: opened, crypto: crypto),
                        observedPresentationIDs: observedPresentations)
                    try writePrivate(encoded(saved), to: queueURL)
                    checks["inspectionPageRead"] = true; checks["pendingInspectionDurable"] = true
                    report["queueInspectionKind"] = await normalizer.inspectionKind
                    stoppedForInspection = true; break
                }
            }
            let failures = await completions.failures, fullScanner = await scanner.full
            try demand(failures == 0 && fullScanner)
            if config.stage == "queue" { try demand(stoppedForInspection) }
            else {
                stage = "checking-full-receipts-and-recovery"
                let snapshot = await opened.snapshot(), queue = try await opened.queueStatistics()
                let omissions = try await opened.coverageOmissions()
                let observedSources = await normalizer.sourceObservations
                try demand(queue.count == 0 && queue.claimedCount == 0 && omissions.isEmpty
                    && observedPresentations == binding.presentations
                    && observedSources == Set(binding.originals.map(\.identity)))
                try await finalInventory(snapshot, binding: binding, crypto: crypto)
                checks["bothPresentationGapsResolved"] = true; checks["noPresentationCopies"] = true
                let inventory = try await inventoryCommitment(snapshot, store: opened, crypto: crypto)
                if let oldQueue {
                    let ids = try await opened.captureIdentitiesForTesting()
                    let completed = await completions.ids
                    try demand(ids.consumed.contains(oldQueue.pendingID) && completed.contains(oldQueue.pendingID))
                    checks["pendingConsumed"] = true; checks["pendingSuccessfullyProcessed"] = true; checks["originalReceiptsFull"] = true
                    try writePrivate(encoded(FinalEvidence(schemaVersion: 1, inventory: inventory, originalReceipts: snapshot.analysisReceipts)), to: finalURL)
                } else if let oldFinal, let originalAdmission {
                    let calls = await scanner.calls, completed = await completions.ids
                    try demand(inventory == oldFinal.inventory && snapshot.analysisReceipts == oldFinal.originalReceipts
                        && calls == 0 && completed.contains(originalAdmission))
                    let counters = await measured.counts()
                    try demand(counters["cursorCalls", default: 0] > 0 && counters["exactTurnCalls", default: 0] > 0)
                    checks["freshAuditRead"] = true; checks["inventoryUnchanged"] = true
                    checks["receiptsUnchanged"] = true; checks["noAdditionalDetectorScans"] = true
                }
            }
            let snapshot = await opened.snapshot(), queue = try await opened.queueStatistics()
            report["analysisReceiptCount"] = snapshot.analysisReceipts.count; report["occurrenceCount"] = snapshot.occurrences.count
            report["sourceCount"] = snapshot.sourceKinds.count; report["valueCount"] = snapshot.records.count
            report["queueCount"] = queue.count; report["gapCount"] = try await opened.coverageOmissions().count
            report["checks"] = checks
        } catch { failed = true; report["failureStage"] = stage }
        if let history {
            let counters = await history.counts()
            for key in ["threadReadCalls", "itemReadCalls", "turnReadCalls", "threadListCalls", "cursorCalls", "exactTurnCalls"] { report[key] = counters[key] ?? 0 }
        }
        report["detectorScanCalls"] = await detector?.calls ?? 0
        if let client {
            await client.close()
            report["readerShutdown"] = await client.lastShutdownCompletedWithinDeadline == true
            if report["readerShutdown"] as? Bool != true, !failed { failed = true; report["failureStage"] = "closing-reader" }
        } else { report["readerShutdown"] = true }
        if let store {
            do { try await store.close(); report["storeClosed"] = true }
            catch { if !failed { report["failureStage"] = "closing-store" }; failed = true; report["storeClosed"] = false }
        } else { report["storeClosed"] = true }
        do {
            try verifyCiphertextFiles(config.controls)
            report["ciphertextVerified"] = true
        } catch { if !failed { report["failureStage"] = "checking-ciphertext" }; failed = true; report["ciphertextVerified"] = false }
        report["authAbsent"] = absent(config.home.appendingPathComponent("auth.json"))
        report["passed"] = !failed && report["readerShutdown"] as? Bool == true
            && report["storeClosed"] as? Bool == true && report["authAbsent"] as? Bool == true
        try writePrivate(JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), to: config.report)
        #expect(report["passed"] as? Bool == true)
    }
}
