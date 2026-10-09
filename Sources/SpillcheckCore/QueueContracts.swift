import Foundation

/// Persisted with the encrypted capture so a restart does not change live alert provenance.
public struct LiveCaptureScope: Codable, Hashable, Sendable {
    public let startedAt: Date
    public let catchupReason: AuditReason
    public let catchupAuditID: UUID?
    public init(startedAt: Date, catchupReason: AuditReason = .restart, catchupAuditID: UUID = UUID()) throws {
        guard startedAt.timeIntervalSince1970.isFinite else { throw ContractError.invalidTime }
        self.startedAt = startedAt
        self.catchupReason = catchupReason
        self.catchupAuditID = catchupAuditID
    }
}

public struct OpenedCapture: Sendable {
    public let body: Data
    public let scope: LiveCaptureScope?
    public let historicalAudit: HistoricalAuditContext?
}

enum CapturedWorkCodec {
    private struct Header: Codable {
        let schemaVersion: Int
        let scope: LiveCaptureScope?
        let historicalAudit: HistoricalAuditContext?
    }
    private static let magic = Data([0x4c, 0x52, 0x51, 0x01])
    static func encode(_ body: Data, scope: LiveCaptureScope?, historicalAudit: HistoricalAuditContext? = nil) throws -> Data {
        guard scope != nil || historicalAudit != nil else { return body }
        if let scope, !scope.startedAt.timeIntervalSince1970.isFinite { throw StorageError.invalidTime }
        if let audit = historicalAudit {
            guard audit == (try HistoricalAuditContext(id: audit.id, reason: audit.reason, endingAt: audit.end)) else {
                throw StorageError.invalidTime
            }
        }
        let header = try JSONEncoder().encode(Header(schemaVersion: 2, scope: scope, historicalAudit: historicalAudit))
        guard header.count <= 2048 else { throw StorageError.invalidPayload }
        var size = UInt32(header.count).bigEndian
        var result = magic
        result.append(withUnsafeBytes(of: &size) { Data($0) })
        result.append(header)
        result.append(body)
        return result
    }
    static func decode(_ data: Data) throws -> OpenedCapture {
        guard data.prefix(4) == magic else { return OpenedCapture(body: data, scope: nil, historicalAudit: nil) }
        guard data.count > 8 else { throw StorageError.invalidPayload }
        let count = data[4..<8].reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= 2048, 8 + count < data.count else { throw StorageError.invalidPayload }
        let header = try JSONDecoder().decode(Header.self, from: data.subdata(in: 8..<(8 + count)))
        guard [1, 2].contains(header.schemaVersion), header.scope != nil || header.historicalAudit != nil else {
            throw StorageError.invalidPayload
        }
        if let scope = header.scope, !scope.startedAt.timeIntervalSince1970.isFinite { throw StorageError.invalidTime }
        if let audit = header.historicalAudit,
           audit != (try HistoricalAuditContext(id: audit.id, reason: audit.reason, endingAt: audit.end)) {
            throw StorageError.invalidTime
        }
        return OpenedCapture(body: data.subdata(in: (8 + count)..<data.count), scope: header.scope,
                             historicalAudit: header.historicalAudit)
    }
}

/// Revision alone is not identity: identical payloads in distinct source items are separate work.
public struct IngestionIdentity: Hashable, Codable, Sendable {
    public let source: SourceIdentity
    public let revision: ContentRevision

    public init(source: SourceIdentity, revision: ContentRevision) {
        self.source = source
        self.revision = revision
    }
}

public enum QueuedProcessingState: Hashable, Codable, Sendable {
    case pending
    case claimed(leaseID: UUID, expiresAt: Date)
    case retryEligible
}

/// A storage contract only. Durable encrypted insertion, leases and retries belong to milestone 2.
public struct QueuedEvent: Hashable, Codable, Sendable {
    public let id: UUID
    public let identity: IngestionIdentity
    public let encryptedPayload: ProtectedPayloadReference
    public let capturedAt: Date
    public let expiresAt: Date
    public let state: QueuedProcessingState
    public let retryCount: UInt

    public init(
        id: UUID = UUID(), identity: IngestionIdentity, encryptedPayload: ProtectedPayloadReference,
        capturedAt: Date, expiresAt: Date, state: QueuedProcessingState = .pending, retryCount: UInt = 0
    ) throws {
        guard capturedAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > capturedAt else { throw ContractError.invalidTime }
        self.id = id
        self.identity = identity
        self.encryptedPayload = encryptedPayload
        self.capturedAt = capturedAt
        self.expiresAt = expiresAt
        self.state = state
        self.retryCount = retryCount
    }

    public func isEligible(at time: Date) -> Bool { time >= capturedAt && time < expiresAt }
}

/// Cursor bytes must be opaque structural data; source paths/titles belong in protected metadata.
/// Advancing this record is part of the transaction that commits processing and any coverage gap.
public struct SourceCheckpoint: Hashable, Codable, Sendable {
    public let capabilityID: UUID
    public let sourceDocumentID: UUID
    public let revision: ContentRevision
    public let byteOffset: UInt64
    public let lastContentTime: Date?
    public let gaps: [CoverageGap]
    /// Versioned adapter cursors are protected alongside progress, never plaintext indexes.
    public let adapterState: Data?

    public init(
        capabilityID: UUID, sourceDocumentID: UUID, revision: ContentRevision,
        byteOffset: UInt64, lastContentTime: Date? = nil, gaps: [CoverageGap] = [], adapterState: Data? = nil
    ) {
        self.capabilityID = capabilityID
        self.sourceDocumentID = sourceDocumentID
        self.revision = revision
        self.byteOffset = byteOffset
        self.lastContentTime = lastContentTime
        self.gaps = gaps
        self.adapterState = adapterState
    }
}
