import Foundation

public enum PipelineOutcome: Sendable, Equatable { case idle, processed, retryScheduled }
public enum PipelineError: Error, Sendable { case alreadyProcessing, budgetExhausted }
public struct PipelineActivity: Sendable {
    public let processing: Bool
    public let pendingCount: Int
}

@_spi(Testing) public enum PipelineFailureStage: String, Sendable {
    case openCapture, decodeCapture, normalize, captureScope, scan, preparePayloads, commitSource, completeCapture
}
@_spi(Testing) public enum PipelineFailureCode: String, Sendable {
    case contractEmptyIdentity, contractInvalidFingerprint, contractInvalidRange, contractInvalidUTF8
    case contractDuplicateSegment, contractMissingSegment, contractValueDoesNotMatchSource, contractInvalidTime
    case contractMissingEvidence, contractConflictingValueAtLocation, contractConflictingSourceMetadata
    case contractUnknownOccurrence, contractUnknownValue, contractObsoleteMarkerNotFound, contractContentStillRetained
    case contractMismatchedAudit, contractInvalidState, contractInvalidSnapshot, contractUnsupportedSnapshotVersion
    case storageInvalidPayload, storageInvalidTime, storageCorruptProtectedState, storageStateChanged, storageFailure
    case protectionInvalidEnvelope, protectionIncorrectKey, protectionInvalidPurpose, protectionAuthenticationFailed, protectionCryptographyFailure
    case collectionFailure, detectorFailure, transportFailure, pipelineBudgetExhausted, unexpected
}
@_spi(Testing) public struct PipelineFailureDiagnostic: Sendable {
    public let stage: PipelineFailureStage
    public let code: PipelineFailureCode
    public let reason: CoverageGapReason
}

public struct RetainedExcerpt: Codable, Sendable {
    public let text: String
    public let clipped: Bool
    public init(text: String, clipped: Bool) { self.text = text; self.clipped = clipped }
}

/// One worker, independent of capture acknowledgment. Every retained byte is protected before SQL.
public actor DetectionPipeline {
    private let store: ProtectedStore
    private let cryptography: BackgroundCryptography
    private let normalizer: any CaptureNormalizer
    private let detector: any SecretDetector
    private let detectorVersion: String
    private let onActivity: @Sendable (PipelineActivity) async -> Void
    private var liveSince: Date
    private var worker: Task<Void, Never>?
    private var processing = false
    private var lastCompaction = Date.distantPast
    private var failureObserver: (@Sendable (PipelineFailureDiagnostic) async -> Void)?
    private var captureCompletionObserver: (@Sendable (UUID) async -> Void)?
    private var failureStage: PipelineFailureStage = .openCapture

    /// Disposable diagnostics use closed labels only. Normal application construction leaves this nil.
    @_spi(Testing) public func observeFailuresForTesting(
        _ observer: @escaping @Sendable (PipelineFailureDiagnostic) async -> Void
    ) { failureObserver = observer }

    /// Called only after the capture's processing and atomic completion succeed, never on loss.
    @_spi(Testing) public func observeCaptureCompletionsForTesting(
        _ observer: @escaping @Sendable (UUID) async -> Void
    ) { captureCompletionObserver = observer }

    private func diagnosticStage(_ stage: PipelineFailureStage) {
        if failureObserver != nil { failureStage = stage }
    }

    public init(store: ProtectedStore, cryptography: BackgroundCryptography,
                normalizer: any CaptureNormalizer, detector: any SecretDetector,
                detectorVersion: String, liveSince: Date = Date(),
                onActivity: @escaping @Sendable (PipelineActivity) async -> Void = { _ in }) {
        self.store = store
        self.cryptography = cryptography
        self.normalizer = normalizer
        self.detector = detector
        self.detectorVersion = detectorVersion
        self.liveSince = liveSince
        self.onActivity = onActivity
    }

    public func start(liveSince: Date? = nil) {
        guard worker == nil else { return }
        if let liveSince { self.liveSince = liveSince }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                do {
                    if try await self.processNext() == .idle { await self.compactIfDue() }
                }
                catch is CancellationError { break }
                catch { /* Only controlled coverage errors enter persistence, never raw diagnostics. */ }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
        }
    }

    /// Compaction runs only while this single worker is idle, so it never races a source commit.
    private func compactIfDue(at now: Date = Date()) async {
        guard now.timeIntervalSince(lastCompaction) >= 60 * 60 else { return }
        lastCompaction = now
        // A failed pass leaves the ledger unchanged and is retried at the next interval.
        _ = try? await store.compactProcessedSources(at: now)
        _ = try? await store.expireCoverageRecovery(at: now)
    }

    public func stop() async {
        let task = worker
        worker = nil
        task?.cancel()
        await task?.value
        await publish(processing: false)
    }

    @discardableResult
    public func processNext(at now: Date = Date()) async throws -> PipelineOutcome {
        guard !processing else { throw PipelineError.alreadyProcessing }
        guard !Task.isCancelled, let permit = await store.processingPermit() else { return .idle }
        guard let capture = try await store.nextPending(at: now, permit: permit) else { return .idle }
        processing = true
        await publish(processing: true)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.process(capture, permit: permit, now: now) }
                group.addTask {
                    try await Task.sleep(for: .seconds(110))
                    throw PipelineError.budgetExhausted
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
            if let captureCompletionObserver { await captureCompletionObserver(capture.id) }
            processing = false
            await publish(processing: false)
            return .processed
        } catch {
            processing = false
            await publish(processing: false)
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let storageError = error as? StorageError,
               [.monitoringPaused, .staleProcessingPermit, .staleClaim].contains(storageError) { return .idle }
            if let failureObserver {
                await failureObserver(.init(stage: failureStage, code: Self.diagnosticCode(error), reason: Self.reason(for: error)))
            }
            // The store generation rejects retry work after pause, deletion or shutdown too.
            try await store.retry(capture, reason: Self.reason(for: error), at: Date(), permit: permit)
            return .retryScheduled
        }
    }

    private func process(_ capture: PendingCapture, permit: StoreProcessingPermit, now: Date) async throws {
        diagnosticStage(.openCapture)
        let opened = try await store.openCapturedWork(capture)
        diagnosticStage(.decodeCapture)
        let packet = try CapturePacket(body: opened.body)
        diagnosticStage(.normalize)
        let batch = try await normalizer.normalize(packet, capturedAt: capture.capturedAt, cryptography: cryptography)
        diagnosticStage(.captureScope)
        let scope = try opened.scope ?? LiveCaptureScope(startedAt: liveSince)
        let audit = try opened.historicalAudit ?? HistoricalAuditContext(
            id: scope.catchupAuditID ?? capture.id, reason: scope.catchupReason, endingAt: scope.startedAt)
        var reducedCoverage = false
        var coverageGaps = batch.coverageGaps
        var recoveredReferences = batch.recoveredReferences
        for collected in batch.sources {
            try Task.checkCancellation()
            diagnosticStage(.captureScope)
            let source = try scopedSource(collected.record, scope: scope, audit: audit,
                                          forceHistorical: opened.historicalAudit != nil)
            // No audit window reaches this far back, so processed-source receipts can be compacted.
            if source.metadata.contentTime < now.addingTimeInterval(-HistoricalAuditContext.analysisHorizon) { continue }
            let receipt = AnalysisReceipt(source: source.metadata.identity, revision: source.revision,
                detectorVersion: detectorVersion)
            if await store.snapshot().analysisReceipts.contains(receipt) { continue }
            if case .historical(let audit) = source.metadata.origin.provenance,
               !audit.includes(contentTime: source.metadata.contentTime) { continue }
            diagnosticStage(.scan)
            let output = try await detector.scan(source)
            coverageGaps.append(contentsOf: output.coverageGaps)
            if !output.coverageGaps.isEmpty {
                recoveredReferences.removeAll { reference in
                    reference.session == source.metadata.identity.session
                        && reference.locator == source.metadata.locator
                        && (reference.itemID == nil || reference.itemID == source.metadata.identity.itemID)
                }
            }
            let degraded = output.scannerFailure != nil
            reducedCoverage = reducedCoverage || degraded
            let version = output.detectorVersion + (degraded ? "+reduced" : (output.coverageGaps.isEmpty ? "" : "+partial"))
            diagnosticStage(.preparePayloads)
            let prepared = try await prepare(source: source, context: collected.context, output: output, version: version)
            try Task.checkCancellation()
            diagnosticStage(.commitSource)
            _ = try await store.commit(prepared.analysis, payloads: prepared.payloads, linking: capture, permit: permit)
        }
        if reducedCoverage {
            // Retryable scanner work retains its queue claim and source progress. Persist its
            // controlled gaps without settling any parser recovery references prematurely.
            diagnosticStage(.completeCapture)
            for gap in coverageGaps { try await store.recordCoverageGap(gap, at: now) }
            diagnosticStage(.scan)
            throw DetectorFailure.unavailable
        }
        try Task.checkCancellation()
        diagnosticStage(.completeCapture)
        try await store.completeCapture(capture, checkpoints: batch.checkpoints,
            continuation: batch.continuation, historicalProgress: batch.historicalProgress,
            coverageGaps: coverageGaps, recoveredReferences: recoveredReferences, permit: permit, at: now)
    }

    private func prepare(source: SourceRecord, context: RetainedSourceContext?, output: DetectorOutput,
                         version: String) async throws -> (analysis: SourceAnalysis, payloads: [ProtectedPayload]) {
        let snapshot = await store.snapshot()
        var payloads: [ProtectedPayload] = []
        var findings: [LocatedDetection] = []
        var retainSourceContext = !output.unlocated.isEmpty
        var fingerprints: [ValueFingerprint] = []
        for finding in output.findings {
            try Task.checkCancellation()
            try finding.extraction.validate(in: source)
            fingerprints.append(try await cryptography.fingerprint(exactBytes: finding.extraction.valueUTF8))
        }
        for (finding, fingerprint) in zip(output.findings, fingerprints) {
            try Task.checkCancellation()
            let metadataOnly = snapshot.obsoleteMarkers[fingerprint] != nil
                && snapshot.records[fingerprint]?.protectedValue == nil
            let valueReference = ProtectedPayloadReference()
            let excerptReference = metadataOnly ? nil : ProtectedPayloadReference()
            if !metadataOnly {
                retainSourceContext = true
                payloads.append(try await cryptography.sealInventory(finding.extraction.valueUTF8,
                    binding: PayloadBinding(reference: valueReference, ownerID: valueReference.id, kind: .value)))
                if let excerptReference {
                    let others = zip(output.findings, fingerprints).filter { $0.1 != fingerprint }
                        .flatMap { $0.0.extraction.location.components }
                    let excerpt = Self.excerpt(around: finding.extraction.location, in: source, masking: others)
                    payloads.append(try await cryptography.sealInventory(JSONEncoder().encode(excerpt),
                        binding: PayloadBinding(reference: excerptReference, ownerID: excerptReference.id, kind: .excerpt)))
                }
            }
            findings.append(try LocatedDetection(extraction: finding.extraction, in: source, fingerprint: fingerprint,
                evidence: finding.evidence, protectedValue: valueReference, protectedExcerpt: excerptReference))
        }
        var preparedSource = source
        if retainSourceContext {
            try Task.checkCancellation()
            let reference = ProtectedPayloadReference()
            let retained = context ?? RetainedSourceContext(sessionIdentifier: source.metadata.identity.session.sessionID)
            payloads.append(try await cryptography.sealInventory(JSONEncoder().encode(retained),
                binding: PayloadBinding(reference: reference, ownerID: reference.id, kind: .sourceMetadata)))
            preparedSource = try replacingMetadata(source, protectedReference: reference)
        }
        return (try SourceAnalysis(source: preparedSource, detectorVersion: version, detections: findings,
            unlocated: output.unlocated), payloads)
    }

    private func scopedSource(_ source: SourceRecord, scope: LiveCaptureScope, audit: HistoricalAuditContext,
                              forceHistorical: Bool) throws -> SourceRecord {
        // Existing content discovered by a live nudge receives historical provenance and summary rules.
        guard forceHistorical || source.metadata.contentTime < scope.startedAt else { return source }
        let old = source.metadata.origin
        let origin = try SourceOrigin(adapterID: old.adapterID, adapterVersion: old.adapterVersion,
            agentVersion: old.agentVersion, interface: old.interface, provenance: .historical(audit),
            canonicalization: old.canonicalization)
        return try replacingMetadata(source, origin: origin)
    }

    private func replacingMetadata(_ source: SourceRecord, protectedReference: ProtectedPayloadReference? = nil,
                                   origin: SourceOrigin? = nil) throws -> SourceRecord {
        let old = source.metadata
        return try SourceRecord(metadata: SourceRecordMetadata(identity: old.identity, contentType: old.contentType,
            contentTime: old.contentTime, observedAt: old.observedAt, locator: old.locator,
            protectedMetadata: protectedReference ?? old.protectedMetadata, origin: origin ?? old.origin),
            revision: source.revision, segments: source.segments)
    }

    static let maskedOtherValue = "[other detected value]"

    /// Other detected values are independently deletable and acknowledgeable. Their bytes are
    /// replaced here, so removing one value cannot leave it revealable through a neighbour's context.
    static func excerpt(around location: CanonicalLocation, in source: SourceRecord,
                        masking others: [ComponentRange] = []) -> RetainedExcerpt {
        guard let component = location.components.first,
              let segment = source.segments.first(where: { $0.id == component.segmentID }) else {
            return RetainedExcerpt(text: "", clipped: true)
        }
        let bytes = segment.utf8
        var start = max(0, component.range.lowerBound - 1024)
        var end = min(bytes.count, start + 4096)
        while start < end, bytes[start] & 0xC0 == 0x80 { start += 1 }
        while end > start, end < bytes.count, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        let own = location.components.filter { $0.segmentID == component.segmentID }.map(\.range)
        let hidden = others.filter { $0.segmentID == component.segmentID }.flatMap { other -> [Range<Int>] in
            let lower = max(other.range.lowerBound, start), upper = min(other.range.upperBound, end)
            return lower < upper ? Self.subtract(own, from: lower..<upper) : []
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for piece in hidden {
            if let last = merged.last, piece.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, piece.upperBound)
            } else { merged.append(piece) }
        }
        var retained = Data(), cursor = start
        for piece in merged {
            if piece.lowerBound > cursor { retained.append(bytes.subdata(in: cursor..<piece.lowerBound)) }
            retained.append(Data(maskedOtherValue.utf8))
            cursor = max(cursor, piece.upperBound)
        }
        if cursor < end { retained.append(bytes.subdata(in: cursor..<end)) }
        let text = String(data: retained, encoding: .utf8) ?? ""
        return RetainedExcerpt(text: text, clipped: start > 0 || end < bytes.count || location.components.count > 1)
    }

    /// The occurrence's own value stays readable even when another detection overlaps it.
    private static func subtract(_ own: [UTF8Range], from range: Range<Int>) -> [Range<Int>] {
        var pieces = [range]
        for keep in own {
            pieces = pieces.flatMap { piece -> [Range<Int>] in
                guard keep.lowerBound < piece.upperBound, keep.upperBound > piece.lowerBound else { return [piece] }
                return [piece.lowerBound..<max(piece.lowerBound, keep.lowerBound),
                        min(piece.upperBound, keep.upperBound)..<piece.upperBound].filter { !$0.isEmpty }
            }
        }
        return pieces
    }

    private func publish(processing: Bool) async {
        let count = (try? await store.queueStatistics().count) ?? 0
        await onActivity(PipelineActivity(processing: processing, pendingCount: count))
    }

    private static func reason(for error: any Error) -> CoverageGapReason {
        if let failure = error as? CodexHistoryReadFailure { return reason(for: failure.reason) }
        return switch error {
        case ClaudeCollectionError.awaitingTranscript: .sourceUnavailable
        case is ClaudeCollectionError: .malformedSource
        case CodexCollectionError.unsupportedVersion, CodexHistoryError.unsupportedVersion: .unsupportedVersion
        case CodexCollectionError.awaitingHistory, CodexHistoryError.unavailable,
             CodexHistoryError.remoteFailure: .sourceUnavailable
        case CodexCollectionError.authorityConflict, CodexCollectionError.missingAuthority: .unresolvedCorrelation
        case CodexHistoryError.timedOut, CodexHistoryError.responseLimitExceeded: .budgetExhausted
        case CodexHistoryError.malformedResponse, is CodexCollectionError: .malformedSource
        case is CodexHistoryError: .sourceUnavailable
        case DetectorFailure.timedOut, DetectorFailure.outputLimitExceeded,
             DetectorFailure.inputLimitExceeded, PipelineError.budgetExhausted: .budgetExhausted
        case is DetectorFailure: .scannerUnavailable
        case is CaptureTransportError: .malformedSource
        default: .captureRejected
        }
    }

    private static func diagnosticCode(_ error: any Error) -> PipelineFailureCode {
        if let error = error as? ContractError {
            return switch error {
            case .emptyIdentity: .contractEmptyIdentity
            case .invalidFingerprint: .contractInvalidFingerprint
            case .invalidRange: .contractInvalidRange
            case .invalidUTF8: .contractInvalidUTF8
            case .duplicateSegment: .contractDuplicateSegment
            case .missingSegment: .contractMissingSegment
            case .valueDoesNotMatchSource: .contractValueDoesNotMatchSource
            case .invalidTime: .contractInvalidTime
            case .missingEvidence: .contractMissingEvidence
            case .conflictingValueAtLocation: .contractConflictingValueAtLocation
            case .conflictingSourceMetadata: .contractConflictingSourceMetadata
            case .unknownOccurrence: .contractUnknownOccurrence
            case .unknownValue: .contractUnknownValue
            case .obsoleteMarkerNotFound: .contractObsoleteMarkerNotFound
            case .contentStillRetained: .contractContentStillRetained
            case .mismatchedAudit: .contractMismatchedAudit
            case .invalidState: .contractInvalidState
            case .invalidSnapshot: .contractInvalidSnapshot
            case .unsupportedSnapshotVersion: .contractUnsupportedSnapshotVersion
            }
        }
        if let error = error as? StorageError {
            return switch error {
            case .invalidPayload: .storageInvalidPayload
            case .invalidTime: .storageInvalidTime
            case .corruptProtectedState: .storageCorruptProtectedState
            case .stateChanged: .storageStateChanged
            default: .storageFailure
            }
        }
        if let error = error as? ProtectionError {
            return switch error {
            case .invalidEnvelope: .protectionInvalidEnvelope
            case .incorrectKey: .protectionIncorrectKey
            case .invalidPurpose: .protectionInvalidPurpose
            case .authenticationFailed: .protectionAuthenticationFailed
            case .cryptographyFailure: .protectionCryptographyFailure
            }
        }
        return switch error {
        case is ClaudeCollectionError, is CodexCollectionError, is CodexHistoryError, is CodexHistoryReadFailure: .collectionFailure
        case is DetectorFailure: .detectorFailure
        case is CaptureTransportError: .transportFailure
        case PipelineError.budgetExhausted: .pipelineBudgetExhausted
        default: .unexpected
        }
    }
}
