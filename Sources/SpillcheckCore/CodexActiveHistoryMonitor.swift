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
              interface != .desktopCode, authority != .t3VersionedTranscript || interface == .t3,
              authority != .t3VersionedTranscript || (transcriptURL?.isFileURL == true
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
/// Public polling follows activity: each hook or collected item marks its thread active, polls
/// slow down as the thread goes quiet, and stop after an hour until the next hook. Every hook
/// capture still reads its thread directly, so pausing an idle poll loses no content.
public actor CodexActiveHistoryMonitor {
    public typealias Enqueue = @Sendable (CapturePacket, Date) async throws -> Void
    public typealias GapHandler = @Sendable (CoverageGap) async -> Void
    private let profileID: String
    private var sources: [CodexActiveSource]
    private let enqueue: Enqueue
    private let onGap: GapHandler
    private let historyClient: CodexAppServerHistoryClient?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var signatures: [String: Signature] = [:]
    private var lastActivity: [String: Date] = [:]
    private var nextPoll: [String: Date] = [:]
    private var nextIndex = 0
    private struct Signature: Equatable {
        let device: UInt64, inode: UInt64, size: Int64, modifiedSeconds: Int64, modifiedNanos: Int64
    }
    public init(profileID: String, sources: [CodexActiveSource],
                historyClient: CodexAppServerHistoryClient? = nil, enqueue: @escaping Enqueue,
                onGap: @escaping GapHandler = { _ in }) throws {
        guard !profileID.isEmpty, profileID.utf8.count <= 256, sources.count <= 256 else { throw CodexCollectionError.invalidConfiguration }
        self.profileID = profileID; self.sources = sources; self.historyClient = historyClient
        self.enqueue = enqueue; self.onGap = onGap
        let now = Date()
        for source in sources { lastActivity[source.threadID] = now }
    }

    /// Delay before the next public poll of a thread idle for `idle` seconds; nil while dormant.
    public static func publicPollDelay(idle: TimeInterval) -> TimeInterval? {
        switch idle {
        case ..<120: 1
        case ..<600: 5
        case ..<3600: 30
        default: nil
        }
    }

    /// Selecting a source also records activity for it. At capacity, the least recently active
    /// source is replaced; its thread is still read by any later hook capture.
    public func addSource(_ source: CodexActiveSource, at date: Date = Date()) throws {
        if let previous = sources.first(where: { $0.threadID == source.threadID }) {
            guard previous == source else { throw CodexCollectionError.authorityConflict }
        } else {
            if sources.count >= 256, let stalest = sources.indices.min(by: {
                (lastActivity[sources[$0].threadID] ?? .distantPast) < (lastActivity[sources[$1].threadID] ?? .distantPast)
            }) {
                let removed = sources.remove(at: stalest)
                lastActivity.removeValue(forKey: removed.threadID); nextPoll.removeValue(forKey: removed.threadID)
                if let url = removed.transcriptURL { signatures.removeValue(forKey: url.path) }
                if nextIndex > stalest { nextIndex -= 1 }
            }
            sources.append(source)
        }
        lastActivity[source.threadID] = date
        nextPoll[source.threadID] = date
    }
    @discardableResult public func pollOnce(at date: Date = Date()) async throws -> Int {
        let permit = generation
        guard !sources.isEmpty else { return 0 }
        var count = 0, selected = 0, inspected = 0
        // At most 32 due sources per pass; rotate fairly through the configured set.
        while inspected < sources.count, selected < 32 {
            guard permit == generation, !Task.isCancelled else { return count }
            let source = sources[(nextIndex + inspected) % sources.count]
            inspected += 1
            var delay: TimeInterval?
            if source.authority == .publicNativeItems {
                delay = Self.publicPollDelay(idle: date.timeIntervalSince(lastActivity[source.threadID] ?? date))
                guard delay != nil, (nextPoll[source.threadID] ?? .distantPast) <= date else { continue }
            }
            selected += 1
            var event: [String: String] = ["hook_event_name": "SpillcheckHistoryPoll", "session_id": source.threadID]
            var signature: Signature?
            if source.authority == .t3VersionedTranscript, let url = source.transcriptURL {
                var info = stat()
                guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
                    await onGap(.init(reason: .sourceUnavailable)); continue
                }
                let current = Signature(device: UInt64(info.st_dev), inode: info.st_ino, size: info.st_size,
                    modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec))
                guard signatures[url.path] != current else { continue }
                signature = current; event["transcript_path"] = url.path
            }
            let packet = try CapturePacket(metadata: .init(agent: .codex, interface: source.interface, profileID: profileID),
                eventJSON: JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
            try await enqueue(packet, date)
            guard permit == generation, !Task.isCancelled else { return count }
            if let url = source.transcriptURL, let signature { signatures[url.path] = signature }
            if let delay { nextPoll[source.threadID] = date.addingTimeInterval(delay) }
            count += 1
        }
        if !sources.isEmpty { nextIndex = (nextIndex + inspected) % sources.count }
        return count
    }
    public func start(interval: Duration = .seconds(1)) {
        guard task == nil else { return }
        generation = UUID()
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { _ = try await self?.pollOnce() }
                catch { if !Task.isCancelled { await self?.reportFailure() } }
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
    private func reportFailure() async { await onGap(.init(reason: .deliveryUncertain)) }
}
