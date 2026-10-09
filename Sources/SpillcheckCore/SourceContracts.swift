import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Sendable {
    case codex
    case claudeCode = "claude-code"
}

public enum AgentInterface: String, Codable, CaseIterable, Sendable {
    case standaloneCLI = "standalone-cli"
    case t3
    case desktopCode = "desktop-code"
}

public enum ContentType: String, Codable, CaseIterable, Sendable {
    case userPrompt, toolOutput, toolError, intermediateResponse, finalResponse
}

public enum ContractError: Error, Equatable, Sendable {
    case emptyIdentity
    case invalidFingerprint
    case invalidRange
    case invalidUTF8
    case duplicateSegment
    case missingSegment
    case valueDoesNotMatchSource
    case invalidTime
    case missingEvidence
    case conflictingValueAtLocation
    case conflictingSourceMetadata
    case unknownOccurrence
    case unknownValue
    case obsoleteMarkerNotFound
    case contentStillRetained
    case mismatchedAudit
    case invalidState
    case invalidSnapshot
    case unsupportedSnapshotVersion
}

/// A source installation/profile is shared across CLI and T3 presentations of the same session.
public struct SessionIdentity: Hashable, Codable, Sendable {
    public let provider: AgentProvider
    public let profileID: String
    public let sessionID: String

    public init(provider: AgentProvider, profileID: String, sessionID: String) throws {
        guard !profileID.isEmpty, !sessionID.isEmpty else { throw ContractError.emptyIdentity }
        self.provider = provider
        self.profileID = profileID
        self.sessionID = sessionID
    }
}

/// Interface, timestamps, content hashes and live/history provenance are deliberately absent.
public struct SourceIdentity: Hashable, Codable, Sendable {
    public let session: SessionIdentity
    public let itemID: String

    public init(session: SessionIdentity, itemID: String) throws {
        guard !itemID.isEmpty else { throw ContractError.emptyIdentity }
        self.session = session
        self.itemID = itemID
    }
}

/// Only a dedicated keyed digest belongs here. The caller owns the key and exact-byte hashing.
/// This type never computes an unkeyed hash or stores the original value.
public struct ValueFingerprint: Hashable, Codable, Sendable {
    public let keyedDigest: Data

    public init(keyedDigest: Data) throws {
        guard keyedDigest.count == 32 else { throw ContractError.invalidFingerprint }
        self.keyedDigest = keyedDigest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(keyedDigest: container.decode(Data.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(keyedDigest)
    }
}

/// Keyed canonical content identity; distinct from value identity and upstream item identity.
public struct ContentRevision: Hashable, Codable, Sendable {
    public let keyedDigest: Data

    public init(keyedDigest: Data) throws {
        guard keyedDigest.count == 32 else { throw ContractError.invalidFingerprint }
        self.keyedDigest = keyedDigest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(keyedDigest: container.decode(Data.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(keyedDigest)
    }
}

/// Reference to separately encrypted bytes. Paths, titles, excerpts and raw values are not indexes.
public struct ProtectedPayloadReference: Hashable, Codable, Sendable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

public enum SourceOpeningCapability: String, Codable, Sendable {
    case validatedRoute, unavailable, activeSessionRestriction, unverified
}

/// The opaque document identity is adapter-owned; a raw filesystem path must be protected separately.
public enum SourceLocator: Hashable, Codable, Sendable {
    case upstreamItem
    case transcript(documentID: UUID, recordIndex: UInt64)
    case transcriptByteOffset(documentID: UUID, byteOffset: UInt64)
    case unavailable
}

public struct SessionRecord: Hashable, Codable, Sendable {
    public let identity: SessionIdentity
    public let interface: AgentInterface
    public let parentSession: SessionIdentity?
    public let protectedMetadata: ProtectedPayloadReference?
    public let openingCapability: SourceOpeningCapability

    public init(
        identity: SessionIdentity, interface: AgentInterface,
        parentSession: SessionIdentity? = nil,
        protectedMetadata: ProtectedPayloadReference? = nil,
        openingCapability: SourceOpeningCapability = .unverified
    ) {
        self.identity = identity
        self.interface = interface
        self.parentSession = parentSession
        self.protectedMetadata = protectedMetadata
        self.openingCapability = openingCapability
    }
}

public enum AuditReason: String, Codable, Sendable { case firstLaunch, restart, resume }

public struct HistoricalAuditContext: Hashable, Codable, Sendable {
    public static let lookback: TimeInterval = 7 * 24 * 60 * 60
    /// Audit work expires with its queue entry, at most one day after the audit ends. Content
    /// older than this horizon is never analyzed, whether it arrives live or historically.
    public static let analysisHorizon: TimeInterval = lookback + 24 * 60 * 60
    /// Processed-source receipts older than this cannot match any future analysis.
    public static let receiptHorizon: TimeInterval = analysisHorizon + 24 * 60 * 60
    public let id: UUID
    public let reason: AuditReason
    public let start: Date
    public let end: Date

    public init(id: UUID = UUID(), reason: AuditReason, endingAt end: Date) throws {
        guard end.timeIntervalSince1970.isFinite else { throw ContractError.invalidTime }
        self.id = id
        self.reason = reason
        self.end = end
        self.start = end.addingTimeInterval(-Self.lookback)
    }

    /// Selection uses item content time, never conversation creation time or observation time.
    public func includes(contentTime: Date) -> Bool { contentTime >= start && contentTime <= end }
}

public enum SourceProvenance: Hashable, Codable, Sendable {
    case live
    case historical(HistoricalAuditContext)
}

public enum CanonicalizationBasis: Hashable, Codable, Sendable {
    case sharedUpstreamIdentity
    case verifiedMapping(version: String)
    case exclusiveAuthority
}

public struct SourceOrigin: Hashable, Codable, Sendable {
    public let adapterID: String
    public let adapterVersion: String
    public let agentVersion: String
    public let interface: AgentInterface
    public let provenance: SourceProvenance
    public let canonicalization: CanonicalizationBasis

    public init(
        adapterID: String, adapterVersion: String, agentVersion: String,
        interface: AgentInterface, provenance: SourceProvenance,
        canonicalization: CanonicalizationBasis
    ) throws {
        guard !adapterID.isEmpty, !adapterVersion.isEmpty, !agentVersion.isEmpty else {
            throw ContractError.emptyIdentity
        }
        if case .verifiedMapping(let version) = canonicalization, version.isEmpty {
            throw ContractError.emptyIdentity
        }
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
        self.agentVersion = agentVersion
        self.interface = interface
        self.provenance = provenance
        self.canonicalization = canonicalization
    }
}

public struct SourceRecordMetadata: Hashable, Codable, Sendable {
    public let identity: SourceIdentity
    public let contentType: ContentType
    public let contentTime: Date
    public let observedAt: Date
    public let locator: SourceLocator
    public let protectedMetadata: ProtectedPayloadReference?
    public let origin: SourceOrigin

    public init(
        identity: SourceIdentity, contentType: ContentType, contentTime: Date,
        observedAt: Date, locator: SourceLocator = .upstreamItem,
        protectedMetadata: ProtectedPayloadReference? = nil, origin: SourceOrigin
    ) throws {
        guard contentTime.timeIntervalSince1970.isFinite, observedAt.timeIntervalSince1970.isFinite else {
            throw ContractError.invalidTime
        }
        self.identity = identity
        self.contentType = contentType
        self.contentTime = contentTime
        self.observedAt = observedAt
        self.locator = locator
        self.protectedMetadata = protectedMetadata
        self.origin = origin
    }
}

/// Canonical segments contain transport-decoded text. Their stable IDs and coordinates must be
/// shared by equivalent collectors; presentation wrappers and raw JSON offsets are not coordinates.
/// Existing canonical coordinates are immutable. Rewritten content or shifted offsets require a
/// verified adapter mapping to a new segment/item identity; an item revision alone is not that mapping.
public struct SourceSegment: Hashable, Sendable {
    public let id: String
    public let utf8: Data

    public init(id: String, utf8: Data) throws {
        guard !id.isEmpty else { throw ContractError.emptyIdentity }
        guard String(data: utf8, encoding: .utf8) != nil else { throw ContractError.invalidUTF8 }
        self.id = id
        self.utf8 = utf8
    }
}

/// Transient normalized content. Do not put this record in a plaintext database or diagnostic log.
public struct SourceRecord: Sendable {
    public let metadata: SourceRecordMetadata
    public let revision: ContentRevision
    public let segments: [SourceSegment]

    public init(metadata: SourceRecordMetadata, revision: ContentRevision, segments: [SourceSegment]) throws {
        guard !segments.isEmpty else { throw ContractError.missingSegment }
        guard Set(segments.map(\.id)).count == segments.count else { throw ContractError.duplicateSegment }
        self.metadata = metadata
        self.revision = revision
        self.segments = segments
    }
}

/// Byte offsets, not Swift character offsets. Bounds are half-open and must describe nonempty text.
public struct UTF8Range: Hashable, Codable, Sendable {
    public let lowerBound: Int
    public let upperBound: Int
    public var count: Int { upperBound - lowerBound }

    public init(_ lowerBound: Int, _ upperBound: Int) throws {
        guard lowerBound >= 0, upperBound > lowerBound else { throw ContractError.invalidRange }
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    private enum CodingKeys: String, CodingKey { case lowerBound, upperBound }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(container.decode(Int.self, forKey: .lowerBound), container.decode(Int.self, forKey: .upperBound))
    }
}

public struct ComponentRange: Hashable, Codable, Sendable {
    public let segmentID: String
    public let range: UTF8Range

    public init(segmentID: String, range: UTF8Range) throws {
        guard !segmentID.isEmpty else { throw ContractError.emptyIdentity }
        self.segmentID = segmentID
        self.range = range
    }
}

/// Several components represent one exact extraction. Components are ordered, nonoverlapping
/// canonical ranges; distinct locations remain distinct appearances even when their text matches.
public struct CanonicalLocation: Hashable, Codable, Sendable {
    public let components: [ComponentRange]

    public init(components: [ComponentRange]) throws {
        guard !components.isEmpty, components.allSatisfy({ !$0.segmentID.isEmpty }) else {
            throw ContractError.invalidRange
        }
        for (previous, next) in zip(components, components.dropFirst()) {
            guard previous.segmentID < next.segmentID ||
                (previous.segmentID == next.segmentID && previous.range.upperBound <= next.range.lowerBound) else {
                throw ContractError.invalidRange
            }
        }
        self.components = components
    }

    public init(segmentID: String, range: UTF8Range) throws {
        try self.init(components: [ComponentRange(segmentID: segmentID, range: range)])
    }

    private enum CodingKeys: String, CodingKey { case components }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(components: container.decode([ComponentRange].self, forKey: .components))
    }

    public func extract(from source: SourceRecord) throws -> Data {
        var result = Data()
        for component in components {
            guard let segment = source.segments.first(where: { $0.id == component.segmentID }) else {
                throw ContractError.missingSegment
            }
            guard component.range.upperBound <= segment.utf8.count else { throw ContractError.invalidRange }
            let fragment = segment.utf8.subdata(in: component.range.lowerBound..<component.range.upperBound)
            guard String(data: fragment, encoding: .utf8) != nil else { throw ContractError.invalidUTF8 }
            result.append(fragment)
        }
        return result
    }
}

/// A detector may retain only a source-verified extraction. No trimming, case folding or guessing.
public enum SourceValueTransform: Hashable, Sendable {
    case identity
    case declaredURIPasswordPercentEncoding(context: CanonicalLocation)
}

public struct ExactExtraction: Sendable {
    public let valueUTF8: Data
    public let location: CanonicalLocation
    public let transform: SourceValueTransform

    public init(valueUTF8: Data, location: CanonicalLocation, in source: SourceRecord) throws {
        guard !valueUTF8.isEmpty, String(data: valueUTF8, encoding: .utf8) != nil else {
            throw ContractError.invalidUTF8
        }
        guard try location.extract(from: source) == valueUTF8 else { throw ContractError.valueDoesNotMatchSource }
        self.valueUTF8 = valueUTF8
        self.location = location
        transform = .identity
    }

    /// Only a declared password field in an anchored credential URI may be percent-decoded.
    /// Its original byte range remains the occurrence coordinate. '+' remains a literal plus.
    public static func declaredURIPassword(
        location: CanonicalLocation, context: CanonicalLocation, in source: SourceRecord
    ) throws -> ExactExtraction {
        let decoded = try uriPassword(location: location, context: context, in: source)
        return ExactExtraction(valueUTF8: decoded, location: location,
            transform: .declaredURIPasswordPercentEncoding(context: context))
    }

    private init(valueUTF8: Data, location: CanonicalLocation, transform: SourceValueTransform) {
        self.valueUTF8 = valueUTF8
        self.location = location
        self.transform = transform
    }

    public func validate(in source: SourceRecord) throws {
        let expected: Data
        switch transform {
        case .identity: expected = try location.extract(from: source)
        case .declaredURIPasswordPercentEncoding(let context):
            expected = try Self.uriPassword(location: location, context: context, in: source)
        }
        guard expected == valueUTF8 else { throw ContractError.valueDoesNotMatchSource }
    }

    private static func uriPassword(
        location: CanonicalLocation, context: CanonicalLocation, in source: SourceRecord
    ) throws -> Data {
        guard location.components.count == 1, context.components.count == 1,
              let field = location.components.first, let whole = context.components.first,
              field.segmentID == whole.segmentID,
              field.range.lowerBound >= whole.range.lowerBound,
              field.range.upperBound <= whole.range.upperBound else { throw ContractError.invalidRange }
        let bytes = try context.extract(from: source)
        guard let text = String(data: bytes, encoding: .utf8) else { throw ContractError.invalidUTF8 }
        // This grammar matches the declared field of the pinned credential-URI detector.
        let expression = try NSRegularExpression(
            pattern: #"^(?:https?|postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|rediss?|amqps?|ldaps?|smtps?|ftps?|ssh)://[^:/@\s'"`]{0,128}:([^/@\s'"`]{1,256})@"#,
            options: [.caseInsensitive])
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let passwordRange = Range(match.range(at: 1), in: text) else {
            throw ContractError.valueDoesNotMatchSource
        }
        let start = text[..<passwordRange.lowerBound].utf8.count + whole.range.lowerBound
        let end = start + text[passwordRange].utf8.count
        guard field.range.lowerBound == start, field.range.upperBound == end else {
            throw ContractError.valueDoesNotMatchSource
        }
        let raw = Array(try location.extract(from: source))
        guard raw.contains(37) else { throw ContractError.valueDoesNotMatchSource }
        var result = Data()
        var offset = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: byte - 48
            case 65...70: byte - 55
            case 97...102: byte - 87
            default: nil
            }
        }
        while offset < raw.count {
            if raw[offset] == 37 {
                guard offset + 2 < raw.count, let high = hex(raw[offset + 1]), let low = hex(raw[offset + 2]) else {
                    throw ContractError.valueDoesNotMatchSource
                }
                result.append(high * 16 + low)
                offset += 3
            } else {
                result.append(raw[offset])
                offset += 1
            }
        }
        guard !result.isEmpty, String(data: result, encoding: .utf8) != nil else { throw ContractError.invalidUTF8 }
        return result
    }
}
