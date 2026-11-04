import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

/// Every launch started its own catch-up, and earlier unfinished ones kept running. Their pages
/// interleaved, each rewound the per-file positions the other saved, and none finished: the vault
/// held 49 audits, each still reporting unread history.
@Suite("One catch-up per profile")
struct HistoryChainTests {
    private let profile = "SYNTHETIC_HISTORY_CHAIN_PROFILE"
    private var scope: CollectionScope {
        CollectionScope(provider: .codex, profileID: profile, interface: .standaloneCLI, path: .publicHistory)
    }

    private func openStore() async throws -> (ProtectedStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-history-chain-\(UUID())")
        return (try await ProtectedStore.open(at: directory, cryptography: try BackgroundCryptography.ephemeralForTesting()), directory)
    }

    private func packet(_ page: Int) throws -> CapturePacket {
        try CapturePacket(metadata: .init(agent: .codex, profileID: profile), eventJSON: JSONEncoder().encode(["page": page]))
    }

    private func identity(_ audit: HistoricalAuditContext) -> CoverageAuditIdentity {
        .init(auditID: audit.id, provider: .codex, profileID: profile)
    }

    private func enqueue(_ store: ProtectedStore, _ audit: HistoricalAuditContext, at time: Date,
                         retry: CoverageSourceRetryDescriptor? = nil) async throws {
        let permit = try #require(await store.processingPermit())
        let context = CollectionWorkContext(scope: scope, operation: .historicalRead, audit: identity(audit), retry: retry,
            trigger: .historyRequest, auditWindow: DateInterval(start: audit.start, end: audit.end))
        _ = try await store.enqueue(packet(0).body, capturedAt: time, permit: permit, at: time,
                                    historicalAudit: audit, workContext: context)
    }

    private func finish(_ store: ProtectedStore, _ audit: HistoricalAuditContext, continues: Bool, unread: Bool,
                        at time: Date, claimed: PendingCapture? = nil) async throws {
        let permit = try #require(await store.processingPermit())
        let capture: PendingCapture
        if let claimed { capture = claimed } else { capture = try #require(try await store.nextPending(at: time, permit: permit)) }
        try await store.completeCapture(capture, continuation: continues ? packet(1) : nil,
            historicalProgress: .init(audit: audit, bytesRead: 100, hasUnreadContent: unread),
            coverageGaps: continues ? [.init(reason: .budgetExhausted)] : [], permit: permit, at: time)
    }

    private func progress(_ store: ProtectedStore, _ audit: HistoricalAuditContext) async throws -> StoredHistoricalProgress? {
        try await store.historicalProgressPage().items.first { $0.progress.audit.id == audit.id }
    }

    @Test func aNewCatchUpRetiresTheProfilesUnfinishedOneAndSettlesItWhenDone() async throws {
        let (store, directory) = try await openStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let earlier = try HistoricalAuditContext(reason: .restart, endingAt: now.addingTimeInterval(-3600))
        try await enqueue(store, earlier, at: now.addingTimeInterval(-3600))
        try await finish(store, earlier, continues: true, unread: true, at: now.addingTimeInterval(-3500))
        #expect(try await store.queueStatistics().historicalCount == 1)

        let later = try HistoricalAuditContext(reason: .restart, endingAt: now)
        #expect(try await store.supersedeHistory(provider: .codex, profileID: profile, by: later, at: now) == false)
        #expect(try await store.queueStatistics().historicalCount == 0)
        let retired = try #require(try await progress(store, earlier))
        #expect(retired.supersededAt == now)
        #expect(retired.continuationQueued == false)
        #expect(retired.sourceRecovery == false)
        var report = try await store.coverageReport(endingAt: now)
        #expect(report.isSupersededAudit(identity(earlier)))
        #expect(!report.isCoveredByLaterAudit(identity(earlier)))
        #expect(report.providersReadingHistory.isEmpty)

        try await enqueue(store, later, at: now)
        let finishedAt = now.addingTimeInterval(60)
        try await finish(store, later, continues: false, unread: false, at: finishedAt)
        #expect(try await progress(store, later)?.completedProfileAudit == true)
        report = try await store.coverageReport(endingAt: finishedAt)
        #expect(report.isCoveredByLaterAudit(identity(earlier)))
        #expect(report.activeGapEvents.isEmpty)
        #expect(report.gapEvents.items.allSatisfy(report.hasRecoveredBacklog))
        try await store.close()
    }

    @Test func aPageBeingReadWhenReplacedQueuesNoNextPage() async throws {
        let (store, directory) = try await openStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let earlier = try HistoricalAuditContext(reason: .restart, endingAt: now.addingTimeInterval(-60))
        try await enqueue(store, earlier, at: now.addingTimeInterval(-60))
        let permit = try #require(await store.processingPermit())
        let reading = try #require(try await store.nextPending(at: now, permit: permit))
        let later = try HistoricalAuditContext(reason: .restart, endingAt: now)
        #expect(try await store.supersedeHistory(provider: .codex, profileID: profile, by: later, at: now) == false)
        // Claimed pages are not removed from under their reader.
        #expect(try await store.queueStatistics().count == 1)
        try await finish(store, earlier, continues: true, unread: true, at: now.addingTimeInterval(1), claimed: reading)
        #expect(try await store.queueStatistics().count == 0)
        let stopped = try #require(try await progress(store, earlier))
        #expect(stopped.continuationQueued == false)
        #expect(stopped.supersededAt == now.addingTimeInterval(1))
        try await store.close()
    }

    @Test func theSameAuditCarriesOnAndASourceRetryIsLeftAlone() async throws {
        let (store, directory) = try await openStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: now.addingTimeInterval(-60))
        try await enqueue(store, audit, at: now.addingTimeInterval(-60))
        #expect(try await store.supersedeHistory(provider: .codex, profileID: profile, by: audit, at: now))
        #expect(try await store.queueStatistics().historicalCount == 1)

        let session = try SessionIdentity(provider: .codex, profileID: profile, sessionID: "synthetic-retried-thread")
        let retry = try HistoricalAuditContext(reason: .resume, endingAt: now.addingTimeInterval(-30))
        try await enqueue(store, retry, at: now.addingTimeInterval(-30), retry: .init(scope: scope, session: session))
        let later = try HistoricalAuditContext(reason: .restart, endingAt: now)
        #expect(try await store.supersedeHistory(provider: .codex, profileID: profile, by: later, at: now) == false)
        // The profile catch-up is retired; the retry of one source keeps reading.
        #expect(try await store.queueStatistics().historicalCount == 1)
        // Another profile's catch-up is not this one's to retire.
        #expect(try await store.supersedeHistory(provider: .codex, profileID: "other", by: later, at: now) == false)
        #expect(try await store.queueStatistics().historicalCount == 1)
        try await store.close()
    }
}
