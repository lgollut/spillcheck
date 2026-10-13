import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

@Suite("Bounded legacy migration structural evidence")
struct LegacyMigrationStorageTests {
    @Test func snapshotRetainsCiphertextQueueMetadataWithoutClaimingOrRewriting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let permit = try #require(await store.processingPermit())
        let marker = Data("FAKE_ONLY_LEGACY_PENDING_PACKET".utf8)
        let date = Date()
        _ = try await store.enqueue(marker, capturedAt: date, permit: permit)
        let revision = await store.stateRevision()
        let before = try await store.legacyMigrationRowsForTesting()
        let after = try await store.legacyMigrationRowsForTesting()
        #expect(before.migrations.count == 8 && before.migrations.last == "v8-certified-source-recovery")
        let afterRevision = await store.stateRevision()
        #expect(before.rows == after.rows && afterRevision == revision)
        let rowBytes = try #require(before.rows["captures"]?.first)
        let row = try #require(JSONSerialization.jsonObject(with: rowBytes) as? [String: Any])
        #expect(Set(row.keys) == ["id", "encoded", "byte_count", "captured_at", "expires_at", "retry_count",
            "available_at", "state", "work_class", "claim_id", "lease_until"])
        #expect(row["state"] as? Int == 0 && row["retry_count"] as? Int == 0)
        #expect(row["claim_id"] is NSNull && row["lease_until"] is NSNull)
        #expect(row["captured_at"] as? Double == date.timeIntervalSince1970)
        let encoded = try #require((row["encoded"] as? String).flatMap { Data(base64Encoded: $0) })
        #expect(encoded.range(of: marker) == nil && encoded.count > marker.count)
        #expect(try await store.queueStatistics().claimedCount == 0)
        for table in ["coverage_omissions", "collection_health_incidents", "collection_work", "successful_collection_reads", "codex_hook_content_slots"] {
            #expect(before.rows[table] == [])
        }
        try await store.close()
    }

    @Test func tooManyRowsRejectsInsteadOfReturningTruncatedMigrationEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
        let permit = try #require(await store.processingPermit())
        for index in 0..<129 { _ = try await store.enqueue(Data("FAKE_\(index)".utf8), capturedAt: .now, permit: permit) }
        await #expect(throws: StorageError.stateTooLarge) { try await store.legacyMigrationRowsForTesting() }
        #expect(try await store.queueStatistics().count == 129)
        try await store.close()
    }
}
