import Foundation

public enum CodexEnrolledRoutingError: Error, Sendable {
    /// A stale native poll must not turn into a hook event or a delivery failure.
    case hookOwnedPoll
}

/// Admission fixes the representation before the encrypted capture is queued.
/// Only an existing exact hook authority selects hooks; a valid unknown session
/// selects the configured native authority, including on its first SessionStart.
/// Neither missing history nor a different session identifier enrolls a side chat.
public struct CodexEnrolledSessionRouter: CaptureNormalizer, Sendable {
    private let native: any CaptureNormalizer
    private let hooks: any CaptureNormalizer
    private var nativeRoute: CollectionCaptureRoute
    private let nativeAuthority: CodexCollectionAuthority
    private let authorityLookup: SourceAuthorityLookup

    public init(native: any CaptureNormalizer, hooks: any CaptureNormalizer,
                nativeRoute: CollectionCaptureRoute, nativeAuthority: CodexCollectionAuthority,
                authorityLookup: @escaping SourceAuthorityLookup) throws {
        guard nativeRoute.scope.provider == .codex,
              nativeRoute.scope.path == nativeAuthority.collectionPath else {
            throw CodexCollectionError.invalidConfiguration
        }
        self.native = native; self.hooks = hooks; self.nativeRoute = nativeRoute
        self.nativeAuthority = nativeAuthority; self.authorityLookup = authorityLookup
    }

    /// Refresh future admissions without replacing authority, adapters, or queued work.
    public func updatingReaderVersion(_ version: String?) -> Self {
        var updated = self
        updated.nativeRoute = .init(scope: nativeRoute.scope, readerVersion: version,
            hostVersion: nativeRoute.hostVersion)
        return updated
    }

    public func context(for packet: CapturePacket, trigger: CollectionWorkTrigger,
                        audit: HistoricalAuditContext? = nil,
                        recordAuthority: SourceAuthorityRecorder) async throws -> CollectionWorkContext {
        try validate(packet)
        guard audit == nil, let selected = try selectedSession(in: packet) else {
            return try nativeRoute.context(for: packet, trigger: trigger, audit: audit)
        }
        var choice = try await authorityLookup(selected.session)
        if choice == nil {
            let desired = try CollectionAuthorityChoice(session: selected.session,
                adapterVersion: CodexAdapter.adapterVersion, authorityID: nativeAuthority.rawValue)
            do { try await recordAuthority(desired) }
            catch StorageError.invalidPayload { /* Another immutable selector may have won. */ }
            catch CodexCollectionError.authorityConflict { /* Re-read only the committed winner. */ }
            choice = try await authorityLookup(selected.session)
        }
        guard let choice else { throw CodexCollectionError.missingAuthority }
        let hookOwned = try isHookChoice(choice, session: selected.session)
        if hookOwned && selected.isPoll { throw CodexEnrolledRoutingError.hookOwnedPoll }
        let route = hookOwned ? hookRoute : nativeRoute
        return try route.context(for: packet, trigger: trigger, audit: audit)
    }

    public func normalize(_ packet: CapturePacket, capturedAt: Date,
                          cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        try await normalize(packet, capturedAt: capturedAt, context: nil, cryptography: cryptography)
    }

    public func normalize(_ packet: CapturePacket, capturedAt: Date, context: CollectionWorkContext?,
                          cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        try validate(packet)
        if let selected = try selectedSession(in: packet),
           let choice = try await authorityLookup(selected.session),
           try isHookChoice(choice, session: selected.session) {
            // An older queued native capture cannot change representation merely
            // because this session was enrolled after its admission.
            guard context?.scope == hookRoute.scope, context?.audit == nil else {
                throw CodexCollectionError.authorityConflict
            }
            guard !selected.isPoll else { throw CodexEnrolledRoutingError.hookOwnedPoll }
            return try await hooks.normalize(packet, capturedAt: capturedAt, context: context, cryptography: cryptography)
        }
        guard context == nil || context?.scope == nativeRoute.scope else { throw CodexCollectionError.authorityConflict }
        // Old native queue rows may predate admission-time selection. Their native
        // reader still enforces authority before importing any source content.
        return try await native.normalize(packet, capturedAt: capturedAt, context: context, cryptography: cryptography)
    }

    private var hookRoute: CollectionCaptureRoute {
        .init(scope: .init(provider: .codex, profileID: nativeRoute.scope.profileID,
            interface: nativeRoute.scope.interface, path: .hook), hostVersion: nativeRoute.hostVersion)
    }

    private func isHookChoice(_ choice: CollectionAuthorityChoice, session: SessionIdentity) throws -> Bool {
        guard choice.session == session else { throw CodexCollectionError.authorityConflict }
        if choice.authorityID == CodexHookContentAdapter.authorityID { return true }
        guard choice.authorityID == nativeAuthority.rawValue else { throw CodexCollectionError.authorityConflict }
        return false
    }

    private func validate(_ packet: CapturePacket) throws {
        guard packet.metadata.agent == .codex, packet.metadata.profileID == nativeRoute.scope.profileID,
              packet.metadata.interface == nativeRoute.scope.interface else { throw CodexCollectionError.wrongProfile }
    }

    private func selectedSession(in packet: CapturePacket) throws -> (session: SessionIdentity, isPoll: Bool)? {
        guard let event = try? JSONDecoder().decode(CodexJSON.self, from: packet.eventJSON),
              event["kind"].string != CodexHistoryRequest.kind,
              let name = event["hook_event_name"].string else { return nil }
        let isPoll = ["SpillcheckHistoryPoll", "LeakretHistoryPoll"].contains(name)
        guard isPoll || CodexHookConfiguration.events.contains(name),
              let id = event["session_id"].nonemptyString,
              id.utf8.count <= 4096, !id.utf8.contains(0) else { return nil }
        return (try .init(provider: .codex, profileID: nativeRoute.scope.profileID, sessionID: id), isPoll)
    }
}
