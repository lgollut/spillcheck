import Darwin
import Foundation

public struct CodexActiveSource: Sendable, Equatable {
    public let threadID: String
    public let interface: AgentInterface
    public let authority: CodexCollectionAuthority
    public let transcriptURL: URL?
    public init(threadID: String, interface: AgentInterface,
                authority: CodexCollectionAuthority, transcriptURL: URL? = nil) throws {
        guard !threadID.isEmpty, threadID.utf8.count <= 4096, !threadID.utf8.contains(0),
              authority != .nativeRolloutTranscript || interface == .t3,
              authority != .nativeRolloutTranscript || (transcriptURL?.isFileURL == true
                && transcriptURL?.path.hasPrefix("/") == true && transcriptURL?.pathExtension == "jsonl") else {
            throw CodexCollectionError.invalidConfiguration
        }
        self.threadID = threadID; self.interface = interface; self.authority = authority
        self.transcriptURL = transcriptURL.map(codexConfiguredURL)
    }
}

/// Only exact configured/admitted active sources. Public polling rereads the bounded tail so
/// same-second metadata changes cannot hide hosted-tool or intermediate-message output.
/// Versioned transcript polling performs stat only and reads zero unchanged payload bytes.
/// Public polling follows activity: a hook marks its thread active when it arrives and a collected
/// item as of its own time. Polls slow down as the thread goes quiet, and stop after an hour until
/// the next hook. Every hook capture still reads its thread directly, so pausing an idle poll loses
/// no content.
public actor CodexActiveHistoryMonitor {
    public typealias Enqueue = @Sendable (CapturePacket, Date) async throws -> Void
    public typealias GapHandler = @Sendable (CoverageGap) async -> Void
    private let profileID: String
    private var sources: [CodexActiveSource]
    private let enqueue: Enqueue
    private let onGap: GapHandler
    private let historyClient: CodexAppServerHistoryClient?
    private let authorityLookup: SourceAuthorityLookup?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var signatures: [String: Signature] = [:]
    private var lastActivity: [String: Date] = [:]
    private var nextPoll: [String: Date] = [:]
    /// Consecutive failed polls per selected thread; absent when the last poll succeeded.
    private var pollFailures: [String: PollFailures] = [:]
    /// One gap per continuous capacity failure. Bounded by the configured source set.
    private var capacityFailureReported: Set<String> = []
    private var nextIndex = 0
    private struct PollFailures {
        var count: Int
        /// The newest poll counted, so the pipeline's retries of one poll count once.
        var latestPoll: Date
    }
    private struct Signature: Equatable {
        let device: UInt64, inode: UInt64, size: Int64, modifiedSeconds: Int64, modifiedNanos: Int64
    }
    public init(profileID: String, sources: [CodexActiveSource],
                historyClient: CodexAppServerHistoryClient? = nil, enqueue: @escaping Enqueue,
                authorityLookup: SourceAuthorityLookup? = nil,
                onGap: @escaping GapHandler = { _ in }) throws {
        guard !profileID.isEmpty, profileID.utf8.count <= 256, sources.count <= 256 else { throw CodexCollectionError.invalidConfiguration }
        self.profileID = profileID; self.sources = sources; self.historyClient = historyClient
        self.authorityLookup = authorityLookup
        self.enqueue = enqueue; self.onGap = onGap
        let now = Date()
        for source in sources { lastActivity[source.threadID] = now }
    }

    /// Delay before the next public poll of a thread idle for `idle` seconds; nil while dormant.
    /// Each consecutive failed poll doubles it, up to an hour.
    public static func publicPollDelay(idle: TimeInterval, failures: Int = 0) -> TimeInterval? {
        let base: TimeInterval
        switch idle {
        case ..<120: base = 1
        case ..<600: base = 5
        case ..<3600: base = 30
        default: return nil
        }
        return min(base * pow(2, Double(min(failures, 16))), 3600)
    }

    /// Selecting a source also records activity for it. At capacity, the least recently active
    /// source is replaced; its thread is still read by any later hook capture.
    public func addSource(_ source: CodexActiveSource, at date: Date = Date()) async throws {
        try await admit(source, activeAt: date, at: date)
        // A hook proves the thread exists, so earlier failed polls no longer count against it.
        pollFailures.removeValue(forKey: source.threadID)
    }

    /// A thread whose polls keep failing, such as one deleted from its app, is polled less often
    /// rather than failing at the activity cadence. The poll's outcome is known only after the
    /// detection worker has processed it, so this also pushes back a poll already scheduled.
    /// The pipeline retries a failed poll and each attempt reports, so a poll counts once, by the
    /// time it was made (`polledAt`).
    public func recordPollFailure(thread: String, polledAt: Date, at date: Date = Date()) {
        guard let source = sources.first(where: { $0.threadID == thread }), source.authority == .publicNativeItems,
              polledAt > pollFailures[thread]?.latestPoll ?? .distantPast else { return }
        pollFailures[thread] = .init(count: (pollFailures[thread]?.count ?? 0) + 1, latestPoll: polledAt)
        reschedule(thread, from: date)
    }

    public func recordPollSuccess(thread: String, at date: Date = Date()) {
        guard pollFailures.removeValue(forKey: thread) != nil, let next = pollDelay(thread, at: date) else { return }
        nextPoll[thread] = date.addingTimeInterval(next)
    }

    private func pollDelay(_ thread: String, at date: Date) -> TimeInterval? {
        Self.publicPollDelay(idle: date.timeIntervalSince(lastActivity[thread] ?? date), failures: pollFailures[thread]?.count ?? 0)
    }

    /// Never earlier than a poll already pushed back, which can happen while a poll is being queued.
    private func reschedule(_ thread: String, from date: Date) {
        guard let next = pollDelay(thread, at: date) else { return }
        nextPoll[thread] = max(nextPoll[thread] ?? date, date.addingTimeInterval(next))
    }

    /// Live items count as activity as of their own time, not when they were read. A poll rereads
    /// its thread's tail, and a poll queued before a restart can be read much later, so neither
    /// can keep a quiet thread at the fastest cadence.
    public func observe(_ batch: CollectionBatch, authority: CodexCollectionAuthority, at date: Date = Date()) async {
        var observed: [String: (source: CodexActiveSource, newest: Date)] = [:]
        for collected in batch.sources {
            let metadata = collected.record.metadata
            guard case .live = metadata.origin.provenance else { continue }
            let thread = metadata.identity.session.sessionID
            if let known = observed[thread] {
                observed[thread] = (known.source, max(known.newest, metadata.contentTime))
            } else if let source = try? CodexActiveSource(threadID: thread, interface: metadata.origin.interface,
                authority: authority, transcriptURL: collected.context?.transcriptPath.map { URL(fileURLWithPath: $0) }) {
                observed[thread] = (source, metadata.contentTime)
            }
        }
        for (source, newest) in observed.values { try? await admit(source, activeAt: min(newest, date), at: date) }
    }

    /// Activity no newer than a thread's last leaves its cadence alone.
    private func admit(_ source: CodexActiveSource, activeAt activity: Date, at date: Date) async throws {
        // An unknown owner keeps the source; each poll rechecks ownership and reports a failure.
        if (try? await isHookOwned(source)) == true { return }
        if let previous = sources.first(where: { $0.threadID == source.threadID }) {
            guard previous.authority == source.authority, previous.transcriptURL == source.transcriptURL else {
                throw CodexCollectionError.authorityConflict
            }
            guard activity > lastActivity[source.threadID] ?? .distantPast else { return }
        } else {
            if sources.count >= 256, let stalest = sources.indices.min(by: {
                (lastActivity[sources[$0].threadID] ?? .distantPast) < (lastActivity[sources[$1].threadID] ?? .distantPast)
            }) {
                guard activity > lastActivity[sources[stalest].threadID] ?? .distantPast else { return }
                let removed = sources.remove(at: stalest)
                lastActivity.removeValue(forKey: removed.threadID); nextPoll.removeValue(forKey: removed.threadID)
                pollFailures.removeValue(forKey: removed.threadID)
                capacityFailureReported.remove(removed.threadID)
                if let url = removed.transcriptURL { signatures.removeValue(forKey: url.path) }
                if nextIndex > stalest { nextIndex -= 1 }
            }
            sources.append(source)
        }
        lastActivity[source.threadID] = activity
        nextPoll[source.threadID] = date
    }
    @discardableResult public func pollOnce(at date: Date = Date()) async throws -> Int {
        let permit = generation
        guard !sources.isEmpty else { return 0 }
        var count = 0, selected = 0, inspected = 0
        var failure: (any Error)?
        // At most 32 due sources per pass; rotate fairly through the configured set. A failing
        // source is reported and skipped so it cannot starve the sources after it.
        while inspected < sources.count, selected < 32 {
            guard permit == generation, !Task.isCancelled else { return count }
            let source = sources[(nextIndex + inspected) % sources.count]
            inspected += 1
            do { if try await isHookOwned(source) { continue } }
            catch {
                if !Task.isCancelled { await onGap(gap(.deliveryUncertain, source: source, at: date)) }
                failure = failure ?? error
                continue
            }
            guard permit == generation, !Task.isCancelled else { return count }
            var delay: TimeInterval?
            if source.authority == .publicNativeItems {
                delay = pollDelay(source.threadID, at: date)
                guard delay != nil, (nextPoll[source.threadID] ?? .distantPast) <= date else { continue }
            }
            selected += 1
            var event: [String: String] = ["hook_event_name": "SpillcheckHistoryPoll", "session_id": source.threadID]
            var signature: Signature?
            if source.authority == .nativeRolloutTranscript, let url = source.transcriptURL {
                var info = stat()
                guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
                    await onGap(gap(.sourceUnavailable, source: source, at: date)); continue
                }
                let current = Signature(device: UInt64(info.st_dev), inode: info.st_ino, size: info.st_size,
                    modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec))
                guard signatures[url.path] != current else { continue }
                signature = current; event["transcript_path"] = url.path
            }
            do {
                let packet = try CapturePacket(metadata: .init(agent: .codex, interface: source.interface, profileID: profileID),
                    eventJSON: JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
                try await enqueue(packet, date)
            }
            catch CodexEnrolledRoutingError.hookOwnedPoll { continue }
            catch StorageError.capacityExceeded(.sourceAuthorities) {
                if permit == generation, !Task.isCancelled, capacityFailureReported.insert(source.threadID).inserted {
                    await onGap(gap(.budgetExhausted, source: source, at: date, diagnostic: .authorityStorageLimit))
                }
                if delay != nil { reschedule(source.threadID, from: date) }
                continue
            }
            catch {
                if !Task.isCancelled { await onGap(gap(.deliveryUncertain, source: source, at: date)) }
                failure = failure ?? error
                continue
            }
            guard permit == generation, !Task.isCancelled else { return count }
            capacityFailureReported.remove(source.threadID)
            if let url = source.transcriptURL, let signature { signatures[url.path] = signature }
            // The enqueue awaited, so a failure may have been recorded since the delay was chosen.
            if delay != nil { reschedule(source.threadID, from: date) }
            count += 1
        }
        if !sources.isEmpty { nextIndex = (nextIndex + inspected) % sources.count }
        if let failure { throw failure }
        return count
    }
    public func start(interval: Duration = .seconds(1)) {
        guard task == nil else { return }
        generation = UUID()
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { _ = try await self?.pollOnce() }
                catch { /* pollOnce reports the exact failed source before propagating. */ }
                do { try await Task.sleep(for: interval) } catch { break }
            }
        }
    }
    public func stop() async {
        generation = UUID()
        let pending = task; task = nil
        pending?.cancel(); await pending?.value
        await historyClient?.close()
    }
    private func isHookOwned(_ source: CodexActiveSource) async throws -> Bool {
        guard let authorityLookup else { return false }
        let session = try SessionIdentity(provider: .codex, profileID: profileID, sessionID: source.threadID)
        guard let choice = try await authorityLookup(session) else { return false }
        guard choice.session == session else { throw CodexCollectionError.authorityConflict }
        return choice.authorityID == CodexHookContentAdapter.authorityID
    }
    private func gap(_ reason: CoverageGapReason, source: CodexActiveSource, at date: Date,
                     diagnostic: CoverageDiagnosticCode? = nil) -> CoverageGap {
        .init(reason: reason,
            scope: .init(provider: .codex, profileID: profileID, interface: source.interface, path: source.authority.collectionPath),
            operation: .liveRead,
            recovery: .init(session: try? .init(provider: .codex, profileID: profileID, sessionID: source.threadID),
                parserContract: CodexAdapter.parserContract, sourceURL: source.transcriptURL),
            diagnosticCode: diagnostic ?? reason.defaultDiagnosticCode, observedAt: date)
    }
}
