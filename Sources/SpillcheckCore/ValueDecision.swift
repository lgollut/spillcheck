import Foundation

/// The user's decision about an exact value. It covers every appearance of that value, including
/// later ones, until the user changes it. Rotation and revocation remain `ObsoleteAcknowledgement`s
/// on an `ObsoleteValueMarker`, because ADR 0004 retains later obsolete appearances differently.
public enum ValueDecision: String, Codable, CaseIterable, Sendable {
    /// A real credential the user still has to change at its service. It stays live: a later
    /// appearance in another conversation alerts as an undecided value's would.
    case needsRotation
    /// A credential that only works in tests or local development.
    case testOrDevelopment
    /// Not a credential at all.
    case notSecret
    /// A real credential the user keeps as it is.
    case acceptedRisk

    /// Later appearances of a dismissed value are recorded and counted, without alerts or review.
    public var dismissesValue: Bool { self != .needsRotation }
}

/// Like the obsolete marker, a decision is keyed by the value's keyed fingerprint and survives
/// removal of the retained content. It holds no value, excerpt or occurrence history.
public struct ValueDecisionRecord: Hashable, Codable, Sendable {
    public let fingerprint: ValueFingerprint
    public let decision: ValueDecision
    public let decidedAt: Date
    /// The value's appearances when it was decided, so later ones can be counted. Removing the
    /// retained content resets it, because those appearances are gone.
    public internal(set) var appearancesAtDecision: Int
}

/// A decision about a detection whose exact value wasn't located. With no value to recognize
/// again, it covers that detection only.
public struct UnlocatedDecisionRecord: Hashable, Codable, Sendable {
    public let resultID: UUID
    public let decision: ValueDecision
    public let decidedAt: Date
}

extension ValueDecisionRecord {
    /// Decisions implied by the per-appearance reviews recorded before review belonged to the
    /// value. Any appearance confirmed as a secret means the value needs rotation. A value whose
    /// reviewed appearances were all false positives, with none left unreviewed, is not a secret.
    /// Anything else stays undecided, and values acknowledged rotated or revoked keep that state.
    /// The review time wasn't recorded, so the value's latest appearance stands in for it.
    static func derived(
        records: [ValueFingerprint: InventoryRecord], occurrences: [UUID: Occurrence],
        obsoleteAppearances: [UUID: ObsoleteAppearance], obsoleteMarkers: [ValueFingerprint: ObsoleteValueMarker]
    ) -> [ValueFingerprint: ValueDecisionRecord] {
        var appearances: [UUID: Int] = [:]
        var reviews: [UUID: Set<OccurrenceReview>] = [:]
        for occurrence in occurrences.values {
            appearances[occurrence.valueID, default: 0] += 1
            reviews[occurrence.valueID, default: []].insert(occurrence.review)
        }
        for appearance in obsoleteAppearances.values { appearances[appearance.valueID, default: 0] += 1 }
        var decisions: [ValueFingerprint: ValueDecisionRecord] = [:]
        for (fingerprint, record) in records where obsoleteMarkers[fingerprint] == nil {
            let states = reviews[record.id] ?? []
            let decision: ValueDecision
            if states.contains(.confirmedSecret) {
                decision = .needsRotation
            } else if states == [.falsePositive] {
                decision = .notSecret
            } else {
                continue
            }
            decisions[fingerprint] = ValueDecisionRecord(
                fingerprint: fingerprint, decision: decision, decidedAt: record.lastOccurrenceAt,
                appearancesAtDecision: appearances[record.id] ?? 0
            )
        }
        return decisions
    }
}

/// A change to what the user decided about a value. Several apply in order, as one write.
public enum InventoryDecisionChange: Hashable, Sendable {
    case decide(ValueFingerprint, ValueDecision?)
    case decideUnlocated(UUID, ValueDecision?)
    case acknowledge(ValueFingerprint, ObsoleteAcknowledgement)
    case forgetMarker(ValueFingerprint)

    /// The changes that put back what `snapshot` recorded before this change, so it can be undone.
    public func inverse(in snapshot: InventorySnapshot) -> [InventoryDecisionChange] {
        switch self {
        case .decide(let fingerprint, _):
            return [.decide(fingerprint, snapshot.valueDecisions[fingerprint]?.decision)]
        case .decideUnlocated(let resultID, _):
            return [.decideUnlocated(resultID, snapshot.unlocatedDecisions[resultID]?.decision)]
        case .acknowledge(let fingerprint, _):
            // Acknowledging replaced the decision, so undoing restores it after forgetting the marker.
            return [.forgetMarker(fingerprint)]
                + (snapshot.valueDecisions[fingerprint].map { [.decide(fingerprint, $0.decision)] } ?? [])
        case .forgetMarker(let fingerprint):
            return snapshot.obsoleteMarkers[fingerprint].map { [.acknowledge(fingerprint, $0.acknowledgement)] } ?? []
        }
    }

    /// The inverse of several changes, undone last first.
    public static func inverse(of changes: [Self], in snapshot: InventorySnapshot) -> [Self] {
        changes.reversed().flatMap { $0.inverse(in: snapshot) }
    }
}

extension InventoryLedger {
    public mutating func apply(_ change: InventoryDecisionChange, at time: Date) throws {
        switch change {
        case .decide(let fingerprint, let decision): try decide(fingerprint, as: decision, at: time)
        case .decideUnlocated(let resultID, let decision): try decide(unlocated: resultID, as: decision, at: time)
        case .acknowledge(let fingerprint, let acknowledgement): try acknowledgeObsolete(fingerprint, as: acknowledgement, at: time)
        case .forgetMarker(let fingerprint): try forgetObsoleteMarker(fingerprint)
        }
    }
}
