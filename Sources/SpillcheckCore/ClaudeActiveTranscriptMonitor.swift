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
    private struct SelectedSource {
        let source: ClaudeActiveSource
        let parent: ClaudeActiveSource?
    }

    public init(profileID: String, sources: [ClaudeActiveSource], enqueue: @escaping Enqueue,
                onGap: @escaping GapHandler = { _ in }) throws {
        guard !profileID.isEmpty else { throw ClaudeCollectionError.invalidConfiguration }
        self.profileID = profileID; self.sources = sources; self.enqueue = enqueue; self.onGap = onGap
    }

    @discardableResult public func pollOnce(at date: Date = Date()) async throws -> Int {
        let permit = generation
        var count = 0
        var failure: (any Error)?
        let selected = selectedSources()
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
    public func add(source: ClaudeActiveSource) {
        guard !sources.contains(where: { $0.transcriptURL == source.transcriptURL && $0.sessionID == source.sessionID }) else { return }
        sources.append(source)
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

    private func selectedSources() -> (sources: [SelectedSource], exhaustedSources: [ClaudeActiveSource]) {
        var result = sources.map { SelectedSource(source: $0, parent: nil) }, exhaustedSources: [ClaudeActiveSource] = []
        // Claude 2.1.293 native Agent sidechains are in the selected conversation's own
        // <session>/subagents directory, and workflow agents in its subagents/workflows/<run>
        // directories. This is bounded conversation-local discovery, not enumeration of the
        // profile's histories or T3's unrelated provider sessions.
        for parent in sources {
            let project = claudeConfiguredURL(parent.transcriptURL.deletingLastPathComponent())
            let subagents = project.appendingPathComponent(parent.transcriptURL.deletingPathExtension().lastPathComponent).appendingPathComponent("subagents")
            // Every child is listed before any is polled, so the 32 most recently written ones are
            // polled whichever folder holds them and a finished run can't crowd out a live one.
            // The rest are reported as exhausted; their modification time only orders polling.
            var candidates: [(url: URL, modified: timespec)] = [], runs: [URL] = []
            var inspected = 0, exhausted = false
            // Collects agent transcripts, or with `listingRuns` only the workflow run folders.
            func scan(_ directory: URL, listingRuns: Bool = false) {
                guard !exhausted, let fd = try? claudeOpenDirectory(directory.path) else { return }
                guard let stream = fdopendir(fd) else { close(fd); return }
                defer { closedir(stream) }
                var listed = 0
                while let entry = readdir(stream) {
                    let name = withUnsafePointer(to: &entry.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                    }
                    guard name != ".", name != ".." else { continue }
                    listed += 1; inspected += 1
                    if listed > 128 || inspected > 512 { exhausted = true; return }
                    if listingRuns {
                        guard ClaudeToolHookSelection.isSafeIdentifier(name) else { continue }
                    } else {
                        guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl"), !name.contains("/") else { continue }
                    }
                    var info = stat()
                    guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_uid == getuid(),
                          (info.st_mode & S_IFMT) == (listingRuns ? S_IFDIR : S_IFREG) else { continue }
                    if listingRuns { runs.append(directory.appendingPathComponent(name)) }
                    else { candidates.append((directory.appendingPathComponent(name), info.st_mtimespec)) }
                }
            }
            scan(subagents)
            scan(subagents.appendingPathComponent("workflows"), listingRuns: true)
            for run in runs { scan(run) }
            candidates.sort { ($0.modified.tv_sec, $0.modified.tv_nsec) > ($1.modified.tv_sec, $1.modified.tv_nsec) }
            if candidates.count > 32 { exhausted = true }
            for candidate in candidates.prefix(32) {
                if let child = try? ClaudeActiveSource(sessionID: parent.sessionID, transcriptURL: candidate.url, interface: parent.interface) {
                    result.append(.init(source: child, parent: parent))
                }
            }
            if exhausted { exhaustedSources.append(parent) }
        }
        return (result, exhaustedSources)
    }
}
