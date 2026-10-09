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

    public init(reason: CoverageGapReason, capabilityID: UUID? = nil, interval: DateInterval? = nil) {
        self.reason = reason
        self.capabilityID = capabilityID
        self.interval = interval
    }
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

    public init(
        capability: AdapterCapability, setupVerified: Bool,
        analyzedIntervals: [DateInterval] = [], gaps: [CoverageGap] = []
    ) {
        self.capability = capability
        self.setupVerified = setupVerified
        self.analyzedIntervals = analyzedIntervals
        self.gaps = gaps
    }

    public var isConnected: Bool { setupVerified && capability.validation == .validated }
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
