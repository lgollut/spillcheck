import Darwin
import Foundation

/// A selected active provider source, not a request to enumerate private session history.
public struct ClaudeActiveSource: Sendable {
    public let sessionID: String
    public let transcriptURL: URL
    public let interface: AgentInterface
    public init(sessionID: String, transcriptURL: URL, interface: AgentInterface = .t3) throws {
        guard !sessionID.isEmpty, transcriptURL.isFileURL, transcriptURL.path.hasPrefix("/"),
              transcriptURL.pathExtension == "jsonl", interface != .desktopCode else {
            throw ClaudeCollectionError.invalidConfiguration
        }
        self.sessionID = sessionID; self.transcriptURL = transcriptURL; self.interface = interface
    }
}

/// Lightweight polling for interfaces where hook registration has not been measured. No payload
/// reads occur here. Queue admission owns monitoring permits; the observer marks a change only after
/// the enqueue callback returns successfully. Normalization performs the bounded, safe content read.
public actor ClaudeActiveTranscriptMonitor {
    public typealias Enqueue = @Sendable (CapturePacket, Date) async throws -> Void
    public typealias GapHandler = @Sendable (CoverageGap) async -> Void
    private let profileID: String
    private var sources: [ClaudeActiveSource]
    private let enqueue: Enqueue
    private let onGap: GapHandler
    private var signatures: [String: Signature] = [:]
    private var task: Task<Void, Never>?
    private var generation: UUID = UUID()
    private struct Signature: Equatable, Sendable {
        let device: UInt64, inode: UInt64, size: Int64, modifiedSeconds: Int64, modifiedNanos: Int64
    }

    public init(profileID: String, sources: [ClaudeActiveSource], enqueue: @escaping Enqueue,
                onGap: @escaping GapHandler = { _ in }) throws {
        guard !profileID.isEmpty else { throw ClaudeCollectionError.invalidConfiguration }
        self.profileID = profileID; self.sources = sources; self.enqueue = enqueue; self.onGap = onGap
    }

    @discardableResult public func pollOnce(at date: Date = Date()) async throws -> Int {
        let permit = generation
        var count = 0
        let selected = selectedSources()
        if selected.exhausted { await onGap(.init(reason: .budgetExhausted)) }
        for source in selected.sources {
            guard permit == generation, !Task.isCancelled else { return count }
            var info = stat()
            guard lstat(source.transcriptURL.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
                await onGap(.init(reason: .sourceUnavailable)); continue
            }
            let signature = Signature(device: UInt64(info.st_dev), inode: info.st_ino, size: info.st_size,
                modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec))
            let key = source.transcriptURL.path
            guard signatures[key] != signature else { continue }
            let event: [String: String] = ["hook_event_name": "SpillcheckTranscriptPoll", "session_id": source.sessionID,
                                         "transcript_path": source.transcriptURL.path]
            let packet = try CapturePacket(metadata: .init(agent: .claudeCode, interface: source.interface, profileID: profileID),
                eventJSON: JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
            try await enqueue(packet, date)
            guard permit == generation, !Task.isCancelled else { return count }
            signatures[key] = signature; count += 1
        }
        return count
    }

    public func start(interval: Duration = .milliseconds(250)) {
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
        pending?.cancel()
        await pending?.value
    }
    public func add(source: ClaudeActiveSource) {
        guard !sources.contains(where: { $0.transcriptURL == source.transcriptURL && $0.sessionID == source.sessionID }) else { return }
        sources.append(source)
    }
    private func reportFailure() async { await onGap(.init(reason: .deliveryUncertain)) }

    private func selectedSources() -> (sources: [ClaudeActiveSource], exhausted: Bool) {
        var result = sources, exhausted = false
        // Claude 2.1.293 native Agent sidechains are in the selected conversation's own
        // <session>/subagents directory. This is bounded conversation-local discovery, not
        // enumeration of the profile's histories or T3's unrelated provider sessions.
        for parent in sources {
            let project = claudeConfiguredURL(parent.transcriptURL.deletingLastPathComponent())
            let directory = project.appendingPathComponent(parent.transcriptURL.deletingPathExtension().lastPathComponent).appendingPathComponent("subagents")
            var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if fd >= 0 {
                for part in directory.path.split(separator:"/") {
                    let next=String(part).withCString { openat(fd,$0,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC) }
                    close(fd); fd=next
                    if fd < 0 { break }
                }
            }
            guard fd >= 0 else { continue }
            guard let stream = fdopendir(fd) else { close(fd); continue }
            defer { closedir(stream) }
            var inspected = 0, children = 0
            while let entry = readdir(stream) {
                inspected += 1
                if inspected > 128 || children >= 32 { exhausted = true; break }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl"), !name.contains("/") else { continue }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { continue }
                if let child = try? ClaudeActiveSource(sessionID: parent.sessionID,
                    transcriptURL: directory.appendingPathComponent(name), interface: parent.interface) {
                    result.append(child); children += 1
                }
            }
        }
        return (result, exhausted)
    }
}
