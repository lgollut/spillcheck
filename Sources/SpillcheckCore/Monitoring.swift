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

public struct CoverageGap: Hashable, Codable, Sendable {
    public let reason: CoverageGapReason
    public let capabilityID: UUID?
    public let interval: DateInterval?
    public let scope: CollectionScope?
    public let contentType: ContentType?
    public let operation: CollectionOperation?
    public let recovery: CoverageRecoveryReference?
    /// Only a demonstrated required-content or operation failure qualifies for a health alert.
    /// Optional fields preserve decoding of previously encrypted gap records.
    public let isRequiredFormatFailure: Bool?

    public init(reason: CoverageGapReason, capabilityID: UUID? = nil, interval: DateInterval? = nil,
                scope: CollectionScope? = nil, contentType: ContentType? = nil,
                operation: CollectionOperation? = nil,
                recovery: CoverageRecoveryReference? = nil, isRequiredFormatFailure: Bool? = nil) {
        self.reason = reason
        self.capabilityID = capabilityID
        self.interval = interval
        self.scope = scope
        self.contentType = contentType
        self.operation = operation
        self.recovery = recovery
        self.isRequiredFormatFailure = isRequiredFormatFailure
    }
}

/// Structural selection for rereading an original source. It retains no source content.
/// All native identifiers and coordinates are encrypted by ProtectedStore.
public struct CoverageRecoveryReference: Hashable, Codable, Sendable {
    public let session: SessionIdentity?
    public let locator: SourceLocator
    public let itemID: String?
    public let contentTime: Date?
    public let parserContract: String

    public init(session: SessionIdentity? = nil, locator: SourceLocator = .unavailable,
                itemID: String? = nil, contentTime: Date? = nil, parserContract: String) {
        self.session = session
        self.locator = locator
        self.itemID = itemID
        self.contentTime = contentTime
        self.parserContract = parserContract
    }

    /// A complete successful reparse of this exact item/record is required. A readable sibling
    /// or a changed parser version alone never establishes recovery.
    public func identifiesSameLocation(as other: Self) -> Bool {
        guard locator == other.locator, itemID == other.itemID else { return false }
        switch locator {
        case .transcript, .transcriptByteOffset: return true
        case .upstreamItem, .unavailable: return session == other.session
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
