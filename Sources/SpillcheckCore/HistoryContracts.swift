import Foundation

public struct HistoryReadBudget: Sendable {
    public let maximumBytes: Int
    public let maximumDuration: TimeInterval
    public let maximumSources: Int

    public init(maximumBytes: Int = 100 * 1024 * 1024, maximumDuration: TimeInterval = 30,
                maximumSources: Int = 256) {
        self.maximumBytes = maximumBytes
        self.maximumDuration = maximumDuration
        self.maximumSources = maximumSources
    }
}

/// Measured observations, not a claim that unindexed or unread content has been covered.
public struct HistoricalReadProgress: Codable, Sendable, Equatable {
    public let audit: HistoricalAuditContext
    public let bytesRead: Int
    public let oldestContentTime: Date?
    public let newestContentTime: Date?
    public let hasUnreadContent: Bool

    public init(audit: HistoricalAuditContext, bytesRead: Int, oldestContentTime: Date? = nil,
                newestContentTime: Date? = nil, hasUnreadContent: Bool) {
        self.audit = audit
        self.bytesRead = bytesRead
        self.oldestContentTime = oldestContentTime
        self.newestContentTime = newestContentTime
        self.hasUnreadContent = hasUnreadContent
    }
}

/// A chosen canonical representation cannot switch after items have been persisted.
public struct CollectionAuthorityChoice: Codable, Hashable, Sendable {
    public let session: SessionIdentity
    public let adapterVersion: String
    public let authorityID: String

    public init(session: SessionIdentity, adapterVersion: String, authorityID: String) throws {
        guard !adapterVersion.isEmpty, !authorityID.isEmpty,
              adapterVersion.utf8.count <= 256, authorityID.utf8.count <= 256 else {
            throw ContractError.emptyIdentity
        }
        self.session = session
        self.adapterVersion = adapterVersion
        self.authorityID = authorityID
    }
}

public typealias SourceAuthorityLookup = @Sendable (SessionIdentity) async throws -> CollectionAuthorityChoice?
public typealias SourceAuthorityRecorder = @Sendable (CollectionAuthorityChoice) async throws -> Void

public struct StoredHistoricalProgress: Codable, Sendable {
    public let provider: AgentProvider
    public let profileID: String
    public let progress: HistoricalReadProgress
}

/// The initial request and all continuation cursors contain structural selection only.
public protocol HistoricalCaptureProducer: Sendable {
    func initialHistoricalCapture(audit: HistoricalAuditContext) async throws -> CapturePacket
}
