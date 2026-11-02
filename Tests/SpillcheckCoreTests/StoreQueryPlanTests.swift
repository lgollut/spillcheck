import Foundation
import GRDB
import Testing
@_spi(Testing) @testable import SpillcheckCore

/// The queue, work ledger and omission ledger hold thousands of rows with large encrypted
/// columns. A statement that runs for every capture or every refresh must reach its rows through
/// an index; reading every row made each capture slower the longer the queue grew.
@Suite("Vault statements that run per capture stay indexed")
struct StoreQueryPlanTests {
    @Test func perCaptureAndRefreshStatementsNeverReadEveryRow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spillcheck-query-plans-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: try BackgroundCryptography.ephemeralForTesting())
        try await store.close()
        let database = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path)
        defer { try? database.close() }
        typealias Queries = ProtectedStore.HotQueries
        let statements: [(String, String)] = [
            ("expiring captures", Queries.expiringCaptures),
            ("queue bytes", Queries.queueBytes),
            ("queue bytes without the finished capture", Queries.queueBytesExcluding),
            ("history queue count", Queries.historicalCount),
            ("work ledger bytes", Queries.workBytes),
            ("omission ledger bytes", Queries.omissionBytes),
            ("expired claims", Queries.releaseExpiredClaims),
            ("released work", Queries.requeueReleasedWork),
            ("next capture", Queries.nextCapture),
            ("completed work pruning", Queries.pruneCompletedWork),
            ("evidence work count", Queries.evidenceWorkCount),
            ("omission expiry", Queries.expireRecoverableOmissions),
        ]
        for (name, sql) in statements {
            let plan = try await database.read { db in try Self.plan(of: sql, in: db) }
            let everyRow = plan.filter {
                ($0.hasPrefix("SCAN ") && !$0.contains("COVERING INDEX") && $0 != "SCAN CONSTANT ROW")
                    || $0.contains("TEMP B-TREE")
            }
            #expect(everyRow.isEmpty, "\(name) reads every row: \(plan)")
        }
    }

    @Test func recoveriesFindTheirOmissionsByLocation() async throws {
        // Without statistics SQLite chose the state-and-age index for these, then read every blocked
        // or retryable omission in the last week to compare its location. A history pass recovers
        // thousands of locations, so a capture's settlement read millions of rows from disk.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spillcheck-location-plans-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: try BackgroundCryptography.ephemeralForTesting())
        try await store.close()
        let database = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path)
        defer { try? database.close() }
        typealias Queries = ProtectedStore.HotQueries
        for (name, sql) in [("recoverable omissions at a location", Queries.recoverableOmissionsAtLocation),
                            ("recovering a location", Queries.recoverOmissionsAtLocation)] {
            let plan = try await database.read { db in try Self.plan(of: sql, in: db) }
            #expect(plan.contains { $0.hasPrefix("SEARCH coverage_omissions USING INDEX coverage_omissions_location (location_id=?") },
                    "\(name) does not search by location: \(plan)")
        }
    }

    @Test func settlementPreparesItsPerLocationStatementsOnce() async throws {
        // A history pass records or recovers thousands of locations in one capture. Parsing and
        // planning the same statements again for each location took longer than running them.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spillcheck-settlement-statements-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: try BackgroundCryptography.ephemeralForTesting())
        let now = Date()
        let session = try SessionIdentity(provider: .codex, profileID: "private-native-profile", sessionID: "private-native-session")
        let scope = CollectionScope(provider: .codex, profileID: "private-native-profile", interface: .standaloneCLI, path: .publicHistory)
        let locations = (0..<24).map {
            CoverageRecoveryReference(session: session, locator: .upstreamItem, itemID: "private-item-\($0)",
                                      contentTime: now, parserContract: "contract")
        }
        func complete(gaps: [CoverageGap] = [], recovered: [CoverageRecoveryReference] = []) async throws {
            let permit = try #require(await store.processingPermit())
            _ = try await store.enqueue(Data("synthetic controlled capture".utf8), capturedAt: now, permit: permit, at: now)
            let capture = try #require(try await store.nextPending(at: now, permit: permit))
            try await store.completeCapture(capture, coverageGaps: gaps, recoveredReferences: recovered, permit: permit, at: now)
        }
        func runs(_ sql: String) async throws -> Int {
            try await store.preparedStatementRunsForTesting().filter { $0.key.contains(sql) }.values.reduce(0, +)
        }

        try await complete(gaps: locations.map {
            CoverageGap(reason: .malformedSource, scope: scope, contentType: .toolOutput, recovery: $0, isRequiredFormatFailure: true)
        })
        #expect(try await store.coverageOmissions().count == locations.count)
        #expect(try await runs("INSERT INTO coverage_omissions") >= locations.count)

        try await complete(recovered: locations)
        #expect(try await store.coverageOmissions().isEmpty)
        #expect(try await store.healthIncidents().isEmpty)
        #expect(try await runs(ProtectedStore.HotQueries.recoverOmissionsAtLocation) >= locations.count)
        #expect(try await runs("UPDATE collection_health_incidents SET resolved_at") >= locations.count)
        try await store.close()
    }

    @Test func theCoverageReportReadsOnlyTheWorkRowsItReturns() async throws {
        // The report rebuilds every few seconds and the window holds tens of thousands of work rows.
        // Reading and sorting all of them to return a page made it the app's main background cost.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spillcheck-work-plans-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: try BackgroundCryptography.ephemeralForTesting())
        try await store.close()
        let database = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path)
        defer { try? database.close() }
        typealias Queries = ProtectedStore.HotQueries
        let active = try await database.read { db in try Self.plan(of: Queries.activeWork, in: db) }
        #expect(active.contains { $0.hasPrefix("SEARCH collection_work USING INDEX collection_work_state") },
                "active work is not found by state: \(active)")
        #expect(!active.contains { $0.hasPrefix("SCAN ") }, "active work reads every row: \(active)")
        // The sort over the active rows is bounded by the queue, not by the window, so it is allowed.
        let settled = try await database.read { db in try Self.plan(of: Queries.settledWork, in: db) }
        #expect(settled.contains { $0.hasPrefix("SEARCH collection_work USING INDEX collection_work_updated") },
                "settled work does not walk the updated index: \(settled)")
        #expect(!settled.contains { $0.hasPrefix("SCAN ") }, "settled work reads every row: \(settled)")
        // A full sort would read the whole window first; the partial sorts stop at the limit.
        #expect(!settled.contains("USE TEMP B-TREE FOR ORDER BY"), "settled work sorts the whole window: \(settled)")
    }

    @Test func pagedWorkRowsMatchSortingTheWholeWindow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spillcheck-work-pages-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: try BackgroundCryptography.ephemeralForTesting())
        try await store.close()
        let database = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path)
        defer { try? database.close() }
        let states = ["queued", "processing", "stalled", "completed", "recovered", "terminal", "blocked"]
        let (from, through) = (1_000.0, 2_000.0)
        // Few distinct times so many rows tie; the bounds and rows just outside them are included.
        let times: [Double] = [999, 1_000, 1_000, 1_001, 1_500, 1_500, 1_500, 1_999, 2_000, 2_000, 2_001]
        try await database.write { db in
            for n in 0..<220 {
                try db.execute(sql: """
                    INSERT INTO collection_work (id, state, admitted_at, updated_at, encoded) VALUES (?, ?, 0, ?, ?)
                    """, arguments: [String(format: "id-%04d", (n * 37) % 1000), states[(n * 5 + n / 7) % states.count],
                                     times[(n * 3 + n / 11) % times.count], Data([UInt8(n % 256)])])
            }
        }
        let reference = """
            SELECT * FROM collection_work WHERE updated_at >= ? AND updated_at <= ?
            ORDER BY (state IN ('queued', 'processing', 'stalled')) DESC, updated_at DESC, id LIMIT ?
            """
        // Fewer than the active rows, between them and the window, exactly the window, and beyond it.
        for limit in [1, 5, 20, 40, 100, 150, 200, 1000] {
            let (expected, actual) = try await database.read { db in
                (try Row.fetchAll(db, sql: reference, arguments: [from, through, limit]).map(\.description),
                 try ProtectedStore.workRows(in: db, from: from, through: through, limit: limit).rows.map(\.description))
            }
            let counts = try await database.read { db in
                (try ProtectedStore.workRows(in: db, from: from, through: through, limit: limit).count,
                 try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection_work WHERE updated_at >= ? AND updated_at <= ?",
                                  arguments: [from, through]))
            }
            #expect(counts.0 == counts.1, "count differs at limit \(limit)")
            #expect(actual == expected, "rows differ at limit \(limit)")
            #expect(!expected.isEmpty)
        }
        let activeInWindow = try await database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM collection_work WHERE state IN ('queued', 'processing', 'stalled')
                AND updated_at >= ? AND updated_at <= ?
                """, arguments: [from, through])
        }
        #expect((activeInWindow ?? 0) > 20 && (activeInWindow ?? 0) < 150)
    }

    private static func plan(of sql: String, in db: Database) throws -> [String] {
        let statement = try db.makeStatement(sql: "EXPLAIN QUERY PLAN " + sql)
        // Unbound parameters are NULL; the plan does not depend on them.
        statement.setUncheckedArguments([])
        return try Row.fetchAll(statement).map { $0["detail"] }
    }
}
