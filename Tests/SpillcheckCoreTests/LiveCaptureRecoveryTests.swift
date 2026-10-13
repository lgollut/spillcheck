import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

@Suite("Frozen live capture recovery")
struct LiveCaptureRecoveryTests {
    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let crypto: BackgroundCryptography
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let route: CollectionCaptureRoute
        let packet: CapturePacket
        let context: CollectionWorkContext
        init() throws {
            crypto = try BackgroundCryptography.ephemeralForTesting()
            route = CollectionCaptureRoute(scope: .init(provider: .codex, profileID: "fake-recovery", interface: .t3, path: .publicHistory))
            packet = try CapturePacket(metadata: .init(agent: .codex, interface: .t3, profileID: "fake-recovery"),
                eventJSON: Data("{\"hook_event_name\":\"SpillcheckHistoryPoll\",\"session_id\":\"11111111-1111-4111-8111-111111111111\"}".utf8))
            context = try route.context(for: packet, trigger: .activePoll)
        }
        func open(retaining: Int = 16) async throws -> ProtectedStore {
            try await ProtectedStore.open(at: directory, cryptography: crypto,
                limits: .init(maxRetryCount: 0, maxSuccessfulWorkRecords: retaining))
        }
        func loss(in store: ProtectedStore, scopeAge: TimeInterval? = 60, offset: TimeInterval = 0) async throws -> UUID {
            let id = UUID(), time = now.addingTimeInterval(offset)
            let permit = try #require(await store.processingPermit())
            let scope = try scopeAge.map { try LiveCaptureScope(startedAt: time.addingTimeInterval(-$0)) }
            _ = try await store.enqueue(packet.body, id: id, capturedAt: time, permit: permit, at: time,
                scope: scope, workContext: context)
            let captured = try #require(try await store.nextPending(at: time, permit: permit))
            #expect(captured.id == id)
            try await store.retry(captured, reason: .sourceUnavailable, at: time, permit: permit)
            return id
        }
        func read(in store: ProtectedStore, target: UUID?, end: Date, at time: Date,
                  successful: Bool = true, unread: Bool = false) async throws -> UUID {
            let permit = try #require(await store.processingPermit()), id = UUID()
            let audit = try HistoricalAuditContext(reason: .resume, endingAt: end)
            let context = try route.context(for: packet, trigger: .historyRequest, audit: audit, retry: context.retry)
            _ = try await store.enqueue(packet.body, id: id, capturedAt: time, permit: permit, at: time,
                historicalAudit: audit, workContext: context, recoveryOf: target)
            let capture = try #require(try await store.nextPending(at: time, permit: permit))
            #expect(capture.id == id)
            try await store.completeCapture(capture, historicalProgress: .init(audit: audit, bytesRead: 1, hasUnreadContent: unread),
                successfulRead: successful, permit: permit, at: time)
            return id
        }
    }

    @Test func liveAdmissionFreezesOriginalHistoricalAndLiveResponsibility() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let permit = try #require(await store.processingPermit())
        let time = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let scope = try LiveCaptureScope(startedAt: time.addingTimeInterval(-60))
        let route = CollectionCaptureRoute(scope: .init(provider: .codex, profileID: "fake-recovery",
            interface: .t3, path: .publicHistory))
        let packet = try CapturePacket(metadata: .init(agent: .codex, interface: .t3, profileID: "fake-recovery"),
            eventJSON: Data("{\"hook_event_name\":\"SpillcheckHistoryPoll\",\"session_id\":\"11111111-1111-4111-8111-111111111111\"}".utf8))
        let context = try route.context(for: packet, trigger: .activePoll)
        let id = UUID()
        _ = try await store.enqueue(packet.body, id: id, capturedAt: time, permit: permit, at: time,
            scope: scope, workContext: context)
        let work = try #require(try await store.collectionWork(id: id))
        #expect(work.context.auditWindow == DateInterval(start: scope.startedAt.addingTimeInterval(-HistoricalAuditContext.lookback), end: time))
        try await store.close()
    }

    @Test func twoCertifiedIntervalsRecoverOnlyExactTargetAcrossRestartAndPruning() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try await f.open(retaining: 1)
        let unrelated = try await f.loss(in: store)
        let target = try await f.loss(in: store, offset: 1)
        let time = f.now.addingTimeInterval(5)
        let ends = try await store.remainingRecoveryAuditEnds(for: target, at: time)
        #expect(ends.count == 2)
        // A successful later moving window is not linked to the loss and cannot certify it.
        _ = try await f.read(in: store, target: nil, end: time, at: time)
        #expect(try await store.remainingRecoveryAuditEnds(for: target, at: time) == ends)
        let first = try await f.read(in: store, target: target, end: ends[0], at: time)
        let certified = try #require(try await store.collectionWork(id: first)?.recoveryCertificate)
        #expect(certified.targetWorkID == target)
        #expect(try await store.collectionWork(id: target)?.state == .terminal)
        for _ in 0..<3 { _ = try await f.read(in: store, target: nil, end: time, at: time) }
        #expect(try await store.collectionWork(id: first)?.recoveryCertificate == certified)
        try await store.close()

        let reopened = try await f.open(retaining: 1)
        let remaining = try await reopened.remainingRecoveryAuditEnds(for: target, at: time)
        #expect(remaining == [ends[1]])
        _ = try await f.read(in: reopened, target: target, end: remaining[0], at: time)
        #expect(try await reopened.collectionWork(id: target)?.state == .recovered)
        #expect(try await reopened.collectionWork(id: unrelated)?.state == .terminal)
        let report = try await reopened.coverageReport(endingAt: time)
        #expect(report.omissionStateCounts[.recovered] == 1)
        #expect(report.omissionStateCounts[.retryable] == 1)
        #expect(try await reopened.remainingRecoveryAuditEnds(for: target, at: time).isEmpty)
        try await reopened.close()

        let again = try await f.open()
        #expect(try await again.remainingRecoveryAuditEnds(for: target, at: time).isEmpty)
        #expect(try await again.collectionWork(id: unrelated)?.state == .terminal)
        try await again.close()
    }

    @Test func noOpPartialAndInsufficientReadsDoNotRecoverTarget() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try await f.open()
        let target = try await f.loss(in: store)
        let time = f.now.addingTimeInterval(5)
        let ends = try await store.remainingRecoveryAuditEnds(for: target, at: time)
        let noop = try await f.read(in: store, target: target, end: ends[0], at: time, successful: false)
        #expect(try await store.collectionWork(id: noop)?.recoveryCertificate == nil)
        let partial = try await f.read(in: store, target: target, end: ends[0], at: time, unread: true)
        #expect(try await store.collectionWork(id: partial)?.recoveryCertificate == nil)
        #expect(try await store.remainingRecoveryAuditEnds(for: target, at: time) == ends)
        let late = try await f.read(in: store, target: target, end: time, at: time)
        #expect(try await store.collectionWork(id: late)?.recoveryCertificate != nil)
        #expect(try await store.collectionWork(id: target)?.state == .terminal)
        #expect(try await store.remainingRecoveryAuditEnds(for: target, at: time).count == 1)
        try await store.close()
    }

    @Test func unknownLegacyAndExpiredTargetsRemainHonest() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try await f.open()
        let legacy = try await f.loss(in: store, scopeAge: nil)
        await #expect(throws: StorageError.invalidPayload) {
            try await store.remainingRecoveryAuditEnds(for: UUID(), at: f.now)
        }
        await #expect(throws: StorageError.invalidPayload) {
            try await store.remainingRecoveryAuditEnds(for: legacy, at: f.now)
        }
        let read = try await f.read(in: store, target: legacy, end: f.now, at: f.now)
        #expect(try await store.collectionWork(id: read)?.recoveryCertificate == nil)
        #expect(try await store.collectionWork(id: legacy)?.state == .terminal)
        let target = try await f.loss(in: store, offset: 1)
        let expired = f.now.addingTimeInterval(HistoricalAuditContext.lookback + 2)
        await #expect(throws: StorageError.invalidTime) {
            try await store.remainingRecoveryAuditEnds(for: target, at: expired)
        }
        let late = try await f.read(in: store, target: target, end: expired, at: expired)
        #expect(try await store.collectionWork(id: late)?.recoveryCertificate == nil)
        #expect(try await store.collectionWork(id: target)?.state == .terminal)
        try await store.close()
    }

    @Test func staleMonitoringScopeIsBoundedByAbsoluteAnalysisHorizon() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try await f.open()
        let target = try await f.loss(in: store, scopeAge: 30 * 24 * 60 * 60)
        let work = try #require(try await store.collectionWork(id: target))
        #expect(work.context.auditWindow?.duration == HistoricalAuditContext.analysisHorizon)
        #expect(try await store.remainingRecoveryAuditEnds(for: target, at: f.now).count == 2)
        try await store.close()
    }

    @Test func wrongSourceCannotLinkRecoveryAndOldRowsDecodeWithoutCertificate() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try await f.open()
        let target = try await f.loss(in: store)
        let permit = try #require(await store.processingPermit())
        let audit = try HistoricalAuditContext(reason: .resume, endingAt: f.now)
        let other = try SessionIdentity(provider: .codex, profileID: "fake-recovery", sessionID: "other-session")
        let retry = CoverageSourceRetryDescriptor(scope: f.route.scope, session: other)
        let context = try f.route.context(for: f.packet, trigger: .historyRequest, audit: audit, retry: retry)
        await #expect(throws: StorageError.invalidPayload) {
            try await store.enqueue(f.packet.body, capturedAt: f.now, permit: permit, at: f.now,
                historicalAudit: audit, workContext: context, recoveryOf: target)
        }
        let original = try #require(try await store.collectionWork(id: target))
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        encoded.removeValue(forKey: "recoveryOf"); encoded.removeValue(forKey: "recoveryCertificate")
        let old = try JSONDecoder().decode(StoredCollectionWork.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(old.recoveryOf == nil && old.recoveryCertificate == nil)
        try await store.close()
    }

    @Test func continuationCannotForgetEarlierFailedReadOrRequiredGap() async throws {
        for mode in ["failed-read", "required-gap", "clean-budget"] {
            let f = try Fixture()
            defer { try? FileManager.default.removeItem(at: f.directory) }
            let store = try await f.open()
            let target = try await f.loss(in: store, scopeAge: 0)
            let audit = try HistoricalAuditContext(reason: .resume, endingAt: f.now)
            let permit = try #require(await store.processingPermit())
            let context = try f.route.context(for: f.packet, trigger: .historyRequest, audit: audit, retry: f.context.retry)
            _ = try await store.enqueue(f.packet.body, capturedAt: f.now, permit: permit, at: f.now,
                historicalAudit: audit, workContext: context, recoveryOf: target)
            let first = try #require(try await store.nextPending(at: f.now, permit: permit))
            let gap: CoverageGap = mode == "required-gap"
                ? .init(reason: .unsupportedContent, isRequiredFormatFailure: true)
                : .init(reason: .budgetExhausted)
            try await store.completeCapture(first, continuation: f.packet,
                historicalProgress: .init(audit: audit, bytesRead: 1, hasUnreadContent: true), coverageGaps: [gap],
                successfulRead: mode == "clean-budget", permit: permit, at: f.now)
            #expect(try await store.collectionWork(id: first.id)?.recoveryCertificate == nil)
            try await store.close()

            let reopened = try await f.open()
            let nextPermit = try #require(await reopened.processingPermit())
            let last = try #require(try await reopened.nextPending(at: f.now, permit: nextPermit))
            try await reopened.completeCapture(last,
                historicalProgress: .init(audit: audit, bytesRead: 1, hasUnreadContent: false),
                successfulRead: true, permit: nextPermit, at: f.now)
            let recovered = mode == "clean-budget"
            #expect((try await reopened.collectionWork(id: target)?.state == .recovered) == recovered)
            #expect((try await reopened.collectionWork(id: last.id)?.recoveryCertificate != nil) == recovered)
            try await reopened.close()
        }
    }

    @Test func exactRetryQueriesIgnoreMoreThanOneThousandUnrelatedCompletedRows() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try await f.open(retaining: 2048)
        let target = try await f.loss(in: store)
        let permit = try #require(await store.processingPermit())
        for index in 0..<1005 {
            let time = f.now.addingTimeInterval(Double(index + 1) / 1000)
            _ = try await store.enqueue(f.packet.body, capturedAt: time, permit: permit, at: time, workContext: f.context)
            let capture = try #require(try await store.nextPending(at: time, permit: permit))
            try await store.completeCapture(capture, permit: permit, at: time)
        }
        let time = f.now.addingTimeInterval(2)
        let report = try await store.coverageReport(endingAt: time)
        #expect(report.work.isTruncated)
        #expect(!report.work.items.contains { $0.id == target })
        let retry = try #require(f.context.retry)
        #expect(try await store.retryableCollectionWork(for: retry).map(\.id) == [target])
        let ends = try await store.remainingRecoveryAuditEnds(for: target, at: time)
        let first = try await f.read(in: store, target: target, end: ends[0], at: time)
        let linked = try await store.recoveryCollectionWork(for: target)
        #expect(linked.map(\.id) == [first])
        #expect(linked.first?.recoveryCertificate?.targetWorkID == target)
        try await store.close()
    }

    @Test func recoveryChainQueryRejectsOverflowInsteadOfTruncating() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try await f.open(retaining: 256)
        let target = try await f.loss(in: store)
        for _ in 0..<129 {
            _ = try await f.read(in: store, target: target, end: f.now, at: f.now, successful: false)
        }
        await #expect(throws: StorageError.stateTooLarge) {
            try await store.recoveryCollectionWork(for: target)
        }
        #expect(try await store.collectionWork(id: target)?.state == .terminal)
        try await store.close()
    }
}
