import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

@Suite("Historical observation bounds")
struct HistoryProgressBoundsTests {
    @Test func invalidBoundsCannotAdvanceDurableHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-history-bounds-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let now = Date(), audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let packet = try CapturePacket(metadata: .init(agent: .codex, profileID: "bounds-test"), eventJSON: Data("{}".utf8))
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, historicalAudit: audit)
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        for (oldest, newest) in [
            (audit.start.addingTimeInterval(-1), now),
            (audit.start, now.addingTimeInterval(1)),
            (now, audit.start)
        ] {
            let progress = HistoricalReadProgress(audit: audit, bytesRead: 10,
                oldestContentTime: oldest, newestContentTime: newest, hasUnreadContent: false)
            await #expect(throws: StorageError.invalidPayload) {
                try await store.completeCapture(capture, historicalProgress: progress, permit: permit, at: now)
            }
            #expect(try await store.queueStatistics().count == 1)
            #expect(try await store.historicalProgress().isEmpty)
        }
        let tooLarge = HistoricalReadProgress(audit: audit, bytesRead: 100 * 1024 * 1024 + 1,
            hasUnreadContent: true)
        await #expect(throws: StorageError.invalidPayload) {
            try await store.completeCapture(capture, historicalProgress: tooLarge, permit: permit, at: now)
        }
        let atBudget = HistoricalReadProgress(audit: audit, bytesRead: 100 * 1024 * 1024,
            hasUnreadContent: true)
        try await store.completeCapture(capture, historicalProgress: atBudget, permit: permit, at: now)
        #expect(try await store.historicalProgress().first?.progress == atBudget)
        try await store.close()
    }
}
