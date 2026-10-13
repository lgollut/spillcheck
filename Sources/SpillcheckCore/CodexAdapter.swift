import Darwin
import Foundation

public enum CodexCollectionError: Error, Equatable, Sendable {
    case invalidConfiguration, wrongProfile, malformedCapture, awaitingHistory, unsafeTranscriptPath
    case authorityConflict, missingAuthority, unsupportedVersion
}
public enum CodexCollectionAuthority: String, Codable, Sendable {
    case publicNativeItems = "codex-public-native-v1"
    case t3VersionedTranscript = "codex-t3-transcript-v1"
    /// Native Codex rollout JSONL. Keep the historical authority identifier for stored choices.
    public static let nativeRolloutTranscript = Self.t3VersionedTranscript

    public var collectionPath: CollectionPath {
        switch self {
        case .publicNativeItems: .publicHistory
        case .t3VersionedTranscript: .versionedTranscript
        }
    }
}
public struct CodexReadLimits: Sendable {
    public let maximumBytes: Int
    public let maximumRowBytes: Int
    public let maximumRows: Int
    public let pageSize: Int
    public init(maximumBytes: Int = 8 * 1024 * 1024, maximumRowBytes: Int = 1024 * 1024,
                maximumRows: Int = 8192, pageSize: Int = 64) {
        self.maximumBytes = maximumBytes; self.maximumRowBytes = maximumRowBytes
        self.maximumRows = maximumRows; self.pageSize = pageSize
    }
}

/// Hooks trigger bounded canonical reads. They never manufacture message IDs or a second authority.
public struct CodexAdapter: CaptureNormalizer, SourceHistoricalCaptureProducer, Sendable {
    public static let validatedAgentVersion = "0.161.0"
    public static let validatedT3Version = "0.0.46-nightly.20261007.2761"
    public static let validatedT3ProducerVersion = "0.160.1"
    public static let adapterVersion = "1"
    public static let parserContract = "codex-content-contract-v16"
    /// A missing representation, not an invented upstream message/item identity.
    static let nativeChildInputRequirementID = "codex-native-child-input"
    public let profileID: String
    public let agentVersion: String
    public let interface: AgentInterface
    public let t3Version: String?
    public let authority: CodexCollectionAuthority
    public let allowedTranscriptRoots: [URL]
    public let limits: CodexReadLimits
    let history: any CodexHistoryReading
    let authorityLookup: SourceAuthorityLookup
    let authorityRecorder: SourceAuthorityRecorder
    let checkpointLookup: SourceCheckpointLookup
    let historyBudget: HistoryReadBudget
    private let rootAliases: [(original: URL, resolved: URL)]

    public init(profileID: String, agentVersion: String, interface: AgentInterface = .standaloneCLI,
                t3Version: String? = nil,
                authority: CodexCollectionAuthority = .publicNativeItems,
                history: any CodexHistoryReading, allowedTranscriptRoots: [URL] = [],
                limits: CodexReadLimits = .init(), historyBudget: HistoryReadBudget = .init(),
                authorityLookup: @escaping SourceAuthorityLookup,
                authorityRecorder: @escaping SourceAuthorityRecorder,
                checkpointLookup: @escaping SourceCheckpointLookup = { _ in nil }) throws {
        guard !profileID.isEmpty, profileID.utf8.count <= 256, !profileID.utf8.contains(0),
              limits.maximumBytes > 0, limits.maximumBytes <= CapturePacket.maximumBodyBytes,
              limits.maximumRowBytes > 0, limits.maximumRowBytes <= limits.maximumBytes,
              limits.maximumRows > 0, limits.pageSize > 0, limits.pageSize <= 256,
              historyBudget.maximumBytes > 0, historyBudget.maximumBytes <= 100 * 1024 * 1024,
              historyBudget.maximumDuration > 0,
              historyBudget.maximumDuration <= 30, historyBudget.maximumSources > 0, historyBudget.maximumSources <= 256,
              authority != .nativeRolloutTranscript || interface == .t3,
              allowedTranscriptRoots.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") && $0.path != "/" }) else {
            throw CodexCollectionError.invalidConfiguration
        }
        self.profileID = profileID; self.agentVersion = agentVersion; self.interface = interface; self.t3Version = t3Version
        self.authority = authority; self.history = history; self.limits = limits
        self.historyBudget = historyBudget; self.authorityLookup = authorityLookup; self.authorityRecorder = authorityRecorder
        self.checkpointLookup = checkpointLookup
        rootAliases = allowedTranscriptRoots.map { ($0.standardizedFileURL, codexConfiguredURL($0)) }
        self.allowedTranscriptRoots = rootAliases.map(\.resolved)
    }

    public func capabilities() -> [AdapterCapability] {
        ContentType.allCases.map { type in
            let eligible = isEligible
            let evidence = CollectionCompatibility.recordedEvidence(provider: .codex, interface: interface,
                producerVersion: interface == .standaloneCLI ? agentVersion : CollectionCompatibility.unknownProducerVersion,
                readerVersion: agentVersion, hostVersion: t3Version)
            return AdapterCapability(provider: .codex, interface: interface,
                agentVersion: interface == .standaloneCLI ? agentVersion : CollectionCompatibility.unknownProducerVersion,
                adapterVersion: Self.adapterVersion, contentType: type,
                path: authority.collectionPath,
                validation: eligible ? (authority == .publicNativeItems ? evidence : .unverified) : .unsupported,
                canObserveActiveSession: eligible && authority == .publicNativeItems,
                canReadHistoricalContent: eligible && authority == .publicNativeItems, canonicalization: .exclusiveAuthority)
        }
    }

    public func normalize(_ packet: CapturePacket, capturedAt: Date,
                          cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        guard packet.metadata.agent == .codex, packet.metadata.profileID == profileID,
              packet.metadata.interface == interface else { throw CodexCollectionError.wrongProfile }
        var operation: CollectionOperation = .hookDelivery
        func gap(_ reason: CoverageGapReason) -> CoverageGap {
            .init(reason: reason, scope: collectionScope, operation: operation,
                diagnosticCode: reason.defaultDiagnosticCode, observedAt: capturedAt)
        }
        guard isEligible else {
            return CollectionBatch(sources: [], coverageGaps: [gap(.unsupportedVersion)])
        }
        if let request = try? JSONDecoder().decode(CodexHistoryRequest.self, from: packet.eventJSON),
           request.kind == CodexHistoryRequest.kind {
            return try await normalizeHistory(request, observedAt: capturedAt, cryptography: cryptography)
        }
        let hook = try? JSONDecoder().decode(CodexJSON.self, from: packet.eventJSON)
        if hook?["kind"].string == CodexHistoryRequest.kind { operation = .historicalRead }
        if ["SpillcheckHistoryPoll", "LeakretHistoryPoll"].contains(hook?["hook_event_name"].string ?? "") { operation = .liveRead }
        guard let hook, let event = hook["hook_event_name"].string, let threadID = codexNativeIdentifier(hook["session_id"]) else {
            return CollectionBatch(sources: [], coverageGaps: [gap(.malformedSource)])
        }
        guard Set(CodexHookConfiguration.events + ["SpillcheckHistoryPoll", "LeakretHistoryPoll"]).contains(event) else {
            return CollectionBatch(sources: [], coverageGaps: [gap(.unsupportedContent)])
        }
        operation = .liveRead
        if authority == .nativeRolloutTranscript {
            guard let path = hook["transcript_path"].nonemptyString else {
                return CollectionBatch(sources: [], coverageGaps: [gap(.sourceUnavailable)])
            }
            do { try await selectAuthority(sessionID: threadID) }
            catch StorageError.capacityExceeded(.sourceAuthorities) {
                return .init(sources: [], coverageGaps: [.init(reason: .budgetExhausted,
                    scope: collectionScope, operation: .liveRead,
                    diagnosticCode: .authorityStorageLimit, observedAt: capturedAt)])
            }
            let data = try readTranscript(path: path)
            let document = try await documentIdentity(path, cryptography: cryptography)
            return try await importTranscript(data, documentID: document, observedAt: capturedAt,
                expectedSessionID: threadID, context: .init(sessionIdentifier: threadID,
                    projectPath: hook["cwd"].string, transcriptPath: path), cryptography: cryptography)
        }
        var request = CodexHistoryRequest(audit: nil, threads: [threadID])
        request.emptyPageIsCurrent = ["SpillcheckHistoryPoll", "LeakretHistoryPoll"].contains(event)
        if event == "SubagentStart" || event == "SubagentStop", let child = hook["agent_id"].nonemptyString,
           child != threadID { request.threads.append(child) }
        let batch = try await normalizeHistory(request, observedAt: capturedAt, cryptography: cryptography)
        return batch
    }

    public func initialHistoricalCapture(audit: HistoricalAuditContext) async throws -> CapturePacket {
        try packet(CodexHistoryRequest(audit: audit))
    }

    /// Disposable acceptance can bind one initial exact-source request to its frozen audit.
    /// This is not a hook feature: discovery, continuations, transcript selection and native
    /// relationship state are refused. The caller must separately authenticate test mode.
    @_spi(Testing) public static func historicalAuditForTesting(in packet: CapturePacket) throws -> HistoricalAuditContext? {
        guard packet.metadata.agent == .codex else { return nil }
        do {
            guard let object = try JSONSerialization.jsonObject(with: packet.eventJSON) as? [String: Any] else {
                throw CodexCollectionError.invalidConfiguration
            }
            guard object["kind"] as? String == CodexHistoryRequest.kind else { return nil }
            let keys: Set<String> = ["kind", "audit", "threads", "archived", "discovering", "children", "visited",
                "hasReplayCursor", "partial", "threadPartial", "threadReadBeganAtStart", "threadHasInWindowItems",
                "nativeChildParents", "consecutiveBudgetFailures", "liveBootstrapped", "selectedSourceOnly"]
            guard packet.eventJSON.count <= 16 * 1024, Set(object.keys).isSubset(of: keys),
                  let auditObject = object["audit"] as? [String: Any],
                  Set(auditObject.keys) == ["id", "reason", "start", "end"] else {
                throw CodexCollectionError.invalidConfiguration
            }
            let request = try JSONDecoder().decode(CodexHistoryRequest.self, from: packet.eventJSON)
            guard let audit = request.audit, audit.start.timeIntervalSince1970.isFinite,
                  audit.end.timeIntervalSince1970.isFinite,
                  audit.start == audit.end.addingTimeInterval(-HistoricalAuditContext.lookback),
                  audit.end.timeIntervalSince(audit.start) == HistoricalAuditContext.lookback,
                  request.threads.count == 1, let thread = request.threads.first,
                  let native = UUID(uuidString: thread), native.uuidString.lowercased() == thread,
                  request.selectedSourceOnly, !request.discovering, !request.archived,
                  request.children.isEmpty, request.visited.isEmpty, request.nativeChildParents.isEmpty,
                  !request.hasReplayCursor, !request.partial, !request.threadPartial,
                  !request.threadReadBeganAtStart, !request.threadHasInWindowItems, !request.liveBootstrapped,
                  request.consecutiveBudgetFailures == 0,
                  request.threadListCursor == nil, request.itemCursor == nil, request.replayCursor == nil,
                  request.pageLimit == nil, request.threadUpdatedAt == nil, request.threadListedAt == nil,
                  request.threadNativeChildParentID == nil, request.transcriptPath == nil else {
                throw CodexCollectionError.invalidConfiguration
            }
            return audit
        } catch { throw CodexCollectionError.invalidConfiguration }
    }

    public func initialHistoricalCapture(audit: HistoricalAuditContext,
                                         source: CoverageSourceRetryDescriptor) async throws -> CapturePacket {
        guard source.scope == collectionScope,
              let session = source.session, session.provider == .codex, session.profileID == profileID,
              codexNativeIdentifier(.string(session.sessionID)) != nil else { throw CodexCollectionError.invalidConfiguration }
        var request = CodexHistoryRequest(audit: audit, threads: [session.sessionID])
        request.selectedSourceOnly = true
        if authority == .nativeRolloutTranscript {
            guard let url = source.sourceURL, url.isFileURL else { throw CodexCollectionError.invalidConfiguration }
            _ = try transcriptURL(path: url.path)
            request.transcriptPath = url.path
        }
        return try packet(request)
    }

    func selectAuthority(sessionID: String) async throws {
        let session = try SessionIdentity(provider: .codex, profileID: profileID, sessionID: sessionID)
        let desired = try CollectionAuthorityChoice(session: session, adapterVersion: Self.adapterVersion, authorityID: authority.rawValue)
        if let previous = try await authorityLookup(session) {
            guard previous.session == desired.session, previous.authorityID == desired.authorityID else { throw CodexCollectionError.authorityConflict }
        } else { try await authorityRecorder(desired) }
        guard let committed = try await authorityLookup(session),
              committed.session == desired.session, committed.authorityID == desired.authorityID else { throw CodexCollectionError.missingAuthority }
    }

    public func importPublicItems(_ page: CodexHistoryPage, thread: CodexJSON, observedAt: Date,
                                  provenance: SourceProvenance = .live,
                                  turnTimes: [String: DateInterval] = [:],
                                  cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        guard authority == .publicNativeItems, let threadID = codexNativeIdentifier(thread["id"]) else { throw CodexCollectionError.authorityConflict }
        guard isEligible else { return .init(sources: [], coverageGaps: [.init(reason: .unsupportedVersion,
            scope: collectionScope, operation: provenance.collectionOperation, observedAt: observedAt)]) }
        let producerVersion = recordedProducerVersion(thread["cliVersion"])
        try await selectAuthority(sessionID: threadID)
        let session = try SessionIdentity(provider: .codex, profileID: profileID, sessionID: threadID)
        let context = RetainedSourceContext(sessionIdentifier: threadID, title: thread["name"].string,
            projectPath: thread["cwd"].string, transcriptPath: thread["path"].string)
        var sources: [CollectedSource] = [], gaps: [CoverageGap] = [], recovered: [CoverageRecoveryReference] = []
        for entry in page.data {
            try Task.checkCancellation()
            let item = entry["item"], type = item["type"].string, id = codexNativeIdentifier(item["id"])
            var kind = codexContentType(item)
            var date: Date?
            func gap(_ reason: CoverageGapReason, required: Bool = false,
                     diagnostic: CoverageDiagnosticCode? = nil, excluded: Bool = false,
                     constraint: CoverageRecoveryConstraint? = nil) {
                gaps.append(.init(reason: reason, scope: collectionScope, contentType: kind, operation: provenance.collectionOperation,
                    recovery: .init(session: session, locator: id == nil ? .unavailable : .upstreamItem,
                        itemID: id, contentTime: date, parserContract: Self.parserContract, constraint: constraint),
                    isRequiredFormatFailure: required, sourceKind: codexSourceKind(type),
                    diagnosticCode: diagnostic ?? reason.defaultDiagnosticCode, excludedContent: excluded ? true : nil, observedAt: observedAt))
            }
            // A tool still running is retried later; any other unrecognized status is malformed.
            func unfinishedGap(_ status: String?) {
                gap(status == "inProgress" ? .incompleteMessage : .malformedSource, required: status != "inProgress")
            }
            func encryptedGap(_ content: CodexJSON) -> Bool {
                let encrypted = codexEncryptedContentState(content)
                if encrypted.present {
                    gap(encrypted.malformed ? .malformedSource : .unsupportedContent, required: true,
                        diagnostic: encrypted.malformed ? .invalidFieldType : .encryptedContentUnavailable)
                }
                return encrypted.present
            }
            guard (try JSONEncoder().encode(entry)).count <= limits.maximumRowBytes else {
                gap(.budgetExhausted, required: type == "plan" || type == "hookPrompt"); continue
            }
            guard let turnID = entry["turnId"].nonemptyString, let id, let type else { gap(.malformedSource, required: kind != nil); continue }
            if let milliseconds = entry["completedAtMs"].number ?? entry["startedAtMs"].number,
               milliseconds.isFinite, abs(milliseconds) < 1e15 {
                date = Date(timeIntervalSince1970: milliseconds / 1000)
            } else if entry["completedAtMs"] != .null || entry["startedAtMs"] != .null {
                gap(.malformedSource, required: kind != nil); continue
            } else if let interval = turnTimes[turnID] {
                if case .historical(let audit) = provenance,
                   (interval.start < audit.start && interval.end >= audit.start || interval.start <= audit.end && interval.end > audit.end) {
                    gap(.missingTimestamp); continue
                }
                date = type == "userMessage" ? interval.start : interval.end
            } else { gap(.missingTimestamp); continue }
            guard let date else { continue }
            if case .historical(let audit) = provenance, !audit.includes(contentTime: date) { continue }
            var segments: [SourceSegment]
            var recoveryConstraint: CoverageRecoveryConstraint?
            var hasContentGap = false, excludedContent = false, localMediaProofEligible = false
            switch type {
            case "userMessage":
                kind = .userPrompt
                let parsed = try codexMessageSegments(item["content"], pointer: "/content", recognizeLocalMedia: true)
                segments = parsed.segments
                hasContentGap = encryptedGap(item["content"])
                localMediaProofEligible = parsed.localMediaProofEligible
                excludedContent = parsed.recognizedLocalMedia || codexContainsBinaryContent(item["content"])
                if parsed.malformed { gap(.malformedSource, required: true); hasContentGap = true }
                if parsed.unsupported { gap(.unsupportedContent, required: true, diagnostic: .unknownBlockKind); hasContentGap = true }
            case "hookPrompt":
                // Codex records hook continuation input as its own user-role item.
                // Preserve its decoded fragments, never a callback's run identifier
                // or a human message that happens to contain similar XML.
                kind = .userPrompt
                guard let fragments = item["fragments"].array else {
                    gap(.malformedSource, required: true,
                        diagnostic: item["fragments"] == .null ? .missingPayload : .invalidFieldType); continue
                }
                segments = []
                var textBytes = 0, pointerBytes = 0
                for (index, fragment) in fragments.enumerated() {
                    guard index < 1024 else {
                        gap(.budgetExhausted, required: true, diagnostic: .readBudgetExceeded); hasContentGap = true; break
                    }
                    if index % 64 == 0 { try Task.checkCancellation() }
                    guard fragment.object != nil else {
                        gap(.malformedSource, required: true, diagnostic: .invalidFieldType); hasContentGap = true; continue
                    }
                    if let runID = codexNativeIdentifier(fragment["hookRunId"]),
                       !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Metadata validates the fragment shape; it is never scanned
                        // or substituted for the native message/source identity.
                    } else {
                        gap(.malformedSource, required: true,
                            diagnostic: fragment["hookRunId"] == .null ? .missingPayload : .invalidFieldType)
                        hasContentGap = true
                    }
                    guard let text = fragment["text"].string else {
                        gap(.malformedSource, required: true,
                            diagnostic: fragment["text"] == .null ? .missingPayload : .invalidFieldType)
                        hasContentGap = true; continue
                    }
                    guard !text.isEmpty else { continue }
                    let pointer = "/fragments/\(index)/text", bytes = Data(text.utf8)
                    guard bytes.count <= limits.maximumRowBytes - textBytes,
                          pointer.utf8.count <= limits.maximumRowBytes - pointerBytes else {
                        gap(.budgetExhausted, required: true, diagnostic: .readBudgetExceeded); hasContentGap = true; break
                    }
                    segments.append(try .init(id: pointer, utf8: bytes))
                    textBytes += bytes.count; pointerBytes += pointer.utf8.count
                }
            case "agentMessage":
                // Native assistant phase is nullable (including rendered review
                // replies). Preserve that original text without claiming finality;
                // a missing field or unknown value is still a format gap.
                guard let phase = item.object?["phase"],
                      phase == .null || ["commentary", "partial_answer", "final_answer"].contains(phase.string ?? "") else {
                    gap(.unsupportedContent, required: true); continue
                }
                kind = phase.string == "final_answer" ? .finalResponse : .intermediateResponse
                guard item["text"].string != nil else { gap(.malformedSource, required: true); continue }
                segments = try codexTextSegments(item["text"], pointer: "/text")
            case "plan":
                // Native plan-mode text is removed from AgentMessage and retained in
                // its own Plan item. The public item has no phase, so do not attest
                // that it came from a final-answer message.
                kind = .intermediateResponse
                guard item["text"].string != nil else {
                    gap(.malformedSource, required: true,
                        diagnostic: item["text"] == .null ? .missingPayload : .invalidFieldType); continue
                }
                segments = try codexTextSegments(item["text"], pointer: "/text")
            case "commandExecution":
                let status = item["status"].string
                guard ["completed", "failed", "declined"].contains(status ?? "") else {
                    unfinishedGap(status); continue
                }
                if status == "completed" {
                    guard let code = item["exitCode"].number, code.isFinite, code.rounded() == code else {
                        gap(.malformedSource, required: true); continue
                    }
                    kind = code == 0 ? .toolOutput : .toolError
                } else { kind = .toolError }
                // The native projection converts empty command output to explicit
                // null. A missing field is still malformed, not proven silence.
                guard let output = item.object?["aggregatedOutput"], output.string != nil || output == .null else {
                    gap(.malformedSource, required: true); continue
                }
                segments = try codexTextSegments(output, pointer: "/aggregatedOutput")
            case "mcpToolCall":
                let status = item["status"].string
                guard ["completed", "failed"].contains(status ?? "") else {
                    unfinishedGap(status); continue
                }
                kind = status == "failed" || item["error"] != .null ? .toolError : .toolOutput
                guard item["result"] != .null || item["error"] != .null else {
                    gap(.malformedSource, required: true, diagnostic: .missingPayload); continue
                }
                guard codexStructuredTextContract(item["result"]), codexStructuredTextContract(item["error"]) else {
                    gap(.malformedSource, required: true); continue
                }
                // MCP structuredContent is opaque result JSON, not a content-block
                // list. Only the protocol envelope retains media/encryption semantics.
                var protocolResult = item["result"]
                if var fields = protocolResult.object {
                    fields.removeValue(forKey: "structuredContent")
                    protocolResult = .object(fields)
                }
                let result = try codexToolSegments(protocolResult, pointer: "/result")
                let error = try codexToolSegments(item["error"], pointer: "/error")
                let protocolSegments = result.segments + error.segments
                let protocolTextBytes = protocolSegments.reduce(0) { $0 + $1.utf8.count }
                let protocolPointerBytes = protocolSegments.reduce(0) { $0 + $1.id.utf8.count }
                var structured = CodexWebSearchContent(
                    maximumTextBytes: max(0, limits.maximumRowBytes - protocolTextBytes),
                    maximumPointerBytes: max(0, limits.maximumRowBytes - protocolPointerBytes))
                if item["result"]["structuredContent"] != .null {
                    try structured.collect(item["result"]["structuredContent"], pointer: "/result/structuredContent")
                }
                // The native result contract orders _meta, content, structuredContent.
                // Retain existing segment order and coordinates across the parser upgrade.
                segments = result.segments + structured.segments + error.segments
                hasContentGap = encryptedGap(.array([protocolResult, item["error"]]))
                excludedContent = codexContainsBinaryContent(protocolResult) || codexContainsBinaryContent(item["error"])
                if result.malformed || error.malformed { gap(.malformedSource, required: true); hasContentGap = true }
                if result.unsupported || error.unsupported { gap(.unsupportedContent, required: true, diagnostic: .unknownBlockKind); hasContentGap = true }
                if structured.budgetExceeded {
                    gap(.budgetExhausted, required: true, diagnostic: .readBudgetExceeded); hasContentGap = true
                }
            case "dynamicToolCall":
                let status = item["status"].string
                guard ["completed", "failed"].contains(status ?? "") else {
                    unfinishedGap(status); continue
                }
                guard item["success"] == .null || item["success"].bool != nil else {
                    gap(.malformedSource, required: true, diagnostic: .invalidFieldType); continue
                }
                kind = status == "failed" || item["success"].bool == false ? .toolError : .toolOutput
                // The public protocol uses contentItems. Retain the original pointer for older
                // recordings that used content; changing that pointer would duplicate ranges.
                let field = item.object?["contentItems"] != nil ? "contentItems" : "content"
                guard item[field] != .null else { gap(.malformedSource, required: true, diagnostic: .missingPayload); continue }
                guard item[field].array != nil else { gap(.malformedSource, required: true, diagnostic: .invalidFieldType); continue }
                let parsed = try codexToolSegments(item[field], pointer: "/\(field)", blockList: true)
                segments = parsed.segments
                hasContentGap = encryptedGap(item[field])
                excludedContent = codexContainsBinaryContent(item[field])
                if parsed.malformed { gap(.malformedSource, required: true); hasContentGap = true }
                if parsed.unsupported { gap(.unsupportedContent, required: true, diagnostic: .unknownBlockKind); hasContentGap = true }
            case "functionCallOutput":
                kind = .toolOutput
                guard item["output"].string != nil || item["output"].array != nil else {
                    gap(.malformedSource, required: true, diagnostic: item["output"] == .null ? .missingPayload : .invalidFieldType); continue
                }
                let parsed = try codexToolSegments(item["output"], pointer: "/output", blockList: true)
                segments = parsed.segments
                hasContentGap = encryptedGap(item["output"])
                excludedContent = codexContainsBinaryContent(item["output"])
                if parsed.malformed { gap(.malformedSource, required: true); hasContentGap = true }
                if parsed.unsupported { gap(.unsupportedContent, required: true, diagnostic: .unknownBlockKind); hasContentGap = true }
            case "webSearch":
                // 0.162.1's public WebSearchItem optionally carries opaque standalone
                // result JSON. Query/action describe the request, never returned content.
                kind = .toolOutput
                guard item["results"] != .null else {
                    gap(.unsupportedContent, required: true, diagnostic: .missingPayload); continue
                }
                guard item["results"].array != nil else {
                    gap(.malformedSource, required: true, diagnostic: .invalidFieldType); continue
                }
                var parsed = CodexWebSearchContent(maximumTextBytes: limits.maximumRowBytes,
                    maximumPointerBytes: limits.maximumRowBytes)
                try parsed.collect(item["results"])
                segments = parsed.segments
                if parsed.budgetExceeded {
                    gap(.budgetExhausted, required: true, diagnostic: .readBudgetExceeded); hasContentGap = true
                }
            case "sleep":
                // The pinned producer emits only requested-duration display metadata,
                // even before it checks the sleep result. This item has no returned
                // text and establishes no success, failure, or interruption outcome.
                guard let fields = item.object,
                      Set(fields.keys).isSubset(of: ["type", "id", "durationMs"]) else {
                    gap(.unsupportedContent, required: true); continue
                }
                guard let duration = item["durationMs"].number, duration.isFinite,
                      duration.rounded() == duration, (1...43_200_000).contains(duration) else {
                    gap(.malformedSource, required: true,
                        diagnostic: item["durationMs"] == .null ? .missingPayload : .invalidFieldType); continue
                }
                segments = []
                // A newly recognized metadata shape cannot settle an old required
                // content or scanner omission that happens to share its native ID.
                recoveryConstraint = .unclassifiedMetadata
            case "subAgentActivity", "collabAgentToolCall", "reasoning", "contextCompaction": continue
            default: gap(.unsupportedContent); continue
            }
            if excludedContent {
                // This is an exclusion, never a successful scan or general item
                // recovery. Only the complete recognized message shape may
                // reclassify its former unknown-local-block warning.
                gap(.unsupportedContent, diagnostic: .excludedBinaryContent, excluded: true,
                    constraint: localMediaProofEligible && !hasContentGap ? .recognizedLocalMedia : nil)
                hasContentGap = true
            }
            if !segments.isEmpty, let kind {
                sources.append(try await source(sessionID: threadID, itemID: id, kind: kind, segments: segments,
                    date: date, observedAt: observedAt, provenance: provenance, locator: .upstreamItem,
                    context: context, producerVersion: producerVersion, cryptography: cryptography))
            }
            if !hasContentGap {
                recovered.append(.init(session: session, locator: .upstreamItem, itemID: id, contentTime: date,
                    parserContract: Self.parserContract, constraint: recoveryConstraint))
            }
        }
        return .init(sources: sources, coverageGaps: Array(Set(gaps)), recoveredReferences: recovered)
    }

    public func importTranscript(_ data: Data, documentID: UUID, observedAt: Date,
                                 provenance: SourceProvenance = .live, expectedSessionID: String,
                                 context: RetainedSourceContext? = nil,
                                 cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        guard authority == .nativeRolloutTranscript, interface == .t3 else { throw CodexCollectionError.authorityConflict }
        guard codexNativeIdentifier(.string(expectedSessionID)) != nil else { throw CodexCollectionError.invalidConfiguration }
        guard isEligible else { return .init(sources: [], coverageGaps: [.init(reason: .unsupportedVersion,
            scope: collectionScope, operation: provenance.collectionOperation, observedAt: observedAt)]) }
        // Establish the native session authority before emitting rows. Producer metadata is
        // provenance and can be absent or different from the external reader's version.
        let completeRows = data.prefix(limits.maximumBytes).split(separator: 10, omittingEmptySubsequences: false).dropLast()
        guard let metadata = completeRows.lazy.compactMap({ try? JSONDecoder().decode(CodexJSON.self, from: Data($0)) })
            .first(where: { $0["type"].string == "session_meta" }),
            metadata["payload"]["id"].string == expectedSessionID else { throw CodexCollectionError.malformedCapture }
        let producerVersion = recordedProducerVersion(metadata["payload"]["cli_version"])
        try await selectAuthority(sessionID: expectedSessionID)
        let session = try SessionIdentity(provider: .codex, profileID: profileID, sessionID: expectedSessionID)
        var sources: [CollectedSource] = [], gaps: [CoverageGap] = [], recovered: [CoverageRecoveryReference] = []
        var offset = 0, index: UInt64 = 0
        let bounded = data.prefix(limits.maximumBytes)
        for line in bounded.split(separator: 10, omittingEmptySubsequences: false) {
            try Task.checkCancellation()
            let locator = SourceLocator.transcript(documentID: documentID, recordIndex: index)
            var kind: ContentType?, date: Date?
            func gap(_ reason: CoverageGapReason, required: Bool = false,
                     diagnostic: CoverageDiagnosticCode? = nil, excluded: Bool = false) {
                gaps.append(.init(reason: reason, scope: collectionScope, contentType: kind, operation: provenance.collectionOperation,
                    recovery: .init(session: session, locator: locator, contentTime: date, parserContract: Self.parserContract,
                        sourceURL: context?.transcriptPath.map { URL(fileURLWithPath: $0) }),
                    isRequiredFormatFailure: required, diagnosticCode: diagnostic ?? reason.defaultDiagnosticCode,
                    excludedContent: excluded ? true : nil, observedAt: observedAt))
            }
            func encryptedGap(_ content: CodexJSON) -> Bool {
                let encrypted = codexEncryptedContentState(content)
                if encrypted.present {
                    gap(encrypted.malformed ? .malformedSource : .unsupportedContent, required: true,
                        diagnostic: encrypted.malformed ? .invalidFieldType : .encryptedContentUnavailable)
                }
                return encrypted.present
            }
            if offset + line.count >= bounded.count { if !line.isEmpty { gap(.incompleteMessage) }; break }
            if index >= limits.maximumRows { gap(.budgetExhausted); break }
            defer { offset += line.count + 1; index += 1 }
            guard !line.isEmpty else { continue }
            guard line.count <= limits.maximumRowBytes else { gap(.budgetExhausted); continue }
            guard let row = try? JSONDecoder().decode(CodexJSON.self, from: Data(line)) else { gap(.malformedSource); continue }
            let body = row["payload"]
            if row["type"].string == "session_meta" {
                guard body["id"].string == expectedSessionID else { throw CodexCollectionError.authorityConflict }
                guard recordedProducerVersion(body["cli_version"]) == producerVersion else { throw CodexCollectionError.malformedCapture }
                continue
            }
            guard row["type"].string == "response_item" else { continue }
            if body["type"].string == "message" {
                kind = body["role"].string == "user" ? .userPrompt
                    : body["phase"].string == "final_answer" ? .finalResponse : .intermediateResponse
            } else if body["type"].string == "agent_message", codexIncomingChildMessage(body, metadata: metadata["payload"]) {
                kind = .userPrompt
            } else if ["function_call_output", "custom_tool_call_output"].contains(body["type"].string ?? "") { kind = .toolOutput }
            guard let timestamp = row["timestamp"].string, let parsedDate = codexTimestamp(timestamp) else {
                gap(.missingTimestamp, required: body["type"].string == "agent_message" && kind == .userPrompt); continue
            }
            date = parsedDate
            if case .historical(let audit) = provenance, !audit.includes(contentTime: parsedDate) { continue }
            let id: String
            var segments: [SourceSegment], hasContentGap = false, excludedContent = false
            switch body["type"].string {
            case "message":
                guard let nativeID = codexNativeIdentifier(body["id"]) else { gap(.malformedSource, required: true); continue }
                id = nativeID
                if body["role"].string == "user" { kind = .userPrompt }
                else if body["role"].string == "assistant", let phase = body["phase"].string,
                        ["commentary", "final_answer"].contains(phase) {
                    kind = phase == "final_answer" ? .finalResponse : .intermediateResponse
                } else if body["role"].string == "system" || body["role"].string == "developer" { continue }
                else { gap(.unsupportedContent, required: true); continue }
                let parsed = try codexMessageSegments(body["content"], pointer: "/content")
                segments = parsed.segments
                hasContentGap = encryptedGap(body["content"])
                excludedContent = codexContainsBinaryContent(body["content"])
                if parsed.malformed { gap(.malformedSource, required: true); hasContentGap = true }
                if parsed.unsupported { gap(.unsupportedContent); hasContentGap = true }
            case "agent_message":
                // The original child's metadata and recipient establish an incoming parent
                // task. Mirrored replies or unrelated agent messages are not child prompts.
                guard codexIncomingChildMessage(body, metadata: metadata["payload"]) else {
                    gap(.unresolvedCorrelation, required: true, diagnostic: .unresolvedIdentity); continue
                }
                kind = .userPrompt
                guard let nativeID = codexNativeIdentifier(body["id"]) else {
                    gap(.malformedSource, required: true); continue
                }
                id = nativeID
                let parsed = try codexMessageSegments(body["content"], pointer: "/content")
                segments = parsed.segments
                hasContentGap = encryptedGap(body["content"])
                excludedContent = codexContainsBinaryContent(body["content"])
                if parsed.malformed { gap(.malformedSource, required: true); hasContentGap = true }
                if parsed.unsupported { gap(.unsupportedContent, required: true, diagnostic: .unknownBlockKind); hasContentGap = true }
            case "function_call_output", "custom_tool_call_output":
                guard let call = codexNativeIdentifier(body["call_id"]) else { gap(.malformedSource, required: true); continue }
                id = "tool:\(call)"
                guard codexStructuredTextContract(body["output"]), body["output"] != .null else { gap(.malformedSource, required: true); continue }
                let decoded = try codexNativeOutput(body["output"], pointer: "/output")
                kind = decoded.failed ? .toolError : .toolOutput; segments = decoded.segments
                hasContentGap = encryptedGap(.array(decoded.encryptedBlocks))
                excludedContent = codexContainsBinaryContent(body["output"])
            case "function_call", "custom_tool_call", "reasoning": continue
            default: gap(.unsupportedContent); continue
            }
            if excludedContent {
                // An exclusion, never a successful scan, matching the public route.
                gap(.unsupportedContent, diagnostic: .excludedBinaryContent, excluded: true)
                hasContentGap = true
            }
            if !segments.isEmpty, let kind {
                sources.append(try await source(sessionID: expectedSessionID, itemID: id, kind: kind,
                    segments: segments, date: parsedDate, observedAt: observedAt, provenance: provenance,
                    locator: locator, context: context, producerVersion: producerVersion, cryptography: cryptography))
            }
            if !hasContentGap {
                recovered.append(.init(session: session, locator: locator, contentTime: parsedDate, parserContract: Self.parserContract))
            }
        }
        if data.count > limits.maximumBytes { gaps.append(.init(reason: .budgetExhausted, scope: collectionScope,
            operation: provenance.collectionOperation, diagnosticCode: .readBudgetExceeded, observedAt: observedAt)) }
        return .init(sources: sources, coverageGaps: Array(Set(gaps)), recoveredReferences: recovered)
    }

    private func source(sessionID: String, itemID: String, kind: ContentType, segments: [SourceSegment], date: Date,
                        observedAt: Date, provenance: SourceProvenance, locator: SourceLocator,
                        context: RetainedSourceContext?, producerVersion: String,
                        cryptography: BackgroundCryptography) async throws -> CollectedSource {
        let identity = try SourceIdentity(session: .init(provider: .codex, profileID: profileID, sessionID: sessionID), itemID: itemID)
        let origin = try SourceOrigin(adapterID: "codex", adapterVersion: Self.adapterVersion, agentVersion: producerVersion,
            interface: interface, provenance: provenance, canonicalization: .exclusiveAuthority)
        let metadata = try SourceRecordMetadata(identity: identity, contentType: kind, contentTime: date,
            observedAt: observedAt, locator: locator, origin: origin)
        let revision = try await cryptography.revision(canonicalBytes: codexCanonicalBytes(segments))
        return try .init(record: SourceRecord(metadata: metadata, revision: revision, segments: segments), context: context)
    }
    var isEligible: Bool {
        CollectionCompatibility.isEligible(provider: .codex, interface: interface, version: agentVersion)
    }
    var collectionScope: CollectionScope {
        .init(provider: .codex, profileID: profileID, interface: interface,
              path: authority.collectionPath)
    }
    func recordedProducerVersion(_ value: CodexJSON) -> String {
        guard let version = value.nonemptyString, version.utf8.count <= 256, !version.utf8.contains(0) else {
            return CollectionCompatibility.unknownProducerVersion
        }
        return version
    }
    func packet(_ request: CodexHistoryRequest) throws -> CapturePacket {
        try .init(metadata: .init(agent: .codex, interface: interface, profileID: profileID), eventJSON: JSONEncoder().encode(request))
    }
    func documentIdentity(_ path: String, cryptography: BackgroundCryptography) async throws -> UUID {
        let bytes = Array(try await cryptography.revision(canonicalBytes: Data("codex-document-v1\u{0}\(profileID)\u{0}\(path)".utf8)).keyedDigest.prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    func transcriptURL(path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw CodexCollectionError.unsafeTranscriptPath }
        let original = URL(fileURLWithPath: path).standardizedFileURL
        var url = original
        for root in rootAliases where original.path.hasPrefix(root.original.path + "/") {
            url = root.resolved.appendingPathComponent(String(original.path.dropFirst(root.original.path.count + 1))); break
        }
        guard url.pathExtension == "jsonl", allowedTranscriptRoots.contains(where: { url.path.hasPrefix($0.path + "/") }) else {
            throw CodexCollectionError.unsafeTranscriptPath
        }
        return url
    }
    func readTranscript(path: String) throws -> Data {
        let url = try transcriptURL(path: path)
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw CodexCollectionError.unsafeTranscriptPath }; defer { Darwin.close(fd) }
        let parts = url.path.split(separator: "/")
        for (index, part) in parts.enumerated() {
            let next = String(part).withCString { openat(fd, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (index < parts.count - 1 ? O_DIRECTORY : 0)) }
            guard next >= 0 else { throw CodexCollectionError.awaitingHistory }; Darwin.close(fd); fd = next
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { throw CodexCollectionError.unsafeTranscriptPath }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while bytes.count <= limits.maximumBytes {
            try Task.checkCancellation()
            let n = Darwin.read(fd, &buffer, min(buffer.count, limits.maximumBytes + 1 - bytes.count))
            if n == 0 { break }; if n < 0 { if errno == EINTR { continue }; throw CodexCollectionError.awaitingHistory }
            bytes.append(contentsOf: buffer.prefix(n))
        }
        return bytes
    }
}

func codexTimestamp(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}
private func codexNativeIdentifier(_ value: CodexJSON) -> String? {
    guard let id = value.nonemptyString, id.utf8.count <= 4096, !id.utf8.contains(0) else { return nil }
    return id
}

/// The measured native representation identifies the receiver by its own agent path and
/// repeats the parent thread in source metadata. Do not infer identity from message text.
private func codexIncomingChildMessage(_ body: CodexJSON, metadata: CodexJSON) -> Bool {
    let spawn = metadata["source"]["subagent"]["thread_spawn"]
    guard let child = codexNativeIdentifier(metadata["id"]),
          let parent = codexNativeIdentifier(spawn["parent_thread_id"]), parent != child,
          metadata["parent_thread_id"] == .null || metadata["parent_thread_id"].string == parent,
          let path = codexNativeIdentifier(metadata["agent_path"]), path.hasPrefix("/"),
          spawn["agent_path"].string == path, body["recipient"].string == path else { return false }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count >= 3, components.first == "", components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
    return body["author"].string == components.dropLast().joined(separator: "/")
}

private func codexEncryptedContentState(_ value: CodexJSON) -> (present: Bool, malformed: Bool) {
    if value["type"].string == "encrypted_content" {
        return (true, value["encrypted_content"].nonemptyString == nil)
    }
    let children = value.array ?? value.object.map { Array($0.values) } ?? []
    return children.reduce((false, false)) { result, child in
        let next = codexEncryptedContentState(child)
        return (result.0 || next.present, result.1 || next.malformed)
    }
}

func codexTextSegments(_ value: CodexJSON, pointer: String) throws -> [SourceSegment] {
    switch value {
    case .string(let text): return text.isEmpty ? [] : [try .init(id: pointer, utf8: Data(text.utf8))]
    case .array(let values): return try values.enumerated().flatMap { try codexTextSegments($0.element, pointer: "\(pointer)/\($0.offset)") }
    case .object(let values):
        if codexBinaryContentTypes.contains(value["type"].string ?? "") || value["type"].string == "tool_reference" { return [] }
        return try values.keys.sorted().flatMap { key -> [SourceSegment] in
            if key == "type", ["text", "input_text", "output_text", "inputText"].contains(value["type"].string ?? "") { return [] }
            return try codexTextSegments(values[key]!, pointer: pointer + "/" + key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1"))
        }
    default: return []
    }
}
private func codexCanonicalBytes(_ segments: [SourceSegment]) -> Data {
    var bytes = Data("codex-segments-v1".utf8)
    for segment in segments { for data in [Data(segment.id.utf8), segment.utf8] {
        var count = UInt64(data.count).bigEndian; withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }; bytes.append(data)
    } }
    return bytes
}
/// Only a direct element of a native content-item list is an encryption block. Object JSON
/// below it, including printed JSON, is opaque tool data and stays scannable.
private func codexNativeOutput(_ value: CodexJSON, pointer: String) throws
    -> (segments: [SourceSegment], failed: Bool, encryptedBlocks: [CodexJSON]) {
    if let values = value.array {
        var segments: [SourceSegment] = [], failed = false, encryptedBlocks: [CodexJSON] = []
        for (index, block) in values.enumerated() {
            if block["type"].string == "encrypted_content" { encryptedBlocks.append(block); continue }
            let result = try codexNativeOutput(block, pointer: "\(pointer)/\(index)")
            segments += result.segments; failed = failed || result.failed
            encryptedBlocks += result.encryptedBlocks
        }
        return (segments, failed, encryptedBlocks)
    }
    if let text = value.string ?? value["text"].string,
       let encoded = text.data(using: .utf8), let object = try? JSONDecoder().decode(CodexJSON.self, from: encoded), object.object != nil {
        if object["output"].string != nil, let status = object["exit_code"].number {
            return (try codexTextSegments(object, pointer: pointer + "/decoded"), status != 0, [])
        }
        let segments = try codexTextSegments(object, pointer: pointer + "/decoded")
        return (segments, object["isError"].bool == true, [])
    }
    return (try codexTextSegments(value, pointer: pointer), value["isError"].bool == true, [])
}

private func codexContentType(_ item: CodexJSON) -> ContentType? {
    switch item["type"].string {
    case "userMessage", "hookPrompt": return .userPrompt
    case "agentMessage": return item["phase"].string == "final_answer" ? .finalResponse : .intermediateResponse
    case "plan": return .intermediateResponse
    case "commandExecution":
        return item["status"].string == "completed" && item["exitCode"].number == 0 ? .toolOutput : .toolError
    case "mcpToolCall": return item["status"].string == "failed" || item["error"] != .null ? .toolError : .toolOutput
    case "dynamicToolCall": return item["status"].string == "failed" || item["success"].bool == false ? .toolError : .toolOutput
    case "functionCallOutput", "webSearch": return .toolOutput
    default: return nil
    }
}

/// Message blocks are recognized individually; tool-result payloads retain recursive strings.
private func codexMessageSegments(_ value: CodexJSON, pointer: String, recognizeLocalMedia: Bool = false) throws ->
    (segments: [SourceSegment], malformed: Bool, unsupported: Bool, recognizedLocalMedia: Bool, localMediaProofEligible: Bool) {
    guard let blocks = value.array else { return ([], true, false, false, false) }
    var segments: [SourceSegment] = [], malformed = false, unsupported = false, localMedia = false
    for (index, block) in blocks.enumerated() {
        if index % 64 == 0 { try Task.checkCancellation() }
        switch block["type"].string {
        case "text", "input_text", "output_text", "inputText":
            guard block["text"].string != nil else { malformed = true; continue }
            segments += try codexTextSegments(block["text"], pointer: "\(pointer)/\(index)/text")
        case "localImage", "localAudio":
            // These are public UserInput variants. The same strings inside raw
            // transcript blocks or opaque tool JSON acquire no media semantics.
            guard recognizeLocalMedia else { unsupported = true; continue }
            let image = block["type"].string == "localImage"
            let keys: Set<String> = image ? ["type", "path", "detail"] : ["type", "path"]
            guard let fields = block.object, Set(fields.keys).isSubset(of: keys) else {
                unsupported = true; continue
            }
            guard let path = block["path"].nonemptyString, path.utf8.count <= 4096, !path.utf8.contains(0) else {
                malformed = true; continue
            }
            if let detail = fields["detail"], detail != .null {
                guard let value = detail.string else { malformed = true; continue }
                guard ["auto", "low", "high", "original"].contains(value) else { unsupported = true; continue }
            }
            localMedia = true
        case "image", "image_url", "input_image", "inputImage", "audio", "input_audio", "inputAudio", "tool_reference", "encrypted_content": continue
        case nil: malformed = true
        default: unsupported = true
        }
    }
    var proofEligible = false
    if localMedia && !malformed && !unsupported {
        proofEligible = try codexLocalMediaProofComplete(blocks)
    }
    return (segments, malformed, unsupported, localMedia, proofEligible)
}

/// A stricter proof boundary than legacy message parsing. Uncertain sibling
/// metadata withholds reclassification without changing its existing text/gaps.
/// In particular, never downgrade an old warning from a future text-bearing
/// field just because another block is a recognized local attachment.
private func codexLocalMediaProofComplete(_ blocks: [CodexJSON]) throws -> Bool {
    func nonemptyText(_ value: CodexJSON) -> Bool { value.nonemptyString.map { !$0.utf8.contains(0) } ?? false }
    func detail(_ fields: [String: CodexJSON]) -> Bool {
        guard let value = fields["detail"], value != .null else { return true }
        return ["auto", "low", "high", "original"].contains(value.string ?? "")
    }
    for (index, block) in blocks.enumerated() {
        if index % 64 == 0 { try Task.checkCancellation() }
        guard let fields = block.object else { return false }
        switch block["type"].string {
        case "localImage", "localAudio": continue // Validated by the public-only parser above.
        case "text":
            guard Set(fields.keys).isSubset(of: ["type", "text", "text_elements"]),
                  let text = block["text"].string else { return false }
            if let value = fields["text_elements"] {
                guard let elements = value.array else { return false }
                for (elementIndex, element) in elements.enumerated() {
                    if elementIndex % 64 == 0 { try Task.checkCancellation() }
                    guard let keys = element.object, Set(keys.keys) == ["byteRange", "placeholder"],
                          element["placeholder"] == .null || element["placeholder"].string != nil,
                          let range = element["byteRange"].object, Set(range.keys) == ["start", "end"],
                          let start = range["start"]?.number, let end = range["end"]?.number,
                          start.isFinite, end.isFinite, start.rounded() == start, end.rounded() == end,
                          start >= 0, end >= start, end <= Double(text.utf8.count) else { return false }
                }
            }
        case "image":
            guard Set(fields.keys).isSubset(of: ["type", "url", "fileId", "detail"]), detail(fields),
                  (fields["url"] != nil) != (fields["fileId"] != nil),
                  nonemptyText(block["url"]) || nonemptyText(block["fileId"]) else { return false }
        case "audio":
            guard Set(fields.keys) == ["type", "url"], nonemptyText(block["url"]) else { return false }
        default: return false
        }
    }
    return true
}

private func codexStructuredTextContract(_ value: CodexJSON) -> Bool {
    switch value {
    case .string, .array, .object, .null: return true
    default: return false
    }
}

private func codexToolSegments(_ value: CodexJSON, pointer: String, blockList: Bool = false) throws ->
    (segments: [SourceSegment], malformed: Bool, unsupported: Bool) {
    var segments: [SourceSegment] = [], malformed = false, unsupported = false
    switch value {
    case .array(let values):
        for (index, child) in values.enumerated() {
            if blockList {
                guard let type = child["type"].string else { malformed = true; continue }
                guard ["text", "input_text", "output_text", "inputText", "resource", "resource_link",
                    "image", "image_url", "input_image", "inputImage", "audio", "input_audio", "inputAudio", "encrypted_content", "tool_reference"].contains(type) else {
                    unsupported = true; continue
                }
            }
            let parsed = try codexToolSegments(child, pointer: "\(pointer)/\(index)")
            segments += parsed.segments; malformed = malformed || parsed.malformed; unsupported = unsupported || parsed.unsupported
        }
    case .object(let values):
        let type = value["type"].string
        if codexBinaryContentTypes.contains(type ?? "") || type == "tool_reference" || type == "encrypted_content" { return ([], false, false) }
        if ["text", "input_text", "output_text", "inputText"].contains(type ?? ""), value["text"].string == nil { malformed = true }
        for key in values.keys.sorted() {
            if key == "type", ["text", "input_text", "output_text", "inputText"].contains(type ?? "") { continue }
            let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
            let parsed = try codexToolSegments(values[key]!, pointer: pointer + "/" + escaped,
                blockList: key == "content" && values[key]!.array != nil)
            segments += parsed.segments; malformed = malformed || parsed.malformed; unsupported = unsupported || parsed.unsupported
        }
    case .string: segments = try codexTextSegments(value, pointer: pointer)
    default: break
    }
    return (segments, malformed, unsupported)
}

private let codexBinaryContentTypes: Set<String> = [
    "image", "image_url", "input_image", "inputImage", "audio", "input_audio", "inputAudio",
]

private func codexContainsBinaryContent(_ value: CodexJSON) -> Bool {
    if codexBinaryContentTypes.contains(value["type"].string ?? "") { return true }
    if let values = value.array { return values.contains(where: codexContainsBinaryContent) }
    if let values = value.object { return values.values.contains(where: codexContainsBinaryContent) }
    return false
}

private func codexSourceKind(_ type: String?) -> CoverageSourceKind {
    switch type {
    case "userMessage": .codexUserMessage
    case "hookPrompt": .codexHookPrompt
    case "agentMessage": .codexAgentMessage
    case "plan": .codexPlan
    case "commandExecution": .codexCommandExecution
    case "mcpToolCall": .codexMCPToolCall
    case "dynamicToolCall": .codexDynamicToolCall
    case "functionCallOutput": .codexFunctionCallOutput
    case "webSearch": .codexWebSearch
    default: .codexUnknownItem
    }
}
