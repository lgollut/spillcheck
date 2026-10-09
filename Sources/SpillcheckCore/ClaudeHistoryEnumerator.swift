import Darwin
import Foundation

struct ClaudeDirectoryPosition: Codable, Sendable {
    let path: String
    let depth: Int
    var cookie: Int = 0
    var signature: ClaudeFileSignature?
}

/// Queue-encrypted selection data only. No source body, excerpt, or credential enters this cursor.
struct ClaudeHistoryRequest: Codable, Sendable {
    static let kind = "LeakretClaudeHistory"
    let kind: String
    let version: Int
    let audit: HistoricalAuditContext
    var directories: [ClaudeDirectoryPosition]
    var pending: [String]
    var deferred: [String]
    var partial: Bool

    func validate() throws {
        guard kind == Self.kind, version == 1, directories.count <= 4096,
              pending.count <= 4096, deferred.count <= 4096,
              audit.end.timeIntervalSince1970.isFinite,
              audit.start == audit.end.addingTimeInterval(-HistoricalAuditContext.lookback) else {
            throw ClaudeCollectionError.invalidConfiguration
        }
    }
}

private struct ClaudeHistoryEnvelope: Decodable { let kind: String? }

extension ClaudeAdapter: HistoricalCaptureProducer {
    /// Only disposable acceptance receivers admit externally delivered historical cursors.
    /// Ordinary hooks have no audit. The production queue still requires the same frozen audit
    /// on admission and completion, including every continuation.
    @_spi(Testing) public static func historicalAuditForTesting(in packet: CapturePacket) throws -> HistoricalAuditContext? {
        guard packet.metadata.agent == .claudeCode else { return nil }
        do {
            let envelope = try JSONDecoder().decode(ClaudeHistoryEnvelope.self, from: packet.eventJSON)
            guard envelope.kind == ClaudeHistoryRequest.kind else { return nil }
            let request = try JSONDecoder().decode(ClaudeHistoryRequest.self, from: packet.eventJSON)
            try request.validate()
            return request.audit
        } catch { throw ClaudeCollectionError.invalidConfiguration }
    }

    public func initialHistoricalCapture(audit: HistoricalAuditContext) async throws -> CapturePacket {
        try historyPacket(.init(kind: ClaudeHistoryRequest.kind, version: 1, audit: audit,
            directories: allowedTranscriptRoots.map { .init(path: $0.path, depth: 0) },
            pending: [], deferred: [], partial: false), interface: .standaloneCLI)
    }

    func historyPacket(_ request: ClaudeHistoryRequest, interface: AgentInterface) throws -> CapturePacket {
        try CapturePacket(metadata: .init(agent: .claudeCode, interface: interface, profileID: profileID),
            eventJSON: JSONEncoder().encode(request))
    }

    func normalizeHistory(_ original: ClaudeHistoryRequest, interface: AgentInterface,
                          cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        do { try original.validate() } catch {
            return .init(sources: [], coverageGaps: [.init(reason: .malformedSource)])
        }
        var request = original
        let clock = ContinuousClock(), started = ContinuousClock.now
        var sources: [CollectedSource] = [], checkpoints: [SourceCheckpoint] = [], gaps: [CoverageGap] = []
        var recoveredReferences: [CoverageRecoveryReference] = []
        var bytes = 0, processed = 0, inspected = 0
        var oldest: Date?, newest: Date?
        var seen = Set<String>(), next: [String] = []
        // Deferred sources are placed after newly discovered candidates. Each source gets one
        // bounded slice per pass; a continually growing source cannot monopolize discovery.
        while processed < historyBudget.maximumSources, bytes < historyBudget.maximumBytes,
              clock.now - started < .seconds(historyBudget.maximumDuration) {
            try Task.checkCancellation()
            if request.pending.isEmpty {
                if request.directories.isEmpty {
                    guard !request.deferred.isEmpty else { break }
                    request.pending = request.deferred; request.deferred = []
                    continue
                }
                guard inspected < 4096 else { break }
                var directory = request.directories.removeFirst()
                do {
                    let page = try claudeDiscoverPage(directory, allowedRoots: allowedTranscriptRoots,
                        maximumEntries: min(128, 4096 - inspected))
                    inspected += page.inspected
                    request.pending += page.files
                    request.directories += page.directories
                    gaps += page.gaps
                    if !page.gaps.isEmpty { request.partial = true }
                    if let cookie = page.cookie { directory.cookie = cookie; directory.signature = page.signature; request.directories.append(directory) }
                } catch {
                    gaps.append(.init(reason: .sourceUnavailable)); request.partial = true
                }
                continue
            }
            let path = request.pending.removeFirst()
            guard seen.insert(path).inserted else { continue }
            processed += 1
            do {
                let key = try await checkpointIdentity(path: path, provenance: .historical(request.audit), cryptography: cryptography)
                let checkpoint = try await checkpointLookup(key)
                // A 2 MiB quantum admits the supported 1 MiB physical row while giving another
                // file an opportunity before exhausting the 100 MiB pass budget.
                let quantum = min(2 * 1024 * 1024, historyBudget.maximumBytes - bytes)
                let context = RetainedSourceContext(sessionIdentifier: "", transcriptPath: path, openingCapability: .unverified)
                let read = try await readIncremental(path: path, interface: interface, checkpoint: checkpoint,
                    observedAt: Date(), provenance: .historical(request.audit), context: context,
                    maximumBytes: quantum, cryptography: cryptography)
                bytes += read.bytesRead; sources += read.batch.sources; checkpoints += read.batch.checkpoints
                gaps += read.batch.coverageGaps
                recoveredReferences += read.batch.recoveredReferences
                if let time = read.oldestContentTime { oldest = oldest.map { min($0, time) } ?? time }
                if let time = read.newestContentTime { newest = newest.map { max($0, time) } ?? time }
                if read.canContinueHistory { next.append(path) }
                if read.hasUnreadContent && !read.canContinueHistory { request.partial = true }
                if read.batch.coverageGaps.contains(where: {
                    ![CoverageGapReason.budgetExhausted, .unresolvedCorrelation, .incompleteMessage].contains($0.reason)
                }) { request.partial = true }
            } catch ClaudeCollectionError.unsafeTranscriptPath {
                gaps.append(.init(reason: .sourceUnavailable)); request.partial = true
            } catch ClaudeCollectionError.awaitingTranscript {
                gaps.append(.init(reason: .sourceUnavailable)); request.partial = true
            }
        }
        request.deferred += next
        let continuing = !request.directories.isEmpty || !request.pending.isEmpty || !request.deferred.isEmpty
        if continuing { gaps.append(.init(reason: .budgetExhausted, interval: .init(start: request.audit.start, end: request.audit.end))) }
        let unread = request.partial || continuing || !gaps.isEmpty
        return .init(sources: sources, coverageGaps: Array(Set(gaps)), checkpoints: checkpoints,
            continuation: continuing ? try historyPacket(request, interface: interface) : nil,
            historicalProgress: .init(audit: request.audit, bytesRead: bytes, oldestContentTime: oldest,
                newestContentTime: newest, hasUnreadContent: unread), recoveredReferences: recoveredReferences)
    }
}

private struct ClaudeDiscoveryPage {
    let files: [String], directories: [ClaudeDirectoryPosition], gaps: [CoverageGap]
    let cookie: Int?, signature: ClaudeFileSignature, inspected: Int
}

/// Enumeration is metadata-only, bounded and resumable. Directory cookies are not a guarantee
/// across mutations; a changed directory explicitly marks partial coverage and the next audit
/// starts a new traversal. No file mtime is used to exclude source content.
private func claudeDiscoverPage(_ position: ClaudeDirectoryPosition, allowedRoots: [URL],
                                maximumEntries: Int) throws -> ClaudeDiscoveryPage {
    guard position.depth >= 0, position.depth <= 4, position.cookie >= 0,
          !position.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
          allowedRoots.contains(where: { position.path == $0.path || position.path.hasPrefix($0.path + "/") }) else {
        throw ClaudeCollectionError.unsafeTranscriptPath
    }
    let fd = try claudeOpenDirectory(position.path)
    guard let stream = fdopendir(fd) else { close(fd); throw ClaudeCollectionError.unsafeTranscriptPath }
    defer { closedir(stream) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == getuid() else { throw ClaudeCollectionError.unsafeTranscriptPath }
    let signature = ClaudeFileSignature(info)
    var gaps: [CoverageGap] = []
    if let old = position.signature, old != signature { gaps.append(.init(reason: .sourceChanged)) }
    if position.cookie != 0 { seekdir(stream, position.cookie) }
    var files: [String] = [], directories: [ClaudeDirectoryPosition] = [], inspected = 0
    while inspected < maximumEntries {
        try Task.checkCancellation()
        guard let entry = readdir(stream) else {
            return .init(files: files, directories: directories, gaps: gaps, cookie: nil, signature: signature, inspected: inspected)
        }
        inspected += 1
        let name = withUnsafePointer(to: &entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
        }
        guard !name.hasPrefix("."), !name.contains("/"), !name.utf8.contains(0) else { continue }
        var item = stat()
        guard fstatat(fd, name, &item, AT_SYMLINK_NOFOLLOW) == 0, item.st_uid == getuid() else { continue }
        let path = URL(fileURLWithPath: position.path).appendingPathComponent(name).path
        if (item.st_mode & S_IFMT) == S_IFDIR {
            if position.depth < 4 { directories.append(.init(path: path, depth: position.depth + 1)) }
            else { gaps.append(.init(reason: .budgetExhausted)) }
        } else if (item.st_mode & S_IFMT) == S_IFREG {
            if name.hasSuffix(".jsonl") { files.append(path) }
            else if name.contains(".jsonl.") { gaps.append(.init(reason: .unsupportedContent)) }
        } else if (item.st_mode & S_IFMT) == S_IFLNK { gaps.append(.init(reason: .sourceUnavailable)) }
    }
    return .init(files: files, directories: directories, gaps: gaps,
        cookie: telldir(stream), signature: signature, inspected: inspected)
}

func claudeOpenDirectory(_ path: String) throws -> Int32 {
    guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw ClaudeCollectionError.unsafeTranscriptPath }
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw ClaudeCollectionError.unsafeTranscriptPath }
    for part in path.split(separator: "/") {
        let next = String(part).withCString { openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        close(fd); fd = next
        if fd < 0 { throw ClaudeCollectionError.unsafeTranscriptPath }
    }
    return fd
}
