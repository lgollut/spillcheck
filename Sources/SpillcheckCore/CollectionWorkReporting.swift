import Foundation

/// A source selection, never a retained message. All fields stay encrypted at rest.
/// A caller must revalidate this selection against its configured authorized source before reading.
public struct CoverageSourceRetryDescriptor: Hashable, Codable, Sendable {
    public let scope: CollectionScope
    public let session: SessionIdentity?
    public let sourceDocumentID: UUID?
    public let sourceURL: URL?

    public init(scope: CollectionScope, session: SessionIdentity? = nil,
                sourceDocumentID: UUID? = nil, sourceURL: URL? = nil) {
        self.scope = scope; self.session = session
        self.sourceDocumentID = sourceDocumentID; self.sourceURL = sourceURL
    }

    /// A derived document ID may enrich a previously admitted exact file selection. It must
    /// not make that selection a different source, or let one session select a sibling file.
    public func identifiesSameSource(as other: Self) -> Bool {
        guard scope == other.scope else { return false }
        switch scope.path {
        case .publicHistory:
            guard let session, session == other.session else { return false }
            return true
        case .versionedTranscript:
            guard let sourceURL, sourceURL == other.sourceURL else { return false }
            if let session, let otherSession = other.session, session != otherSession { return false }
            if let sourceDocumentID, let otherDocument = other.sourceDocumentID, sourceDocumentID != otherDocument { return false }
            return true
        case .hook:
            return false // A delivery route does not identify an original historical source.
        }
    }
}

public enum CollectionWorkTrigger: String, Codable, Sendable { case helperDelivery, activePoll, historyRequest }

public struct CollectionWorkContext: Hashable, Codable, Sendable {
    public let scope: CollectionScope
    public let operation: CollectionOperation
    public let audit: CoverageAuditIdentity?
    public let retry: CoverageSourceRetryDescriptor?
    /// Configured reader when this work was admitted; execution may use a later version.
    public let readerVersion: String?
    public let hostVersion: String?
    public let trigger: CollectionWorkTrigger?
    public let auditWindow: DateInterval?

    public init(scope: CollectionScope, operation: CollectionOperation,
                audit: CoverageAuditIdentity? = nil, retry: CoverageSourceRetryDescriptor? = nil,
                readerVersion: String? = nil, hostVersion: String? = nil, trigger: CollectionWorkTrigger? = nil, auditWindow: DateInterval? = nil) {
        self.scope = scope; self.operation = operation; self.audit = audit; self.retry = retry
        self.readerVersion = readerVersion; self.hostVersion = hostVersion; self.trigger = trigger; self.auditWindow = auditWindow
    }
}

/// Terminal means this queue attempt ended. It does not assert the original source is unavailable.
public enum CollectionWorkState: String, Codable, Sendable {
    case queued, processing, stalled, terminal, completed, recovered
}

/// An authenticated, completed exact-source audit. A plain completed state or an
/// unrelated successful read cannot certify recovery of an earlier capture.
public struct CollectionRecoveryCertificate: Codable, Equatable, Sendable {
    let schemaVersion: Int
    public let targetWorkID: UUID
    public let auditWindow: DateInterval
    public let completedAt: Date

    init(targetWorkID: UUID, auditWindow: DateInterval, completedAt: Date) {
        schemaVersion = 1
        self.targetWorkID = targetWorkID; self.auditWindow = auditWindow; self.completedAt = completedAt
    }
}

public struct StoredCollectionWork: Codable, Equatable, Sendable {
    public let id: UUID
    public let context: CollectionWorkContext
    public let state: CollectionWorkState
    public let admittedAt: Date
    public let lastAttemptedAt: Date?
    public let completedAt: Date?
    public let omissionID: UUID?
    public let recoveryOf: UUID?
    public let recoveryCertificate: CollectionRecoveryCertificate?

    public init(id: UUID, context: CollectionWorkContext, state: CollectionWorkState,
                admittedAt: Date, lastAttemptedAt: Date? = nil, completedAt: Date? = nil, omissionID: UUID? = nil,
                recoveryOf: UUID? = nil, recoveryCertificate: CollectionRecoveryCertificate? = nil) {
        self.id = id; self.context = context; self.state = state; self.admittedAt = admittedAt
        self.lastAttemptedAt = lastAttemptedAt; self.completedAt = completedAt; self.omissionID = omissionID
        self.recoveryOf = recoveryOf; self.recoveryCertificate = recoveryCertificate
    }
}

public struct SuccessfulCollectionRead: Codable, Sendable {
    public let scope: CollectionScope
    public let operation: CollectionOperation
    public let succeededAt: Date
    public let producerVersions: Set<String>
    public let readerVersion: String?
    public let hostVersion: String?

    public init(scope: CollectionScope, operation: CollectionOperation, succeededAt: Date,
                producerVersions: Set<String> = [], readerVersion: String? = nil, hostVersion: String? = nil) {
        self.scope = scope; self.operation = operation; self.succeededAt = succeededAt
        self.producerVersions = producerVersions; self.readerVersion = readerVersion; self.hostVersion = hostVersion
    }
}
