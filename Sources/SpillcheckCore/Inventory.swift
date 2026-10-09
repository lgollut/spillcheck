import Foundation

public enum ObsoleteAcknowledgement: String, Codable, Sendable { case rotated, revoked }

/// Recognition survives content deletion. It contains no payloads, excerpts or old occurrences.
public struct ObsoleteValueMarker: Hashable, Codable, Sendable {
    public let fingerprint: ValueFingerprint
    public let acknowledgement: ObsoleteAcknowledgement
    public let acknowledgedAt: Date
}

public struct InventoryRecord: Hashable, Codable, Sendable {
    public let id: UUID
    public let fingerprint: ValueFingerprint
    public internal(set) var protectedValue: ProtectedPayloadReference?
    public internal(set) var categories: Set<SecretCategory>
    public internal(set) var firstOccurrenceAt: Date
    public internal(set) var lastOccurrenceAt: Date

    public var maskedLabels: [String] {
        categories.sorted(by: { $0.rawValue < $1.rawValue }).map(\.maskedLabel)
    }
}

public struct ReviewCounts: Equatable, Sendable {
    public let total: Int
    public let confirmed: Int
    public let unreviewed: Int
    public let falsePositive: Int
    public let needsReview: Int
}

public struct InventorySummary: Sendable {
    public let record: InventoryRecord
    public let detectorSignal: SignalStrength?
    public let reviewCounts: ReviewCounts
    public let obsoleteAppearanceCount: Int
    public let metadataOnlyOccurrenceCount: Int
    public let obsoleteMarker: ObsoleteValueMarker?

    public var occurrenceCount: Int { reviewCounts.total + metadataOnlyOccurrenceCount }
    public var canRevealRetainedValue: Bool { record.protectedValue != nil }
}

public struct AlertEligibilityKey: Hashable, Codable, Sendable {
    public let fingerprint: ValueFingerprint
    public let session: SessionIdentity
}

public enum AlertDeliveryState: String, Codable, Sendable { case pending, delivered, permissionDenied, cancelled }

/// Persist the decision and its opaque identifier together. Retries use this identifier, never
/// generate a new notification. This does not claim exactly-once macOS presentation.
public struct AlertDecision: Hashable, Codable, Sendable {
    public let id: UUID
    public let valueID: UUID
    public let eligibility: AlertEligibilityKey
    public let categories: Set<SecretCategory>
    public internal(set) var delivery: AlertDeliveryState

    public var notificationIdentifier: String { "leakret-\(id.uuidString.lowercased())" }
    public var provider: AgentProvider { eligibility.session.provider }
    public var maskedLabels: [String] {
        categories.sorted(by: { $0.rawValue < $1.rawValue }).map(\.maskedLabel)
    }
}

public struct HistoricalContribution: Sendable {
    public let audit: HistoricalAuditContext
    public let ordinaryOccurrenceIDs: Set<UUID>
    public let obsoleteOccurrenceIDs: Set<UUID>
    public let ordinaryValueIDs: Set<UUID>
}

public struct HistoricalAuditSummary: Sendable {
    public let audit: HistoricalAuditContext
    public private(set) var ordinaryOccurrenceIDs: Set<UUID> = []
    public private(set) var obsoleteOccurrenceIDs: Set<UUID> = []
    public private(set) var ordinaryValueIDs: Set<UUID> = []

    public init(audit: HistoricalAuditContext) { self.audit = audit }
    public var ordinaryOccurrenceCount: Int { ordinaryOccurrenceIDs.count }
    public var obsoleteOccurrenceCount: Int { obsoleteOccurrenceIDs.count }
    public var ordinaryValueCount: Int { ordinaryValueIDs.count }
    public var shouldNotify: Bool { ordinaryOccurrenceCount > 0 }
    public var notificationIdentifier: String { "leakret-audit-\(audit.id.uuidString.lowercased())" }

    public mutating func include(_ contribution: HistoricalContribution) throws {
        guard contribution.audit == audit else { throw ContractError.mismatchedAudit }
        ordinaryOccurrenceIDs.formUnion(contribution.ordinaryOccurrenceIDs)
        obsoleteOccurrenceIDs.formUnion(contribution.obsoleteOccurrenceIDs)
        ordinaryValueIDs.formUnion(contribution.ordinaryValueIDs)
    }
}

public enum AnalysisOutcome: String, Sendable { case processed, replay, outsideHistoricalWindow }

public struct InventoryTransition: Sendable {
    public let outcome: AnalysisOutcome
    public let createdValueIDs: Set<UUID>
    public let insertedOccurrenceIDs: Set<UUID>
    public let insertedObsoleteAppearanceIDs: Set<UUID>
    public let insertedUnlocatedIDs: Set<UUID>
    public let addedEvidenceCount: Int
    public let alerts: [AlertDecision]
    public let historicalContribution: HistoricalContribution?
    /// Protection can run before reconciliation; remove unused encrypted payloads in the transaction.
    public let discardedPayloadReferences: Set<ProtectedPayloadReference>
}

/// A persistence implementation must apply this plan atomically, including matching queued retries
/// and notification work. Independent processed-source receipts are deliberately not removed.
public struct ContentRemovalPlan: Sendable {
    public let removedValueID: UUID
    public let payloadReferences: Set<ProtectedPayloadReference>
    public let occurrenceIDs: Set<UUID>
    public let notificationIdentifiers: Set<String>
    public let sourceItems: Set<SourceIdentity>
    public let retainedObsoleteMarker: ObsoleteValueMarker?
}

public struct AnalysisReceipt: Hashable, Codable, Sendable {
    public let source: SourceIdentity
    public let revision: ContentRevision
    public let detectorVersion: String

    public init(source: SourceIdentity, revision: ContentRevision, detectorVersion: String) {
        self.source = source
        self.revision = revision
        self.detectorVersion = detectorVersion
    }
}

public enum LocationReceipt: Hashable, Codable, Sendable {
    case occurrence(UUID)
    case obsoleteAppearance(UUID)
    case removed
}

public enum StrongSignalReceipt: Hashable, Codable, Sendable {
    case liveAlert(UUID)
    case historicalAudit(UUID)
}

public struct UnlocatedIdentity: Hashable, Codable, Sendable {
    public let source: SourceIdentity
    public let evidence: Set<DetectionEvidence>
    public let reason: LocationFailure

    public init(source: SourceIdentity, evidence: Set<DetectionEvidence>, reason: LocationFailure) {
        self.source = source
        self.evidence = evidence
        self.reason = reason
    }
}

/// Domain state for persistence integration. Codable supports repeatable restart fixtures; the
/// storage layer still owns schema migrations, unique rows and atomic durable transactions.
/// Source receipts remain separately accessible even when all retained inventory content is gone.
public struct InventorySnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let records: [ValueFingerprint: InventoryRecord]
    public let occurrences: [UUID: Occurrence]
    public let obsoleteAppearances: [UUID: ObsoleteAppearance]
    public let obsoleteMarkers: [ValueFingerprint: ObsoleteValueMarker]
    public let alertDecisions: [UUID: AlertDecision]
    public let unlocatedResults: [UUID: UnlocatedResult]
    public let analysisReceipts: Set<AnalysisReceipt>
    public let locationReceipts: [OccurrenceIdentity: LocationReceipt]
    public let strongSignalReceipts: [AlertEligibilityKey: StrongSignalReceipt]
    public let unlocatedReceipts: Set<UnlocatedIdentity>
    public let sourceKinds: [SourceIdentity: ContentType]
    /// Latest content time per processed source. Sources without a time predate compaction.
    public let sourceTimes: [SourceIdentity: Date]
    public let conversationLabels: [SessionIdentity: MaskedConversationLabel]
    public let historicalNotificationDecisions: [UUID: HistoricalNotificationDecision]
    /// App-generated entry numbers. A label is never reused, even after its entry is removed.
    public let valueLabels: [ValueFingerprint: MaskedValueLabel]
    public let unlocatedLabels: [UUID: MaskedValueLabel]
    public let nextValueLabel: Int

    public init(
        schemaVersion: Int = 1,
        records: [ValueFingerprint: InventoryRecord] = [:], occurrences: [UUID: Occurrence] = [:],
        obsoleteAppearances: [UUID: ObsoleteAppearance] = [:],
        obsoleteMarkers: [ValueFingerprint: ObsoleteValueMarker] = [:],
        alertDecisions: [UUID: AlertDecision] = [:], unlocatedResults: [UUID: UnlocatedResult] = [:],
        analysisReceipts: Set<AnalysisReceipt> = [],
        locationReceipts: [OccurrenceIdentity: LocationReceipt] = [:],
        strongSignalReceipts: [AlertEligibilityKey: StrongSignalReceipt] = [:],
        unlocatedReceipts: Set<UnlocatedIdentity> = [], sourceKinds: [SourceIdentity: ContentType] = [:],
        sourceTimes: [SourceIdentity: Date] = [:],
        conversationLabels: [SessionIdentity: MaskedConversationLabel] = [:],
        historicalNotificationDecisions: [UUID: HistoricalNotificationDecision] = [:],
        valueLabels: [ValueFingerprint: MaskedValueLabel] = [:], unlocatedLabels: [UUID: MaskedValueLabel] = [:],
        nextValueLabel: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.records = records
        self.occurrences = occurrences
        self.obsoleteAppearances = obsoleteAppearances
        self.obsoleteMarkers = obsoleteMarkers
        self.alertDecisions = alertDecisions
        self.unlocatedResults = unlocatedResults
        self.analysisReceipts = analysisReceipts
        self.locationReceipts = locationReceipts
        self.strongSignalReceipts = strongSignalReceipts
        self.unlocatedReceipts = unlocatedReceipts
        self.sourceKinds = sourceKinds
        self.sourceTimes = sourceTimes
        self.conversationLabels = conversationLabels
        self.historicalNotificationDecisions = historicalNotificationDecisions
        self.valueLabels = valueLabels
        self.unlocatedLabels = unlocatedLabels
        self.nextValueLabel = nextValueLabel
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, records, occurrences, obsoleteAppearances, obsoleteMarkers, alertDecisions, unlocatedResults
        case analysisReceipts, locationReceipts, strongSignalReceipts, unlocatedReceipts, sourceKinds, sourceTimes
        case conversationLabels, historicalNotificationDecisions, valueLabels, unlocatedLabels, nextValueLabel
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(schemaVersion: try c.decode(Int.self, forKey: .schemaVersion),
            records: try c.decode([ValueFingerprint: InventoryRecord].self, forKey: .records),
            occurrences: try c.decode([UUID: Occurrence].self, forKey: .occurrences),
            obsoleteAppearances: try c.decode([UUID: ObsoleteAppearance].self, forKey: .obsoleteAppearances),
            obsoleteMarkers: try c.decode([ValueFingerprint: ObsoleteValueMarker].self, forKey: .obsoleteMarkers),
            alertDecisions: try c.decode([UUID: AlertDecision].self, forKey: .alertDecisions),
            unlocatedResults: try c.decode([UUID: UnlocatedResult].self, forKey: .unlocatedResults),
            analysisReceipts: try c.decode(Set<AnalysisReceipt>.self, forKey: .analysisReceipts),
            locationReceipts: try c.decode([OccurrenceIdentity: LocationReceipt].self, forKey: .locationReceipts),
            strongSignalReceipts: try c.decode([AlertEligibilityKey: StrongSignalReceipt].self, forKey: .strongSignalReceipts),
            unlocatedReceipts: try c.decode(Set<UnlocatedIdentity>.self, forKey: .unlocatedReceipts),
            sourceKinds: try c.decode([SourceIdentity: ContentType].self, forKey: .sourceKinds),
            sourceTimes: try c.decodeIfPresent([SourceIdentity: Date].self, forKey: .sourceTimes) ?? [:],
            conversationLabels: try c.decodeIfPresent([SessionIdentity: MaskedConversationLabel].self, forKey: .conversationLabels) ?? [:],
            historicalNotificationDecisions: try c.decodeIfPresent([UUID: HistoricalNotificationDecision].self, forKey: .historicalNotificationDecisions) ?? [:],
            valueLabels: try c.decodeIfPresent([ValueFingerprint: MaskedValueLabel].self, forKey: .valueLabels) ?? [:],
            unlocatedLabels: try c.decodeIfPresent([UUID: MaskedValueLabel].self, forKey: .unlocatedLabels) ?? [:],
            nextValueLabel: try c.decodeIfPresent(Int.self, forKey: .nextValueLabel) ?? 1)
    }
}

extension InventorySnapshot {
    /// Summaries are reconstructed from protected occurrence provenance after every restart.
    /// Deleted occurrences and current false-positive reviews cannot remain in pending totals.
    public func historicalSummaries() throws -> [HistoricalAuditSummary] {
        var summaries: [UUID: HistoricalAuditSummary] = [:]
        let recordsByID = Dictionary(uniqueKeysWithValues: records.values.map { ($0.id, $0) })
        for occurrence in occurrences.values {
            guard case .historical(let audit) = occurrence.source.origin.provenance,
                  occurrence.review != .falsePositive else { continue }
            var summary = summaries[audit.id] ?? HistoricalAuditSummary(audit: audit)
            let obsolete = occurrence.classification != .ordinary
                || recordsByID[occurrence.valueID].map { obsoleteMarkers[$0.fingerprint] != nil } == true
            try summary.include(HistoricalContribution(audit: audit,
                ordinaryOccurrenceIDs: obsolete ? [] : [occurrence.id],
                obsoleteOccurrenceIDs: obsolete ? [occurrence.id] : [],
                ordinaryValueIDs: obsolete ? [] : [occurrence.valueID]))
            summaries[audit.id] = summary
        }
        for appearance in obsoleteAppearances.values {
            guard case .historical(let audit) = appearance.provenance else { continue }
            var summary = summaries[audit.id] ?? HistoricalAuditSummary(audit: audit)
            try summary.include(HistoricalContribution(audit: audit, ordinaryOccurrenceIDs: [],
                obsoleteOccurrenceIDs: [appearance.id], ordinaryValueIDs: []))
            summaries[audit.id] = summary
        }
        return summaries.values.sorted { $0.audit.end > $1.audit.end }
    }
}

/// Pure in-memory domain transitions, suitable for running within a later storage transaction.
/// This is not persistence, encryption, a queue, a collector or a scanner implementation.
/// Raw source content and exact values are absent; only encrypted payload references are retained.
public struct InventoryLedger: Sendable {
    public private(set) var records: [ValueFingerprint: InventoryRecord] = [:]
    public private(set) var occurrences: [UUID: Occurrence] = [:]
    public private(set) var obsoleteAppearances: [UUID: ObsoleteAppearance] = [:]
    public private(set) var obsoleteMarkers: [ValueFingerprint: ObsoleteValueMarker] = [:]
    public private(set) var alertDecisions: [UUID: AlertDecision] = [:]
    public private(set) var unlocatedResults: [UUID: UnlocatedResult] = [:]
    public private(set) var conversationLabels: [SessionIdentity: MaskedConversationLabel] = [:]
    public private(set) var historicalNotificationDecisions: [UUID: HistoricalNotificationDecision] = [:]
    public private(set) var valueLabels: [ValueFingerprint: MaskedValueLabel] = [:]
    public private(set) var unlocatedLabels: [UUID: MaskedValueLabel] = [:]
    private var nextValueLabel = 1
    private var analysisReceipts: Set<AnalysisReceipt> = []
    private var locationReceipts: [OccurrenceIdentity: LocationReceipt] = [:]
    private var strongSignalReceipts: [AlertEligibilityKey: StrongSignalReceipt] = [:]
    private var unlocatedReceipts: Set<UnlocatedIdentity> = []
    private var sourceKinds: [SourceIdentity: ContentType] = [:]
    private var sourceTimes: [SourceIdentity: Date] = [:]

    public init() {}

    public var snapshot: InventorySnapshot {
        InventorySnapshot(
            records: records, occurrences: occurrences, obsoleteAppearances: obsoleteAppearances,
            obsoleteMarkers: obsoleteMarkers, alertDecisions: alertDecisions, unlocatedResults: unlocatedResults,
            analysisReceipts: analysisReceipts, locationReceipts: locationReceipts,
            strongSignalReceipts: strongSignalReceipts, unlocatedReceipts: unlocatedReceipts, sourceKinds: sourceKinds,
            sourceTimes: sourceTimes, conversationLabels: conversationLabels, historicalNotificationDecisions: historicalNotificationDecisions,
            valueLabels: valueLabels, unlocatedLabels: unlocatedLabels, nextValueLabel: nextValueLabel
        )
    }

    public init(snapshot: InventorySnapshot) throws {
        try Self.validate(snapshot)
        records = snapshot.records
        occurrences = snapshot.occurrences
        obsoleteAppearances = snapshot.obsoleteAppearances
        obsoleteMarkers = snapshot.obsoleteMarkers
        alertDecisions = snapshot.alertDecisions
        unlocatedResults = snapshot.unlocatedResults
        analysisReceipts = snapshot.analysisReceipts
        locationReceipts = snapshot.locationReceipts
        strongSignalReceipts = snapshot.strongSignalReceipts
        unlocatedReceipts = snapshot.unlocatedReceipts
        sourceKinds = snapshot.sourceKinds
        sourceTimes = snapshot.sourceTimes
        conversationLabels = snapshot.conversationLabels
        historicalNotificationDecisions = snapshot.historicalNotificationDecisions
        let sessions = Set(snapshot.sourceKinds.keys.map(\.session))
            .union(snapshot.occurrences.values.map { $0.source.identity.session })
            .union(snapshot.obsoleteAppearances.values.map { $0.source.session })
            .union(snapshot.unlocatedResults.values.map { $0.source.identity.session }).sorted {
            ($0.provider.rawValue, $0.profileID, $0.sessionID) < ($1.provider.rawValue, $1.profileID, $1.sessionID)
        }
        for session in sessions { assignConversationLabel(session) }
        // Labels follow the entries they name. Older snapshots receive labels in first-seen order.
        // A damaged label is cosmetic: drop duplicates and renumber rather than reject the vault.
        var usedLabels: Set<Int> = []
        valueLabels = snapshot.valueLabels.filter { records[$0.key] != nil || obsoleteMarkers[$0.key] != nil }
            .sorted { $0.value.index < $1.value.index }
            .reduce(into: [:]) { if usedLabels.insert($1.value.index).inserted { $0[$1.key] = $1.value } }
        unlocatedLabels = snapshot.unlocatedLabels.filter { unlocatedResults[$0.key] != nil }
            .sorted { $0.value.index < $1.value.index }
            .reduce(into: [:]) { if usedLabels.insert($1.value.index).inserted { $0[$1.key] = $1.value } }
        nextValueLabel = max(snapshot.nextValueLabel,
                             (snapshot.valueLabels.values.map(\.index) + snapshot.unlocatedLabels.values.map(\.index)).max().map { $0 + 1 } ?? 1)
        for record in records.values.sorted(by: { ($0.firstOccurrenceAt, $0.id.uuidString) < ($1.firstOccurrenceAt, $1.id.uuidString) }) {
            assignValueLabel(record.fingerprint)
        }
        for marker in obsoleteMarkers.values.sorted(by: { $0.acknowledgedAt < $1.acknowledgedAt }) {
            assignValueLabel(marker.fingerprint)
        }
        for result in unlocatedResults.values.sorted(by: { ($0.source.contentTime, $0.id.uuidString) < ($1.source.contentTime, $1.id.uuidString) })
            where unlocatedLabels[result.id] == nil {
            unlocatedLabels[result.id] = takeValueLabel()
        }
    }

    /// Receipts contain source/range identity, not a value, excerpt or inventory record reference.
    public var processedLocations: Set<OccurrenceIdentity> { Set(locationReceipts.keys) }
    public var analyzedRevisionCount: Int { analysisReceipts.count }

    public func needsProcessedSourceCompaction(before cutoff: Date) -> Bool {
        guard sourceKinds.count == sourceTimes.count else { return true }
        var copy = self
        return copy.pruneProcessedSources(before: cutoff, stampingUntimedAt: cutoff) > 0
    }

    /// Drops bookkeeping for sources whose content is older than `cutoff`. The pipeline never
    /// analyzes content beyond `HistoricalAuditContext.analysisHorizon`, so a cutoff at or before
    /// that horizon cannot let replay or backfill recreate deleted content. Sources still referenced
    /// by an occurrence, obsolete appearance or unlocated result keep their kind and time. Sources
    /// recorded before content times were tracked are stamped with `now` and become eligible later.
    /// Returns the number of removed entries.
    @discardableResult
    public mutating func pruneProcessedSources(before cutoff: Date, stampingUntimedAt now: Date) -> Int {
        for source in sourceKinds.keys where sourceTimes[source] == nil { sourceTimes[source] = now }
        let stale = Set(sourceTimes.filter { $0.value < cutoff }.keys)
        guard !stale.isEmpty else { return 0 }
        let referenced = Set(occurrences.values.map(\.identity.source))
            .union(obsoleteAppearances.values.map(\.source))
            .union(unlocatedResults.values.map(\.source.identity))
        let unreferenced = stale.subtracting(referenced)
        let before = analysisReceipts.count + locationReceipts.count + unlocatedReceipts.count + sourceKinds.count
        analysisReceipts = analysisReceipts.filter { !stale.contains($0.source) }
        locationReceipts = locationReceipts.filter { $0.value != .removed || !stale.contains($0.key.source) }
        unlocatedReceipts = unlocatedReceipts.filter { !unreferenced.contains($0.source) }
        for source in unreferenced {
            sourceKinds.removeValue(forKey: source)
            sourceTimes.removeValue(forKey: source)
        }
        return before - (analysisReceipts.count + locationReceipts.count + unlocatedReceipts.count + sourceKinds.count)
    }

    /// The caller must also check its monitoring generation immediately before durable commit.
    /// A failing contract leaves the entire ledger unchanged, including earlier findings in a batch.
    public mutating func ingest(_ analysis: SourceAnalysis) throws -> InventoryTransition {
        var next = self
        let transition = try next.apply(analysis)
        try next.refreshPendingNotifications()
        self = next
        return transition
    }

    public func summary(for fingerprint: ValueFingerprint) -> InventorySummary? {
        guard let record = records[fingerprint] else { return nil }
        let appearances = occurrences.values.filter { $0.valueID == record.id }
        let active = appearances.filter { $0.review != .falsePositive }
        let signal: SignalStrength? = active.isEmpty ? nil :
            (active.contains(where: { $0.detectorSignal == .strong }) ? .strong : .ambiguous)
        return InventorySummary(
            record: record, detectorSignal: signal,
            reviewCounts: ReviewCounts(
                total: appearances.count,
                confirmed: appearances.filter { $0.review == .confirmedSecret }.count,
                unreviewed: appearances.filter { $0.review == .unreviewed }.count,
                falsePositive: appearances.filter { $0.review == .falsePositive }.count,
                needsReview: appearances.filter(\.needsReview).count
            ),
            obsoleteAppearanceCount: appearances.filter { $0.classification == .obsolete }.count +
                obsoleteAppearances.values.filter { $0.valueID == record.id }.count,
            metadataOnlyOccurrenceCount: obsoleteAppearances.values.filter { $0.valueID == record.id }.count,
            obsoleteMarker: obsoleteMarkers[fingerprint]
        )
    }

    /// Manual review changes no alert eligibility and never issues a notification.
    public mutating func review(_ occurrenceID: UUID, as state: OccurrenceReview) throws {
        guard var occurrence = occurrences[occurrenceID] else { throw ContractError.unknownOccurrence }
        occurrence.review = state
        occurrences[occurrenceID] = occurrence
        try refreshPendingNotifications()
    }

    public mutating func acknowledgeObsolete(
        _ fingerprint: ValueFingerprint, as acknowledgement: ObsoleteAcknowledgement, at time: Date
    ) throws {
        guard records[fingerprint] != nil || obsoleteMarkers[fingerprint] != nil else {
            throw ContractError.unknownValue
        }
        guard time.timeIntervalSince1970.isFinite else { throw ContractError.invalidTime }
        obsoleteMarkers[fingerprint] = ObsoleteValueMarker(
            fingerprint: fingerprint, acknowledgement: acknowledgement, acknowledgedAt: time
        )
        try refreshPendingNotifications()
    }

    /// Forgetting affects later new source appearances. Existing receipts still suppress old replay.
    /// Historical metadata-only appearances keep their original obsolete label; they gain no payload.
    public mutating func forgetObsoleteMarker(_ fingerprint: ValueFingerprint) throws {
        guard obsoleteMarkers.removeValue(forKey: fingerprint) != nil else {
            throw ContractError.obsoleteMarkerNotFound
        }
        if records[fingerprint] == nil { valueLabels.removeValue(forKey: fingerprint) }
    }

    public mutating func recordAlertDelivery(_ alertID: UUID, state: AlertDeliveryState) throws {
        guard var alert = alertDecisions[alertID] else { throw ContractError.invalidState }
        guard alert.delivery == .pending || alert.delivery == state else { throw ContractError.invalidState }
        alert.delivery = state
        alertDecisions[alertID] = alert
    }

    public func alertIsEligible(_ alert: AlertDecision) -> Bool {
        alert.delivery == .pending && alertHasEligibleContent(alert)
    }

    public func alertHasEligibleContent(_ alert: AlertDecision) -> Bool {
        guard alert.delivery != .cancelled, obsoleteMarkers[alert.eligibility.fingerprint] == nil,
              records[alert.eligibility.fingerprint]?.id == alert.valueID else { return false }
        return occurrences.values.contains {
            $0.valueID == alert.valueID && $0.source.identity.session == alert.eligibility.session
                && $0.review != .falsePositive && $0.detectorSignal == .strong && $0.classification == .ordinary
        }
    }

    public mutating func settleHistoricalNotifications(auditIDs: Set<UUID>) throws {
        try refreshPendingNotifications()
        for summary in try snapshot.historicalSummaries() where auditIDs.contains(summary.audit.id) && summary.shouldNotify {
            guard historicalNotificationDecisions[summary.audit.id] == nil else { continue }
            historicalNotificationDecisions[summary.audit.id] = HistoricalNotificationDecision(summary: summary)
        }
    }

    public mutating func recordHistoricalNotificationDelivery(_ auditID: UUID, state: AlertDeliveryState) throws {
        guard var decision = historicalNotificationDecisions[auditID],
              decision.delivery == .pending || decision.delivery == state else { throw ContractError.invalidState }
        decision.delivery = state
        historicalNotificationDecisions[auditID] = decision
    }

    private mutating func refreshPendingNotifications() throws {
        for alert in alertDecisions.values where alert.delivery == .pending && !alertIsEligible(alert) {
            // A withdrawn alert never reached the user. Releasing its eligibility lets the next
            // strong occurrence of this value in the same conversation notify normally.
            alertDecisions.removeValue(forKey: alert.id)
            if strongSignalReceipts[alert.eligibility] == .liveAlert(alert.id) {
                strongSignalReceipts.removeValue(forKey: alert.eligibility)
            }
        }
        guard historicalNotificationDecisions.values.contains(where: { $0.delivery == .pending }) else { return }
        let summaries = Dictionary(uniqueKeysWithValues: try snapshot.historicalSummaries().map { ($0.audit.id, $0) })
        for decision in historicalNotificationDecisions.values where decision.delivery == .pending {
            if let summary = summaries[decision.audit.id], summary.shouldNotify {
                historicalNotificationDecisions[decision.audit.id] = HistoricalNotificationDecision(summary: summary)
            } else {
                var cancelled = decision; cancelled.delivery = .cancelled
                historicalNotificationDecisions[decision.audit.id] = cancelled
            }
        }
    }

    private mutating func assignConversationLabel(_ session: SessionIdentity) {
        guard conversationLabels[session] == nil else { return }
        let maximum = conversationLabels.values.map(\.index).max() ?? 0
        guard maximum < Int.max else { return }
        conversationLabels[session] = MaskedConversationLabel(index: maximum + 1)
    }

    private mutating func assignValueLabel(_ fingerprint: ValueFingerprint) {
        guard valueLabels[fingerprint] == nil else { return }
        valueLabels[fingerprint] = takeValueLabel()
    }

    private mutating func takeValueLabel() -> MaskedValueLabel {
        let label = MaskedValueLabel(index: nextValueLabel)
        if nextValueLabel < Int.max { nextValueLabel += 1 }
        return label
    }

    public mutating func removeContent(for fingerprint: ValueFingerprint) throws -> ContentRemovalPlan {
        guard let record = records.removeValue(forKey: fingerprint) else { throw ContractError.unknownValue }
        let removedOccurrences = occurrences.values.filter { $0.valueID == record.id }
        let removedAppearances = obsoleteAppearances.values.filter { $0.valueID == record.id }
        let occurrenceIDs = Set(removedOccurrences.map(\.id) + removedAppearances.map(\.id))
        let removedAlerts = alertDecisions.values.filter { $0.valueID == record.id }
        var payloads = Set(removedOccurrences.compactMap(\.protectedExcerpt))
        payloads.formUnion(removedOccurrences.compactMap { $0.source.protectedMetadata })
        if let value = record.protectedValue { payloads.insert(value) }
        for occurrence in removedOccurrences { occurrences.removeValue(forKey: occurrence.id) }
        for appearance in removedAppearances { obsoleteAppearances.removeValue(forKey: appearance.id) }
        for alert in removedAlerts { alertDecisions.removeValue(forKey: alert.id) }
        strongSignalReceipts = strongSignalReceipts.filter { $0.key.fingerprint != fingerprint }
        for (identity, receipt) in locationReceipts {
            let id: UUID?
            switch receipt {
            case .occurrence(let occurrenceID), .obsoleteAppearance(let occurrenceID): id = occurrenceID
            case .removed: id = nil
            }
            if let id, occurrenceIDs.contains(id) { locationReceipts[identity] = .removed }
        }
        if obsoleteMarkers[fingerprint] == nil { valueLabels.removeValue(forKey: fingerprint) }
        try refreshPendingNotifications()
        return ContentRemovalPlan(
            removedValueID: record.id, payloadReferences: payloads.subtracting(activePayloadReferences), occurrenceIDs: occurrenceIDs,
            notificationIdentifiers: Set(removedAlerts.map(\.notificationIdentifier)),
            sourceItems: Set(removedOccurrences.map { $0.identity.source } + removedAppearances.map(\.source)),
            retainedObsoleteMarker: obsoleteMarkers[fingerprint]
        )
    }

    private mutating func apply(_ analysis: SourceAnalysis) throws -> InventoryTransition {
        var payloads = Set(analysis.detections.flatMap {
            [$0.protectedValue] + ($0.protectedExcerpt.map { [$0] } ?? [])
        })
        if let metadata = analysis.source.protectedMetadata { payloads.insert(metadata) }
        if case .historical(let audit) = analysis.source.origin.provenance,
           !audit.includes(contentTime: analysis.source.contentTime) {
            return emptyTransition(outcome: .outsideHistoricalWindow, discarded: payloads)
        }
        assignConversationLabel(analysis.source.identity.session)
        let analysisReceipt = AnalysisReceipt(
            source: analysis.source.identity, revision: analysis.revision, detectorVersion: analysis.detectorVersion
        )
        guard !analysisReceipts.contains(analysisReceipt) else {
            return emptyTransition(outcome: .replay, discarded: payloads)
        }
        if let knownKind = sourceKinds[analysis.source.identity], knownKind != analysis.source.contentType {
            throw ContractError.conflictingSourceMetadata
        }
        sourceKinds[analysis.source.identity] = analysis.source.contentType
        sourceTimes[analysis.source.identity] = max(sourceTimes[analysis.source.identity] ?? .distantPast,
                                                    analysis.source.contentTime)
        var createdValueIDs: Set<UUID> = []
        var insertedOccurrenceIDs: Set<UUID> = []
        var insertedObsoleteIDs: Set<UUID> = []
        var ordinaryValueIDs: Set<UUID> = []
        var historicalOrdinaryIDs: Set<UUID> = []
        var insertedUnlocatedIDs: Set<UUID> = []
        var retainedPayloads: Set<ProtectedPayloadReference> = []
        var addedEvidenceCount = 0
        var alerts: [AlertDecision] = []

        for detection in analysis.detections {
            let identity = OccurrenceIdentity(source: analysis.source.identity, location: detection.location)
            let marker = obsoleteMarkers[detection.fingerprint]
            if let receipt = locationReceipts[identity] {
                switch receipt {
                case .removed, .obsoleteAppearance:
                    continue
                case .occurrence(let id):
                    guard var occurrence = occurrences[id], let record = records[detection.fingerprint],
                          record.id == occurrence.valueID else { throw ContractError.conflictingValueAtLocation }
                    let oldCount = occurrence.evidence.count
                    occurrence.evidence.formUnion(detection.evidence)
                    occurrence.origins.insert(analysis.source.origin)
                    occurrences[id] = occurrence
                    addedEvidenceCount += occurrence.evidence.count - oldCount
                    updateCategories(for: detection.fingerprint, evidence: detection.evidence)
                    if marker == nil, occurrence.classification == .ordinary,
                       occurrence.review != .falsePositive, occurrence.detectorSignal == .strong,
                       let updatedRecord = records[detection.fingerprint] {
                        let key = AlertEligibilityKey(
                            fingerprint: detection.fingerprint, session: analysis.source.identity.session
                        )
                        let previouslyEligible = strongSignalReceipts[key] != nil
                        if let alert = makeEligibleDecision(for: updatedRecord, source: analysis.source) {
                            alerts.append(alert)
                        }
                        if !previouslyEligible, case .historical = analysis.source.origin.provenance {
                            historicalOrdinaryIDs.insert(id)
                            ordinaryValueIDs.insert(updatedRecord.id)
                        }
                    }
                    continue
                }
            }

            var record: InventoryRecord
            if let existing = records[detection.fingerprint] {
                record = existing
            } else {
                record = InventoryRecord(
                    id: UUID(), fingerprint: detection.fingerprint, protectedValue: nil,
                    categories: [], firstOccurrenceAt: analysis.source.contentTime,
                    lastOccurrenceAt: analysis.source.contentTime
                )
                createdValueIDs.insert(record.id)
            }
            record.firstOccurrenceAt = min(record.firstOccurrenceAt, analysis.source.contentTime)
            record.lastOccurrenceAt = max(record.lastOccurrenceAt, analysis.source.contentTime)

            // An obsolete value whose content was removed never regains value/excerpt payloads.
            if marker != nil, record.protectedValue == nil {
                let appearance = ObsoleteAppearance(
                    id: UUID(), valueID: record.id, source: analysis.source.identity,
                    occurredAt: analysis.source.contentTime, locator: analysis.source.locator,
                    provenance: analysis.source.origin.provenance
                )
                records[detection.fingerprint] = record
                assignValueLabel(detection.fingerprint)
                obsoleteAppearances[appearance.id] = appearance
                locationReceipts[identity] = .obsoleteAppearance(appearance.id)
                insertedObsoleteIDs.insert(appearance.id)
                continue
            }

            if record.protectedValue == nil {
                record.protectedValue = detection.protectedValue
                retainedPayloads.insert(detection.protectedValue)
            }
            record.categories.formUnion(detection.evidence.map(\.category))
            records[detection.fingerprint] = record
            assignValueLabel(detection.fingerprint)
            let occurrence = Occurrence(
                id: UUID(), identity: identity, valueID: record.id, source: analysis.source,
                origins: [analysis.source.origin], evidence: detection.evidence, review: .unreviewed,
                classification: marker == nil ? .ordinary : .obsolete,
                protectedExcerpt: detection.protectedExcerpt
            )
            occurrences[occurrence.id] = occurrence
            locationReceipts[identity] = .occurrence(occurrence.id)
            insertedOccurrenceIDs.insert(occurrence.id)
            if let excerpt = detection.protectedExcerpt { retainedPayloads.insert(excerpt) }
            addedEvidenceCount += detection.evidence.count
            if marker == nil {
                ordinaryValueIDs.insert(record.id)
                historicalOrdinaryIDs.insert(occurrence.id)
                if occurrence.detectorSignal == .strong,
                   let alert = makeEligibleDecision(for: record, source: analysis.source) {
                    alerts.append(alert)
                }
            } else {
                insertedObsoleteIDs.insert(occurrence.id)
            }
        }

        for finding in analysis.unlocated {
            let identity = UnlocatedIdentity(
                source: analysis.source.identity, evidence: finding.evidence, reason: finding.reason
            )
            guard unlocatedReceipts.insert(identity).inserted else { continue }
            let result = UnlocatedResult(
                id: UUID(), source: analysis.source, evidence: finding.evidence, reason: finding.reason
            )
            unlocatedResults[result.id] = result
            unlocatedLabels[result.id] = takeValueLabel()
            insertedUnlocatedIDs.insert(result.id)
        }
        analysisReceipts.insert(analysisReceipt)

        let history: HistoricalContribution?
        if case .historical(let audit) = analysis.source.origin.provenance {
            history = HistoricalContribution(
                audit: audit,
                ordinaryOccurrenceIDs: historicalOrdinaryIDs,
                obsoleteOccurrenceIDs: insertedObsoleteIDs, ordinaryValueIDs: ordinaryValueIDs
            )
        } else { history = nil }
        // A reference already retained elsewhere must not be deleted merely because this retry uses it.
        return InventoryTransition(
            outcome: .processed, createdValueIDs: createdValueIDs,
            insertedOccurrenceIDs: insertedOccurrenceIDs,
            insertedObsoleteAppearanceIDs: insertedObsoleteIDs.subtracting(insertedOccurrenceIDs),
            insertedUnlocatedIDs: insertedUnlocatedIDs, addedEvidenceCount: addedEvidenceCount,
            alerts: alerts, historicalContribution: history,
            discardedPayloadReferences: payloads.subtracting(retainedPayloads).subtracting(activePayloadReferences)
        )
    }

    private mutating func updateCategories(for fingerprint: ValueFingerprint, evidence: Set<DetectionEvidence>) {
        guard var record = records[fingerprint] else { return }
        record.categories.formUnion(evidence.map(\.category))
        records[fingerprint] = record
    }

    private mutating func makeEligibleDecision(
        for record: InventoryRecord, source: SourceRecordMetadata
    ) -> AlertDecision? {
        let eligibility = AlertEligibilityKey(fingerprint: record.fingerprint, session: source.identity.session)
        guard strongSignalReceipts[eligibility] == nil else { return nil }
        switch source.origin.provenance {
        case .live:
            let alert = AlertDecision(
                id: UUID(), valueID: record.id, eligibility: eligibility,
                categories: record.categories, delivery: .pending
            )
            alertDecisions[alert.id] = alert
            strongSignalReceipts[eligibility] = .liveAlert(alert.id)
            return alert
        case .historical(let audit):
            strongSignalReceipts[eligibility] = .historicalAudit(audit.id)
            return nil
        }
    }

    private func emptyTransition(
        outcome: AnalysisOutcome, discarded: Set<ProtectedPayloadReference>
    ) -> InventoryTransition {
        return InventoryTransition(
            outcome: outcome, createdValueIDs: [], insertedOccurrenceIDs: [],
            insertedObsoleteAppearanceIDs: [], insertedUnlocatedIDs: [], addedEvidenceCount: 0,
            alerts: [], historicalContribution: nil,
            discardedPayloadReferences: discarded.subtracting(activePayloadReferences)
        )
    }

    private var activePayloadReferences: Set<ProtectedPayloadReference> {
        Set(records.values.compactMap(\.protectedValue))
            .union(occurrences.values.compactMap(\.protectedExcerpt))
            .union(occurrences.values.compactMap { $0.source.protectedMetadata })
            .union(unlocatedResults.values.compactMap { $0.source.protectedMetadata })
    }

    private static func validate(_ snapshot: InventorySnapshot) throws {
        guard snapshot.schemaVersion == 1 else { throw ContractError.unsupportedSnapshotVersion }
        guard Set(snapshot.records.values.map(\.id)).count == snapshot.records.count else {
            throw ContractError.invalidSnapshot
        }
        let recordsByID = Dictionary(uniqueKeysWithValues: snapshot.records.values.map { ($0.id, $0) })
        for (fingerprint, record) in snapshot.records {
            guard fingerprint == record.fingerprint, fingerprint.keyedDigest.count == 32,
                  record.firstOccurrenceAt.timeIntervalSince1970.isFinite,
                  record.lastOccurrenceAt.timeIntervalSince1970.isFinite,
                  record.firstOccurrenceAt <= record.lastOccurrenceAt else { throw ContractError.invalidSnapshot }
        }
        for (id, occurrence) in snapshot.occurrences {
            guard id == occurrence.id, snapshot.obsoleteAppearances[id] == nil,
                  let record = recordsByID[occurrence.valueID], record.protectedValue != nil,
                  occurrence.identity.source == occurrence.source.identity,
                  !occurrence.evidence.isEmpty,
                  snapshot.locationReceipts[occurrence.identity] == .occurrence(id),
                  snapshot.sourceKinds[occurrence.identity.source] == occurrence.source.contentType else {
                throw ContractError.invalidSnapshot
            }
        }
        for (id, appearance) in snapshot.obsoleteAppearances {
            guard id == appearance.id, recordsByID[appearance.valueID] != nil,
                  appearance.occurredAt.timeIntervalSince1970.isFinite,
                  snapshot.locationReceipts.contains(where: {
                      $0.key.source == appearance.source && $0.value == .obsoleteAppearance(id)
                  }) else { throw ContractError.invalidSnapshot }
        }
        for (identity, receipt) in snapshot.locationReceipts {
            switch receipt {
            case .occurrence(let id):
                guard snapshot.occurrences[id]?.identity == identity else { throw ContractError.invalidSnapshot }
            case .obsoleteAppearance(let id):
                guard snapshot.obsoleteAppearances[id]?.source == identity.source else { throw ContractError.invalidSnapshot }
            case .removed: break
            }
        }
        for (fingerprint, marker) in snapshot.obsoleteMarkers {
            guard fingerprint == marker.fingerprint, marker.acknowledgedAt.timeIntervalSince1970.isFinite else {
                throw ContractError.invalidSnapshot
            }
        }
        for (id, alert) in snapshot.alertDecisions {
            guard id == alert.id, recordsByID[alert.valueID]?.fingerprint == alert.eligibility.fingerprint,
                  snapshot.strongSignalReceipts[alert.eligibility] == .liveAlert(id) else {
                throw ContractError.invalidSnapshot
            }
        }
        guard Set(snapshot.conversationLabels.values.map(\.index)).count == snapshot.conversationLabels.count,
              snapshot.conversationLabels.values.allSatisfy({ $0.index > 0 && $0.index < Int.max }) else {
            throw ContractError.invalidSnapshot
        }
        for (id, decision) in snapshot.historicalNotificationDecisions {
            guard id == decision.audit.id, decision.ordinaryValueCount > 0, decision.ordinaryOccurrenceCount > 0,
                  decision.ordinaryValueCount <= decision.ordinaryOccurrenceCount, decision.obsoleteOccurrenceCount >= 0,
                  decision.audit.end.timeIntervalSince1970.isFinite, decision.audit.start.timeIntervalSince1970.isFinite,
                  decision.audit.start == decision.audit.end.addingTimeInterval(-HistoricalAuditContext.lookback) else {
                throw ContractError.invalidSnapshot
            }
        }
        for (eligibility, receipt) in snapshot.strongSignalReceipts {
            guard snapshot.records[eligibility.fingerprint] != nil else { throw ContractError.invalidSnapshot }
            if case .liveAlert(let id) = receipt {
                guard snapshot.alertDecisions[id]?.eligibility == eligibility else { throw ContractError.invalidSnapshot }
            }
        }
        for (id, result) in snapshot.unlocatedResults {
            guard id == result.id, !result.evidence.isEmpty,
                  snapshot.unlocatedReceipts.contains(UnlocatedIdentity(
                    source: result.source.identity, evidence: result.evidence, reason: result.reason
                  )) else { throw ContractError.invalidSnapshot }
        }
        for receipt in snapshot.analysisReceipts {
            guard !receipt.detectorVersion.isEmpty, receipt.revision.keyedDigest.count == 32,
                  snapshot.sourceKinds[receipt.source] != nil else { throw ContractError.invalidSnapshot }
        }
        for (source, time) in snapshot.sourceTimes {
            guard snapshot.sourceKinds[source] != nil, time.timeIntervalSince1970.isFinite else {
                throw ContractError.invalidSnapshot
            }
        }
    }
}
