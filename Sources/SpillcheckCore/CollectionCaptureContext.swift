import Foundation

/// Configuration supplies the route; a capture may select a source only within that route.
/// This retains a selection for recovery, not permission to open it. Readers validate it again.
public struct CollectionCaptureRoute: Sendable {
    public let scope: CollectionScope
    public let readerVersion: String?
    public let hostVersion: String?
    /// The reader's root check for a transcript path. Only with it may a child tool hook's
    /// workflow run folder be looked up; otherwise the route never touches the filesystem.
    public let transcriptLocator: (@Sendable (String) -> URL?)?

    public init(scope: CollectionScope, readerVersion: String? = nil, hostVersion: String? = nil,
                transcriptLocator: (@Sendable (String) -> URL?)? = nil) {
        self.scope = scope; self.readerVersion = readerVersion; self.hostVersion = hostVersion
        self.transcriptLocator = transcriptLocator
    }

    public func context(for packet: CapturePacket, trigger: CollectionWorkTrigger,
                        audit: HistoricalAuditContext? = nil,
                        retry: CoverageSourceRetryDescriptor? = nil) throws -> CollectionWorkContext {
        guard packet.metadata.agent == scope.provider, packet.metadata.profileID == scope.profileID,
              packet.metadata.interface == scope.interface else { throw CaptureTransportError.invalidMetadata }
        let identity = audit.map { CoverageAuditIdentity(auditID: $0.id, provider: scope.provider, profileID: scope.profileID) }
        var source = retry
        if source == nil, audit == nil,
           let event = try? JSONSerialization.jsonObject(with: packet.eventJSON) as? [String: Any],
           let sessionID = event["session_id"] as? String,
           let session = try? SessionIdentity(provider: scope.provider, profileID: scope.profileID, sessionID: sessionID) {
            let path = scope.path == .versionedTranscript ? event["transcript_path"] as? String : nil
            // A transcript selection without its original file is not an exact-source retry.
            if scope.provider == .claudeCode, scope.path == .versionedTranscript {
                source = claudeTranscriptRetry(event: event, session: session)
            } else if scope.path == .publicHistory || path?.hasPrefix("/") == true {
                source = CoverageSourceRetryDescriptor(scope: scope, session: session,
                    sourceURL: path.map { URL(fileURLWithPath: $0) })
            }
        }
        guard source == nil || source?.scope == scope else { throw CaptureTransportError.invalidMetadata }
        return CollectionWorkContext(scope: scope, operation: audit == nil ? .liveRead : .historicalRead,
            audit: identity, retry: source, readerVersion: readerVersion, hostVersion: hostVersion, trigger: trigger)
    }

    private func claudeTranscriptRetry(event: [String: Any], session: SessionIdentity) -> CoverageSourceRetryDescriptor? {
        let name = event["hook_event_name"] as? String ?? ""
        // SubagentStop reads parent and child. One exact-file audit cannot certify both.
        guard name != "SubagentStop", let parent = event["transcript_path"] as? String,
              parent.hasPrefix("/") else { return nil }
        let child: String
        if ClaudeToolHookSelection.toolEvents.contains(name), event["agent_id"] != nil {
            guard let agentID = event["agent_id"] as? String,
                  event["agent_transcript_path"] == nil || event["agent_transcript_path"] is String,
                  let selected = try? ClaudeToolHookSelection.toolHookChildPath(parentPath: parent, agentID: agentID,
                      declaredChildPath: event["agent_transcript_path"] as? String,
                      confinedParent: transcriptLocator?(parent)) else { return nil }
            child = selected
        } else if ClaudeToolHookSelection.pollEvents.contains(name), event["agent_transcript_path"] != nil {
            guard let declared = event["agent_transcript_path"] as? String,
                  let selected = try? ClaudeToolHookSelection.selectedPollChildPath(parentPath: parent,
                      declaredChildPath: declared) else { return nil }
            child = selected
        } else {
            return CoverageSourceRetryDescriptor(scope: scope, session: session, sourceURL: URL(fileURLWithPath: parent))
        }
        // The hook's session belongs to its parent; only native child rows establish the child's session.
        return CoverageSourceRetryDescriptor(scope: scope, sourceURL: URL(fileURLWithPath: child))
    }
}
