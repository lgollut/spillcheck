import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor LocalMediaReadGate: BackgroundStoreCryptography {
    nonisolated let manifest: ProtectionManifest
    let delegate: BackgroundCryptography
    private var armed = false
    private var gate: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ delegate: BackgroundCryptography) { self.delegate = delegate; manifest = delegate.manifest }
    func arm() { armed = true }
    func blocked() async {
        if gate != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { gate?.resume(); gate = nil }
    func sealBackground(_ plaintext: Data, binding: PayloadBinding) async throws -> ProtectedPayload {
        try await delegate.sealBackground(plaintext, binding: binding)
    }
    func openBackground(_ payload: ProtectedPayload, binding: PayloadBinding) async throws -> Data {
        let plaintext = try await delegate.openBackground(payload, binding: binding)
        if armed, let omission = try? JSONDecoder().decode(CoverageOmission.self, from: plaintext),
           omission.gap.sourceKind == .codexUserMessage, omission.gap.diagnosticCode == .unknownBlockKind {
            armed = false
            await withCheckedContinuation { continuation in
                gate = continuation; waiters.forEach { $0.resume() }; waiters.removeAll()
            }
        }
        return plaintext
    }
    func revision(canonicalBytes: Data) async throws -> ContentRevision {
        try await delegate.revision(canonicalBytes: canonicalBytes)
    }
}

private let localMediaTextValue = "SPILLCHECK_FAKE_LOCAL_MEDIA_TEXT_42"
private actor LocalMediaTextDetector: SecretDetector {
    private(set) var calls = 0
    func scan(_ source: SourceRecord) throws -> DetectorOutput {
        calls += 1
        var findings: [DetectorFinding] = []
        let bytes = Data(localMediaTextValue.utf8)
        for segment in source.segments {
            if let range = segment.utf8.range(of: bytes) {
                let location = try CanonicalLocation(segmentID: segment.id, range: .init(range.lowerBound, range.upperBound))
                findings.append(try .init(extraction: .init(valueUTF8: bytes, location: location, in: source), evidence: [evidence()]))
            }
        }
        return .init(detectorVersion: "synthetic-local-media-full", findings: findings, unlocated: [])
    }
}

@Suite("Persisted native local-media warning correction", .timeLimit(.minutes(1)))
struct LocalMediaWarningRecoveryTests {
    private let now = Date(timeIntervalSince1970: 1_791_750_000)
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-local-media-\(UUID())")
    }
    private func scope(_ interface: AgentInterface = .standaloneCLI, path: CollectionPath = .publicHistory,
                       profile: String = "media-profile") -> CollectionScope {
        .init(provider: .codex, profileID: profile, interface: interface, path: path)
    }
    private func reference(_ item: String = "media", time: Date? = nil,
                           constraint: CoverageRecoveryConstraint? = nil,
                           session: String = "native-session", sourceURL: URL? = nil) throws -> CoverageRecoveryReference {
        .init(session: try .init(provider: .codex, profileID: "media-profile", sessionID: session),
            locator: .upstreamItem, itemID: item, contentTime: time ?? now,
            parserContract: constraint == nil ? "media-old" : "media-new", sourceURL: sourceURL, constraint: constraint)
    }
    private func old(_ reference: CoverageRecoveryReference, scope: CollectionScope? = nil,
                     operation: CollectionOperation = .liveRead, required: Bool? = true,
                     kind: CoverageSourceKind = .codexUserMessage, diagnostic: CoverageDiagnosticCode = .unknownBlockKind,
                     excluded: Bool? = nil, contentType: ContentType = .userPrompt,
                     reason: CoverageGapReason = .unsupportedContent) -> CoverageGap {
        .init(reason: reason, scope: scope ?? self.scope(), contentType: contentType, operation: operation,
            recovery: reference, isRequiredFormatFailure: required, sourceKind: kind,
            diagnosticCode: diagnostic, excludedContent: excluded)
    }
    private func proof(_ reference: CoverageRecoveryReference? = nil, scope: CollectionScope? = nil,
                       operation: CollectionOperation = .liveRead) throws -> CoverageGap {
        old(try reference ?? self.reference(constraint: .recognizedLocalMedia), scope: scope,
            operation: operation, required: false, diagnostic: .excludedBinaryContent, excluded: true)
    }
    private func capture(_ store: ProtectedStore, scope: CollectionScope? = nil,
                         authorized: Bool = true, operation: CollectionOperation = .liveRead) async throws -> (PendingCapture, StoreProcessingPermit) {
        let permit = try #require(await store.processingPermit())
        let selected = scope ?? self.scope()
        let packet = try CapturePacket(metadata: .init(agent: .codex, interface: selected.interface, profileID: selected.profileID),
            eventJSON: JSONSerialization.data(withJSONObject: ["hook_event_name": "SpillcheckHistoryPoll", "session_id": "native-session"]))
        let context = authorized ? CollectionWorkContext(scope: selected, operation: operation) : nil
        _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, workContext: context)
        return (try #require(try await store.nextPending(at: now, permit: permit)), permit)
    }
    private func complete(_ store: ProtectedStore, gaps: [CoverageGap], refs: [CoverageRecoveryReference] = [],
                          scope: CollectionScope? = nil, authorized: Bool = true,
                          operation: CollectionOperation = .liveRead) async throws {
        let (capture, permit) = try await capture(store, scope: scope, authorized: authorized, operation: operation)
        try await store.completeCapture(capture, coverageGaps: gaps, recoveredReferences: refs, permit: permit, at: now)
    }

    @Test func exactWarningBecomesPersistentExclusionWithoutLosingIdentityAgeOrState() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let earlier = now.addingTimeInterval(-3600)
        let oldReference = try reference(time: earlier)
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        try await store.recordCoverageGap(old(oldReference), at: earlier)
        let before = try #require(try await store.coverageOmissions().first)
        let incident = try #require(try await store.healthIncidents().first)
        try await store.close()
        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let current = try proof(reference(time: earlier, constraint: .recognizedLocalMedia))
        try await complete(reopened, gaps: [current])
        let after = try #require(try await reopened.coverageOmissions().first)
        #expect(after.id == before.id && after.firstObservedAt == before.firstObservedAt)
        #expect(after.state == before.state && after.resolvedAt == before.resolvedAt)
        #expect(after.gap.recovery?.contentTime == earlier && after.gap.recovery?.parserContract == "media-new")
        #expect(after.gap.excludedContent == true && after.gap.isRequiredFormatFailure == false)
        #expect(after.gap.diagnosticCode == .excludedBinaryContent && !after.gap.requiresAnalysis)
        #expect(try await reopened.coverageOmissions().count == 1)
        #expect(try await reopened.healthIncidents().isEmpty)
        let resolved = try #require(try await reopened.healthIncidents(includeResolved: true).first)
        #expect(resolved.id == incident.id && resolved.resolvedAt == now && resolved.delivery == .cancelled)
        #expect(await reopened.snapshot().analysisReceipts.isEmpty)
        #expect(await reopened.snapshot().records.isEmpty)
        try await reopened.close()
        let cold = try await ProtectedStore.open(at: directory, cryptography: crypto)
        #expect(try await cold.coverageOmissions() == [after])
        try await complete(cold, gaps: [current])
        #expect(try await cold.coverageOmissions() == [after])
        #expect(try await cold.healthIncidents(includeResolved: true) == [resolved])
        #expect(await cold.snapshot().analysisReceipts.isEmpty)
        try await cold.close()
    }

    @Test func sameIncidentSiblingOrAssessmentPreventsSettlement() async throws {
        for assessment in [false, true] {
            let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
            let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
            try await store.recordCoverageGap(old(reference()), at: now)
            if assessment {
                try await store.recordCoverageGap(.init(reason: .unsupportedContent, scope: scope(),
                    contentType: .userPrompt, operation: .liveRead, isRequiredFormatFailure: true,
                    sourceKind: .codexUserMessage, diagnosticCode: .unknownBlockKind), at: now)
            } else {
                try await store.recordCoverageGap(old(reference("other")), at: now)
            }
            let incident = try #require(try await store.healthIncidents().first)
            try await complete(store, gaps: [proof()])
            #expect(try await store.healthIncidents() == [incident])
            let target = try #require(try await store.coverageOmissions().first { $0.gap.recovery?.itemID == "media" })
            #expect(target.gap.excludedContent == true)
            if !assessment {
                try await complete(store, gaps: [], refs: [reference("other")])
                #expect(try await store.healthIncidents().isEmpty)
                #expect(try await store.coverageOmissions() == [target])
            }
            try await store.close()
        }
    }

    @Test func authenticatedCurrentRouteAndOperationAreRequired() async throws {
        for (route, authorized, operation) in [
            (scope(), false, CollectionOperation.liveRead), (scope(path: .hook), true, .liveRead),
            (scope(profile: "other-profile"), true, .liveRead), (scope(.t3), true, .liveRead),
            (scope(), true, .hookDelivery), (scope(), true, .historicalRead)
        ] {
            let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
            let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
            try await store.recordCoverageGap(old(reference()), at: now)
            let before = try await store.coverageOmissions()
            try await complete(store, gaps: [proof()], scope: route, authorized: authorized, operation: operation)
            #expect(try await store.coverageOmissions() == before)
            #expect(try await store.healthIncidents().count == 1)
            try await store.close()
        }
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
        try await store.recordCoverageGap(old(reference(), operation: .historicalRead), at: now)
        try await complete(store, gaps: [proof(operation: .historicalRead)], operation: .historicalRead)
        #expect(try await store.coverageOmissions().first?.gap.excludedContent == true)
        #expect(try await store.healthIncidents().isEmpty)
        try await store.close()
    }

    @Test func everyOtherPriorMeaningAndSelectionRemainUntouched() async throws {
        for variant in 0..<16 {
            let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
            let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
            let ref = try reference()
            let gap: CoverageGap
            switch variant {
            case 0: gap = old(ref, diagnostic: .encryptedContentUnavailable)
            case 1: gap = old(ref, diagnostic: .malformedRecord)
            case 2: gap = old(ref, diagnostic: .unknownRecordKind)
            case 3: gap = old(ref, kind: .codexAgentMessage)
            case 4: gap = old(ref, required: false)
            case 5: gap = old(ref, required: nil)
            case 6: gap = old(ref, excluded: false)
            case 7: gap = old(ref, excluded: true)
            case 8: gap = old(try reference(constraint: .unclassifiedMetadata))
            case 9: gap = old(try reference(sourceURL: URL(fileURLWithPath: "/tmp/not-native")))
            case 10: gap = old(ref, reason: .scannerUnavailable)
            case 11: gap = old(ref, reason: .malformedSource)
            case 12: gap = old(ref, contentType: .toolOutput)
            case 13: gap = old(try reference(time: now.addingTimeInterval(-1)))
            case 14: gap = old(try reference(session: "other-session"))
            default: gap = old(.init(session: ref.session, locator: ref.locator, itemID: ref.itemID,
                parserContract: ref.parserContract))
            }
            try await store.recordCoverageGap(gap, at: now)
            let before = try #require(try await store.coverageOmissions().first)
            try await complete(store, gaps: [proof()])
            #expect(try await store.coverageOmissions().contains(before))
            try await store.close()
        }
    }

    @Test func sameBatchRequiredSiblingVetoesCorrectionRegardlessOfOrderOrKey() async throws {
        for differentKey in [false, true] {
            for proofFirst in [false, true] {
                let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
                try await store.recordCoverageGap(old(reference()), at: now)
                let before = try #require(try await store.coverageOmissions().first)
                let sibling = old(try reference(), diagnostic: .encryptedContentUnavailable,
                    reason: differentKey ? .malformedSource : .unsupportedContent)
                let current = try proof()
                try await complete(store, gaps: proofFirst ? [current, sibling] : [sibling, current], refs: [reference()])
                let currentOmissions = try await store.coverageOmissions()
                if differentKey { #expect(currentOmissions.contains(before)) }
                else {
                    let retained = try #require(currentOmissions.first { $0.id == before.id })
                    #expect(retained.firstObservedAt == before.firstObservedAt && retained.gap.requiresAnalysis)
                    #expect(retained.gap.diagnosticCode == .encryptedContentUnavailable)
                }
                #expect(try await store.healthIncidents().isEmpty == false)
                try await store.close()
            }
        }
    }

    @Test func inactiveExpiredFutureAndPreviouslyRecoveredRowsCannotBeReclassified() async throws {
        for variant in 0..<4 {
            let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
            let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
            let time = variant == 0 || variant == 1 ? now.addingTimeInterval(-HistoricalAuditContext.lookback - 1)
                : variant == 2 ? now.addingTimeInterval(1) : now
            let ref = try reference(time: time)
            try await store.recordCoverageGap(old(ref), at: min(time, now))
            if variant == 1 { _ = try await store.expireCoverageRecovery(at: now) }
            if variant == 3 { try await complete(store, gaps: [], refs: [ref]) }
            let before = try await store.coverageOmissions(includeRecovered: true)
            try await complete(store, gaps: [proof(reference(time: time, constraint: .recognizedLocalMedia))])
            #expect(try await store.coverageOmissions(includeRecovered: true) == before)
            try await store.close()
        }
    }

    @Test func gapOnlyProofRejectsBroadRecoveryAndInvalidSignaturesWithoutProgress() async throws {
        for variant in 0..<7 {
            let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
            let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
            try await store.recordCoverageGap(old(reference()), at: now)
            let before = try await store.coverageOmissions()
            let ref = try reference(constraint: .recognizedLocalMedia)
            let gap: CoverageGap
            switch variant {
            case 1: gap = old(ref, required: false, diagnostic: .excludedBinaryContent, excluded: nil)
            case 2: gap = old(ref, required: true, diagnostic: .excludedBinaryContent, excluded: true)
            case 3: gap = old(ref, required: false, diagnostic: .unknownBlockKind, excluded: true)
            case 4: gap = old(ref, required: false, kind: .codexAgentMessage, diagnostic: .excludedBinaryContent, excluded: true)
            case 5: gap = try proof(reference(constraint: .recognizedLocalMedia, sourceURL: URL(fileURLWithPath: "/tmp/other")))
            case 6: gap = try proof(.init(session: ref.session, locator: .upstreamItem, itemID: "media",
                parserContract: "media-new", constraint: .recognizedLocalMedia))
            default: gap = try proof()
            }
            let (capture, permit) = try await capture(store)
            await #expect(throws: StorageError.invalidPayload) {
                try await store.completeCapture(capture, coverageGaps: variant == 0 ? [] : [gap],
                    recoveredReferences: variant == 0 ? [ref] : [], permit: permit, at: now)
            }
            #expect(try await store.coverageOmissions() == before)
            #expect(try await store.queueStatistics().count == 1)
            #expect(await store.snapshot().analysisReceipts.isEmpty)
            try await store.close()
        }
    }

    @Test func cryptoYieldConcurrentLifecycleOrCiphertextChangeRejectsStaleCorrection() async throws {
        for variant in 0..<4 {
            let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
            let crypto = LocalMediaReadGate(try BackgroundCryptography.ephemeralForTesting())
            let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
            let ref = try reference()
            try await store.recordCoverageGap(old(ref), at: now)
            let (capture, permit) = try await capture(store)
            let checkpoint = SourceCheckpoint(capabilityID: UUID(), sourceDocumentID: UUID(),
                revision: try ContentRevision(keyedDigest: Data(repeating: 5, count: 32)), byteOffset: 31)
            await crypto.arm()
            let pending = Task {
                try await store.completeCapture(capture, checkpoints: [checkpoint], coverageGaps: [proof()],
                    permit: permit, at: now)
            }
            await crypto.blocked()
            if variant == 0 {
                _ = try await store.expireCoverageRecovery(at: now.addingTimeInterval(HistoricalAuditContext.lookback + 1))
            } else if variant == 1 {
                try await complete(store, gaps: [], refs: [ref])
            } else if variant == 2 {
                try await store.recordCoverageGap(old(ref, diagnostic: .encryptedContentUnavailable), at: now)
            } else {
                try await store.recordCoverageGap(old(ref), at: now)
            }
            let concurrentlyChanged = try await store.coverageOmissions(includeRecovered: true)
            await crypto.release()
            await #expect(throws: StorageError.stateChanged) { try await pending.value }
            #expect(try await store.coverageOmissions(includeRecovered: true) == concurrentlyChanged)
            #expect(try await store.queueStatistics().count == 1)
            #expect(try await store.checkpoint(documentID: checkpoint.sourceDocumentID) == nil)
            #expect(await store.snapshot().analysisReceipts.isEmpty)
            try await store.close()
        }
    }

    @Test func newerSameKeyRequiredMeaningReplacesLegacyUnknownAndCannotBecomeMedia() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
        let earlier = now.addingTimeInterval(-3600), ref = try reference(time: now.addingTimeInterval(-3600))
        try await store.recordCoverageGap(old(ref), at: earlier)
        let before = try #require(try await store.coverageOmissions().first)
        try await store.recordCoverageGap(old(ref, diagnostic: .encryptedContentUnavailable), at: now)
        let changed = try #require(try await store.coverageOmissions().first)
        #expect(changed.id == before.id && changed.firstObservedAt == before.firstObservedAt)
        #expect(changed.gap.diagnosticCode == .encryptedContentUnavailable && changed.gap.requiresAnalysis)
        try await complete(store, gaps: [proof(reference(time: earlier, constraint: .recognizedLocalMedia))])
        #expect(try await store.coverageOmissions() == [changed])
        #expect(try await store.healthIncidents().count == 1)
        try await store.close()
    }

    @Test func knownRequiredMeaningDominatesLegacyInBothBatchOrdersBeforeLaterMediaProof() async throws {
        for legacyFirst in [false, true] {
            let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
            let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
            let ref = try reference(), legacy = old(try reference())
            let known = old(ref, diagnostic: .encryptedContentUnavailable)
            try await store.recordCoverageGap(legacy, at: now.addingTimeInterval(-1))
            let initial = try #require(try await store.coverageOmissions().first)
            try await complete(store, gaps: legacyFirst ? [legacy, known] : [known, legacy])
            let kept = try #require(try await store.coverageOmissions().first)
            #expect(kept.id == initial.id && kept.firstObservedAt == initial.firstObservedAt)
            #expect(kept.gap.diagnosticCode == .encryptedContentUnavailable && kept.gap.requiresAnalysis)
            try await complete(store, gaps: [proof()])
            #expect(try await store.coverageOmissions() == [kept])
            #expect(try await store.healthIncidents().count == 1)
            try await store.close()
        }
    }

    @Test func actualAdapterPipelineRetainsTextFindingAndReceiptThroughCorrectionColdAndReplay() async throws {
        // The detector is synthetic; native parsing, encrypted commits, receipts and
        // restart/replay use the production adapter, pipeline and store.
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting(), detector = LocalMediaTextDetector()
        let currentTime = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let contentTime = currentTime.addingTimeInterval(-30)
        let history = CodexTestHistory(), sessionID = "local-media-session"
        let routeScope = CollectionScope(provider: .codex, profileID: "test", interface: .standaloneCLI, path: .publicHistory)
        let packet = try codexPacket(thread: sessionID, interface: .standaloneCLI)
        let context = try CollectionCaptureRoute(scope: routeScope, readerVersion: "0.162.1").context(for: packet, trigger: .activePoll)
        var baseline: InventorySnapshot?, prior: CoverageOmission?, corrected: CoverageOmission?
        for stage in 0..<3 {
            var blocks: [[String: Any]] = [["type": "text", "text": localMediaTextValue]]
            if stage > 0 { blocks.append(["type": "localImage", "path": "/not-opened/fake.png"]) }
            let entry = try codexItem("original-user", type: "userMessage", timestamp: contentTime.timeIntervalSince1970 * 1000,
                body: ["content": blocks])
            await history.configure(sessionID, thread: try codexThread(sessionID, producer: "0.162.1"), pages: [.init(data: [entry])])
            let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
            if let baseline {
                let cold = await store.snapshot()
                #expect(cold.occurrences == baseline.occurrences && cold.analysisReceipts == baseline.analysisReceipts)
                #expect(cold.locationReceipts == baseline.locationReceipts && cold.records == baseline.records)
            }
            let adapter = try CodexAdapter(profileID: "test", agentVersion: "0.162.1", history: history,
                authorityLookup: { try await store.authority(for: $0) }, authorityRecorder: { choice in
                    let permit = try #require(await store.processingPermit())
                    try await store.selectAuthority(choice, permit: permit)
                })
            let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
                detector: detector, detectorVersion: "synthetic-local-media-full")
            let permit = try #require(await store.processingPermit())
            _ = try await store.enqueue(packet.body, capturedAt: currentTime, permit: permit, at: currentTime, workContext: context)
            #expect(try await pipeline.processNext(at: currentTime) == .processed)
            #expect(try await store.queueStatistics().count == 0)
            let snapshot = await store.snapshot()
            #expect(snapshot.records.count == 1 && snapshot.occurrences.count == 1 && snapshot.analysisReceipts.count == 1)
            let occurrence = try #require(snapshot.occurrences.values.first)
            #expect(occurrence.source.contentType == .userPrompt && occurrence.source.contentTime == contentTime)
            #expect(occurrence.identity.source.itemID == "original-user")
            #expect(occurrence.identity.location.components.map(\.segmentID) == ["/content/0/text"])
            if stage == 0 {
                baseline = snapshot
                let oldGap = CoverageGap(reason: .unsupportedContent, scope: routeScope, contentType: .userPrompt, operation: .liveRead,
                    recovery: .init(session: occurrence.identity.source.session, locator: .upstreamItem,
                        itemID: "original-user", contentTime: contentTime, parserContract: "codex-content-contract-v15"),
                    isRequiredFormatFailure: true, sourceKind: .codexUserMessage, diagnosticCode: .unknownBlockKind)
                try await store.recordCoverageGap(oldGap, at: contentTime)
                prior = try #require(try await store.coverageOmissions().first)
            } else {
                let baseline = try #require(baseline)
                #expect(snapshot.occurrences == baseline.occurrences && snapshot.analysisReceipts == baseline.analysisReceipts)
                #expect(snapshot.locationReceipts == baseline.locationReceipts && snapshot.records == baseline.records)
                #expect(snapshot.sourceKinds == baseline.sourceKinds && snapshot.sourceTimes == baseline.sourceTimes)
                let omission = try #require(try await store.coverageOmissions().first)
                #expect(omission.id == prior?.id && omission.firstObservedAt == prior?.firstObservedAt && omission.state == prior?.state)
                #expect(omission.gap.excludedContent == true && omission.gap.recovery?.constraint == .recognizedLocalMedia)
                #expect(try await store.healthIncidents().isEmpty)
                if stage == 1 { corrected = omission } else { #expect(omission == corrected) }
            }
            try await store.close()
        }
        #expect(await detector.calls == 1)
    }
}
