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
        // Workflow agents write one run folder lower: subagents/workflows/<run>/agent-<id>.jsonl.
        let declared = URL(fileURLWithPath: declaredChildPath), run = declared.deletingLastPathComponent()
        guard declared.lastPathComponent == "agent-\(agentID).jsonl",
              run.deletingLastPathComponent().path == subagents.appendingPathComponent("workflows").path,
              isSafeIdentifier(run.lastPathComponent) else {
            throw ClaudeCollectionError.unsafeTranscriptPath
        }
        return declaredChildPath
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
