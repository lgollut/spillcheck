import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor ReaderVersionHistory: CodexHistoryReading {
    var metadataVersion: String?
    let itemVersion: String?
    let listingVersion: String?
    let turnVersion: String?
    let empty: Bool
    let timestampFallback: Bool
    let now: Date
    var calls: [String] = []

    init(metadata: String? = "0.162.1", items: String? = "0.162.1",
         listing: String? = "0.162.1", turns: String? = "0.162.1",
         empty: Bool = false, timestampFallback: Bool = false, now: Date) {
        metadataVersion = metadata; itemVersion = items; listingVersion = listing
        turnVersion = turns; self.empty = empty; self.timestampFallback = timestampFallback; self.now = now
    }
    func replaceMetadataVersion(_ version: String?) { metadataVersion = version }
    func recordedCalls() -> [String] { calls }
    func readThread(_ id: String) throws -> CodexThreadRead {
        calls.append("metadata")
        return .init(thread: try codexThread(id, producer: "0.160.1",
            updatedAt: now.addingTimeInterval(-60).timeIntervalSince1970),
            bytesRead: 64, readerVersion: metadataVersion)
    }
    func listThreads(cursor: String?, limit: Int, archived: Bool) throws -> CodexHistoryPage {
        calls.append("listing")
        return .init(data: archived ? [] : [try codexThread(updatedAt: now.addingTimeInterval(-60).timeIntervalSince1970)],
            bytesRead: 64, readerVersion: listingVersion)
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int,
                   direction: CodexHistoryDirection) throws -> CodexHistoryPage {
        calls.append("items")
        return .init(data: empty ? [] : [try codexItem(timestamp: timestampFallback ? nil
            : now.addingTimeInterval(-10).timeIntervalSince1970 * 1000)],
            bytesRead: 64, readerVersion: itemVersion)
    }
    func listTurns(threadID: String, cursor: String?, limit: Int,
                   direction: CodexHistoryDirection) throws -> CodexHistoryPage {
        calls.append("turns")
        return .init(data: [try codexJSON(["id": "turn",
            "startedAt": now.addingTimeInterval(-10).timeIntervalSince1970,
            "completedAt": now.addingTimeInterval(-9).timeIntervalSince1970])],
            bytesRead: 64, readerVersion: turnVersion)
    }
}

private actor ReaderVersionCheckpoints {
    private var values: [UUID: SourceCheckpoint] = [:]
    func save(_ checkpoints: [SourceCheckpoint]) {
        for checkpoint in checkpoints { values[checkpoint.sourceDocumentID] = checkpoint }
    }
    func get(_ id: UUID) -> SourceCheckpoint? { values[id] }
}

private struct ReaderVersionRoutingNormalizer: CaptureNormalizer {
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        .init(sources: [])
    }
}

@Suite("Codex reader execution provenance")
struct CodexReaderVersionTests {
    private let now = Date(timeIntervalSince1970: 1_791_434_500)

    private func adapter(_ history: ReaderVersionHistory,
                         checkpoints: @escaping SourceCheckpointLookup = { _ in nil }) throws -> CodexAdapter {
        let authority = CodexTestAuthority()
        return try CodexAdapter(profileID: "test", agentVersion: "0.161.0", interface: .t3,
            history: history, authorityLookup: { await authority.lookup($0) },
            authorityRecorder: { try await authority.record($0) }, checkpointLookup: checkpoints)
    }

    @Test func uniformResponsesReportActualReaderRatherThanConfiguredOrProducerVersion() async throws {
        let history = ReaderVersionHistory(now: now)
        let batch = try await adapter(history).normalize(codexPacket(thread: "parent"),
            capturedAt: now, cryptography: .ephemeralForTesting())
        #expect(batch.observedReaderVersion == "0.162.1")
        #expect(batch.sources.count == 1 && batch.coverageGaps.isEmpty)
        #expect(batch.sources.first?.record.metadata.origin.agentVersion == "0.160.1")
        #expect(await history.recordedCalls() == ["metadata", "items"])
    }

    @Test func mixedOrMissingResponseVersionCannotBorrowAnotherResponseVersion() async throws {
        for metadata: String? in ["0.161.0", nil] {
            let history = ReaderVersionHistory(metadata: metadata, now: now)
            let batch = try await adapter(history).normalize(codexPacket(thread: "parent"),
                capturedAt: now, cryptography: .ephemeralForTesting())
            #expect(batch.sources.count == 1 && batch.coverageGaps.isEmpty)
            #expect(batch.observedReaderVersion == nil)
        }
    }

    @Test func discoveryAndTimestampFallbackParticipateInReaderEvidence() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let discovered = ReaderVersionHistory(listing: "0.161.0", now: now)
        let discoveryAdapter = try adapter(discovered)
        let request = CodexHistoryRequest(audit: try HistoricalAuditContext(reason: .resume, endingAt: now))
        let discovery = try await discoveryAdapter.normalize(discoveryAdapter.packet(request),
            capturedAt: now, cryptography: crypto)
        #expect(discovery.sources.count == 1 && discovery.observedReaderVersion == nil)
        #expect(await discovered.recordedCalls() == ["listing", "metadata", "items"])

        for turns: String? in ["0.162.1", "0.161.0", nil] {
            let history = ReaderVersionHistory(turns: turns, timestampFallback: true, now: now)
            let batch = try await adapter(history).normalize(codexPacket(thread: "parent"),
                capturedAt: now, cryptography: crypto)
            #expect(batch.sources.count == 1 && batch.coverageGaps.isEmpty)
            #expect(batch.observedReaderVersion == (turns == "0.162.1" ? "0.162.1" : nil))
            #expect(await history.recordedCalls() == ["metadata", "items", "turns"])
        }
    }

    @Test func validEmptyPollKeepsActualReadEvidence() async throws {
        let history = ReaderVersionHistory(empty: true, now: now)
        let batch = try await adapter(history).normalize(codexPacket(thread: "parent"),
            capturedAt: now, cryptography: .ephemeralForTesting())
        #expect(batch.sources.isEmpty && batch.coverageGaps.isEmpty && batch.observedRead)
        #expect(batch.observedReaderVersion == "0.162.1")
    }

    @Test func unchangedAuditUsesFreshMetadataReaderWithoutReusingPriorItemsVersion() async throws {
        let history = ReaderVersionHistory(now: now), checkpoints = ReaderVersionCheckpoints()
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let collector = try adapter(history, checkpoints: { await checkpoints.get($0) })
        let firstRequest = CodexHistoryRequest(audit: try HistoricalAuditContext(reason: .resume, endingAt: now), threads: ["parent"])
        let first = try await collector.normalize(collector.packet(firstRequest), capturedAt: now, cryptography: crypto)
        #expect(first.sources.count == 1 && first.observedReaderVersion == "0.162.1")
        await checkpoints.save(first.checkpoints)
        await history.replaceMetadataVersion("0.163.0")
        let nextRequest = CodexHistoryRequest(audit: try HistoricalAuditContext(reason: .resume,
            endingAt: now.addingTimeInterval(60)), threads: ["parent"])
        let unchanged = try await collector.normalize(collector.packet(nextRequest), capturedAt: now, cryptography: crypto)
        #expect(unchanged.sources.isEmpty && unchanged.historicalProgress?.hasUnreadContent == false)
        #expect(unchanged.observedReaderVersion == "0.163.0")
        #expect(await history.recordedCalls() == ["metadata", "items", "metadata"])
    }

    @Test func successfulExecutionVersionSurvivesRestartWithoutRewritingQueuedConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-reader-evidence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let permit = try #require(await store.processingPermit())
        let packet = try codexPacket(thread: "parent")
        let route = CollectionCaptureRoute(scope: .init(provider: .codex, profileID: "test",
            interface: .t3, path: .publicHistory), readerVersion: "0.161.0")
        let context = try route.context(for: packet, trigger: .activePoll)
        let id = UUID()
        _ = try await store.enqueue(packet.body, id: id, capturedAt: now, permit: permit, at: now, workContext: context)
        try await store.close()

        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let nextPermit = try #require(await reopened.processingPermit())
        let capture = try #require(try await reopened.nextPending(at: now, permit: nextPermit))
        #expect(capture.id == id)
        try await reopened.completeCapture(capture, successfulRead: true,
            observedReaderVersion: "0.162.1", observedProducerVersions: ["0.160.1"], permit: nextPermit, at: now)
        #expect(try await reopened.collectionWork(id: id)?.context == context)
        try await reopened.close()

        let final = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let report = try await final.coverageReport(endingAt: now)
        let read = try #require(report.successfulReads.items.first)
        #expect(read.readerVersion == "0.162.1" && read.producerVersions == ["0.160.1"])
        #expect(report.work.items.first?.context.readerVersion == "0.161.0")
        try await final.close()
    }

    @Test func missingMeasuredCodexVersionStaysUnknownWhileOtherProvidersKeepConfiguredFallback() async throws {
        for provider in [AgentProvider.codex, .claudeCode] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-reader-fallback-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let crypto = try BackgroundCryptography.ephemeralForTesting()
            let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
            let permit = try #require(await store.processingPermit())
            let context = CollectionWorkContext(scope: .init(provider: provider, profileID: "test",
                interface: .standaloneCLI, path: provider == .codex ? .publicHistory : .versionedTranscript),
                operation: .liveRead, readerVersion: "configured-version")
            let packet = try CapturePacket(metadata: .init(agent: provider, profileID: "test"),
                eventJSON: Data("{}".utf8))
            _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, workContext: context)
            let capture = try #require(try await store.nextPending(at: now, permit: permit))
            try await store.completeCapture(capture, successfulRead: true, permit: permit, at: now)
            let report = try await store.coverageReport(endingAt: now)
            #expect(report.successfulReads.items.first?.readerVersion == (provider == .codex ? nil : "configured-version"))
            try await store.close()
        }
    }

    @Test func routeVersionRefreshPreservesAuthorityAndPriorContextsWithoutLabellingHooksAsNativeReads() async throws {
        let authority = CodexTestAuthority()
        let nativeRoute = CollectionCaptureRoute(scope: .init(provider: .codex, profileID: "test",
            interface: .t3, path: .publicHistory), readerVersion: "0.161.0", hostVersion: "fake-host")
        let router = try CodexEnrolledSessionRouter(native: ReaderVersionRoutingNormalizer(),
            hooks: ReaderVersionRoutingNormalizer(), nativeRoute: nativeRoute,
            nativeAuthority: .publicNativeItems, authorityLookup: { await authority.lookup($0) })
        let nativePacket = try codexPacket(thread: "parent", event: "UserPromptSubmit")
        let prior = try await router.context(for: nativePacket, trigger: .helperDelivery,
            recordAuthority: { try await authority.record($0) })
        let session = try SessionIdentity(provider: .codex, profileID: "test", sessionID: "parent")
        let originalChoice = try #require(await authority.lookup(session))
        let updated = router.updatingReaderVersion("0.162.1")
        let future = try await updated.context(for: nativePacket, trigger: .helperDelivery,
            recordAuthority: { try await authority.record($0) })
        #expect(prior.readerVersion == "0.161.0" && future.readerVersion == "0.162.1")
        #expect(prior.scope == future.scope && prior.retry == future.retry && future.hostVersion == "fake-host")
        #expect(await authority.lookup(session) == originalChoice)
        let unchangedRouter = try await router.context(for: nativePacket, trigger: .helperDelivery,
            recordAuthority: { try await authority.record($0) })
        #expect(unchangedRouter == prior)

        let hookSession = try SessionIdentity(provider: .codex, profileID: "test", sessionID: "hook-owned")
        let hookChoice = try CollectionAuthorityChoice(session: hookSession,
            adapterVersion: CodexAdapter.adapterVersion, authorityID: CodexHookContentAdapter.authorityID)
        try await authority.record(hookChoice)
        let hook = try await updated.context(for: codexPacket(thread: "hook-owned", event: "UserPromptSubmit"),
            trigger: .helperDelivery, recordAuthority: { try await authority.record($0) })
        #expect(hook.scope.path == .hook && hook.readerVersion == nil && hook.hostVersion == "fake-host")
        #expect(await authority.lookup(hookSession) == hookChoice)
    }
}
