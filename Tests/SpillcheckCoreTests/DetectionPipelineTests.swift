import Foundation
import GRDB
import Testing
@_spi(Testing) @testable import SpillcheckCore

private let pipelineValue = "SPILLCHECK_PIPELINE_SYNTHETIC_VALUE_73"
private let pipelineDetectorVersion = "fixture-detector-1"

private struct PipelineSourceSpec: Sendable {
    let session: String
    let item: String
    let type: ContentType
    let contentTime: Date
    let text: String
    let locator: SourceLocator

    init(session: String = "first-session", item: String, type: ContentType = .toolOutput,
         contentTime: Date, text: String = pipelineValue, locator: SourceLocator = .upstreamItem) {
        self.session = session
        self.item = item
        self.type = type
        self.contentTime = contentTime
        self.text = text
        self.locator = locator
    }
}

private struct PipelineCaptureID: Codable { let id: String }

private struct PipelineNormalizer: CaptureNormalizer {
    let batches: [String: [PipelineSourceSpec]]
    let checkpoints: [String: [SourceCheckpoint]]

    init(_ batches: [String: [PipelineSourceSpec]], checkpoints: [String: [SourceCheckpoint]] = [:]) {
        self.batches = batches
        self.checkpoints = checkpoints
    }

    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        let id = try JSONDecoder().decode(PipelineCaptureID.self, from: packet.eventJSON).id
        let specs = try #require(batches[id])
        var sources: [CollectedSource] = []
        for spec in specs {
            let fixture = try sourceRecord(provider: .claudeCode, session: spec.session, item: spec.item,
                contentType: spec.type, text: spec.text, contentTime: spec.contentTime)
            let metadata = try SourceRecordMetadata(identity: fixture.metadata.identity, contentType: spec.type,
                contentTime: spec.contentTime, observedAt: capturedAt, locator: spec.locator,
                origin: fixture.metadata.origin)
            let revision = try await cryptography.revision(canonicalBytes: fixture.segments[0].utf8)
            let record = try SourceRecord(metadata: metadata, revision: revision, segments: fixture.segments)
            sources.append(CollectedSource(record: record, context: RetainedSourceContext(
                sessionIdentifier: spec.session, title: "Synthetic pipeline title", projectPath: "/synthetic/pipeline")))
        }
        return CollectionBatch(sources: sources, checkpoints: checkpoints[id] ?? [])
    }
}

private actor PipelineDetector: SecretDetector {
    private var degraded = false
    private var version = pipelineDetectorVersion
    private var blockedScanNumber: Int?
    private var blocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var observed: [SourceRecordMetadata] = []

    func setDegraded(_ value: Bool) { degraded = value }
    func setVersion(_ value: String) { version = value }
    func blockNext() { blockScanNumber(observed.count + 1) }
    func blockScanNumber(_ number: Int) { blockedScanNumber = number; blocked = false }
    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }

    func scan(_ source: SourceRecord) async throws -> DetectorOutput {
        observed.append(source.metadata)
        if blockedScanNumber == observed.count {
            blockedScanNumber = nil
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                blocked = true
                for waiter in blockedWaiters { waiter.resume() }
                blockedWaiters.removeAll()
            }
        }
        let value = Data(pipelineValue.utf8)
        var findings: [DetectorFinding] = []
        for segment in source.segments {
            var cursor = 0
            while cursor < segment.utf8.count,
                  let range = segment.utf8.range(of: value, in: cursor..<segment.utf8.count) {
                let location = try CanonicalLocation(segmentID: segment.id,
                    range: UTF8Range(range.lowerBound, range.upperBound))
                findings.append(try DetectorFinding(extraction: ExactExtraction(valueUTF8: value,
                    location: location, in: source), evidence: [evidence()]))
                cursor = range.upperBound
            }
        }
        return DetectorOutput(detectorVersion: version, findings: findings, unlocated: [],
            coverageGaps: degraded ? [CoverageGap(reason: .scannerUnavailable)] : [],
            scannerFailure: degraded ? .unavailable : nil)
    }
}

private struct PipelineFixture {
    let directory: URL
    let crypto: BackgroundCryptography
    let store: ProtectedStore

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-pipeline-\(UUID())")
        crypto = try BackgroundCryptography.ephemeralForTesting()
        store = try await ProtectedStore.open(at: directory, cryptography: crypto)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@discardableResult
private func enqueuePipeline(
    _ id: String, into store: ProtectedStore, capturedAt: Date = Date(), scope: LiveCaptureScope? = nil
) async throws -> UUID {
    let packet = try CapturePacket(metadata: CaptureMetadata(agent: .claudeCode),
        eventJSON: JSONEncoder().encode(PipelineCaptureID(id: id)))
    let captureID = UUID()
    let permit = try #require(await store.processingPermit())
    #expect(try await store.enqueue(packet.body, id: captureID, capturedAt: capturedAt,
        permit: permit, at: capturedAt, scope: scope) == .inserted(captureID))
    return captureID
}

private func protectedPayloadKinds(in directory: URL) throws -> [String] {
    let database = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path)
    defer { try? database.close() }
    return try database.read { try String.fetchAll($0, sql: "SELECT kind FROM protected_payloads ORDER BY kind") }
}

private func inspectPipelineFiles(in directory: URL) throws {
    for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
        if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            #expect(try Data(contentsOf: file).range(of: Data(pipelineValue.utf8)) == nil)
        }
    }
}

@Suite("Detection pipeline with real encrypted persistence", .timeLimit(.minutes(1)))
struct DetectionPipelineTests {
    @Test func allContentTypesGroupExactValuesAlertOncePerSessionAndReplayQuietly() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.remove() }
        let now = Date()
        let sources = ContentType.allCases.map { type in
            PipelineSourceSpec(item: type.rawValue, type: type, contentTime: now,
                text: type == .toolOutput ? pipelineValue + " " + pipelineValue : pipelineValue)
        }
        let normalizer = PipelineNormalizer(["first": sources, "replay": sources,
            "new-session": [PipelineSourceSpec(session: "second-session", item: "new", contentTime: now)]])
        let detector = PipelineDetector()
        let pipeline = DetectionPipeline(store: fixture.store, cryptography: fixture.crypto,
            normalizer: normalizer, detector: detector, detectorVersion: pipelineDetectorVersion,
            liveSince: now.addingTimeInterval(-60))
        try await enqueuePipeline("first", into: fixture.store)
        #expect(try await pipeline.processNext() == .processed)
        let first = await fixture.store.snapshot()
        #expect(first.records.count == 1)
        #expect(first.occurrences.count == 6)
        #expect(Set(first.occurrences.values.map(\.source.contentType)) == Set(ContentType.allCases))
        #expect(first.alertDecisions.count == 1)
        #expect(first.analysisReceipts.count == 5)
        #expect(try await fixture.store.queueStatistics().count == 0)
        #expect(try protectedPayloadKinds(in: fixture.directory).filter { $0 == ProtectedPayloadKind.value.rawValue }.count == 1)
        let firstAlertIDs = Set(first.alertDecisions.keys)
        try await enqueuePipeline("replay", into: fixture.store)
        #expect(try await pipeline.processNext() == .processed)
        let replay = await fixture.store.snapshot()
        #expect(replay.occurrences.count == 6)
        #expect(Set(replay.alertDecisions.keys) == firstAlertIDs)
        #expect(await detector.observed.count == 5)
        try await enqueuePipeline("new-session", into: fixture.store)
        #expect(try await pipeline.processNext() == .processed)
        let second = await fixture.store.snapshot()
        #expect(second.records.count == 1)
        #expect(second.occurrences.count == 7)
        #expect(second.alertDecisions.count == 2)
        #expect(Set(second.alertDecisions.values.map(\.eligibility.session.sessionID)) == ["first-session", "second-session"])
        try inspectPipelineFiles(in: fixture.directory)
        try await fixture.store.close()
    }

    @Test func degradedScannerCommitsPartialEvidenceButRetriesWithoutAFullReceiptOrCheckpoint() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.remove() }
        let now = Date()
        let document = UUID()
        let revision = try await fixture.crypto.revision(canonicalBytes: Data(pipelineValue.utf8))
        let checkpoint = SourceCheckpoint(capabilityID: UUID(), sourceDocumentID: document, revision: revision, byteOffset: 256)
        let normalizer = PipelineNormalizer(["partial": [PipelineSourceSpec(item: "partial", contentTime: now)]],
            checkpoints: ["partial": [checkpoint]])
        let detector = PipelineDetector()
        await detector.setDegraded(true)
        let pipeline = DetectionPipeline(store: fixture.store, cryptography: fixture.crypto,
            normalizer: normalizer, detector: detector, detectorVersion: pipelineDetectorVersion,
            liveSince: now.addingTimeInterval(-60))
        try await enqueuePipeline("partial", into: fixture.store)
        #expect(try await pipeline.processNext() == .retryScheduled)
        let partial = await fixture.store.snapshot()
        #expect(partial.records.count == 1)
        #expect(partial.occurrences.count == 1)
        #expect(partial.analysisReceipts.count == 1)
        #expect(partial.analysisReceipts.allSatisfy { $0.detectorVersion == pipelineDetectorVersion + "+reduced" })
        #expect(try await fixture.store.queueStatistics().count == 1)
        #expect(try await fixture.store.coverageGaps().contains { $0.reason == .scannerUnavailable })
        #expect(try await fixture.store.checkpoint(documentID: document) == nil)
        await detector.setDegraded(false)
        #expect(try await pipeline.processNext(at: Date().addingTimeInterval(3)) == .processed)
        let complete = await fixture.store.snapshot()
        #expect(await detector.observed.count == 2)
        #expect(complete.records.count == 1)
        #expect(complete.occurrences.count == 1)
        #expect(complete.alertDecisions.count == 1)
        #expect(complete.analysisReceipts.contains { $0.detectorVersion == pipelineDetectorVersion })
        #expect(try await fixture.store.queueStatistics().count == 0)
        #expect(try await fixture.store.checkpoint(documentID: document)?.byteOffset == 256)
        try inspectPipelineFiles(in: fixture.directory)
        try await fixture.store.close()
    }

    @Test func pauseDuringScanRejectsLateInventoryReceiptAlertAndPayloadCommit() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.remove() }
        let now = Date()
        let detector = PipelineDetector()
        await detector.blockNext()
        let pipeline = DetectionPipeline(store: fixture.store, cryptography: fixture.crypto,
            normalizer: PipelineNormalizer(["blocked": [PipelineSourceSpec(item: "blocked", contentTime: now)]]),
            detector: detector, detectorVersion: pipelineDetectorVersion, liveSince: now.addingTimeInterval(-60))
        try await enqueuePipeline("blocked", into: fixture.store)
        let work = Task { try await pipeline.processNext() }
        await detector.waitUntilBlocked()
        await fixture.store.setMonitoring(enabled: false)
        await detector.release()
        #expect(try await work.value == .idle)
        let paused = await fixture.store.snapshot()
        #expect(paused.records.isEmpty)
        #expect(paused.occurrences.isEmpty)
        #expect(paused.alertDecisions.isEmpty)
        #expect(paused.analysisReceipts.isEmpty)
        #expect(try protectedPayloadKinds(in: fixture.directory).isEmpty)
        #expect(try await fixture.store.queueStatistics().count == 1)
        #expect(try await pipeline.processNext() == .idle)
        #expect(await detector.observed.count == 1)
        await fixture.store.setMonitoring(enabled: true)
        #expect(try await pipeline.processNext(at: Date().addingTimeInterval(181)) == .processed)
        #expect(await fixture.store.snapshot().occurrences.count == 1)
        #expect(try await fixture.store.queueStatistics().count == 0)
        try await fixture.store.close()
    }

    @Test func acknowledgedDeletedValueRediscoveryRemainsMetadataOnlyWithoutProtectedContent() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.remove() }
        let now = Date()
        let detector = PipelineDetector()
        let pipeline = DetectionPipeline(store: fixture.store, cryptography: fixture.crypto,
            normalizer: PipelineNormalizer([
                "original": [PipelineSourceSpec(item: "original", contentTime: now)],
                "rediscovered": [PipelineSourceSpec(session: "later-session", item: "new-appearance", contentTime: now)]
            ]), detector: detector, detectorVersion: pipelineDetectorVersion, liveSince: now.addingTimeInterval(-60))
        try await enqueuePipeline("original", into: fixture.store)
        #expect(try await pipeline.processNext() == .processed)
        let fingerprint = try await fixture.crypto.fingerprint(exactBytes: Data(pipelineValue.utf8))
        try await fixture.store.acknowledgeObsolete(fingerprint, as: .revoked, at: now)
        _ = try await fixture.store.removeContent(for: fingerprint)
        #expect(try protectedPayloadKinds(in: fixture.directory).isEmpty)
        try await enqueuePipeline("rediscovered", into: fixture.store)
        #expect(try await pipeline.processNext() == .processed)
        let rediscovered = await fixture.store.snapshot()
        #expect(rediscovered.records.count == 1)
        #expect(rediscovered.records[fingerprint]?.protectedValue == nil)
        #expect(rediscovered.occurrences.isEmpty)
        #expect(rediscovered.obsoleteMarkers.count == 1)
        #expect(rediscovered.obsoleteAppearances.count == 1)
        #expect(rediscovered.obsoleteAppearances.values.first?.source.session.sessionID == "later-session")
        #expect(rediscovered.alertDecisions.isEmpty)
        #expect(rediscovered.unlocatedResults.isEmpty)
        #expect(try protectedPayloadKinds(in: fixture.directory).isEmpty)
        #expect(try await fixture.store.queueStatistics().count == 0)
        try inspectPipelineFiles(in: fixture.directory)
        try await fixture.store.close()
    }

    @Test func acknowledgementDuringScanUsesCurrentMarkerAndCancelsPendingAlerts() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.remove() }
        let now = Date()
        let detector = PipelineDetector()
        let pipeline = DetectionPipeline(store: fixture.store, cryptography: fixture.crypto,
            normalizer: PipelineNormalizer([
                "original": [PipelineSourceSpec(item: "original", contentTime: now)],
                "pending": [PipelineSourceSpec(session: "new-session", item: "pending-appearance", contentTime: now)]
            ]), detector: detector, detectorVersion: pipelineDetectorVersion, liveSince: now.addingTimeInterval(-60))
        try await enqueuePipeline("original", into: fixture.store)
        #expect(try await pipeline.processNext() == .processed)
        let original = await fixture.store.snapshot()
        let fingerprint = try await fixture.crypto.fingerprint(exactBytes: Data(pipelineValue.utf8))
        let value = try #require(original.records[fingerprint])
        let originalAlertIDs = Set(original.alertDecisions.keys)
        #expect(originalAlertIDs.count == 1)
        await detector.blockNext()
        try await enqueuePipeline("pending", into: fixture.store)
        let work = Task { try await pipeline.processNext() }
        await detector.waitUntilBlocked()
        try await fixture.store.acknowledgeObsolete(fingerprint, as: .rotated, at: now)
        #expect(await fixture.store.pendingLiveAlerts().isEmpty)
        await detector.release()
        #expect(try await work.value == .processed)
        let completed = await fixture.store.snapshot()
        #expect(completed.records[fingerprint]?.id == value.id)
        #expect(completed.records[fingerprint]?.protectedValue == value.protectedValue)
        #expect(completed.obsoleteMarkers[fingerprint]?.acknowledgement == .rotated)
        #expect(completed.occurrences.count == 2)
        let appeared = try #require(completed.occurrences.values.first {
            $0.source.identity.session.sessionID == "new-session"
        })
        #expect(appeared.classification == .obsolete)
        #expect(appeared.protectedExcerpt != nil)
        #expect(appeared.source.protectedMetadata != nil)
        // The undelivered alert is withdrawn with its eligibility; the obsolete appearance adds none.
        #expect(completed.alertDecisions.isEmpty && completed.strongSignalReceipts.isEmpty)
        #expect(await fixture.store.pendingLiveAlerts().isEmpty)
        #expect(completed.analysisReceipts.count == 2)
        #expect(try await fixture.store.queueStatistics().count == 0)
        #expect(try protectedPayloadKinds(in: fixture.directory).filter { $0 == ProtectedPayloadKind.value.rawValue }.count == 1)
        try inspectPipelineFiles(in: fixture.directory)
        try await fixture.store.close()
        let restarted = try await ProtectedStore.open(at: fixture.directory, cryptography: fixture.crypto)
        #expect(await restarted.snapshot().obsoleteMarkers[fingerprint]?.acknowledgement == .rotated)
        #expect(await restarted.pendingLiveAlerts().isEmpty)
        try await restarted.close()
    }

    @Test func acknowledgementAndRemovalDuringScanRetryAsMetadataOnlyAfterRestart() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.remove() }
        let now = Date()
        let originalSource = PipelineSourceSpec(item: "original", contentTime: now)
        let normalizer = PipelineNormalizer([
            "original": [originalSource],
            "pending": [PipelineSourceSpec(session: "new-session", item: "pending-appearance", contentTime: now)],
            "old-replay": [originalSource]
        ])
        let detector = PipelineDetector()
        let pipeline = DetectionPipeline(store: fixture.store, cryptography: fixture.crypto,
            normalizer: normalizer, detector: detector, detectorVersion: pipelineDetectorVersion,
            liveSince: now.addingTimeInterval(-60))
        try await enqueuePipeline("original", into: fixture.store)
        #expect(try await pipeline.processNext() == .processed)
        let fingerprint = try await fixture.crypto.fingerprint(exactBytes: Data(pipelineValue.utf8))
        let original = await fixture.store.snapshot()
        let originalValue = try #require(original.records[fingerprint]?.protectedValue)
        await detector.blockNext()
        try await enqueuePipeline("pending", into: fixture.store)
        let work = Task { try await pipeline.processNext() }
        await detector.waitUntilBlocked()
        try await fixture.store.acknowledgeObsolete(fingerprint, as: .revoked, at: now)
        let removal = try await fixture.store.removeContent(for: fingerprint)
        #expect(removal.retainedObsoleteMarker?.acknowledgement == .revoked)
        #expect(try await fixture.store.payload(originalValue) == nil)
        await detector.release()
        #expect(try await work.value == .idle)
        let deleted = await fixture.store.snapshot()
        #expect(deleted.records.isEmpty)
        #expect(deleted.occurrences.isEmpty)
        #expect(deleted.obsoleteAppearances.isEmpty)
        #expect(deleted.alertDecisions.isEmpty)
        #expect(deleted.analysisReceipts == original.analysisReceipts)
        #expect(try protectedPayloadKinds(in: fixture.directory).isEmpty)
        // Its value was not yet known when deletion ran, so this new source stays in the encrypted
        // queue. A fresh permit may analyze it; the current recognition marker determines retention.
        #expect(try await fixture.store.queueStatistics().count == 1)
        try await fixture.store.close()
        let restarted = try await ProtectedStore.open(at: fixture.directory, cryptography: fixture.crypto)
        let retry = DetectionPipeline(store: restarted, cryptography: fixture.crypto,
            normalizer: normalizer, detector: detector, detectorVersion: pipelineDetectorVersion,
            liveSince: now.addingTimeInterval(-60))
        #expect(try await retry.processNext(at: Date().addingTimeInterval(181)) == .processed)
        let metadataOnly = await restarted.snapshot()
        #expect(metadataOnly.records.count == 1)
        #expect(metadataOnly.records[fingerprint]?.protectedValue == nil)
        #expect(metadataOnly.occurrences.isEmpty)
        #expect(metadataOnly.obsoleteAppearances.count == 1)
        #expect(metadataOnly.obsoleteAppearances.values.first?.source.itemID == "pending-appearance")
        #expect(metadataOnly.obsoleteMarkers[fingerprint]?.acknowledgement == .revoked)
        #expect(metadataOnly.alertDecisions.isEmpty)
        #expect(metadataOnly.analysisReceipts.count == 2)
        #expect(try protectedPayloadKinds(in: fixture.directory).isEmpty)
        #expect(try await restarted.queueStatistics().count == 0)
        let scans = await detector.observed.count
        try await enqueuePipeline("old-replay", into: restarted)
        #expect(try await retry.processNext() == .processed)
        #expect(await detector.observed.count == scans)
        #expect(await restarted.snapshot().occurrences.isEmpty)
        #expect(await restarted.snapshot().obsoleteAppearances.count == 1)
        #expect(try await restarted.payload(originalValue) == nil)
        try inspectPipelineFiles(in: fixture.directory)
        try await restarted.close()
    }

    @Test func deletionDuringReanalysisKeepsRemovedSourceDeletedAndNewAppearanceDetectable() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.remove() }
        let now = Date()
        let originalSource = PipelineSourceSpec(item: "original", contentTime: now)
        let normalizer = PipelineNormalizer([
            "original": [originalSource], "reanalysis": [originalSource], "old-replay": [originalSource],
            "new": [PipelineSourceSpec(item: "genuinely-new-appearance", contentTime: now)]
        ])
        let detector = PipelineDetector()
        let pipeline = DetectionPipeline(store: fixture.store, cryptography: fixture.crypto,
            normalizer: normalizer, detector: detector, detectorVersion: pipelineDetectorVersion,
            liveSince: now.addingTimeInterval(-60))
        try await enqueuePipeline("original", into: fixture.store)
        #expect(try await pipeline.processNext() == .processed)
        let fingerprint = try await fixture.crypto.fingerprint(exactBytes: Data(pipelineValue.utf8))
        let original = await fixture.store.snapshot()
        let oldRecord = try #require(original.records[fingerprint])
        let oldValue = try #require(oldRecord.protectedValue)
        let nextVersion = pipelineDetectorVersion + "-reevaluated"
        await detector.setVersion(nextVersion)
        let reanalysis = DetectionPipeline(store: fixture.store, cryptography: fixture.crypto,
            normalizer: normalizer, detector: detector, detectorVersion: nextVersion,
            liveSince: now.addingTimeInterval(-60))
        await detector.blockNext()
        try await enqueuePipeline("reanalysis", into: fixture.store)
        let work = Task { try await reanalysis.processNext() }
        await detector.waitUntilBlocked()
        let removal = try await fixture.store.removeContent(for: fingerprint)
        #expect(removal.retainedObsoleteMarker == nil)
        await detector.release()
        #expect(try await work.value == .idle)
        #expect(await fixture.store.snapshot().records.isEmpty)
        #expect(await fixture.store.snapshot().obsoleteMarkers.isEmpty)
        #expect(try protectedPayloadKinds(in: fixture.directory).isEmpty)
        #expect(try await fixture.store.queueStatistics().count == 1)
        #expect(try await reanalysis.processNext(at: Date().addingTimeInterval(181)) == .processed)
        let reevaluated = await fixture.store.snapshot()
        #expect(reevaluated.records.isEmpty)
        #expect(reevaluated.occurrences.isEmpty)
        #expect(reevaluated.alertDecisions.isEmpty)
        #expect(reevaluated.obsoleteMarkers.isEmpty)
        #expect(reevaluated.analysisReceipts.count == 2)
        #expect(reevaluated.analysisReceipts.contains { $0.detectorVersion == nextVersion })
        #expect(reevaluated.locationReceipts.values.allSatisfy { $0 == .removed })
        #expect(try protectedPayloadKinds(in: fixture.directory).isEmpty)
        #expect(try await fixture.store.payload(oldValue) == nil)
        try await enqueuePipeline("new", into: fixture.store)
        #expect(try await reanalysis.processNext() == .processed)
        let newlyDetected = await fixture.store.snapshot()
        let newRecord = try #require(newlyDetected.records[fingerprint])
        #expect(newRecord.id != oldRecord.id)
        #expect(newRecord.protectedValue != nil && newRecord.protectedValue != oldValue)
        #expect(newlyDetected.occurrences.count == 1)
        #expect(newlyDetected.occurrences.values.first?.source.identity.itemID == "genuinely-new-appearance")
        #expect(newlyDetected.occurrences.values.first?.classification == .ordinary)
        #expect(newlyDetected.obsoleteMarkers.isEmpty)
        #expect(newlyDetected.alertDecisions.count == 1)
        #expect(await fixture.store.pendingLiveAlerts().count == 1)
        let newAlertIDs = Set(newlyDetected.alertDecisions.keys)
        try await enqueuePipeline("old-replay", into: fixture.store)
        #expect(try await reanalysis.processNext() == .processed)
        #expect(await fixture.store.snapshot().occurrences.count == 1)
        #expect(Set(await fixture.store.snapshot().alertDecisions.keys) == newAlertIDs)
        #expect(try await fixture.store.queueStatistics().count == 0)
        try inspectPipelineFiles(in: fixture.directory)
        try await fixture.store.close()
    }

    @Test func persistedAdmissionScopeKeepsOriginalLiveContentLiveAcrossRestartAndOldRowsHistorical() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.remove() }
        let admission = Date()
        let startedAt = admission.addingTimeInterval(-60)
        let scope = try LiveCaptureScope(startedAt: startedAt, catchupReason: .resume)
        let document = UUID()
        let normalizer = PipelineNormalizer(["restart": [
            PipelineSourceSpec(session: "live-session", item: "live", contentTime: admission.addingTimeInterval(-30),
                locator: .transcript(documentID: document, recordIndex: 2)),
            PipelineSourceSpec(session: "old-session", item: "old", contentTime: admission.addingTimeInterval(-120),
                locator: .transcript(documentID: document, recordIndex: 1)),
            PipelineSourceSpec(session: "outside-lookback", item: "expired", contentTime: startedAt.addingTimeInterval(-HistoricalAuditContext.lookback - 1),
                locator: .transcript(documentID: document, recordIndex: 0))
        ]])
        _ = try await enqueuePipeline("restart", into: fixture.store, capturedAt: admission, scope: scope)
        let auditID = try #require(scope.catchupAuditID)
        try await fixture.store.close()
        let reopened = try await ProtectedStore.open(at: fixture.directory, cryptography: fixture.crypto)
        let detector = PipelineDetector()
        let pipeline = DetectionPipeline(store: reopened, cryptography: fixture.crypto, normalizer: normalizer,
            detector: detector, detectorVersion: pipelineDetectorVersion, liveSince: admission.addingTimeInterval(60))
        #expect(try await pipeline.processNext() == .processed)
        let snapshot = await reopened.snapshot()
        #expect(snapshot.records.count == 1)
        #expect(snapshot.occurrences.count == 2)
        #expect(snapshot.alertDecisions.count == 1)
        #expect(snapshot.alertDecisions.values.first?.eligibility.session.sessionID == "live-session")
        let observations = await detector.observed
        #expect(observations.count == 2)
        #expect(observations.first { $0.identity.itemID == "live" }?.origin.provenance == .live)
        let old = try #require(observations.first { $0.identity.itemID == "old" })
        guard case .historical(let audit) = old.origin.provenance else {
            Issue.record("Old transcript content was not historical")
            try await reopened.close()
            return
        }
        #expect(audit.id == auditID)
        #expect(audit.reason == .resume)
        // SQLite's Unix-epoch Double round trip can lose sub-microsecond precision.
        #expect(abs(audit.end.timeIntervalSince(startedAt)) < 0.000001)
        #expect(snapshot.strongSignalReceipts.values.contains(.historicalAudit(auditID)))
        #expect(try await reopened.queueStatistics().count == 0)
        try inspectPipelineFiles(in: fixture.directory)
        try await reopened.close()
    }

    @Test func deletionAfterFirstSourceCommitPurgesLinkedMultiSourceQueueBeforeFinalCompletion() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.remove() }
        let now = Date()
        let detector = PipelineDetector()
        await detector.blockScanNumber(2)
        let pipeline = DetectionPipeline(store: fixture.store, cryptography: fixture.crypto,
            normalizer: PipelineNormalizer(["mixed": [
                PipelineSourceSpec(item: "first-committed", contentTime: now),
                PipelineSourceSpec(item: "second-pending", contentTime: now, text: "ordinary pending source content")
            ]]), detector: detector, detectorVersion: pipelineDetectorVersion, liveSince: now.addingTimeInterval(-60))
        let captureID = try await enqueuePipeline("mixed", into: fixture.store)
        let work = Task { try await pipeline.processNext() }
        await detector.waitUntilBlocked()
        #expect(await fixture.store.snapshot().occurrences.count == 1)
        #expect(try await fixture.store.queueStatistics().count == 1)
        let fingerprint = try await fixture.crypto.fingerprint(exactBytes: Data(pipelineValue.utf8))
        _ = try await fixture.store.removeContent(for: fingerprint)
        #expect(try await fixture.store.queueStatistics().count == 0)
        #expect(try await fixture.store.coverageGaps().contains { $0.reason == .captureRejected })
        await detector.release()
        #expect(try await work.value == .idle)
        let removed = await fixture.store.snapshot()
        #expect(removed.records.isEmpty)
        #expect(removed.alertDecisions.isEmpty)
        #expect(removed.analysisReceipts.count == 1)
        #expect(removed.analysisReceipts.first?.source.itemID == "first-committed")
        let packet = try CapturePacket(metadata: CaptureMetadata(agent: .claudeCode),
            eventJSON: JSONEncoder().encode(PipelineCaptureID(id: "mixed")))
        let permit = try #require(await fixture.store.processingPermit())
        #expect(try await fixture.store.enqueue(packet.body, id: captureID, capturedAt: now,
            permit: permit) == .alreadyProcessed(captureID))
        try await fixture.store.close()
    }

    @Test func contentBeyondTheAnalysisHorizonIsNeverScannedOrReceipted() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.remove() }
        let now = Date()
        let detector = PipelineDetector()
        let stale = now.addingTimeInterval(-HistoricalAuditContext.analysisHorizon - 60)
        let pipeline = DetectionPipeline(store: fixture.store, cryptography: fixture.crypto,
            normalizer: PipelineNormalizer(["stale": [PipelineSourceSpec(item: "stale", contentTime: stale)]]),
            detector: detector, detectorVersion: pipelineDetectorVersion, liveSince: now.addingTimeInterval(-60))
        try await enqueuePipeline("stale", into: fixture.store)
        #expect(try await pipeline.processNext() == .processed)
        #expect(await detector.observed.isEmpty)
        let snapshot = await fixture.store.snapshot()
        #expect(snapshot.analysisReceipts.isEmpty && snapshot.records.isEmpty)
        #expect(try await fixture.store.queueStatistics().count == 0)
        try await fixture.store.close()
    }

    @Test func retainedExcerptMasksOtherDetectedValuesButKeepsItsOwn() throws {
        let text = "user=OTHER_VALUE_1 key=OWN_VALUE_2 tail"
        let source = try sourceRecord(text: text)
        func range(_ needle: String) throws -> ComponentRange {
            let bytes = Data(text.utf8), found = try #require(bytes.range(of: Data(needle.utf8)))
            return try ComponentRange(segmentID: "text", range: UTF8Range(found.lowerBound, found.upperBound))
        }
        let own = try CanonicalLocation(components: [range("OWN_VALUE_2")])
        let masked = DetectionPipeline.excerpt(around: own, in: source, masking: [try range("OTHER_VALUE_1")])
        #expect(masked.text == "user=[other detected value] key=OWN_VALUE_2 tail")
        // An overlapping detection is hidden only outside this occurrence's own bytes.
        let covering = try ComponentRange(segmentID: "text", range: UTF8Range(5, try range("OWN_VALUE_2").range.upperBound))
        let overlapped = DetectionPipeline.excerpt(around: own, in: source, masking: [covering])
        #expect(overlapped.text == "user=[other detected value]OWN_VALUE_2 tail")
        #expect(DetectionPipeline.excerpt(around: own, in: source).text == text)
    }
}
