import Foundation

public enum SignalStrength: String, Codable, Sendable { case ambiguous, strong }
public enum OccurrenceReview: String, Codable, Sendable { case unreviewed, confirmedSecret, falsePositive }
public enum AppearanceClassification: String, Codable, Sendable { case ordinary, obsolete }
public enum SecretCategory: String, Codable, CaseIterable, Sendable {
    case apiKey, token, password, privateKey, connectionCredential

    public var maskedLabel: String {
        switch self {
        case .apiKey: "API key ••••"
        case .token: "Token ••••"
        case .password: "Password ••••"
        case .privateKey: "Private key ••••"
        case .connectionCredential: "Connection credential ••••"
        }
    }
}

public enum DetectionReason: String, Codable, Sendable {
    case recognizedFormat, privateKeyBlock, credentialField, entropy, connectionString, localRule
}

/// IDs and versions come from app-controlled rule definitions, never from instructions in content.
public struct RuleIdentity: Hashable, Codable, Sendable {
    public let id: String
    public let version: String

    public init(id: String, version: String) throws {
        guard !id.isEmpty, !version.isEmpty else { throw ContractError.emptyIdentity }
        self.id = id
        self.version = version
    }
}

public struct DetectionEvidence: Hashable, Codable, Sendable {
    public let rule: RuleIdentity
    public let signal: SignalStrength
    public let reason: DetectionReason
    public let category: SecretCategory

    public init(rule: RuleIdentity, signal: SignalStrength, reason: DetectionReason, category: SecretCategory) {
        self.rule = rule
        self.signal = signal
        self.reason = reason
        self.category = category
    }
}

public struct OccurrenceIdentity: Hashable, Codable, Sendable {
    public let source: SourceIdentity
    public let location: CanonicalLocation

    public init(source: SourceIdentity, location: CanonicalLocation) {
        self.source = source
        self.location = location
    }
}

/// Prepared input drops the raw value after exact extraction, keyed hashing and protection.
/// Source/revision binding prevents a verified extraction from being attached to another item.
public struct LocatedDetection: Sendable {
    public let fingerprint: ValueFingerprint
    public let location: CanonicalLocation
    public let evidence: Set<DetectionEvidence>
    public let protectedValue: ProtectedPayloadReference
    public let protectedExcerpt: ProtectedPayloadReference?
    fileprivate let sourceIdentity: SourceIdentity
    fileprivate let sourceRevision: ContentRevision

    public init(
        extraction: ExactExtraction, in source: SourceRecord, fingerprint: ValueFingerprint,
        evidence: Set<DetectionEvidence>, protectedValue: ProtectedPayloadReference,
        protectedExcerpt: ProtectedPayloadReference? = nil
    ) throws {
        guard !evidence.isEmpty else { throw ContractError.missingEvidence }
        try extraction.validate(in: source)
        self.fingerprint = fingerprint
        self.location = extraction.location
        self.evidence = evidence
        self.protectedValue = protectedValue
        self.protectedExcerpt = protectedExcerpt
        self.sourceIdentity = source.metadata.identity
        self.sourceRevision = source.revision
    }
}

public enum LocationFailure: String, Codable, Sendable {
    case unavailableRange, ambiguousRange, invalidEncoding, scannerReportMismatch
}

/// An unlocated result has evidence and a source, never a guessed value or a reveal payload.
public struct UnlocatedDetection: Hashable, Sendable {
    public let evidence: Set<DetectionEvidence>
    public let reason: LocationFailure

    public init(evidence: Set<DetectionEvidence>, reason: LocationFailure) throws {
        guard !evidence.isEmpty else { throw ContractError.missingEvidence }
        self.evidence = evidence
        self.reason = reason
    }
}

public struct SourceAnalysis: Sendable {
    public let source: SourceRecordMetadata
    public let revision: ContentRevision
    public let detectorVersion: String
    public let detections: [LocatedDetection]
    public let unlocated: [UnlocatedDetection]

    public init(
        source: SourceRecord, detectorVersion: String,
        detections: [LocatedDetection], unlocated: [UnlocatedDetection] = []
    ) throws {
        guard !detectorVersion.isEmpty else { throw ContractError.emptyIdentity }
        guard detections.allSatisfy({
            $0.sourceIdentity == source.metadata.identity && $0.sourceRevision == source.revision
        }) else { throw ContractError.conflictingSourceMetadata }
        self.source = source.metadata
        self.revision = source.revision
        self.detectorVersion = detectorVersion
        self.detections = detections
        self.unlocated = unlocated
    }
}

public struct Occurrence: Hashable, Codable, Sendable {
    public let id: UUID
    public let identity: OccurrenceIdentity
    public let valueID: UUID
    public let source: SourceRecordMetadata
    public internal(set) var origins: Set<SourceOrigin>
    public internal(set) var evidence: Set<DetectionEvidence>
    public internal(set) var review: OccurrenceReview
    /// Classification when this appearance was accepted, independent of later review or forgetting.
    public let classification: AppearanceClassification
    public let protectedExcerpt: ProtectedPayloadReference?

    public var detectorSignal: SignalStrength {
        evidence.contains(where: { $0.signal == .strong }) ? .strong : .ambiguous
    }
    public var needsReview: Bool { review == .unreviewed && detectorSignal == .ambiguous }
}

public struct UnlocatedResult: Hashable, Codable, Sendable {
    public let id: UUID
    public let source: SourceRecordMetadata
    public let evidence: Set<DetectionEvidence>
    public let reason: LocationFailure
}

/// Contains only source/time/controlled label after obsolete content has been removed.
/// The independent source receipt carries replay coordinates; this record has no evidence or excerpt.
public struct ObsoleteAppearance: Hashable, Codable, Sendable {
    public let id: UUID
    public let valueID: UUID
    public let source: SourceIdentity
    public let occurredAt: Date
    public let locator: SourceLocator
    public let provenance: SourceProvenance
    public var label: String { "Obsolete value" }
}
