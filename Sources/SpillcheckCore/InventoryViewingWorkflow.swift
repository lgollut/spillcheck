import Foundation

public enum InventoryRevealField: Hashable, Sendable {
    case value(ProtectedPayloadReference)
    case excerpt(occurrenceID: UUID, reference: ProtectedPayloadReference)
    case sourceMetadata(occurrenceID: UUID, reference: ProtectedPayloadReference)
    case unlocatedSourceMetadata(resultID: UUID, reference: ProtectedPayloadReference)

    public var reference: ProtectedPayloadReference {
        switch self {
        case .value(let reference), .excerpt(_, let reference), .sourceMetadata(_, let reference),
             .unlocatedSourceMetadata(_, let reference): reference
        }
    }

    /// The collector binds each retained field to its independently generated reference.
    public var binding: PayloadBinding {
        let kind: ProtectedPayloadKind
        switch self {
        case .value: kind = .value
        case .excerpt: kind = .excerpt
        case .sourceMetadata, .unlocatedSourceMetadata: kind = .sourceMetadata
        }
        return PayloadBinding(reference: reference, ownerID: reference.id, kind: kind)
    }
}

/// Build requests from the current protected snapshot, never from an envelope's own header.
public struct InventoryRevealSelection: Hashable, Sendable {
    /// For an unlocated result this is its opaque result ID, and never an invented value identity.
    public let valueID: UUID
    public let fields: [InventoryRevealField]

    private init(valueID: UUID, fields: [InventoryRevealField]) {
        self.valueID = valueID
        self.fields = fields
    }

    public static func retainedValue(in snapshot: InventorySnapshot, valueID: UUID) throws -> Self {
        guard let record = snapshot.records.values.first(where: { $0.id == valueID }),
              let reference = record.protectedValue else { throw ContractError.unknownValue }
        return Self(valueID: valueID, fields: [.value(reference)])
    }

    public static func occurrence(in snapshot: InventorySnapshot, occurrenceID: UUID) throws -> Self {
        guard let occurrence = snapshot.occurrences[occurrenceID],
              snapshot.records.values.contains(where: { $0.id == occurrence.valueID }) else {
            throw ContractError.unknownOccurrence
        }
        var fields: [InventoryRevealField] = []
        if let reference = occurrence.protectedExcerpt {
            fields.append(.excerpt(occurrenceID: occurrenceID, reference: reference))
        }
        if let reference = occurrence.source.protectedMetadata {
            fields.append(.sourceMetadata(occurrenceID: occurrenceID, reference: reference))
        }
        guard !fields.isEmpty else { throw StorageError.payloadMissing }
        return Self(valueID: occurrence.valueID, fields: fields)
    }

    /// One authentication reveals the exact value together with this occurrence's retained context.
    public static func occurrenceWithValue(in snapshot: InventorySnapshot, occurrenceID: UUID) throws -> Self {
        guard let occurrence = snapshot.occurrences[occurrenceID],
              let record = snapshot.records.values.first(where: { $0.id == occurrence.valueID }) else {
            throw ContractError.unknownOccurrence
        }
        var fields = record.protectedValue.map { [InventoryRevealField.value($0)] } ?? []
        if let reference = occurrence.protectedExcerpt {
            fields.append(.excerpt(occurrenceID: occurrenceID, reference: reference))
        }
        if let reference = occurrence.source.protectedMetadata {
            fields.append(.sourceMetadata(occurrenceID: occurrenceID, reference: reference))
        }
        guard !fields.isEmpty else { throw StorageError.payloadMissing }
        return Self(valueID: occurrence.valueID, fields: fields)
    }

    public static func unlocatedSource(in snapshot: InventorySnapshot, resultID: UUID) throws -> Self {
        guard let reference = snapshot.unlocatedResults[resultID]?.source.protectedMetadata else {
            throw StorageError.payloadMissing
        }
        return Self(valueID: resultID, fields: [.unlocatedSourceMetadata(resultID: resultID, reference: reference)])
    }

    public func isCurrent(in snapshot: InventorySnapshot) -> Bool {
        fields.allSatisfy { field in
            switch field {
            case .value(let reference):
                snapshot.records.values.contains { $0.id == valueID && $0.protectedValue == reference }
            case .excerpt(let occurrenceID, let reference):
                snapshot.occurrences[occurrenceID].map {
                    $0.valueID == valueID && $0.protectedExcerpt == reference
                } == true
            case .sourceMetadata(let occurrenceID, let reference):
                snapshot.occurrences[occurrenceID].map {
                    $0.valueID == valueID && $0.source.protectedMetadata == reference
                } == true
            case .unlocatedSourceMetadata(let resultID, let reference):
                resultID == valueID && snapshot.unlocatedResults[resultID]?.source.protectedMetadata == reference
            }
        }
    }
}

/// This guard also covers payload loading and decoding around the vault's own private-key guard.
public struct InventoryRevealGuard: Sendable {
    public struct Ticket: Hashable, Sendable {
        fileprivate let generation: UUID
        fileprivate let valueID: UUID
    }

    public private(set) var selectedValueID: UUID?
    private var generation = UUID()

    public init() {}

    public mutating func select(valueID: UUID?) {
        selectedValueID = valueID
        invalidate()
    }

    public mutating func invalidate() { generation = UUID() }

    public mutating func begin(_ selection: InventoryRevealSelection) throws -> Ticket {
        guard selectedValueID == selection.valueID else { throw ViewingAuthorizationError.invalidated }
        invalidate()
        return Ticket(generation: generation, valueID: selection.valueID)
    }

    public func accepts(_ ticket: Ticket) -> Bool {
        ticket.generation == generation && ticket.valueID == selectedValueID
    }
}

public enum SourceOpeningFailure: String, Error, Codable, Sendable {
    case unavailable, activeSession, unverified, invalidReference, applicationMissing
    case commandFailed, timedOut, cancelled

    public var message: String {
        switch self {
        case .unavailable: "The source conversation is unavailable."
        case .activeSession: "This conversation is active and cannot be moved to the desktop app."
        case .unverified: "Direct opening has not been verified for this source."
        case .invalidReference: "This source has no supported conversation reference."
        case .applicationMissing: "The source application or command is unavailable."
        case .commandFailed: "The source application could not open this conversation."
        case .timedOut: "The source application did not finish opening the conversation."
        case .cancelled: "Source opening was cancelled."
        }
    }
}

public enum SourceOpeningResult: Equatable, Sendable {
    /// Dispatch success is not proof that the application displayed the requested conversation.
    case requested
    case fallback(SourceOpeningFailure, retainedContextAvailable: Bool)

    public var message: String {
        switch self {
        case .requested: "Opening requested in the source application."
        case .fallback(let reason, let retained):
            reason.message + (retained ? " Reveal the retained context here." : " No retained context is available.")
        }
    }
}

/// Arguments remain distinct until the user deliberately executes a terminal action.
public struct SourceCommandPlan: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]

    public init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    public var displayCommand: String {
        ([executableURL.path] + arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
    }
}

public enum SourceOpeningPlan {
    public static func nativeIdentifier(_ session: SessionIdentity) throws -> UUID {
        guard let identifier = UUID(uuidString: session.sessionID) else { throw SourceOpeningFailure.invalidReference }
        return identifier
    }

    public static func codexURL(session: SessionIdentity) throws -> URL {
        guard session.provider == .codex else { throw SourceOpeningFailure.invalidReference }
        let identifier = try nativeIdentifier(session)
        guard let url = URL(string: "codex://threads/\(identifier.uuidString.lowercased())") else {
            throw SourceOpeningFailure.invalidReference
        }
        return url
    }

    public static func claudeDesktop(session: SessionIdentity, executableURL: URL) throws -> SourceCommandPlan {
        guard session.provider == .claudeCode else { throw SourceOpeningFailure.invalidReference }
        let identifier = try nativeIdentifier(session)
        return SourceCommandPlan(executableURL: executableURL,
            arguments: ["--desktop", "--resume", identifier.uuidString.lowercased()])
    }

    public static func terminalResume(session: SessionIdentity, executableURL: URL) throws -> SourceCommandPlan {
        let identifier = try nativeIdentifier(session)
        return SourceCommandPlan(executableURL: executableURL, arguments: session.provider == .codex
            ? ["resume", identifier.uuidString.lowercased()] : ["--resume", identifier.uuidString.lowercased()])
    }
}
