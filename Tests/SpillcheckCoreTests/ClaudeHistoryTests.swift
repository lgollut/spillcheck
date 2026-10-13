import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor ClaudeTestCheckpoints {
    var values: [UUID: SourceCheckpoint] = [:]
    func get(_ id: UUID) -> SourceCheckpoint? { values[id] }
    func commit(_ batch: CollectionBatch) { for checkpoint in batch.checkpoints { values[checkpoint.sourceDocumentID] = checkpoint } }
}
private func historyDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-claude-history-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
}
private func historyRow(_ id: String, text: String, date: String = "2026-10-07T20:00:00Z", session: String = "old-session") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["type": "user", "uuid": id, "sessionId": session,
        "timestamp": date, "version": "2.1.293", "message": ["role": "user", "content": text]], options: [.sortedKeys]) + Data([10])
}
private func historyAudit() throws -> HistoricalAuditContext {
    try .init(reason: .resume, endingAt: ISO8601DateFormatter().date(from: "2026-10-08T00:00:00Z")!)
}
private func historyAppend(_ data: Data, to url: URL) throws {
    let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
    try file.seekToEnd(); try file.write(contentsOf: data)
}

private struct ClaudeHistoryNoFindingsDetector: SecretDetector {
    func scan(_ source: SourceRecord) async throws -> DetectorOutput {
        .init(detectorVersion: "history-fixture", findings: [], unlocated: [])
    }
}
private actor ClaudeHistoryFailureObserver {
    var failures: [PipelineFailureDiagnostic] = []
    func record(_ failure: PipelineFailureDiagnostic) { failures.append(failure) }
}

@Suite("Claude bounded history")
struct ClaudeHistoryTests {
    @Test func temporarilyMissingHistorySourceRetriesSameAuditAcrossRestartAndRecoversExactly() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("temporarily-missing.jsonl"), good = directory.appendingPathComponent("good.jsonl")
        try historyRow("good", text: "still readable").write(to: good)
        let checkpoints = ClaudeTestCheckpoints(), crypto = try BackgroundCryptography.ephemeralForTesting(), audit = try historyAudit()
        func adapter() throws -> ClaudeAdapter {
            try ClaudeAdapter(profileID: "test", agentVersion: "2.1.295", allowedTranscriptRoots: [directory],
                checkpointLookup: { await checkpoints.get($0) }, historyBudget: .init(maximumSources: 1))
        }
        let original = try adapter()
        let first = try await original.normalize(original.historyPacket(.init(kind: ClaudeHistoryRequest.kind, version: 1,
            audit: audit, directories: [], pending: [missing.path, good.path], deferred: [], partial: false), interface: .t3),
            capturedAt: audit.end, cryptography: crypto)
        #expect(first.historicalProgress?.hasUnreadContent == true && first.continuation != nil)
        try historyRow("restored", text: "available original").write(to: missing)
        let restarted = try adapter()
        var packet = try #require(first.continuation), ids: [String] = [], final: CollectionBatch?
        for _ in 0..<4 {
            let batch = try await restarted.normalize(packet, capturedAt: audit.end, cryptography: crypto)
            await checkpoints.commit(batch)
            ids += batch.sources.map(\.record.metadata.identity.itemID)
            final = batch
            guard let next = batch.continuation else { break }
            packet = next
        }
        #expect(Set(ids) == ["prompt:good:block:0", "prompt:restored:block:0"])
        #expect(final?.continuation == nil && final?.historicalProgress?.hasUnreadContent == false)
        let failedReference = try #require(first.coverageGaps.first { $0.reason == .sourceUnavailable }?.recovery)
        #expect(failedReference.sourceDocumentID != nil)
        #expect(final?.recoveredReferences.contains { $0.identifiesSameLocation(as: failedReference) } == true)
        #expect(first.coverageGaps.filter { $0.reason == .sourceUnavailable }.allSatisfy {
            $0.scope?.interface == .t3 && $0.operation == .historicalRead && $0.diagnosticCode == .unavailableSource
        })
    }

    @Test func availabilityProofCannotSettleOtherWholeSourceGapsOnTheSameFile() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("flaky.jsonl")
        let checkpoints = ClaudeTestCheckpoints(), crypto = try BackgroundCryptography.ephemeralForTesting(), audit = try historyAudit()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.295", allowedTranscriptRoots: [directory],
            limits: .init(maximumBytes: 1024, maximumRowBytes: 512, maximumRows: 64),
            checkpointLookup: { await checkpoints.get($0) }, historyBudget: .init(maximumSources: 1))
        let first = try await adapter.normalize(adapter.historyPacket(.init(kind: ClaudeHistoryRequest.kind, version: 1,
            audit: audit, directories: [], pending: [file.path], deferred: [], partial: false), interface: .t3),
            capturedAt: audit.end, cryptography: crypto)
        let unavailable = try #require(first.coverageGaps.first { $0.reason == .sourceUnavailable }?.recovery)
        try (historyRow("first", text: "first") + historyRow("oversized", text: String(repeating: "x", count: 6000))
            + historyRow("last", text: "last")).write(to: file)
        var packet = try #require(first.continuation), gaps: [CoverageGap] = [], proofs: [CoverageRecoveryReference] = []
        for _ in 0..<20 {
            let batch = try await adapter.normalize(packet, capturedAt: audit.end, cryptography: crypto)
            await checkpoints.commit(batch)
            gaps += batch.coverageGaps
            proofs += batch.recoveredReferences.filter { $0.identifiesSameLocation(as: unavailable) }
            guard let next = batch.continuation else { break }
            packet = next
        }
        let oversized = try #require(gaps.first { $0.diagnosticCode == .oversizedRecord }?.recovery)
        #expect(!proofs.isEmpty)
        #expect(oversized.sourceDocumentID == unavailable.sourceDocumentID && !oversized.identifiesSameLocation(as: unavailable))
    }

    @Test func permanentlyMissingHistorySourceStopsAfterThreeAttemptsWithUnreadCoverage() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("permanently-missing.jsonl")
        let crypto = try BackgroundCryptography.ephemeralForTesting(), audit = try historyAudit()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.295", allowedTranscriptRoots: [directory])
        var packet = try adapter.historyPacket(.init(kind: ClaudeHistoryRequest.kind, version: 1,
            audit: audit, directories: [], pending: [missing.path], deferred: [], partial: false), interface: .standaloneCLI)
        var attempts = 0, final: CollectionBatch?
        for _ in 0..<5 {
            let batch = try await adapter.normalize(packet, capturedAt: audit.end, cryptography: crypto)
            attempts += 1; final = batch
            #expect(batch.sources.isEmpty)
            guard let next = batch.continuation else { break }
            packet = next
        }
        #expect(attempts == 3)
        #expect(final?.continuation == nil && final?.historicalProgress?.hasUnreadContent == true)
        #expect(final?.coverageGaps.contains { $0.reason == .sourceUnavailable } == true)
    }

    @Test func discardedOversizedHistoryRowKeepsFinalAuditPartial() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("oversized-audit.jsonl")
        try (historyRow("first", text: "first") + historyRow("oversized", text: String(repeating: "x", count: 6000))
            + historyRow("last", text: "last")).write(to: file)
        let checkpoints = ClaudeTestCheckpoints(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.295", allowedTranscriptRoots: [directory],
            limits: .init(maximumBytes: 1024, maximumRowBytes: 512, maximumRows: 64),
            checkpointLookup: { await checkpoints.get($0) })
        var packet = try await adapter.initialHistoricalCapture(audit: historyAudit()), final: CollectionBatch?, sawOversized = false
        var readableIDs = Set<String>()
        for _ in 0..<20 {
            let batch = try await adapter.normalize(packet, capturedAt: Date(), cryptography: crypto)
            await checkpoints.commit(batch)
            sawOversized = sawOversized || batch.coverageGaps.contains { $0.diagnosticCode == .oversizedRecord }
            readableIDs.formUnion(batch.sources.map(\.record.metadata.identity.itemID))
            final = batch
            guard let next = batch.continuation else { break }
            packet = next
        }
        #expect(sawOversized)
        #expect(final?.continuation == nil)
        #expect(final?.historicalProgress?.hasUnreadContent == true)
        #expect(readableIDs == ["prompt:first:block:0", "prompt:last:block:0"])
    }

    @Test func disposableHistoryAdmissionValidatesFrozenAuditAndLeavesOrdinaryHooksUnbound() async throws {
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.295", allowedTranscriptRoots: [])
        let audit = try historyAudit(), packet = try await adapter.initialHistoricalCapture(audit: audit)
        #expect(try ClaudeAdapter.historicalAuditForTesting(in: packet) == audit)
        let hook = try CapturePacket(metadata: .init(agent: .claudeCode, profileID: "test"),
            eventJSON: Data("{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"session\"}".utf8))
        #expect(try ClaudeAdapter.historicalAuditForTesting(in: hook) == nil)
        let malformed = try CapturePacket(metadata: packet.metadata,
            eventJSON: Data("{\"kind\":\"LeakretClaudeHistory\",\"version\":1}".utf8))
        #expect(throws: ClaudeCollectionError.invalidConfiguration) {
            try ClaudeAdapter.historicalAuditForTesting(in: malformed)
        }
        var json = try JSONSerialization.jsonObject(with: packet.eventJSON) as! [String: Any]
        json["version"] = 2
        let future = try CapturePacket(metadata: packet.metadata, eventJSON: JSONSerialization.data(withJSONObject: json))
        #expect(throws: ClaudeCollectionError.invalidConfiguration) {
            try ClaudeAdapter.historicalAuditForTesting(in: future)
        }
        json["version"] = 1
        var alteredAudit = json["audit"] as! [String: Any]
        alteredAudit["start"] = 0
        json["audit"] = alteredAudit
        let changedWindow = try CapturePacket(metadata: packet.metadata, eventJSON: JSONSerialization.data(withJSONObject: json))
        #expect(throws: ClaudeCollectionError.invalidConfiguration) {
            try ClaudeAdapter.historicalAuditForTesting(in: changedWindow)
        }
    }

    @Test func queueBoundHistoricalAuditSettlesProgressAndReportsUnboundCompletionFailure() async throws {
        for bindAudit in [false, true] {
            let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
            let sourceRoot = directory.appendingPathComponent("sources")
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
            let now = Date(), contentTime = now.addingTimeInterval(-3600)
            try historyRow("native-item", text: "required historical prompt", date: ISO8601DateFormatter().string(from: contentTime))
                .write(to: sourceRoot.appendingPathComponent("native.jsonl"))
            let crypto = try BackgroundCryptography.ephemeralForTesting()
            let store = try await ProtectedStore.open(at: directory.appendingPathComponent("store"), cryptography: crypto)
            let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.295", allowedTranscriptRoots: [sourceRoot],
                checkpointLookup: { id in try await store.checkpoint(documentID: id) })
            let audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
            let packet = try await adapter.initialHistoricalCapture(audit: audit)
            let preview = try await adapter.normalize(packet, capturedAt: now, cryptography: crypto)
            let emittedCheckpoint = try #require(preview.checkpoints.first)
            let admittedAudit = bindAudit ? try ClaudeAdapter.historicalAuditForTesting(in: packet) : nil
            let permit = try #require(await store.processingPermit())
            _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, historicalAudit: admittedAudit)
            let observer = ClaudeHistoryFailureObserver()
            let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
                detector: ClaudeHistoryNoFindingsDetector(), detectorVersion: "history-fixture", liveSince: now)
            await pipeline.observeFailuresForTesting { await observer.record($0) }
            let outcome = try await pipeline.processNext(at: now)
            let progress = try await store.historicalProgress(), failures = await observer.failures
            #expect(await store.snapshot().analysisReceipts.count == 1)
            if bindAudit {
                #expect(outcome == .processed && failures.isEmpty)
                #expect(try await store.queueStatistics().count == 0)
                #expect(progress.count == 1 && progress.first?.progress.audit == audit)
                #expect(progress.first?.progress.hasUnreadContent == false)
                // Discovery uses the configured physical root, which can differ from a temporary
                // directory alias. Completion must persist the exact adapter-emitted checkpoint.
                let persisted = try #require(await store.checkpoint(documentID: emittedCheckpoint.sourceDocumentID))
                #expect(persisted.sourceDocumentID == emittedCheckpoint.sourceDocumentID)
                #expect(persisted.byteOffset == emittedCheckpoint.byteOffset)
                #expect(persisted.lastContentTime == emittedCheckpoint.lastContentTime)
                #expect(persisted.gaps == emittedCheckpoint.gaps)
                let cursor = try JSONDecoder().decode(ClaudeReadCursor.self, from: #require(persisted.adapterState))
                #expect(cursor.parserContract == ClaudeAdapter.parserContractVersion)
            } else {
                #expect(outcome == .retryScheduled && progress.isEmpty)
                #expect(try await store.queueStatistics().count == 1)
                #expect(failures.count == 1)
                #expect(failures.first?.stage == .completeCapture)
                #expect(failures.first?.code == .storageInvalidPayload)
                #expect(failures.first?.reason == .captureRejected)
            }
            try await store.close()
        }
    }

    @Test(arguments: ["missing", "claude-transcript-3", "claude-transcript-6", "claude-transcript-7", "claude-transcript-8", "claude-transcript-9"])
    func parserContractUpdateRevisitsUnchangedSourceWithoutChangingNativeIdentity(oldContract: String) async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
        let file = directory.appendingPathComponent("upgrade.jsonl")
        try historyRow("native-row",text:"eligible unchanged content").write(to:file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID:"test",agentVersion:"2.1.295",allowedTranscriptRoots:[directory])
        let initial = try await adapter.readIncremental(path:file.path,interface:.standaloneCLI,cryptography:crypto)
        let checkpoint = try #require(initial.batch.checkpoints.first)
        var cursor = try JSONSerialization.jsonObject(with:try #require(checkpoint.adapterState)) as! [String:Any]
        if oldContract == "missing" { cursor.removeValue(forKey:"parserContract") }
        else { cursor["parserContract"] = oldContract }
        let old = SourceCheckpoint(capabilityID:checkpoint.capabilityID,sourceDocumentID:checkpoint.sourceDocumentID,
            revision:checkpoint.revision,byteOffset:checkpoint.byteOffset,lastContentTime:checkpoint.lastContentTime,
            gaps:checkpoint.gaps,adapterState:try JSONSerialization.data(withJSONObject:cursor))
        let recovered = try await adapter.readIncremental(path:file.path,interface:.t3,checkpoint:old,cryptography:crypto)
        #expect(recovered.bytesRead > 0 && recovered.batch.sources.count == 1)
        #expect(recovered.batch.checkpoints.first?.sourceDocumentID == checkpoint.sourceDocumentID)
        #expect(recovered.batch.sources.first?.record.metadata.identity == initial.batch.sources.first?.record.metadata.identity)
        #expect(recovered.batch.sources.first?.record.revision == initial.batch.sources.first?.record.revision)
        let current = try #require(recovered.batch.checkpoints.first)
        let caughtUp = try await adapter.readIncremental(path:file.path,interface:.standaloneCLI,checkpoint:current,cryptography:crypto)
        #expect(caughtUp.bytesRead == 0 && caughtUp.batch.sources.isEmpty)
    }

    @Test func parserUpdateRecoversConsumedNormalModeWarningWithoutSourceChanges() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mode-upgrade.jsonl")
        let control = try JSONSerialization.data(withJSONObject: ["type": "mode", "sessionId": "session",
            "mode": "normal"]) + Data([10])
        try control.write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [directory])
        let initial = try await adapter.readIncremental(path: file.path, expectedSessionID: "session", interface: .t3,
            cryptography: crypto)
        let checkpoint = try #require(initial.batch.checkpoints.first)
        var cursor = try JSONDecoder().decode(ClaudeReadCursor.self, from: #require(checkpoint.adapterState))
        #expect(cursor.forwardOffset == UInt64(control.count) && cursor.reverseEnd == 0)
        cursor.parserContract = "claude-transcript-9"
        let oldState = try JSONEncoder().encode(cursor)
        let session = try SessionIdentity(provider: .claudeCode, profileID: "test", sessionID: "session")
        let oldReference = CoverageRecoveryReference(session: session,
            locator: .transcriptByteOffset(documentID: checkpoint.capabilityID, byteOffset: 0),
            parserContract: "claude-transcript-9", sourceURL: file)
        // Parser 9 consumed this exact row and left a row-specific warning in its checkpoint.
        let oldGap = CoverageGap(reason: .unsupportedContent, capabilityID: checkpoint.capabilityID,
            scope: .init(provider: .claudeCode, profileID: "test", interface: .t3, path: .versionedTranscript),
            operation: .liveRead, recovery: oldReference, isRequiredFormatFailure: false,
            sourceKind: .claudeUnknownRecord)
        let old = SourceCheckpoint(capabilityID: checkpoint.capabilityID, sourceDocumentID: checkpoint.sourceDocumentID,
            revision: try await crypto.revision(canonicalBytes: oldState), byteOffset: checkpoint.byteOffset,
            lastContentTime: checkpoint.lastContentTime, gaps: [oldGap], adapterState: oldState)
        let recovered = try await adapter.readIncremental(path: file.path, expectedSessionID: "session", interface: .t3,
            checkpoint: old, cryptography: crypto)
        #expect(recovered.bytesRead > 0 && recovered.batch.sources.isEmpty && recovered.batch.coverageGaps.isEmpty)
        #expect(recovered.hasUnreadContent == false)
        let recovery = try #require(recovered.batch.recoveredReferences.first {
            $0.identifiesSameLocation(as: oldReference)
        })
        #expect(recovery.session == session && recovery.sourceURL == file && recovery.contentTime == nil)
        #expect(recovery.parserContract == ClaudeAdapter.parserContractVersion && recovery.parserContract != "claude-transcript-9")
        let current = try #require(recovered.batch.checkpoints.first)
        #expect(current.sourceDocumentID == checkpoint.sourceDocumentID && current.byteOffset == UInt64(control.count))
        #expect(current.gaps.isEmpty)
        let currentCursor = try JSONDecoder().decode(ClaudeReadCursor.self, from: #require(current.adapterState))
        #expect(currentCursor.parserContract == ClaudeAdapter.parserContractVersion)
        let warm = try await adapter.readIncremental(path: file.path, expectedSessionID: "session", interface: .t3,
            checkpoint: current, cryptography: crypto)
        #expect(warm.bytesRead == 0 && warm.batch.sources.isEmpty && warm.batch.coverageGaps.isEmpty)
        #expect(warm.batch.recoveredReferences.isEmpty && warm.hasUnreadContent == false)
        #expect(try Data(contentsOf: file) == control)
    }

    @Test func normalModeControlWithWrongExpectedSessionRemainsAGap() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("wrong-session-mode.jsonl")
        try (JSONSerialization.data(withJSONObject: ["type": "mode", "sessionId": "other-session",
            "mode": "normal"]) + Data([10])).write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.296", allowedTranscriptRoots: [directory])
        let rejected = try await adapter.readIncremental(path: file.path, expectedSessionID: "expected-session",
            interface: .t3, cryptography: crypto)
        #expect(rejected.batch.sources.isEmpty && rejected.batch.recoveredReferences.isEmpty)
        #expect(rejected.batch.coverageGaps.map(\.reason) == [.unsupportedContent])
    }

    @Test func parserUpdateRecoversChildPreviouslyReadUnderParentIdentity() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("agent-child.jsonl")
        try historyRow("child-prompt", text: "FAKE_CHILD_PROMPT", session: "native-child").write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory])
        let rejected = try await adapter.readIncremental(path: file.path, expectedSessionID: "parent", interface: .t3,
            cryptography: crypto)
        #expect(rejected.batch.sources.isEmpty)
        let omission = try #require(rejected.batch.coverageGaps.first { $0.reason == .unresolvedCorrelation }?.recovery)
        let checkpoint = try #require(rejected.batch.checkpoints.first)
        var cursor = try JSONDecoder().decode(ClaudeReadCursor.self, from: #require(checkpoint.adapterState))
        cursor.parserContract = "claude-transcript-7"
        let old = SourceCheckpoint(capabilityID: checkpoint.capabilityID, sourceDocumentID: checkpoint.sourceDocumentID,
            revision: checkpoint.revision, byteOffset: checkpoint.byteOffset, lastContentTime: checkpoint.lastContentTime,
            gaps: checkpoint.gaps, adapterState: try JSONEncoder().encode(cursor))
        let recovered = try await adapter.readIncremental(path: file.path, interface: .t3, checkpoint: old, cryptography: crypto)
        #expect(recovered.batch.sources.map(\.record.metadata.identity.itemID) == ["prompt:child-prompt:block:0"])
        #expect(recovered.batch.sources.first?.record.metadata.identity.session.sessionID == "native-child")
        #expect(recovered.batch.coverageGaps.isEmpty)
        #expect(recovered.batch.recoveredReferences.contains { $0.identifiesSameLocation(as: omission) })
        let warm = try await adapter.readIncremental(path: file.path, interface: .t3,
            checkpoint: recovered.batch.checkpoints.first, cryptography: crypto)
        #expect(warm.bytesRead == 0 && warm.batch.sources.isEmpty)
    }

    @Test func benchmarkColdWarmAnd78ByteAppendOnDisposableLargeHistory() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("benchmark.jsonl")
        var bytes = Data()
        for index in 0..<15000 { bytes += try historyRow("old-\(index)", text: String(repeating: "x", count: 900), date: "2020-01-01T00:00:00Z") }
        bytes += try historyRow("recent", text: "SYNTHETIC_BENCHMARK")
        try bytes.write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "benchmark", agentVersion: "2.1.293", allowedTranscriptRoots: [directory],
            limits: .init(maximumBytes: 64 * 1024, maximumRowBytes: 4096, maximumRows: 128))
        let clock = ContinuousClock(), coldStart = ContinuousClock.now
        let cold = try await adapter.readIncremental(path: file.path, interface: .standaloneCLI, provenance: .historical(historyAudit()), cryptography: crypto)
        let coldDuration = clock.now - coldStart
        let warmStart = clock.now
        let warm = try await adapter.readIncremental(path: file.path, interface: .standaloneCLI, checkpoint: cold.batch.checkpoints.first,
            provenance: .historical(historyAudit()), cryptography: crypto)
        let warmDuration = clock.now - warmStart
        // Independently exercise the live cursor; the historical audit freezes its file extent.
        let live = try await adapter.readIncremental(path: file.path, interface: .standaloneCLI, cryptography: crypto)
        var appended = Data("{\"type\":\"system\"}".utf8)
        appended += Data(repeating: 32, count: 77 - appended.count); appended.append(10)
        try historyAppend(appended, to: file)
        let appendStart = clock.now
        let append = try await adapter.readIncremental(path: file.path, interface: .standaloneCLI, checkpoint: live.batch.checkpoints.first, cryptography: crypto)
        let appendDuration = clock.now - appendStart
        func milliseconds(_ duration: Duration) -> Double {
            let value = duration.components
            return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
        }
        #expect(cold.bytesRead <= 65536 && warm.bytesRead == 0 && append.bytesRead < 8192)
        #expect(cold.batch.sources.count == 1 && append.batch.sources.isEmpty)
        let report: [String: Any] = ["schemaVersion": 1, "fixtureBytes": bytes.count, "appendPayloadBytes": appended.count,
            "coldBytesRead": cold.bytesRead, "warmBytesRead": warm.bytesRead, "appendBytesReadIncludingKeyedAnchors": append.bytesRead,
            "coldMilliseconds": milliseconds(coldDuration), "warmMilliseconds": milliseconds(warmDuration),
            "appendMilliseconds": milliseconds(appendDuration), "recentOldSessionObserved": cold.batch.sources.count == 1,
            "unreadPrefixExplicitlyPartial": cold.hasUnreadContent, "syntheticOnly": true]
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = project.appendingPathComponent(".build/implementation/claude-history-benchmark.json")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    }
    @Test func oldConversationRecentTailUsesContentTimeAndWarmReadsZero() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("old.jsonl")
        var bytes = Data()
        for index in 0..<3200 { bytes += try historyRow("old-\(index)", text: String(repeating: "a", count: 900), date: "2020-01-01T00:00:00Z") }
        bytes += try historyRow("recent", text: "SYNTHETIC_RECENT")
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: file.path)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory],
            limits: .init(maximumBytes: 64 * 1024, maximumRowBytes: 4096, maximumRows: 128))
        let result = try await adapter.readIncremental(path: file.path, interface: .standaloneCLI,
            provenance: .historical(historyAudit()), maximumBytes: 64 * 1024, cryptography: crypto)
        #expect(result.bytesRead <= 64 * 1024)
        #expect(result.batch.sources.map(\.record.metadata.identity.itemID) == ["prompt:recent:block:0"])
        // Rows before the first row dated before the cutoff are outside this audit, not unread.
        #expect(!result.hasUnreadContent && !result.canContinueHistory)
        #expect(!result.batch.coverageGaps.contains { $0.reason == .unresolvedCorrelation })
        let checkpoint = try #require(result.batch.checkpoints.first)
        let warm = try await adapter.readIncremental(path: file.path, interface: .standaloneCLI,
            checkpoint: checkpoint, provenance: .historical(historyAudit()), cryptography: crypto)
        #expect(warm.bytesRead == 0 && warm.batch.sources.isEmpty && !warm.hasUnreadContent)
        #expect(warm.batch.coverageGaps.isEmpty)
    }

    @Test func recentMtimeDoesNotMakeOldContentEligible() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("old.jsonl")
        try historyRow("old", text: "OLD_SYNTHETIC", date: "2020-01-01T00:00:00Z").write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory])
        let read = try await adapter.readIncremental(path: file.path, interface: .t3,
            provenance: .historical(historyAudit()), cryptography: crypto)
        #expect(read.batch.sources.isEmpty)
        #expect(!read.hasUnreadContent)
    }

    @Test func largeLiveAppendAndRestartKeepBoundedProgress() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large.jsonl")
        var bytes = Data()
        for index in 0..<16000 { bytes += try historyRow("old-\(index)", text: String(repeating: "a", count: 900)) }
        bytes += try historyRow("tail", text: "SYNTHETIC_TAIL")
        try bytes.write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory],
            limits: .init(maximumBytes: 64 * 1024, maximumRowBytes: 4096, maximumRows: 128))
        let cold = try await adapter.readIncremental(path: file.path, interface: .t3, cryptography: crypto)
        #expect(cold.batch.sources.contains { $0.record.metadata.identity.itemID == "prompt:tail:block:0" })
        #expect(cold.bytesRead <= 64 * 1024)
        let saved = try JSONDecoder().decode(SourceCheckpoint.self, from: JSONEncoder().encode(#require(cold.batch.checkpoints.first)))
        let appended = try historyRow("appended", text: "SYNTHETIC_APPEND")
        try historyAppend(appended, to: file)
        let changed = try await adapter.readIncremental(path: file.path, interface: .t3, checkpoint: saved, cryptography: crypto)
        #expect(changed.batch.sources.map(\.record.metadata.identity.itemID) == ["prompt:appended:block:0"])
        #expect(changed.bytesRead < 8192)
        let warm = try await adapter.readIncremental(path: file.path, interface: .t3,
            checkpoint: #require(changed.batch.checkpoints.first), cryptography: crypto)
        #expect(warm.bytesRead == 0)
    }

    @Test(arguments: [false, true])
    func rowBudgetBeforePartialTailKeepsCompleteRowsReadable(historical: Bool) async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("row-budget-partial-tail.jsonl")
        let firstRow = try historyRow("first", text: "SYNTHETIC_FIRST")
        let secondRow = try historyRow("second", text: "SYNTHETIC_COMPLETE_AFTER_ROW_BUDGET")
        let partialRow = try historyRow("partial", text: "SYNTHETIC_PARTIAL").dropLast(2)
        try (firstRow + secondRow + partialRow).write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory],
            limits: .init(maximumBytes: 4096, maximumRowBytes: 4096, maximumRows: 1))
        let provenance: SourceProvenance = historical ? .historical(try historyAudit()) : .live
        let first = try await adapter.readIncremental(path: file.path, interface: .standaloneCLI,
            provenance: provenance, cryptography: crypto)
        #expect(first.batch.sources.map(\.record.metadata.identity.itemID) == ["prompt:first:block:0"])
        #expect(first.hasForwardContent && first.hasUnreadContent && first.canContinueHistory)
        let saved = try JSONDecoder().decode(SourceCheckpoint.self,
            from: JSONEncoder().encode(#require(first.batch.checkpoints.first)))

        // No append occurs between reads. The complete second row must not wait for the partial tail.
        let second = try await adapter.readIncremental(path: file.path, interface: .standaloneCLI,
            checkpoint: saved, provenance: provenance, cryptography: crypto)
        #expect(second.batch.sources.map(\.record.metadata.identity.itemID) == ["prompt:second:block:0"])
        #expect(second.batch.checkpoints.first?.byteOffset == UInt64(firstRow.count + secondRow.count))
        #expect(!second.hasForwardContent && !second.canContinueHistory)
        let warm = try await adapter.readIncremental(path: file.path, interface: .standaloneCLI,
            checkpoint: #require(second.batch.checkpoints.first), provenance: provenance, cryptography: crypto)
        #expect(warm.bytesRead == 0 && warm.batch.sources.isEmpty)
        #expect(!warm.hasForwardContent && !warm.canContinueHistory)
    }

    @Test(arguments: [false, true])
    func parserUpdateRecoversCompleteRowBehindLegacyPartialTailCursor(historical: Bool) async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("legacy-row-budget-partial-tail.jsonl")
        let firstRow = try historyRow("first", text: "SYNTHETIC_FIRST")
        let secondRow = try historyRow("second", text: "SYNTHETIC_COMPLETE_AFTER_ROW_BUDGET")
        let partialRow = try historyRow("partial", text: "SYNTHETIC_PARTIAL").dropLast(2)
        try (firstRow + secondRow + partialRow).write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory],
            limits: .init(maximumBytes: 4096, maximumRowBytes: 4096, maximumRows: 1))
        let provenance: SourceProvenance = historical ? .historical(try historyAudit()) : .live
        let initial = try await adapter.readIncremental(path: file.path, interface: .standaloneCLI,
            provenance: provenance, cryptography: crypto)
        let checkpoint = try #require(initial.batch.checkpoints.first)
        var cursor = try JSONDecoder().decode(ClaudeReadCursor.self, from: #require(checkpoint.adapterState))
        cursor.parserContract = "claude-transcript-8"
        cursor.waitingForAppend = true
        let legacy = SourceCheckpoint(capabilityID: checkpoint.capabilityID, sourceDocumentID: checkpoint.sourceDocumentID,
            revision: checkpoint.revision, byteOffset: checkpoint.byteOffset, lastContentTime: checkpoint.lastContentTime,
            gaps: checkpoint.gaps, adapterState: try JSONEncoder().encode(cursor))

        let recovered = try await adapter.readIncremental(path: file.path, interface: .standaloneCLI,
            checkpoint: legacy, provenance: provenance, cryptography: crypto)
        #expect(recovered.bytesRead > 0 && recovered.hasForwardContent)
        #expect(recovered.batch.sources.map(\.record.metadata.identity) == initial.batch.sources.map(\.record.metadata.identity))
        #expect(recovered.batch.sources.map(\.record.revision) == initial.batch.sources.map(\.record.revision))
        #expect(recovered.batch.checkpoints.first?.sourceDocumentID == checkpoint.sourceDocumentID)
        let second = try await adapter.readIncremental(path: file.path, interface: .standaloneCLI,
            checkpoint: #require(recovered.batch.checkpoints.first), provenance: provenance, cryptography: crypto)
        #expect(second.batch.sources.map(\.record.metadata.identity.itemID) == ["prompt:second:block:0"])
        let warm = try await adapter.readIncremental(path: file.path, interface: .standaloneCLI,
            checkpoint: #require(second.batch.checkpoints.first), provenance: provenance, cryptography: crypto)
        #expect(warm.bytesRead == 0 && warm.batch.sources.isEmpty && !warm.canContinueHistory)
    }

    @Test func partialTailHeldThenCompleteAndFailedCommitReplaySameIdentity() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("partial.jsonl"), complete = try historyRow("partial", text: "SYNTHETIC_PARTIAL")
        try complete.dropLast(2).write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory])
        let partial = try await adapter.readIncremental(path: file.path, interface: .standaloneCLI, cryptography: crypto)
        #expect(partial.batch.sources.isEmpty && partial.batch.checkpoints.first?.byteOffset == 0)
        let held = try await adapter.readIncremental(path: file.path, interface: .standaloneCLI,
            checkpoint: #require(partial.batch.checkpoints.first), cryptography: crypto)
        #expect(held.bytesRead == 0)
        try historyAppend(Data(complete.suffix(2)), to: file)
        let first = try await adapter.readIncremental(path: file.path, interface: .standaloneCLI,
            checkpoint: partial.batch.checkpoints.first, cryptography: crypto)
        let replay = try await adapter.readIncremental(path: file.path, interface: .standaloneCLI,
            checkpoint: partial.batch.checkpoints.first, cryptography: crypto)
        #expect(first.batch.sources.count == 1)
        #expect(first.batch.sources.map(\.record.metadata.identity) == replay.batch.sources.map(\.record.metadata.identity))
        #expect(first.batch.sources.map(\.record.revision) == replay.batch.sources.map(\.record.revision))
    }

    @Test func equalSizeRewriteReplacementAndTruncateRegrowAreVisible() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("change.jsonl")
        let initial = try historyRow("initial", text: "AAAA")
        try initial.write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory])
        let read = try await adapter.readIncremental(path: file.path, interface: .t3, cryptography: crypto)
        let checkpoint = try #require(read.batch.checkpoints.first)
        try historyRow("initial", text: "BBBB").write(to: file)
        let rewrite = try await adapter.readIncremental(path: file.path, interface: .t3, checkpoint: checkpoint, cryptography: crypto)
        #expect(rewrite.batch.coverageGaps.contains { $0.reason == .sourceChanged })
        try historyRow("replacement", text: "REPLACEMENT").write(to: file, options: .atomic)
        let replaced = try await adapter.readIncremental(path: file.path, interface: .t3, checkpoint: checkpoint, cryptography: crypto)
        #expect(replaced.batch.coverageGaps.contains { $0.reason == .sourceChanged })
        #expect(replaced.batch.sources.first?.record.metadata.identity.itemID == "prompt:replacement:block:0")
        let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: historyRow("regrown", text: String(repeating: "C", count: 500))); try handle.close()
        let regrown = try await adapter.readIncremental(path: file.path, interface: .t3,
            checkpoint: #require(replaced.batch.checkpoints.first), cryptography: crypto)
        #expect(regrown.batch.coverageGaps.contains { $0.reason == .sourceChanged })
    }

    @Test func oversizeDrainMakesProgressAndFollowingValidRowSurvives() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("oversize.jsonl")
        try historyRow("first", text: "FIRST").write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory],
            limits: .init(maximumBytes: 1024, maximumRowBytes: 512, maximumRows: 64))
        let initial = try await adapter.readIncremental(path: file.path, interface: .standaloneCLI, cryptography: crypto)
        var checkpoint = try #require(initial.batch.checkpoints.first)
        try historyAppend(historyRow("too-big", text: String(repeating: "x", count: 6000)) + historyRow("following", text: "FOLLOWING"), to: file)
        var seen = Set<String>(), previous = checkpoint.byteOffset, gap = false
        for _ in 0..<16 {
            let read = try await adapter.readIncremental(path: file.path, interface: .standaloneCLI, checkpoint: checkpoint, cryptography: crypto)
            #expect(read.bytesRead <= 1024)
            gap = gap || read.batch.coverageGaps.contains { $0.reason == .budgetExhausted }
            seen.formUnion(read.batch.sources.map(\.record.metadata.identity.itemID))
            checkpoint = try #require(read.batch.checkpoints.first)
            #expect(checkpoint.byteOffset > previous); previous = checkpoint.byteOffset
            if !read.hasForwardContent { break }
        }
        #expect(gap && seen == ["prompt:following:block:0"])
    }

    @Test func historicalAndLiveCheckpointLanesDoNotSkipFutureRows() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("future.jsonl")
        try (historyRow("past", text: "PAST") + historyRow("future", text: "FUTURE", date: "2026-10-09T00:00:00Z")).write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory])
        let historic = try await adapter.readIncremental(path: file.path, interface: .t3, provenance: .historical(historyAudit()), cryptography: crypto)
        #expect(historic.batch.sources.count == 1)
        let liveKey = try await adapter.checkpointIdentity(path: file.path, provenance: .live, cryptography: crypto)
        #expect(historic.batch.checkpoints.first?.sourceDocumentID != liveKey)
        let live = try await adapter.readIncremental(path: file.path, interface: .t3, cryptography: crypto)
        #expect(live.batch.sources.count == 2)
        let later = try HistoricalAuditContext(reason: .restart, endingAt: ISO8601DateFormatter().date(from: "2026-10-10T00:00:00Z")!)
        let newlyEligible = try await adapter.readIncremental(path: file.path, interface: .t3,
            checkpoint: historic.batch.checkpoints.first, provenance: .historical(later), cryptography: crypto)
        #expect(newlyEligible.batch.sources.contains { $0.record.metadata.identity.itemID == "prompt:future:block:0" })
    }

    @Test func unchangedCheckpointDoesNotPublishBoundsOutsideLaterRollingAudit() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rolling.jsonl")
        try historyRow("boundary", text: "BOUNDARY", date: "2026-10-01T00:00:01Z").write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory])
        let firstAudit = try historyAudit()
        let first = try await adapter.readIncremental(path: file.path, interface: .t3, provenance: .historical(firstAudit), cryptography: crypto)
        #expect(first.newestContentTime != nil)
        let laterAudit = try HistoricalAuditContext(reason: .restart, endingAt: firstAudit.end.addingTimeInterval(2))
        let later = try await adapter.readIncremental(path: file.path, interface: .t3, checkpoint: first.batch.checkpoints.first,
            provenance: .historical(laterAudit), cryptography: crypto)
        #expect(later.bytesRead == 0 && later.batch.sources.isEmpty)
        #expect(later.newestContentTime == nil && later.oldestContentTime == nil)
    }

    @Test func continuouslyAppendedFutureContentCannotStarveFrozenHistoricalSuffix() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("continuous.jsonl")
        var initial = Data()
        for index in 0..<24 { initial += try historyRow("initial-\(index)", text: String(repeating: "x", count: 100)) }
        try initial.write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory],
            limits: .init(maximumBytes: 1024, maximumRowBytes: 512, maximumRows: 16))
        let audit = try historyAudit()
        var checkpoint: SourceCheckpoint?, seen = Set<String>(), finished = false
        for index in 0..<24 {
            let read = try await adapter.readIncremental(path: file.path, interface: .t3, checkpoint: checkpoint,
                provenance: .historical(audit), cryptography: crypto)
            #expect(read.bytesRead <= 1024)
            seen.formUnion(read.batch.sources.map(\.record.metadata.identity.itemID)); checkpoint = read.batch.checkpoints.first
            try historyAppend(historyRow("future-\(index)", text: String(repeating: "f", count: 1800), date: "2026-10-09T00:00:00Z"), to: file)
            if !read.canContinueHistory { finished = true; break }
        }
        #expect(finished && seen.count == 24)
        #expect(seen.allSatisfy { $0.hasPrefix("prompt:initial-") })
    }

    @Test func fairDiscoveryContinuationPreservesAuditAndOtherSourceProgress() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("a.jsonl"), b = directory.appendingPathComponent("b.jsonl")
        var large = Data()
        for index in 0..<80 { large += try historyRow("large-\(index)", text: String(repeating: "x", count: 200)) }
        try large.write(to: a); try historyRow("other", text: "OTHER").write(to: b)
        try Data([1,2,3]).write(to: directory.appendingPathComponent("unsupported.jsonl.zst"))
        let cache = ClaudeTestCheckpoints(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory],
            limits: .init(maximumBytes: 1024, maximumRowBytes: 512, maximumRows: 16),
            checkpointLookup: { await cache.get($0) }, historyBudget: .init(maximumBytes: 1024, maximumDuration: 1, maximumSources: 1))
        let audit = try historyAudit(); var packet: CapturePacket? = try await adapter.initialHistoricalCapture(audit: audit)
        var foundOther = false, allIDs = Set<SourceIdentity>(), unsupported = false
        for index in 0..<12 {
            guard let current = packet else { break }
            if index > 0 { try historyAppend(historyRow("growing-\(index)", text: "NEW"), to: a) }
            let batch = try await adapter.normalize(current, capturedAt: Date(), cryptography: crypto)
            await cache.commit(batch)
            #expect(batch.historicalProgress?.audit == audit)
            #expect((batch.historicalProgress?.bytesRead ?? Int.max) <= 1024)
            foundOther = foundOther || batch.sources.contains { $0.record.metadata.identity.itemID == "prompt:other:block:0" }
            allIDs.formUnion(batch.sources.map(\.record.metadata.identity))
            unsupported = unsupported || batch.coverageGaps.contains { $0.reason == .unsupportedContent }
            packet = batch.continuation
        }
        #expect(foundOther && unsupported && allIDs.count > 1)
    }

    @Test func drainedEligiblePagesCompleteAndCursorCannotTraverseOutsideRoot() async throws {
        let directory = try historyDirectory(), outside = try historyDirectory()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: outside) }
        let file = directory.appendingPathComponent("eligible.jsonl")
        var data = Data()
        for index in 0..<20 { data += try historyRow("eligible-\(index)", text: String(repeating: "x", count: 100)) }
        try data.write(to: file)
        try historyRow("outside", text: "OUTSIDE").write(to: outside.appendingPathComponent("private.jsonl"))
        let cache = ClaudeTestCheckpoints(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory],
            limits: .init(maximumBytes: 1024, maximumRowBytes: 512, maximumRows: 16), checkpointLookup: { await cache.get($0) },
            historyBudget: .init(maximumBytes: 1024, maximumDuration: 1, maximumSources: 1))
        let initial = try await adapter.initialHistoricalCapture(audit: historyAudit())
        var packet: CapturePacket? = initial, final: CollectionBatch?, seen = Set<SourceIdentity>()
        for _ in 0..<24 {
            guard let current = packet else { break }
            let batch = try await adapter.normalize(current, capturedAt: Date(), cryptography: crypto)
            await cache.commit(batch); seen.formUnion(batch.sources.map(\.record.metadata.identity))
            final = batch; packet = batch.continuation
        }
        #expect(packet == nil && seen.count == 20 && final?.historicalProgress?.hasUnreadContent == false)
        var malicious = try JSONDecoder().decode(ClaudeHistoryRequest.self, from: initial.eventJSON)
        malicious.directories = [.init(path: directory.path + "/../" + outside.lastPathComponent, depth: 0)]
        let refused = try await adapter.normalize(adapter.historyPacket(malicious, interface: .standaloneCLI), capturedAt: Date(), cryptography: crypto)
        #expect(refused.sources.isEmpty && refused.historicalProgress?.hasUnreadContent == true)
        #expect(refused.coverageGaps.contains { $0.reason == .sourceUnavailable })
    }

    @Test func relocationExplicitRootReplaysIdentityAndDeletedSourceIsUnavailable() async throws {
        let first = try historyDirectory(), second = try historyDirectory()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let original = first.appendingPathComponent("session.jsonl"), relocated = second.appendingPathComponent("session.jsonl")
        try historyRow("same", text: "SYNTHETIC").write(to: original)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [first, second])
        let before = try await adapter.readIncremental(path: original.path, interface: .t3, cryptography: crypto)
        try FileManager.default.moveItem(at: original, to: relocated)
        let moved = try await adapter.readIncremental(path: relocated.path, interface: .t3, cryptography: crypto)
        #expect(before.batch.sources.map(\.record.metadata.identity) == moved.batch.sources.map(\.record.metadata.identity))
        await #expect(throws: ClaudeCollectionError.awaitingTranscript) {
            try await adapter.readIncremental(path: original.path, interface: .t3, checkpoint: before.batch.checkpoints.first, cryptography: crypto)
        }
    }

    @Test func laterAuditRereadsOnlyRowsThePreviousAuditLeftToLiveCollection() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("resume.jsonl")
        var bytes = Data()
        for index in 0..<40 { bytes += try historyRow("in-window-\(index)", text: String(repeating: "w", count: 1000)) }
        bytes += try historyRow("future", text: "FUTURE", date: "2026-10-09T00:00:00Z")
        try bytes.write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory])
        let first = try await adapter.readIncremental(path: file.path, interface: .t3, provenance: .historical(historyAudit()), cryptography: crypto)
        #expect(first.batch.sources.count == 40)
        let later = try HistoricalAuditContext(reason: .restart, endingAt: ISO8601DateFormatter().date(from: "2026-10-10T00:00:00Z")!)
        let resumed = try await adapter.readIncremental(path: file.path, interface: .t3,
            checkpoint: first.batch.checkpoints.first, provenance: .historical(later), cryptography: crypto)
        #expect(resumed.batch.sources.map(\.record.metadata.identity.itemID) == ["prompt:future:block:0"])
        #expect(resumed.bytesRead < 6 * 1024 && resumed.bytesRead < bytes.count / 4)
        #expect(!resumed.hasUnreadContent)
    }

    @Test func liveTailCursorReportsItsUnreadPrefixOnce() async throws {
        let directory = try historyDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("live.jsonl")
        var bytes = Data()
        for index in 0..<30 { bytes += try historyRow("row-\(index)", text: String(repeating: "l", count: 1000)) }
        try bytes.write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory],
            limits: .init(maximumBytes: 8 * 1024, maximumRowBytes: 4096, maximumRows: 128))
        let cold = try await adapter.readIncremental(path: file.path, interface: .t3, cryptography: crypto)
        #expect(cold.batch.coverageGaps.contains { $0.reason == .unresolvedCorrelation })
        try historyAppend(historyRow("appended", text: "APPENDED"), to: file)
        let next = try await adapter.readIncremental(path: file.path, interface: .t3,
            checkpoint: cold.batch.checkpoints.first, cryptography: crypto)
        #expect(next.batch.sources.map(\.record.metadata.identity.itemID) == ["prompt:appended:block:0"])
        #expect(!next.batch.coverageGaps.contains { $0.reason == .unresolvedCorrelation })
        let unchanged = try await adapter.readIncremental(path: file.path, interface: .t3,
            checkpoint: next.batch.checkpoints.first, cryptography: crypto)
        #expect(unchanged.bytesRead == 0 && unchanged.batch.coverageGaps.isEmpty)
    }
}
