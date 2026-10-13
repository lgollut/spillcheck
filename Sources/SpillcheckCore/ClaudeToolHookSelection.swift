import Foundation

/// Hook hints select one native child; they never grant access outside the reader's roots.
enum ClaudeToolHookSelection {
    static let toolEvents: Set<String> = ["PostToolUse", "PostToolUseFailure", "PostToolBatch"]
    static let pollEvents: Set<String> = ["SpillcheckTranscriptPoll", "LeakretTranscriptPoll"]

    static func childPath(parentPath: String, agentID: String, declaredChildPath: String? = nil) throws -> String {
        guard parentPath.hasPrefix("/"), parentPath.utf8.count <= 4096,
              !parentPath.utf8.contains(0),
              (1...128).contains(agentID.utf8.count),
              agentID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw ClaudeCollectionError.unsafeTranscriptPath
        }
        let parent = URL(fileURLWithPath: parentPath)
        guard parent.pathExtension == "jsonl" else { throw ClaudeCollectionError.unsafeTranscriptPath }
        let child = parent.deletingPathExtension().appendingPathComponent("subagents")
            .appendingPathComponent("agent-\(agentID).jsonl").path
        guard declaredChildPath == nil || declaredChildPath == child else {
            throw ClaudeCollectionError.unsafeTranscriptPath
        }
        return child
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
