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

    private static func plan(of sql: String, in db: Database) throws -> [String] {
        let statement = try db.makeStatement(sql: "EXPLAIN QUERY PLAN " + sql)
        // Unbound parameters are NULL; the plan does not depend on them.
        statement.setUncheckedArguments([])
        return try Row.fetchAll(statement).map { $0["detail"] }
    }
}
