import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

@Suite("Reusing an unchanged coverage report")
struct CoverageReportReuseTests {
    @Test func anUnchangedVaultReusesItsReportUntilAWriteOrAMinutePasses() async throws {
        // The app rebuilt this report every second, decrypting up to a few thousand rows each
        // time, even while nothing changed.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-report-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: try BackgroundCryptography.ephemeralForTesting())
        let start = Date()
        let first = try await store.recentCoverageReport(at: start)
        _ = try await store.recentCoverageReport(at: start.addingTimeInterval(1))
        _ = try await store.recentCoverageReport(at: start.addingTimeInterval(30))
        #expect(await store.coverageReportBuilds == 1)

        // Any write is seen by the next refresh.
        try await store.recordCoverageGap(reason: .malformedSource, at: start.addingTimeInterval(31))
        let changed = try await store.recentCoverageReport(at: start.addingTimeInterval(32))
        #expect(await store.coverageReportBuilds == 2)
        #expect(!changed.hasSameRecords(as: first))
        // Exports and other callers always get a fresh report.
        #expect(changed.hasSameRecords(as: try await store.coverageReport(endingAt: start.addingTimeInterval(32))))
        #expect(await store.coverageReportBuilds == 3)

        // A reused report's window ends when it was built, so it is rebuilt a minute later.
        _ = try await store.recentCoverageReport(at: start.addingTimeInterval(91))
        #expect(await store.coverageReportBuilds == 3)
        _ = try await store.recentCoverageReport(at: start.addingTimeInterval(93))
        #expect(await store.coverageReportBuilds == 4)
        _ = try await store.recentCoverageReport(at: start.addingTimeInterval(94))
        #expect(await store.coverageReportBuilds == 4)
        try await store.close()
    }
}
