import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private let presentationDetectorVersion = "presentation-fixture-full-v1"
private let presentationValue = "SPILLCHECK_FAKE_PRESENTATION_ORIGINAL_42"

private struct PresentationNormalizer: CaptureNormalizer {
    let batch: CollectionBatch
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) async throws -> CollectionBatch { batch }
}

private actor PresentationDetector: SecretDetector {
    enum Mode: Sendable { case full, partial, reduced, wrongVersion }
    let mode: Mode
    private(set) var calls = 0
    init(_ mode: Mode = .full) { self.mode = mode }
    func scan(_ source: SourceRecord) throws -> DetectorOutput {
        calls += 1
        var findings: [DetectorFinding] = []
        for segment in source.segments {
            if let range = segment.utf8.range(of: Data(presentationValue.utf8)) {
                let location = try CanonicalLocation(segmentID: segment.id,
                    range: .init(range.lowerBound, range.upperBound))
                findings.append(try .init(extraction: .init(valueUTF8: Data(presentationValue.utf8),
                    location: location, in: source), evidence: [evidence()]))
            }
        }
        return .init(detectorVersion: mode == .wrongVersion ? "old-detector" : presentationDetectorVersion,
            findings: findings, unlocated: [],
            coverageGaps: mode == .partial || mode == .reduced ? [.init(reason: .scannerUnavailable)] : [],
            scannerFailure: mode == .reduced ? .unavailable : nil)
    }
}

private struct PresentationFixture {
    let directory: URL
    let crypto: BackgroundCryptography
    let store: ProtectedStore
    let now: Date
    let source: SourceRecord
    let originalPacket: CapturePacket
    let scope = CollectionScope(provider: .codex, profileID: "fixture-profile",
        interface: .standaloneCLI, path: .publicHistory)

    init(contentAge: TimeInterval = 30, provenance: SourceProvenance = .live) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-presentation-\(UUID())")
        now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        crypto = try BackgroundCryptography.ephemeralForTesting()
        store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        originalPacket = try .init(metadata: .init(agent: .codex, profileID: "fixture-profile"),
            eventJSON: Data("{\"session_id\":\"session-1\"}".utf8))
        let raw = try sourceRecord(item: "original", contentType: .intermediateResponse,
            text: presentationValue, provenance: provenance, contentTime: now.addingTimeInterval(-contentAge))
        source = try .init(metadata: raw.metadata,
            revision: await crypto.revision(canonicalBytes: Data(presentationValue.utf8)), segments: raw.segments)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func gap(_ item: String = "presentation", contract: String = "current-parser",
             operation: CollectionOperation = .historicalRead) -> CoverageGap {
        .init(reason: .unsupportedContent, scope: scope, contentType: .intermediateResponse, operation: operation,
            recovery: .init(session: source.metadata.identity.session, locator: .upstreamItem, itemID: item,
                contentTime: source.metadata.contentTime, parserContract: contract),
            isRequiredFormatFailure: true, sourceKind: .codexUnknownItem, diagnosticCode: .unknownRecordKind)
    }
    func batch(source selectedSource: SourceRecord? = nil, includeSource: Bool = true,
               gap selectedGap: CoverageGap? = nil, additionalGaps: [CoverageGap] = [],
               dependencyMetadata: SourceRecordMetadata? = nil, dependencyRevision: ContentRevision? = nil,
               audit: HistoricalAuditContext, dependencies: Bool = true, includeProgress: Bool = true,
               continuation: CapturePacket? = nil, unresolvedRecoveryContinuation: CapturePacket? = nil,
               hasUnreadContent: Bool = false) -> CollectionBatch {
        let original = selectedSource ?? source
        let provisional = selectedGap ?? gap()
        return .init(sources: includeSource ? [.init(record: original)] : [],
            coverageGaps: [provisional] + additionalGaps,
            continuation: continuation, unresolvedRecoveryContinuation: unresolvedRecoveryContinuation,
            historicalProgress: includeProgress ? .init(audit: audit, bytesRead: presentationValue.utf8.count,
                hasUnreadContent: hasUnreadContent) : nil,
            pendingRecoveryDependencies: dependencies ? [.init(provisionalGap: provisional,
                originalMetadata: dependencyMetadata ?? original.metadata,
                originalRevision: dependencyRevision ?? original.revision)] : [], observedRead: true)
    }
    func packet(partial: Bool? = nil, metadata: CaptureMetadata? = nil) throws -> CapturePacket {
        if partial == nil && metadata == nil { return originalPacket }
        let json = partial.map { "{\"session_id\":\"session-1\",\"partial\":\($0)}" }
            ?? "{\"session_id\":\"session-1\"}"
        let selectedMetadata = try metadata ?? CaptureMetadata(agent: .codex, profileID: scope.profileID)
        return try .init(metadata: selectedMetadata, eventJSON: Data(json.utf8))
    }
    func queued(in target: ProtectedStore) async throws -> (PendingCapture, OpenedCapture) {
        #expect(try await target.queueStatistics().count == 1)
        let permit = try #require(await target.processingPermit())
        let capture = try #require(try await target.nextPending(at: now.addingTimeInterval(60), permit: permit))
        return (capture, try await target.openCapturedWork(capture))
    }
    @discardableResult
    func process(_ batch: CollectionBatch, detector: PresentationDetector = .init(),
                 audit: HistoricalAuditContext?, store selectedStore: ProtectedStore? = nil,
                 liveSince: Date? = nil, includeContext: Bool = true,
                 expectFailedAttemptOnly: Bool = false) async throws -> PipelineOutcome {
        let target = selectedStore ?? store
        let packet = try self.packet()
        let context = try CollectionCaptureRoute(scope: scope).context(for: packet,
            trigger: audit == nil ? .activePoll : .historyRequest, audit: audit)
        let permit = try #require(await target.processingPermit())
        _ = try await target.enqueue(packet.body, capturedAt: now, permit: permit, at: now,
            scope: .init(startedAt: liveSince ?? now), historicalAudit: audit,
            workContext: includeContext ? context : nil)
        let admittedProgress = try await target.historicalProgress()
        let admittedCaptures = try await target.captureIdentitiesForTesting()
        let pipeline = DetectionPipeline(store: target, cryptography: crypto,
            normalizer: PresentationNormalizer(batch: batch), detector: detector,
            detectorVersion: presentationDetectorVersion, liveSince: liveSince ?? now)
        let attemptStarted = Date()
        let outcome = try await pipeline.processNext(at: now)
        let attemptFinished = Date()
        if expectFailedAttemptOnly {
            #expect(admittedProgress.isEmpty)
            let expectedAudit = try #require(audit)
            let failedProgress = try await target.historicalProgress()
            #expect(failedProgress.count == 1)
            let failed = try #require(failedProgress.first)
            let attemptedAt = try #require(failed.lastAttemptedAt)
            // retry() records a failed attempt even though completeCapture() never ran.
            // None of this rejected batch's measured bytes or completion may be certified.
            #expect(failed == StoredHistoricalProgress(provider: .codex, profileID: scope.profileID,
                progress: .init(audit: expectedAudit, bytesRead: 0, hasUnreadContent: true),
                lastAttemptedAt: attemptedAt, completedAt: nil, continuationQueued: true))
            #expect(attemptedAt >= attemptStarted && attemptedAt <= attemptFinished)
            let afterCaptures = try await target.captureIdentitiesForTesting()
            #expect(afterCaptures.pending == admittedCaptures.pending && afterCaptures.consumed == admittedCaptures.consumed)
        }
        return outcome
    }
}

@Suite("Receipt-gated presentation recovery", .timeLimit(.minutes(1)))
struct PresentationRecoveryPipelineTests {
    @Test func fullOriginalScanSettlesOnlyExactPresentationAndColdReplayDoesNotRescan() async throws {
        let fixture = try await PresentationFixture()
        defer { fixture.remove() }
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixture.now)
        let old = fixture.gap(contract: "old-parser")
        let unrelated = fixture.gap("unrelated")
        try await fixture.store.recordCoverageGap(old, at: fixture.now)
        try await fixture.store.recordCoverageGap(unrelated, at: fixture.now)
        let detector = PresentationDetector()
        let batch = fixture.batch(audit: audit)
        #expect(try await fixture.process(batch, detector: detector, audit: audit) == .processed)
        let initial = await fixture.store.snapshot()
        #expect(initial.occurrences.count == 1 && initial.analysisReceipts.count == 1)
        #expect(initial.analysisReceipts.first?.source == fixture.source.metadata.identity)
        #expect(try await fixture.store.coverageOmissions().map { $0.gap.recovery?.itemID } == ["unrelated"])
        #expect(try await fixture.store.coverageOmissions(includeRecovered: true).contains {
            $0.gap.recovery?.itemID == "presentation" && $0.state == .recovered
        })
        // An unrelated stored omission does not prevent this exact read from completing.
        #expect(try await fixture.store.historicalProgress().first?.progress.hasUnreadContent == false)
        try await fixture.store.close()
        let reopened = try await ProtectedStore.open(at: fixture.directory, cryptography: fixture.crypto)
        #expect(try await fixture.process(batch, detector: detector, audit: audit, store: reopened) == .processed)
        let replay = await reopened.snapshot()
        #expect(replay.occurrences == initial.occurrences)
        #expect(replay.analysisReceipts == initial.analysisReceipts)
        #expect(await detector.calls == 1)
        #expect(try await reopened.coverageOmissions().map { $0.gap.recovery?.itemID } == ["unrelated"])
        try await reopened.close()
    }

    @Test func partialReducedAndWrongDetectorCannotSettleOrCompleteHistoricalRead() async throws {
        for mode in [PresentationDetector.Mode.partial, .reduced, .wrongVersion] {
            let fixture = try await PresentationFixture()
            defer { fixture.remove() }
            let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixture.now)
            try await fixture.store.recordCoverageGap(fixture.gap(contract: "old-parser"), at: fixture.now)
            let result = try await fixture.process(fixture.batch(audit: audit), detector: .init(mode), audit: audit)
            #expect(result == (mode == .reduced ? .retryScheduled : .processed))
            #expect(try await fixture.store.coverageOmissions().contains { $0.gap.recovery?.itemID == "presentation" })
            let receipts = await fixture.store.snapshot().analysisReceipts
            #expect(receipts.count == 1 && receipts.allSatisfy { $0.detectorVersion != presentationDetectorVersion })
            if mode != .reduced {
                #expect(try await fixture.store.historicalProgress().first?.progress.hasUnreadContent == true)
                #expect(try await fixture.store.historicalProgress().first?.completedAt == nil)
            }
            try await fixture.store.close()
        }
    }

    @Test func existingReceiptNeedsFreshExactOriginalAndScope() async throws {
        let fixture = try await PresentationFixture()
        defer { fixture.remove() }
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixture.now)
        let detector = PresentationDetector()
        #expect(try await fixture.process(.init(sources: [.init(record: fixture.source)]),
            detector: detector, audit: audit) == .processed)
        let different = try ContentRevision(keyedDigest: Data(repeating: 0x5a, count: 32))
        let changedMetadata = try SourceRecordMetadata(identity: fixture.source.metadata.identity,
            contentType: .finalResponse, contentTime: fixture.source.metadata.contentTime,
            observedAt: fixture.source.metadata.observedAt, origin: fixture.source.metadata.origin)
        let badCases = [fixture.batch(includeSource: false, audit: audit),
            fixture.batch(dependencyRevision: different, audit: audit),
            fixture.batch(dependencyMetadata: changedMetadata, audit: audit)]
        for batch in badCases {
            #expect(try await fixture.process(batch, detector: detector, audit: audit) == .processed)
            #expect(try await fixture.store.coverageOmissions().contains { $0.gap.recovery?.itemID == "presentation" })
            #expect(try await fixture.store.historicalProgress().first?.progress.hasUnreadContent == true)
        }
        #expect(try await fixture.process(fixture.batch(audit: audit), detector: detector,
            audit: audit, includeContext: false) == .processed)
        #expect(try await fixture.store.coverageOmissions().contains { $0.gap.recovery?.itemID == "presentation" })
        #expect(await detector.calls == 1)
        try await fixture.store.close()
    }

    @Test func excludedOrRequiredOriginalGapBlocksDependencyDespiteFullReceipt() async throws {
        for excluded in [false, true] {
            let fixture = try await PresentationFixture()
            defer { fixture.remove() }
            let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixture.now)
            let originalGap = CoverageGap(reason: .unsupportedContent, scope: fixture.scope,
                recovery: .init(session: fixture.source.metadata.identity.session, locator: .upstreamItem,
                    itemID: fixture.source.metadata.identity.itemID, contentTime: fixture.source.metadata.contentTime,
                    parserContract: "current-parser"), excludedContent: excluded)
            #expect(try await fixture.process(fixture.batch(additionalGaps: [originalGap], audit: audit), audit: audit) == .processed)
            #expect(await fixture.store.snapshot().analysisReceipts.count == 1)
            #expect(try await fixture.store.coverageOmissions().contains { $0.gap.recovery?.itemID == "presentation" })
            #expect(try await fixture.store.historicalProgress().first?.progress.hasUnreadContent == true)
            try await fixture.store.close()
        }
    }

    @Test func expiredOutOfAuditAndFutureSourcesCannotRecoverEvenWithExistingFullReceipt() async throws {
        for age in [HistoricalAuditContext.analysisHorizon + 1, HistoricalAuditContext.lookback + 1, -1] {
            let fixture = try await PresentationFixture(contentAge: age)
            defer { fixture.remove() }
            // Retain a full receipt from outside the current admitted processing window.
            let analysis = try SourceAnalysis(source: fixture.source, detectorVersion: presentationDetectorVersion,
                detections: [])
            let permit = try #require(await fixture.store.processingPermit())
            _ = try await fixture.store.commit(analysis, payloads: [], permit: permit)
            #expect(await fixture.store.snapshot().analysisReceipts.count == 1)
            let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixture.now)
            let detector = PresentationDetector()
            #expect(try await fixture.process(fixture.batch(audit: audit), detector: detector, audit: audit) == .processed)
            #expect(await detector.calls == 0)
            #expect(try await fixture.store.coverageOmissions().contains { $0.gap.recovery?.itemID == "presentation" })
            #expect(try await fixture.store.historicalProgress().first?.progress.hasUnreadContent == true)
            try await fixture.store.close()
        }
    }

    @Test func liveCatchupUsesCaptureAuditInsteadOfSuppliedHistoricalProvenance() async throws {
        let oldAudit = try HistoricalAuditContext(reason: .firstLaunch,
            endingAt: Date().addingTimeInterval(-2 * HistoricalAuditContext.lookback))
        let fixture = try await PresentationFixture(provenance: .historical(oldAudit))
        defer { fixture.remove() }
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixture.now)
        let gap = fixture.gap(operation: .liveRead)
        #expect(try await fixture.process(fixture.batch(gap: gap, audit: audit, includeProgress: false), audit: nil) == .processed)
        #expect(try await fixture.store.coverageOmissions().isEmpty)
        #expect(await fixture.store.snapshot().analysisReceipts.count == 1)
        try await fixture.store.close()
    }

    @Test func oneDependencyCannotRemoveDifferentGapAtSamePresentationLocation() async throws {
        let fixture = try await PresentationFixture()
        defer { fixture.remove() }
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixture.now)
        let provisional = fixture.gap()
        let other = CoverageGap(reason: .malformedSource, scope: fixture.scope,
            operation: .historicalRead, recovery: provisional.recovery,
            isRequiredFormatFailure: true, diagnosticCode: .invalidFieldType)
        #expect(try await fixture.process(fixture.batch(additionalGaps: [other], audit: audit), audit: audit) == .processed)
        let unresolved = try await fixture.store.coverageOmissions()
        #expect(unresolved.contains { $0.gap.reason == .malformedSource })
        #expect(!unresolved.contains { $0.gap.reason == .unsupportedContent })
        try await fixture.store.close()
    }

    @Test func conflictingDependenciesNeverSettle() async throws {
        for implicit in [false, true] {
            let fixture = try await PresentationFixture()
            defer { fixture.remove() }
            let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixture.now)
            let batch = fixture.batch(audit: audit)
            let provisional = fixture.gap()
            let implicitContext = CoverageGap(reason: provisional.reason, contentType: provisional.contentType,
                recovery: provisional.recovery, isRequiredFormatFailure: provisional.isRequiredFormatFailure,
                sourceKind: provisional.sourceKind, diagnosticCode: provisional.diagnosticCode)
            let conflictGap = implicit ? implicitContext : provisional
            let conflict = CoverageRecoveryDependency(provisionalGap: conflictGap,
                originalMetadata: fixture.source.metadata,
                originalRevision: try .init(keyedDigest: Data(repeating: 0x71, count: 32)))
            let changed = CollectionBatch(sources: batch.sources,
                coverageGaps: batch.coverageGaps + (implicit ? [implicitContext] : []),
                historicalProgress: batch.historicalProgress,
                pendingRecoveryDependencies: batch.pendingRecoveryDependencies + [conflict],
                observedRead: true)
            #expect(try await fixture.process(changed, audit: audit) == .processed)
            #expect(await fixture.store.snapshot().analysisReceipts.count == 1)
            #expect(try await fixture.store.coverageOmissions().contains { $0.gap.recovery?.itemID == "presentation" })
            #expect(try await fixture.store.historicalProgress().first?.progress.hasUnreadContent == true)
            try await fixture.store.close()
        }
    }

    @Test func foreignProfileAndHostCannotUseCaptureScopeForRecovery() async throws {
        for foreignProfile in [false, true] {
            let fixture = try await PresentationFixture()
            defer { fixture.remove() }
            let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixture.now)
            let raw = try sourceRecord(profile: foreignProfile ? "foreign-profile" : fixture.scope.profileID,
                item: "original", contentType: .intermediateResponse, text: presentationValue,
                interface: foreignProfile ? .standaloneCLI : .desktopCode,
                contentTime: fixture.source.metadata.contentTime)
            let source = try SourceRecord(metadata: raw.metadata, revision: fixture.source.revision, segments: raw.segments)
            let permit = try #require(await fixture.store.processingPermit())
            _ = try await fixture.store.commit(SourceAnalysis(source: source,
                detectorVersion: presentationDetectorVersion, detections: []), payloads: [], permit: permit)
            let gap = fixture.gap()
            #expect(try await fixture.process(fixture.batch(source: source, gap: gap, audit: audit), audit: audit) == .processed)
            #expect(try await fixture.store.coverageOmissions().contains { $0.gap.recovery?.itemID == "presentation" })
            #expect(try await fixture.store.historicalProgress().first?.progress.hasUnreadContent == true)
            try await fixture.store.close()
        }
    }

    @Test func ordinaryReferenceCannotBypassMissingProvisionalGapButUnrelatedRecoveryStillWorks() async throws {
        let fixture = try await PresentationFixture()
        defer { fixture.remove() }
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixture.now)
        let provisional = fixture.gap()
        let unrelated = fixture.gap("unrelated")
        try await fixture.store.recordCoverageGap(fixture.gap(contract: "old-parser"), at: fixture.now)
        try await fixture.store.recordCoverageGap(unrelated, at: fixture.now)
        let references = [try #require(provisional.recovery), try #require(unrelated.recovery)]
        let malformed = CollectionBatch(sources: [.init(record: fixture.source)],
            historicalProgress: .init(audit: audit, bytesRead: presentationValue.utf8.count, hasUnreadContent: false),
            recoveredReferences: references,
            pendingRecoveryDependencies: [.init(provisionalGap: provisional,
                originalMetadata: fixture.source.metadata, originalRevision: fixture.source.revision)], observedRead: true)
        #expect(try await fixture.process(malformed, audit: audit) == .processed)
        #expect(await fixture.store.snapshot().analysisReceipts.count == 1)
        #expect(try await fixture.store.coverageOmissions().map { $0.gap.recovery?.itemID } == ["presentation"])
        #expect(try await fixture.store.coverageOmissions(includeRecovered: true).contains {
            $0.gap.recovery?.itemID == "unrelated" && $0.state == .recovered
        })
        #expect(try await fixture.store.historicalProgress().first?.progress.hasUnreadContent == true)
        try await fixture.store.close()
    }

    @Test func fullReceiptSelectsSuccessContinuationAndPreservesPriorPartialAcrossRestart() async throws {
        for priorPartial in [false, true] {
            let fixture = try await PresentationFixture()
            defer { fixture.remove() }
            let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixture.now)
            let success = try fixture.packet(partial: priorPartial)
            // An unrelated earlier gap can make both branches legitimately identical.
            let failure = try priorPartial ? success : fixture.packet(partial: true)
            let base = fixture.batch(audit: audit, continuation: success,
                unresolvedRecoveryContinuation: failure, hasUnreadContent: priorPartial)
            // Exercise the single-checkpoint initializer's forwarding contract as well.
            let batch = CollectionBatch(sources: base.sources, coverageGaps: base.coverageGaps, checkpoint: nil,
                continuation: success, unresolvedRecoveryContinuation: failure,
                historicalProgress: base.historicalProgress,
                pendingRecoveryDependencies: base.pendingRecoveryDependencies, observedRead: true)
            #expect(try await fixture.process(batch, audit: audit) == .processed)
            let initial = await fixture.store.snapshot()
            #expect(initial.analysisReceipts.count == 1 && initial.occurrences.count == 1)
            #expect(try await fixture.store.coverageOmissions().isEmpty)
            #expect(try await fixture.store.historicalProgress().first?.progress.hasUnreadContent == priorPartial)
            #expect(try await fixture.store.coverageReport(endingAt: fixture.now).successfulReads.totalCount == 1)
            try await fixture.store.close()
            let reopened = try await ProtectedStore.open(at: fixture.directory, cryptography: fixture.crypto)
            let (capture, opened) = try await fixture.queued(in: reopened)
            #expect(capture.retryCount == 0 && opened.body == success.body)
            #expect(opened.historicalAudit == audit && opened.scope?.startedAt == fixture.now)
            #expect(await reopened.snapshot().analysisReceipts == initial.analysisReceipts)
            #expect(try await reopened.historicalProgress().first?.progress.hasUnreadContent == priorPartial)
            try await reopened.close()
        }
    }

    @Test func deniedOriginalReceiptSelectsFailureContinuationAndCannotRecordSuccess() async throws {
        for variant in 0...3 {
            let fixture = try await PresentationFixture()
            defer { fixture.remove() }
            let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixture.now)
            let success = try fixture.packet(partial: false)
            let failure = try fixture.packet(partial: true)
            let detector = PresentationDetector(variant == 1 ? .partial : variant == 2 ? .wrongVersion : .full)
            let batch = fixture.batch(includeSource: variant != 0, audit: audit,
                continuation: success, unresolvedRecoveryContinuation: failure)
            #expect(try await fixture.process(batch, detector: detector, audit: audit,
                includeContext: variant != 3) == .processed)
            #expect(try await fixture.store.coverageOmissions().contains { $0.gap.recovery?.itemID == "presentation" })
            #expect(try await fixture.store.historicalProgress().first?.progress.hasUnreadContent == true)
            #expect(try await fixture.store.historicalProgress().first?.completedAt == nil)
            #expect(try await fixture.store.coverageReport(endingAt: fixture.now).successfulReads.totalCount == 0)
            try await fixture.store.close()
            let reopened = try await ProtectedStore.open(at: fixture.directory, cryptography: fixture.crypto)
            let (capture, opened) = try await fixture.queued(in: reopened)
            #expect(capture.retryCount == 0 && opened.body == failure.body)
            #expect(opened.historicalAudit == audit && opened.scope?.startedAt == fixture.now)
            #expect(try await reopened.historicalProgress().first?.progress.hasUnreadContent == true)
            try await reopened.close()
        }
    }

    @Test func reducedScannerRetainsOriginalCaptureInsteadOfEitherContinuation() async throws {
        let fixture = try await PresentationFixture()
        defer { fixture.remove() }
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixture.now)
        let success = try fixture.packet(partial: false)
        let failure = try fixture.packet(partial: true)
        let batch = fixture.batch(audit: audit, continuation: success, unresolvedRecoveryContinuation: failure)
        #expect(try await fixture.process(batch, detector: .init(.reduced), audit: audit,
            expectFailedAttemptOnly: true) == .retryScheduled)
        #expect(try await fixture.store.coverageOmissions().contains { $0.gap.recovery?.itemID == "presentation" })
        #expect(try await fixture.store.coverageReport(endingAt: fixture.now).successfulReads.totalCount == 0)
        let (capture, opened) = try await fixture.queued(in: fixture.store)
        let original = try fixture.packet()
        #expect(capture.retryCount == 1 && opened.body == original.body)
        #expect(opened.body != success.body && opened.body != failure.body)
        #expect(opened.historicalAudit == audit)
        try await fixture.store.close()
    }

    @Test func invalidContinuationPairsFailBeforeScanningAndKeepOriginalCapture() async throws {
        for variant in 0...5 {
            let fixture = try await PresentationFixture()
            defer { fixture.remove() }
            let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixture.now)
            let normalSuccess = try fixture.packet(partial: false)
            let normalFailure = try fixture.packet(partial: true)
            let wrongProfile = try fixture.packet(partial: false,
                metadata: .init(agent: .codex, profileID: "other-profile"))
            let wrongHost = try fixture.packet(partial: true,
                metadata: .init(agent: .codex, interface: .desktopCode, profileID: fixture.scope.profileID))
            let wrongProvider = try fixture.packet(partial: true,
                metadata: .init(agent: .claudeCode, profileID: fixture.scope.profileID))
            let success: CapturePacket? = variant == 0 ? nil : variant == 3 ? wrongProfile : normalSuccess
            let failure: CapturePacket? = variant == 1 ? nil : variant == 4 ? wrongHost
                : variant == 5 ? wrongProvider : normalFailure
            let batch = fixture.batch(audit: audit, dependencies: variant != 2,
                continuation: success, unresolvedRecoveryContinuation: failure)
            let detector = PresentationDetector()
            #expect(try await fixture.process(batch, detector: detector, audit: audit,
                expectFailedAttemptOnly: true) == .retryScheduled)
            #expect(await detector.calls == 0)
            #expect(await fixture.store.snapshot().analysisReceipts.isEmpty)
            let (capture, opened) = try await fixture.queued(in: fixture.store)
            let original = try fixture.packet()
            #expect(capture.retryCount == 1 && opened.body == original.body)
            try await fixture.store.close()
        }
    }

    @Test func ordinaryContinuationWithoutDependenciesRemainsSupported() async throws {
        let fixture = try await PresentationFixture()
        defer { fixture.remove() }
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixture.now)
        let continuation = try fixture.packet(partial: false)
        let batch = CollectionBatch(sources: [.init(record: fixture.source)], continuation: continuation,
            historicalProgress: .init(audit: audit, bytesRead: presentationValue.utf8.count, hasUnreadContent: false),
            observedRead: true)
        #expect(try await fixture.process(batch, audit: audit) == .processed)
        #expect(await fixture.store.snapshot().analysisReceipts.count == 1)
        let (capture, opened) = try await fixture.queued(in: fixture.store)
        #expect(capture.retryCount == 0 && opened.body == continuation.body)
        try await fixture.store.close()
    }
}
