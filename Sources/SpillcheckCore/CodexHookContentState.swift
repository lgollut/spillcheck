import Foundation

/// A hook slot binds one source identity to the first admitted content revision.
/// Replays preserve that observation time; a changed revision cannot replace it.
public enum CodexHookContentBinding: Equatable, Sendable {
    case accepted(firstObservedAt: Date)
    case conflict
}

/// Contains no source text. The keyed revision, identity and observation time are
/// all encrypted in the store. Slots outlive queue expiry and value removal so
/// replaying an old hook cannot manufacture a new observation. Only deleting or
/// resetting the entire vault removes these bindings.
struct StoredCodexHookContent: Codable, Sendable {
    static let authorityID = "codex-hook-content-v1"
    let source: SourceIdentity
    let revision: ContentRevision
    let firstObservedAt: Date

    static func validSource(_ source: SourceIdentity) -> Bool {
        let session = source.session
        return session.provider == .codex
            && validIdentifier(session.profileID, maximumBytes: 256)
            && validIdentifier(session.sessionID, maximumBytes: 4096)
            && validIdentifier(source.itemID, maximumBytes: 4096)
            && source.itemID.hasPrefix("codex-hook-v1:") && source.itemID.utf8.count > "codex-hook-v1:".utf8.count
    }

    private static func validIdentifier(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes && !value.utf8.contains(0)
    }
}
