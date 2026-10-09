import Foundation

public extension AgentProvider {
    var displayName: String { self == .codex ? "Codex" : "Claude Code" }
}

public extension AgentInterface {
    var hostLabel: String {
        switch self {
        case .standaloneCLI: "CLI"
        case .t3: "T3"
        case .desktopCode: "GUI"
        }
    }
}

public extension ContentType {
    var pluralLabel: String {
        switch self {
        case .userPrompt: "User prompts"
        case .intermediateResponse: "Intermediate responses"
        case .finalResponse: "Final responses"
        case .toolOutput: "Tool output"
        case .toolError: "Tool errors"
        }
    }
}

public extension CollectionOperation {
    var label: String {
        switch self {
        case .hookDelivery: "Hook delivery"
        case .liveRead: "Live collection"
        case .historicalRead: "History catch-up"
        }
    }
}

public extension SecretCategory {
    var displayName: String {
        switch self {
        case .apiKey: "API key"
        case .token: "Token"
        case .password: "Password"
        case .privateKey: "Private key"
        case .connectionCredential: "Connection credential"
        }
    }
}

public enum InventoryEntryID: Hashable, Sendable {
    case value(UUID)
    case obsoleteMarker(ValueFingerprint)
    case unlocated(UUID)
}

public enum InventoryEntryKind: String, Sendable { case retainedValue, obsoleteValue, rememberedObsoleteMarker, unlocatedDetection }

public enum InventoryReviewFilter: String, CaseIterable, Hashable, Sendable {
    case all, needsReview, unreviewed, confirmedSecret, falsePositive, obsolete
    public var label: String {
        switch self {
        case .all: "All reviews"
        case .needsReview: "Needs review"
        case .unreviewed: "Unreviewed"
        case .confirmedSecret: "Confirmed secret"
        case .falsePositive: "False positive"
        case .obsolete: "Obsolete"
        }
    }
}

public struct InventoryFilter: Sendable {
    public var agent: AgentProvider?
    public var session: SessionIdentity?
    public var review: InventoryReviewFilter
    public init(agent: AgentProvider? = nil, session: SessionIdentity? = nil, review: InventoryReviewFilter = .all) {
        self.agent = agent; self.session = session; self.review = review
    }
}

public struct InventoryConversation: Identifiable, Hashable, Sendable {
    /// This identity is for filtering/actions, and must never be interpolated into masked text.
    public let id: SessionIdentity
    public let provider: AgentProvider
    public let label: MaskedConversationLabel
}

public struct InventoryEntry: Identifiable, Hashable, Sendable {
    public let id: InventoryEntryID
    public let kind: InventoryEntryKind
    /// App-generated number, such as "L-14". Absent only for entries restored without one.
    public let label: MaskedValueLabel?
    public let valueID: UUID?
    public let fingerprint: ValueFingerprint?
    public let categoryLabels: [String]
    public let agentLabels: [String]
    public let occurrenceCount: Int
    public let observedAt: Date
    public let reviewLabel: String
    public let reviewStates: Set<InventoryReviewFilter>
    public let detectorSignal: SignalStrength?
    public let acknowledgement: ObsoleteAcknowledgement?
    public let acknowledgedAt: Date?
    public let protectedValue: ProtectedPayloadReference?
    /// Evidence from every retained occurrence, for naming and explanation.
    public let evidence: [DetectionEvidence]
    public var canRevealRetainedValue: Bool { protectedValue != nil }
    public var valueKind: ValueKind { ValueKind(evidence: evidence) }
}

/// Why an appearance did or did not produce its own notification.
public enum OccurrenceAlertState: Hashable, Sendable {
    /// The first strong appearance of this value in its conversation.
    case alerted(AlertDeliveryState)
    case repeatInConversation
    case awaitingReview
    /// Recent-history catch-up reports a masked summary instead of individual alerts.
    case catchUp
    case obsolete
    case unlocated
    case notAlerted
}

public struct InventoryOccurrencePresentation: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let source: SourceIdentity
    public let interface: AgentInterface?
    public let contentType: ContentType?
    public let observedAt: Date
    public let conversation: InventoryConversation
    public let review: OccurrenceReview?
    public let classification: AppearanceClassification
    public let evidence: [DetectionEvidence]
    public let locator: SourceLocator
    public let protectedExcerpt: ProtectedPayloadReference?
    public let protectedMetadata: ProtectedPayloadReference?
    public let locationFailure: LocationFailure?
    public let alert: OccurrenceAlertState
    public var metadataOnly: Bool { review == nil && classification == .obsolete }
}

/// A masked projection contains controlled labels and action identities, with no source text.
public struct InventoryPresentation: Sendable {
    public let conversations: [InventoryConversation]
    private let allEntries: [InventoryEntry]
    private let appearances: [InventoryEntryID: [InventoryOccurrencePresentation]]

    public init(snapshot: InventorySnapshot) throws {
        let ledger = try InventoryLedger(snapshot: snapshot)
        let sessions = Set(snapshot.occurrences.values.map { $0.source.identity.session })
            .union(snapshot.obsoleteAppearances.values.map { $0.source.session })
            .union(snapshot.unlocatedResults.values.map { $0.source.identity.session })
            .sorted { ($0.provider.rawValue, $0.profileID, $0.sessionID) < ($1.provider.rawValue, $1.profileID, $1.sessionID) }
        guard sessions.allSatisfy({ ledger.conversationLabels[$0] != nil }) else { throw ContractError.invalidSnapshot }
        conversations = sessions.map {
            InventoryConversation(id: $0, provider: $0.provider, label: ledger.conversationLabels[$0]!)
        }.sorted { $0.label.index < $1.label.index }
        let conversationMap = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        var details: [InventoryEntryID: [InventoryOccurrencePresentation]] = [:]
        var entries: [InventoryEntry] = []
        for record in snapshot.records.values {
            guard let summary = ledger.summary(for: record.fingerprint) else { continue }
            let id = InventoryEntryID.value(record.id)
            let occurrences = snapshot.occurrences.values.filter { $0.valueID == record.id }
            let obsolete = snapshot.obsoleteAppearances.values.filter { $0.valueID == record.id }
            let alerts = Self.alertStates(occurrences, decisions: snapshot.alertDecisions.values.filter { $0.valueID == record.id })
            var states = Set(occurrences.map { Self.filter($0.review) })
            if summary.reviewCounts.needsReview > 0 { states.insert(.needsReview) }
            if summary.obsoleteMarker != nil || summary.obsoleteAppearanceCount > 0 { states.insert(.obsolete) }
            let providers = Set(occurrences.map { $0.source.identity.session.provider })
                .union(obsolete.map { $0.source.session.provider })
            let label = summary.obsoleteMarker.map { $0.acknowledgement == .rotated ? "Acknowledged rotated" : "Acknowledged revoked" }
                ?? (summary.reviewCounts.total == 0 ? "Obsolete value"
                    : summary.reviewCounts.needsReview > 0 ? "Needs review"
                    : summary.reviewCounts.confirmed == summary.reviewCounts.total ? "Confirmed secret"
                    : summary.reviewCounts.falsePositive == summary.reviewCounts.total ? "False positive"
                    : summary.reviewCounts.unreviewed == summary.reviewCounts.total ? "Unreviewed" : "Mixed reviews")
            entries.append(InventoryEntry(id: id, kind: summary.obsoleteMarker != nil || summary.obsoleteAppearanceCount > 0 ? .obsoleteValue : .retainedValue,
                label: snapshot.valueLabels[record.fingerprint], valueID: record.id, fingerprint: record.fingerprint, categoryLabels: record.categories.sorted { $0.rawValue < $1.rawValue }.map(\.displayName),
                agentLabels: providers.sorted { $0.rawValue < $1.rawValue }.map(\.displayName), occurrenceCount: summary.occurrenceCount,
                observedAt: record.lastOccurrenceAt, reviewLabel: label, reviewStates: states, detectorSignal: summary.detectorSignal,
                acknowledgement: summary.obsoleteMarker?.acknowledgement, acknowledgedAt: summary.obsoleteMarker?.acknowledgedAt,
                protectedValue: record.protectedValue,
                evidence: Self.evidence(occurrences.reduce(into: Set<DetectionEvidence>()) { $0.formUnion($1.evidence) })))
            details[id] = occurrences.compactMap { occurrence in
                guard let conversation = conversationMap[occurrence.source.identity.session] else { return nil }
                return InventoryOccurrencePresentation(id: occurrence.id, source: occurrence.source.identity,
                    interface: occurrence.source.origin.interface, contentType: occurrence.source.contentType, observedAt: occurrence.source.contentTime,
                    conversation: conversation, review: occurrence.review, classification: occurrence.classification,
                    evidence: Self.evidence(occurrence.evidence), locator: occurrence.source.locator,
                    protectedExcerpt: occurrence.protectedExcerpt, protectedMetadata: occurrence.source.protectedMetadata, locationFailure: nil,
                    alert: alerts[occurrence.id] ?? .notAlerted)
            } + obsolete.compactMap { occurrence in
                guard let conversation = conversationMap[occurrence.source.session] else { return nil }
                return InventoryOccurrencePresentation(id: occurrence.id, source: occurrence.source, interface: nil,
                    contentType: snapshot.sourceKinds[occurrence.source], observedAt: occurrence.occurredAt, conversation: conversation,
                    review: nil, classification: .obsolete, evidence: [], locator: occurrence.locator,
                    protectedExcerpt: nil, protectedMetadata: nil, locationFailure: nil, alert: .obsolete)
            }
        }
        for marker in snapshot.obsoleteMarkers.values where snapshot.records[marker.fingerprint] == nil {
            entries.append(InventoryEntry(id: .obsoleteMarker(marker.fingerprint), kind: .rememberedObsoleteMarker,
                label: snapshot.valueLabels[marker.fingerprint], valueID: nil, fingerprint: marker.fingerprint, categoryLabels: [], agentLabels: [], occurrenceCount: 0,
                observedAt: marker.acknowledgedAt, reviewLabel: marker.acknowledgement == .rotated ? "Acknowledged rotated" : "Acknowledged revoked",
                reviewStates: [.obsolete], detectorSignal: nil, acknowledgement: marker.acknowledgement,
                acknowledgedAt: marker.acknowledgedAt, protectedValue: nil,
                evidence: []))
        }
        for result in snapshot.unlocatedResults.values {
            guard let conversation = conversationMap[result.source.identity.session] else { continue }
            let id = InventoryEntryID.unlocated(result.id)
            entries.append(InventoryEntry(id: id, kind: .unlocatedDetection, label: snapshot.unlocatedLabels[result.id],
                valueID: nil, fingerprint: nil,
                categoryLabels: Set(result.evidence.map(\.category)).sorted { $0.rawValue < $1.rawValue }.map(\.displayName),
                agentLabels: [result.source.identity.session.provider.displayName], occurrenceCount: 0,
                observedAt: result.source.contentTime, reviewLabel: "Value not located", reviewStates: [.needsReview],
                detectorSignal: result.evidence.contains { $0.signal == .strong } ? .strong : .ambiguous,
                acknowledgement: nil, acknowledgedAt: nil, protectedValue: nil, evidence: Self.evidence(result.evidence)))
            details[id] = [InventoryOccurrencePresentation(id: result.id, source: result.source.identity, interface: result.source.origin.interface,
                contentType: result.source.contentType, observedAt: result.source.contentTime, conversation: conversation,
                review: nil, classification: .ordinary, evidence: Self.evidence(result.evidence), locator: result.source.locator,
                protectedExcerpt: nil, protectedMetadata: result.source.protectedMetadata, locationFailure: result.reason,
                alert: .unlocated)]
        }
        appearances = details.mapValues { $0.sorted { $0.observedAt > $1.observedAt } }
        allEntries = entries.sorted { $0.observedAt > $1.observedAt }
    }

    public func entries(matching filter: InventoryFilter = InventoryFilter()) -> [InventoryEntry] {
        allEntries.filter { entry in
            let detail = appearances[entry.id] ?? []
            if detail.isEmpty {
                return filter.agent == nil && filter.session == nil && (filter.review == .all || entry.reviewStates.contains(filter.review))
            }
            return detail.contains { occurrence in
                guard (filter.agent == nil || occurrence.source.session.provider == filter.agent),
                      (filter.session == nil || occurrence.source.session == filter.session) else { return false }
                switch filter.review {
                case .all: return true
                case .obsolete: return entry.acknowledgement != nil || occurrence.classification == .obsolete
                case .needsReview: return occurrence.locationFailure != nil || occurrence.review == .unreviewed && !occurrence.evidence.contains { $0.signal == .strong }
                case .unreviewed: return occurrence.review == .unreviewed
                case .confirmedSecret: return occurrence.review == .confirmedSecret
                case .falsePositive: return occurrence.review == .falsePositive
                }
            }
        }
    }

    public func occurrences(for entry: InventoryEntryID) -> [InventoryOccurrencePresentation] { appearances[entry] ?? [] }
    public func entry(_ id: InventoryEntryID) -> InventoryEntry? { allEntries.first { $0.id == id } }
    private static func filter(_ state: OccurrenceReview) -> InventoryReviewFilter {
        switch state { case .unreviewed: .unreviewed; case .confirmedSecret: .confirmedSecret; case .falsePositive: .falsePositive }
    }
    /// Alert decisions are per value and conversation. The earliest eligible live appearance carries it.
    private static func alertStates(_ occurrences: [Occurrence], decisions: [AlertDecision]) -> [UUID: OccurrenceAlertState] {
        let delivery = Dictionary(decisions.map { ($0.eligibility.session, $0.delivery) }, uniquingKeysWith: { first, _ in first })
        var carrier: [SessionIdentity: UUID] = [:]
        var states: [UUID: OccurrenceAlertState] = [:]
        for occurrence in occurrences.sorted(by: { ($0.source.contentTime, $0.id.uuidString) < ($1.source.contentTime, $1.id.uuidString) }) {
            let session = occurrence.source.identity.session
            if occurrence.classification == .obsolete { states[occurrence.id] = .obsolete; continue }
            if case .historical = occurrence.source.origin.provenance { states[occurrence.id] = .catchUp; continue }
            if occurrence.detectorSignal == .ambiguous { states[occurrence.id] = .awaitingReview; continue }
            guard let state = delivery[session] else { states[occurrence.id] = .notAlerted; continue }
            if carrier[session] == nil, occurrence.review != .falsePositive {
                carrier[session] = occurrence.id
                states[occurrence.id] = .alerted(state)
            } else {
                states[occurrence.id] = .repeatInConversation
            }
        }
        return states
    }

    private static func evidence(_ values: Set<DetectionEvidence>) -> [DetectionEvidence] {
        values.sorted { ($0.rule.id, $0.rule.version, $0.category.rawValue, $0.reason.rawValue) < ($1.rule.id, $1.rule.version, $1.category.rawValue, $1.reason.rawValue) }
    }
}
