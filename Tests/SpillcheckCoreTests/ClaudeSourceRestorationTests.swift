import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private struct ClaudeRestorationDetector: SecretDetector {
    func scan(_ source: SourceRecord) async throws -> DetectorOutput {
        .init(detectorVersion: "claude-restoration-fixture", findings: [], unlocated: [])
    }
}

private struct ClaudeRestorationUnavailableDetector: SecretDetector {
    func scan(_ source: SourceRecord) async throws -> DetectorOutput {
        .init(detectorVersion: "claude-restoration-fixture", findings: [], unlocated: [],
            coverageGaps: [.init(reason: .scannerUnavailable)], scannerFailure: .unavailable)
    }
}

private struct ClaudeRestorationFixture {
    let root: URL
    let sources: URL
    let affected: URL
    let healthy: URL
    let parked: URL
    let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let scope = CollectionScope(provider: .claudeCode, profileID: "owned-restoration",
        interface: .t3, path: .versionedTranscript)
    let crypto: BackgroundCryptography

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spillcheck-claude-restoration-\(UUID())").resolvingSymlinksInPath()
        sources = root.appendingPathComponent("sources")
        affected = sources.appendingPathComponent("affected.jsonl")
        healthy = sources.appendingPathComponent("healthy.jsonl")
        parked = root.appendingPathComponent("affected-original.jsonl")
        crypto = try .ephemeralForTesting()
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try row(session: "affected", id: "affected-first").write(to: affected)
        try row(session: "healthy", id: "healthy-first").write(to: healthy)
    }

    func row(session: String, id: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "user", "uuid": id,
            "sessionId": session, "timestamp": ISO8601DateFormatter().string(from: now),
            "version": "2.1.296", "message": ["role": "user", "content": "FAKE_RESTORATION_\(id)"]]) + Data([10])
    }

    func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    func packet(profile: String? = nil) throws -> CapturePacket {
        try .init(metadata: .init(agent: .claudeCode, interface: .t3, profileID: profile ?? scope.profileID),
            eventJSON: JSONSerialization.data(withJSONObject: ["hook_event_name": "SpillcheckTranscriptPoll",
                "session_id": "affected", "transcript_path": affected.path]))
    }

    func open() async throws -> (ProtectedStore, DetectionPipeline, ClaudeActiveTranscriptMonitor) {
        let store = try await ProtectedStore.open(at: root.appendingPathComponent("store"), cryptography: crypto)
        let adapter = try ClaudeAdapter(profileID: scope.profileID, agentVersion: "2.1.296",
            allowedTranscriptRoots: [sources], checkpointLookup: { try await store.checkpoint(documentID: $0) })
        let route = CollectionCaptureRoute(scope: scope, readerVersion: "2.1.296")
        let liveScope = try LiveCaptureScope(startedAt: now)
        let monitor = try ClaudeActiveTranscriptMonitor(profileID: scope.profileID,
            sources: [try .init(sessionID: "affected", transcriptURL: affected),
                      try .init(sessionID: "healthy", transcriptURL: healthy)],
            enqueue: { packet, time in
                let permit = try #require(await store.processingPermit())
                let context = try route.context(for: packet, trigger: .activePoll)
                _ = try await store.enqueue(packet.body, capturedAt: time, permit: permit, at: time,
                    scope: liveScope, workContext: context)
            }, onGap: { gap in
                // The fixture's polls and reports run on `now`, not the wall clock. A gap dated by
                // the wall clock fell outside the report window whenever the suite ran slowly.
                try? await store.recordCoverageGap(gap, at: gap.observedAt ?? now)
            })
        let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
            detector: ClaudeRestorationDetector(), detectorVersion: "claude-restoration-fixture", liveSince: now)
        return (store, pipeline, monitor)
    }

    func establishFailureAndHealthyProgress(store: ProtectedStore, pipeline: DetectionPipeline,
                                            monitor: ClaudeActiveTranscriptMonitor) async throws {
        #expect(try await monitor.pollOnce(at: now) == 2)
        #expect(try await pipeline.processNext(at: now) == .processed)
        #expect(try await pipeline.processNext(at: now) == .processed)
        #expect(await store.snapshot().analysisReceipts.count == 2)
        #expect(try await store.coverageGaps().isEmpty)

        // Rename away and back preserves the original file, inode, bytes and mtime.
        try FileManager.default.moveItem(at: affected, to: parked)
        #expect(try await monitor.pollOnce(at: now.addingTimeInterval(1)) == 0)
        let missing = try await store.coverageGaps()
        #expect(missing.count == 1 && missing.first?.reason == .sourceUnavailable)
        #expect(missing.first?.scope == scope && missing.first?.operation == .liveRead)
        #expect(missing.first?.recovery?.sourceURL == affected)
        #expect(missing.first?.recovery?.session?.sessionID == "affected")

        try append(row(session: "healthy", id: "healthy-while-other-unavailable"), to: healthy)
        let time = now.addingTimeInterval(2)
        #expect(try await monitor.pollOnce(at: time) == 1)
        #expect(try await pipeline.processNext(at: time) == .processed)
        let snapshot = await store.snapshot()
        #expect(snapshot.analysisReceipts.count == 3)
        #expect(snapshot.sourceKinds.keys.contains { $0.session.sessionID == "healthy"
            && $0.itemID == "prompt:healthy-while-other-unavailable:block:0" })
        let coverage = try await store.coverageReport(endingAt: time)
        #expect(!coverage.isTruncated)
        #expect(coverage.gapEvents.items.count == 2)
        #expect(coverage.gapEvents.items.allSatisfy { $0.gap.reason == .sourceUnavailable })
        #expect(coverage.unresolvedOmissions.count == 1)
        #expect(coverage.unresolvedOmissions.first?.state == .retryable)
        #expect(coverage.unresolvedOmissions.first?.gap.recovery?.sourceURL == affected)
        #expect(coverage.activeGapEvents.isEmpty)
        #expect(try await store.queueStatistics().count == 0)
        try FileManager.default.moveItem(at: parked, to: affected)
    }
}

@Suite("Claude exact source restoration")
struct ClaudeSourceRestorationTests {
    @Test func unchangedOriginalReturnIsReadAgainAndResolvesItsAvailabilityWarning() async throws {
        let fixture = try ClaudeRestorationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (store, pipeline, monitor) = try await fixture.open()
        try await fixture.establishFailureAndHealthyProgress(store: store, pipeline: pipeline, monitor: monitor)
        let time = fixture.now.addingTimeInterval(3)
        let successfulReads = try await store.coverageReport(endingAt: time).successfulReads.items
        let queued = try await monitor.pollOnce(at: time)
        #expect(queued == 1)
        if queued == 1 { #expect(try await pipeline.processNext(at: time) == .processed) }
        let coverage = try await store.coverageReport(endingAt: time)
        #expect(!coverage.isTruncated)
        #expect(coverage.unresolvedOmissions.isEmpty)
        #expect(coverage.omissions.items.count == 1 && coverage.omissions.items.first?.state == .recovered)
        #expect(coverage.activeGapEvents.isEmpty)
        #expect(coverage.gapEvents.items.count == 2)
        #expect(coverage.successfulReads.items.count == successfulReads.count)
        for (after, before) in zip(coverage.successfulReads.items, successfulReads) {
            #expect(after.scope == before.scope && after.operation == before.operation
                && after.succeededAt == before.succeededAt && after.producerVersions == before.producerVersions
                && after.readerVersion == before.readerVersion && after.hostVersion == before.hostVersion)
        }
        #expect(await store.snapshot().analysisReceipts.count == 3)
        #expect(try await store.queueStatistics().count == 0)
        try await store.close()
    }

    @Test func validAppendAfterReturnCannotLeaveItsWholeSourceWarningStale() async throws {
        let fixture = try ClaudeRestorationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (store, pipeline, monitor) = try await fixture.open()
        try await fixture.establishFailureAndHealthyProgress(store: store, pipeline: pipeline, monitor: monitor)
        try fixture.append(fixture.row(session: "affected", id: "affected-after-return"), to: fixture.affected)
        let time = fixture.now.addingTimeInterval(3)
        #expect(try await monitor.pollOnce(at: time) == 1)
        #expect(try await pipeline.processNext(at: time) == .processed)
        let snapshot = await store.snapshot()
        #expect(snapshot.analysisReceipts.count == 4)
        #expect(snapshot.sourceKinds.keys.contains { $0.session.sessionID == "affected"
            && $0.itemID == "prompt:affected-after-return:block:0" })
        let coverage = try await store.coverageReport(endingAt: time)
        #expect(!coverage.isTruncated)
        #expect(coverage.unresolvedOmissions.isEmpty)
        #expect(coverage.omissions.items.count == 1 && coverage.omissions.items.first?.state == .recovered)
        #expect(coverage.activeGapEvents.isEmpty)
        #expect(coverage.gapEvents.items.count == 2)
        #expect(try await store.queueStatistics().count == 0)
        try await store.close()
    }

    @Test(arguments: ["valid", "partialOnly", "malformedOnly", "invalidVersionOnly", "validThenMalformed", "validThenInvalidVersion",
                      "wrongSession", "conflictingSession", "identityBeyondBound"])
    func identityProofIsBoundedAndSeparateFromRowFormatCoverage(variant: String) async throws {
        let fixture = try ClaudeRestorationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try Data(contentsOf: fixture.affected)
        let malformed = try JSONSerialization.data(withJSONObject: ["type": "user", "sessionId": "affected",
            "uuid": "malformed", "version": "2.1.296", "timestamp": ISO8601DateFormatter().string(from: fixture.now),
            "message": ["content": "fake malformed row"]]) + Data([10])
        switch variant {
        case "partialOnly": try Data(original.dropLast(2)).write(to: fixture.affected)
        case "malformedOnly": try malformed.write(to: fixture.affected)
        case "validThenMalformed": try fixture.append(malformed, to: fixture.affected)
        case "validThenInvalidVersion", "invalidVersionOnly":
            var row = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
            row["version"] = String(repeating: "x", count: 257); row["uuid"] = "invalid-version"
            let bytes = try JSONSerialization.data(withJSONObject: row) + Data([10])
            if variant == "invalidVersionOnly" { try bytes.write(to: fixture.affected) }
            else { try fixture.append(bytes, to: fixture.affected) }
        case "wrongSession": try fixture.row(session: "another", id: "wrong").write(to: fixture.affected)
        case "conflictingSession": try fixture.append(fixture.row(session: "another", id: "wrong"), to: fixture.affected)
        case "identityBeyondBound":
            let control = try JSONSerialization.data(withJSONObject: ["type": "mode", "sessionId": "affected", "mode": "normal"]) + Data([10])
            try (Data((0..<64).flatMap { _ in control }) + original).write(to: fixture.affected)
        default: break
        }
        let adapter = try ClaudeAdapter(profileID: fixture.scope.profileID, agentVersion: "2.1.296",
            allowedTranscriptRoots: [fixture.sources])
        let batch = try await adapter.normalize(fixture.packet(), capturedAt: fixture.now, cryptography: fixture.crypto)
        let proofs = batch.recoveredReferences.filter { $0.constraint == .claudeSourceAvailability }
        let expected = ["valid", "validThenMalformed", "validThenInvalidVersion"].contains(variant)
        #expect(proofs.count == (expected ? 1 : 0))
        if expected {
            #expect(proofs.first?.session?.sessionID == "affected")
            #expect(proofs.first?.sourceURL == fixture.affected)
            #expect(proofs.first?.availabilityObservedAt == fixture.now)
        }
        if variant == "validThenMalformed" { #expect(batch.coverageGaps.contains { $0.reason == .malformedSource }) }
        // Per-row producer versions are retained by the typed reader. This prefix proof
        // still needs bounded identity metadata and must not treat the later row as proof.
    }

    @Test func symlinkAndWrongProfileNeverProduceAvailabilityEvidence() async throws {
        let fixture = try ClaudeRestorationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = try ClaudeAdapter(profileID: fixture.scope.profileID, agentVersion: "2.1.296",
            allowedTranscriptRoots: [fixture.sources])
        await #expect(throws: ClaudeCollectionError.wrongProfile) {
            try await adapter.normalize(fixture.packet(profile: "another-profile"), capturedAt: fixture.now,
                cryptography: fixture.crypto)
        }
        try FileManager.default.removeItem(at: fixture.affected)
        try FileManager.default.createSymbolicLink(at: fixture.affected, withDestinationURL: fixture.healthy)
        await #expect(throws: ClaudeCollectionError.awaitingTranscript) {
            try await adapter.normalize(fixture.packet(), capturedAt: fixture.now, cryptography: fixture.crypto)
        }
    }

    @Test func childAvailabilityUsesItsOwnNativeIdentityWithoutClaimingParentSession() async throws {
        let fixture = try ClaudeRestorationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let child = fixture.sources.appendingPathComponent("affected/subagents/agent-owned.jsonl")
        try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture.row(session: "distinct-native-child", id: "child-row").write(to: child)
        let adapter = try ClaudeAdapter(profileID: fixture.scope.profileID, agentVersion: "2.1.296",
            allowedTranscriptRoots: [fixture.sources])
        let packet = try CapturePacket(metadata: .init(agent: .claudeCode, interface: .t3, profileID: fixture.scope.profileID),
            eventJSON: JSONSerialization.data(withJSONObject: ["hook_event_name": "SpillcheckTranscriptPoll",
                "session_id": "affected", "transcript_path": fixture.affected.path, "agent_transcript_path": child.path]))
        let batch = try await adapter.normalize(packet, capturedAt: fixture.now, cryptography: fixture.crypto)
        #expect(batch.sources.count == 1 && batch.sources.first?.record.metadata.identity.session.sessionID == "distinct-native-child")
        let proofs = batch.recoveredReferences.filter { $0.constraint == .claudeSourceAvailability }
        #expect(proofs.count == 1 && proofs.first?.session == nil && proofs.first?.sourceURL == child)
    }

    @Test func scannerFailureCannotCommitAvailabilityRecoveryPrematurely() async throws {
        let fixture = try ClaudeRestorationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (store, pipeline, monitor) = try await fixture.open()
        try await fixture.establishFailureAndHealthyProgress(store: store, pipeline: pipeline, monitor: monitor)
        try fixture.append(fixture.row(session: "affected", id: "needs-scan-after-return"), to: fixture.affected)
        let time = fixture.now.addingTimeInterval(3)
        #expect(try await monitor.pollOnce(at: time) == 1)
        let adapter = try ClaudeAdapter(profileID: fixture.scope.profileID, agentVersion: "2.1.296",
            allowedTranscriptRoots: [fixture.sources], checkpointLookup: { try await store.checkpoint(documentID: $0) })
        let failing = DetectionPipeline(store: store, cryptography: fixture.crypto, normalizer: adapter,
            detector: ClaudeRestorationUnavailableDetector(), detectorVersion: "claude-restoration-fixture", liveSince: fixture.now)
        #expect(try await failing.processNext(at: time) == .retryScheduled)
        let coverage = try await store.coverageReport(endingAt: time)
        #expect(coverage.unresolvedOmissions.contains { $0.gap.reason == .sourceUnavailable
            && $0.gap.recovery?.sourceURL == fixture.affected })
        #expect(try await store.queueStatistics().count == 1)
        try await store.close()
    }
}
