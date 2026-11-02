import Foundation
import GRDB
import Testing
@_spi(Testing) @testable import SpillcheckCore

/// Completed work that holds gap evidence is kept for presentation, but it must never fill the
/// protected-state cap: a full work ledger rejects every enqueue and stops all collection.
@Suite("Gap evidence in the work ledger stays bounded")
struct BoundedGapEvidenceTests {
    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-evidence-\(UUID())")
        let crypto: BackgroundCryptography
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let route: CollectionCaptureRoute
        let packet: CapturePacket
        let context: CollectionWorkContext
        init() throws {
            crypto = try BackgroundCryptography.ephemeralForTesting()
            route = CollectionCaptureRoute(scope: .init(provider: .codex, profileID: "fake-evidence", interface: .t3, path: .publicHistory))
            packet = try CapturePacket(metadata: .init(agent: .codex, interface: .t3, profileID: "fake-evidence"),
                eventJSON: Data("{\"hook_event_name\":\"SpillcheckHistoryPoll\",\"session_id\":\"11111111-1111-4111-8111-111111111111\"}".utf8))
            context = try route.context(for: packet, trigger: .activePoll)
        }

        func open(_ limits: StoreLimits) async throws -> ProtectedStore {
            try await ProtectedStore.open(at: directory, cryptography: crypto, limits: limits)
        }

        /// A catch-up capture that finishes with a gap on an excluded attachment, as most do.
        @discardableResult
        func captureWithGap(in store: ProtectedStore, index: Int) async throws -> UUID {
            let time = now.addingTimeInterval(Double(index) / 1000)
            let permit = try #require(await store.processingPermit())
            let id = UUID()
            _ = try await store.enqueue(packet.body, id: id, capturedAt: time, permit: permit, at: time, workContext: context)
            let capture = try #require(try await store.nextPending(at: time, permit: permit))
            #expect(capture.id == id)
            try await store.completeCapture(capture, coverageGaps: [.init(reason: .budgetExhausted, excludedContent: true)],
                permit: permit, at: time)
            return id
        }

        func ledger<T: Sendable>(_ read: @escaping @Sendable (Database) throws -> T) throws -> T {
            let queue = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path)
            defer { try? queue.close() }
            return try queue.read(read)
        }

        func evidenceRows() throws -> Int {
            try ledger { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collection_work WHERE retain_evidence = 1 AND state IN ('completed', 'recovered')") ?? 0 }
        }

        func workBytes() throws -> Int {
            try ledger { try Int.fetchOne($0, sql: ProtectedStore.HotQueries.workBytes) ?? 0 }
        }
    }

    @Test func captureAfterCaptureWithAGapNeverFillsTheLedger() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let evidenceBound = 8
        let store = try await f.open(.init(maxRetryCount: 0, maxProtectedStateBytes: 40_000,
            maxSuccessfulWorkRecords: 4, maxEvidenceWorkRecords: evidenceBound))
        // Unfinished work is never pruned, whatever the bound.
        let permit = try #require(await store.processingPermit())
        let lost = UUID()
        _ = try await store.enqueue(f.packet.body, id: lost, capturedAt: f.now, permit: permit, at: f.now, workContext: f.context)
        let claimed = try #require(try await store.nextPending(at: f.now, permit: permit))
        try await store.retry(claimed, reason: .sourceUnavailable, at: f.now, permit: permit)
        var newest: [UUID] = []
        for index in 1...400 {
            newest.append(try await f.captureWithGap(in: store, index: index))
        }
        try await store.close()
        // The cap is small enough that unbounded evidence would have exhausted it. Trimming goes
        // below the bound by an eighth, so the count settles just under it.
        let kept = try f.ledger { try String.fetchAll($0, sql: "SELECT id FROM collection_work WHERE retain_evidence = 1 AND state = 'completed' ORDER BY updated_at DESC, id") }
        #expect((evidenceBound - evidenceBound / 8)...evidenceBound ~= kept.count)
        #expect(try f.workBytes() <= 40_000)
        #expect(Set(kept) == Set(newest.suffix(kept.count).map(\.uuidString)))
        #expect(try f.ledger { try String.fetchOne($0, sql: "SELECT state FROM collection_work WHERE id = ?", arguments: [lost.uuidString]) } == "terminal")
    }

    @Test func aLedgerAlreadyOverTheCapRecoversWhenOpened() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let crowded = try await f.open(.init(maxSuccessfulWorkRecords: 4, maxEvidenceWorkRecords: 200))
        for index in 0..<120 { try await f.captureWithGap(in: crowded, index: index) }
        try await crowded.close()
        let full = try f.workBytes()
        #expect(try f.evidenceRows() == 120)

        // The fixed build opens a vault that earlier builds filled to the brim.
        let cap = full * 3 / 4
        let limits = StoreLimits(maxProtectedStateBytes: cap, maxSuccessfulWorkRecords: 4, maxEvidenceWorkRecords: 10)
        let store = try await f.open(limits)
        try await store.close()
        // Opening alone must make room: cap pressure at the first enqueue would hide a missing prune.
        #expect(try f.evidenceRows() == 10)
        #expect(try f.workBytes() <= cap)

        let reopened = try await f.open(limits)
        let permit = try #require(await reopened.processingPermit())
        let time = f.now.addingTimeInterval(10)
        _ = try await reopened.enqueue(f.packet.body, capturedAt: time, permit: permit, at: time, workContext: f.context)
        try await reopened.close()
        #expect(try f.evidenceRows() <= 10)
        #expect(try f.workBytes() <= cap)
        #expect(try f.ledger { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collection_work WHERE state = 'queued'") } == 1)
    }

    @Test func enqueueMakesRoomBeforeFailingWhenCompletedEvidenceIsPrunable() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let crowded = try await f.open(.init(maxSuccessfulWorkRecords: 4, maxEvidenceWorkRecords: 200))
        for index in 0..<60 { try await f.captureWithGap(in: crowded, index: index) }
        try await crowded.close()
        let cap = try f.workBytes() + 10

        // The bound is generous, so only pressure from the cap can free the room.
        let store = try await f.open(.init(maxProtectedStateBytes: cap, maxSuccessfulWorkRecords: 4, maxEvidenceWorkRecords: 200))
        let permit = try #require(await store.processingPermit())
        for index in 0..<5 {
            let time = f.now.addingTimeInterval(10 + Double(index))
            _ = try await store.enqueue(f.packet.body, capturedAt: time, permit: permit, at: time, workContext: f.context)
        }
        try await store.close()
        #expect(try f.workBytes() <= cap)
        #expect(try f.ledger { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collection_work WHERE state = 'queued'") } == 5)
    }

    @Test func aCertifiedRecoveryOfAnUnresolvedLossOutlivesTheEvidenceBound() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try await f.open(.init(maxRetryCount: 0, maxSuccessfulWorkRecords: 4, maxEvidenceWorkRecords: 2))
        let permit = try #require(await store.processingPermit())
        // A month of lost history needs two audits, so one certified pass leaves the loss terminal.
        let lossAge: TimeInterval = 30 * 24 * 60 * 60
        let scope = try LiveCaptureScope(startedAt: f.now.addingTimeInterval(-lossAge))
        let target = UUID()
        _ = try await store.enqueue(f.packet.body, id: target, capturedAt: f.now, permit: permit, at: f.now,
            scope: scope, workContext: f.context)
        let claimed = try #require(try await store.nextPending(at: f.now, permit: permit))
        try await store.retry(claimed, reason: .sourceUnavailable, at: f.now, permit: permit)
        let end = try #require(try await store.remainingRecoveryAuditEnds(for: target, at: f.now).first)
        let audit = try HistoricalAuditContext(reason: .resume, endingAt: end)
        let readContext = try f.route.context(for: f.packet, trigger: .historyRequest, audit: audit, retry: f.context.retry)
        let certified = UUID()
        _ = try await store.enqueue(f.packet.body, id: certified, capturedAt: f.now, permit: permit, at: f.now,
            historicalAudit: audit, workContext: readContext, recoveryOf: target)
        let read = try #require(try await store.nextPending(at: f.now, permit: permit))
        try await store.completeCapture(read, historicalProgress: .init(audit: audit, bytesRead: 1, hasUnreadContent: false),
            coverageGaps: [.init(reason: .budgetExhausted, excludedContent: true)],
            successfulRead: true, permit: permit, at: f.now)
        #expect(try await store.collectionWork(id: certified)?.recoveryCertificate != nil)
        #expect(try await store.collectionWork(id: target)?.state == .terminal)
        for index in 1...6 { try await f.captureWithGap(in: store, index: index) }
        try await store.close()
        #expect(try f.evidenceRows() == 3)
        #expect(try f.ledger { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collection_work WHERE id = ?", arguments: [certified.uuidString]) } == 1)
    }

    @Test func aSettledBacklogEventStaysSettledAfterItsWorkRowIsPruned() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try await f.open(.init(maxSuccessfulWorkRecords: 4, maxEvidenceWorkRecords: 1))
        let permit = try #require(await store.processingPermit())
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: f.now)
        let context = try f.route.context(for: f.packet, trigger: .historyRequest, audit: audit)
        _ = try await store.enqueue(f.packet.body, capturedAt: f.now, permit: permit, at: f.now,
            historicalAudit: audit, workContext: context)
        for page in 0..<3 {
            let time = f.now.addingTimeInterval(Double(page * 10))
            let capture = try #require(try await store.nextPending(at: time, permit: permit))
            let last = page == 2
            try await store.completeCapture(capture, continuation: last ? nil : f.packet,
                historicalProgress: .init(audit: audit, bytesRead: 100, hasUnreadContent: false),
                coverageGaps: last ? [] : [.init(reason: .budgetExhausted)], permit: permit, at: time)
        }
        let report = try await store.coverageReport(endingAt: f.now.addingTimeInterval(30))
        let events = report.gapEvents.items
        #expect(events.count == 2 && events.allSatisfy { $0.isIntermediateBacklog && $0.workID != nil })
        // The bound keeps one evidence row, so the earlier page's work is gone from the report.
        #expect(report.work.items.count < 3)
        #expect(!report.work.isTruncated)
        #expect(report.activeGapEvents.isEmpty)
        try await store.close()
    }
}
