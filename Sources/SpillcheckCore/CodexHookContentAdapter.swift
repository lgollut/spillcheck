import Foundation

public typealias CodexHookContentBinder = @Sendable (
    SourceIdentity, ContentRevision, Date
) async throws -> CodexHookContentBinding

/// An explicitly enrolled hook session has its own observed-content authority.
/// Enrollment is supplied by the caller and persisted before processing. Missing
/// public history, a project path, or a differing session ID never enrolls a side chat.
/// This collector neither reads history nor claims native item or parent identity.
public struct CodexHookContentAdapter: CaptureNormalizer, Sendable {
    public static let authorityID = "codex-hook-content-v1"
    public static let adapterVersion = "1"
    // Tool-result parsing advances independently of persisted prompt/final slots.
    public static let parserContract = "codex-hook-observed-slots-v3"
    public static let itemPrefix = "codex-hook-v1:"
    public let profileID: String
    public let interface: AgentInterface
    private let authorityLookup: SourceAuthorityLookup
    private let bind: CodexHookContentBinder
    private let maximumBytes: Int

    public init(profileID: String, interface: AgentInterface,
                maximumBytes: Int = 1024 * 1024,
                authorityLookup: @escaping SourceAuthorityLookup,
                bind: @escaping CodexHookContentBinder) throws {
        guard !profileID.isEmpty, profileID.utf8.count <= 256, !profileID.utf8.contains(0),
              maximumBytes > 0, maximumBytes <= CapturePacket.maximumBodyBytes else {
            throw CodexCollectionError.invalidConfiguration
        }
        self.profileID = profileID; self.interface = interface
        self.maximumBytes = maximumBytes; self.authorityLookup = authorityLookup; self.bind = bind
    }

    public var collectionScope: CollectionScope {
        .init(provider: .codex, profileID: profileID, interface: interface, path: .hook)
    }

    public func capabilities() -> [AdapterCapability] {
        ContentType.allCases.map { kind in
            let available = kind != .intermediateResponse
            return .init(provider: .codex, interface: interface, agentVersion: "unknown",
                adapterVersion: Self.adapterVersion, contentType: kind, path: .hook,
                validation: available ? .unverified : .unsupported,
                canObserveActiveSession: available, canReadHistoricalContent: false,
                canonicalization: .exclusiveAuthority)
        }
    }

    static func identifier(_ value: CodexJSON) -> String? {
        guard let value = value.string, !value.isEmpty, value.utf8.count <= 256,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || [45, 46, 58, 95].contains($0) }) else { return nil }
        return value
    }

    public func normalize(_ packet: CapturePacket, capturedAt: Date,
                          cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        guard packet.metadata.agent == .codex, packet.metadata.profileID == profileID,
              packet.metadata.interface == interface else { throw CodexCollectionError.wrongProfile }
        guard capturedAt.timeIntervalSince1970.isFinite else { throw ContractError.invalidTime }
        var session: SessionIdentity?
        var itemID: String?
        var kind: ContentType?
        func gap(_ reason: CoverageGapReason, _ diagnostic: CoverageDiagnosticCode) -> CollectionBatch {
            .init(sources: [], coverageGaps: [.init(reason: reason, scope: collectionScope,
                contentType: kind, operation: .hookDelivery,
                recovery: session.map { .init(session: $0, locator: .unavailable,
                    itemID: itemID, parserContract: Self.parserContract) },
                isRequiredFormatFailure: true, sourceKind: .codexHookEvent,
                diagnosticCode: diagnostic, observedAt: capturedAt)])
        }
        guard packet.eventJSON.count <= maximumBytes else { return gap(.budgetExhausted, .oversizedRecord) }
        guard let event = try? JSONDecoder().decode(CodexJSON.self, from: packet.eventJSON),
              let eventName = Self.identifier(event["hook_event_name"]),
              let sessionID = Self.identifier(event["session_id"]) else {
            return gap(.malformedSource, .invalidFieldType)
        }
        let selected = try SessionIdentity(provider: .codex, profileID: profileID, sessionID: sessionID)
        session = selected
        guard let authority = try await authorityLookup(selected), authority.session == selected,
              authority.authorityID == Self.authorityID else {
            return gap(.unresolvedCorrelation, .unresolvedIdentity)
        }
        if ["SessionStart", "SessionEnd"].contains(eventName) { return .init(sources: []) }
        guard let turnID = Self.identifier(event["turn_id"]) else {
            return gap(.malformedSource, .unresolvedIdentity)
        }
        // A structured, bounded namespace avoids delimiter collisions and cannot be
        // mistaken for a message item returned by the native history API.
        var slotParts = [turnID, eventName]
        if eventName == "PostToolUse" {
            guard let callID = Self.identifier(event["tool_use_id"]) else {
                return gap(.malformedSource, .unresolvedIdentity)
            }
            slotParts.append(callID)
        }
        let slotID = Self.itemPrefix + (try JSONEncoder().encode(slotParts)).base64EncodedString()
        itemID = slotID
        if eventName == "Interrupt" {
            kind = .finalResponse
            return gap(.incompleteMessage, .hookInterrupted)
        }
        guard event["agent_id"] == .null, event["agent_type"] == .null else {
            return gap(.unresolvedCorrelation, .unresolvedIdentity)
        }
        let contentType: ContentType
        let segments: [SourceSegment]
        var toolIssues: Set<CodexHookToolIssue> = []
        var toolCanonical: Data?
        switch eventName {
        case "UserPromptSubmit":
            contentType = .userPrompt
            guard let text = event["prompt"].string else { kind = contentType; return gap(.malformedSource, .missingPayload) }
            segments = [try .init(id: "/prompt", utf8: Data(text.utf8))]
        case "Stop":
            contentType = .finalResponse; kind = contentType
            guard event["stop_hook_active"] == .bool(false) else {
                return gap(.incompleteMessage, .hookContentUnavailable)
            }
            guard let text = event["last_assistant_message"].string else { return gap(.malformedSource, .missingPayload) }
            segments = [try .init(id: "/last_assistant_message", utf8: Data(text.utf8))]
        case "PostToolUse":
            kind = .toolOutput
            guard let name = event["tool_name"].string, !name.isEmpty,
                  name.utf8.count <= 256, !name.utf8.contains(0) else {
                return gap(.malformedSource, .invalidFieldType)
            }
            guard let response = event.object?["tool_response"] else {
                return gap(.malformedSource, .missingPayload)
            }
            var parsed = CodexHookToolResult(maximumTextBytes: maximumBytes, maximumPointerBytes: maximumBytes,
                toolName: name)
            try parsed.collect(response, mcpResult: name.hasPrefix("mcp__"))
            contentType = parsed.failed ? .toolError : .toolOutput
            toolIssues = parsed.issues
            // A valid text-free result still gets an immutable receipt. The empty
            // segment has no bytes from which a detector could extract a value.
            segments = parsed.segments.isEmpty
                ? [try .init(id: "/tool_response", utf8: Data())] : parsed.segments
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            toolCanonical = Data("codex-hook-tool-content-v1".utf8)
            for bytes in [Data(name.utf8), Data(contentType.rawValue.utf8), try encoder.encode(response)] {
                var length = UInt64(bytes.count).bigEndian
                withUnsafeBytes(of: &length) { toolCanonical?.append(contentsOf: $0) }
                toolCanonical?.append(bytes)
            }
            for segment in segments { for bytes in [Data(segment.id.utf8), segment.utf8] {
                var length = UInt64(bytes.count).bigEndian
                withUnsafeBytes(of: &length) { toolCanonical?.append(contentsOf: $0) }
                toolCanonical?.append(bytes)
            } }
        default: return gap(.unsupportedContent, .hookContentUnavailable)
        }
        kind = contentType
        let identity = try SourceIdentity(session: selected, itemID: slotID)
        var canonical = Data("codex-hook-content-v1".utf8)
        if let toolCanonical { canonical = toolCanonical }
        else {
            // Preserve the v1 prompt/final revision representation byte for byte.
            for segment in segments { for bytes in [Data(segment.id.utf8), segment.utf8] {
                var length = UInt64(bytes.count).bigEndian
                withUnsafeBytes(of: &length) { canonical.append(contentsOf: $0) }
                canonical.append(bytes)
            } }
        }
        let revision = try await cryptography.revision(canonicalBytes: canonical)
        let binding: CodexHookContentBinding
        do { binding = try await bind(identity, revision, capturedAt) }
        catch StorageError.capacityExceeded(.codexHookContentSlots) { return gap(.budgetExhausted, .hookStorageLimit) }
        catch StorageError.stateTooLarge { return gap(.budgetExhausted, .hookStorageLimit) }
        let firstObserved: Date
        switch binding {
        case .accepted(let date): firstObserved = date
        case .conflict: return gap(.sourceChanged, .hookIdentityConflict)
        }
        let origin = try SourceOrigin(adapterID: "codex-hook-content", adapterVersion: Self.adapterVersion,
            agentVersion: "unknown", interface: interface, provenance: .live,
            canonicalization: .exclusiveAuthority)
        let metadata = try SourceRecordMetadata(identity: identity, contentType: contentType,
            contentTime: firstObserved, observedAt: firstObserved, locator: .unavailable,
            origin: origin, timeBasis: .firstObservation)
        let gaps = toolIssues.map { issue in
            CoverageGap(reason: issue.reason, scope: collectionScope, contentType: contentType,
                operation: .hookDelivery, recovery: .init(session: selected, locator: .unavailable,
                    itemID: slotID, parserContract: Self.parserContract),
                isRequiredFormatFailure: issue != .binary, sourceKind: .codexHookEvent,
                diagnosticCode: issue.diagnostic, excludedContent: issue == .binary ? true : nil,
                observedAt: capturedAt)
        }
        return try .init(sources: [.init(record: .init(metadata: metadata, revision: revision, segments: segments),
            context: .init(sessionIdentifier: sessionID, openingCapability: .unavailable))],
            coverageGaps: gaps, observedRead: true)
    }
}

private enum CodexHookToolIssue: Hashable {
    case malformed, unsupported, binary, encrypted, budget

    var reason: CoverageGapReason {
        switch self {
        case .malformed: .malformedSource
        case .unsupported, .binary, .encrypted: .unsupportedContent
        case .budget: .budgetExhausted
        }
    }
    var diagnostic: CoverageDiagnosticCode {
        switch self {
        case .malformed: .invalidFieldType
        case .unsupported: .unknownBlockKind
        case .binary: .excludedBinaryContent
        case .encrypted: .encryptedContentUnavailable
        case .budget: .readBudgetExceeded
        }
    }
}

/// PostToolUse carries arbitrary tool-specific JSON. Only the response subtree
/// supplies source text. Raw strings, including printed JSON, never establish
/// completion status. Only a recognized response object can supply that status.
private struct CodexHookToolResult {
    let maximumTextBytes: Int
    let maximumPointerBytes: Int
    private let statusFamily: StatusFamily
    var segments: [SourceSegment] = []
    var issues: Set<CodexHookToolIssue> = []
    var failed = false
    private var nodes = 0
    private var textBytes = 0
    private var pointerBytes = 0
    private var pointerBudgetExhausted = false
    private static let textTypes: Set<String> = ["text", "input_text", "output_text", "inputText"]
    private static let binaryTypes: Set<String> = ["image", "image_url", "input_image", "inputImage",
        "audio", "input_audio", "inputAudio"]
    private static let nativeBlockTypes: Set<String> = ["input_text", "input_image", "input_audio", "encrypted_content"]
    private enum StatusFamily { case shell, mcp, unknown }

    init(maximumTextBytes: Int, maximumPointerBytes: Int, toolName: String) {
        self.maximumTextBytes = maximumTextBytes
        self.maximumPointerBytes = maximumPointerBytes
        let localName = toolName.hasPrefix("functions.") ? String(toolName.dropFirst("functions.".count)) : toolName
        if toolName.hasPrefix("mcp__") { statusFamily = .mcp }
        else if ["Bash", "shell", "shell_command", "exec_command", "write_stdin"].contains(localName) { statusFamily = .shell }
        else { statusFamily = .unknown }
    }

    mutating func collect(_ value: CodexJSON, pointer: String = "/tool_response", depth: Int = 0,
                          block: Bool = false, mcpResult: Bool = false, resource: Bool = false) throws {
        guard !pointerBudgetExhausted else { return }
        guard admitPointer(bytes: pointer.utf8.count) else { return }
        guard depth <= 32, nodes < 8192, segments.count < 1024 else { issues.insert(.budget); return }
        nodes += 1
        if nodes % 64 == 0 { try Task.checkCancellation() }
        switch value {
        case .string(let text):
            let bytes = Data(text.utf8)
            guard bytes.count <= maximumTextBytes - textBytes else { issues.insert(.budget); return }
            textBytes += bytes.count
            segments.append(try .init(id: pointer, utf8: bytes))
        case .array(let values):
            // Native function output uses a top-level content-item array. Other
            // arrays are arbitrary application JSON unless their caller supplies
            // an MCP content-block context.
            let typedBlocks = block || (depth == 0 && values.contains {
                Self.nativeBlockTypes.contains($0["type"].string ?? "")
            })
            for (index, child) in values.enumerated() {
                guard nodes < 8192, segments.count < 1024 else { issues.insert(.budget); break }
                let component = String(index)
                guard canConstructPointer(parentBytes: pointer.utf8.count, componentBytes: component.utf8.count) else { break }
                try collect(child, pointer: pointer + "/" + component, depth: depth + 1,
                    block: typedBlocks)
            }
        case .object(let values):
            let type = value["type"].string
            if block && Self.binaryTypes.contains(type ?? "") { issues.insert(.binary); return }
            if block && type == "encrypted_content" { issues.insert(.encrypted); return }
            if block && type == "tool_reference" { return }
            if block && Self.textTypes.contains(type ?? "") {
                if value["text"].string == nil { issues.insert(.malformed) }
            } else if block, !["resource", "resource_link"].contains(type ?? "") {
                issues.insert(type == nil ? .malformed : .unsupported)
            }
            if depth == 0 { inspectStatus(value) }
            for key in values.keys.sorted() {
                guard nodes < 8192, segments.count < 1024 else { issues.insert(.budget); break }
                guard !pointerBudgetExhausted else { break }
                if block && key == "type", Self.textTypes.contains(type ?? "") || ["resource", "resource_link"].contains(type ?? "") { continue }
                if key == "blob" && resource {
                    issues.insert(.binary); continue
                }
                let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                guard canConstructPointer(parentBytes: pointer.utf8.count, componentBytes: escaped.utf8.count) else { break }
                try collect(values[key]!, pointer: pointer + "/" + escaped, depth: depth + 1,
                    block: (key == "content" || key == "contentItems") && mcpResult,
                    resource: block && type == "resource" && key == "resource")
            }
        case .number, .bool, .null: break // Recognized JSON values without textual content.
        }
    }

    /// Every visited path counts, including paths without string leaves, so a long shared key
    /// cannot amplify one event into far larger segment identifiers. Exhaustion is terminal.
    private mutating func canConstructPointer(parentBytes: Int, componentBytes: Int) -> Bool {
        guard !pointerBudgetExhausted else { return false }
        let remaining = maximumPointerBytes - pointerBytes
        guard parentBytes < remaining, componentBytes <= remaining - parentBytes - 1 else {
            issues.insert(.budget); pointerBudgetExhausted = true; return false
        }
        return true
    }

    private mutating func admitPointer(bytes: Int) -> Bool {
        guard bytes <= maximumPointerBytes - pointerBytes else {
            issues.insert(.budget); pointerBudgetExhausted = true; return false
        }
        pointerBytes += bytes
        return true
    }

    mutating private func inspectStatus(_ value: CodexJSON) {
        guard let object = value.object else { return }
        // Arbitrary local-function JSON can contain business fields named error,
        // status, or success. Those do not establish execution status. Keep their
        // bytes without claiming a failure; absent status never prevents scanning.
        // This reads only the response envelope. Printed JSON inside output or
        // application result/error objects cannot change execution status.
        switch statusFamily {
        case .mcp:
            if let status = object["isError"], status != .null {
                if let flag = status.bool { failed = failed || flag }
                else { issues.insert(.malformed) }
            }
        case .shell:
            for status in [value["exit_code"], value["exitCode"], value["metadata"]["exit_code"]] where status != .null {
                guard let code = status.number, code.isFinite, code.rounded() == code,
                      code >= Double(Int32.min), code <= Double(Int32.max) else {
                    issues.insert(.malformed); continue
                }
                failed = failed || code != 0
            }
        case .unknown: break
        }
    }
}
