#if DEBUG
import CryptoKit
import Darwin
import Foundation
@_spi(Testing) import SpillcheckCore

private enum DesktopBetaError: Error { case boundary, evidence, budget }
private func desktopDemand(_ condition: Bool) throws { if !condition { throw DesktopBetaError.evidence } }
private func desktopSHA(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
private let desktopProfile = "owned-signed-codex-desktop-beta"
private let desktopReader = "0.162.1"
private let desktopProducer = "0.160.1"
private let desktopToken = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
private let desktopExpected: [String: ContentType] = [
    "PARENT_PROMPT": .userPrompt, "PARENT_INTERMEDIATE": .intermediateResponse,
    "PARENT_FINAL": .finalResponse, "PARENT_TOOL_OUTPUT": .toolOutput, "PARENT_TOOL_ERROR": .toolError,
    "CHILD_INTERMEDIATE": .intermediateResponse, "CHILD_FINAL": .finalResponse,
    "CHILD_TOOL_OUTPUT": .toolOutput, "CHILD_TOOL_ERROR": .toolError
]
private func desktopCanonical<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let raw = try encoder.encode(value)
    try desktopDemand(raw.count <= 512 * 1024)
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
    return try JSONSerialization.data(withJSONObject: normalize(json), options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
}
private func desktopCommitment<T: Encodable>(_ domain: String, _ value: T, _ crypto: BackgroundCryptography) async throws -> String {
    var bytes = Data(("desktop-beta-acceptance-v1/" + domain + "\n").utf8)
    bytes.append(try desktopCanonical(value))
    return try await crypto.revision(canonicalBytes: bytes).keyedDigest.base64EncodedString()
}
private func desktopPrivateDirectory(_ path: URL) throws {
    var info = stat()
    guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
          info.st_uid == getuid(), info.st_mode & 0o077 == 0,
          let canonical = realpath(path.path, nil) else { throw DesktopBetaError.boundary }
    defer { free(canonical) }
    try desktopDemand(String(cString: canonical) == path.path)
}
private func desktopWrite<T: Encodable>(_ value: T, _ path: URL) throws {
    try desktopPrivateDirectory(path.deletingLastPathComponent())
    let bytes = try desktopCanonical(value)
    let fd = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw DesktopBetaError.boundary }; defer { close(fd) }
    try bytes.withUnsafeBytes { raw in
        var written = 0
        while written < raw.count {
            let count = write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
            guard count > 0 else { throw DesktopBetaError.boundary }; written += count
        }
    }
    try desktopDemand(fsync(fd) == 0)
}
private func desktopLoad<T: Decodable>(_ type: T.Type, _ path: URL) throws -> T {
    try desktopPrivateDirectory(path.deletingLastPathComponent())
    let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw DesktopBetaError.boundary }; defer { close(fd) }
    var first = stat(), last = stat(), named = stat()
    guard fstat(fd, &first) == 0, first.st_mode & S_IFMT == S_IFREG, first.st_uid == getuid(),
          first.st_nlink == 1, first.st_mode & 0o077 == 0, first.st_size >= 0,
          first.st_size <= 512 * 1024 else { throw DesktopBetaError.boundary }
    var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count == 0 { break }
        guard count > 0, bytes.count <= 512 * 1024 - count else { throw DesktopBetaError.boundary }
        bytes.append(contentsOf: buffer.prefix(count))
    }
    guard fstat(fd, &last) == 0, lstat(path.path, &named) == 0,
          first.st_dev == last.st_dev, first.st_ino == last.st_ino, first.st_size == last.st_size,
          first.st_mtimespec.tv_sec == last.st_mtimespec.tv_sec, first.st_mtimespec.tv_nsec == last.st_mtimespec.tv_nsec,
          first.st_dev == named.st_dev, first.st_ino == named.st_ino,
          first.st_mode == named.st_mode, named.st_nlink == 1, bytes.count == first.st_size else {
        throw DesktopBetaError.boundary
    }
    return try JSONDecoder().decode(type, from: bytes)
}

private struct DesktopSegment: Codable, Equatable {
    let id: String, sha256: String
    let bytes: Int
}
private struct DesktopOriginal: Codable, Equatable {
    let identity: SourceIdentity
    let kind: ContentType
    let time: Date
    let revision: ContentRevision
    let segments: [DesktopSegment]
    let locations: [CanonicalLocation]
    let markers: [String]
}
private struct DesktopBinding: Codable, Equatable {
    let schemaVersion: Int
    let originals: [DesktopOriginal]
    let nativeRows: [String]
    let typedMarkers: [String: Int]
}
private struct DesktopPair<K: Encodable, V: Encodable>: Encodable { let key: K; let value: V }
private struct DesktopInventory: Codable, Equatable {
    let counts: [String: Int]
    let digests: [String: [String]]
    let schemaVersion: Int, nextValueLabel: Int, payloadCount: Int
}
private struct DesktopFinal: Codable {
    let schemaVersion: Int
    let inventory: DesktopInventory
    let receipts: Set<AnalysisReceipt>
    let omission: CoverageOmission
    let consumedCaptures: [UUID]
}

private actor DesktopHistory: CodexHistoryReading {
    let client: CodexAppServerHistoryClient
    let descriptor: DesktopBetaAcceptance.Descriptor
    let deadline = ProcessInfo.processInfo.systemUptime + 150
    var remainingBytes = 32 * 1024 * 1024
    var production = false, linked = false
    var threads = 0, items = 0, turns = 0, lists = 0, calls = 0, productionBytes = 0
    var productionThreadIDs = Set<String>()
    init(_ client: CodexAppServerHistoryClient, _ descriptor: DesktopBetaAcceptance.Descriptor) {
        self.client = client; self.descriptor = descriptor
    }
    func beginProduction() { production = true }
    private func admit(_ id: String, _ budget: CodexRPCBudget) throws -> CodexRPCBudget {
        try desktopDemand(descriptor.ids.contains(id) && (id == descriptor.parentID || linked)
            && calls < 128 && remainingBytes > 0 && deadline > ProcessInfo.processInfo.systemUptime)
        calls += 1
        return try .init(maximumBytes: min(remainingBytes, budget.maximumBytes),
            timeout: min(budget.timeout, deadline - ProcessInfo.processInfo.systemUptime))
    }
    private func charge(_ count: Int) throws {
        try desktopDemand(count >= 0 && count <= remainingBytes); remainingBytes -= count
        if production { productionBytes += count }
    }
    func readThread(_ id: String) async throws -> CodexThreadRead {
        try await readThread(id, budget: .init(maximumBytes: 4 * 1024 * 1024, timeout: 10))
    }
    func readThread(_ id: String, budget: CodexRPCBudget) async throws -> CodexThreadRead {
        let result = try await client.readThread(id, budget: admit(id, budget)); try charge(result.bytesRead)
        let thread = result.thread
        guard result.readerVersion == desktopReader, thread["id"].string == id,
              thread["cliVersion"].string == descriptor.producerVersion, thread["cwd"].string == descriptor.projectPath,
              thread["ephemeral"].bool != true, let sourcePath = thread["path"].string,
              sourcePath.hasPrefix(descriptor.homePath + "/") else { throw DesktopBetaError.evidence }
        if production { threads += 1; productionThreadIDs.insert(id) }
        return result
    }
    func listThreads(cursor: String?, limit: Int, archived: Bool) throws -> CodexHistoryPage { lists += 1; throw DesktopBetaError.boundary }
    func listThreads(cursor: String?, limit: Int, archived: Bool, budget: CodexRPCBudget) throws -> CodexHistoryPage { lists += 1; throw DesktopBetaError.boundary }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection) async throws -> CodexHistoryPage {
        try await listTurns(threadID: threadID, cursor: cursor, limit: limit, direction: direction,
            budget: .init(maximumBytes: 4 * 1024 * 1024, timeout: 10))
    }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection, budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        let page = try await client.listTurns(threadID: threadID, cursor: cursor, limit: limit, direction: direction,
            budget: admit(threadID, budget)); try charge(page.bytesRead)
        try desktopDemand(page.readerVersion == desktopReader && page.data.count <= limit)
        if production { turns += 1 }; return page
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int, direction: CodexHistoryDirection) async throws -> CodexHistoryPage {
        try await listItems(threadID: threadID, turnID: turnID, cursor: cursor, limit: limit, direction: direction,
            budget: .init(maximumBytes: 4 * 1024 * 1024, timeout: 10))
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int, direction: CodexHistoryDirection, budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        let page = try await client.listItems(threadID: threadID, turnID: turnID, cursor: cursor, limit: limit,
            direction: direction, budget: admit(threadID, budget)); try charge(page.bytesRead)
        try desktopDemand(page.readerVersion == desktopReader && page.data.count <= limit)
        for row in page.data {
            let item = row["item"]
            guard ["collabAgentToolCall", "subAgentActivity"].contains(item["type"].string ?? "") else { continue }
            let references = Set([item["agentThreadId"].string].compactMap { $0 }
                + (item["receiverThreadIds"].array ?? []).compactMap(\.string))
            try desktopDemand(references.isSubset(of: descriptor.ids))
            let nativeCreation = item["type"].string == "subAgentActivity" && item["kind"].string == "started"
                || item["type"].string == "collabAgentToolCall" && item["tool"].string == "spawnAgent"
                    && item["senderThreadId"].string == threadID && item["status"].string == "completed"
            if nativeCreation && threadID == descriptor.parentID && references.contains(descriptor.childID) { linked = true }
        }
        if production { items += 1 }; return page
    }
    func counters() -> [String: Int] {
        ["threadReadCalls": threads, "itemReadCalls": items, "turnReadCalls": turns, "threadListCalls": lists,
         "nativeBytesRead": productionBytes, "productionSessionCount": productionThreadIDs.count]
    }
}

private func desktopAllowedGap(_ gap: CoverageGap, descriptor: DesktopBetaAcceptance.Descriptor) -> Bool {
    let scope = CollectionScope(provider: .codex, profileID: desktopProfile, interface: .desktopCode, path: .publicHistory)
    return gap.scope == scope && gap.reason == .unsupportedContent && gap.contentType == .userPrompt
        && gap.operation == .historicalRead && gap.diagnosticCode == .nativeChildInputUnavailable
        && gap.isRequiredFormatFailure == true && gap.excludedContent != true && gap.sourceKind == nil
        && gap.capabilityID == nil && gap.interval == nil && gap.recovery?.locator == .unavailable
        && gap.recovery?.session?.provider == .codex && gap.recovery?.session?.profileID == desktopProfile
        && gap.recovery?.session?.sessionID == descriptor.childID
        && gap.recovery?.itemID == "codex-native-child-input" && gap.recovery?.contentTime == nil
        && gap.recovery?.parserContract == CodexAdapter.parserContract && gap.recovery?.constraint == nil
        && gap.recovery?.sourceURL == nil && gap.recovery?.sourceDocumentID == nil
}
private func desktopFreshGapEmissionMatches(_ emittedGap: CoverageGap, _ durableGap: CoverageGap,
                                            observedDuring interval: DateInterval) throws -> Bool {
    guard let latest = emittedGap.observedAt, let earlier = durableGap.observedAt,
          latest.timeIntervalSince1970.isFinite, earlier.timeIntervalSince1970.isFinite,
          interval.start.timeIntervalSince1970.isFinite, interval.end.timeIntervalSince1970.isFinite,
          interval.duration >= 0, interval.duration <= 180,
          latest > earlier, latest >= interval.start, latest <= interval.end else { return false }
    // Repeating a blocked omission preserves its entire durable record. The
    // independent fresh adapter event must match that gap except for observation
    // time. Never relax equality of the stored omission to prove a reread.
    func withoutObservation(_ value: CoverageGap) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: desktopCanonical(value)) as? [String: Any] else {
            throw DesktopBetaError.evidence
        }
        object.removeValue(forKey: "observedAt")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    return try withoutObservation(emittedGap) == withoutObservation(durableGap)
}
private func desktopLocations(_ source: SourceRecord) throws -> [CanonicalLocation] {
    let token = Data(desktopToken.utf8)
    var result: [CanonicalLocation] = []
    for segment in source.segments {
        var offset = 0
        while offset < segment.utf8.count,
              let range = segment.utf8.range(of: token, in: offset..<segment.utf8.count) {
            result.append(try .init(segmentID: segment.id, range: .init(range.lowerBound, range.upperBound)))
            offset = range.upperBound
        }
    }
    return result
}
private func desktopOriginal(_ source: SourceRecord, descriptor: DesktopBetaAcceptance.Descriptor) throws -> DesktopOriginal {
    let metadata = source.metadata
    try desktopDemand(metadata.identity.session.provider == .codex && metadata.identity.session.profileID == desktopProfile
        && descriptor.ids.contains(metadata.identity.session.sessionID) && metadata.locator == .upstreamItem
        && metadata.origin.agentVersion == descriptor.producerVersion && metadata.origin.interface == .desktopCode
        && metadata.origin.adapterID == "codex" && metadata.origin.adapterVersion == CodexAdapter.adapterVersion
        && metadata.origin.canonicalization == .exclusiveAuthority && source.segments.count <= 128)
    let role = metadata.identity.session.sessionID == descriptor.parentID ? "PARENT_" : "CHILD_"
    let locations = try desktopLocations(source)
    let text = source.segments.map { String(decoding: $0.utf8, as: UTF8.self) }.joined(separator: "\n")
    let markers = desktopExpected.filter { marker, kind in
        marker.hasPrefix(role) && kind == metadata.contentType && !locations.isEmpty
            && text.contains("SPILLCHECK_GUI_" + marker)
    }.keys.sorted()
    return .init(identity: metadata.identity, kind: metadata.contentType, time: metadata.contentTime,
        revision: source.revision, segments: source.segments.map { .init(id: $0.id, sha256: desktopSHA($0.utf8), bytes: $0.utf8.count) },
        locations: locations, markers: markers)
}

private func desktopBind(_ descriptor: DesktopBetaAcceptance.Descriptor, history: DesktopHistory,
                         adapter: CodexAdapter, crypto: BackgroundCryptography) async throws -> DesktopBinding {
    var originals: [SourceIdentity: DesktopOriginal] = [:], rows: [String] = [], markers: [String: Int] = [:]
    for id in [descriptor.parentID, descriptor.childID] {
        let thread = try await history.readThread(id).thread
        var times: [String: DateInterval] = [:], cursor: String?, seen = Set<String>()
        for number in 0..<16 {
            let page = try await history.listTurns(threadID: id, cursor: cursor, limit: 64, direction: .ascending)
            for turn in page.data {
                if let turnID = turn["id"].string, let start = turn["startedAt"].number,
                   let end = turn["completedAt"].number ?? turn["startedAt"].number,
                   start.isFinite, end.isFinite, end >= start {
                    times[turnID] = DateInterval(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
                }
            }
            guard let next = page.nextCursor else { break }
            try desktopDemand(number < 15 && seen.insert(next).inserted); cursor = next
        }
        cursor = nil; seen = []
        for number in 0..<16 {
            let page = try await history.listItems(threadID: id, turnID: nil, cursor: cursor, limit: 64, direction: .ascending)
            for row in page.data { rows.append(try await desktopCommitment("native-row", DesktopPair(key: id, value: row), crypto)) }
            let batch = try await adapter.importPublicItems(page, thread: thread, observedAt: Date(), turnTimes: times, cryptography: crypto)
            try desktopDemand(batch.coverageGaps.isEmpty && originals.count + batch.sources.count <= 128 && rows.count <= 1024)
            for collected in batch.sources {
                let original = try desktopOriginal(collected.record, descriptor: descriptor)
                try desktopDemand(original.identity.session.sessionID == id && originals[original.identity] == nil)
                originals[original.identity] = original
                for marker in original.markers { markers[marker, default: 0] += 1 }
            }
            guard let next = page.nextCursor else { break }
            try desktopDemand(number < 15 && seen.insert(next).inserted); cursor = next
        }
    }
    try desktopDemand(await history.linked)
    try desktopDemand(markers == desktopExpected.mapValues { _ in 1 }
        && Set(originals.keys.map { $0.session.sessionID }) == descriptor.ids
        && originals.values.reduce(0) { $0 + $1.locations.count } == 15)
    let sorted = originals.values.sorted { left, right in
        if left.identity.session.sessionID != right.identity.session.sessionID {
            return left.identity.session.sessionID < right.identity.session.sessionID
        }
        return left.identity.itemID < right.identity.itemID
    }
    return .init(schemaVersion: 1, originals: sorted, nativeRows: rows.sorted(), typedMarkers: markers)
}
private actor DesktopNormalizer: CaptureNormalizer {
    let adapter: CodexAdapter, binding: DesktopBinding, descriptor: DesktopBetaAcceptance.Descriptor
    var observed = Set<SourceIdentity>(), calls = 0
    var canonicalGaps: [CoverageGap] = []
    init(_ adapter: CodexAdapter, _ binding: DesktopBinding, _ descriptor: DesktopBetaAcceptance.Descriptor) {
        self.adapter = adapter; self.binding = binding; self.descriptor = descriptor
    }
    func normalize(_ packet: CapturePacket, capturedAt: Date, cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        let batch = try await adapter.normalize(packet, capturedAt: capturedAt, cryptography: cryptography)
        calls += 1; try desktopDemand(calls <= 128)
        for source in batch.sources {
            let actual = try desktopOriginal(source.record, descriptor: descriptor)
            try desktopDemand(binding.originals.contains(actual))
            observed.insert(actual.identity)
        }
        for gap in batch.coverageGaps {
            try desktopDemand(desktopAllowedGap(gap, descriptor: descriptor)); canonicalGaps.append(gap)
        }
        return batch
    }
}
private actor DesktopDetector: SecretDetector {
    let real: BetterleaksSecretDetector
    var calls = 0, full = true
    init(_ detector: BetterleaksSecretDetector) { real = detector }
    func scan(_ source: SourceRecord) async throws -> DetectorOutput {
        calls += 1
        let result = try await real.scan(source)
        full = full && result.detectorVersion == BetterleaksSecretDetector.version
            && result.scannerFailure == nil && result.coverageGaps.isEmpty
        return result
    }
}
private actor DesktopCompletions {
    var completed = Set<UUID>(), failures = 0
    func success(_ id: UUID) { completed.insert(id) }
    func failure() { failures += 1 }
}
private func desktopAdapter(_ history: DesktopHistory, store: ProtectedStore) throws -> CodexAdapter {
    try .init(profileID: desktopProfile, agentVersion: desktopProducer, interface: .desktopCode,
        authority: .publicNativeItems, history: history, limits: .init(pageSize: 64),
        historyBudget: .init(maximumBytes: 4 * 1024 * 1024, maximumDuration: 10, maximumSources: 128),
        authorityLookup: { try await store.authority(for: $0) }, authorityRecorder: { choice in
            guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
            try await store.selectAuthority(choice, permit: permit)
        }, checkpointLookup: { try await store.checkpoint(documentID: $0) })
}
private func desktopInventory(_ snapshot: InventorySnapshot, store: ProtectedStore,
                              crypto: BackgroundCryptography) async throws -> DesktopInventory {
    var counts: [String: Int] = [:], digests: [String: [String]] = [:]
    func rows<T: Encodable>(_ name: String, _ values: [T]) async throws {
        try desktopDemand(values.count <= 128); counts[name] = values.count
        var result: [String] = []
        for value in values { result.append(try await desktopCommitment(name, value, crypto)) }
        digests[name] = result.sorted()
    }
    func pairs<K: Encodable, V: Encodable>(_ name: String, _ values: [K: V]) async throws {
        try await rows(name, values.map { DesktopPair(key: $0.key, value: $0.value) })
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
private func desktopCheckInventory(_ snapshot: InventorySnapshot, _ binding: DesktopBinding,
                                  crypto: BackgroundCryptography) async throws {
    let identities = Set(binding.originals.map(\.identity))
    let receipts = Set(binding.originals.map { AnalysisReceipt(source: $0.identity, revision: $0.revision,
        detectorVersion: BetterleaksSecretDetector.version) })
    let fingerprint = try await crypto.fingerprint(exactBytes: Data(desktopToken.utf8))
    try desktopDemand(snapshot.analysisReceipts == receipts && Set(snapshot.sourceKinds.keys) == identities
        && Set(snapshot.sourceTimes.keys) == identities && snapshot.records.count == 1 && snapshot.records[fingerprint] != nil
        && snapshot.occurrences.count == 15 && snapshot.locationReceipts.count == 15
        && snapshot.obsoleteMarkers.isEmpty && snapshot.obsoleteAppearances.isEmpty
        && snapshot.unlocatedResults.isEmpty && snapshot.unlocatedReceipts.isEmpty)
    for original in binding.originals {
        let appearances = snapshot.occurrences.values.filter { $0.source.identity == original.identity }
        try desktopDemand(snapshot.sourceKinds[original.identity] == original.kind
            && snapshot.sourceTimes[original.identity] == original.time
            && Set(appearances.map { $0.identity.location }) == Set(original.locations)
            && appearances.count == original.locations.count)
        for appearance in appearances {
            try desktopDemand(appearance.valueID == snapshot.records[fingerprint]?.id
                && appearance.source.contentType == original.kind && appearance.source.contentTime == original.time
                && appearance.source.origin.agentVersion == desktopProducer && appearance.source.origin.interface == .desktopCode
                && snapshot.locationReceipts[appearance.identity] == .occurrence(appearance.id))
        }
    }
}

/// A bounded signed retained-source check. It never opens a live desktop session,
/// installs hooks, enumerates the provider home or changes a full-support gate.
@MainActor final class DesktopBetaAcceptance {
    struct Descriptor: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let parentID: String, childID: String, homePath: String, projectPath: String
        let producerVersion: String, hostVersion: String, ownershipProofSHA256: String
        var ids: Set<String> { [parentID, childID] }
        nonisolated static func decode(_ bytes: Data) throws -> Self {
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try desktopDemand(bytes.count <= 8192 && encoder.encode(value) == bytes && value.schemaVersion == 1
                && UUID(uuidString: value.parentID)?.uuidString.lowercased() == value.parentID
                && UUID(uuidString: value.childID)?.uuidString.lowercased() == value.childID && value.parentID != value.childID
                && value.producerVersion == desktopProducer && value.hostVersion == "26.930.61225"
                && value.homePath.hasPrefix("/") && value.projectPath.hasPrefix("/")
                && value.projectPath.hasSuffix("/.build/harness-compatibility/manual-codex-gui-beta-2026-10-10/work")
                && !value.homePath.utf8.contains(0) && !value.projectPath.utf8.contains(0)
                && value.homePath.utf8.count <= 4096 && value.projectPath.utf8.count <= 4096
                && value.ownershipProofSHA256.count == 64
                && value.ownershipProofSHA256.allSatisfy { "0123456789abcdef".contains($0) })
            return value
        }
    }
    private(set) var report: [String: Any] = ["passed": false, "status": "not-started"]
    static func omissionRereadMatchesForTesting(_ current: CoverageOmission, _ previous: CoverageOmission,
                                               emittedGap: CoverageGap, observedDuring interval: DateInterval) throws -> Bool {
        try current == previous && desktopFreshGapEmissionMatches(emittedGap, previous.gap, observedDuring: interval)
    }
    func run(recovery: DisposableRecoveryConfiguration, configuration: CodexCollectionConfiguration,
             store: ProtectedStore, cryptography crypto: BackgroundCryptography) async throws {
        guard recovery.desktopBetaEnabled, let stage = recovery.desktopBetaStage,
              ["scan", "replay"].contains(stage), let data = recovery.desktopBetaDescriptorData else { throw DesktopBetaError.boundary }
        let descriptor = try Descriptor.decode(data)
        try desktopDemand(configuration.profileID == desktopProfile && configuration.readerVersion == desktopReader
            && configuration.interface == .desktopCode && configuration.authorizedHosts == [.desktopCode]
            && configuration.authority == .publicNativeItems && configuration.activeSources.isEmpty
            && configuration.home.path == descriptor.homePath
            && recovery.root.deletingLastPathComponent().path == "/private/tmp"
            && recovery.root.lastPathComponent.hasPrefix("spillcheck-desktop-beta-"))
        try desktopPrivateDirectory(recovery.root)
        for path in [descriptor.homePath, descriptor.projectPath] {
            guard let canonical = realpath(path, nil) else { throw DesktopBetaError.boundary }
            defer { free(canonical) }; try desktopDemand(String(cString: canonical) == path)
        }
        let controls = recovery.root.appendingPathComponent("desktop-beta-evidence")
        var report: [String: Any] = ["schemaVersion": 1, "stage": stage, "passed": false,
            "readerStarted": false, "readerShutdown": false,
            "parserContract": CodexAdapter.parserContract, "readerVersion": desktopReader,
            "producerVersion": desktopProducer, "hostVersion": descriptor.hostVersion,
            "detectorVersion": BetterleaksSecretDetector.version,
            "upstreamScannerSHA256": BetterleaksConfiguration.pinnedExecutableSHA256,
            "rulesSHA256": BetterleaksConfiguration.pinnedConfigurationSHA256,
            "cryptoScope": "signed-original-owner-device-protection", "ownershipProofSHA256": descriptor.ownershipProofSHA256]
        for key in ["applicationRouteEstablished", "liveDesktopDispatchEstablished", "sideChatCoverageEstablished",
            "nativeChildIncomingInputEstablished", "sourceOpeningEstablished", "systemNotificationDeliveryEstablished", "fullCodexAcceptance"] {
            report[key] = false
        }
        var checks: [String: Bool] = [:], step = "preflight", failed = false
        var client: CodexAppServerHistoryClient?, history: DesktopHistory?, detector: DesktopDetector?
        do {
            if stage == "scan" { try desktopDemand(mkdir(controls.path, 0o700) == 0) }
            try desktopPrivateDirectory(controls)
            let bindingURL = controls.appendingPathComponent("binding.json"), finalURL = controls.appendingPathComponent("final.json")
            let old = stage == "replay" ? try desktopLoad(DesktopFinal.self, finalURL) : nil
            let initial = await store.snapshot(), queue = try await store.queueStatistics()
            if let old {
                let coldInventory = try await desktopInventory(initial, store: store, crypto: crypto)
                let coldOmissions = try await store.coverageOmissions(includeRecovered: true)
                let coldCaptures = try await store.captureIdentitiesForTesting()
                try desktopDemand(old.schemaVersion == 1 && queue.count == 0
                    && old.inventory == coldInventory && initial.analysisReceipts == old.receipts
                    && coldOmissions == [old.omission] && coldCaptures.consumed == old.consumedCaptures)
                checks["coldInventoryAndGapUnchangedBeforeRead"] = true
            } else {
                let initialOmissions = try await store.coverageOmissions(includeRecovered: true)
                try desktopDemand(initial.records.isEmpty && initial.occurrences.isEmpty && initial.analysisReceipts.isEmpty
                    && initial.sourceKinds.isEmpty && queue.count == 0 && initialOmissions.isEmpty)
                checks["emptyBeforeAdmission"] = true
            }
            step = "original-native-binding"
            let readerDirectory = controls.appendingPathComponent("reader-" + stage)
            try desktopDemand(mkdir(readerDirectory.path, 0o700) == 0)
            let passive = CodexAppServerHistoryClient(configuration: try .init(executableURL: configuration.executable,
                codexHomeURL: configuration.home, workingDirectoryURL: readerDirectory, requestTimeout: 10,
                maximumResponseBytes: 4 * 1024 * 1024))
            client = passive; report["readerStarted"] = true
            let measured = DesktopHistory(passive, descriptor); history = measured
            let adapter = try desktopAdapter(measured, store: store)
            let binding = try await desktopBind(descriptor, history: measured, adapter: adapter, crypto: crypto)
            if stage == "scan" { try desktopWrite(binding, bindingURL) }
            else { try desktopDemand(binding == desktopLoad(DesktopBinding.self, bindingURL)) }
            checks["originalNativeRowsBound"] = true; checks["nativeParentChildLinkVerified"] = true
            await measured.beginProduction()
            let normalizer = DesktopNormalizer(adapter, binding, descriptor)
            let scanner = DesktopDetector(try CollectionConfiguration.bundledDetector(workingDirectory: controls.appendingPathComponent("scanner")))
            detector = scanner
            let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: normalizer,
                detector: scanner, detectorVersion: BetterleaksSecretDetector.version, liveSince: Date())
            let completions = DesktopCompletions()
            await pipeline.observeCaptureCompletionsForTesting { await completions.success($0) }
            await pipeline.observeFailuresForTesting { _ in await completions.failure() }
            let scope = CollectionScope(provider: .codex, profileID: desktopProfile, interface: .desktopCode, path: .publicHistory)
            let route = CollectionCaptureRoute(scope: scope, readerVersion: desktopReader)
            // Initial discovery proves production child traversal. On replay, normal
            // profile audits can skip the unchanged parent from its saved checkpoint.
            // Use the production exact-source retry API for each already bound source.
            // Distinct audits retain the child's partial progress independently.
            let selections: [String?] = old == nil ? [nil] : [descriptor.parentID, descriptor.childID]
            var admissions = Set<UUID>(), audits = Set<UUID>()
            let processingBeganAt = Date()
            step = "production-scan"
            for selection in selections {
                let now = Date(), audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
                let packet: CapturePacket, retry: CoverageSourceRetryDescriptor?
                if let selection {
                    let session = try SessionIdentity(provider: .codex, profileID: desktopProfile, sessionID: selection)
                    let selected = CoverageSourceRetryDescriptor(scope: scope, session: session)
                    packet = try await adapter.initialHistoricalCapture(audit: audit, source: selected)
                    retry = selected
                } else {
                    let emptyRequest = try await adapter.initialHistoricalCapture(audit: audit)
                    guard var request = try JSONSerialization.jsonObject(with: emptyRequest.eventJSON) as? [String: Any] else {
                        throw DesktopBetaError.evidence
                    }
                    request["threads"] = [descriptor.parentID]; request["discovering"] = false
                    packet = try CapturePacket(metadata: emptyRequest.metadata,
                        eventJSON: JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]))
                    retry = nil
                }
                let context = try route.context(for: packet, trigger: .historyRequest, audit: audit, retry: retry)
                guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
                let admission = UUID(); admissions.insert(admission); audits.insert(audit.id)
                report["initialAdmissionCount"] = admissions.count; report["createdAuditCount"] = audits.count
                _ = try await store.enqueue(packet.body, id: admission, capturedAt: now, permit: permit, at: now, historicalAudit: audit, workContext: context)
                for _ in 0..<128 {
                    if try await store.queueStatistics().count == 0 { break }
                    try desktopDemand(try await pipeline.processNext() == .processed)
                }
                try desktopDemand(try await store.queueStatistics().count == 0)
            }
            let final = await store.snapshot(), finalQueue = try await store.queueStatistics()
            let omissions = try await store.coverageOmissions(includeRecovered: true)
            let failures = await completions.failures, completed = await completions.completed
            let full = await scanner.full, observed = await normalizer.observed, emissions = await normalizer.canonicalGaps
            let consumed = Set(try await store.captureIdentitiesForTesting().consumed)
            report["successfulAdmissionCount"] = completed.intersection(admissions).count
            report["consumedAdmissionCount"] = consumed.intersection(admissions).count
            report["observedOriginalSourceCount"] = observed.count
            report["expectedOriginalSourceCount"] = binding.originals.count
            report["canonicalGapEmissionCount"] = emissions.count; report["durableOmissionCount"] = omissions.count
            report["pipelineFailureCount"] = failures; report["normalizerCallCount"] = await normalizer.calls
            report["queueCount"] = finalQueue.count; report["queueClaimedCount"] = finalQueue.claimedCount
            try desktopDemand(finalQueue.count == 0 && finalQueue.claimedCount == 0 && failures == 0
                && admissions.count == selections.count && audits.count == selections.count
                && admissions.isSubset(of: completed) && admissions.isSubset(of: consumed)
                && full && observed == Set(binding.originals.map(\.identity))
                && emissions.count == 1 && omissions.count == 1
                && desktopAllowedGap(omissions[0].gap, descriptor: descriptor) && omissions[0].isUnresolved)
            try await desktopCheckInventory(final, binding, crypto: crypto)
            checks["allOriginalSourcesHaveFullCurrentReceipts"] = true
            checks["fiveParentFourChildMarkersCommitted"] = true
            checks["onlyCanonicalChildInputLimitation"] = true
            checks["freshAuditSuccessfullyProcessed"] = true
            let inventory = try await desktopInventory(final, store: store, crypto: crypto)
            let calls = await scanner.calls
            if let old {
                let inventoryEqual = inventory == old.inventory, receiptsEqual = final.analysisReceipts == old.receipts
                let omissionEqual = omissions == [old.omission]
                report["inventoryEqual"] = inventoryEqual; report["receiptsEqual"] = receiptsEqual
                report["omissionEqual"] = omissionEqual
                let freshEmission = try desktopFreshGapEmissionMatches(emissions[0], old.omission.gap,
                    observedDuring: DateInterval(start: processingBeganAt, end: Date()))
                report["freshCanonicalGapObservedWithinReplay"] = freshEmission
                try desktopDemand(inventoryEqual && receiptsEqual && omissionEqual && freshEmission && calls == 0)
                checks["inventoryReceiptsAndGapUnchangedAfterReread"] = true
                checks["exactSourceRetriesConsumedAfterFreshReads"] = true
                checks["freshCanonicalGapObservedWithinReplay"] = true
                checks["noAdditionalDetectorScans"] = true
            } else {
                try desktopDemand(calls == binding.originals.count)
                try desktopWrite(DesktopFinal(schemaVersion: 1, inventory: inventory, receipts: final.analysisReceipts,
                    omission: omissions[0], consumedCaptures: try await store.captureIdentitiesForTesting().consumed), finalURL)
                checks["everyOriginalFullyScanned"] = true
            }
            report["typedCommittedMarkers"] = binding.typedMarkers
            report["analysisReceiptCount"] = final.analysisReceipts.count; report["sourceCount"] = final.sourceKinds.count
            report["occurrenceCount"] = final.occurrences.count; report["valueCount"] = final.records.count
            report["sessionCount"] = Set(final.sourceKinds.keys.map(\.session)).count
            report["gapCount"] = omissions.count; report["queueCount"] = finalQueue.count
        } catch { failed = true; report["failureStage"] = step }
        if let history { for (key, value) in await history.counters() { report[key] = value } }
        report["detectorScanCalls"] = await detector?.calls ?? 0
        if let client {
            await client.close(); report["readerShutdown"] = await client.lastShutdownCompletedWithinDeadline == true
        } else { report["readerShutdown"] = true }
        report["checks"] = checks
        report["passed"] = !failed && report["readerShutdown"] as? Bool == true
            && report["productionSessionCount"] as? Int == 2 && (report["nativeBytesRead"] as? Int ?? 0) > 0
        self.report = report
    }
}
#endif
