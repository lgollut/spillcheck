import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private func nativeHookPrompt(_ fragments: Any, id: String = "hook-prompt-native",
                              timestamp: Double = 1_791_434_400_000) throws -> CodexJSON {
    try codexItem(id, type: "hookPrompt", timestamp: timestamp, body: ["fragments": fragments])
}
private actor HookPromptCheckpoints {
    var values: [UUID: SourceCheckpoint] = [:]
    func save(_ value: SourceCheckpoint) { values[value.sourceDocumentID] = value }
    func get(_ id: UUID) -> SourceCheckpoint? { values[id] }
}
private let hookPromptFakeValue = "SPILLCHECK_FAKE_HOOK_INPUT_42"
private actor HookPromptDetector: SecretDetector {
    private(set) var calls = 0
    func scan(_ source: SourceRecord) throws -> DetectorOutput {
        calls += 1
        let value = Data(hookPromptFakeValue.utf8)
        var findings: [DetectorFinding] = []
        for segment in source.segments {
            if let range = segment.utf8.range(of: value) {
                let location = try CanonicalLocation(segmentID: segment.id,
                    range: .init(range.lowerBound, range.upperBound))
                findings.append(try .init(extraction: .init(valueUTF8: value, location: location, in: source), evidence: [evidence()]))
            }
        }
        return .init(detectorVersion: "fake-hook-input-detector", findings: findings, unlocated: [])
    }
}
private func inspectHookPromptFiles(_ directory: URL) throws {
    let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    for case let file as URL in files {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        #expect(try Data(contentsOf: file).range(of: Data(hookPromptFakeValue.utf8)) == nil)
    }
}

@Suite("Codex native hook-provided input")
struct CodexHookPromptContentTests {
    @Test func originalHookFragmentsKeepTheirOwnInputIdentityAndExactDecodedBytes() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1"), crypto = try BackgroundCryptography.ephemeralForTesting()
        let text = "é🙂\r\n<&> already decoded"
        let ordinary = try codexItem("ordinary-user", type: "userMessage", body: ["content": [["type": "text", "text": text]]])
        let hook = try nativeHookPrompt([["text": text, "hookRunId": "run-not-a-source-id"],
            ["text": text, "hookRunId": "run-not-a-source-id"]])
        let batch = try await adapter.importPublicItems(.init(data: [ordinary, hook]), thread: codexThread("owned-thread"),
            observedAt: Date(), cryptography: crypto)
        #expect(batch.coverageGaps.isEmpty && batch.sources.count == 2)
        let source = try #require(batch.sources.last)
        #expect(source.record.metadata.identity.session.sessionID == "owned-thread")
        #expect(source.record.metadata.identity.itemID == "hook-prompt-native")
        #expect(source.record.metadata.contentType == .userPrompt && source.record.metadata.locator == .upstreamItem)
        #expect(source.record.segments.map(\.id) == ["/fragments/0/text", "/fragments/1/text"])
        #expect(source.record.segments.map(\.utf8) == [Data(text.utf8), Data(text.utf8)])
        #expect(!codexText(source).contains("run-not-a-source-id"))
        #expect(batch.sources.first?.record.metadata.identity.itemID == "ordinary-user")
        #expect(batch.sources.first?.record.segments.map(\.id) == ["/content/0/text"])
        #expect(batch.recoveredReferences.contains { $0.itemID == "hook-prompt-native" })
    }

    @Test func replayAndRunMetadataDoNotCreateNewSourcesOrRevisionsAndPastedXMLStaysUserText() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        var records: [SourceRecord] = []
        for (run, text) in [("run-one", "same"), ("run-two", "same"), ("run-two", "changed")] {
            let batch = try await adapter.importPublicItems(.init(data: [nativeHookPrompt([["text": text, "hookRunId": run]])]),
                thread: codexThread(), observedAt: Date(), cryptography: crypto)
            records.append(try #require(batch.sources.first?.record))
        }
        #expect(records[0].metadata.identity == records[1].metadata.identity && records[1].metadata.identity == records[2].metadata.identity)
        #expect(records[0].revision == records[1].revision && records[1].revision != records[2].revision)
        let pasted = "<hook_prompt hook_run_id=\"user-pasted\">ordinary input</hook_prompt>"
        let batch = try await adapter.importPublicItems(.init(data: [codexItem("pasted", type: "userMessage", body: [
            "content": [["type": "text", "text": pasted]]])]), thread: codexThread(), observedAt: Date(), cryptography: crypto)
        #expect(batch.sources.first?.record.segments.map(\.id) == ["/content/0/text"])
        #expect(batch.sources.first.map(codexText) == pasted)
    }

    @Test func invalidFragmentMetadataLeavesRequiredGapWhileReadableSiblingsStillCollect() async throws {
        let fragments: [Any] = [["text": "first", "hookRunId": "valid"],
            ["text": "missing metadata"], ["text": "blank metadata", "hookRunId": " \n"],
            ["text": 12, "hookRunId": "valid"], "not-a-fragment",
            ["text": "invalid metadata type", "hookRunId": false],
            ["text": "last", "hookRunId": "valid-last"]]
        let batch = try await codexTestAdapter().importPublicItems(.init(data: [nativeHookPrompt(fragments)]),
            thread: codexThread(), observedAt: Date(), cryptography: BackgroundCryptography.ephemeralForTesting())
        let source = try #require(batch.sources.first)
        #expect(source.record.segments.map(\.id) == ["/fragments/0/text", "/fragments/1/text", "/fragments/2/text", "/fragments/5/text", "/fragments/6/text"])
        #expect(batch.coverageGaps.allSatisfy { $0.reason == .malformedSource && $0.isRequiredFormatFailure == true
            && $0.sourceKind?.rawValue == "codexHookPrompt" && $0.contentType == .userPrompt
            && $0.recovery?.itemID == "hook-prompt-native" })
        #expect(!batch.coverageGaps.isEmpty && batch.recoveredReferences.isEmpty)
    }

    @Test func missingFragmentListIsRequiredButValidEmptyInputHasNoInventedLocation() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        for fragments: Any in [NSNull(), false, "not-a-list", ["text": "not-a-list"]] {
            let batch = try await adapter.importPublicItems(.init(data: [nativeHookPrompt(fragments)]),
                thread: codexThread(), observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty)
            #expect(batch.coverageGaps.contains { $0.isRequiredFormatFailure == true && $0.sourceKind?.rawValue == "codexHookPrompt" })
        }
        for fragments: [Any] in [[], [["text": "", "hookRunId": "valid"]]] {
            let batch = try await adapter.importPublicItems(.init(data: [nativeHookPrompt(fragments)]),
                thread: codexThread(), observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.coverageGaps.isEmpty && batch.recoveredReferences.count == 1)
        }
    }

    @Test func fragmentAndRowBudgetsKeepOtherItemsAndNeverRecoverIncompleteInput() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let many = try nativeHookPrompt(Array(repeating: ["text": "tiny", "hookRunId": "run"], count: 1025))
        let batch = try await adapter.importPublicItems(.init(data: [many]), thread: codexThread(), observedAt: Date(), cryptography: crypto)
        #expect(batch.sources.first?.record.segments.count == 1024)
        #expect(batch.coverageGaps.contains { $0.reason == .budgetExhausted && $0.isRequiredFormatFailure == true })
        #expect(batch.recoveredReferences.isEmpty)
        let small = try codexTestAdapter(limits: .init(maximumRowBytes: 1024))
        let oversized = try nativeHookPrompt([["text": String(repeating: "🧪", count: 400), "hookRunId": "run"]])
        let bounded = try nativeHookPrompt([["text": "kept", "hookRunId": "run"]], id: "bounded-hook")
        let rows = try await small.importPublicItems(.init(data: [oversized, bounded]), thread: codexThread(), observedAt: Date(), cryptography: crypto)
        #expect(rows.sources.map(\.record.metadata.identity.itemID) == ["bounded-hook"])
        #expect(rows.coverageGaps.contains { $0.reason == .budgetExhausted && $0.isRequiredFormatFailure == true
            && $0.sourceKind?.rawValue == "codexHookPrompt" && $0.recovery?.itemID == "hook-prompt-native" })
        #expect(!rows.recoveredReferences.contains { $0.itemID == "hook-prompt-native" })
    }

    @Test func v8CleanAuditIsInvalidatedForAnUnchangedOriginalHookInput() async throws {
        let history = CodexTestHistory(), checkpoints = HookPromptCheckpoints()
        let crypto = try BackgroundCryptography.ephemeralForTesting(), now = Date(timeIntervalSince1970: 1_791_434_500)
        let thread = try codexThread(updatedAt: 1_791_434_400)
        await history.configure("parent", thread: thread, pages: [.init(data: [try nativeHookPrompt([["text": "original input", "hookRunId": "run"]])])])
        let adapter = try codexTestAdapter(history: history, checkpoints: { await checkpoints.get($0) })
        let audit = try HistoricalAuditContext(reason: .firstLaunch, endingAt: now)
        let first = try await adapter.normalize(adapter.packet(.init(audit: audit, threads: ["parent"])), capturedAt: now, cryptography: crypto)
        let checkpoint = try #require(first.checkpoints.first), stateBytes = try #require(checkpoint.adapterState)
        var state = try #require(try JSONSerialization.jsonObject(with: stateBytes) as? [String: Any])
        state["parserContract"] = "codex-content-contract-v8"
        await checkpoints.save(.init(capabilityID: checkpoint.capabilityID, sourceDocumentID: checkpoint.sourceDocumentID,
            revision: checkpoint.revision, byteOffset: checkpoint.byteOffset, lastContentTime: checkpoint.lastContentTime,
            adapterState: try JSONSerialization.data(withJSONObject: state)))
        let next = try HistoricalAuditContext(reason: .restart, endingAt: now.addingTimeInterval(30))
        let batch = try await adapter.normalize(adapter.packet(.init(audit: next, threads: ["parent"])), capturedAt: now, cryptography: crypto)
        #expect(batch.sources.map(\.record.metadata.identity.itemID) == ["hook-prompt-native"])
        #expect(batch.recoveredReferences.contains { $0.itemID == "hook-prompt-native" && $0.parserContract == CodexAdapter.parserContract })
    }

    @Test func hookContinuationNeverProvesTheKnownChildsOriginalTask() async throws {
        let history = CodexTestHistory(), now = Date(timeIntervalSince1970: 1_791_434_500)
        let child = try codexJSON(["id": "known-child", "parentThreadId": "parent", "cliVersion": "0.162.1",
            "updatedAt": 1_791_434_400])
        await history.configure("known-child", thread: child, pages: [.init(data: [try nativeHookPrompt([
            ["text": "hook continuation input", "hookRunId": "run"]])])])
        let adapter = try codexTestAdapter(history: history)
        let audit = try HistoricalAuditContext(reason: .firstLaunch, endingAt: now)
        let batch = try await adapter.normalize(adapter.packet(.init(audit: audit, threads: ["known-child"])),
            capturedAt: now, cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(batch.sources.count == 1 && batch.sources.first?.record.metadata.contentType == .userPrompt)
        #expect(batch.sources.first?.record.metadata.identity.session.sessionID == "known-child")
        #expect(batch.coverageGaps.contains { $0.diagnosticCode == .nativeChildInputUnavailable
            && $0.isRequiredFormatFailure == true && $0.recovery?.session?.sessionID == "known-child" })
        #expect(!batch.recoveredReferences.contains { $0.itemID == CodexAdapter.nativeChildInputRequirementID })
    }

    @Test func originalHookGapRecoversThroughEncryptedStoreAndColdReplayDoesNotDuplicate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-hook-input-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting(), detector = HookPromptDetector()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), contentTime = now.addingTimeInterval(-30)
        let history = CodexTestHistory()
        let session = try SessionIdentity(provider: .codex, profileID: "test", sessionID: "hook-input-session")
        let scope = CollectionScope(provider: .codex, profileID: "test", interface: .standaloneCLI, path: .publicHistory)
        await history.configure(session.sessionID, thread: try codexThread(session.sessionID), pages: [.init(data: [try nativeHookPrompt([
            ["text": hookPromptFakeValue, "hookRunId": "run"]], timestamp: contentTime.timeIntervalSince1970 * 1000)])])
        let originalGap = CoverageGap(reason: .unsupportedContent, scope: scope, operation: .liveRead,
            recovery: .init(session: session, locator: .upstreamItem, itemID: "hook-prompt-native", contentTime: contentTime,
                parserContract: "codex-content-contract-v8"), sourceKind: .codexUnknownItem, observedAt: contentTime)
        let unrelatedGap = CoverageGap(reason: .unsupportedContent, scope: scope, operation: .liveRead,
            recovery: .init(session: session, locator: .unavailable, itemID: CodexAdapter.nativeChildInputRequirementID,
                parserContract: "codex-content-contract-v8"), isRequiredFormatFailure: true,
            diagnosticCode: .nativeChildInputUnavailable, observedAt: contentTime)
        let packet = try codexPacket(thread: session.sessionID, interface: .standaloneCLI)
        let context = try CollectionCaptureRoute(scope: scope, readerVersion: "0.162.1").context(for: packet, trigger: .activePoll)
        var occurrenceID: UUID?, receiptCount = 0
        for replay in [false, true] {
            let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
            if !replay {
                try await store.recordCoverageGap(originalGap, at: contentTime)
                try await store.recordCoverageGap(unrelatedGap, at: contentTime)
            }
            let adapter = try CodexAdapter(profileID: "test", agentVersion: "0.162.1", history: history,
                authorityLookup: { try await store.authority(for: $0) }, authorityRecorder: { choice in
                    let permit = try #require(await store.processingPermit())
                    try await store.selectAuthority(choice, permit: permit)
                })
            let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
                detector: detector, detectorVersion: "fake-hook-input-detector")
            let permit = try #require(await store.processingPermit())
            _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, workContext: context)
            #expect(try await pipeline.processNext(at: now) == .processed)
            #expect(try await store.queueStatistics().count == 0)
            let omissions = try await store.coverageOmissions()
            #expect(omissions.count == 1 && omissions.first?.gap.diagnosticCode == .nativeChildInputUnavailable)
            let snapshot = await store.snapshot()
            #expect(snapshot.records.count == 1 && snapshot.occurrences.count == 1)
            let occurrence = try #require(snapshot.occurrences.values.first)
            #expect(occurrence.source.contentType == .userPrompt)
            #expect(occurrence.identity.source.session == session && occurrence.identity.source.itemID == "hook-prompt-native")
            #expect(occurrence.identity.location.components.map(\.segmentID) == ["/fragments/0/text"])
            if replay { #expect(occurrence.id == occurrenceID && snapshot.analysisReceipts.count == receiptCount) }
            else { occurrenceID = occurrence.id; receiptCount = snapshot.analysisReceipts.count }
            try await store.close()
        }
        #expect(await detector.calls == 1)
        try inspectHookPromptFiles(directory)
    }
}
