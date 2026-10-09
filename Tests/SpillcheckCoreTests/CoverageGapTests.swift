import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

@Suite("Protected coverage intervals")
struct CoverageGapTests {
    @Test func capabilityAndUnfinishedIntervalSurviveRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-gap-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let capability = UUID()
        let gap = CoverageGap(reason: .budgetExhausted, capabilityID: capability,
            interval: DateInterval(start: fixtureTime.addingTimeInterval(-600), end: fixtureTime))
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        try await store.recordCoverageGap(gap)
        #expect(try await store.coverageGaps() == [gap])
        try await store.close()
        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        #expect(try await reopened.coverageGaps() == [gap])
        let database = try Data(contentsOf: directory.appendingPathComponent(ProtectedStore.databaseFilename))
        #expect(database.range(of: Data(capability.uuidString.utf8)) == nil)
        try await reopened.close()
    }
}
