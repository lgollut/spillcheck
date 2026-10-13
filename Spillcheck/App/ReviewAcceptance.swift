#if DEBUG
import CryptoKit
import Darwin
import Foundation
@_spi(Testing) import SpillcheckCore

// Authenticated DEBUG-only witness. The signed original owner supplies real device protection.
private let recoveryValue = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
private let recoveryVersion = "0.162.1"
private let recoveryProfile = "owned-signed-codex-review"
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
    let stage: String, root: URL, home: URL, executable: URL, store: URL
    let thread: String, turn: String, inputID: String, outputID: String
    let inputHash: String, outputHash: String, inputBytes: Int, outputBytes: Int
    var controls: URL { root.appendingPathComponent("review-evidence") }
    init(recovery: DisposableRecoveryConfiguration, configuration: CodexCollectionConfiguration) throws {
        guard recovery.reviewEnabled, let stage = recovery.reviewStage,
              let bytes = recovery.reviewDescriptorData else { throw RecoveryProbeError.boundary }
        let descriptor = try ReviewAcceptance.Descriptor.decode(bytes)
        self.stage = stage; root = recovery.root; store = recovery.store
        home = configuration.home; executable = configuration.executable
        thread = descriptor.threadID; turn = descriptor.turnID
        inputID = descriptor.inputID; outputID = descriptor.outputID
        inputHash = descriptor.inputSHA256; outputHash = descriptor.outputSHA256
        inputBytes = descriptor.inputBytes; outputBytes = descriptor.outputBytes
        try demand(configuration.profileID == recoveryProfile && configuration.readerVersion == recoveryVersion
            && configuration.interface == .standaloneCLI && configuration.authorizedHosts == [.standaloneCLI]
            && configuration.authority == .publicNativeItems && configuration.activeSources.isEmpty
            && root.deletingLastPathComponent().path == "/private/tmp"
            && root.lastPathComponent.hasPrefix("spillcheck-signed-review-")
            && home.path == root.appendingPathComponent("home").path
            && store.path == root.appendingPathComponent("protected-store").path)
        try privateDirectory(root); try privateDirectory(home)
        try demand(absent(home.appendingPathComponent("auth.json")))
    }
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
    let consumedCaptures: [UUID]
    let observedPresentationIDs: Set<String>
}
private struct FinalEvidence: Codable {
    let schemaVersion: Int
    let inventory: InventoryCommitment
    let originalReceipts: Set<AnalysisReceipt>
    let consumedCaptures: [UUID]
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
          let outputText = output["item"]["text"].string,
          case .object(let outputObject) = output["item"] else { throw RecoveryProbeError.evidence }
    let inputData = Data(inputText.utf8), outputData = Data(outputText.utf8)
    try demand(input["item"]["id"].string == config.inputID && output["item"]["id"].string == config.outputID
        && outputObject["phase"] == CodexJSON.null && output["turnId"].string == config.turn
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

// Read-only projection of a genuine encrypted continuation. This never supplies
// an inspection state to production or reimplements its recovery decision.
private struct ReviewContinuation: Decodable {
    struct Work: Decodable {
        struct Progress: Decodable { let pageCount: Int; let bytesRead: Int }
        struct EntryPass: Decodable { let turns: Progress; let items: Progress }
        struct Entry: Decodable {
            let transportFailures: Int, readerVersion: String?, parserContract: String
            let pass: EntryPass
        }
        struct Exit: Decodable {
            let transportFailures: Int, readerVersion: String?, parserContract: String
            let pass: Progress
        }
        let entryInspection: Entry?, inspection: Exit?
    }
    let reviewWork: Work?
}
private func successfulInspectionKind(_ work: ReviewContinuation.Work) -> String? {
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
           let work = try JSONDecoder().decode(ReviewContinuation.self, from: packet.eventJSON).reviewWork {
            if let kind = successfulInspectionKind(work) { inspectionStarted = true; inspectionKind = kind }
        }
        return batch
    }
}
private actor RecoveryDetector: SecretDetector {
    let real: BetterleaksSecretDetector
    var calls = 0
    var full = true
    init(_ detector: BetterleaksSecretDetector) { real = detector }
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
    let scope = CollectionScope(provider: .codex, profileID: recoveryProfile, interface: .standaloneCLI, path: .publicHistory)
    let session = try SessionIdentity(provider: .codex, profileID: recoveryProfile, sessionID: binding.thread)
    let packet = try await adapter.initialHistoricalCapture(audit: audit,
        source: CoverageSourceRetryDescriptor(scope: scope, session: session))
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
/// Runs the existing genuine review witness inside a signed disposable worker.
/// It deliberately drives production processNext directly; automatic app routing
/// and host setup are separate acceptance gates.
@MainActor
final class ReviewAcceptance {
    struct Descriptor: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let threadID: String, turnID: String, inputID: String, outputID: String
        let inputSHA256: String, outputSHA256: String
        let inputBytes: Int, outputBytes: Int
        let producerVersion: String
        static func decode(_ data: Data) throws -> Self {
            let value = try JSONDecoder().decode(Self.self, from: data)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try demand(data.count <= 4096 && encoder.encode(value) == data && value.schemaVersion == 1
                && UUID(uuidString: value.threadID)?.uuidString.lowercased() == value.threadID
                && boundedID(value.turnID) && boundedID(value.inputID) && boundedID(value.outputID)
                && value.inputID != value.outputID && hexDigest(value.inputSHA256) && hexDigest(value.outputSHA256)
                && (1...16_384).contains(value.inputBytes) && (1...16_384).contains(value.outputBytes)
                && value.producerVersion == recoveryVersion)
            return value
        }
    }
    private(set) var report: [String: Any] = ["passed": false, "status": "not-started"]
    func run(recovery: DisposableRecoveryConfiguration, configuration: CodexCollectionConfiguration,
             store opened: ProtectedStore, cryptography crypto: BackgroundCryptography) async throws {
        let config = try RecoveryConfiguration(recovery: recovery, configuration: configuration)
        var report: [String: Any] = ["schemaVersion": 1, "stage": config.stage, "passed": false,
            "parserContract": CodexAdapter.parserContract, "readerVersion": recoveryVersion, "producerVersion": recoveryVersion,
            "detectorVersion": BetterleaksSecretDetector.version, "upstreamScannerSHA256": BetterleaksConfiguration.pinnedExecutableSHA256,
            "rulesSHA256": BetterleaksConfiguration.pinnedConfigurationSHA256, "cryptoScope": "signed-original-owner-device-protection",
            "inputTextSHA256": config.inputHash, "inputTextBytes": config.inputBytes,
            "outputTextSHA256": config.outputHash, "outputTextBytes": config.outputBytes]
        for key in ["applicationRouteEstablished", "desktopAcceptance", "t3Acceptance", "nativeChildCoverage", "providerUpgradeAcceptance", "systemNotificationDeliveryEstablished"] { report[key] = false }
        var checks: [String: Bool] = [:], stage = "preflight"
        var client: CodexAppServerHistoryClient?, history: RecoveryHistory?, measuredDetector: RecoveryDetector?
        var failed = false
        report["readerStarted"] = false
        do {
            if config.stage == "queue" { try makeDirectory(config.controls) }
            else { try privateDirectory(config.controls) }
            let scannerDirectory = config.controls.appendingPathComponent("scanner")
            let detector = try CollectionConfiguration.bundledDetector(workingDirectory: scannerDirectory)
            report["bundledScannerSelected"] = true
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
                    && inventory == oldQueue.inventory && ids.consumed == oldQueue.consumedCaptures)
                checks["pendingIdentityUnchanged"] = true
            } else if let oldFinal {
                stage = "checking-cold-inventory"
                let inventory = try await inventoryCommitment(cold, store: opened, crypto: crypto)
                let captures = try await opened.captureIdentitiesForTesting()
                try demand(oldFinal.schemaVersion == 1 && coldQueue.count == 0
                    && inventory == oldFinal.inventory
                    && cold.analysisReceipts == oldFinal.originalReceipts
                    && captures.consumed == oldFinal.consumedCaptures)
                checks["coldInventoryUnchanged"] = true
            }
            stage = "binding-original-native-sources"
            let readerDirectory = config.controls.appendingPathComponent("reader-" + config.stage)
            try makeDirectory(readerDirectory)
            let passive = CodexAppServerHistoryClient(configuration: try .init(executableURL: config.executable,
                codexHomeURL: config.home, workingDirectoryURL: readerDirectory, requestTimeout: 8, maximumResponseBytes: 2 * 1024 * 1024))
            client = passive
            report["readerStarted"] = true
            let measured = RecoveryHistory(client: passive, configuration: config); history = measured
            let adapter = try makeAdapter(measured, store: opened)
            let binding = try await bindOriginals(config, history: measured, adapter: adapter, crypto: crypto)
            if config.stage == "queue" { try writePrivate(encoded(binding), to: bindingURL) }
            else { try demand(binding == load(ReviewBinding.self, bindingURL)) }
            report["originalBindingVerified"] = true; report["nativeInputRootVerified"] = true
            report["exactOwnedSourceOnly"] = true; report["authAbsent"] = true
            await measured.beginProduction()
            let normalizer = RecoveryNormalizer(adapter: adapter, binding: binding)
            let scanner = RecoveryDetector(detector); measuredDetector = scanner
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
                        consumedCaptures: ids.consumed, observedPresentationIDs: observedPresentations)
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
                    try writePrivate(encoded(FinalEvidence(schemaVersion: 1, inventory: inventory, originalReceipts: snapshot.analysisReceipts, consumedCaptures: ids.consumed)), to: finalURL)
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
        report["detectorScanCalls"] = await measuredDetector?.calls ?? 0
        if let client {
            await client.close()
            report["readerShutdown"] = await client.lastShutdownCompletedWithinDeadline == true
            if report["readerShutdown"] as? Bool != true, !failed { failed = true; report["failureStage"] = "closing-reader" }
        } else { report["readerShutdown"] = true }
        report["authAbsent"] = absent(config.home.appendingPathComponent("auth.json"))
        report["passed"] = !failed && report["readerShutdown"] as? Bool == true
            && report["authAbsent"] as? Bool == true
        self.report = report
    }
}
#endif
