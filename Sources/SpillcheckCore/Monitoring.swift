import Foundation

public enum MonitoringMode: String, Codable, Sendable { case enabled, paused }
public enum AppRunState: String, Codable, Sendable { case running, stopped }

public enum QueueActivity: Hashable, Codable, Sendable {
    case idle
    case waiting(itemCount: UInt)
    case processing(pendingCount: UInt, activeCount: UInt)
}

public enum CoverageGapReason: String, Codable, CaseIterable, Sendable {
    case unsupportedContent, unsupportedVersion, sourceUnavailable, missingTimestamp
    case queueSaturated, queueExpired, captureRejected, deliveryUncertain
    case malformedSource, incompleteMessage, scannerUnavailable, budgetExhausted
    case unresolvedCorrelation, sourceChanged, notificationBudgetExhausted
}

/// Allowlisted source labels. Unknown provider strings and payloads never enter diagnostics.
public enum CoverageSourceKind: String, Codable, Sendable {
    case codexUserMessage, codexAgentMessage, codexPlan, codexCommandExecution, codexMCPToolCall
    case codexDynamicToolCall, codexFunctionCallOutput, codexWebSearch, codexUnknownItem
    case codexHookEvent, codexHookPrompt
    case claudeUserMessage, claudeAssistantMessage, claudeQueuedPrompt, claudeAttachment
    case claudeToolResult, claudeUnknownRecord
}

public enum CoverageDiagnosticCode: String, Codable, Sendable {
    case malformedRecord, missingPayload, invalidFieldType, unknownRecordKind, unknownBlockKind
    case excludedBinaryContent, encryptedContentUnavailable, incompleteWrite, readBudgetExceeded, unavailableSource
    case changedSource, missingTimestamp, unresolvedIdentity, oversizedRecord
    case hookIdentityConflict, hookInterrupted, hookContentUnavailable, hookStorageLimit, authorityStorageLimit
    case nativeChildInputUnavailable
}

public struct CoverageGap: Hashable, Codable, Sendable {
    public let reason: CoverageGapReason
    public let capabilityID: UUID?
    public let interval: DateInterval?
    /// When this failure was observed. This is not the affected content's timestamp or period.
    /// Nil on older encrypted records; unknown content periods remain unknown.
    public let observedAt: Date?
    public let scope: CollectionScope?
    public let contentType: ContentType?
    public let operation: CollectionOperation?
    public let recovery: CoverageRecoveryReference?
    /// Only a demonstrated required-content or operation failure qualifies for a health alert.
    /// Optional fields preserve decoding of previously encrypted gap records.
    public let isRequiredFormatFailure: Bool?
    public let sourceKind: CoverageSourceKind?
    public let diagnosticCode: CoverageDiagnosticCode?
    /// A recognized binary/media payload was intentionally excluded from text analysis.
    public let excludedContent: Bool?

    public init(reason: CoverageGapReason, capabilityID: UUID? = nil, interval: DateInterval? = nil,
                scope: CollectionScope? = nil, contentType: ContentType? = nil,
                operation: CollectionOperation? = nil,
                recovery: CoverageRecoveryReference? = nil, isRequiredFormatFailure: Bool? = nil,
                sourceKind: CoverageSourceKind? = nil, diagnosticCode: CoverageDiagnosticCode? = nil,
                excludedContent: Bool? = nil, observedAt: Date? = nil) {
        self.reason = reason
        self.capabilityID = capabilityID
        self.interval = interval
        self.observedAt = observedAt
        self.scope = scope
        self.contentType = contentType
        self.operation = operation
        self.recovery = recovery
        self.isRequiredFormatFailure = isRequiredFormatFailure
        self.sourceKind = sourceKind
        self.diagnosticCode = diagnosticCode
        self.excludedContent = excludedContent
    }

    /// Intentional media exclusions do not count as missing required text analysis.
    public var requiresAnalysis: Bool { excludedContent != true }

    /// Fill only known collection context. Never manufacture a source content period from a
    /// read attempt, nor replace more specific row/item metadata supplied by the parser.
    public func contextualized(scope: CollectionScope, operation: CollectionOperation,
                               observedAt: Date) -> Self {
        .init(reason: reason, capabilityID: capabilityID, interval: interval,
            scope: self.scope ?? scope, contentType: contentType, operation: self.operation ?? operation,
            recovery: recovery, isRequiredFormatFailure: isRequiredFormatFailure,
            sourceKind: sourceKind, diagnosticCode: diagnosticCode ?? reason.defaultDiagnosticCode,
            excludedContent: excludedContent, observedAt: self.observedAt ?? observedAt)
    }
}

extension CoverageGapReason {
    public var defaultDiagnosticCode: CoverageDiagnosticCode? {
        switch self {
        case .malformedSource: .malformedRecord
        case .missingTimestamp: .missingTimestamp
        case .incompleteMessage: .incompleteWrite
        case .budgetExhausted: .readBudgetExceeded
        case .unsupportedContent: .unknownRecordKind
        case .unresolvedCorrelation: .unresolvedIdentity
        case .sourceUnavailable: .unavailableSource
        case .sourceChanged: .changedSource
        default: nil
        }
    }
}

/// Structural selection for rereading an original source. It retains no source content.
/// All native identifiers and coordinates are encrypted by ProtectedStore.
public enum CoverageRecoveryConstraint: String, Codable, Sendable {
    /// A recognized metadata item proves only that the old optional unknown-kind warning
    /// was unnecessary. It does not prove recovery of text or scanner failures at that item.
    case unclassifiedMetadata
    /// Gap-only evidence that a previously unsupported user-message block is recognized
    /// local media. It reclassifies that exact warning; it never recovers a location.
    case recognizedLocalMedia
    /// A bounded read verified this exact Claude source's native identity. This settles
    /// only its earlier availability warning, never content, scanner or delivery losses.
    case claudeSourceAvailability
}

public struct CoverageRecoveryReference: Hashable, Codable, Sendable {
    public let session: SessionIdentity?
    public let locator: SourceLocator
    public let itemID: String?
    /// Whole-source availability, separate from an omitted row/item inside that source.
    public let sourceDocumentID: UUID?
    public let contentTime: Date?
    /// Exact original selection for an authorized retry. Encrypted with the reference, never a
    /// display label or a request to search the provider's other sources.
    public let sourceURL: URL?
    public let parserContract: String
    public let constraint: CoverageRecoveryConstraint?
    /// Availability observation boundary, separate from native content time. An older
    /// queued read cannot settle a newer observation that the source is unavailable.
    public let availabilityObservedAt: Date?

    public init(session: SessionIdentity? = nil, locator: SourceLocator = .unavailable,
                itemID: String? = nil, contentTime: Date? = nil, parserContract: String,
                sourceDocumentID: UUID? = nil, sourceURL: URL? = nil,
                constraint: CoverageRecoveryConstraint? = nil, availabilityObservedAt: Date? = nil) {
        self.session = session
        self.locator = locator
        self.itemID = itemID
        self.sourceDocumentID = sourceDocumentID
        self.contentTime = contentTime
        self.sourceURL = sourceURL
        self.parserContract = parserContract
        self.constraint = constraint
        self.availabilityObservedAt = availabilityObservedAt
    }

    /// The file selected for a retry. Row locators already carry the document identity; keeping
    /// it computed preserves the existing encrypted row-recovery keys and whole-source semantics.
    public var retrySourceDocumentID: UUID? {
        if let sourceDocumentID { return sourceDocumentID }
        switch locator {
        case .transcript(let documentID, _), .transcriptByteOffset(let documentID, _): return documentID
        case .upstreamItem, .unavailable: return nil
        }
    }

    /// A complete successful reparse of this exact item/record is required. A readable sibling
    /// or a changed parser version alone never establishes recovery.
    public func identifiesSameLocation(as other: Self) -> Bool {
        guard locator == other.locator, itemID == other.itemID, sourceDocumentID == other.sourceDocumentID else { return false }
        switch locator {
        case .transcript, .transcriptByteOffset: return true
        case .upstreamItem: return session == other.session
        case .unavailable:
            // Without a document identity, an explicit file selection must not match another
            // file belonging to the same native conversation.
            if sourceDocumentID == nil, sourceURL != nil || other.sourceURL != nil {
                return session == other.session && sourceURL == other.sourceURL
            }
            return session == other.session
        }
    }
}

public enum CoverageOmissionState: String, Codable, Sendable {
    case retryable, blocked, recovered, unrecoverable
}

public struct CoverageOmission: Hashable, Codable, Sendable {
    public let id: UUID
    public let gap: CoverageGap
    public let firstObservedAt: Date
    public let state: CoverageOmissionState
    public let resolvedAt: Date?

    public var isUnresolved: Bool { state != .recovered }
    public func isEligibleForRecovery(at now: Date) -> Bool {
        guard state == .retryable || state == .blocked, let reference = gap.recovery else { return false }
        let time = reference.contentTime ?? firstObservedAt
        return time >= now.addingTimeInterval(-HistoricalAuditContext.lookback) && time <= now
    }
}

/// Incident identity and delivery survive app restarts; notification text uses controlled labels.
public struct CollectionHealthIncident: Hashable, Codable, Sendable {
    public let id: UUID
    public let scope: CollectionScope
    public let contentType: ContentType?
    public let operation: CollectionOperation?
    public let reason: CoverageGapReason
    public let firstObservedAt: Date
    public let resolvedAt: Date?
    public let delivery: AlertDeliveryState

    public init(id: UUID, scope: CollectionScope, contentType: ContentType? = nil,
                operation: CollectionOperation? = nil, reason: CoverageGapReason,
                firstObservedAt: Date, resolvedAt: Date?, delivery: AlertDeliveryState) {
        self.id = id
        self.scope = scope
        self.contentType = contentType
        self.operation = operation
        self.reason = reason
        self.firstObservedAt = firstObservedAt
        self.resolvedAt = resolvedAt
        self.delivery = delivery
    }

    public var notificationIdentifier: String { "spillcheck-health-\(id.uuidString.lowercased())" }
    public var isActive: Bool { resolvedAt == nil }
}

public enum CoverageStatus: Hashable, Codable, Sendable {
    case notConfigured
    case complete
    case partial([CoverageGap])
}

public enum CollectionPath: String, Codable, Sendable { case hook, publicHistory, versionedTranscript }
public enum CapabilityValidation: String, Codable, Sendable { case validated, unverified, unsupported }

public struct AdapterCapability: Hashable, Codable, Sendable {
    public let id: UUID
    public let provider: AgentProvider
    public let interface: AgentInterface
    public let agentVersion: String
    public let adapterVersion: String
    public let contentType: ContentType
    public let path: CollectionPath
    public let validation: CapabilityValidation
    public let canObserveActiveSession: Bool
    public let canReadHistoricalContent: Bool
    public let canonicalization: CanonicalizationBasis

    public init(
        id: UUID = UUID(), provider: AgentProvider, interface: AgentInterface,
        agentVersion: String, adapterVersion: String, contentType: ContentType,
        path: CollectionPath, validation: CapabilityValidation,
        canObserveActiveSession: Bool, canReadHistoricalContent: Bool,
        canonicalization: CanonicalizationBasis
    ) {
        self.id = id
        self.provider = provider
        self.interface = interface
        self.agentVersion = agentVersion
        self.adapterVersion = adapterVersion
        self.contentType = contentType
        self.path = path
        self.validation = validation
        self.canObserveActiveSession = canObserveActiveSession
        self.canReadHistoricalContent = canReadHistoricalContent
        self.canonicalization = canonicalization
    }
}

/// A working setup is separate from the content and intervals actually analyzed.
public struct AdapterCoverage: Hashable, Codable, Sendable {
    public let capability: AdapterCapability
    public let setupVerified: Bool
    public let analyzedIntervals: [DateInterval]
    public let gaps: [CoverageGap]
    public let assessment: CollectionAssessment?

    public init(
        capability: AdapterCapability, setupVerified: Bool,
        analyzedIntervals: [DateInterval] = [], gaps: [CoverageGap] = [], assessment: CollectionAssessment? = nil
    ) {
        self.capability = capability
        self.setupVerified = setupVerified
        self.analyzedIntervals = analyzedIntervals
        self.gaps = gaps
        self.assessment = assessment
    }

    public var isConnected: Bool { setupVerified }
}

public struct ProcessingPermit: Equatable, Sendable {
    fileprivate let generation: UUID
}

/// Lifecycle, monitoring choice, queue work and coverage never overwrite each other.
/// A permit is a generation guard, not authorization to reveal protected inventory content.
public struct MonitoringState: Equatable, Sendable {
    public private(set) var mode: MonitoringMode
    public private(set) var queueActivity: QueueActivity
    public private(set) var coverage: CoverageStatus
    public private(set) var runState: AppRunState
    private var generation = UUID()

    public init(
        mode: MonitoringMode = .enabled, queueActivity: QueueActivity = .idle,
        coverage: CoverageStatus = .notConfigured, runState: AppRunState = .running
    ) {
        self.mode = mode
        self.queueActivity = queueActivity
        self.coverage = coverage
        self.runState = runState
    }

    public var acceptsPayloads: Bool { runState == .running && mode == .enabled }

    public func processingPermit() -> ProcessingPermit? {
        acceptsPayloads ? ProcessingPermit(generation: generation) : nil
    }

    public func acceptsCommit(_ permit: ProcessingPermit) -> Bool {
        acceptsPayloads && permit.generation == generation
    }

    public mutating func pause() { mode = .paused; generation = UUID() }
    public mutating func resume() {
        guard runState == .running else { return }
        mode = .enabled
        generation = UUID()
    }
    public mutating func stop() { runState = .stopped; generation = UUID() }
    public mutating func updateQueueActivity(_ activity: QueueActivity) { queueActivity = activity }
    public mutating func updateCoverage(_ status: CoverageStatus) { coverage = status }
}
