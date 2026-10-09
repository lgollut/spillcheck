import Darwin
import Foundation

public enum CodexCollectionError: Error, Equatable, Sendable {
    case invalidConfiguration, wrongProfile, malformedCapture, awaitingHistory, unsafeTranscriptPath
    case authorityConflict, missingAuthority, unsupportedVersion
}
public enum CodexCollectionAuthority: String, Codable, Sendable {
    case publicNativeItems = "codex-public-native-v1"
    case t3VersionedTranscript = "codex-t3-transcript-v1"
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
public struct CodexAdapter: CaptureNormalizer, HistoricalCaptureProducer, Sendable {
    public static let validatedAgentVersion = "0.161.0"
    public static let validatedT3Version = "0.0.46-nightly.20261007.2761"
    public static let validatedT3ProducerVersion = "0.160.1"
    public static let adapterVersion = "1"
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
              authority != .t3VersionedTranscript || interface == .t3,
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
            let supported = hasSupportedVersionTuple
            return AdapterCapability(provider: .codex, interface: interface,
                agentVersion: interface == .t3 ? Self.validatedT3ProducerVersion : agentVersion,
                adapterVersion: Self.adapterVersion, contentType: type,
                path: authority == .publicNativeItems ? .publicHistory : .versionedTranscript,
                validation: supported ? (authority == .publicNativeItems ? .validated : .unverified) : .unsupported,
                canObserveActiveSession: supported && authority == .publicNativeItems,
                canReadHistoricalContent: supported && authority == .publicNativeItems, canonicalization: .exclusiveAuthority)
        }
    }

    public func normalize(_ packet: CapturePacket, capturedAt: Date,
                          cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        guard packet.metadata.agent == .codex, packet.metadata.profileID == profileID,
              packet.metadata.interface == interface else { throw CodexCollectionError.wrongProfile }
        guard hasSupportedVersionTuple else {
            return CollectionBatch(sources: [], coverageGaps: [.init(reason: .unsupportedVersion)])
        }
        if let request = try? JSONDecoder().decode(CodexHistoryRequest.self, from: packet.eventJSON),
           request.kind == CodexHistoryRequest.kind {
            return try await normalizeHistory(request, observedAt: capturedAt, cryptography: cryptography)
        }
        guard let hook = try? JSONDecoder().decode(CodexJSON.self, from: packet.eventJSON),
              let event = hook["hook_event_name"].string, let threadID = hook["session_id"].nonemptyString else {
            return CollectionBatch(sources: [], coverageGaps: [.init(reason: .malformedSource)])
        }
        guard Set(CodexHookConfiguration.events + ["SpillcheckHistoryPoll", "LeakretHistoryPoll"]).contains(event) else {
            return CollectionBatch(sources: [], coverageGaps: [.init(reason: .unsupportedContent)])
        }
        if authority == .t3VersionedTranscript {
            guard let path = hook["transcript_path"].nonemptyString else {
                return CollectionBatch(sources: [], coverageGaps: [.init(reason: .sourceUnavailable)])
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
        guard authority == .publicNativeItems, let threadID = thread["id"].nonemptyString else { throw CodexCollectionError.authorityConflict }
        guard let producerVersion = thread["cliVersion"].string, supportsProducer(producerVersion) else {
            return .init(sources: [], coverageGaps: [.init(reason: .unsupportedVersion)])
        }
        try await selectAuthority(sessionID: threadID)
        let context = RetainedSourceContext(sessionIdentifier: threadID, title: thread["name"].string,
            projectPath: thread["cwd"].string, transcriptPath: thread["path"].string)
        var sources: [CollectedSource] = [], gaps: [CoverageGap] = []
        for entry in page.data {
            try Task.checkCancellation()
            guard let turnID = entry["turnId"].nonemptyString else { gaps.append(.init(reason: .malformedSource)); continue }
            let item = entry["item"]
            let date: Date
            if let milliseconds = entry["completedAtMs"].number ?? entry["startedAtMs"].number,
               milliseconds.isFinite, abs(milliseconds) < 1e15 { date = Date(timeIntervalSince1970: milliseconds / 1000) }
            else if let interval = turnTimes[turnID] {
                if case .historical(let audit) = provenance,
                   (interval.start < audit.start && interval.end >= audit.start || interval.start <= audit.end && interval.end > audit.end) {
                    gaps.append(.init(reason: .missingTimestamp)); continue
                }
                date = item["type"].string == "userMessage" ? interval.start : interval.end
            } else { gaps.append(.init(reason: .missingTimestamp)); continue }
            if case .historical(let audit) = provenance, !audit.includes(contentTime: date) { continue }
            guard let id = item["id"].nonemptyString, let type = item["type"].string else {
                gaps.append(.init(reason: .malformedSource)); continue
            }
            var kind: ContentType, segments: [SourceSegment]
            switch type {
            case "userMessage":
                kind = .userPrompt; segments = try codexTextSegments(item["content"], pointer: "/content")
            case "agentMessage":
                guard let phase = item["phase"].string, ["commentary", "final_answer"].contains(phase) else {
                    gaps.append(.init(reason: .unsupportedContent)); continue
                }
                kind = phase == "final_answer" ? .finalResponse : .intermediateResponse
                segments = try codexTextSegments(item["text"], pointer: "/text")
            case "commandExecution":
                guard ["completed", "failed", "declined"].contains(item["status"].string ?? "") else {
                    gaps.append(.init(reason: .incompleteMessage)); continue
                }
                kind = item["status"].string == "completed" && (item["exitCode"].number ?? 0) == 0 ? .toolOutput : .toolError
                segments = try codexTextSegments(item["aggregatedOutput"], pointer: "/aggregatedOutput")
            case "mcpToolCall":
                guard ["completed", "failed"].contains(item["status"].string ?? "") else {
                    gaps.append(.init(reason: .incompleteMessage)); continue
                }
                kind = item["status"].string == "failed" || item["error"] != .null ? .toolError : .toolOutput
                segments = try codexTextSegments(item["result"], pointer: "/result")
                segments += try codexTextSegments(item["error"], pointer: "/error")
            case "dynamicToolCall":
                guard ["completed", "failed"].contains(item["status"].string ?? "") else {
                    gaps.append(.init(reason: .incompleteMessage)); continue
                }
                kind = item["status"].string == "failed" ? .toolError : .toolOutput
                segments = try codexTextSegments(item["content"], pointer: "/content")
            case "subAgentActivity", "collabAgentToolCall", "reasoning", "plan", "contextCompaction": continue
            default: gaps.append(.init(reason: .unsupportedContent)); continue
            }
            guard !segments.isEmpty else { continue }
            sources.append(try await source(sessionID: threadID, itemID: id, kind: kind, segments: segments,
                date: date, observedAt: observedAt, provenance: provenance, locator: .upstreamItem,
                context: context, producerVersion: producerVersion, cryptography: cryptography))
        }
        return .init(sources: sources, coverageGaps: Array(Set(gaps)))
    }

    public func importTranscript(_ data: Data, documentID: UUID, observedAt: Date,
                                 provenance: SourceProvenance = .live, expectedSessionID: String,
                                 context: RetainedSourceContext? = nil,
                                 cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        guard authority == .t3VersionedTranscript, interface == .t3 else { throw CodexCollectionError.authorityConflict }
        guard hasSupportedVersionTuple else { return .init(sources: [], coverageGaps: [.init(reason: .unsupportedVersion)]) }
        // A physical transcript is a distinct authority. Its creator version must be checked
        // before any response row can be emitted, including when it appears late in a file.
        let completeRows = data.prefix(limits.maximumBytes).split(separator: 10, omittingEmptySubsequences: false).dropLast()
        guard let session = completeRows.lazy.compactMap({ try? JSONDecoder().decode(CodexJSON.self, from: Data($0)) })
            .first(where: { $0["type"].string == "session_meta" }),
            session["payload"]["id"].string == expectedSessionID else { throw CodexCollectionError.malformedCapture }
        guard let producerVersion = session["payload"]["cli_version"].string, supportsProducer(producerVersion) else {
            return .init(sources: [], coverageGaps: [.init(reason: .unsupportedVersion)])
        }
        try await selectAuthority(sessionID: expectedSessionID)
        var sources: [CollectedSource] = [], gaps: [CoverageGap] = [], offset = 0, index: UInt64 = 0
        let bounded = data.prefix(limits.maximumBytes)
        for line in bounded.split(separator: 10, omittingEmptySubsequences: false) {
            try Task.checkCancellation()
            if offset + line.count >= bounded.count { if !line.isEmpty { gaps.append(.init(reason: .incompleteMessage)) }; break }
            if index >= limits.maximumRows { gaps.append(.init(reason: .budgetExhausted)); break }
            defer { offset += line.count + 1; index += 1 }
            guard !line.isEmpty else { continue }
            guard line.count <= limits.maximumRowBytes else { gaps.append(.init(reason: .budgetExhausted)); continue }
            guard let row = try? JSONDecoder().decode(CodexJSON.self, from: Data(line)) else { gaps.append(.init(reason: .malformedSource)); continue }
            let body = row["payload"]
            if row["type"].string == "session_meta" {
                guard body["id"].string == expectedSessionID else { throw CodexCollectionError.authorityConflict }
                guard body["cli_version"].string == producerVersion else { throw CodexCollectionError.malformedCapture }
                continue
            }
            guard row["type"].string == "response_item" else { continue }
            guard let timestamp = row["timestamp"].string, let date = codexTimestamp(timestamp) else {
                gaps.append(.init(reason: .missingTimestamp)); continue
            }
            if case .historical(let audit) = provenance, !audit.includes(contentTime: date) { continue }
            var id: String, kind: ContentType, segments: [SourceSegment]
            switch body["type"].string {
            case "message":
                guard let nativeID = body["id"].nonemptyString else { gaps.append(.init(reason: .malformedSource)); continue }
                id = nativeID
                if body["role"].string == "user" { kind = .userPrompt }
                else if body["role"].string == "assistant", let phase = body["phase"].string,
                        ["commentary", "final_answer"].contains(phase) {
                    kind = phase == "final_answer" ? .finalResponse : .intermediateResponse
                } else if body["role"].string == "system" || body["role"].string == "developer" { continue }
                else { gaps.append(.init(reason: .unsupportedContent)); continue }
                segments = try codexTextSegments(body["content"], pointer: "/content")
            case "function_call_output", "custom_tool_call_output":
                guard let call = body["call_id"].nonemptyString else { gaps.append(.init(reason: .malformedSource)); continue }
                id = "tool:\(call)"
                let decoded = try codexT3Output(body["output"], pointer: "/output")
                kind = decoded.failed ? .toolError : .toolOutput; segments = decoded.segments
            case "function_call", "custom_tool_call", "reasoning": continue
            default: gaps.append(.init(reason: .unsupportedContent)); continue
            }
            guard !segments.isEmpty else { continue }
            sources.append(try await source(sessionID: expectedSessionID, itemID: id, kind: kind,
                segments: segments, date: date, observedAt: observedAt, provenance: provenance,
                locator: .transcript(documentID: documentID, recordIndex: index), context: context,
                producerVersion: producerVersion, cryptography: cryptography))
        }
        if data.count > limits.maximumBytes { gaps.append(.init(reason: .budgetExhausted)) }
        return .init(sources: sources, coverageGaps: Array(Set(gaps)))
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
    var hasSupportedVersionTuple: Bool {
        agentVersion == Self.validatedAgentVersion &&
        (interface == .standaloneCLI || interface == .t3 && t3Version == Self.validatedT3Version)
    }
    func supportsProducer(_ version: String) -> Bool {
        hasSupportedVersionTuple && version == (interface == .t3 ? Self.validatedT3ProducerVersion : Self.validatedAgentVersion)
    }
    func packet(_ request: CodexHistoryRequest) throws -> CapturePacket {
        try .init(metadata: .init(agent: .codex, interface: interface, profileID: profileID), eventJSON: JSONEncoder().encode(request))
    }
    func documentIdentity(_ path: String, cryptography: BackgroundCryptography) async throws -> UUID {
        let bytes = Array(try await cryptography.revision(canonicalBytes: Data("codex-document-v1\u{0}\(profileID)\u{0}\(path)".utf8)).keyedDigest.prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    private func readTranscript(path: String) throws -> Data {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw CodexCollectionError.unsafeTranscriptPath }
        let original = URL(fileURLWithPath: path).standardizedFileURL
        var url = original
        for root in rootAliases where original.path.hasPrefix(root.original.path + "/") {
            url = root.resolved.appendingPathComponent(String(original.path.dropFirst(root.original.path.count + 1))); break
        }
        guard url.pathExtension == "jsonl", allowedTranscriptRoots.contains(where: { url.path.hasPrefix($0.path + "/") }) else {
            throw CodexCollectionError.unsafeTranscriptPath
        }
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
func codexTextSegments(_ value: CodexJSON, pointer: String) throws -> [SourceSegment] {
    switch value {
    case .string(let text): return text.isEmpty ? [] : [try .init(id: pointer, utf8: Data(text.utf8))]
    case .array(let values): return try values.enumerated().flatMap { try codexTextSegments($0.element, pointer: "\(pointer)/\($0.offset)") }
    case .object(let values):
        if ["image", "image_url", "input_image", "inputImage", "audio", "input_audio", "inputAudio", "tool_reference"].contains(value["type"].string ?? "") { return [] }
        if ["text", "input_text", "output_text", "inputText"].contains(value["type"].string ?? "") { return try codexTextSegments(value["text"], pointer: pointer + "/text") }
        return try values.keys.sorted().flatMap { key in try codexTextSegments(values[key]!, pointer: pointer + "/" + key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")) }
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
private func codexT3Output(_ value: CodexJSON, pointer: String) throws -> (segments: [SourceSegment], failed: Bool) {
    if let values = value.array {
        var segments: [SourceSegment] = [], failed = false
        for (index, block) in values.enumerated() {
            let result = try codexT3Output(block, pointer: "\(pointer)/\(index)")
            segments += result.segments; failed = failed || result.failed
        }
        return (segments, failed)
    }
    if let text = value.string ?? value["text"].string,
       let encoded = text.data(using: .utf8), let object = try? JSONDecoder().decode(CodexJSON.self, from: encoded), object.object != nil {
        if let output = object["output"].string, let status = object["exit_code"].number {
            return (try codexTextSegments(.string(output), pointer: pointer + "/decoded/output"), status != 0)
        }
        let segments = try codexTextSegments(object, pointer: pointer + "/decoded")
        return (segments, object["isError"].bool == true)
    }
    return (try codexTextSegments(value, pointer: pointer), value["isError"].bool == true)
}
