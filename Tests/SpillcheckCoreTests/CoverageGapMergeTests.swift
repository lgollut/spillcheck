import Foundation
import GRDB
import Testing
@_spi(Testing) @testable import SpillcheckCore

/// A failing source used to add one encrypted row per poll or per catch-up pass. A week of that
/// filled the coverage report's bound with repeats, so the window showed only part of its gaps.
@Suite("Repeats of a coverage gap are stored once")
struct CoverageGapMergeTests {
    private let scope = CollectionScope(provider: .codex, profileID: "default", interface: .standaloneCLI, path: .publicHistory)

    private func openStore() async throws -> (ProtectedStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spillcheck-gap-merge-\(UUID())").resolvingSymlinksInPath()
        let store = try await ProtectedStore.open(at: directory, cryptography: try BackgroundCryptography.ephemeralForTesting())
        return (store, directory)
    }

    private func unavailable(_ thread: String, at time: Date) throws -> CoverageGap {
        CoverageGap(reason: .sourceUnavailable, scope: scope, operation: .liveRead,
            recovery: .init(session: try SessionIdentity(provider: .codex, profileID: "default", sessionID: thread),
                            parserContract: CodexAdapter.parserContract),
            diagnosticCode: CoverageGapReason.sourceUnavailable.defaultDiagnosticCode, observedAt: time)
    }

    private func database(_ directory: URL) throws -> DatabaseQueue {
        try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path)
    }

    @Test func aRepeatedGapIsOneEventWithItsCountAndBothTimes() async throws {
        let (store, directory) = try await openStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let times = (0..<3).map { fixtureTime.addingTimeInterval(Double($0) * 60) }
        for time in times { try await store.recordCoverageGap(try unavailable("thread-a", at: time), at: time) }
        try await store.recordCoverageGap(try unavailable("thread-b", at: times[1]), at: times[1])
        try await store.recordCoverageGap(CoverageGap(reason: .captureRejected), at: times[0])
        try await store.recordCoverageGap(CoverageGap(reason: .captureRejected), at: times[2])

        let page = try await store.coverageGapEvents()
        #expect(page.totalCount == 3)
        let threadA = try #require(page.items.first { $0.gap.recovery?.session?.sessionID == "thread-a" })
        #expect(threadA.count == 3)
        #expect(threadA.observedAt == times[2])
        #expect(threadA.earliestObservedAt == times[0])
        #expect(threadA.gap.observedAt == times[2])
        let threadB = try #require(page.items.first { $0.gap.recovery?.session?.sessionID == "thread-b" })
        #expect(threadB.count == 1)
        #expect(threadB.earliestObservedAt == times[1])
        let rejected = try #require(page.items.first { $0.gap.reason == .captureRejected })
        #expect(rejected.count == 2)
        #expect(rejected.earliestObservedAt == times[0])
        #expect(rejected.observedAt == times[2])

        try await store.close()
    }

    @Test func anEarlierRepeatCountsWithoutReplacingTheLatestObservation() async throws {
        let (store, directory) = try await openStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let late = fixtureTime.addingTimeInterval(600)
        try await store.recordCoverageGap(try unavailable("thread-a", at: late), at: late)
        try await store.recordCoverageGap(try unavailable("thread-a", at: fixtureTime), at: fixtureTime)
        let event = try #require(try await store.coverageGapEvents().items.first)
        #expect(event.count == 2)
        #expect(event.observedAt == late)
        #expect(event.earliestObservedAt == fixtureTime)
        try await store.close()
    }

    @Test func olderRowsFoldIntoOneEventPerGap() async throws {
        let (store, directory) = try await openStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let times = (0..<5).map { fixtureTime.addingTimeInterval(Double($0) * 60) }
        // Rows written before this change have no merge key. Clearing it after each write gives
        // each observation a row of its own, as older builds stored them.
        for time in times.prefix(4) {
            try await store.recordCoverageGap(try unavailable("thread-a", at: time), at: time)
            try await store.recordCoverageGap(try unavailable("thread-b", at: time), at: time)
            try await database(directory).write { db in try db.execute(sql: "UPDATE coverage_gaps SET merge_key = NULL") }
        }
        // A newer keyed row for thread-a already exists, as after the first write of a new build.
        try await store.recordCoverageGap(try unavailable("thread-a", at: times[4]), at: times[4])
        #expect(try await store.coverageGapEvents().totalCount == 9)

        // Two rows per pass, so the folding spans passes and meets rows an earlier pass keyed.
        var passes = 0
        while try await store.compactLegacyCoverageGaps(limit: 2) > 0 { passes += 1 }
        #expect(passes == 4)

        let events = try await store.coverageGapEvents().items
        #expect(events.count == 2)
        let threadA = try #require(events.first { $0.gap.recovery?.session?.sessionID == "thread-a" })
        #expect(threadA.count == 5)
        #expect(threadA.observedAt == times[4])
        #expect(threadA.earliestObservedAt == times[0])
        let threadB = try #require(events.first { $0.gap.recovery?.session?.sessionID == "thread-b" })
        #expect(threadB.count == 4)
        #expect(threadB.observedAt == times[3])
        #expect(threadB.earliestObservedAt == times[0])

        // New repeats keep merging into the folded rows.
        try await store.recordCoverageGap(try unavailable("thread-b", at: times[4]), at: times[4])
        let merged = try #require(try await store.coverageGapEvents().items.first { $0.gap.recovery?.session?.sessionID == "thread-b" })
        #expect(merged.count == 5)
        #expect(merged.observedAt == times[4])
        #expect(try await store.compactLegacyCoverageGaps() == 0)
        try await store.close()
    }

    @Test func theReportWarnsOnlyWhenOpenGapsDoNotFit() async throws {
        let (store, directory) = try await openStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        for index in 0..<3 {
            try await store.recordCoverageGap(try unavailable("thread-\(index)", at: now), at: now)
        }
        let fits = try await store.coverageReport(endingAt: now.addingTimeInterval(1), limit: 3)
        #expect(!fits.hidesUnresolvedGaps)
        let bounded = try await store.coverageReport(endingAt: now.addingTimeInterval(1), limit: 2)
        #expect(bounded.hidesUnresolvedGaps)
        #expect(bounded.hiddenUnresolvedCount >= 1)
        try await store.close()
    }
}
