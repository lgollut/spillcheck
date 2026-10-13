#if DEBUG
import CryptoKit
import Darwin
import Foundation
@_spi(Testing) import SpillcheckCore

/// Observes the same native responses and normalized batches used by production.
/// Expected identities/bytes select the fake fixture; they never supply a receipt.
@MainActor
final class NativeContentAcceptance {
    static let maximumSources = 128
    enum Failure: String, Error { case unsafeConfiguration, unsafeState, foreignSource,
        invalidNativeContent, changedSource, incompleteRead, receiptMismatch, reportUnavailable }
    enum FixtureKind: String, Codable, Sendable { case mcp, hookPrompt = "hook-prompt", plan, localImage = "local-image" }
    struct Segment: Codable, Equatable, Sendable {
        let pointer: String
        let textSHA256: String
        let textBytes: Int
    }
    struct Descriptor: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let fixtureKind: FixtureKind
        let threadID: String
        let turnID: String
        let itemID: String
        let producerVersion: String
        let hookRunID: String
        let segments: [Segment]
        let imageSHA256: String?
        var contentType: ContentType {
            switch fixtureKind {
            case .mcp: .toolOutput
            case .hookPrompt, .localImage: .userPrompt
            case .plan: .intermediateResponse
            }
        }
        var textBytes: Int { segments.reduce(0) { $0 + $1.textBytes } }
        var profileID: String { "owned-signed-codex-" + (fixtureKind == .localImage ? "local-media" : fixtureKind.rawValue) }

        @MainActor static func decode(_ data: Data) throws -> Self {
            guard data.count <= 8192 else { throw Failure.unsafeConfiguration }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard try encoder.encode(value) == data, value.schemaVersion == 1,
                  UUID(uuidString: value.threadID)?.uuidString.lowercased() == value.threadID,
                  NativeContentAcceptance.opaque(value.turnID), NativeContentAcceptance.opaque(value.itemID),
                  value.producerVersion == "0.162.1",
                  (value.fixtureKind == .hookPrompt ? NativeContentAcceptance.opaque(value.hookRunID) : value.hookRunID.isEmpty) else {
                throw Failure.unsafeConfiguration
            }
            guard value.fixtureKind == .localImage ? value.imageSHA256 == NativeContentAcceptance.imageSHA256 : value.imageSHA256 == nil else {
                throw Failure.unsafeConfiguration
            }
            if value.fixtureKind == .localImage {
                guard !value.turnID.utf8.contains(127), !value.itemID.utf8.contains(127) else { throw Failure.unsafeConfiguration }
            }
            if value.fixtureKind == .plan {
                guard UUID(uuidString: value.turnID)?.uuidString.lowercased() == value.turnID,
                      value.itemID.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
                      value.segments.count == 1, let segment = value.segments.first,
                      segment.pointer == "/text", (1...16_384).contains(segment.textBytes),
                      segment.textSHA256.utf8.count == 64,
                      segment.textSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw Failure.unsafeConfiguration
                }
            } else if value.segments != NativeContentAcceptance.expectedSegments(value.fixtureKind) {
                throw Failure.unsafeConfiguration
            }
            return value
        }
    }
    static func opaque(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains { $0.value < 32 }
    }
    static let mediaText = "This is a fake-only local attachment test.\r\nSPILLCHECK_FAKE_LOCAL_IMAGE_42 café\nDo not use tools, commands, agents, files or external services. Ignore the image content and reply with only this line:\nSPILLCHECK_LOCAL_IMAGE_DONE_42"
    static let imageSHA256 = "7893f9dd97b6ddcfb0e31cb46ca92ebec7f50c1dec1f145212cd423e3562f6aa"
    static let hookText = "SPILLCHECK_INJECTED_HOOK_ONLY_97 é🙂\nThis is harmless hook-provided input. Do not use tools. Reply with only the following line, without punctuation or formatting:\nSPILLCHECK_HOOK_AFTER_42"
    static func expectedText(_ kind: FixtureKind) -> [String: String] {
        // Plan text is emitted by the real producer and bound by its descriptor.
        if kind == .plan { return [:] }
        if kind == .localImage { return ["/content/0/text": mediaText] }
        if kind == .hookPrompt { return ["/fragments/0/text": hookText] }
        return [
            "/result/content/0/text": "SPILLCHECK_MCP_PROTOCOL_TEXT_42",
            "/result/structuredContent/type": "image",
            "/result/structuredContent/caption": "SPILLCHECK_MCP_BUSINESS_IMAGE_42 é🙂\r\n",
            "/result/structuredContent/content/0/type": "encrypted_content",
            "/result/structuredContent/content/0/caption": "ordinary business encrypted label",
            "/result/structuredContent/content/0/encrypted_content": "ordinary business field",
            "/result/structuredContent/content/0/a~1b~0": "escaped pointer text",
            "/result/structuredContent/resource/blob": "ordinary business blob",
            "/result/structuredContent/printed": #"{"type":"image","caption":"literal\nbytes"}"#,
            "/result/structuredContent/error": "business error",
            "/result/structuredContent/status": "failed"
        ]
    }
    static func expectedSegments(_ kind: FixtureKind) -> [Segment] {
        expectedText(kind).map { pointer, text in
            .init(pointer: pointer, textSHA256: sha(Data(text.utf8)), textBytes: text.utf8.count)
        }.sorted { $0.pointer < $1.pointer }
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func expectedMCPResult() throws -> CodexJSON {
        let value: [String: Any] = [
            "content": [["type": "text", "text": "SPILLCHECK_MCP_PROTOCOL_TEXT_42"]],
            "structuredContent": ["type": "image", "caption": "SPILLCHECK_MCP_BUSINESS_IMAGE_42 é🙂\r\n",
                "content": [["type": "encrypted_content", "caption": "ordinary business encrypted label",
                    "encrypted_content": "ordinary business field", "a/b~": "escaped pointer text"]],
                "resource": ["blob": "ordinary business blob"],
                "printed": #"{"type":"image","caption":"literal\nbytes"}"#,
                "error": "business error", "status": "failed", "exit_code": 7, "isError": true],
            "_meta": NSNull()
        ]
        return try JSONDecoder().decode(CodexJSON.self, from: JSONSerialization.data(withJSONObject: value))
    }
    struct Report: Encodable {
        let fixtureKind: FixtureKind
        let measured = true
        let truncated = false
        let nativeKindEvidence = "same-response-native-content-descriptor"
        let expectedExcludedGapCount: Int?
        let excludedGapEventCount: Int?
        let expectedExcludedGapDigests: [String]?
        let onlyExpectedExcludedMedia: Bool?
        let parserContract = CodexAdapter.parserContract
        let detectorVersion = BetterleaksSecretDetector.version
        let initialStoreEmpty: Bool
        let initialReceiptDigests: [String]
        let initialSourceKindDigests: [String]
        let initialSourceTimeDigests: [String]
        let initialConversationLabelDigests: [String]
        let receiptDigests: [String]
        let sourceKindDigests: [String]
        let sourceTimeDigests: [String]
        let conversationLabelDigests: [String]
        let receiptCount: Int
        let sourceCount: Int
        let sessionCount: Int
        let conversationLabelCount: Int
        let observedTargetSourceCount: Int
        let committedTargetSourceCount: Int
        let targetSourceDigests: [String]
        let targetResultDigests: [String]
        let targetReceiptDigests: [String]
        let targetSegmentCount: Int
        let targetTextBytes: Int
        let nativeReadCount: Int
        let nativeTargetVerified: Bool
        let allObservedTargetSourcesCommitted: Bool
        let cleanInventory: Bool
        let payloadRowCount: Int
        let batchCount: Int
        let readerVersions: [String]
        let producerVersions: [String]
    }
    private struct Pair<K: Encodable, V: Encodable>: Encodable { let key: K; let value: V }
    let session: SessionIdentity
    let descriptor: Descriptor
    let producerWorkPath: String
    private(set) var failure: Failure?
    private(set) var nativeReadCount = 0
    private var nativeTime: Date?
    private var initialized = false
    private var initialStoreEmpty = false
    private var initialReceipts: [String] = [], initialKinds: [String] = [], initialTimes: [String] = [], initialLabels: [String] = []
    private var receipt: AnalysisReceipt?
    private var sourceDigest: String?, resultDigest: String?
    private var observedTime: Date?
    private var batchCount = 0
    private var readerVersions: Set<String> = []

    init(session: SessionIdentity, descriptor: Descriptor, producerWorkPath: String) {
        self.session = session; self.descriptor = descriptor; self.producerWorkPath = producerWorkPath
    }

    static func selected(configuration: CodexCollectionConfiguration,
                         recovery: DisposableRecoveryConfiguration) throws -> NativeContentAcceptance {
        guard recovery.nativeContentEnabled, let bytes = recovery.nativeContentDescriptorData,
              configuration.interface == .standaloneCLI, configuration.authority == .publicNativeItems,
              configuration.authorizedHosts == [.standaloneCLI], configuration.activeSources.isEmpty,
              configuration.readerVersion == "0.162.1",
              configuration.home.deletingLastPathComponent().path == recovery.root.path,
              let canonical = realpath(configuration.home.path, nil) else { throw Failure.unsafeConfiguration }
        defer { free(canonical) }
        var info = stat()
        guard String(cString: canonical) == configuration.home.path,
              lstat(configuration.home.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Failure.unsafeConfiguration }
        let descriptor = try Descriptor.decode(bytes)
        guard configuration.profileID == descriptor.profileID else { throw Failure.unsafeConfiguration }
        return try .init(session: SessionIdentity(provider: .codex, profileID: configuration.profileID,
            sessionID: descriptor.threadID), descriptor: descriptor,
            producerWorkPath: recovery.root.appendingPathComponent("work").path)
    }

    func reject(_ reason: Failure) { if failure == nil { failure = reason } }
    static func hasNoFindings(_ snapshot: InventorySnapshot) -> Bool { WebResultAcceptance.hasNoFindings(snapshot) }
    func checkSelection(_ id: String, turn: String? = nil) throws {
        try checkFilesAbsent()
        guard failure == nil, id == descriptor.threadID,
              turn == nil || turn == descriptor.turnID else { reject(.foreignSource); throw Failure.foreignSource }
    }
    func verifyThread(_ result: CodexThreadRead) throws {
        guard result.readerVersion == descriptor.producerVersion,
              result.thread["id"].string == descriptor.threadID,
              result.thread["cliVersion"].string == descriptor.producerVersion,
              result.thread["cwd"].string == producerWorkPath,
              result.thread["ephemeral"].bool == false,
              result.thread["parentThreadId"] == .null, result.thread["forkedFromId"] == .null else {
            reject(.foreignSource); throw Failure.foreignSource
        }
    }
    private func checkFilesAbsent() throws {
        guard descriptor.fixtureKind == .localImage else { return }
        func absent(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == -1 && errno == ENOENT
        }
        let root = URL(fileURLWithPath: producerWorkPath).deletingLastPathComponent()
        guard absent(root.appendingPathComponent("home/auth.json").path), absent(producerWorkPath + "/fixture.png") else {
            reject(.unsafeState); throw Failure.unsafeState
        }
    }
    func acceptsGap(_ gap: CoverageGap) -> Bool {
        guard descriptor.fixtureKind == .localImage, let reference = gap.recovery, let time = reference.contentTime else { return false }
        if let scope = gap.scope {
            guard scope.provider == .codex, scope.profileID == session.profileID,
                  scope.interface == .standaloneCLI, scope.path == .publicHistory else { return false }
        }
        guard gap.operation == nil || gap.operation == .historicalRead else { return false }
        return gap.reason == .unsupportedContent && gap.diagnosticCode == .excludedBinaryContent
            && gap.excludedContent == true && gap.isRequiredFormatFailure == false && !gap.requiresAnalysis
            && gap.sourceKind == .codexUserMessage && gap.contentType == .userPrompt
            && reference.session == session && reference.itemID == descriptor.itemID && reference.locator == .upstreamItem
            && reference.parserContract == CodexAdapter.parserContract && reference.constraint == .recognizedLocalMedia
            && reference.sourceDocumentID == nil && reference.sourceURL == nil
            && (nativeTime == nil || nativeTime == time)
    }
    func acceptsCoverage(_ batch: CollectionBatch) -> Bool {
        if descriptor.fixtureKind == .localImage { return batch.coverageGaps.allSatisfy(acceptsGap) }
        return !batch.coverageGaps.contains { $0.requiresAnalysis && ($0.reason != .budgetExhausted || batch.continuation == nil) }
    }
    func verifyItems(_ page: CodexHistoryPage) throws {
        try checkFilesAbsent()
        guard page.readerVersion == descriptor.producerVersion, page.data.count <= 256,
              descriptor.fixtureKind == .plan || page.nextCursor == nil else { reject(.incompleteRead); throw Failure.incompleteRead }
        var matched = false
        let kind: String
        let allowed: [String]
        switch descriptor.fixtureKind {
        case .mcp:
            kind = "mcpToolCall"; allowed = ["userMessage", "agentMessage", "reasoning", kind]
        case .hookPrompt:
            kind = "hookPrompt"; allowed = ["userMessage", "agentMessage", "reasoning", "commandExecution", kind]
        case .plan:
            kind = "plan"; allowed = ["userMessage", "agentMessage", "reasoning", kind]
        case .localImage:
            kind = "userMessage"; allowed = [kind, "agentMessage", "reasoning"]
        }
        for entry in page.data {
            let item = entry["item"]
            guard let turn = entry["turnId"].string, Self.opaque(turn),
                  allowed.contains(item["type"].string ?? ""),
                  descriptor.fixtureKind != .localImage || (Self.opaque(item["id"].string ?? "") && !(item["id"].string ?? "").utf8.contains(127)),
                  descriptor.fixtureKind == .hookPrompt || turn == descriptor.turnID else {
                reject(.foreignSource); throw Failure.foreignSource
            }
            guard item["type"].string == kind || item["id"].string == descriptor.itemID else { continue }
            guard !matched, turn == descriptor.turnID, item["type"].string == kind,
                  item["id"].string == descriptor.itemID else { reject(.invalidNativeContent); throw Failure.invalidNativeContent }
            if descriptor.fixtureKind == .mcp {
                guard item["server"].string == "spillcheck_opaque_fixture", item["tool"].string == "opaque_business_result",
                      item["arguments"] == .object([:]), item["status"].string == "completed", item["error"] == .null,
                      item["result"] == (try Self.expectedMCPResult()) else {
                    reject(.invalidNativeContent); throw Failure.invalidNativeContent
                }
            } else if descriptor.fixtureKind == .hookPrompt {
                guard let fragments = item["fragments"].array, fragments.count == 1,
                      fragments[0]["text"].string == Self.hookText,
                      fragments[0]["hookRunId"].string == descriptor.hookRunID else {
                    reject(.invalidNativeContent); throw Failure.invalidNativeContent
                }
            } else if descriptor.fixtureKind == .localImage {
                guard let content = item["content"].array, content.count == 2,
                      case .object(let textFields) = content[0], Set(textFields.keys) == ["type", "text", "text_elements"],
                      content[0]["type"].string == "text", content[0]["text"].string == Self.mediaText,
                      content[0]["text_elements"].array == [],
                      case .object(let mediaFields) = content[1], Set(mediaFields.keys).isSubset(of: ["type", "path", "detail"]),
                      content[1]["type"].string == "localImage", content[1]["path"].string == producerWorkPath + "/fixture.png",
                      mediaFields["detail"] == nil || mediaFields["detail"] == CodexJSON.null else {
                    reject(.invalidNativeContent); throw Failure.invalidNativeContent
                }
            } else {
                guard let text = item["text"].string,
                      matchesSegment(pointer: "/text", bytes: Data(text.utf8)) else {
                    reject(.invalidNativeContent); throw Failure.invalidNativeContent
                }
            }
            matched = true
            if let ms = entry["completedAtMs"].number ?? entry["startedAtMs"].number {
                guard ms.isFinite, abs(ms) < 1e15 else { reject(.invalidNativeContent); throw Failure.invalidNativeContent }
                let time = Date(timeIntervalSince1970: ms / 1000)
                guard nativeTime == nil || nativeTime == time else { reject(.changedSource); throw Failure.changedSource }
                nativeTime = time
            }
        }
        guard matched || descriptor.fixtureKind == .plan else { reject(.incompleteRead); throw Failure.incompleteRead }
        if matched {
            guard nativeReadCount < Self.maximumSources else { reject(.incompleteRead); throw Failure.incompleteRead }
            nativeReadCount += 1
        }
    }
    func verifyTurns(_ page: CodexHistoryPage) throws {
        try checkFilesAbsent()
        if descriptor.fixtureKind == .localImage {
            guard page.readerVersion == descriptor.producerVersion, page.nextCursor == nil, page.data.count == 1,
                  let turn = page.data.first, turn["id"].string == descriptor.turnID,
                  turn["status"].string == "completed", turn["error"] == .null,
                  let start = turn["startedAt"].number, let end = turn["completedAt"].number,
                  start.isFinite, end.isFinite, abs(start) < 1e12, abs(end) < 1e12, end >= start else {
                reject(.foreignSource); throw Failure.foreignSource
            }
            if let nativeTime {
                guard nativeTime >= Date(timeIntervalSince1970: start), nativeTime < Date(timeIntervalSince1970: end + 1) else {
                    reject(.changedSource); throw Failure.changedSource
                }
            } else { nativeTime = Date(timeIntervalSince1970: start) }
            return
        }
        guard page.readerVersion == descriptor.producerVersion, page.data.count <= 256,
              descriptor.fixtureKind == .plan || page.nextCursor == nil,
              page.data.allSatisfy({ Self.opaque($0["id"].string ?? "")
                && (descriptor.fixtureKind == .hookPrompt || $0["id"].string == descriptor.turnID) }) else {
            reject(.foreignSource); throw Failure.foreignSource
        }
        // Unrelated CLI turns may have no interval. Only the exact target's original
        // interval can supply the production fallback when its native item has no time.
        if nativeTime == nil, let turn = page.data.first(where: { $0["id"].string == descriptor.turnID }),
           let start = turn["startedAt"].number, let end = turn["completedAt"].number ?? turn["startedAt"].number,
           start.isFinite, end.isFinite, end >= start { nativeTime = Date(timeIntervalSince1970: end) }
    }
    private func matchesSegments(_ segments: [SourceSegment]) -> Bool {
        segments.count == descriptor.segments.count && Set(segments.map(\.id)).count == descriptor.segments.count
            && segments.allSatisfy { matchesSegment(pointer: $0.id, bytes: $0.utf8) }
    }
    private func matchesSegment(pointer: String, bytes: Data) -> Bool {
        descriptor.segments.contains { $0.pointer == pointer && $0.textBytes == bytes.count && $0.textSHA256 == Self.sha(bytes) }
    }

    func captureInitial(_ snapshot: InventorySnapshot, cryptography: BackgroundCryptography) async throws {
        guard !initialized else { throw Failure.unsafeState }
        try validate(snapshot)
        initialStoreEmpty = snapshot.analysisReceipts.isEmpty && snapshot.sourceKinds.isEmpty
            && snapshot.sourceTimes.isEmpty && snapshot.conversationLabels.isEmpty && snapshot.nextValueLabel == 1
            && WebResultAcceptance.hasNoFindings(snapshot)
        initialReceipts = try await digests("receipt", Array(snapshot.analysisReceipts), cryptography)
        initialKinds = try await digests("kind", snapshot.sourceKinds.map { Pair(key: $0.key, value: $0.value) }, cryptography)
        initialTimes = try await digests("time", snapshot.sourceTimes.map { Pair(key: $0.key, value: $0.value) }, cryptography)
        initialLabels = try await digests("label", snapshot.conversationLabels.map { Pair(key: $0.key, value: $0.value) }, cryptography)
        initialized = true
    }

    func observe(_ batch: CollectionBatch, metadata: CaptureMetadata, path: CollectionPath,
                 cryptography: BackgroundCryptography) async {
        guard failure == nil else { return }
        do {
            guard initialized, metadata.agent == .codex, metadata.profileID == session.profileID,
                  metadata.interface == .standaloneCLI, path == .publicHistory else { throw Failure.foreignSource }
            guard batchCount < Self.maximumSources, batch.sources.count <= Self.maximumSources,
                  InventoryStateAcceptance.hasReadEvidence(batch), batch.observedReaderVersion == descriptor.producerVersion,
                  acceptsCoverage(batch) else {
                throw Failure.incompleteRead
            }
            batchCount += 1; readerVersions.insert(descriptor.producerVersion)
            for collected in batch.sources {
                let source = collected.record, metadata = source.metadata
                guard metadata.identity.session == session else { throw Failure.foreignSource }
                guard metadata.identity.itemID == descriptor.itemID else { continue }
                guard nativeReadCount > 0, metadata.contentTime == nativeTime,
                      metadata.contentType == descriptor.contentType, metadata.locator == .upstreamItem,
                      metadata.origin.adapterID == "codex", metadata.origin.adapterVersion == CodexAdapter.adapterVersion,
                      metadata.origin.agentVersion == descriptor.producerVersion, metadata.origin.interface == .standaloneCLI,
                      metadata.origin.canonicalization == .exclusiveAuthority,
                      matchesSegments(source.segments),
                      descriptor.fixtureKind != .localImage || batch.coverageGaps.count == 1 else { throw Failure.invalidNativeContent }
                guard case .historical = metadata.origin.provenance else { throw Failure.invalidNativeContent }
                let canonical = WebResultAcceptance.canonicalSegments(source.segments)
                guard try await cryptography.revision(canonicalBytes: canonical) == source.revision else { throw Failure.invalidNativeContent }
                let candidate = AnalysisReceipt(source: metadata.identity, revision: source.revision,
                    detectorVersion: BetterleaksSecretDetector.version)
                guard receipt == nil || receipt == candidate, observedTime == nil || observedTime == metadata.contentTime else {
                    throw Failure.changedSource
                }
                receipt = candidate; observedTime = metadata.contentTime
                sourceDigest = try await digest("source", metadata.identity, cryptography)
                var bound = Data("native-content-acceptance-v1/result\n".utf8)
                bound.append(Data(sourceDigest!.utf8)); bound.append(0); bound.append(source.revision.keyedDigest); bound.append(canonical)
                resultDigest = try await cryptography.revision(canonicalBytes: bound).keyedDigest.base64EncodedString()
            }
        } catch { reject((error as? Failure) ?? .reportUnavailable) }
    }
    private func validate(_ snapshot: InventorySnapshot) throws {
        guard snapshot.analysisReceipts.count <= Self.maximumSources, snapshot.sourceKinds.count <= Self.maximumSources,
              snapshot.sourceTimes.count <= Self.maximumSources, snapshot.conversationLabels.count <= 1 else { throw Failure.reportUnavailable }
        guard snapshot.analysisReceipts.allSatisfy({ $0.source.session == session }),
              snapshot.sourceKinds.keys.allSatisfy({ $0.session == session }),
              snapshot.sourceTimes.keys.allSatisfy({ $0.session == session }),
              snapshot.conversationLabels.keys.allSatisfy({ $0 == session }) else { throw Failure.foreignSource }
        guard snapshot.analysisReceipts.allSatisfy({ $0.detectorVersion == BetterleaksSecretDetector.version }),
              Set(snapshot.analysisReceipts.map(\.source)) == Set(snapshot.sourceKinds.keys),
              Set(snapshot.sourceKinds.keys) == Set(snapshot.sourceTimes.keys) else { throw Failure.receiptMismatch }
    }
    func report(snapshot: InventorySnapshot, payloadRows: Int, gaps: [CoverageGap] = [],
                cryptography: BackgroundCryptography) async throws -> Report {
        guard initialized else { throw Failure.unsafeState }
        try validate(snapshot)
        let media = descriptor.fixtureKind == .localImage
        var excludedDigests: [String] = []
        if media {
            guard gaps.count <= Self.maximumSources, gaps.allSatisfy(acceptsGap) else { throw Failure.incompleteRead }
            let references = Set(gaps.compactMap(\.recovery))
            guard references.count <= 1 else { throw Failure.incompleteRead }
            if let reference = references.first {
                guard snapshot.sourceTimes.first(where: { $0.key.session == session && $0.key.itemID == descriptor.itemID })?.value == reference.contentTime else { throw Failure.incompleteRead }
            }
            excludedDigests = try await digests("excluded-local-media", Array(references), cryptography)
        } else if !gaps.isEmpty { throw Failure.incompleteRead }
        let committed = receipt.map { snapshot.analysisReceipts.contains($0)
            && snapshot.sourceKinds[$0.source] == descriptor.contentType && snapshot.sourceTimes[$0.source] == observedTime } ?? false
        return try await Report(fixtureKind: descriptor.fixtureKind,
            expectedExcludedGapCount: media ? excludedDigests.count : nil, excludedGapEventCount: media ? gaps.count : nil,
            expectedExcludedGapDigests: media ? excludedDigests : nil, onlyExpectedExcludedMedia: media ? true : nil,
            initialStoreEmpty: initialStoreEmpty, initialReceiptDigests: initialReceipts,
            initialSourceKindDigests: initialKinds, initialSourceTimeDigests: initialTimes, initialConversationLabelDigests: initialLabels,
            receiptDigests: digests("receipt", Array(snapshot.analysisReceipts), cryptography),
            sourceKindDigests: digests("kind", snapshot.sourceKinds.map { Pair(key: $0.key, value: $0.value) }, cryptography),
            sourceTimeDigests: digests("time", snapshot.sourceTimes.map { Pair(key: $0.key, value: $0.value) }, cryptography),
            conversationLabelDigests: digests("label", snapshot.conversationLabels.map { Pair(key: $0.key, value: $0.value) }, cryptography),
            receiptCount: snapshot.analysisReceipts.count, sourceCount: snapshot.sourceKinds.count,
            sessionCount: Set(snapshot.sourceKinds.keys.map(\.session)).count, conversationLabelCount: snapshot.conversationLabels.count,
            observedTargetSourceCount: receipt == nil ? 0 : 1, committedTargetSourceCount: committed ? 1 : 0,
            targetSourceDigests: sourceDigest.map { [$0] } ?? [], targetResultDigests: resultDigest.map { [$0] } ?? [],
            targetReceiptDigests: digests("receipt", committed ? receipt.map { [$0] } ?? [] : [], cryptography),
            targetSegmentCount: receipt == nil ? 0 : descriptor.segments.count, targetTextBytes: receipt == nil ? 0 : descriptor.textBytes,
            nativeReadCount: nativeReadCount, nativeTargetVerified: failure == nil && nativeReadCount > 0 && nativeTime != nil,
            allObservedTargetSourcesCommitted: failure == nil && receipt != nil && committed && (!media || excludedDigests.count == 1),
            cleanInventory: failure == nil && WebResultAcceptance.hasNoFindings(snapshot) && payloadRows == 0,
            payloadRowCount: payloadRows, batchCount: batchCount, readerVersions: readerVersions.sorted(),
            producerVersions: receipt == nil ? [] : [descriptor.producerVersion])
    }
    private func digest<T: Encodable>(_ domain: String, _ value: T, _ crypto: BackgroundCryptography) async throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(value)
        guard encoded.count <= 64 * 1024 else { throw Failure.reportUnavailable }
        var bytes = Data(("native-content-acceptance-v1/" + domain + "\n").utf8); bytes.append(encoded)
        return try await crypto.revision(canonicalBytes: bytes).keyedDigest.base64EncodedString()
    }
    private func digests<T: Encodable>(_ domain: String, _ values: [T], _ crypto: BackgroundCryptography) async throws -> [String] {
        guard values.count <= Self.maximumSources else { throw Failure.reportUnavailable }
        var result: [String] = []
        for value in values { result.append(try await digest(domain, value, crypto)) }
        return result.sorted()
    }
}

struct NativeContentAcceptanceHistory: CodexHistoryReading {
    let client: any CodexHistoryReading
    let evidence: NativeContentAcceptance
    func readThread(_ id: String) async throws -> CodexThreadRead {
        try await evidence.checkSelection(id)
        let result = try await client.readThread(id); try await evidence.verifyThread(result); return result
    }
    func readThread(_ id: String, budget: CodexRPCBudget) async throws -> CodexThreadRead {
        try await evidence.checkSelection(id)
        let result = try await client.readThread(id, budget: budget); try await evidence.verifyThread(result); return result
    }
    func listThreads(cursor: String?, limit: Int, archived: Bool) async throws -> CodexHistoryPage {
        await evidence.reject(.foreignSource); throw CodexHistoryError.unsafeMethod
    }
    func listThreads(cursor: String?, limit: Int, archived: Bool, budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        await evidence.reject(.foreignSource); throw CodexHistoryError.unsafeMethod
    }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection) async throws -> CodexHistoryPage {
        try await evidence.checkSelection(threadID)
        let page = try await client.listTurns(threadID: threadID, cursor: cursor, limit: limit, direction: direction)
        try await evidence.verifyTurns(page); return page
    }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection, budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        try await evidence.checkSelection(threadID)
        let page = try await client.listTurns(threadID: threadID, cursor: cursor, limit: limit, direction: direction, budget: budget)
        try await evidence.verifyTurns(page); return page
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int, direction: CodexHistoryDirection) async throws -> CodexHistoryPage {
        try await evidence.checkSelection(threadID, turn: turnID)
        let page = try await client.listItems(threadID: threadID, turnID: turnID, cursor: cursor, limit: limit, direction: direction)
        try await evidence.verifyItems(page); return page
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int, direction: CodexHistoryDirection, budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        try await evidence.checkSelection(threadID, turn: turnID)
        let page = try await client.listItems(threadID: threadID, turnID: turnID, cursor: cursor, limit: limit, direction: direction, budget: budget)
        try await evidence.verifyItems(page); return page
    }
}
#endif
