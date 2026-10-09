import Darwin
import Foundation

public enum ClaudeCollectionError: Error, Equatable, Sendable {
    case invalidConfiguration, wrongProfile, malformedCapture, unsafeTranscriptPath
    /// The hook was delivered before its canonical transcript row became available. Retain/retry it.
    case awaitingTranscript
}

public struct ClaudeReadLimits: Sendable {
    public let maximumBytes: Int
    public let maximumRowBytes: Int
    public let maximumRows: Int
    public init(maximumBytes: Int = 8 * 1024 * 1024, maximumRowBytes: Int = 1024 * 1024,
                maximumRows: Int = 8192) {
        self.maximumBytes = maximumBytes; self.maximumRowBytes = maximumRowBytes
        self.maximumRows = maximumRows
    }
}

/// Version-isolated Claude Code collection. Raw strings and paths exist only in this transient batch.
/// Batch results need the exact transcript tool-use ID for source time and error classification.
/// Display IDs are never used as transcript IDs. Broad history discovery belongs to another layer.
public struct ClaudeAdapter: CaptureNormalizer, Sendable {
    public static let validatedAgentVersion = "2.1.293"
    public static let adapterVersion = "2"
    /// Cursor interpretation changes independently of native identities and canonical content.
    public static let parserContractVersion = "claude-transcript-5"
    /// Harness-injected configuration and context, including instruction files. None carries a
    /// user message, model response or tool result. Mentioned files, edited-file snippets,
    /// diagnostics, hook output and queued notifications are deliberately absent and stay gaps.
    static let contextAttachmentTypes: Set<String> = [
        "agent_listing_delta", "auto_mode", "command_permissions", "compact_file_reference", "credential_org",
        "date", "deferred_tools_delta", "deferred_tools_record", "environment", "instructions",
        "mcp_instructions_delta", "model", "nested_memory", "prompt_snapshot", "read_truncation_notice",
        "remote_session_change", "session_context", "silent_turn_reminder", "skill_listing",
        "thinking_drop", "total_tokens_reminder",
    ]
    public let profileID: String
    public let agentVersion: String
    public let allowedTranscriptRoots: [URL]
    public let limits: ClaudeReadLimits
    public let checkpointLookup: SourceCheckpointLookup
    public let historyBudget: HistoryReadBudget
    private let rootAliases: [(original: URL, resolved: URL)]

    public init(profileID: String, agentVersion: String, allowedTranscriptRoots: [URL],
                limits: ClaudeReadLimits = .init(),
                checkpointLookup: @escaping SourceCheckpointLookup = { _ in nil },
                historyBudget: HistoryReadBudget = .init()) throws {
        guard !profileID.isEmpty, !agentVersion.isEmpty,
              limits.maximumBytes > 0, limits.maximumBytes <= CapturePacket.maximumBodyBytes,
              limits.maximumRowBytes > 0, limits.maximumRowBytes <= limits.maximumBytes,
              limits.maximumRows > 0, historyBudget.maximumBytes > 0,
              historyBudget.maximumBytes <= 100 * 1024 * 1024,
              historyBudget.maximumDuration > 0, historyBudget.maximumDuration <= 30,
              historyBudget.maximumSources > 0, historyBudget.maximumSources <= 256,
              allowedTranscriptRoots.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }) else {
            throw ClaudeCollectionError.invalidConfiguration
        }
        self.profileID = profileID; self.agentVersion = agentVersion
        self.rootAliases = allowedTranscriptRoots.map { ($0.standardizedFileURL, claudeConfiguredURL($0)) }
        self.allowedTranscriptRoots = rootAliases.map(\.resolved)
        self.limits = limits
        self.checkpointLookup = checkpointLookup
        self.historyBudget = historyBudget
    }

    public func capabilities(interface: AgentInterface) -> [AdapterCapability] {
        var capabilities = ContentType.allCases.map { type in
            let supported = CollectionCompatibility.isEligible(provider: .claudeCode, interface: interface, version: agentVersion)
            return AdapterCapability(provider: .claudeCode, interface: interface,
                agentVersion: agentVersion, adapterVersion: Self.adapterVersion, contentType: type,
                path: .versionedTranscript, validation: supported
                    ? CollectionCompatibility.recordedEvidence(provider: .claudeCode, interface: interface, producerVersion: agentVersion) : .unsupported,
                canObserveActiveSession: supported, canReadHistoricalContent: supported,
                canonicalization: (type == .toolOutput || type == .toolError)
                    ? .sharedUpstreamIdentity : .exclusiveAuthority)
        }
        if interface == .standaloneCLI {
            capabilities += [ContentType.toolOutput, .toolError].map { type in
                AdapterCapability(provider: .claudeCode, interface: interface, agentVersion: agentVersion,
                    adapterVersion: Self.adapterVersion, contentType: type, path: .hook,
                    validation: CollectionCompatibility.recordedEvidence(provider: .claudeCode, interface: interface, producerVersion: agentVersion),
                    canObserveActiveSession: CollectionCompatibility.isEligible(provider: .claudeCode, interface: interface, version: agentVersion),
                    canReadHistoricalContent: false, canonicalization: .sharedUpstreamIdentity)
            }
        }
        return capabilities
    }

    public func normalize(_ packet: CapturePacket, capturedAt: Date,
                          cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        guard packet.metadata.agent == .claudeCode, packet.metadata.profileID == profileID else {
            throw ClaudeCollectionError.wrongProfile
        }
        guard CollectionCompatibility.isEligible(provider: .claudeCode, interface: packet.metadata.interface, version: agentVersion) else {
            return CollectionBatch(sources: [], coverageGaps: [.init(reason: .unsupportedVersion)])
        }
        if let request = try? JSONDecoder().decode(ClaudeHistoryRequest.self, from: packet.eventJSON),
           request.kind == ClaudeHistoryRequest.kind {
            return try await normalizeHistory(request, interface: packet.metadata.interface, cryptography: cryptography)
        }
        let hook: ClaudeJSON
        do { hook = try JSONDecoder().decode(ClaudeJSON.self, from: packet.eventJSON) }
        catch { return CollectionBatch(sources: [], coverageGaps: [.init(reason: .malformedSource)]) }
        guard let event = hook["hook_event_name"].string, let session = hook["session_id"].nonemptyString else {
            return CollectionBatch(sources: [], coverageGaps: [.init(reason: .malformedSource)])
        }
        let events = Set(["SessionStart", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure",
                          "PostToolBatch", "MessageDisplay", "SubagentStart", "SubagentStop", "Stop", "SpillcheckTranscriptPoll", "LeakretTranscriptPoll"])
        guard events.contains(event) else {
            return CollectionBatch(sources: [], coverageGaps: [.init(reason: .unsupportedContent)])
        }
        guard let mainPath = hook["transcript_path"].nonemptyString else {
            return CollectionBatch(sources: [], coverageGaps: [.init(reason: .sourceUnavailable)])
        }
        var paths = [mainPath]
        if event == "SubagentStop", let child = hook["agent_transcript_path"].nonemptyString {
            paths.append(child)
        }
        var sources: [CollectedSource] = [], gaps: [CoverageGap] = []
        var canonicalToolIDs = Set<String>()
        var canonicalPromptIDs = Set<String>()
        var checkpoints: [SourceCheckpoint] = []
        var recoveredReferences: [CoverageRecoveryReference] = []
        var continuationNeeded = false
        for path in paths {
            let checkpointID = try await checkpointIdentity(path: path, provenance: .live, cryptography: cryptography)
            let context = RetainedSourceContext(sessionIdentifier: session, title: nil,
                projectPath: hook["cwd"].string, transcriptPath: path, openingCapability: .unverified)
            let read: ClaudeIncrementalRead
            let previousCheckpoint = try await checkpointLookup(checkpointID)
            do {
                read = try await readIncremental(path: path, expectedSessionID: path == mainPath ? session : nil,
                    interface: packet.metadata.interface, checkpoint: previousCheckpoint,
                    observedAt: Date(), provenance: .live, context: context, cryptography: cryptography)
            }
            catch ClaudeCollectionError.unsafeTranscriptPath {
                return CollectionBatch(sources: [], coverageGaps: [.init(reason: .sourceUnavailable)])
            } catch { throw ClaudeCollectionError.awaitingTranscript }
            let batch = read.batch
            // Hook delivery can precede even the first complete transcript record. Throwing keeps
            // this encrypted capture in the bounded retry queue; hook text is never another source.
            if batch.sources.isEmpty, batch.coverageGaps.isEmpty, read.bytesRead == 0,
               (batch.checkpoints.first?.byteOffset ?? previousCheckpoint?.byteOffset ?? 0) == 0,
               !["SessionStart", "SpillcheckTranscriptPoll", "LeakretTranscriptPoll"].contains(event) {
                throw ClaudeCollectionError.awaitingTranscript
            }
            continuationNeeded = continuationNeeded || read.hasForwardContent
            sources += batch.sources; gaps += batch.coverageGaps
            recoveredReferences += batch.recoveredReferences
            if event == "SubagentStop", path != mainPath,
               !read.hasFinalResponse, !read.hasForwardContent {
                throw ClaudeCollectionError.awaitingTranscript
            }
            if path == mainPath {
                canonicalToolIDs.formUnion(read.toolIDs)
                canonicalPromptIDs.formUnion(read.promptIDs)
            }
            checkpoints += batch.checkpoints
        }
        if event == "PostToolUse" || event == "PostToolUseFailure" {
            guard let id = hook["tool_use_id"].nonemptyString else {
                return CollectionBatch(sources: sources, coverageGaps: gaps + [.init(reason: .malformedSource)], checkpoints: checkpoints,
                    recoveredReferences: recoveredReferences)
            }
            guard canonicalToolIDs.contains(id) || continuationNeeded else { throw ClaudeCollectionError.awaitingTranscript }
        }
        // Only a batch representation with exact shared identity AND canonical bytes is interchangeable.
        // Its date/error status always comes from the persisted record, never the hook observation time.
        if event == "PostToolBatch" {
            guard let calls = hook["tool_calls"].array else {
                return CollectionBatch(sources: sources, coverageGaps: gaps + [.init(reason: .malformedSource)], checkpoints: checkpoints,
                    recoveredReferences: recoveredReferences)
            }
            for call in calls {
                guard let id = call["tool_use_id"].nonemptyString, call.has("tool_response") else {
                    gaps.append(.init(reason: .malformedSource)); continue
                }
                let segments = try textSegments(call["tool_response"], pointer: "/result")
                let matches = sources.filter { $0.record.metadata.identity.itemID == "tool:\(id)" }
                guard let match = matches.first else {
                    // Tool reference-only results do not contain model-visible text to scan.
                    if !segments.isEmpty, !canonicalToolIDs.contains(id), !continuationNeeded {
                        throw ClaudeCollectionError.awaitingTranscript
                    }
                    continue
                }
                if match.record.segments != segments {
                    gaps.append(.init(reason: .unresolvedCorrelation)) // History remains sole authority.
                }
            }
        }
        if event == "UserPromptSubmit", let promptID = hook["prompt_id"].nonemptyString,
           !canonicalPromptIDs.contains(promptID), !continuationNeeded {
            throw ClaudeCollectionError.awaitingTranscript
        }
        if event == "SubagentStop", paths.count == 1 { gaps.append(.init(reason: .sourceUnavailable)) }
        return CollectionBatch(sources: sources, coverageGaps: Array(Set(gaps)), checkpoints: checkpoints,
            continuation: continuationNeeded ? packet : nil, recoveredReferences: recoveredReferences)
    }

    public func importTranscript(
        _ data: Data, documentID: UUID, interface: AgentInterface, observedAt: Date,
        provenance: SourceProvenance = .live, cryptography: BackgroundCryptography,
        expectedSessionID: String? = nil, context: RetainedSourceContext? = nil,
        startingByteOffset: UInt64? = nil
    ) async throws -> CollectionBatch {
        guard CollectionCompatibility.isEligible(provider: .claudeCode, interface: interface, version: agentVersion) else {
            return CollectionBatch(sources: [], coverageGaps: [.init(reason: .unsupportedVersion)])
        }
        var sources: [CollectedSource] = [], gaps: [CoverageGap] = []
        var recoveredReferences: [CoverageRecoveryReference] = []
        let scope = CollectionScope(provider: .claudeCode, profileID: profileID, interface: interface, path: .versionedTranscript)
        var canonicalSession = expectedSessionID
        let bounded = data.prefix(limits.maximumBytes)
        let ambiguousTools = try ambiguousToolResults(bounded)
        var offset = 0, rowIndex: UInt64 = 0
        for line in bounded.split(separator: 10, omittingEmptySubsequences: false) {
            try Task.checkCancellation()
            let locator: SourceLocator = startingByteOffset.map {
                .transcriptByteOffset(documentID: documentID, byteOffset: $0 + UInt64(offset))
            } ?? .transcript(documentID: documentID, recordIndex: rowIndex)
            var rowSession = canonicalSession.flatMap { try? SessionIdentity(provider: .claudeCode, profileID: profileID, sessionID: $0) }
            var rowTime: Date?, rowContentType: ContentType?
            var fullyRecognized = false
            let previousGapCount = gaps.count
            func reference() -> CoverageRecoveryReference {
                .init(session: rowSession, locator: locator, contentTime: rowTime, parserContract: Self.parserContractVersion)
            }
            func addGap(_ reason: CoverageGapReason, contentType: ContentType? = nil, required: Bool = false) {
                gaps.append(.init(reason: reason, capabilityID: documentID, scope: scope,
                    contentType: contentType ?? rowContentType, recovery: reference(), isRequiredFormatFailure: required))
            }
            defer {
                if fullyRecognized, gaps.count == previousGapCount { recoveredReferences.append(reference()) }
            }
            // Do not parse a partial write. A complete JSON value without a newline is not committed framing.
            if offset + line.count >= bounded.count { if !line.isEmpty { addGap(.incompleteMessage) }; break }
            if rowIndex >= limits.maximumRows { addGap(.budgetExhausted); break }
            let next = offset + line.count + 1
            defer { offset = next; rowIndex += 1 }
            guard !line.isEmpty else { continue }
            guard line.count <= limits.maximumRowBytes else { addGap(.budgetExhausted); continue }
            let row: ClaudeJSON
            do { row = try JSONDecoder().decode(ClaudeJSON.self, from: Data(line)) }
            catch { addGap(.malformedSource); continue }
            if let nativeSession = row["sessionId"].nonemptyString {
                rowSession = try? SessionIdentity(provider: .claudeCode, profileID: profileID, sessionID: nativeSession)
            }
            rowTime = row["timestamp"].string.flatMap(Self.timestamp)
            // An unknown format still has useful recovery metadata. A trustworthy timestamp
            // outside this audit must not create a recent omission merely because it was read now.
            if case .historical(let audit) = provenance, let rowTime, !audit.includes(contentTime: rowTime) { continue }
            let producerVersion = row["version"].nonemptyString ?? CollectionCompatibility.unknownProducerVersion
            guard let type = row["type"].string else { addGap(.malformedSource); continue }
            let queuedPrompt = type == "attachment" ? Self.queuedUserPrompt(row["attachment"]) : nil
            // These observed envelopes are session metadata. Anthropic's session reader also
            // excludes non-user/assistant entries from message content. A new content-bearing
            // shape must remain visible as a gap rather than inherit this metadata treatment.
            if queuedPrompt == nil, !row.has("message"), !row.has("content") {
                if type == "attachment" {
                    // Attachment payloads sit under "attachment", so the subtype decides.
                    if Self.contextAttachmentTypes.contains(row["attachment"]["type"].string ?? "") { fullyRecognized = true }
                    else { addGap(.unsupportedContent) }
                    continue
                }
                if ["ai-title", "atis-latch", "cost-state", "last-prompt", "agent-name", "custom-title"].contains(type) {
                    fullyRecognized = true
                    continue
                }
            }
            guard ["user", "assistant"].contains(type) || queuedPrompt != nil else {
                if !["file-history-snapshot", "progress", "system", "queue-operation", "summary"].contains(type) {
                    addGap(.unsupportedContent)
                }
                continue
            }
            let role = queuedPrompt == nil ? type : "user"
            rowContentType = role == "user" ? .userPrompt
                : (row["message"]["stop_reason"].string == "end_turn" ? .finalResponse : .intermediateResponse)
            rowSession = row["sessionId"].nonemptyString.flatMap { try? SessionIdentity(provider: .claudeCode, profileID: profileID, sessionID: $0) }
            guard let sessionID = row["sessionId"].nonemptyString, let uuid = row["uuid"].nonemptyString,
                  canonicalSession == nil || canonicalSession == sessionID else {
                addGap(.unresolvedCorrelation, required: true); continue
            }
            canonicalSession = sessionID
            guard let timestamp = row["timestamp"].string, let date = Self.timestamp(timestamp) else {
                addGap(.missingTimestamp, required: true); continue
            }
            rowTime = date
            if case .historical(let audit) = provenance, !audit.includes(contentTime: date) { continue }
            let message = row["message"]
            let blocks: [ClaudeJSON]
            if let queuedPrompt { blocks = queuedPrompt } else {
                guard message["role"].string == type else { addGap(.malformedSource, required: true); continue }
                if message.has("stop_reason"), !message["stop_reason"].isNull, message["stop_reason"].string == nil {
                    addGap(.malformedSource, required: true); continue
                }
                if let text = message["content"].string { blocks = [.object(["type": .string("text"), "text": .string(text)])] }
                else if let array = message["content"].array { blocks = array }
                else { addGap(.malformedSource, required: true); continue }
            }
            fullyRecognized = true
            for (index, block) in blocks.enumerated() {
                var itemID: String, contentType: ContentType, segments: [SourceSegment]
                var basis: CanonicalizationBasis = .exclusiveAuthority
                switch block["type"].string {
                case "text":
                    guard let text = block["text"].string else { addGap(.malformedSource, required: true); continue }
                    guard !text.isEmpty else { continue }
                    // Native Agent prompts can reuse their parent's promptId. The transcript UUID
                    // identifies the actual appearance; promptId is only a delivery/read hint.
                    itemID = role == "user" ? "prompt:\(uuid):block:\(index)" : "message:\(uuid):block:\(index)"
                    contentType = role == "user" ? .userPrompt
                        : (message["stop_reason"].string == "end_turn" ? .finalResponse : .intermediateResponse)
                    segments = [try SourceSegment(id: "/text", utf8: Data(text.utf8))]
                case "tool_result":
                    guard type == "user", let id = block["tool_use_id"].nonemptyString, block.has("content") else {
                        addGap(.malformedSource, contentType: block["is_error"].bool == true ? .toolError : .toolOutput, required: true); continue
                    }
                    guard !ambiguousTools.contains(sessionID + "\u{0}" + id) else {
                        addGap(.unresolvedCorrelation, contentType: block["is_error"].bool == true ? .toolError : .toolOutput, required: true); continue
                    }
                    itemID = "tool:\(id)"; basis = .sharedUpstreamIdentity
                    guard !block.has("is_error") || block["is_error"].bool != nil else {
                        addGap(.malformedSource, contentType: .toolOutput, required: true); continue
                    }
                    contentType = block["is_error"].bool == true ? .toolError : .toolOutput
                    guard block["content"].isStructuredTextPayload else {
                        addGap(.malformedSource, contentType: contentType, required: true); continue
                    }
                    segments = try textSegments(block["content"], pointer: "/result")
                case "tool_use", "thinking", "redacted_thinking": continue // Inputs/internal reasoning are not output authority.
                case "image", "image_url", "audio": addGap(.unsupportedContent); continue
                default: addGap(.unsupportedContent, required: true); continue
                }
                guard !segments.isEmpty else { continue }
                let identity = try SourceIdentity(session: .init(provider: .claudeCode, profileID: profileID, sessionID: sessionID), itemID: itemID)
                let origin = try SourceOrigin(adapterID: "claude-code", adapterVersion: Self.adapterVersion,
                    agentVersion: producerVersion, interface: interface, provenance: provenance, canonicalization: basis)
                let metadata = try SourceRecordMetadata(identity: identity, contentType: contentType,
                    contentTime: date, observedAt: observedAt, locator: locator, origin: origin)
                let revision = try await cryptography.revision(canonicalBytes: canonicalBytes(segments))
                let record = try SourceRecord(metadata: metadata, revision: revision, segments: segments)
                let sourceContext = RetainedSourceContext(sessionIdentifier: sessionID,
                    title: context?.title, projectPath: context?.projectPath ?? row["cwd"].string,
                    transcriptPath: context?.transcriptPath, openingCapability: context?.openingCapability ?? .unverified)
                sources.append(CollectedSource(record: record, context: sourceContext))
            }
        }
        if data.count > limits.maximumBytes { gaps.append(.init(reason: .budgetExhausted)) }
        let revision = try await cryptography.revision(canonicalBytes: Data(bounded.prefix(offset)))
        let checkpoint = SourceCheckpoint(capabilityID: documentID, sourceDocumentID: documentID,
            revision: revision, byteOffset: UInt64(offset), lastContentTime: sources.map(\.record.metadata.contentTime).max(), gaps: Array(Set(gaps)))
        return CollectionBatch(sources: sources, coverageGaps: Array(Set(gaps)), checkpoint: checkpoint,
            recoveredReferences: recoveredReferences)
    }

    private static func timestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// A prompt submitted while a turn is running is persisted as a queued-command attachment,
    /// not as a user message. Task notifications and meta commands share that envelope.
    private static func queuedUserPrompt(_ attachment: ClaudeJSON) -> [ClaudeJSON]? {
        guard attachment["type"].string == "queued_command", attachment["commandMode"].string == "prompt",
              attachment["isMeta"].bool != true else { return nil }
        if let text = attachment["prompt"].string { return [.object(["type": .string("text"), "text": .string(text)])] }
        return attachment["prompt"].array
    }

    /// One native tool result cannot have competing canonical bytes or success/error semantics
    /// in the same bounded page. Earlier pages need not contain its original tool-use message.
    private func ambiguousToolResults(_ data: Data) throws -> Set<String> {
        var seen: [String: Data] = [:], ambiguous: Set<String> = []
        for line in completeLines(data) {
            try Task.checkCancellation()
            guard line.count <= limits.maximumRowBytes,
                  let row = try? JSONDecoder().decode(ClaudeJSON.self, from: Data(line)),
                  row["type"].string == "user", let session = row["sessionId"].nonemptyString,
                  row["message"]["role"].string == "user" else { continue }
            for block in row["message"]["content"].array ?? [] where block["type"].string == "tool_result" {
                guard let id = block["tool_use_id"].nonemptyString, block.has("content"),
                      !block.has("is_error") || block["is_error"].bool != nil else { continue }
                let key = session + "\u{0}" + id
                let signature = Data([block["is_error"].bool == true ? 1 : 0])
                    + canonicalBytes(try textSegments(block["content"], pointer: "/result"))
                if let previous = seen[key], previous != signature { ambiguous.insert(key) }
                seen[key] = signature
            }
        }
        return ambiguous
    }

    func toolResultIDs(_ data: Data, sessionID: String) -> Set<String> {
        var result = Set<String>()
        for line in completeLines(data) {
            guard line.count <= limits.maximumRowBytes,
                  let row = try? JSONDecoder().decode(ClaudeJSON.self, from: Data(line)),
                  row["type"].string == "user", row["sessionId"].string == sessionID,
                  row["uuid"].nonemptyString != nil, let timestamp = row["timestamp"].string,
                  Self.timestamp(timestamp) != nil else { continue }
            for block in row["message"]["content"].array ?? [] where block["type"].string == "tool_result" {
                if let id = block["tool_use_id"].nonemptyString { result.insert(id) }
            }
        }
        return result
    }

    func promptIDs(_ data: Data, sessionID: String) -> Set<String> {
        var result = Set<String>()
        for line in completeLines(data) {
            guard line.count <= limits.maximumRowBytes,
                  let row = try? JSONDecoder().decode(ClaudeJSON.self, from: Data(line)),
                  row["type"].string == "user", row["sessionId"].string == sessionID,
                  row["isSidechain"].bool != true, row["uuid"].nonemptyString != nil,
                  let timestamp = row["timestamp"].string, Self.timestamp(timestamp) != nil,
                  let id = row["promptId"].nonemptyString else { continue }
            if row["message"]["content"].string != nil || row["message"]["content"].array?.contains(where: { $0["type"].string == "text" }) == true {
                result.insert(id)
            }
        }
        return result
    }

    private func completeLines(_ data: Data) -> [Data.SubSequence] {
        let bounded = data.prefix(limits.maximumBytes)
        guard let newline = bounded.lastIndex(of: 10) else { return [] }
        return Array(bounded[..<newline].split(separator: 10, omittingEmptySubsequences: false).prefix(limits.maximumRows))
    }

    func documentIdentity(_ path: String, cryptography: BackgroundCryptography) async throws -> UUID {
        let bytes = try await cryptography.revision(canonicalBytes: Data("claude-document-v1\u{0}\(profileID)\u{0}\(path)".utf8)).keyedDigest
        let b = Array(bytes.prefix(16))
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }

    func transcriptURL(path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw ClaudeCollectionError.unsafeTranscriptPath }
        let original = URL(fileURLWithPath: path).standardizedFileURL
        var url = original
        for root in rootAliases where original.path.hasPrefix(root.original.path + "/") {
            url = root.resolved.appendingPathComponent(String(original.path.dropFirst(root.original.path.count + 1)))
            break
        }
        guard url.pathExtension == "jsonl", allowedTranscriptRoots.contains(where: { root in
            url.path.hasPrefix(root.path + "/") && root.path != "/"
        }) else { throw ClaudeCollectionError.unsafeTranscriptPath }
        return url
    }

    func openTranscript(path: String) throws -> Int32 {
        let url = try transcriptURL(path: path)
        // Open every component without following symlinks, preventing path replacement/escape races.
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ClaudeCollectionError.unsafeTranscriptPath }
        let parts = url.path.split(separator: "/")
        for (index, part) in parts.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (index < parts.count - 1 ? O_DIRECTORY : 0)
            let next = String(part).withCString { openat(fd, $0, flags) }
            guard next >= 0 else { Darwin.close(fd); throw ClaudeCollectionError.awaitingTranscript }
            Darwin.close(fd); fd = next
        }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_uid == getuid() else {
            Darwin.close(fd)
            throw ClaudeCollectionError.unsafeTranscriptPath
        }
        return fd
    }

    private func readTranscript(path: String) throws -> ClaudeTranscriptRead {
        let fd = try openTranscript(path: path)
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw ClaudeCollectionError.awaitingTranscript }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < limits.maximumBytes {
            let count = min(buffer.count, limits.maximumBytes - data.count)
            let n = Darwin.read(fd, &buffer, count)
            if n == 0 { break }; if n < 0 { if errno == EINTR { continue }; throw ClaudeCollectionError.awaitingTranscript }
            data.append(contentsOf: buffer.prefix(n))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              after.st_size >= before.st_size else { throw ClaudeCollectionError.awaitingTranscript }
        return ClaudeTranscriptRead(data: data, incomplete: !data.isEmpty && data.last != 10,
                                    exhausted: before.st_size > limits.maximumBytes)
    }
}

/// Resolve aliases only for explicitly authorized configuration roots. Untrusted descendants are
/// still opened component-by-component with O_NOFOLLOW. Foundation preserves /var's macOS alias.
func claudeConfiguredURL(_ url: URL) -> URL {
    var parent = url.standardizedFileURL, suffix: [String] = []
    while parent.path != "/" {
        if let resolved = realpath(parent.path, nil) {
            defer { free(resolved) }
            var result = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            for component in suffix.reversed() { result.appendPathComponent(component) }
            return result
        }
        suffix.append(parent.lastPathComponent); parent.deleteLastPathComponent()
    }
    return url.standardizedFileURL
}

private struct ClaudeTranscriptRead { let data: Data; let incomplete: Bool; let exhausted: Bool }

/// Lossless string leaves. Only known binary and tool-reference blocks are excluded;
/// arbitrary structured `data`/`id` strings can contain credentials and must remain scannable.
private func textSegments(_ value: ClaudeJSON, pointer: String) throws -> [SourceSegment] {
    switch value {
    case .string(let text): return text.isEmpty ? [] : [try .init(id: pointer, utf8: Data(text.utf8))]
    case .array(let values): return try values.enumerated().flatMap { try textSegments($0.element, pointer: "\(pointer)/\($0.offset)") }
    case .object(let values):
        if ["image", "image_url", "audio", "tool_reference"].contains(value["type"].string ?? "") { return [] }
        // The type tag is structural. All other string leaves inside an already recognized
        // tool-result payload remain content, including additive fields beside its text.
        return try values.keys.sorted().flatMap { key throws -> [SourceSegment] in
            if key == "type", ["text", "input_text", "output_text"].contains(value["type"].string ?? "") { return [] }
            return try textSegments(values[key]!, pointer: pointer + "/" + key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1"))
        }
    default: return []
    }
}

private func canonicalBytes(_ segments: [SourceSegment]) -> Data {
    var bytes = Data("claude-segments-v1".utf8)
    for segment in segments {
        for value in [Data(segment.id.utf8), segment.utf8] {
            var count = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }; bytes.append(value)
        }
    }
    return bytes
}

private enum ClaudeJSON: Decodable, Sendable {
    case object([String: ClaudeJSON]), array([ClaudeJSON]), string(String), bool(Bool), number(Double), null
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode([String: ClaudeJSON].self) { self = .object(x) }
        else if let x = try? c.decode([ClaudeJSON].self) { self = .array(x) }
        else { self = .number(try c.decode(Double.self)) }
    }
    subscript(_ key: String) -> ClaudeJSON { if case .object(let x) = self { return x[key] ?? .null }; return .null }
    func has(_ key: String) -> Bool { if case .object(let x) = self { return x[key] != nil }; return false }
    var string: String? { if case .string(let x) = self { return x }; return nil }
    var nonemptyString: String? { string.flatMap { $0.isEmpty ? nil : $0 } }
    var bool: Bool? { if case .bool(let x) = self { return x }; return nil }
    var array: [ClaudeJSON]? { if case .array(let x) = self { return x }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }
    var isStructuredTextPayload: Bool {
        switch self {
        case .string, .array, .object: true
        default: false
        }
    }
}
