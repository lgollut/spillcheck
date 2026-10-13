import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private func mcpStructuredItem(_ structured: Any, id: String = "mcp-native", content: [Any] = [],
                               timestamp: Double = 1_791_434_400_000,
                               arguments: String = "request-only") throws -> CodexJSON {
    try codexItem(id, type: "mcpToolCall", timestamp: timestamp, body: ["status": "completed",
        "arguments": ["input": arguments], "error": NSNull(),
        "result": ["content": content, "structuredContent": structured]])
}

private actor MCPStructuredCheckpoints {
    var values: [UUID: SourceCheckpoint] = [:]
    func save(_ value: SourceCheckpoint) { values[value.sourceDocumentID] = value }
    func get(_ id: UUID) -> SourceCheckpoint? { values[id] }
}

private let mcpStructuredFakeValue = "SPILLCHECK_FAKE_MCP_STRUCTURED_VALUE_42"
private actor MCPStructuredDetector: SecretDetector {
    private(set) var calls = 0
    func scan(_ source: SourceRecord) throws -> DetectorOutput {
        calls += 1
        let value = Data(mcpStructuredFakeValue.utf8)
        var findings: [DetectorFinding] = []
        for segment in source.segments {
            if let range = segment.utf8.range(of: value) {
                let location = try CanonicalLocation(segmentID: segment.id,
                    range: .init(range.lowerBound, range.upperBound))
                findings.append(try .init(extraction: .init(valueUTF8: value, location: location, in: source),
                    evidence: [evidence()]))
            }
        }
        return .init(detectorVersion: "fake-mcp-structured-detector", findings: findings, unlocated: [])
    }
}

private struct MCPPriorProjection: CaptureNormalizer {
    let batch: CollectionBatch
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) async throws -> CollectionBatch { batch }
}

/// The unchanged v7 source-revision framing, applied to its two known retained
/// segments. This fixture models the former parser projection, not an old app run.
private func mcpProjectionBytes(_ segments: [SourceSegment]) -> Data {
    var data = Data("codex-segments-v1".utf8)
    for segment in segments {
        for bytes in [Data(segment.id.utf8), segment.utf8] {
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
    }
    return data
}

private func inspectMCPStructuredFiles(_ directory: URL) throws {
    let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    for case let file as URL in files {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        #expect(try Data(contentsOf: file).range(of: Data(mcpStructuredFakeValue.utf8)) == nil)
    }
}

@Suite("Codex native MCP opaque structured content")
struct CodexMCPStructuredContentTests {
    @Test func businessDiscriminantsAndContentKeysRetainExactStringsWithoutInventedProtocolWarnings() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1")
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        for type in ["image", "audio", "tool_reference", "encrypted_content", "text"] {
            let structured: [String: Any] = ["type": type, "caption": "é🙂\r\n",
                "encrypted_content": 42, "content": [["a/b~": "ordinary nested text"]],
                "resource": ["blob": "ordinary business blob"],
                "printed": "{\"type\":\"image\",\"caption\":\"literal\\nbytes\"}",
                "error": "business error", "status": "failed", "exit_code": 7, "isError": true]
            let batch = try await adapter.importPublicItems(.init(data: [mcpStructuredItem(structured)]),
                thread: codexThread("native-session", producer: "0.162.1"), observedAt: Date(), cryptography: crypto)
            let source = try #require(batch.sources.first)
            let strings = Dictionary(uniqueKeysWithValues: source.record.segments.map { ($0.id, String(decoding: $0.utf8, as: UTF8.self)) })
            #expect(source.record.metadata.identity.session.sessionID == "native-session")
            #expect(source.record.metadata.identity.itemID == "mcp-native")
            #expect(source.record.metadata.contentType == .toolOutput && source.record.metadata.locator == .upstreamItem)
            #expect(strings["/result/structuredContent/type"] == type)
            #expect(strings["/result/structuredContent/caption"] == "é🙂\r\n")
            #expect(strings["/result/structuredContent/content/0/a~1b~0"] == "ordinary nested text")
            #expect(strings["/result/structuredContent/resource/blob"] == "ordinary business blob")
            #expect(strings["/result/structuredContent/printed"] == structured["printed"] as? String)
            #expect(strings["/result/structuredContent/error"] == "business error")
            #expect(strings["/result/structuredContent/status"] == "failed")
            #expect(strings.count == 7 && !codexText(source).contains("request-only"))
            #expect(batch.coverageGaps.isEmpty && batch.recoveredReferences.count == 1)
        }
    }

    @Test func actualContentBlocksStillExcludeBinaryAndRequireEncryptedContent() async throws {
        let item = try mcpStructuredItem(["type": "image", "caption": "ordinary business caption"], content: [
            ["type": "text", "text": "retained protocol text"],
            ["type": "image", "data": "BINARY_MUST_STAY_EXCLUDED", "mimeType": "image/png"],
            ["type": "encrypted_content", "encrypted_content": "CIPHERTEXT_MUST_STAY_EXCLUDED"]])
        let batch = try await codexTestAdapter().importPublicItems(.init(data: [item]), thread: codexThread(),
            observedAt: Date(), cryptography: BackgroundCryptography.ephemeralForTesting())
        let source = try #require(batch.sources.first)
        #expect(source.record.segments.map(\.id) == ["/result/content/0/text", "/result/structuredContent/caption", "/result/structuredContent/type"])
        #expect(!codexText(source).contains("MUST_STAY_EXCLUDED"))
        #expect(batch.coverageGaps.contains { $0.diagnosticCode == .encryptedContentUnavailable && $0.requiresAnalysis })
        #expect(batch.coverageGaps.contains { $0.diagnosticCode == .excludedBinaryContent && !$0.requiresAnalysis })
        #expect(batch.recoveredReferences.isEmpty)
    }

    @Test func textFreeStructuredValuesAndReplayKeepNativeIdentityAndStableRevision() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        for value: Any in [NSNull(), [:] as [String: Any], [], ["numbers": [1, 2], "empty": ""], 3, false] {
            let batch = try await adapter.importPublicItems(.init(data: [mcpStructuredItem(value)]),
                thread: codexThread(), observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.coverageGaps.isEmpty && batch.recoveredReferences.count == 1)
        }
        var records: [SourceRecord] = []
        for (argument, caption) in [("request-one", "first"), ("request-two", "first"), ("request-two", "changed")] {
            let batch = try await adapter.importPublicItems(.init(data: [mcpStructuredItem(["type": "tool_reference", "caption": caption],
                arguments: argument)]), thread: codexThread(), observedAt: Date(), cryptography: crypto)
            records.append(try #require(batch.sources.first?.record))
            #expect(batch.coverageGaps.isEmpty && batch.recoveredReferences.count == 1)
        }
        #expect(records[0].metadata.identity == records[1].metadata.identity && records[1].metadata.identity == records[2].metadata.identity)
        #expect(records[0].segments == records[1].segments && records[0].revision == records[1].revision)
        #expect(records[1].revision != records[2].revision)
    }

    @Test func depthSegmentAndPointerBudgetsRetainReadableSiblingsWithoutRecovery() async throws {
        var deep: Any = "MUST_BE_BEYOND_DEPTH"
        for _ in 0..<34 { deep = [deep] }
        let longKey = String(repeating: "z", count: 900 * 1024)
        let values: [Any] = [["a": "readable", "z": deep],
            ["a": "readable", "z": Array(repeating: "tiny", count: 1025)],
            ["a": "readable", longKey: Array(repeating: "x", count: 1024)]]
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        for value in values {
            let item = try mcpStructuredItem(value, content: [["type": "text", "text": "protocol sibling"]])
            #expect(try JSONEncoder().encode(item).count < 1024 * 1024)
            let batch = try await adapter.importPublicItems(.init(data: [item]), thread: codexThread(),
                observedAt: Date(), cryptography: crypto)
            let source = try #require(batch.sources.first)
            #expect(codexText(source).contains("readable") && codexText(source).contains("protocol sibling"))
            #expect(!codexText(source).contains("MUST_BE_BEYOND_DEPTH"))
            #expect(source.record.segments.filter { $0.id.hasPrefix("/result/structuredContent/") }.count <= 1024)
            #expect(source.record.segments.reduce(0) { $0 + $1.id.utf8.count } <= 1024 * 1024)
            #expect(batch.coverageGaps.contains { $0.diagnosticCode == .readBudgetExceeded && $0.isRequiredFormatFailure == true
                && $0.sourceKind == .codexMCPToolCall && $0.recovery?.itemID == "mcp-native" })
            #expect(batch.recoveredReferences.isEmpty)
        }
    }

    @Test func v7CleanAuditCannotHidePreviouslySkippedOpaqueBusinessText() async throws {
        let history = CodexTestHistory(), checkpoints = MCPStructuredCheckpoints()
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: 1_791_434_500)
        let thread = try codexThread(updatedAt: 1_791_434_400)
        let item = try mcpStructuredItem(["type": "tool_reference", "caption": "previously skipped"])
        await history.configure("parent", thread: thread, pages: [.init(data: [item])])
        let adapter = try codexTestAdapter(history: history, checkpoints: { await checkpoints.get($0) })
        let audit = try HistoricalAuditContext(reason: .firstLaunch, endingAt: now)
        let first = try await adapter.normalize(adapter.packet(.init(audit: audit, threads: ["parent"])),
            capturedAt: now, cryptography: crypto)
        let checkpoint = try #require(first.checkpoints.first)
        let adapterState = try #require(checkpoint.adapterState)
        var state = try #require(try JSONSerialization.jsonObject(with: adapterState) as? [String: Any])
        state["parserContract"] = "codex-content-contract-v7"
        await checkpoints.save(.init(capabilityID: checkpoint.capabilityID, sourceDocumentID: checkpoint.sourceDocumentID,
            revision: checkpoint.revision, byteOffset: checkpoint.byteOffset, lastContentTime: checkpoint.lastContentTime,
            adapterState: try JSONSerialization.data(withJSONObject: state)))
        let next = try HistoricalAuditContext(reason: .restart, endingAt: now.addingTimeInterval(30))
        let batch = try await adapter.normalize(adapter.packet(.init(audit: next, threads: ["parent"])),
            capturedAt: now, cryptography: crypto)
        #expect(batch.sources.map(\.record.metadata.identity.itemID) == ["mcp-native"])
        #expect(batch.sources.first.map(codexText)?.contains("previously skipped") == true)
        #expect(batch.recoveredReferences.contains { $0.itemID == "mcp-native" && $0.parserContract == CodexAdapter.parserContract })
    }

    @Test func v7PartiallyCollectedItemAddsMissingTextWithoutReplacingExistingOccurrencesOrAlerts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-mcp-v7-upgrade-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting(), detector = MCPStructuredDetector()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), contentTime = now.addingTimeInterval(-30)
        let session = try SessionIdentity(provider: .codex, profileID: "test", sessionID: "mcp-upgrade")
        let scope = CollectionScope(provider: .codex, profileID: "test", interface: .standaloneCLI, path: .publicHistory)
        let history = CodexTestHistory()
        // v7 collected content/0/text and structuredContent/a, then wrongly treated
        // z/content as a protocol block list and omitted its untyped business row.
        let nativeItem = try mcpStructuredItem(["a": mcpStructuredFakeValue,
            "z": ["content": [["caption": mcpStructuredFakeValue]]]],
            content: [["type": "text", "text": mcpStructuredFakeValue]], timestamp: contentTime.timeIntervalSince1970 * 1000)
        let thread = try codexThread(session.sessionID, producer: "0.162.1")
        await history.configure(session.sessionID, thread: thread, pages: [.init(data: [nativeItem])])
        let reference = try await codexTestAdapter(interface: .standaloneCLI).importPublicItems(.init(data: [nativeItem]),
            thread: thread, observedAt: now, cryptography: crypto)
        let full = try #require(reference.sources.first)
        let priorSegments = try [SourceSegment(id: "/result/content/0/text", utf8: Data(mcpStructuredFakeValue.utf8)),
            SourceSegment(id: "/result/structuredContent/a", utf8: Data(mcpStructuredFakeValue.utf8))]
        let priorRecord = try SourceRecord(metadata: full.record.metadata,
            revision: await crypto.revision(canonicalBytes: mcpProjectionBytes(priorSegments)), segments: priorSegments)
        #expect(full.record.revision != priorRecord.revision)
        let oldGap = CoverageGap(reason: .malformedSource, scope: scope, operation: .liveRead,
            recovery: .init(session: session, locator: .upstreamItem, itemID: "mcp-native", contentTime: contentTime,
                parserContract: "codex-content-contract-v7"), isRequiredFormatFailure: true,
            sourceKind: .codexMCPToolCall, observedAt: contentTime)
        let prior = MCPPriorProjection(batch: .init(sources: [.init(record: priorRecord)], coverageGaps: [oldGap]))
        let packet = try codexPacket(thread: session.sessionID, interface: .standaloneCLI)
        let context = try CollectionCaptureRoute(scope: scope, readerVersion: "0.162.1").context(for: packet, trigger: .activePoll)
        let liveScope = try LiveCaptureScope(startedAt: now.addingTimeInterval(-120))
        var originalLocations: [OccurrenceIdentity: UUID] = [:]
        var originalAlerts: [UUID: AlertDecision] = [:]
        var updatedReceipts = Set<AnalysisReceipt>()
        var updatedLocations: [OccurrenceIdentity: UUID] = [:]
        for stage in 0...2 {
            let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
            let adapter = try CodexAdapter(profileID: "test", agentVersion: "0.162.1", history: history,
                authorityLookup: { try await store.authority(for: $0) }, authorityRecorder: { choice in
                    let permit = try #require(await store.processingPermit())
                    try await store.selectAuthority(choice, permit: permit)
                })
            let normalizer: any CaptureNormalizer = stage == 0 ? prior : adapter
            let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: normalizer,
                detector: detector, detectorVersion: "fake-mcp-structured-detector")
            let permit = try #require(await store.processingPermit())
            _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now,
                scope: liveScope, workContext: context)
            #expect(try await pipeline.processNext(at: now) == .processed)
            #expect(try await store.queueStatistics().count == 0)
            let snapshot = await store.snapshot()
            let locations = Dictionary(uniqueKeysWithValues: snapshot.occurrences.values.map { ($0.identity, $0.id) })
            #expect(snapshot.records.count == 1 && snapshot.occurrences.count == (stage == 0 ? 2 : 3))
            if stage == 0 {
                #expect(snapshot.analysisReceipts.count == 1)
                #expect(snapshot.analysisReceipts.contains(.init(source: priorRecord.metadata.identity,
                    revision: priorRecord.revision, detectorVersion: "fake-mcp-structured-detector")))
                #expect(try await store.coverageOmissions().count == 1)
                #expect(snapshot.alertDecisions.count == 1)
                originalLocations = locations; originalAlerts = snapshot.alertDecisions
            } else {
                #expect(originalLocations.allSatisfy { locations[$0.key] == $0.value })
                #expect(snapshot.alertDecisions == originalAlerts)
                #expect(snapshot.analysisReceipts.count == 2)
                #expect(try await store.coverageOmissions().isEmpty)
                #expect(try await store.coverageOmissions(includeRecovered: true).allSatisfy { $0.state == .recovered })
                if stage == 1 { updatedReceipts = snapshot.analysisReceipts; updatedLocations = locations }
                else {
                    #expect(snapshot.analysisReceipts == updatedReceipts && locations == updatedLocations)
                }
            }
            try await store.close()
        }
        #expect(await detector.calls == 2)
        try inspectMCPStructuredFiles(directory)
    }

    @Test func encryptedStoreRecoversOriginalStructuredOmissionAndColdReplayDoesNotRescan() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-mcp-structured-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting(), detector = MCPStructuredDetector()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), contentTime = now.addingTimeInterval(-60)
        let session = try SessionIdentity(provider: .codex, profileID: "test", sessionID: "mcp-session")
        let scope = CollectionScope(provider: .codex, profileID: "test", interface: .standaloneCLI, path: .publicHistory)
        let oldGap = CoverageGap(reason: .malformedSource, scope: scope, operation: .liveRead,
            recovery: .init(session: session, locator: .upstreamItem, itemID: "mcp-native", contentTime: contentTime,
                parserContract: "codex-content-contract-v7"), isRequiredFormatFailure: true,
            sourceKind: .codexMCPToolCall, observedAt: contentTime)
        let history = CodexTestHistory()
        await history.configure(session.sessionID, thread: try codexThread(session.sessionID), pages: [.init(data: [
            try mcpStructuredItem(["content": [["caption": mcpStructuredFakeValue]]], timestamp: contentTime.timeIntervalSince1970 * 1000)
        ])])
        let packet = try codexPacket(thread: session.sessionID, interface: .standaloneCLI)
        let context = try CollectionCaptureRoute(scope: scope, readerVersion: "0.162.1").context(for: packet, trigger: .activePoll)
        var originalOccurrence: UUID?, receiptCount = 0
        for replay in [false, true] {
            let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
            if !replay { try await store.recordCoverageGap(oldGap, at: contentTime) }
            let adapter = try CodexAdapter(profileID: "test", agentVersion: "0.162.1", history: history,
                authorityLookup: { try await store.authority(for: $0) }, authorityRecorder: { choice in
                    let permit = try #require(await store.processingPermit())
                    try await store.selectAuthority(choice, permit: permit)
                })
            let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
                detector: detector, detectorVersion: "fake-mcp-structured-detector")
            let permit = try #require(await store.processingPermit())
            _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, workContext: context)
            #expect(try await pipeline.processNext(at: now) == .processed)
            #expect(try await store.queueStatistics().count == 0)
            #expect(try await store.coverageOmissions().isEmpty)
            #expect(try await store.coverageOmissions(includeRecovered: true).allSatisfy { $0.state == .recovered })
            let snapshot = await store.snapshot()
            #expect(snapshot.records.count == 1 && snapshot.occurrences.count == 1)
            let occurrence = try #require(snapshot.occurrences.values.first)
            #expect(occurrence.identity.source == (try SourceIdentity(session: session, itemID: "mcp-native")))
            #expect(occurrence.identity.location.components.map(\.segmentID) == ["/result/structuredContent/content/0/caption"])
            if replay {
                #expect(occurrence.id == originalOccurrence && snapshot.analysisReceipts.count == receiptCount)
            } else { originalOccurrence = occurrence.id; receiptCount = snapshot.analysisReceipts.count }
            try await store.close()
        }
        #expect(await detector.calls == 1)
        try inspectMCPStructuredFiles(directory)
    }
}
