import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private let childNow = Date(timeIntervalSince1970: 1_791_434_500)
private actor ChildInputCheckpoints {
    var values: [UUID: SourceCheckpoint] = [:]
    func save(_ checkpoints: [SourceCheckpoint]) { for value in checkpoints { values[value.sourceDocumentID] = value } }
    func get(_ id: UUID) -> SourceCheckpoint? { values[id] }
}
private func childThread(_ extra: [String: Any] = ["parentThreadId": "parent"]) throws -> CodexJSON {
    try codexJSON(["id": "child", "cliVersion": "0.162.1", "updatedAt": childNow.addingTimeInterval(-60).timeIntervalSince1970]
        .merging(extra) { _, new in new })
}
private func childRequirement(_ batch: CollectionBatch) -> [CoverageGap] {
    batch.coverageGaps.filter { $0.diagnosticCode == .nativeChildInputUnavailable }
}
private func childAuditRequest(_ adapter: CodexAdapter, threads: [String] = ["child"]) throws -> CapturePacket {
    try adapter.packet(.init(audit: HistoricalAuditContext(reason: .restart, endingAt: childNow), threads: threads))
}
private func nativeSpawn(_ id: String = "spawn", child: String = "child", parent: String = "parent") throws -> CodexJSON {
    try codexItem(id, type: "collabAgentToolCall", body: ["tool": "spawnAgent", "status": "completed",
        "senderThreadId": parent, "receiverThreadIds": [child], "prompt": "parent arguments are not child input"])
}
private func inspectChildInputFiles(_ directory: URL) throws {
    let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        #expect(try Data(contentsOf: file).range(of: Data("FAKE_NATIVE_PARENT_ONLY".utf8)) == nil)
    }
}

@Suite("Codex missing original native child input")
struct CodexNativeChildInputTests {
    @Test(arguments: [AgentInterface.standaloneCLI, .desktopCode, .t3])
    func completeChildReadKeepsAvailableContentAndRequiredMissingRepresentation(interface: AgentInterface) async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        await history.configure("child", thread: try childThread(), pages: [.init(data: [try codexItem("child-final")])])
        let adapter = try codexTestAdapter(history: history, interface: interface)
        let batch = try await adapter.normalize(codexPacket(thread: "child", interface: interface), capturedAt: childNow, cryptography: crypto)
        let gap = try #require(childRequirement(batch).first)
        #expect(childRequirement(batch).count == 1 && batch.sources.count == 1)
        #expect(gap.reason == .unsupportedContent && gap.contentType == .userPrompt && gap.isRequiredFormatFailure == true)
        #expect(gap.recovery?.locator == .unavailable && gap.recovery?.itemID == CodexAdapter.nativeChildInputRequirementID)
        #expect(gap.recovery?.session?.sessionID == "child" && gap.recovery?.contentTime == nil && gap.sourceKind == nil)
        #expect(!batch.recoveredReferences.contains { $0.identifiesSameLocation(as: gap.recovery!) })
        #expect(batch.sources.first?.record.metadata.identity.itemID == "child-final")
    }

    @Test func mainForkAndConflictingMetadataDoNotProveChild() async throws {
        let cases: [[String: Any]] = [[:], ["forkedFromId": "parent"], ["parentThreadId": "child"],
            ["parentThreadId": "parent", "source": ["subAgent": ["thread_spawn": ["parent_thread_id": "other"]]]]]
        for extra in cases {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        await history.configure("child", thread: try childThread(extra), pages: [.init(data: [try codexItem()])])
        let adapter = try codexTestAdapter(history: history)
        let batch = try await adapter.normalize(codexPacket(thread: "child"), capturedAt: childNow, cryptography: crypto)
        #expect(childRequirement(batch).isEmpty)
        }
    }

    @Test func documentedSpawnMetadataAlsoProvesChildWithoutParentField() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        await history.configure("child", thread: try childThread(["source": ["subAgent": ["thread_spawn": ["parent_thread_id": "parent"]]]]),
            pages: [.init(data: [try codexItem()])])
        let adapter = try codexTestAdapter(history: history)
        #expect(childRequirement(try await adapter.normalize(codexPacket(thread: "child"), capturedAt: childNow, cryptography: crypto)).count == 1)
    }

    @Test func originalUserMessageIncludingInheritedPromptCannotProveIncomingAgentTask() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        await history.configure("child", thread: try childThread(["parentThreadId": "parent", "forkedFromId": "parent"]),
            pages: [.init(data: [try codexItem("inherited", type: "userMessage", body: ["content": [["type": "text", "text": "original parent prompt"]]])])])
        let adapter = try codexTestAdapter(history: history)
        let batch = try await adapter.normalize(codexPacket(thread: "child"), capturedAt: childNow, cryptography: crypto)
        #expect(batch.sources.first?.record.metadata.contentType == .userPrompt)
        #expect(childRequirement(batch).count == 1)
        #expect(!batch.recoveredReferences.contains { $0.itemID == CodexAdapter.nativeChildInputRequirementID })
    }

    @Test func emptySourceTruncatedTailWarmSuffixAndOldContinuationDoNotEstablishAbsence() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try codexTestAdapter(history: history)
        await history.configure("child", thread: try childThread(), pages: [.init(data: [])])
        #expect(childRequirement(try await adapter.normalize(childAuditRequest(adapter), capturedAt: childNow, cryptography: crypto)).isEmpty)
        await history.configure("child", thread: try childThread(), pages: [
            .init(data: [try codexItem("one"), try codexItem("two")], nextCursor: "1", backwardsCursor: "1"),
            .init(data: [try codexItem("last")])])
        #expect(childRequirement(try await adapter.normalize(codexPacket(thread: "child"), capturedAt: childNow, cryptography: crypto)).isEmpty)
        var warm = CodexHistoryRequest(audit: nil, threads: ["child"])
        warm.itemCursor = "1"; warm.liveBootstrapped = true
        #expect(childRequirement(try await adapter.normalize(adapter.packet(warm), capturedAt: childNow, cryptography: crypto)).isEmpty)
        var old = CodexHistoryRequest(audit: try HistoricalAuditContext(reason: .restart, endingAt: childNow), threads: ["child"])
        old.itemCursor = "1"
        #expect(childRequirement(try await adapter.normalize(adapter.packet(old), capturedAt: childNow, cryptography: crypto)).isEmpty)
    }

    @Test func completePaginationSurvivesRestartButMalformedPrefixNeverBecomesComplete() async throws {
        for malformed in [false, true] {
            let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
            let first = try malformed ? codexItem("bad", body: ["text": "bad", "phase": "unknown"]) : codexItem("first")
            await history.configure("child", thread: try childThread(), pages: [.init(data: [first], nextCursor: "1"), .init(data: [try codexItem("last")])])
            let adapter = try codexTestAdapter(history: history)
            let initial = try await adapter.normalize(childAuditRequest(adapter), capturedAt: childNow, cryptography: crypto)
            #expect(childRequirement(initial).isEmpty)
            let restarted = try codexTestAdapter(history: history)
            let final = try await restarted.normalize(#require(initial.continuation), capturedAt: childNow, cryptography: crypto)
            #expect(childRequirement(final).count == (malformed ? 0 : 1))
            #expect(final.historicalProgress?.hasUnreadContent == true)
        }
    }

    @Test func auditCutoffAndEntirelyOldItemsDoNotManufactureRecentMissingTask() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try codexTestAdapter(history: history)
        let old = try codexItem("old", timestamp: childNow.addingTimeInterval(-HistoricalAuditContext.lookback - 60).timeIntervalSince1970 * 1000)
        for next in [nil, "1"] as [String?] {
            await history.configure("child", thread: try childThread(), pages: [.init(data: [old], nextCursor: next)])
            let batch = try await adapter.normalize(childAuditRequest(adapter), capturedAt: childNow, cryptography: crypto)
            #expect(childRequirement(batch).isEmpty)
        }
    }

    @Test func textFreeAndExcludedMediaRowsStillEstablishNonemptyChildHistory() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let items = try [codexItem("empty", type: "webSearch", body: ["results": []]),
            codexItem("media", type: "dynamicToolCall", body: ["status": "completed", "success": true,
                "contentItems": [["type": "inputImage", "imageUrl": "fake-media"]]])]
        for item in items {
            await history.configure("child", thread: try childThread(), pages: [.init(data: [item])])
            let adapter = try codexTestAdapter(history: history)
            let batch = try await adapter.normalize(childAuditRequest(adapter), capturedAt: childNow, cryptography: crypto)
            #expect(batch.sources.isEmpty && childRequirement(batch).count == 1)
        }
    }

    @Test(arguments: ["spawnAgent", "sendInput", "wait"])
    func onlyActualSpawnCanSupplyParentLinkProof(tool: String) async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let spawn = try codexItem("relation", type: "collabAgentToolCall", body: ["tool": tool, "status": "completed",
            "senderThreadId": "parent", "receiverThreadIds": ["child"]])
        await history.configure("parent", thread: try codexThread(), pages: [.init(data: [spawn])])
        await history.configure("child", thread: try childThread([:]), pages: [.init(data: [try codexItem()])])
        let adapter = try codexTestAdapter(history: history)
        let parent = try await adapter.normalize(childAuditRequest(adapter, threads: ["parent"]), capturedAt: childNow, cryptography: crypto)
        let child = try await adapter.normalize(#require(parent.continuation), capturedAt: childNow, cryptography: crypto)
        #expect(childRequirement(child).count == (tool == "spawnAgent" ? 1 : 0))
    }

    @Test func childFirstDiscoveryRevisitsNewProofAndCannotReuseEarlierCleanAudit() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting(), checkpoints = ChildInputCheckpoints()
        await history.configure("child", thread: try childThread([:]), pages: [.init(data: [try codexItem()])])
        await history.configure("parent", thread: try codexThread(), pages: [.init(data: [try nativeSpawn()])])
        let adapter = try codexTestAdapter(history: history, checkpoints: { await checkpoints.get($0) })
        let first = try await adapter.normalize(childAuditRequest(adapter, threads: ["child", "parent"]), capturedAt: childNow, cryptography: crypto)
        #expect(childRequirement(first).isEmpty)
        await checkpoints.save(first.checkpoints)
        let parent = try await adapter.normalize(#require(first.continuation), capturedAt: childNow, cryptography: crypto)
        let child = try await adapter.normalize(#require(parent.continuation), capturedAt: childNow, cryptography: crypto)
        #expect(childRequirement(child).count == 1 && child.continuation == nil)
        #expect((await history.recordedCalls()).filter { $0 == "items:child:nil" }.count == 2)
        await checkpoints.save(child.checkpoints)
        let selected = try CoverageSourceRetryDescriptor(scope: adapter.collectionScope,
            session: SessionIdentity(provider: .codex, profileID: "test", sessionID: "child"))
        let retry = try await adapter.initialHistoricalCapture(audit: HistoricalAuditContext(reason: .resume, endingAt: childNow), source: selected)
        #expect(childRequirement(try await adapter.normalize(retry, capturedAt: childNow, cryptography: crypto)).count == 1)
    }

    @Test func selectedParentRetryDoesNotAccumulateUnneededChildProof() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let spawns = try (0..<257).map { try nativeSpawn("spawn-\($0)", child: "child-\($0)") }
        await history.configure("parent", thread: try codexThread(), pages: [.init(data: spawns)])
        let adapter = try codexTestAdapter(history: history)
        let source = try CoverageSourceRetryDescriptor(scope: adapter.collectionScope,
            session: SessionIdentity(provider: .codex, profileID: "test", sessionID: "parent"))
        let request = try await adapter.initialHistoricalCapture(audit: HistoricalAuditContext(reason: .resume, endingAt: childNow), source: source)
        let batch = try await adapter.normalize(request, capturedAt: childNow, cryptography: crypto)
        #expect(batch.coverageGaps.isEmpty && batch.continuation == nil)
        #expect(!(await history.recordedCalls()).contains { $0.hasPrefix("read:child") })
    }

    @Test func parserUpgradeInvalidatesOldCleanAuditAndKeepsMissingInputVisible() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting(), checkpoints = ChildInputCheckpoints()
        await history.configure("child", thread: try childThread(), pages: [.init(data: [try codexItem()])])
        let adapter = try codexTestAdapter(history: history, checkpoints: { await checkpoints.get($0) })
        let first = try await adapter.normalize(childAuditRequest(adapter), capturedAt: childNow, cryptography: crypto)
        let checkpoint = try #require(first.checkpoints.first)
        let savedState = try #require(checkpoint.adapterState)
        var old = try #require(try JSONSerialization.jsonObject(with: savedState) as? [String: Any])
        old["parserContract"] = "codex-content-contract-v5"; old["hasOmissions"] = false
        old.removeValue(forKey: "nativeChildParentID")
        await checkpoints.save([.init(capabilityID: checkpoint.capabilityID, sourceDocumentID: checkpoint.sourceDocumentID,
            revision: checkpoint.revision, byteOffset: 0, adapterState: try JSONSerialization.data(withJSONObject: old))])
        let again = try await adapter.normalize(childAuditRequest(adapter), capturedAt: childNow, cryptography: crypto)
        #expect(childRequirement(again).count == 1 && again.sources.count == 1)
    }

    @Test func genericRecoveryAndInheritedPromptCannotSettleRequirementAcrossStoreRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-child-input-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let processingTime = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        await history.configure("child", thread: try childThread(), pages: [.init(data: [try codexItem()])])
        let initialAdapter = try codexTestAdapter(history: history)
        let initial = try await initialAdapter.normalize(codexPacket(thread: "child"), capturedAt: childNow, cryptography: crypto)
        let requirement = try #require(childRequirement(initial).first)
        // The pipeline runs on the wall clock, so the processed item must be inside its lookback.
        await history.configure("child", thread: try childThread(["forkedFromId": "parent"]), pages: [.init(data: [
            try codexItem("inherited", type: "userMessage", timestamp: processingTime.timeIntervalSince1970 * 1000,
                          body: ["content": [["type": "text", "text": "FAKE_NATIVE_PARENT_ONLY"]]])])])
        let detector = ChildInputDetector()
        for restart in [false, true] {
            let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
            if !restart { try await store.recordCoverageGap(requirement, at: childNow) }
            let adapter = try CodexAdapter(profileID: "test", agentVersion: "0.162.1", interface: .t3, history: history,
                authorityLookup: { try await store.authority(for: $0) }, authorityRecorder: { choice in
                    let permit = try #require(await store.processingPermit())
                    try await store.selectAuthority(choice, permit: permit)
                })
            let packet = try codexPacket(thread: "child", extra: ["nonce": UUID().uuidString])
            let scope = CollectionScope(provider: .codex, profileID: "test", interface: .t3, path: .publicHistory)
            let context = try CollectionCaptureRoute(scope: scope, readerVersion: "0.162.1")
                .context(for: packet, trigger: .activePoll)
            let batch = try await adapter.normalize(packet, capturedAt: childNow, cryptography: crypto)
            #expect(batch.recoveredReferences.contains { $0.itemID == nil && $0.session?.sessionID == "child" })
            #expect(!batch.recoveredReferences.contains { $0.identifiesSameLocation(as: requirement.recovery!) })
            let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
                detector: detector, detectorVersion: "fake-child-input-detector")
            let permit = try #require(await store.processingPermit())
            _ = try await store.enqueue(packet.body, capturedAt: processingTime, permit: permit, at: processingTime, workContext: context)
            #expect(try await pipeline.processNext(at: processingTime) == .processed)
            let omissions = try await store.coverageOmissions()
            #expect(omissions.count == 1 && omissions.first?.state == .blocked)
            #expect(omissions.first?.gap.diagnosticCode == .nativeChildInputUnavailable)
            #expect(try await store.queueStatistics().count == 0)
            try await store.close()
        }
        #expect(await detector.calls == 1)
        try inspectChildInputFiles(directory)
    }
}

private actor ChildInputDetector: SecretDetector {
    private(set) var calls = 0
    func scan(_ source: SourceRecord) throws -> DetectorOutput {
        calls += 1
        return .init(detectorVersion: "fake-child-input-detector", findings: [], unlocated: [])
    }
}
