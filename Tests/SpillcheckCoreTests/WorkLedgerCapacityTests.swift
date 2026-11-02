import Foundation
import GRDB
import Testing
@_spi(Testing) @testable import SpillcheckCore

private struct WorkCapacityNoFindings: SecretDetector {
    func scan(_ source: SourceRecord) async throws -> DetectorOutput {
        .init(detectorVersion: "work-capacity-fixture", findings: [], unlocated: [])
    }
}

/// Every history page it reads has more to come.
private struct ContinuingHistoryNormalizer: CaptureNormalizer {
    let audit: HistoricalAuditContext
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        CollectionBatch(sources: [], continuation: packet,
            historicalProgress: .init(audit: audit, bytesRead: 100, hasUnreadContent: true))
    }
}

/// Unfinished work is never pruned. Once it alone fills the work ledger, every new capture is
/// refused, and that refusal must say so instead of passing for a generic rejection.
@Suite("A full work ledger is reported as such")
struct WorkLedgerCapacityTests {
    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-work-capacity-\(UUID())")
        let crypto: BackgroundCryptography
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let route: CollectionCaptureRoute
        let packet: CapturePacket
        let liveContext: CollectionWorkContext
        let audit: HistoricalAuditContext
        let historyContext: CollectionWorkContext

        init() throws {
            crypto = try BackgroundCryptography.ephemeralForTesting()
            route = CollectionCaptureRoute(scope: .init(provider: .codex, profileID: "fake-work-capacity", interface: .t3, path: .publicHistory))
            packet = try CapturePacket(metadata: .init(agent: .codex, interface: .t3, profileID: "fake-work-capacity"),
                eventJSON: Data("{\"hook_event_name\":\"SpillcheckHistoryPoll\",\"session_id\":\"11111111-1111-4111-8111-111111111111\"}".utf8))
            liveContext = try route.context(for: packet, trigger: .activePoll)
            audit = try HistoricalAuditContext(reason: .resume, endingAt: now)
            historyContext = try route.context(for: packet, trigger: .historyRequest, audit: audit)
        }

        func open(_ limits: StoreLimits, named name: String) async throws -> ProtectedStore {
            try await ProtectedStore.open(at: directory.appendingPathComponent(name), cryptography: crypto, limits: limits)
        }

        /// Captures a reader has claimed but not finished. Their work rows cannot be pruned.
        func claimUnfinished(_ count: Int, in store: ProtectedStore) async throws {
            let permit = try #require(await store.processingPermit())
            for index in 0..<count {
                let time = now.addingTimeInterval(Double(index))
                _ = try await store.enqueue(packet.body, id: Self.id(index), capturedAt: time, permit: permit,
                    at: time, workContext: liveContext)
                _ = try #require(try await store.nextPending(at: time, permit: permit))
            }
        }

        func enqueueHistory(in store: ProtectedStore) async throws {
            let permit = try #require(await store.processingPermit())
            let time = now.addingTimeInterval(100)
            _ = try await store.enqueue(packet.body, id: Self.id(1000), capturedAt: time, permit: permit, at: time,
                historicalAudit: audit, workContext: historyContext)
        }

        /// Fixed identities give the measured run and the capped run rows of the same size.
        static func id(_ index: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
        }

        func workBytes(_ name: String) throws -> Int {
            let queue = try DatabaseQueue(path: directory.appendingPathComponent(name)
                .appendingPathComponent(ProtectedStore.databaseFilename).path)
            defer { try? queue.close() }
            return try queue.read { try Int.fetchOne($0, sql: ProtectedStore.HotQueries.workBytes) ?? 0 }
        }
    }

    @Test func theCapacitySnapshotReportsTheWorkLedger() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let cap = 1_000_000
        let store = try await f.open(.init(maxProtectedStateBytes: cap), named: "snapshot")
        let empty = try await store.capacitySnapshot().collectionWork
        #expect(empty.count == 0 && empty.encryptedBytes == 0 && empty.state == .available)
        try await f.claimUnfinished(3, in: store)
        try await f.enqueueHistory(in: store)
        let usage = try await store.capacitySnapshot().collectionWork
        try await store.close()
        #expect(usage.count == 4)
        #expect(usage.encryptedBytes == (try f.workBytes("snapshot")) && usage.encryptedBytes > 0)
        #expect(usage.encryptedBytesLimit == cap)
        // Only the ledger's bytes are bounded; its row count never limits collection.
        #expect(usage.countState == .available)
    }

    @Test func anEnqueueThatCannotMakeRoomIsRefusedForWorkStorage() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let measured = try await f.open(.init(), named: "measured")
        try await f.claimUnfinished(8, in: measured)
        try await measured.close()
        let eight = try f.workBytes("measured")
        let row = eight / 8

        // Room for eight unfinished captures, but not a ninth. Encrypted rows differ by a few bytes
        // between runs, far less than the half-row margin.
        let cap = eight + row / 2
        let store = try await f.open(.init(maxProtectedStateBytes: cap), named: "capped")
        try await f.claimUnfinished(8, in: store)
        let permit = try #require(await store.processingPermit())
        let time = f.now.addingTimeInterval(50)
        await #expect(throws: StorageError.capacityExceeded(.collectionWork)) {
            try await store.enqueue(f.packet.body, capturedAt: time, permit: permit, at: time, workContext: f.liveContext)
        }
        let usage = try await store.capacitySnapshot().collectionWork
        #expect(usage.count == 8 && usage.encryptedBytes <= cap && usage.encryptedBytes > cap - row)
        #expect(usage.state == .nearCapacity)
        #expect(try await store.queueStatistics().count == 8)
        try await store.close()
    }

    @Test func aHistoryPageWhoseNextPageIsRefusedIsLostToWorkStorage() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let measured = try await f.open(.init(), named: "measured")
        try await f.claimUnfinished(8, in: measured)
        let unfinished = try f.workBytes("measured")
        try await f.enqueueHistory(in: measured)
        try await measured.close()
        let withHistory = try f.workBytes("measured")
        let historyRow = withHistory - unfinished

        // The history capture fits; the next page it queues does not.
        let store = try await f.open(.init(maxRetryCount: 0, maxProtectedStateBytes: withHistory + historyRow / 2),
            named: "capped")
        try await f.claimUnfinished(8, in: store)
        try await f.enqueueHistory(in: store)
        let pipeline = DetectionPipeline(store: store, cryptography: f.crypto,
            normalizer: ContinuingHistoryNormalizer(audit: f.audit), detector: WorkCapacityNoFindings(),
            detectorVersion: "work-capacity-fixture", liveSince: f.now)
        #expect(try await pipeline.processNext(at: f.now.addingTimeInterval(101)) == .retryScheduled)

        let report = try await store.coverageReport(endingAt: f.now.addingTimeInterval(200))
        let loss = try #require(report.omissions.items.first)
        #expect(report.omissions.items.count == 1)
        #expect(loss.gap.diagnosticCode == .workStorageLimit)
        #expect(loss.gap.operation == .historicalRead && loss.gap.scope == f.route.scope)
        #expect(try await store.collectionWork(id: Fixture.id(1000))?.state == .terminal)
        try await store.close()
    }
}
