import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor CodexPlanCheckpoints {
    var values: [UUID: SourceCheckpoint] = [:]
    func save(_ checkpoint: SourceCheckpoint) { values[checkpoint.sourceDocumentID] = checkpoint }
    func get(_ id: UUID) -> SourceCheckpoint? { values[id] }
}

private let codexPlanValue = "SPILLCHECK_FAKE_PLAN_VALUE_42"

private func inspectCodexPlanFiles(_ directory: URL) throws {
    let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    for case let file as URL in files {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        #expect(try Data(contentsOf: file).range(of: Data(codexPlanValue.utf8)) == nil)
    }
}

private actor CodexPlanDetector: SecretDetector {
    private(set) var calls = 0
    func scan(_ source: SourceRecord) throws -> DetectorOutput {
        calls += 1
        let value = Data(codexPlanValue.utf8)
        var findings: [DetectorFinding] = []
        for segment in source.segments {
            if let range = segment.utf8.range(of: value) {
                let location = try CanonicalLocation(segmentID: segment.id,
                    range: .init(range.lowerBound, range.upperBound))
                findings.append(try .init(extraction: .init(valueUTF8: value, location: location, in: source),
                    evidence: [evidence()]))
            }
        }
        return .init(detectorVersion: "fake-plan-detector", findings: findings, unlocated: [])
    }
}

@Suite("Codex native plan content")
struct CodexPlanContentTests {
    @Test func planKeepsItsNativeIdentityAndOutsideAssistantTextKeepsItsRevision() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1")
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: 1_791_434_500)
        let audit = try HistoricalAuditContext(reason: .firstLaunch, endingAt: now)
        let thread = try codexThread(producer: "0.162.1")
        // Mirrors the producer's split: proposed-plan bytes are absent from the
        // surrounding agent message, and the plan has its own native item ID.
        let outside = try codexItem("outside", body: ["text": "Intro\nOutro", "phase": "final_answer"])
        let plan = try codexItem("turn-plan", type: "plan", body: ["text": "# Plan\n- 🧪 verify\n"])
        let original = try await adapter.importPublicItems(.init(data: [outside]), thread: thread,
            observedAt: now, provenance: .historical(audit), cryptography: crypto)
        let batch = try await adapter.importPublicItems(.init(data: [outside, plan]), thread: thread,
            observedAt: now, provenance: .historical(audit), cryptography: crypto)
        #expect(batch.coverageGaps.isEmpty && batch.sources.count == 2)
        let unchanged = try #require(batch.sources.first)
        #expect(unchanged.record.metadata == original.sources.first?.record.metadata)
        #expect(unchanged.record.revision == original.sources.first?.record.revision)
        #expect(unchanged.record.metadata.contentType == .finalResponse)
        let collected = try #require(batch.sources.last)
        #expect(collected.record.metadata.identity.itemID == "turn-plan")
        #expect(collected.record.metadata.identity.session.sessionID == "parent")
        #expect(collected.record.metadata.contentType == .intermediateResponse)
        #expect(collected.record.metadata.contentTime == Date(timeIntervalSince1970: 1_791_434_400))
        #expect(collected.record.metadata.locator == .upstreamItem)
        #expect(collected.record.metadata.origin.agentVersion == "0.162.1")
        #expect(collected.record.metadata.origin.provenance == .historical(audit))
        #expect(collected.record.metadata.origin.canonicalization == .exclusiveAuthority)
        #expect(collected.record.segments.map(\.id) == ["/text"])
        #expect(collected.record.segments.first?.utf8 == Data("# Plan\n- 🧪 verify\n".utf8))
        #expect(batch.recoveredReferences.contains { $0.itemID == "turn-plan"
            && $0.parserContract == CodexAdapter.parserContract })
    }

    @Test func malformedPlanIsRequiredAndDoesNotHideAReadableSibling() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1")
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let invalid: [[String: Any]] = [[:], ["text": NSNull()], ["text": true], ["text": 7],
            ["text": ["untyped text"]], ["text": ["text": "untyped object"]]]
        for body in invalid {
            let batch = try await adapter.importPublicItems(.init(data: [
                codexItem("invalid-plan", type: "plan", body: body),
                codexItem("readable", body: ["text": "kept", "phase": "commentary"])
            ]), thread: codexThread(), observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.map(\.record.metadata.identity.itemID) == ["readable"])
            #expect(batch.coverageGaps.count == 1)
            let gap = try #require(batch.coverageGaps.first)
            #expect(gap.reason == .malformedSource && gap.isRequiredFormatFailure == true)
            #expect(gap.sourceKind == .codexPlan && gap.contentType == .intermediateResponse)
            #expect(gap.recovery?.itemID == "invalid-plan")
            #expect(!batch.recoveredReferences.contains { $0.itemID == "invalid-plan" })
        }
    }

    @Test func oversizedPlanIsBoundedWithoutRecoveringTheSkippedItem() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1", limits: .init(maximumRowBytes: 1024))
        let batch = try await adapter.importPublicItems(.init(data: [
            codexItem("oversized-plan", type: "plan", body: ["text": String(repeating: "🧪", count: 512)]),
            codexItem("bounded-plan", type: "plan", body: ["text": "kept"])
        ]), thread: codexThread(), observedAt: Date(), cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(batch.sources.map(\.record.metadata.identity.itemID) == ["bounded-plan"])
        #expect(batch.coverageGaps.contains { $0.reason == .budgetExhausted && $0.sourceKind == .codexPlan
            && $0.isRequiredFormatFailure == true && $0.diagnosticCode == .readBudgetExceeded
            && $0.recovery?.itemID == "oversized-plan" })
        #expect(!batch.recoveredReferences.contains { $0.itemID == "oversized-plan" })
    }

    @Test func emptyPlanAndMirroredQuestionsDoNotInventAdditionalTextLocations() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1")
        let text = "Choose one\n- First\n- Second"
        let batch = try await adapter.importPublicItems(.init(data: [
            codexItem("empty-plan", type: "plan", body: ["text": ""]),
            codexItem("question", body: ["text": text, "phase": "final_answer", "delivery": "async",
                "questions": [["title": "Choose one", "options": ["First", "Second"]]]])
        ]), thread: codexThread(), observedAt: Date(), cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(batch.coverageGaps.isEmpty && batch.sources.count == 1)
        #expect(batch.sources.first?.record.segments.map(\.id) == ["/text"])
        #expect(batch.sources.first.map(codexText) == text)
    }

    @Test func v6CompleteAuditIsInvalidatedToReadPreviouslySkippedNativePlan() async throws {
        let history = CodexTestHistory(), checkpoints = CodexPlanCheckpoints()
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: 1_791_434_500)
        let thread = try codexThread(updatedAt: 1_791_434_400)
        let outside = try codexItem("outside", body: ["text": "unchanged outside", "phase": "final_answer"])
        await history.configure("parent", thread: thread, pages: [.init(data: [outside])])
        let adapter = try codexTestAdapter(history: history, version: "0.162.1", checkpoints: { await checkpoints.get($0) })
        let audit = try HistoricalAuditContext(reason: .firstLaunch, endingAt: now)
        let first = try await adapter.normalize(adapter.packet(.init(audit: audit, threads: ["parent"])),
            capturedAt: now, cryptography: crypto)
        let saved = try #require(first.checkpoints.first)
        let savedState = try #require(saved.adapterState)
        var state = try #require(try JSONSerialization.jsonObject(with: savedState) as? [String: Any])
        // Construct the prior parser's completed audit: the source updatedAt is
        // unchanged, but v6 did not scan the native Plan representation.
        state["parserContract"] = "codex-content-contract-v6"
        await checkpoints.save(.init(capabilityID: saved.capabilityID, sourceDocumentID: saved.sourceDocumentID,
            revision: saved.revision, byteOffset: saved.byteOffset, lastContentTime: saved.lastContentTime,
            adapterState: try JSONSerialization.data(withJSONObject: state)))
        await history.configure("parent", thread: thread, pages: [.init(data: [outside,
            try codexItem("turn-plan", type: "plan", body: ["text": "previously skipped plan"])
        ])])
        let next = try HistoricalAuditContext(reason: .restart, endingAt: now.addingTimeInterval(30))
        let after = try await adapter.normalize(adapter.packet(.init(audit: next, threads: ["parent"])),
            capturedAt: now, cryptography: crypto)
        #expect(after.sources.map(\.record.metadata.identity.itemID) == ["outside", "turn-plan"])
        #expect(after.sources.first?.record.metadata.identity == first.sources.first?.record.metadata.identity)
        #expect(after.sources.first?.record.revision == first.sources.first?.record.revision)
        #expect(after.historicalProgress?.hasUnreadContent == false)
        #expect(after.recoveredReferences.contains { $0.itemID == "turn-plan"
            && $0.parserContract == CodexAdapter.parserContract })
    }

    @Test func encryptedPipelineAddsPlanRecoversItsGapAndPreservesOtherTextAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-plan-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let contentTime = now.addingTimeInterval(-60)
        let history = CodexTestHistory(), detector = CodexPlanDetector()
        let outside = try codexItem("outside", timestamp: contentTime.timeIntervalSince1970 * 1000,
            body: ["text": codexPlanValue, "phase": "final_answer"])
        let scope = CollectionScope(provider: .codex, profileID: "test", interface: .standaloneCLI, path: .publicHistory)
        let packet = try codexPacket(thread: "plan-session", interface: .standaloneCLI)
        let context = try CollectionCaptureRoute(scope: scope, readerVersion: "0.162.1")
            .context(for: packet, trigger: .activePoll)
        var originalOutsideID: UUID?, originalPlanID: UUID?
        var completedReceiptCount = 0
        for stage in 0...3 {
            var items = [outside]
            if stage > 0 {
                let planText: Any = stage == 1 ? NSNull() : codexPlanValue
                items.append(try codexItem("turn-plan", type: "plan", timestamp: contentTime.timeIntervalSince1970 * 1000,
                    body: ["text": planText]))
            }
            await history.configure("plan-session", thread: try codexThread("plan-session", producer: "0.162.1"),
                pages: [.init(data: items)])
            let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
            let adapter = try CodexAdapter(profileID: "test", agentVersion: "0.162.1", interface: .standaloneCLI,
                history: history, authorityLookup: { try await store.authority(for: $0) },
                authorityRecorder: { choice in
                    let permit = try #require(await store.processingPermit())
                    try await store.selectAuthority(choice, permit: permit)
                })
            let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
                detector: detector, detectorVersion: "fake-plan-detector")
            let permit = try #require(await store.processingPermit())
            _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, workContext: context)
            #expect(try await pipeline.processNext(at: now) == .processed)
            #expect(try await store.queueStatistics().count == 0)
            let snapshot = await store.snapshot()
            let existing = try #require(snapshot.occurrences.values.first { $0.identity.source.itemID == "outside" })
            if stage == 0 { originalOutsideID = existing.id }
            #expect(existing.id == originalOutsideID && existing.source.contentType == .finalResponse)
            #expect(snapshot.records.count == 1 && snapshot.occurrences.count == (stage < 2 ? 1 : 2))
            if stage == 1 {
                #expect(try await store.coverageOmissions().count == 1)
            } else {
                #expect(try await store.coverageOmissions().isEmpty)
            }
            if stage >= 2 {
                let plan = try #require(snapshot.occurrences.values.first { $0.identity.source.itemID == "turn-plan" })
                #expect(plan.source.contentType == .intermediateResponse && plan.source.contentTime == contentTime)
                #expect(plan.identity.location.components.map(\.segmentID) == ["/text"])
                #expect(try await store.coverageOmissions(includeRecovered: true).allSatisfy { $0.state == .recovered })
                if stage == 2 {
                    originalPlanID = plan.id
                    completedReceiptCount = snapshot.analysisReceipts.count
                } else {
                    #expect(plan.id == originalPlanID && snapshot.analysisReceipts.count == completedReceiptCount)
                }
            }
            try await store.close()
        }
        #expect(await detector.calls == 2)
        try inspectCodexPlanFiles(directory)
    }
}
