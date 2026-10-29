import Darwin
import Foundation

struct ClaudeDirectoryPosition: Codable, Sendable {
    let path: String
    let depth: Int
    /// Kept so cursors queued by earlier builds still decode. A `telldir` value is only valid for
    /// the stream that returned it, so a reopened directory can't resume from it.
    var cookie: Int = 0
    /// Entries `readdir` already returned. A reopened directory resumes by skipping them.
    var entriesRead: Int? = nil
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
    /// Optional for cursors queued by earlier app builds. Paths stay inside the encrypted queue.
    var sourceReadFailures: [String: Int]? = nil
    /// An explicit retry rereads this file once, then resumes its new bounded checkpoint.
    var restartSources: [String]? = nil
    var selectedSessionID: String? = nil

    func validate() throws {
        guard kind == Self.kind, version == 1, directories.count <= 4096,
              pending.count <= 4096, deferred.count <= 4096,
              (sourceReadFailures?.count ?? 0) <= 4096,
              (restartSources?.count ?? 0) <= 1,
              restartSources == nil || (directories.isEmpty && pending.count + deferred.count <= 1),
              selectedSessionID == nil || (!selectedSessionID!.isEmpty && selectedSessionID!.utf8.count <= 4096),
              sourceReadFailures?.allSatisfy({ !$0.key.isEmpty && (1...2).contains($0.value) }) != false,
              audit.end.timeIntervalSince1970.isFinite,
              audit.start == audit.end.addingTimeInterval(-HistoricalAuditContext.lookback) else {
            throw ClaudeCollectionError.invalidConfiguration
        }
    }
}

private struct ClaudeHistoryEnvelope: Decodable { let kind: String? }

extension ClaudeAdapter: SourceHistoricalCaptureProducer {
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

    public func initialHistoricalCapture(audit: HistoricalAuditContext,
                                         source: CoverageSourceRetryDescriptor) async throws -> CapturePacket {
        guard source.scope.provider == .claudeCode, source.scope.profileID == profileID,
              source.scope.path == .versionedTranscript,
              source.session == nil || (source.session?.provider == .claudeCode && source.session?.profileID == profileID),
              let url = source.sourceURL, url.isFileURL else { throw ClaudeCollectionError.invalidConfiguration }
        let path = url.path
        _ = try transcriptURL(path: path)
        return try historyPacket(.init(kind: ClaudeHistoryRequest.kind, version: 1, audit: audit,
            directories: [], pending: [path], deferred: [], partial: false,
            restartSources: [path], selectedSessionID: source.session?.sessionID), interface: source.scope.interface)
    }

    func historyPacket(_ request: ClaudeHistoryRequest, interface: AgentInterface) throws -> CapturePacket {
        try CapturePacket(metadata: .init(agent: .claudeCode, interface: interface, profileID: profileID),
            eventJSON: JSONEncoder().encode(request))
    }

    func normalizeHistory(_ original: ClaudeHistoryRequest, interface: AgentInterface,
                          observedAt: Date, cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        let scope = CollectionScope(provider: .claudeCode, profileID: profileID, interface: interface, path: .versionedTranscript)
        func gap(_ reason: CoverageGapReason, capabilityID: UUID? = nil,
                 recovery: CoverageRecoveryReference? = nil) -> CoverageGap {
            .init(reason: reason, capabilityID: capabilityID, scope: scope, operation: .historicalRead,
                recovery: recovery, diagnosticCode: reason.defaultDiagnosticCode, observedAt: observedAt)
        }
        do { try original.validate() } catch {
            return .init(sources: [], coverageGaps: [gap(.malformedSource)])
        }
        var request = original
        let clock = ContinuousClock(), started = ContinuousClock.now
        var sources: [CollectedSource] = [], checkpoints: [SourceCheckpoint] = [], gaps: [CoverageGap] = []
        var recoveredReferences: [CoverageRecoveryReference] = []
        var bytes = 0, processed = 0, inspected = 0
        var oldest: Date?, newest: Date?
        var seen = Set<String>(), next: [String] = []
        func remainingRows() -> Int {
            CollectionBatch.maximumRecoveryEntries - max(recoveredReferences.count, gaps.count)
                - Self.recoveryEntryReserve
        }
        // Deferred sources are placed after newly discovered candidates. Each source gets one
        // bounded slice per pass; a continually growing source cannot monopolize discovery.
        while processed < historyBudget.maximumSources, bytes < historyBudget.maximumBytes,
              clock.now - started < .seconds(historyBudget.maximumDuration), remainingRows() > 0 {
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
                        maximumEntries: min(128, 4096 - inspected, remainingRows()))
                    inspected += page.inspected
                    request.pending += page.files
                    request.directories += page.directories
                    gaps += page.gaps.map { $0.contextualized(scope: scope, operation: .historicalRead, observedAt: observedAt) }
                    if !page.gaps.isEmpty { request.partial = true }
                    if let entriesRead = page.entriesRead {
                        directory.entriesRead = entriesRead; directory.cookie = 0; directory.signature = page.signature
                        request.directories.append(directory)
                    }
                } catch {
                    gaps.append(gap(.sourceUnavailable)); request.partial = true
                }
                continue
            }
            let path = request.pending.removeFirst()
            guard seen.insert(path).inserted else { continue }
            processed += 1
            let documentID = try await documentIdentity(path, cryptography: cryptography)
            let availability = CoverageRecoveryReference(itemID: Self.sourceAvailabilityItemID,
                parserContract: Self.parserContractVersion, sourceDocumentID: documentID, sourceURL: URL(fileURLWithPath: path))
            func unavailable() -> CoverageGap {
                gap(.sourceUnavailable, capabilityID: documentID, recovery: availability)
            }
            do {
                let key = try await checkpointIdentity(path: path, provenance: .historical(request.audit), cryptography: cryptography)
                let restarting = request.restartSources?.contains(path) == true
                let checkpoint = restarting ? nil : try await checkpointLookup(key)
                // A 2 MiB quantum admits the supported 1 MiB physical row while giving another
                // file an opportunity before exhausting the 100 MiB pass budget.
                let quantum = min(2 * 1024 * 1024, historyBudget.maximumBytes - bytes)
                let context = RetainedSourceContext(sessionIdentifier: "", transcriptPath: path, openingCapability: .unverified)
                let read = try await readIncremental(path: path, expectedSessionID: request.selectedSessionID, interface: interface, checkpoint: checkpoint,
                    observedAt: observedAt, provenance: .historical(request.audit), context: context,
                    maximumBytes: quantum, maximumRows: remainingRows(), cryptography: cryptography)
                request.restartSources?.removeAll { $0 == path }
                bytes += read.bytesRead; sources += read.batch.sources; checkpoints += read.batch.checkpoints
                gaps += read.batch.coverageGaps
                recoveredReferences += read.batch.recoveredReferences
                if request.sourceReadFailures?[path] != nil { recoveredReferences.append(availability) }
                if let time = read.oldestContentTime { oldest = oldest.map { min($0, time) } ?? time }
                if let time = read.newestContentTime { newest = newest.map { max($0, time) } ?? time }
                if read.canContinueHistory { next.append(path) }
                else { request.sourceReadFailures?.removeValue(forKey: path) }
                if read.hasUnreadContent && !read.canContinueHistory { request.partial = true }
                if read.batch.coverageGaps.contains(where: {
                    $0.requiresAnalysis && ($0.diagnosticCode == .oversizedRecord
                        || ![CoverageGapReason.budgetExhausted, .unresolvedCorrelation, .incompleteMessage].contains($0.reason))
                }) { request.partial = true }
            } catch ClaudeCollectionError.unsafeTranscriptPath {
                gaps.append(unavailable()); request.partial = true
                request.sourceReadFailures?.removeValue(forKey: path)
            } catch ClaudeCollectionError.awaitingTranscript {
                gaps.append(unavailable())
                let failures = (request.sourceReadFailures?[path] ?? 0) + 1
                if failures < 3 {
                    if request.sourceReadFailures == nil { request.sourceReadFailures = [:] }
                    request.sourceReadFailures?[path] = failures
                    next.append(path)
                } else {
                    request.partial = true
                    request.sourceReadFailures?.removeValue(forKey: path)
                }
            }
        }
        request.deferred += next
        let continuing = !request.directories.isEmpty || !request.pending.isEmpty || !request.deferred.isEmpty
        if continuing { gaps.append(gap(.budgetExhausted)) }
        let unread = request.partial || continuing || gaps.contains { $0.requiresAnalysis }
        return .init(sources: sources, coverageGaps: Array(Set(gaps)), checkpoints: checkpoints,
            continuation: continuing ? try historyPacket(request, interface: interface) : nil,
            historicalProgress: .init(audit: request.audit, bytesRead: bytes, oldestContentTime: oldest,
                newestContentTime: newest, hasUnreadContent: unread), recoveredReferences: recoveredReferences)
    }
}

private struct ClaudeDiscoveryPage {
    let files: [String], directories: [ClaudeDirectoryPosition], gaps: [CoverageGap]
    let entriesRead: Int?, signature: ClaudeFileSignature, inspected: Int
}

/// Enumeration is metadata-only, bounded and resumable. A reopened directory skips the entries
/// earlier pages read, which holds only while it is unchanged; a changed directory explicitly
/// marks partial coverage and the next audit starts a new traversal. No file mtime is used to
/// exclude source content.
private func claudeDiscoverPage(_ position: ClaudeDirectoryPosition, allowedRoots: [URL],
                                maximumEntries: Int) throws -> ClaudeDiscoveryPage {
    let skip = position.entriesRead ?? 0
    guard position.depth >= 0, position.depth <= 4, position.cookie >= 0, skip >= 0,
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
    for _ in 0..<skip {
        try Task.checkCancellation()
        guard readdir(stream) != nil else {
            return .init(files: [], directories: [], gaps: gaps, entriesRead: nil, signature: signature, inspected: 0)
        }
    }
    var files: [String] = [], directories: [ClaudeDirectoryPosition] = [], inspected = 0
    while inspected < maximumEntries {
        try Task.checkCancellation()
        guard let entry = readdir(stream) else {
            return .init(files: files, directories: directories, gaps: gaps, entriesRead: nil, signature: signature, inspected: inspected)
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
        entriesRead: skip + inspected, signature: signature, inspected: inspected)
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
