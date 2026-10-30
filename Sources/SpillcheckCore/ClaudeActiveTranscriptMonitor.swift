import Darwin
import Foundation

/// A selected active provider source, not a request to enumerate private session history.
public struct ClaudeActiveSource: Sendable {
    public let sessionID: String
    public let transcriptURL: URL
    public let interface: AgentInterface
    public init(sessionID: String, transcriptURL: URL, interface: AgentInterface = .t3) throws {
        guard !sessionID.isEmpty, transcriptURL.isFileURL, transcriptURL.path.hasPrefix("/"),
              transcriptURL.pathExtension == "jsonl" else {
            throw ClaudeCollectionError.invalidConfiguration
        }
        self.sessionID = sessionID; self.transcriptURL = transcriptURL; self.interface = interface
    }
}

/// Lightweight polling for interfaces where hook registration has not been measured. No payload
/// reads occur here. Queue admission owns monitoring permits; the observer marks a change only after
/// the enqueue callback returns successfully. Normalization performs the bounded, safe content read.
/// A selected conversation is checked on every pass while it changes, and less often as it stays
/// unchanged; selecting it again, as each hook for its session does, makes it current again. It is
/// never dropped, because a conversation without hooks has only this monitor.
public actor ClaudeActiveTranscriptMonitor {
    public typealias Enqueue = @Sendable (CapturePacket, Date) async throws -> Void
    public typealias GapHandler = @Sendable (CoverageGap) async -> Void
    private let profileID: String
    private var sources: [ClaudeActiveSource]
    private let enqueue: Enqueue
    private let onGap: GapHandler
    private var signatures: [String: Signature] = [:]
    /// Keyed by the selected conversation's transcript path; its native children count toward it.
    private var lastChange: [String: Date] = [:]
    private var nextCheck: [String: Date] = [:]
    private var task: Task<Void, Never>?
    private var generation: UUID = UUID()
    private struct Signature: Equatable, Sendable {
        let device: UInt64, inode: UInt64, size: Int64, modifiedSeconds: Int64, modifiedNanos: Int64
    }
    private struct SelectedSource {
        let source: ClaudeActiveSource
        let parent: ClaudeActiveSource?
    }

    public init(profileID: String, sources: [ClaudeActiveSource], enqueue: @escaping Enqueue,
                onGap: @escaping GapHandler = { _ in }) throws {
        guard !profileID.isEmpty else { throw ClaudeCollectionError.invalidConfiguration }
        self.profileID = profileID; self.sources = sources; self.enqueue = enqueue; self.onGap = onGap
        let now = Date()
        for source in sources { lastChange[source.transcriptURL.path] = now }
    }

    /// Seconds between checks of a conversation unchanged for `idle` seconds.
    public static func checkDelay(idle: TimeInterval) -> TimeInterval {
        switch idle {
        case ..<120: 0
        case ..<600: 2
        case ..<3600: 10
        default: 30
        }
    }

    @discardableResult public func pollOnce(at date: Date = Date()) async throws -> Int {
        let permit = generation
        var count = 0
        var failure: (any Error)?
        let due = sources.filter { (nextCheck[$0.transcriptURL.path] ?? .distantPast) <= date }
        var changed: Set<String> = []
        let selected = selectedSources(of: due)
        for source in selected.exhaustedSources {
            await onGap(gap(.budgetExhausted, source: source, at: date))
        }
        for selection in selected.sources {
            let source = selection.source
            guard permit == generation, !Task.isCancelled else { return count }
            let key = source.transcriptURL.path
            var info = stat()
            guard lstat(source.transcriptURL.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
                // The original inode/mtime can return unchanged after a temporary absence.
                // It must be read again before its availability warning can be settled.
                signatures.removeValue(forKey: key)
                await onGap(gap(.sourceUnavailable, source: source, parent: selection.parent, at: date)); continue
            }
            let signature = Signature(device: UInt64(info.st_dev), inode: info.st_ino, size: info.st_size,
                modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec))
            guard signatures[key] != signature else { continue }
            changed.insert((selection.parent ?? source).transcriptURL.path)
            var event: [String: String] = ["hook_event_name": "SpillcheckTranscriptPoll", "session_id": source.sessionID,
                                          "transcript_path": source.transcriptURL.path]
            if let parent = selection.parent {
                // A native child may share its parent's session ID or have its own. The poll
                // identifies the selected parent and child file; normalization reads the child's ID.
                event["transcript_path"] = parent.transcriptURL.path
                event["agent_transcript_path"] = source.transcriptURL.path
            }
            do {
                let packet = try CapturePacket(metadata: .init(agent: .claudeCode, interface: source.interface, profileID: profileID),
                    eventJSON: JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
                try await enqueue(packet, date)
            } catch {
                // Report and skip this source so it cannot hold back the rest of the pass.
                if !Task.isCancelled { await onGap(gap(.deliveryUncertain, source: source, parent: selection.parent, at: date)) }
                failure = failure ?? error
                continue
            }
            guard permit == generation, !Task.isCancelled else { return count }
            signatures[key] = signature; count += 1
        }
        for parent in due {
            let key = parent.transcriptURL.path
            if changed.contains(key) { lastChange[key] = date }
            nextCheck[key] = date.addingTimeInterval(Self.checkDelay(idle: date.timeIntervalSince(lastChange[key] ?? date)))
        }
        if let failure { throw failure }
        return count
    }

    public func start(interval: Duration = .milliseconds(250)) {
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
        pending?.cancel()
        await pending?.value
    }
    public func add(source: ClaudeActiveSource, at date: Date = Date()) {
        if !sources.contains(where: { $0.transcriptURL == source.transcriptURL && $0.sessionID == source.sessionID }) {
            sources.append(source)
        }
        let key = source.transcriptURL.path
        lastChange[key] = max(lastChange[key] ?? date, date)
        nextCheck[key] = date
    }
    private func gap(_ reason: CoverageGapReason, source: ClaudeActiveSource,
                     parent: ClaudeActiveSource? = nil, at date: Date) -> CoverageGap {
        // A discovered child has no verified native identity. Storage accepts its URL-only
        // reference only as an availability warning; other child losses stay scoped warnings
        // without a guessed recovery identity.
        let recovery: CoverageRecoveryReference? = parent != nil && reason != .sourceUnavailable ? nil
            : .init(session: parent == nil ? try? .init(provider: .claudeCode, profileID: profileID, sessionID: source.sessionID) : nil,
                parserContract: ClaudeAdapter.parserContractVersion, sourceURL: source.transcriptURL)
        return .init(reason: reason,
            scope: .init(provider: .claudeCode, profileID: profileID, interface: source.interface, path: .versionedTranscript),
            operation: .liveRead, recovery: recovery,
            diagnosticCode: reason.defaultDiagnosticCode, observedAt: date)
    }

    private func selectedSources(of due: [ClaudeActiveSource]) -> (sources: [SelectedSource], exhaustedSources: [ClaudeActiveSource]) {
        var result = due.map { SelectedSource(source: $0, parent: nil) }, exhaustedSources: [ClaudeActiveSource] = []
        // Claude 2.1.293 native Agent sidechains are in the selected conversation's own
        // <session>/subagents directory. This is bounded conversation-local discovery, not
        // enumeration of the profile's histories or T3's unrelated provider sessions.
        for parent in due {
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
                if inspected > 128 || children >= 32 { exhaustedSources.append(parent); break }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl"), !name.contains("/") else { continue }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { continue }
                if let child = try? ClaudeActiveSource(sessionID: parent.sessionID,
                    transcriptURL: directory.appendingPathComponent(name), interface: parent.interface) {
                    result.append(.init(source: child, parent: parent)); children += 1
                }
            }
        }
        return (result, exhaustedSources)
    }
}
