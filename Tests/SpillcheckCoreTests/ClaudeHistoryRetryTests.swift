import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private struct ClaudeHistoryRetryDetector: SecretDetector {
    func scan(_ source: SourceRecord) async throws -> DetectorOutput {
        .init(detectorVersion: "claude-history-retry-fixture", findings: [], unlocated: [])
    }
}

@Suite("Claude profile history recovery")
struct ClaudeHistoryRetryTests {
    @Test(arguments: [1, 2])
    func denseHistoryCommitsEachSliceInsteadOfRetryingAnOversizedRecoveryBatch(fileCount: Int) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spillcheck-claude-dense-history-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let sources = claudeConfiguredURL(sourceDirectory)
        let control = Data("{\"type\":\"mode\",\"mode\":\"normal\",\"sessionId\":\"session\"}\n".utf8)
        let totalRows = 4097
        let files = (0..<fileCount).map { sources.appendingPathComponent("controls-\($0).jsonl") }
        for (index, file) in files.enumerated() {
            let count = totalRows / fileCount + (index < totalRows % fileCount ? 1 : 0)
            try Data(Array(repeating: control, count: count).joined()).write(to: file)
        }
        let now = Date(timeIntervalSince1970: 1_791_900_000)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: root.appendingPathComponent("store"), cryptography: crypto)
        let adapter = try ClaudeAdapter(profileID: "dense-fixture", agentVersion: "2.1.296",
            allowedTranscriptRoots: [sources], checkpointLookup: { try await store.checkpoint(documentID: $0) })
        let audit = try HistoricalAuditContext(reason: .resume, endingAt: now)
        let packet = try await adapter.initialHistoricalCapture(audit: audit)
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, historicalAudit: audit)
        let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
            detector: ClaudeHistoryRetryDetector(), detectorVersion: "claude-history-retry-fixture", liveSince: now)
        let first = try await pipeline.processNext(at: now)
        #expect(first == .processed)
        guard first == .processed else { try await store.close(); return }
        let firstProgress = try #require(try await store.historicalProgress().first)
        #expect(firstProgress.progress.hasUnreadContent && firstProgress.continuationQueued == true)
        var progressed = false
        for file in files {
            let key = try await adapter.checkpointIdentity(path: file.path, provenance: .historical(audit), cryptography: crypto)
            if let saved = try await store.checkpoint(documentID: key), saved.byteOffset > 0 { progressed = true }
        }
        #expect(progressed)
        for _ in 0..<4 {
            if try await store.queueStatistics().count == 0 { break }
            #expect(try await pipeline.processNext(at: now) == .processed)
        }
        #expect(try await store.queueStatistics().count == 0)
        let final = try #require(try await store.historicalProgress().first)
        #expect(!final.progress.hasUnreadContent && final.continuationQueued == false && final.completedAt != nil)
        for file in files {
            let key = try await adapter.checkpointIdentity(path: file.path, provenance: .historical(audit), cryptography: crypto)
            #expect(try await store.checkpoint(documentID: key)?.byteOffset == UInt64(Data(contentsOf: file).count))
        }
        try await store.close()
    }

    @Test func profileRetryAfterParserUpgradeRecoversConsumedPermissionControls() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spillcheck-claude-history-retry-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = claudeConfiguredURL(sources).appendingPathComponent("controls.jsonl")
        let control = try JSONSerialization.data(withJSONObject: ["type": "permission-mode",
            "permissionMode": "dontAsk", "sessionId": "session"], options: [.sortedKeys]) + Data([10])
        try (control + control + control).write(to: file)
        let now = Date(timeIntervalSince1970: 1_791_900_000)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: root.appendingPathComponent("store"), cryptography: crypto)
        let scope = CollectionScope(provider: .claudeCode, profileID: "retry-fixture",
            interface: .standaloneCLI, path: .versionedTranscript)
        let route = CollectionCaptureRoute(scope: scope, readerVersion: "2.1.296")
        let adapter = try ClaudeAdapter(profileID: scope.profileID, agentVersion: "2.1.296",
            allowedTranscriptRoots: [sources], checkpointLookup: { try await store.checkpoint(documentID: $0) })
        let firstAudit = try HistoricalAuditContext(reason: .resume, endingAt: now)
        let consumed = try await adapter.readIncremental(path: file.path, interface: scope.interface,
            observedAt: now, provenance: .historical(firstAudit), cryptography: crypto)
        let checkpoint = try #require(consumed.batch.checkpoints.first)
        var cursor = try JSONDecoder().decode(ClaudeReadCursor.self, from: #require(checkpoint.adapterState))
        cursor.parserContract = "claude-transcript-10"
        let oldState = try JSONEncoder().encode(cursor)
        let session = try SessionIdentity(provider: .claudeCode, profileID: scope.profileID, sessionID: "session")
        let oldGaps = (0..<3).map { index in
            CoverageGap(reason: .unsupportedContent, capabilityID: checkpoint.capabilityID,
                scope: scope, operation: .liveRead,
                recovery: .init(session: session,
                    locator: .transcriptByteOffset(documentID: checkpoint.capabilityID,
                        byteOffset: UInt64(index * control.count)),
                    parserContract: "claude-transcript-10", sourceURL: file),
                sourceKind: .claudeUnknownRecord, diagnosticCode: .unknownRecordKind, observedAt: now)
        }
        let old = SourceCheckpoint(capabilityID: checkpoint.capabilityID, sourceDocumentID: checkpoint.sourceDocumentID,
            revision: try await crypto.revision(canonicalBytes: oldState), byteOffset: checkpoint.byteOffset,
            lastContentTime: nil, gaps: oldGaps, adapterState: oldState)
        let permit = try #require(await store.processingPermit())
        let firstPacket = try await adapter.initialHistoricalCapture(audit: firstAudit)
        let firstContext = try route.context(for: firstPacket, trigger: .historyRequest, audit: firstAudit)
        _ = try await store.enqueue(firstPacket.body, capturedAt: now, permit: permit, at: now,
            historicalAudit: firstAudit, workContext: firstContext)
        let firstCapture = try #require(try await store.nextPending(at: now, permit: permit))
        try await store.completeCapture(firstCapture, checkpoints: [old],
            historicalProgress: .init(audit: firstAudit, bytesRead: control.count * 3, hasUnreadContent: true),
            permit: permit, at: now)
        for gap in oldGaps { try await store.recordCoverageGap(gap, at: now) }
        #expect(try await store.coverageOmissions().filter(\.isUnresolved).count == 3)

        // A profile retry starts discovery with its persisted checkpoint, as the app does.
        // No transcript rewrite or per-source restart is available to force a reread.
        let retryAt = now.addingTimeInterval(60)
        let retryAudit = try HistoricalAuditContext(reason: .resume, endingAt: retryAt)
        let retryPacket = try await adapter.initialHistoricalCapture(audit: retryAudit)
        let retryContext = try route.context(for: retryPacket, trigger: .historyRequest, audit: retryAudit)
        _ = try await store.enqueue(retryPacket.body, capturedAt: retryAt, permit: permit, at: retryAt,
            historicalAudit: retryAudit, workContext: retryContext)
        let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
            detector: ClaudeHistoryRetryDetector(), detectorVersion: "claude-history-retry-fixture", liveSince: now)
        #expect(try await pipeline.processNext(at: retryAt) == .processed)
        let report = try await store.coverageReport(endingAt: retryAt)
        #expect(report.unresolvedOmissions.isEmpty)
        #expect(report.omissions.items.count == 3 && report.omissions.items.allSatisfy { $0.state == .recovered })
        let progress = try #require(report.history.items.first { $0.progress.audit.id == retryAudit.id })
        #expect(progress.progress.bytesRead > 0)
        #expect(!progress.progress.hasUnreadContent && progress.continuationQueued == false && progress.completedAt != nil)
        #expect(report.successfulReads.items.contains { $0.scope == scope && $0.operation == .historicalRead })
        #expect(await store.snapshot().analysisReceipts.isEmpty)
        #expect(try await store.queueStatistics().count == 0)
        #expect(try Data(contentsOf: file) == control + control + control)
        try await store.close()
    }
}
