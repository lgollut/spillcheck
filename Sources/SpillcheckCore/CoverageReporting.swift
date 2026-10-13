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

extension CoverageQueryPage: Equatable where Item: Equatable {}

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
    private let lookup: Lookup

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
        lookup = Lookup(omissions: omissions.items, history: history.items, work: work.items,
                        successfulReads: successfulReads.items)
    }

    public var isTruncated: Bool {
        gapEvents.isTruncated || omissions.isTruncated || history.isTruncated || work.isTruncated || successfulReads.isTruncated
    }

    /// Compares every returned record, count and capacity figure. The window is excluded
    /// because its end moves with each query even when no record changed.
    public func hasSameRecords(as other: CoverageReport) -> Bool {
        gapEvents == other.gapEvents && omissions == other.omissions && history == other.history
            && queue == other.queue && oldestPendingCaptureAt == other.oldestPendingCaptureAt && work == other.work
            && omissionStateCounts == other.omissionStateCounts && successfulReads == other.successfulReads
            && capacity == other.capacity
    }

    public var unresolvedOmissions: [CoverageOmission] { omissions.items.filter(\.isUnresolved) }

    /// Exact omissions own their recovery state only when they are present in this report.
    /// Missing or out-of-window omission rows cannot erase a recent observed event.
    public var independentlyReportedEvents: [StoredCoverageGapEvent] {
        gapEvents.items.filter { event in
            !(lookup.omissionsByLocation[.init(event.gap)] ?? []).contains {
                Self.omission(omissions.items[$0], owns: event)
            }
        }
    }

    /// The lookup only narrows candidates. This rule alone decides ownership.
    private static func omission(_ omission: CoverageOmission, owns event: StoredCoverageGapEvent) -> Bool {
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

    /// The first work row with this identity, in report order.
    public func work(id: UUID) -> StoredCollectionWork? { lookup.workByID[id].map { work.items[$0] } }

    /// The first work row linked to this omission, in report order.
    public func work(omissionID: UUID) -> StoredCollectionWork? {
        lookup.workByOmission[omissionID].map { work.items[$0] }
    }

    /// Work rows admitted for this audit, in report order.
    public func work(audit: CoverageAuditIdentity) -> [StoredCollectionWork] {
        (lookup.workByAudit[audit] ?? []).map { work.items[$0] }
    }

    public func latestSuccessfulRead(scope: CollectionScope, operation: CollectionOperation) -> Date? {
        lookup.latestReads[.init(scope: scope, operation: operation)]
    }

    /// Whether queued or in-progress work already reads this source.
    public func hasPendingWork(for source: CoverageSourceRetryDescriptor) -> Bool {
        guard let key = Lookup.SourceKey(source) else { return false }
        return (lookup.pendingWorkBySource[key] ?? []).contains {
            work.items[$0].context.retry?.identifiesSameSource(as: source) == true
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
            guard !work.isTruncated, lookup.workByID[workID] != nil,
                  !lookup.auditsWithUnsettledWork.contains(audit) else { return false }
        }
        return lookup.latestSettledHistory[audit].map { $0 >= event.observedAt } == true
    }

    /// Presentation joins every event and omission against work and history on each refresh.
    /// Indexes into the report's own arrays keep those joins linear in the report size.
    private struct Lookup: Sendable {
        /// Fields that ownership requires to be equal. Located gaps still need the exact
        /// session and file comparison; unlocated gaps still need the observation time.
        enum LocationKey: Hashable {
            case located(scope: CollectionScope?, reason: CoverageGapReason, contentType: ContentType?,
                         operation: CollectionOperation?, locator: SourceLocator, itemID: String?, sourceDocumentID: UUID?)
            case unlocated(CoverageGap)

            init(_ gap: CoverageGap) {
                if let reference = gap.recovery {
                    self = .located(scope: gap.scope, reason: gap.reason, contentType: gap.contentType,
                                    operation: gap.operation, locator: reference.locator, itemID: reference.itemID,
                                    sourceDocumentID: reference.sourceDocumentID)
                } else { self = .unlocated(gap) }
            }
        }

        struct ReadKey: Hashable {
            let scope: CollectionScope
            let operation: CollectionOperation
        }

        /// The selection that `identifiesSameSource` requires to be present and equal.
        enum SourceKey: Hashable {
            case history(CollectionScope, SessionIdentity)
            case transcript(CollectionScope, URL)

            init?(_ source: CoverageSourceRetryDescriptor) {
                switch source.scope.path {
                case .publicHistory:
                    guard let session = source.session else { return nil }
                    self = .history(source.scope, session)
                case .versionedTranscript:
                    guard let url = source.sourceURL else { return nil }
                    self = .transcript(source.scope, url)
                case .hook: return nil
                }
            }
        }

        var omissionsByLocation: [LocationKey: [Int]] = [:]
        var workByID: [UUID: Int] = [:]
        var workByOmission: [UUID: Int] = [:]
        var workByAudit: [CoverageAuditIdentity: [Int]] = [:]
        var auditsWithUnsettledWork: Set<CoverageAuditIdentity> = []
        /// Latest completion of each audit that finished without unread content or a queued continuation.
        var latestSettledHistory: [CoverageAuditIdentity: Date] = [:]
        var latestReads: [ReadKey: Date] = [:]
        var pendingWorkBySource: [SourceKey: [Int]] = [:]

        init(omissions: [CoverageOmission], history: [StoredHistoricalProgress], work: [StoredCollectionWork],
             successfulReads: [SuccessfulCollectionRead]) {
            for (index, omission) in omissions.enumerated() {
                omissionsByLocation[.init(omission.gap), default: []].append(index)
            }
            for (index, item) in work.enumerated() {
                if workByID[item.id] == nil { workByID[item.id] = index }
                if let omissionID = item.omissionID, workByOmission[omissionID] == nil { workByOmission[omissionID] = index }
                if item.state == .queued || item.state == .processing,
                   let key = item.context.retry.flatMap(SourceKey.init) { pendingWorkBySource[key, default: []].append(index) }
                guard let audit = item.context.audit else { continue }
                workByAudit[audit, default: []].append(index)
                if item.state != .recovered && item.state != .completed { auditsWithUnsettledWork.insert(audit) }
            }
            for item in history where !item.progress.hasUnreadContent && item.continuationQueued == false {
                guard let completedAt = item.completedAt else { continue }
                let audit = CoverageAuditIdentity(auditID: item.progress.audit.id, provider: item.provider,
                                                  profileID: item.profileID)
                latestSettledHistory[audit] = max(latestSettledHistory[audit] ?? completedAt, completedAt)
            }
            for read in successfulReads {
                let key = ReadKey(scope: read.scope, operation: read.operation)
                latestReads[key] = max(latestReads[key] ?? read.succeededAt, read.succeededAt)
            }
        }
    }
}
