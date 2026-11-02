import Foundation

/// Hook hints select one native child; they never grant access outside the reader's roots.
enum ClaudeToolHookSelection {
    static let toolEvents: Set<String> = ["PostToolUse", "PostToolUseFailure", "PostToolBatch"]
    static let pollEvents: Set<String> = ["SpillcheckTranscriptPoll", "LeakretTranscriptPoll"]

    static func childPath(parentPath: String, agentID: String, declaredChildPath: String? = nil) throws -> String {
        guard parentPath.hasPrefix("/"), parentPath.utf8.count <= 4096,
              !parentPath.utf8.contains(0), isSafeIdentifier(agentID) else {
            throw ClaudeCollectionError.unsafeTranscriptPath
        }
        let parent = URL(fileURLWithPath: parentPath)
        guard parent.pathExtension == "jsonl" else { throw ClaudeCollectionError.unsafeTranscriptPath }
        let subagents = parent.deletingPathExtension().appendingPathComponent("subagents")
        let child = subagents.appendingPathComponent("agent-\(agentID).jsonl").path
        guard let declaredChildPath, declaredChildPath != child else { return child }
        // Workflow agents write two folders lower: subagents/workflows/<run>/agent-<id>.jsonl. Only
        // that exact spelling is accepted, so each child keeps a single checkpoint identity.
        let run = URL(fileURLWithPath: declaredChildPath).deletingLastPathComponent().lastPathComponent
        let workflowChild = subagents.appendingPathComponent("workflows").appendingPathComponent(run)
            .appendingPathComponent("agent-\(agentID).jsonl").path
        guard isSafeIdentifier(run), declaredChildPath == workflowChild else {
            throw ClaudeCollectionError.unsafeTranscriptPath
        }
        return workflowChild
    }

    /// Tool hooks name their child by agent ID only, and a workflow agent's hooks name no run.
    /// Its transcript is subagents/workflows/<run>/agent-<id>.jsonl, so while the flat
    /// subagents/agent-<id>.jsonl is absent the one run folder holding that agent is selected.
    /// Folders are listed only below `confinedParent`, the reader's root-checked location of
    /// `parentPath`; without it nothing is listed. No match, several, or more than 128 entries
    /// (the monitor's folder bound) keep the flat path.
    static func toolHookChildPath(parentPath: String, agentID: String, declaredChildPath: String?,
                                  confinedParent: URL?) throws -> String {
        let flat = try childPath(parentPath: parentPath, agentID: agentID, declaredChildPath: declaredChildPath)
        guard declaredChildPath == nil, let confinedParent else { return flat }
        let name = "agent-\(agentID).jsonl"
        let subagents = confinedParent.deletingPathExtension().appendingPathComponent("subagents")
        guard let fd = try? claudeOpenDirectory(subagents.path) else { return flat }
        defer { close(fd) }
        guard !ownedEntry(name, in: fd, type: S_IFREG), let run = workflowRun(holding: name, in: fd) else { return flat }
        let declared = URL(fileURLWithPath: parentPath).deletingPathExtension().appendingPathComponent("subagents")
            .appendingPathComponent("workflows").appendingPathComponent(run).appendingPathComponent(name).path
        return try childPath(parentPath: parentPath, agentID: agentID, declaredChildPath: declared)
    }

    private static func workflowRun(holding name: String, in subagents: Int32) -> String? {
        let workflows = openat(subagents, "workflows", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard workflows >= 0 else { return nil }
        guard let stream = fdopendir(workflows) else { close(workflows); return nil }
        defer { closedir(stream) }
        var holding: [String] = [], listed = 0
        while let entry = readdir(stream) {
            let run = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard run != ".", run != ".." else { continue }
            listed += 1
            if listed > 128 { return nil }
            guard isSafeIdentifier(run), ownedEntry(run, in: workflows, type: S_IFDIR) else { continue }
            let folder = openat(workflows, run, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard folder >= 0 else { continue }
            if ownedEntry(name, in: folder, type: S_IFREG) { holding.append(run) }
            close(folder)
        }
        return holding.count == 1 ? holding[0] : nil
    }

    private static func ownedEntry(_ name: String, in directory: Int32, type: mode_t) -> Bool {
        var info = stat()
        return fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_uid == getuid()
            && (info.st_mode & S_IFMT) == type
    }

    static func isSafeIdentifier(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
            || (97...122).contains($0) || $0 == 45 || $0 == 95 })
    }

    static func selectedPollChildPath(parentPath: String, declaredChildPath: String) throws -> String {
        guard declaredChildPath.hasPrefix("/") else { throw ClaudeCollectionError.unsafeTranscriptPath }
        let child = URL(fileURLWithPath: declaredChildPath)
        let name = child.deletingPathExtension().lastPathComponent
        guard child.pathExtension == "jsonl", name.hasPrefix("agent-") else {
            throw ClaudeCollectionError.unsafeTranscriptPath
        }
        return try childPath(parentPath: parentPath, agentID: String(name.dropFirst("agent-".count)),
            declaredChildPath: declaredChildPath)
    }
}
