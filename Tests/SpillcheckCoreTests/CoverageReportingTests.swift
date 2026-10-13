import Foundation
import GRDB
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor ReportingBlockingCryptography: BackgroundStoreCryptography {
    nonisolated let manifest: ProtectionManifest
    private let delegate: BackgroundCryptography
    private var shouldBlock = false
    private var gate: CheckedContinuation<Void, Never>?

    init(_ delegate: BackgroundCryptography) { self.delegate = delegate; manifest = delegate.manifest }
    func blockNextCheckpointOpen() { shouldBlock = true }
    func isBlocked() -> Bool { gate != nil }
    func release() { gate?.resume(); gate = nil }

    func sealBackground(_ plaintext: Data, binding: PayloadBinding) async throws -> ProtectedPayload {
        try await delegate.sealBackground(plaintext, binding: binding)
    }
    func openBackground(_ payload: ProtectedPayload, binding: PayloadBinding) async throws -> Data {
        if shouldBlock && binding.kind == .sourceCheckpoint {
            shouldBlock = false
            await withCheckedContinuation { gate = $0 }
        }
        return try await delegate.openBackground(payload, binding: binding)
    }
    func revision(canonicalBytes: Data) async throws -> ContentRevision {
        try await delegate.revision(canonicalBytes: canonicalBytes)
    }
}

@Suite("Coverage reporting across bounded reads and restart")
struct CoverageReportingTests {
    private let profile = "SYNTHETIC_PRIVATE_REPORT_PROFILE"

    @Test func legacyExcludedOmissionCannotSuppressRequiredSamePositionEvent() throws {
        let now = Date()
        let scope = CollectionScope(provider: .codex, profileID: profile, interface: .standaloneCLI, path: .publicHistory)
        let reference = CoverageRecoveryReference(session: try SessionIdentity(provider: .codex,
            profileID: profile, sessionID: "synthetic-session"), locator: .upstreamItem,
            itemID: "mixed-input", contentTime: now, parserContract: "contract-v4")
        let required = CoverageGap(reason: .unsupportedContent, scope: scope, contentType: .userPrompt,
            operation: .liveRead, recovery: reference, isRequiredFormatFailure: true,
            diagnosticCode: .encryptedContentUnavailable)
        let media = CoverageGap(reason: .unsupportedContent, scope: scope, contentType: .userPrompt,
            operation: .liveRead, recovery: reference, diagnosticCode: .excludedBinaryContent, excludedContent: true)
        let event = StoredCoverageGapEvent(gap: required, observedAt: now)
        for state in [CoverageOmissionState.blocked, .recovered] {
            for omissionGap in [media, required] {
                let omission = CoverageOmission(id: UUID(), gap: omissionGap, firstObservedAt: now,
                    state: state, resolvedAt: state == .recovered ? now : nil)
                let report = CoverageReport(window: .init(start: now.addingTimeInterval(-60), end: now),
                    gapEvents: .init(items: [event], totalCount: 1), omissions: .init(items: [omission], totalCount: 1),
                    history: .init(items: [], totalCount: 0), queue: .init(count: 0, encryptedBytes: 0, claimedCount: 0, historicalCount: 0),
                    oldestPendingCaptureAt: nil)
                #expect(report.activeGapEvents.count == (omissionGap.requiresAnalysis ? 0 : 1))
            }
        }
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-report-\(UUID())")
    }

    private func packet(_ page: Int) throws -> CapturePacket {
        try CapturePacket(metadata: .init(agent: .codex, profileID: profile),
            eventJSON: JSONEncoder().encode(["page": page]))
    }

    private func finishPass(_ store: ProtectedStore, audit: HistoricalAuditContext, page: Int,
                            continues: Bool, unread: Bool, gaps: [CoverageGap], at time: Date) async throws {
        let permit = try #require(await store.processingPermit())
        let capture = try #require(try await store.nextPending(at: time, permit: permit))
        try await store.completeCapture(capture, continuation: continues ? packet(page + 1) : nil,
            historicalProgress: .init(audit: audit, bytesRead: 100, hasUnreadContent: unread),
            coverageGaps: gaps, permit: permit, at: time)
    }

    private func enqueue(_ store: ProtectedStore, audit: HistoricalAuditContext, at time: Date) async throws {
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(packet(0).body, capturedAt: time, permit: permit, at: time, historicalAudit: audit)
    }

    @Test func boundedPagesRejectClosedStoresAndInvalidIntervals() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
        let now = Date()
        for invalid in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity)] {
            await #expect(throws: StorageError.invalidTime) { try await store.historicalProgressPage(since: invalid) }
            await #expect(throws: StorageError.invalidTime) { try await store.coverageGapEvents(until: invalid) }
            await #expect(throws: StorageError.invalidTime) { try await store.coverageOmissionPage(since: invalid) }
        }
        await #expect(throws: StorageError.invalidTime) {
            try await store.historicalProgressPage(since: now, until: now.addingTimeInterval(-1))
        }
        await #expect(throws: StorageError.invalidTime) {
            try await store.coverageGapEvents(since: now, until: now.addingTimeInterval(-1))
        }
        await #expect(throws: StorageError.invalidTime) {
            try await store.coverageOmissionPage(since: now, until: now.addingTimeInterval(-1))
        }
        try await store.close()
        await #expect(throws: StorageError.databaseUnavailable) { try await store.historicalProgressPage() }
    }

    @Test func exactDroppedWorkRecoveryAndSuccessfulReadEvidenceSurviveRestart() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let scope = CollectionScope(provider: .codex, profileID: profile, interface: .t3, path: .versionedTranscript)
        let session = try SessionIdentity(provider: .codex, profileID: profile, sessionID: "PRIVATE_WORK_SESSION")
        let descriptor = CoverageSourceRetryDescriptor(scope: scope, session: session, sourceDocumentID: UUID(),
            sourceURL: URL(fileURLWithPath: "/private/PRIVATE_AUTHORIZED_TRANSCRIPT"))
        let context = CollectionWorkContext(scope: scope, operation: .historicalRead,
            audit: .init(auditID: audit.id, provider: .codex, profileID: profile), retry: descriptor,
            readerVersion: "test-reader", hostVersion: "test-host")
        let packet = try CapturePacket(metadata: .init(agent: .codex, interface: .t3, profileID: profile),
            eventJSON: Data("{\"kind\":\"fixture\"}".utf8))
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto, limits: .init(maxRetryCount: 0))
        let permit = try #require(await store.processingPermit())
        let lostID = UUID()
        _ = try await store.enqueue(packet.body, id: lostID, capturedAt: now, permit: permit, at: now,
            historicalAudit: audit, workContext: context)
        #expect(try await store.collectionWork(id: lostID)?.state == .queued)
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        #expect(try await store.collectionWork(id: lostID)?.state == .processing)
        try await store.retry(capture, reason: .sourceUnavailable, at: now, permit: permit)
        let failed = try await store.coverageReport(endingAt: now)
        #expect(failed.work.items.first?.state == .terminal)
        #expect(failed.omissionStateCounts[.retryable] == 1)
        #expect(failed.unresolvedOmissions.first?.gap.scope?.path == .versionedTranscript)
        #expect(failed.gapEvents.items.first?.workID == lostID)
        #expect(failed.gapEvents.items.first?.gap.interval == DateInterval(start: audit.start, end: audit.end))
        #expect(failed.successfulReads.items.isEmpty)
        try await store.close()

        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let newPermit = try #require(await reopened.processingPermit())
        let later = now.addingTimeInterval(10)
        #expect(try await reopened.collectionWork(id: lostID)?.context.retry == descriptor)
        // A successful sibling read does not prove the lost work was reread.
        _ = try await reopened.enqueue(packet.body, capturedAt: later, permit: newPermit, at: later,
            historicalAudit: audit, workContext: context)
        let sibling = try #require(try await reopened.nextPending(at: later, permit: newPermit))
        try await reopened.completeCapture(sibling, successfulRead: true, observedProducerVersions: ["test-producer"],
            permit: newPermit, at: later)
        #expect(try await reopened.collectionWork(id: lostID)?.state == .terminal)
        #expect(try await reopened.coverageOmissions().count == 1)
        let freshAudit = try HistoricalAuditContext(reason: .restart, endingAt: later)
        let freshContext = CollectionWorkContext(scope: scope, operation: .historicalRead,
            audit: .init(auditID: freshAudit.id, provider: .codex, profileID: profile), retry: descriptor)
        _ = try await reopened.enqueue(packet.body, capturedAt: later, permit: newPermit, at: later,
            historicalAudit: freshAudit, workContext: freshContext, recoveryOf: lostID)
        let narrower = try #require(try await reopened.nextPending(at: later, permit: newPermit))
        try await reopened.completeCapture(narrower, successfulRead: true, permit: newPermit, at: later)
        #expect(try await reopened.collectionWork(id: lostID)?.state == .terminal)
        #expect(try await reopened.coverageOmissions().count == 1)
        let retryID = UUID()
        _ = try await reopened.enqueue(packet.body, id: retryID, capturedAt: later, permit: newPermit, at: later,
            historicalAudit: audit, workContext: context, recoveryOf: lostID)
        let retry = try #require(try await reopened.nextPending(at: later, permit: newPermit))
        try await reopened.completeCapture(retry,
            historicalProgress: .init(audit: audit, bytesRead: 17, hasUnreadContent: false),
            successfulRead: true, observedProducerVersions: ["test-producer"], permit: newPermit, at: later)
        let report = try await reopened.coverageReport(endingAt: later, limit: 1)
        #expect(report.work.totalCount == 4)
        #expect(report.work.isTruncated)
        #expect(report.omissionStateCounts[.recovered] == 1)
        #expect(try await reopened.collectionWork(id: lostID)?.state == .recovered)
        #expect(report.successfulReads.items.first?.succeededAt == later)
        #expect(report.successfulReads.items.first?.producerVersions == ["test-producer"])
        #expect(report.successfulReads.items.first?.scope.path == .versionedTranscript)
        try await reopened.close()
        let again = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let persisted = try await again.coverageReport(endingAt: later)
        #expect(persisted.successfulReads.items.first?.readerVersion == "test-reader")
        #expect(persisted.successfulReads.items.first?.hostVersion == "test-host")
        #expect(persisted.activeGapEvents.isEmpty)
        try await again.close()
        let bytes = try Data(contentsOf: directory.appendingPathComponent(ProtectedStore.databaseFilename))
        for marker in [profile, "PRIVATE_WORK_SESSION", "PRIVATE_AUTHORIZED_TRANSCRIPT"] {
            #expect(bytes.range(of: Data(marker.utf8)) == nil)
        }
    }

    @Test func admissionAndExpiredWorkAreDurableWithoutClaimingSourceLoss() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let scope = CollectionScope(provider: .codex, profileID: profile, interface: .standaloneCLI, path: .publicHistory)
        let context = CollectionWorkContext(scope: scope, operation: .historicalRead,
            audit: .init(auditID: audit.id, provider: .codex, profileID: profile))
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto, limits: .init(maxQueueAge: 5))
        let permit = try #require(await store.processingPermit())
        for _ in 0..<3 {
            _ = try await store.enqueue(packet(0).body, capturedAt: now, permit: permit, at: now,
                historicalAudit: audit, workContext: context)
        }
        let admitted = try await store.coverageReport(endingAt: now, limit: 1)
        #expect(admitted.history.items.isEmpty)
        #expect(admitted.work.items.first?.state == .queued)
        #expect(admitted.work.totalCount == 3)
        try await store.close()
        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto, limits: .init(maxQueueAge: 5))
        let expiredAt = now.addingTimeInterval(6)
        #expect(try await reopened.maintainQueue(at: expiredAt) == 3)
        let expired = try await reopened.coverageReport(endingAt: expiredAt, limit: 1)
        #expect(expired.queue.count == 0)
        #expect(expired.work.items.first?.state == .terminal)
        #expect(expired.omissions.totalCount == 3)
        #expect(expired.omissionStateCounts[.blocked] == 3)
        #expect(expired.omissionStateCounts[.unrecoverable] == nil)
        try await reopened.close()
    }

    @Test func stalledQueueRetryKeepsOneCaptureAndFailedCommitCannotPublishReadEvidence() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let context = CollectionWorkContext(scope: .init(provider: .codex, profileID: profile,
            interface: .standaloneCLI, path: .publicHistory), operation: .liveRead, trigger: .activePoll)
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto, failureInjector: {
            if $0 == .beforeProcessingCommit { throw StorageError.injectedFailure }
        })
        let permit = try #require(await store.processingPermit())
        let id = UUID()
        _ = try await store.enqueue(packet(0).body, id: id, capturedAt: now, permit: permit, at: now, workContext: context)
        let first = try #require(try await store.nextPending(at: now, permit: permit))
        try await store.retry(first, reason: .sourceUnavailable, at: now, permit: permit)
        #expect(try await store.collectionWork(id: id)?.state == .stalled)
        #expect(try await store.nextPending(at: now, permit: permit) == nil)
        #expect(try await store.retryQueuedWork(id: id, permit: permit, at: now))
        #expect(try await store.queueStatistics().count == 1)
        let retry = try #require(try await store.nextPending(at: now, permit: permit))
        #expect(retry.id == id)
        #expect(try await store.collectionWork(id: id)?.context.trigger == .activePoll)
        await #expect(throws: StorageError.injectedFailure) {
            try await store.completeCapture(retry, successfulRead: true, permit: permit, at: now)
        }
        let report = try await store.coverageReport(endingAt: now)
        #expect(report.work.items.first?.state == .processing)
        #expect(report.successfulReads.items.isEmpty)
        #expect(report.queue.count == 1)
        try await store.close()
    }

    @Test func completedNoOpWorkIsBoundedWithoutInventingSuccessfulReads() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let context = CollectionWorkContext(scope: .init(provider: .codex, profileID: profile,
            interface: .standaloneCLI, path: .publicHistory), operation: .liveRead)
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto,
            limits: .init(maxSuccessfulWorkRecords: 3))
        let permit = try #require(await store.processingPermit())
        for index in 0..<8 {
            let time = now.addingTimeInterval(Double(index))
            _ = try await store.enqueue(packet(index).body, capturedAt: time, permit: permit, at: time, workContext: context)
            let capture = try #require(try await store.nextPending(at: time, permit: permit))
            try await store.completeCapture(capture, permit: permit, at: time)
        }
        let report = try await store.coverageReport(endingAt: now.addingTimeInterval(8))
        #expect(report.work.totalCount == 3)
        #expect(report.work.items.allSatisfy { $0.state == .completed })
        #expect(report.successfulReads.items.isEmpty)
        #expect(report.queue.count == 0)
        try await store.close()
    }

    @Test func unknownDocumentSelectionsKeepSameSessionFilesSeparate() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let now = Date(), session = try SessionIdentity(provider: .claudeCode, profileID: profile, sessionID: "private-parent")
        let scope = CollectionScope(provider: .claudeCode, profileID: profile, interface: .standaloneCLI, path: .versionedTranscript)
        let first = CoverageRecoveryReference(session: session, parserContract: "selection-v1",
            sourceURL: URL(fileURLWithPath: "/private/first.jsonl"))
        let second = CoverageRecoveryReference(session: session, parserContract: "selection-v1",
            sourceURL: URL(fileURLWithPath: "/private/second.jsonl"))
        for reference in [first, second] {
            try await store.recordCoverageGap(.init(reason: .sourceUnavailable, scope: scope, recovery: reference), at: now)
        }
        #expect(try await store.coverageOmissions().count == 2)
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(packet(0).body, capturedAt: now, permit: permit, at: now)
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        try await store.completeCapture(capture, recoveredReferences: [first], permit: permit, at: now)
        let remaining = try await store.coverageOmissions()
        #expect(remaining.count == 1)
        #expect(remaining.first?.gap.recovery?.sourceURL == second.sourceURL)
        try await store.close()
    }

    @Test func severalContinuationsRecoverOnlyTheirBacklogAfterRestart() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        try await enqueue(store, audit: audit, at: now)
        for page in 0..<3 {
            let time = now.addingTimeInterval(Double(page * 10))
            try await finishPass(store, audit: audit, page: page, continues: true, unread: true,
                gaps: [.init(reason: .budgetExhausted)], at: time)
            let report = try await store.coverageReport(endingAt: time)
            #expect(report.activeGapEvents.count == page + 1)
            #expect(report.history.items.first?.completedAt == nil)
            #expect(report.queue.historicalCount == 1)
            #expect(report.oldestPendingCaptureAt == time)
        }
        try await store.close()

        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let finishedAt = now.addingTimeInterval(30)
        try await finishPass(reopened, audit: audit, page: 3, continues: false, unread: false, gaps: [], at: finishedAt)
        let report = try await reopened.coverageReport(endingAt: finishedAt)
        #expect(report.gapEvents.totalCount == 3)
        #expect(report.gapEvents.items.allSatisfy { $0.audit?.auditID == audit.id && $0.audit?.profileID == profile })
        #expect(report.activeGapEvents.isEmpty)
        #expect(report.history.items.first?.completedAt == finishedAt)
        #expect(report.history.items.first?.lastAttemptedAt == finishedAt)
        #expect(report.history.items.first?.progress.audit.end == now)
        #expect(report.history.items.first?.progress.bytesRead == 400)
        #expect(report.queue.count == 0)
        #expect(report.oldestPendingCaptureAt == nil)
        try await reopened.close()

        let secondRestart = try await ProtectedStore.open(at: directory, cryptography: crypto)
        #expect(try await secondRestart.coverageReport(endingAt: finishedAt).activeGapEvents.isEmpty)
        try await secondRestart.close()
        let bytes = try Data(contentsOf: directory.appendingPathComponent(ProtectedStore.databaseFilename))
        #expect(bytes.range(of: Data(profile.utf8)) == nil)
        #expect(bytes.range(of: Data(audit.id.uuidString.utf8)) == nil)
    }

    @Test func terminalUnreadAndUnscopedEventsCannotBeSettledByAnotherSuccessfulPass() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        try await store.recordCoverageGap(.init(reason: .budgetExhausted), at: now)
        try await enqueue(store, audit: audit, at: now)
        try await finishPass(store, audit: audit, page: 0, continues: false, unread: true,
            gaps: [.init(reason: .budgetExhausted), .init(reason: .sourceUnavailable)], at: now)
        #expect(try await store.coverageReport(endingAt: now).history.items.first?.completedAt == nil)
        // Even deliberately reusing an audit cannot prove recovery of a terminal loss event.
        let later = now.addingTimeInterval(30)
        try await enqueue(store, audit: audit, at: later)
        try await finishPass(store, audit: audit, page: 1, continues: false, unread: false, gaps: [], at: later)
        let report = try await store.coverageReport(endingAt: later)
        #expect(report.activeGapEvents.count == 3)
        #expect(report.activeGapEvents.allSatisfy { !$0.isIntermediateBacklog })
        #expect(report.history.items.first?.completedAt == later)
        try await store.close()
    }

    @Test func reportsUseTheDisplayedCalendarWindowAndExposeEveryQueryBound() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 12)))
        let window = AnalyzedActivity.recentWindow(endingAt: now, calendar: calendar)
        for time in [window.start.addingTimeInterval(-1), window.start, now.addingTimeInterval(-2 * 86_400), now,
                     now.addingTimeInterval(1)] {
            try await store.recordCoverageGap(.init(reason: .deliveryUncertain), at: time)
        }
        let scope = CollectionScope(provider: .codex, profileID: profile, interface: .standaloneCLI, path: .publicHistory)
        let session = try SessionIdentity(provider: .codex, profileID: profile, sessionID: "synthetic-private-session")
        for item in 0..<3 {
            let reference = CoverageRecoveryReference(session: session, locator: .upstreamItem, itemID: "item-\(item)",
                contentTime: now, parserContract: "test-v1")
            try await store.recordCoverageGap(.init(reason: .malformedSource, scope: scope,
                contentType: .toolOutput, recovery: reference, isRequiredFormatFailure: true), at: now)
            let audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
            try await enqueue(store, audit: audit, at: now)
            try await finishPass(store, audit: audit, page: 0, continues: false, unread: false, gaps: [], at: now)
        }
        let report = try await store.coverageReport(endingAt: now, limit: 1, calendar: calendar)
        #expect(report.window == window)
        #expect(report.gapEvents.totalCount == 6)
        #expect(report.omissions.totalCount == 3)
        #expect(report.history.totalCount == 3)
        #expect(report.gapEvents.items.count == 1)
        #expect(report.omissions.items.count == 1)
        #expect(report.history.items.count == 1)
        #expect(report.gapEvents.isTruncated && report.omissions.isTruncated && report.history.isTruncated)
        #expect(report.isTruncated)
        try await store.close()
    }

    @Test func recoveredOmissionKeepsItsStateAndTimestampWithoutRevivingTheOldEvent() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let earlier = now.addingTimeInterval(-2 * 86_400)
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let reference = CoverageRecoveryReference(session: try SessionIdentity(provider: .codex, profileID: profile,
            sessionID: "private-session"), locator: .upstreamItem, itemID: "private-item", contentTime: earlier,
            parserContract: "test-v1")
        let gap = CoverageGap(reason: .malformedSource,
            scope: .init(provider: .codex, profileID: profile, interface: .t3, path: .publicHistory),
            contentType: .toolOutput, recovery: reference, isRequiredFormatFailure: true)
        try await store.recordCoverageGap(gap, at: earlier)
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(packet(0).body, capturedAt: now, permit: permit, at: now)
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        try await store.completeCapture(capture, recoveredReferences: [reference], permit: permit, at: now)
        let report = try await store.coverageReport(endingAt: now)
        let omission = try #require(report.omissions.items.first)
        #expect(omission.state == .recovered)
        #expect(omission.firstObservedAt == earlier)
        #expect(omission.resolvedAt == now)
        #expect(report.unresolvedOmissions.isEmpty)
        #expect(report.gapEvents.totalCount == 1)
        #expect(report.activeGapEvents.isEmpty)
        try await store.close()
    }

    @Test func recentEventRemainsVisibleWhenItsOmissionContentFallsOutsideTheWindow() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let reference = CoverageRecoveryReference(session: try SessionIdentity(provider: .codex, profileID: profile,
            sessionID: "synthetic-old-session"), locator: .upstreamItem, itemID: "synthetic-old-item",
            contentTime: now.addingTimeInterval(-8 * 86_400), parserContract: "test-v1")
        let gap = CoverageGap(reason: .malformedSource,
            scope: .init(provider: .codex, profileID: profile, interface: .t3, path: .publicHistory),
            contentType: .toolOutput, recovery: reference, isRequiredFormatFailure: true)
        try await store.recordCoverageGap(gap, at: now)
        let report = try await store.coverageReport(endingAt: now)
        #expect(!report.isTruncated)
        #expect(report.gapEvents.totalCount == 1)
        #expect(report.omissions.totalCount == 0)
        #expect(report.activeGapEvents.map(\.gap) == [gap])
        try await store.close()
    }

    @Test func preEnvelopeGapRemainsQueryableWithoutFabricatingAuditRecovery() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        try await store.close()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), id = UUID()
        let gap = CoverageGap(reason: .budgetExhausted)
        let binding = PayloadBinding(reference: .init(id: id), ownerID: id, kind: .sourceCheckpoint)
        let payload = try await crypto.sealBackground(JSONEncoder().encode(gap), binding: binding)
        let bytes = try payload.encoded()
        let database = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path)
        try await database.write { db in
            try db.execute(sql: "INSERT INTO coverage_gaps (id, created_at, encoded) VALUES (?, ?, ?)",
                arguments: [id.uuidString, now.timeIntervalSince1970, bytes])
        }
        try database.close()
        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let report = try await reopened.coverageReport(endingAt: now)
        let event = try #require(report.activeGapEvents.first)
        #expect(event.id == id)
        #expect(event.gap == gap)
        #expect(event.observedAt == now)
        #expect(event.audit == nil)
        #expect(!event.isIntermediateBacklog)
        try await reopened.close()
    }

    @Test func failedAttemptIsDurableAndCanLaterCompleteWithoutClaimingAnEarlierSuccess() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        try await enqueue(store, audit: audit, at: now)
        let permit = try #require(await store.processingPermit())
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        try await store.retry(capture, reason: .sourceUnavailable, at: now, permit: permit)
        let report = try await store.coverageReport(endingAt: now)
        #expect(report.history.items.first?.lastAttemptedAt == now)
        #expect(report.history.items.first?.completedAt == nil)
        #expect(report.history.items.first?.progress.hasUnreadContent == true)
        #expect(report.history.items.first?.continuationQueued == true)
        try await store.close()

        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let later = now.addingTimeInterval(30)
        try await finishPass(reopened, audit: audit, page: 0, continues: false, unread: false, gaps: [], at: later)
        let recovered = try await reopened.coverageReport(endingAt: later)
        #expect(recovered.history.items.first?.lastAttemptedAt == later)
        #expect(recovered.history.items.first?.completedAt == later)
        #expect(recovered.history.items.first?.progress.bytesRead == 100)
        #expect(recovered.activeGapEvents.isEmpty)
        try await reopened.close()
    }

    @Test func exhaustedFailedAttemptRecordsTerminalLossAndAuditIdentity() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto, limits: .init(maxRetryCount: 0))
        try await enqueue(store, audit: audit, at: now)
        let permit = try #require(await store.processingPermit())
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        try await store.retry(capture, reason: .sourceUnavailable, at: now, permit: permit)
        let report = try await store.coverageReport(endingAt: now)
        #expect(report.queue.count == 0)
        #expect(report.history.items.first?.lastAttemptedAt == now)
        #expect(report.history.items.first?.completedAt == nil)
        #expect(report.history.items.first?.continuationQueued == false)
        #expect(report.unresolvedOmissions.first?.state == .blocked)
        #expect(report.gapEvents.items.first?.audit?.auditID == audit.id)
        #expect(report.gapEvents.items.first?.isIntermediateBacklog == false)
        #expect(report.activeGapEvents.isEmpty)
        try await store.close()
    }

    @Test func successfulSiblingProfileOrOlderCompletionNeverSettlesAnAuditEvent() throws {
        let now = Date(), audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let event = StoredCoverageGapEvent(gap: .init(reason: .budgetExhausted), observedAt: now,
            audit: .init(auditID: audit.id, provider: .codex, profileID: profile), isIntermediateBacklog: true)
        for (recordProfile, completedAt) in [("another-profile", now), (profile, now.addingTimeInterval(-1))] {
            let history = StoredHistoricalProgress(provider: .codex, profileID: recordProfile,
                progress: .init(audit: audit, bytesRead: 10, hasUnreadContent: false),
                lastAttemptedAt: completedAt, completedAt: completedAt, continuationQueued: false)
            let report = CoverageReport(window: .init(start: audit.start, end: now),
                gapEvents: .init(items: [event], totalCount: 1), omissions: .init(items: [], totalCount: 0),
                history: .init(items: [history], totalCount: 1),
                queue: .init(count: 0, encryptedBytes: 0, claimedCount: 0, historicalCount: 0), oldestPendingCaptureAt: nil)
            #expect(!report.hasRecoveredBacklog(event))
            #expect(report.activeGapEvents.count == 1)
        }
    }

    @Test func reopeningOneOriginalSourceNeverRecoversItsUnreadSiblingOrNativeRows() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let firstID = UUID(), secondID = UUID()
        let first = CoverageRecoveryReference(parserContract: "file-access-v1", sourceDocumentID: firstID)
        let second = CoverageRecoveryReference(parserContract: "file-access-v1", sourceDocumentID: secondID)
        let row = CoverageRecoveryReference(locator: .transcriptByteOffset(documentID: firstID, byteOffset: 0),
            contentTime: now, parserContract: "parser-v1")
        let scope = CollectionScope(provider: .claudeCode, profileID: profile, interface: .standaloneCLI, path: .versionedTranscript)
        for reference in [first, second] {
            try await store.recordCoverageGap(.init(reason: .sourceUnavailable, scope: scope,
                operation: .historicalRead, recovery: reference), at: now)
        }
        try await store.recordCoverageGap(.init(reason: .malformedSource, scope: scope,
            contentType: .toolOutput, recovery: row), at: now)
        #expect(try await store.recoverableOmissions(documentID: firstID, at: now).count == 2)
        #expect(!first.identifiesSameLocation(as: second))
        #expect(!first.identifiesSameLocation(as: row))
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(packet(0).body, capturedAt: now, permit: permit, at: now)
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        try await store.completeCapture(capture, recoveredReferences: [first], permit: permit, at: now)
        let remaining = try await store.coverageOmissions()
        #expect(remaining.count == 2)
        #expect(remaining.contains { $0.gap.recovery?.sourceDocumentID == secondID })
        #expect(remaining.contains { $0.gap.recovery?.locator == row.locator })
        #expect(try await store.recoverableOmissions(documentID: firstID, at: now).count == 1)
        try await store.close()
        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        #expect(try await reopened.coverageOmissions(includeRecovered: true).first {
            $0.gap.recovery?.sourceDocumentID == firstID
        }?.state == .recovered)
        try await reopened.close()
    }

    @Test func concurrentCompletionCannotMixAnOlderGapPageWithANewerEmptyQueue() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let blocking = ReportingBlockingCryptography(crypto)
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let store = try await ProtectedStore.open(at: directory, cryptography: blocking)
        try await enqueue(store, audit: audit, at: now)
        try await finishPass(store, audit: audit, page: 0, continues: true, unread: true,
            gaps: [.init(reason: .budgetExhausted)], at: now)
        await blocking.blockNextCheckpointOpen()
        let reportTask = Task { try await store.coverageReport(endingAt: now.addingTimeInterval(30)) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await blocking.isBlocked()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await blocking.isBlocked())
        try await finishPass(store, audit: audit, page: 1, continues: false, unread: true,
            gaps: [.init(reason: .sourceUnavailable)], at: now.addingTimeInterval(10))
        await blocking.release()
        let original = try await reportTask.value
        #expect(original.gapEvents.totalCount == 1)
        #expect(original.queue.historicalCount == 1)
        #expect(original.history.items.first?.progress.bytesRead == 100)
        #expect(original.history.items.first?.lastAttemptedAt == now)
        let current = try await store.coverageReport(endingAt: now.addingTimeInterval(30))
        #expect(current.gapEvents.totalCount == 2)
        #expect(current.queue.count == 0)
        #expect(current.history.items.first?.progress.bytesRead == 200)
        #expect(current.history.items.first?.progress.hasUnreadContent == true)
        try await store.close()
    }
}
