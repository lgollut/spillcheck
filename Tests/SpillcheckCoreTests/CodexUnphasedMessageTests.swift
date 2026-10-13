import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor UnphasedMessageCheckpoints {
    var values: [UUID: SourceCheckpoint] = [:]
    func save(_ value: SourceCheckpoint) { values[value.sourceDocumentID] = value }
    func get(_ id: UUID) -> SourceCheckpoint? { values[id] }
}
private let unphasedMessageFakeValue = "SPILLCHECK_FAKE_UNPHASED_VALUE_42"
private func inspectUnphasedMessageFiles(_ directory: URL) throws {
    let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    for case let file as URL in files {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        #expect(try Data(contentsOf: file).range(of: Data(unphasedMessageFakeValue.utf8)) == nil)
    }
}
private actor UnphasedMessageDetector: SecretDetector {
    private(set) var calls = 0
    func scan(_ source: SourceRecord) throws -> DetectorOutput {
        calls += 1
        let value = Data(unphasedMessageFakeValue.utf8)
        var findings: [DetectorFinding] = []
        for segment in source.segments {
            if let range = segment.utf8.range(of: value) {
                let location = try CanonicalLocation(segmentID: segment.id, range: .init(range.lowerBound, range.upperBound))
                findings.append(try .init(extraction: .init(valueUTF8: value, location: location, in: source), evidence: [evidence()]))
            }
        }
        return .init(detectorVersion: "fake-unphased-message-detector", findings: findings, unlocated: [])
    }
}

@Suite("Codex native assistant message phases")
struct CodexUnphasedMessageTests {
    @Test func explicitNullPhasePreservesOriginalMessageWithoutFinalAnswerClaim() async throws {
        let text = "é🙂\r\nOriginal review output"
        let entries = [try codexItem("unphased-original", body: ["phase": NSNull(), "text": text]),
            try codexItem("separate-final", body: ["phase": "final_answer", "text": "separate reply"]),
            try codexItem("missing-phase", body: ["text": "not structurally complete"])]
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let sibling = try await adapter.importPublicItems(.init(data: [entries[1]]), thread: codexThread(), observedAt: Date(), cryptography: crypto)
        let batch = try await adapter.importPublicItems(.init(data: entries), thread: codexThread(),
            observedAt: Date(), cryptography: crypto)
        #expect(batch.sources.map(\.record.metadata.identity.itemID) == ["unphased-original", "separate-final"])
        let source = try #require(batch.sources.first { $0.record.metadata.identity.itemID == "unphased-original" })
        #expect(source.record.metadata.contentType == .intermediateResponse)
        #expect(source.record.metadata.identity.session.sessionID == "parent" && source.record.metadata.locator == .upstreamItem)
        #expect(source.record.segments.map(\.id) == ["/text"])
        #expect(source.record.segments.map(\.utf8) == [Data(text.utf8)])
        #expect(source.record.metadata.contentTime == Date(timeIntervalSince1970: 1_791_434_400))
        #expect(batch.sources.last?.record.metadata.contentType == .finalResponse)
        #expect(batch.sources.last?.record.revision == sibling.sources.first?.record.revision)
        #expect(batch.coverageGaps.count == 1 && batch.coverageGaps.first?.recovery?.itemID == "missing-phase")
        #expect(batch.coverageGaps.first?.isRequiredFormatFailure == true)
        #expect(Set(batch.recoveredReferences.compactMap(\.itemID)) == ["unphased-original", "separate-final"])
    }

    @Test func missingMalformedAndUnknownPhasesRemainRequiredWithoutHidingSiblings() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        for phase: Any? in [nil, false, 0, ["commentary"], ["phase": "commentary"], "", "future_phase"] {
            var body: [String: Any] = ["text": "unknown classification"]
            body["phase"] = phase
            let batch = try await adapter.importPublicItems(.init(data: [codexItem("invalid-phase", body: body),
                codexItem("readable", body: ["phase": NSNull(), "text": "kept"])]), thread: codexThread(),
                observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.map(\.record.metadata.identity.itemID) == ["readable"])
            #expect(batch.coverageGaps.count == 1)
            let gap = try #require(batch.coverageGaps.first)
            #expect(gap.isRequiredFormatFailure == true && gap.sourceKind == .codexAgentMessage)
            #expect(gap.contentType == .intermediateResponse && gap.recovery?.itemID == "invalid-phase")
            #expect(!batch.recoveredReferences.contains { $0.itemID == "invalid-phase" })
        }
    }

    @Test func knownPartialAnswerPreservesTextWithoutFinalAnswerClaim() async throws {
        let batch = try await codexTestAdapter().importPublicItems(.init(data: [codexItem("partial-original", body: [
            "phase": "partial_answer", "text": "partial assistant text"])]), thread: codexThread(),
            observedAt: Date(), cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(batch.coverageGaps.isEmpty && batch.sources.count == 1)
        let source = try #require(batch.sources.first)
        #expect(source.record.metadata.contentType == .intermediateResponse)
        #expect(source.record.metadata.identity.itemID == "partial-original")
        #expect(source.record.segments.map(\.id) == ["/text"])
        #expect(source.record.segments.map(\.utf8) == [Data("partial assistant text".utf8)])
        #expect(batch.recoveredReferences.map(\.itemID) == ["partial-original"])
    }

    @Test func nullPhaseDoesNotWaiveTextShapeAndEmptyTextHasNoInventedLocation() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        for text: Any? in [nil, NSNull(), false, 0, ["not-text"], ["text": "not-string"]] {
            var body: [String: Any] = ["phase": NSNull()]
            body["text"] = text
            let batch = try await adapter.importPublicItems(.init(data: [codexItem("invalid-text", body: body)]),
                thread: codexThread(), observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty)
            #expect(batch.coverageGaps.first?.reason == .malformedSource && batch.coverageGaps.first?.isRequiredFormatFailure == true)
        }
        let empty = try await adapter.importPublicItems(.init(data: [codexItem("empty", body: ["phase": NSNull(), "text": ""])]),
            thread: codexThread(), observedAt: Date(), cryptography: crypto)
        #expect(empty.sources.isEmpty && empty.coverageGaps.isEmpty && empty.recoveredReferences.map(\.itemID) == ["empty"])
    }

    @Test func originalRevisionIsStableAndEquivalentReviewModeTextIsNotScannedAgain() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let original = try codexItem("original-message", body: ["phase": NSNull(), "text": "rendered review"])
        let review = try codexItem("review-presentation", type: "exitedReviewMode", body: ["review": "rendered review"])
        let first = try await adapter.importPublicItems(.init(data: [original]), thread: codexThread(),
            observedAt: Date(timeIntervalSince1970: 1_791_434_500), cryptography: crypto)
        let replay = try await adapter.importPublicItems(.init(data: [review, original]), thread: codexThread(),
            observedAt: Date(timeIntervalSince1970: 1_791_435_500), cryptography: crypto)
        #expect(replay.sources.count == 1 && replay.sources.first?.record.metadata.identity == first.sources.first?.record.metadata.identity)
        #expect(replay.sources.first?.record.revision == first.sources.first?.record.revision)
        #expect(replay.sources.first?.record.metadata.contentTime == first.sources.first?.record.metadata.contentTime)
        #expect(!replay.recoveredReferences.contains { $0.itemID == "review-presentation" })
        // Existing unsupported-review presentation remains visible; this change
        // never silently marks a separate unparsed native item as recovered.
        #expect(replay.coverageGaps.contains { $0.reason == .unsupportedContent && $0.recovery?.itemID == "review-presentation" })
        let commentary = try await adapter.importPublicItems(.init(data: [codexItem("original-message", body: [
            "phase": "commentary", "text": "rendered review"])]), thread: codexThread(), observedAt: Date(), cryptography: crypto)
        #expect(commentary.sources.first?.record.revision == first.sources.first?.record.revision)
        let changed = try await adapter.importPublicItems(.init(data: [codexItem("original-message", body: [
            "phase": NSNull(), "text": "changed original"])]), thread: codexThread(), observedAt: Date(), cryptography: crypto)
        #expect(changed.sources.first?.record.metadata.identity == first.sources.first?.record.metadata.identity)
        #expect(changed.sources.first?.record.revision != first.sources.first?.record.revision)
    }

    @Test func oversizedUnphasedMessageKeepsExistingRowBoundAndReadableSibling() async throws {
        let adapter = try codexTestAdapter(limits: .init(maximumRowBytes: 1024))
        let batch = try await adapter.importPublicItems(.init(data: [
            codexItem("oversized", body: ["phase": NSNull(), "text": String(repeating: "🧪", count: 512)]),
            codexItem("bounded", body: ["phase": NSNull(), "text": "kept"])]), thread: codexThread(),
            observedAt: Date(), cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(batch.sources.map(\.record.metadata.identity.itemID) == ["bounded"])
        #expect(batch.coverageGaps.contains { $0.reason == .budgetExhausted && $0.recovery?.itemID == "oversized" })
        #expect(!batch.recoveredReferences.contains { $0.itemID == "oversized" })
    }

    @Test func v10CompletedAuditReconsidersUnchangedOriginalUnphasedText() async throws {
        let history = CodexTestHistory(), checkpoints = UnphasedMessageCheckpoints()
        let crypto = try BackgroundCryptography.ephemeralForTesting(), now = Date(timeIntervalSince1970: 1_791_434_500)
        await history.configure("parent", thread: try codexThread(updatedAt: 1_791_434_400), pages: [.init(data: [
            try codexItem("original-message", body: ["phase": NSNull(), "text": "original review output"])])])
        let adapter = try codexTestAdapter(history: history, checkpoints: { await checkpoints.get($0) })
        let firstAudit = try HistoricalAuditContext(reason: .firstLaunch, endingAt: now)
        let first = try await adapter.normalize(adapter.packet(.init(audit: firstAudit, threads: ["parent"])),
            capturedAt: now, cryptography: crypto)
        let checkpoint = try #require(first.checkpoints.first), bytes = try #require(checkpoint.adapterState)
        var state = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        state["parserContract"] = "codex-content-contract-v10"
        await checkpoints.save(.init(capabilityID: checkpoint.capabilityID, sourceDocumentID: checkpoint.sourceDocumentID,
            revision: checkpoint.revision, byteOffset: checkpoint.byteOffset, lastContentTime: checkpoint.lastContentTime,
            adapterState: try JSONSerialization.data(withJSONObject: state)))
        let nextAudit = try HistoricalAuditContext(reason: .restart, endingAt: now.addingTimeInterval(30))
        let next = try await adapter.normalize(adapter.packet(.init(audit: nextAudit, threads: ["parent"])),
            capturedAt: now, cryptography: crypto)
        #expect(next.sources.map(\.record.metadata.identity.itemID) == ["original-message"] && next.coverageGaps.isEmpty)
        #expect(next.recoveredReferences.contains { $0.itemID == "original-message" && $0.parserContract == "codex-content-contract-v16" })
    }

    @Test func exactOldOmissionRecoversThroughEncryptedStoreAndColdReplayDoesNotDuplicate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-unphased-message-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting(), detector = UnphasedMessageDetector()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), contentTime = now.addingTimeInterval(-30)
        let history = CodexTestHistory()
        let session = try SessionIdentity(provider: .codex, profileID: "test", sessionID: "unphased-session")
        let scope = CollectionScope(provider: .codex, profileID: "test", interface: .standaloneCLI, path: .publicHistory)
        let original = try codexItem(
            "original-message", timestamp: contentTime.timeIntervalSince1970 * 1000,
            body: ["phase": NSNull(), "text": unphasedMessageFakeValue])
        let existingFinal = try codexItem("existing-final", timestamp: contentTime.timeIntervalSince1970 * 1000,
            body: ["phase": "final_answer", "text": unphasedMessageFakeValue])
        func oldGap(_ item: String) -> CoverageGap {
            .init(reason: .unsupportedContent, scope: scope, contentType: .intermediateResponse, operation: .liveRead,
                recovery: .init(session: session, locator: .upstreamItem, itemID: item, contentTime: contentTime,
                    parserContract: "codex-content-contract-v10"), isRequiredFormatFailure: true,
                sourceKind: .codexAgentMessage, observedAt: contentTime)
        }
        let packet = try codexPacket(thread: session.sessionID, interface: .standaloneCLI)
        let context = try CollectionCaptureRoute(scope: scope, readerVersion: "0.162.1").context(for: packet, trigger: .activePoll)
        var occurrenceID: UUID?, receiptCount = 0
        var previousOccurrence: Occurrence?, previousReceipts: Set<AnalysisReceipt> = []
        for replay in [false, true] {
            let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
            if !replay {
                try await store.recordCoverageGap(oldGap("original-message"), at: contentTime)
                try await store.recordCoverageGap(oldGap("unrelated-message"), at: contentTime)
            }
            let adapter = try CodexAdapter(profileID: "test", agentVersion: "0.162.1", history: history,
                authorityLookup: { try await store.authority(for: $0) }, authorityRecorder: { choice in
                    let permit = try #require(await store.processingPermit())
                    try await store.selectAuthority(choice, permit: permit)
                })
            let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
                detector: detector, detectorVersion: "fake-unphased-message-detector")
            let permit = try #require(await store.processingPermit())
            if !replay {
                await history.configure(session.sessionID, thread: try codexThread(session.sessionID), pages: [.init(data: [existingFinal])])
                _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, workContext: context)
                #expect(try await pipeline.processNext(at: now) == .processed)
                let before = await store.snapshot()
                previousOccurrence = try #require(before.occurrences.values.first)
                previousReceipts = before.analysisReceipts
                #expect(before.occurrences.count == 1 && previousReceipts.count == 1)
            }
            await history.configure(session.sessionID, thread: try codexThread(session.sessionID), pages: [.init(data: [existingFinal, original])])
            _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, workContext: context)
            #expect(try await pipeline.processNext(at: now) == .processed)
            #expect(try await store.queueStatistics().count == 0)
            let omissions = try await store.coverageOmissions()
            #expect(omissions.count == 1 && omissions.first?.gap.recovery?.itemID == "unrelated-message")
            let snapshot = await store.snapshot()
            #expect(snapshot.records.count == 1 && snapshot.occurrences.count == 2 && snapshot.analysisReceipts.count == 2)
            let retained = try #require(previousOccurrence)
            #expect(snapshot.occurrences[retained.id] == retained && previousReceipts.isSubset(of: snapshot.analysisReceipts))
            let occurrence = try #require(snapshot.occurrences.values.first { $0.identity.source.itemID == "original-message" })
            #expect(occurrence.source.contentType == .intermediateResponse && occurrence.source.contentTime == contentTime)
            #expect(occurrence.identity.source.session == session && occurrence.identity.source.itemID == "original-message")
            #expect(occurrence.identity.location.components.map(\.segmentID) == ["/text"])
            if replay { #expect(occurrence.id == occurrenceID && snapshot.analysisReceipts.count == receiptCount) }
            else { occurrenceID = occurrence.id; receiptCount = snapshot.analysisReceipts.count }
            try await store.close()
        }
        #expect(await detector.calls == 2)
        try inspectUnphasedMessageFiles(directory)
    }
}
