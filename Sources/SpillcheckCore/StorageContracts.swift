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
    case injectedFailure
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

    public init(
        maxEventBytes: Int = 8 * 1024 * 1024,
        maxQueueBytes: Int = 100 * 1024 * 1024,
        maxQueueAge: TimeInterval = 24 * 60 * 60,
        maxRetryCount: UInt = 3, claimDuration: TimeInterval = 180,
        maxProtectedStateBytes: Int = 64 * 1024 * 1024
    ) {
        self.maxEventBytes = maxEventBytes
        self.maxQueueBytes = maxQueueBytes
        self.maxQueueAge = maxQueueAge
        self.maxRetryCount = maxRetryCount
        self.claimDuration = claimDuration
        self.maxProtectedStateBytes = maxProtectedStateBytes
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
}

public struct StoreQueueStatistics: Equatable, Sendable {
    public let count: Int
    public let encryptedBytes: Int
    public let claimedCount: Int
    /// Recent-history work still queued, including its continuations.
    public let historicalCount: Int
}

public enum StorageFailpoint: String, Codable, Sendable {
    case beforeEnqueueCommit, afterEnqueueCommit, beforeProcessingCommit, afterProcessingCommit
}

/// Injected only by acceptance tests. The app supplies no handler and emits no SQL/content logs.
public typealias StorageFailureInjector = @Sendable (StorageFailpoint) throws -> Void
