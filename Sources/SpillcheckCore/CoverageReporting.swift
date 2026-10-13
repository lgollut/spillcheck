import Foundation

/// Counts describe the entire matching query, including rows beyond the returned bound.
public struct CoverageQueryPage<Item: Sendable>: Sendable {
    public let items: [Item]
    public let totalCount: Int
    public var isTruncated: Bool { totalCount > items.count }

    public init(items: [Item], totalCount: Int) {
        self.items = items
        self.totalCount = totalCount
    }
}

/// Protected native profile identity. Diagnostic exports must replace it with an opaque alias.
public struct CoverageAuditIdentity: Hashable, Codable, Sendable {
    public let auditID: UUID
    public let provider: AgentProvider
    public let profileID: String

    public init(auditID: UUID, provider: AgentProvider, profileID: String) {
        self.auditID = auditID
        self.provider = provider
        self.profileID = profileID
    }
}

/// Historical observations remain queryable even after their exact audit finishes.
/// A legacy event has no audit identity and cannot be settled by an unrelated successful read.
public struct StoredCoverageGapEvent: Hashable, Codable, Sendable {
    public let id: UUID
    public let gap: CoverageGap
    public let observedAt: Date
    public let audit: CoverageAuditIdentity?
    public let isIntermediateBacklog: Bool
    public let workID: UUID?

    public init(id: UUID = UUID(), gap: CoverageGap, observedAt: Date,
                audit: CoverageAuditIdentity? = nil, isIntermediateBacklog: Bool = false, workID: UUID? = nil) {
        self.id = id
        self.gap = gap
        self.observedAt = observedAt
        self.audit = audit
        self.isIntermediateBacklog = isIntermediateBacklog
        self.workID = workID
    }
}

/// Content-free in operation, but its protected gaps still carry native recovery identifiers.
/// Exporters must explicitly select safe fields rather than encode this report wholesale.
public struct CoverageReport: Sendable {
    public let window: DateInterval
    public let gapEvents: CoverageQueryPage<StoredCoverageGapEvent>
    public let omissions: CoverageQueryPage<CoverageOmission>
    public let history: CoverageQueryPage<StoredHistoricalProgress>
    public let queue: StoreQueueStatistics
    public let oldestPendingCaptureAt: Date?
    public let work: CoverageQueryPage<StoredCollectionWork>
    public let omissionStateCounts: [CoverageOmissionState: Int]
    public let successfulReads: CoverageQueryPage<SuccessfulCollectionRead>
    /// Aggregate lifetime identity usage, independent of this report's content window.
    public let capacity: StoreCapacitySnapshot?

    public init(window: DateInterval, gapEvents: CoverageQueryPage<StoredCoverageGapEvent>,
                omissions: CoverageQueryPage<CoverageOmission>, history: CoverageQueryPage<StoredHistoricalProgress>,
                queue: StoreQueueStatistics, oldestPendingCaptureAt: Date?,
                work: CoverageQueryPage<StoredCollectionWork> = .init(items: [], totalCount: 0),
                omissionStateCounts: [CoverageOmissionState: Int] = [:],
                successfulReads: CoverageQueryPage<SuccessfulCollectionRead> = .init(items: [], totalCount: 0),
                capacity: StoreCapacitySnapshot? = nil) {
        self.window = window
        self.gapEvents = gapEvents
        self.omissions = omissions
        self.history = history
        self.queue = queue
        self.oldestPendingCaptureAt = oldestPendingCaptureAt
        self.work = work
        self.omissionStateCounts = omissionStateCounts
        self.successfulReads = successfulReads
        self.capacity = capacity
    }

    public var isTruncated: Bool {
        gapEvents.isTruncated || omissions.isTruncated || history.isTruncated || work.isTruncated || successfulReads.isTruncated
    }

    public var unresolvedOmissions: [CoverageOmission] { omissions.items.filter(\.isUnresolved) }

    /// Exact omissions own their recovery state only when they are present in this report.
    /// Missing or out-of-window omission rows cannot erase a recent observed event.
    public var independentlyReportedEvents: [StoredCoverageGapEvent] {
        gapEvents.items.filter { event in
            !omissions.items.contains { omission in
                // Older collectors could persist an excluded media sibling at the same
                // position as unread required text. That row cannot own the text's state.
                if event.gap.requiresAnalysis && !omission.gap.requiresAnalysis { return false }
                if let reference = event.gap.recovery, let other = omission.gap.recovery {
                    return event.gap.scope == omission.gap.scope && event.gap.reason == omission.gap.reason
                        && event.gap.contentType == omission.gap.contentType && event.gap.operation == omission.gap.operation
                        && reference.identifiesSameLocation(as: other)
                }
                return event.gap.recovery == nil && omission.gap.recovery == nil && event.gap == omission.gap
                    && abs(event.observedAt.timeIntervalSince(omission.firstObservedAt)) < 0.001
            }
        }
    }

    /// Combine with unresolvedOmissions for the remaining content gaps. A settled backlog
    /// and an exact omission already represented by its own lifecycle need no duplicate event.
    public var activeGapEvents: [StoredCoverageGapEvent] {
        independentlyReportedEvents.filter { !hasRecoveredBacklog($0) }
    }

    public func hasRecoveredBacklog(_ event: StoredCoverageGapEvent) -> Bool {
        guard event.isIntermediateBacklog, event.gap.reason == .budgetExhausted,
              event.gap.recovery == nil, let audit = event.audit else { return false }
        if let workID = event.workID {
            guard !work.isTruncated, work.items.contains(where: { $0.id == workID }),
                  !work.items.contains(where: { $0.context.audit == audit && $0.state != .recovered && $0.state != .completed }) else { return false }
        }
        return history.items.contains {
            $0.progress.audit.id == audit.auditID && $0.provider == audit.provider && $0.profileID == audit.profileID
                && !$0.progress.hasUnreadContent && $0.continuationQueued == false
                && $0.completedAt.map { $0 >= event.observedAt } == true
        }
    }
}
