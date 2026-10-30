import Foundation

public protocol BackgroundStoreCryptography: Sendable {
    var manifest: ProtectionManifest { get async }
    func sealBackground(_ plaintext: Data, binding: PayloadBinding) async throws -> ProtectedPayload
    func openBackground(_ payload: ProtectedPayload, binding: PayloadBinding) async throws -> Data
    func revision(canonicalBytes: Data) async throws -> ContentRevision
}

public enum StorageError: Error, Equatable, Sendable {
    case unsafeStorageLocation, databaseUnavailable, manifestMissing, manifestMismatch
    case corruptProtectedState, protectionUnavailable, payloadMissing, invalidPayload
    case monitoringPaused, staleProcessingPermit, stateChanged, staleClaim
    case captureTooLarge, queueSaturated, expiredCapture, invalidTime, stateTooLarge
    case capacityExceeded(StorageCapacityResource)
    case injectedFailure
}

/// Allowlisted quota names, never an upstream session or source identifier.
public enum StorageCapacityResource: String, Codable, Sendable {
    case sourceAuthorities, codexHookContentSlots
}

public enum StoreCapacityState: String, Codable, Sendable {
    case available, nearCapacity, full, overLimit
}

/// Whole-table usage only. This snapshot contains no content, identities or keyed revisions.
/// Encrypted bytes include each persisted envelope, not SQLite file/page overhead.
public struct StoreCapacityUsage: Equatable, Codable, Sendable {
    public let count: Int
    public let encryptedBytes: Int
    public let countLimit: Int
    public let encryptedBytesLimit: Int

    public init(count: Int, encryptedBytes: Int, countLimit: Int, encryptedBytesLimit: Int) {
        self.count = max(0, count)
        self.encryptedBytes = max(0, encryptedBytes)
        self.countLimit = max(0, countLimit)
        self.encryptedBytesLimit = max(0, encryptedBytesLimit)
    }

    public var remainingCount: Int { max(0, countLimit - count) }
    public var remainingEncryptedBytes: Int { max(0, encryptedBytesLimit - encryptedBytes) }
    public var countState: StoreCapacityState { Self.state(used: count, limit: countLimit) }
    public var bytesState: StoreCapacityState { Self.state(used: encryptedBytes, limit: encryptedBytesLimit) }
    public var state: StoreCapacityState {
        let states = [countState, bytesState]
        if states.contains(.overLimit) { return .overLimit }
        if states.contains(.full) { return .full }
        if states.contains(.nearCapacity) { return .nearCapacity }
        return .available
    }

    private static func state(used: Int, limit: Int) -> StoreCapacityState {
        if used > limit { return .overLimit }
        if used == limit { return .full }
        // ceil(4 * limit / 5), without multiplication overflow or floating-point rounding.
        return used >= limit - limit / 5 ? .nearCapacity : .available
    }
}

public struct StoreCapacitySnapshot: Equatable, Codable, Sendable {
    public let sourceAuthorities: StoreCapacityUsage
    public let codexHookContentSlots: StoreCapacityUsage

    public init(sourceAuthorities: StoreCapacityUsage, codexHookContentSlots: StoreCapacityUsage) {
        self.sourceAuthorities = sourceAuthorities
        self.codexHookContentSlots = codexHookContentSlots
    }
}

public struct StoreProtectionProbe: Sendable {
    public let state: StoreProtectionState
    public let manifest: ProtectionManifest?
}

public struct StoreLimits: Sendable {
    public let maxEventBytes: Int
    public let maxQueueBytes: Int
    public let maxQueueAge: TimeInterval
    public let maxRetryCount: UInt
    public let claimDuration: TimeInterval
    public let maxProtectedStateBytes: Int
    public let maxSuccessfulWorkRecords: Int
    public let maxHookContentSlots: Int
    public let maxSourceAuthorities: Int

    public init(
        maxEventBytes: Int = 8 * 1024 * 1024,
        maxQueueBytes: Int = 100 * 1024 * 1024,
        maxQueueAge: TimeInterval = 24 * 60 * 60,
        maxRetryCount: UInt = 3, claimDuration: TimeInterval = 180,
        maxProtectedStateBytes: Int = 64 * 1024 * 1024, maxSuccessfulWorkRecords: Int = 2048,
        maxHookContentSlots: Int = 16_384, maxSourceAuthorities: Int = 16_384
    ) {
        self.maxEventBytes = maxEventBytes
        self.maxQueueBytes = maxQueueBytes
        self.maxQueueAge = maxQueueAge
        self.maxRetryCount = maxRetryCount
        self.claimDuration = claimDuration
        self.maxProtectedStateBytes = maxProtectedStateBytes
        self.maxSuccessfulWorkRecords = max(1, maxSuccessfulWorkRecords)
        self.maxHookContentSlots = maxHookContentSlots
        self.maxSourceAuthorities = maxSourceAuthorities
    }
}

public struct StoreProcessingPermit: Equatable, Sendable {
    let generation: UUID
}

public enum QueueInsertion: Equatable, Sendable {
    case inserted(UUID), alreadyQueued(UUID), alreadyProcessed(UUID)
    /// Returning one of these cases means the database transaction is committed. Only then ACK.
    public var isDurable: Bool { true }
}

public struct PendingCapture: Sendable {
    public let id: UUID
    public let claimID: UUID
    public let capturedAt: Date
    public let expiresAt: Date
    public let retryCount: UInt
    public let encryptedPayload: ProtectedPayload
    /// Recent-history work rather than a live capture.
    public let isHistorical: Bool
}

public struct StoreQueueStatistics: Equatable, Sendable {
    public let count: Int
    public let encryptedBytes: Int
    public let claimedCount: Int
    /// Recent-history work still queued, including its continuations.
    public let historicalCount: Int

    public init(count: Int, encryptedBytes: Int, claimedCount: Int, historicalCount: Int) {
        self.count = count
        self.encryptedBytes = encryptedBytes
        self.claimedCount = claimedCount
        self.historicalCount = historicalCount
    }
}

public enum StorageFailpoint: String, Codable, Sendable {
    case beforeEnqueueCommit, afterEnqueueCommit, beforeProcessingCommit, afterProcessingCommit
}

/// Injected only by acceptance tests. The app supplies no handler and emits no SQL/content logs.
public typealias StorageFailureInjector = @Sendable (StorageFailpoint) throws -> Void
