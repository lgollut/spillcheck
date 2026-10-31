import CryptoKit
import Foundation
import GRDB
import Testing
@_spi(Testing) @testable import SpillcheckCore

private final class Trip: @unchecked Sendable {
    var point: StorageFailpoint?
    private(set) var fired = 0
    func injector() -> StorageFailureInjector {
        { [self] actual in
            if actual == point { fired += 1; throw StorageError.injectedFailure }
        }
    }
}

private func changedSegments(_ before: ProtectedStore.PersistedLedgerLayout,
                             _ after: ProtectedStore.PersistedLedgerLayout) -> Set<String> {
    let old = Dictionary(uniqueKeysWithValues: before.segments.map { ($0.id, $0) })
    return Set(after.segments.filter { old[$0.id] != $0 }.map(\.id))
}

private func withDatabase<T>(_ directory: URL, _ body: (Database) throws -> T) throws -> T {
    let database = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path)
    defer { try? database.close() }
    return try database.write(body)
}

/// Opens a stored segment with its own binding, changes it and seals it again under the same binding,
/// as a writer holding the keys could.
private func rewriteSegment<Body: Codable>(
    in directory: URL, crypto: BackgroundCryptography, table: String, key: String, slot: Int, id: LedgerSegmentID,
    as type: Body.Type, _ change: (inout Body) -> Void
) async throws {
    let stored = try withDatabase(directory) { try Data.fetchOne($0, sql: "SELECT encoded FROM \(table) WHERE \(key) = ?", arguments: [slot]) }
    let payload = try ProtectedPayload.decode(try #require(stored))
    let binding = id.binding(vaultID: crypto.manifest.vaultID)
    var body = try JSONDecoder().decode(type, from: await crypto.openBackground(payload, binding: binding))
    change(&body)
    let sealed = try await crypto.sealBackground(JSONEncoder().encode(body), binding: binding).encoded()
    try withDatabase(directory) { try $0.execute(sql: "UPDATE \(table) SET encoded = ? WHERE \(key) = ?", arguments: [sealed, slot]) }
}

/// The bucket salt of a closed vault, read the way the store reads its header.
private func bucketSalt(of directory: URL, crypto: BackgroundCryptography) async throws -> Data {
    let stored = try withDatabase(directory) { try #require(try Data.fetchOne($0, sql: "SELECT encoded FROM store_state")) }
    let payload = try ProtectedPayload.decode(stored)
    let plaintext = try await crypto.openBackground(payload, binding: LedgerSegmentID.header.binding(vaultID: crypto.manifest.vaultID))
    return try JSONDecoder().decode(LedgerHeader.self, from: plaintext).bucketSalt
}

private func copyVault(_ source: URL) throws -> URL {
    let copy = ledgerTestDirectory()
    try FileManager.default.copyItem(at: source, to: copy)
    return copy
}

@Suite("Partitioned sealed ledger persistence")
struct LedgerPersistenceTests {
    /// A vault holding `count` quiet sources spread over five sessions.
    private func quietVault(_ count: Int, cryptography: ((BackgroundCryptography) -> any BackgroundStoreCryptography)? = nil) async throws -> LedgerVault {
        let vault = try LedgerVault()
        try await vault.open(cryptography: cryptography?(vault.crypto))
        for index in 0..<count { try await vault.quiet("item-\(index)", session: "session-\(index % 5)") }
        return vault
    }

    // MARK: Cost of a write

    @Test func quietCommitSealsBoundedLedgerBytes() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let spy = LedgerSealSpy(crypto)
        let vault = try LedgerVault(crypto: crypto)
        defer { vault.remove() }
        try await vault.open(cryptography: spy)
        _ = await spy.takeLedgerSeals()
        var sealed: [Int] = []
        for index in 0..<500 {
            try await vault.quiet("item-\(index)", session: "session-\(index % 5)")
            sealed.append(await spy.takeLedgerSeals().bytes)
        }
        // The header and one bucket, however many sources the vault already holds.
        #expect(sealed[499] <= 16 * 1024, "the 500th commit sealed \(sealed[499]) bytes")
        #expect(sealed[499] <= sealed[9] + 8 * 1024, "10th commit: \(sealed[9]) bytes, 500th: \(sealed[499])")
        try await vault.close()
    }

    @Test func replayCommitSealsOnlyTheHeader() async throws {
        let vault = try await quietVault(40)
        defer { vault.remove() }
        let partial = try analysis(session: "session-1", item: "partial", detectorVersion: "1+partial")
        try await vault.commit(partial)
        let before = try await vault.store.persistedLayoutForTesting()
        let permit = try #require(await vault.store.processingPermit())
        let replay = try await vault.store.commit(partial, payloads: [], permit: permit)
        #expect(replay.outcome == .replay)
        let after = try await vault.store.persistedLayoutForTesting()
        #expect(after.revision == before.revision + 1)
        #expect(changedSegments(before, after) == ["header"])
        try await vault.close()
    }

    @Test func alertDeliverySealsOnlyNotificationState() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let spy = LedgerSealSpy(crypto)
        let vault = try LedgerVault(crypto: crypto)
        defer { vault.remove() }
        try await vault.open(cryptography: spy)
        for index in 0..<500 { try await vault.quiet("item-\(index)", session: "session-\(index % 5)") }
        try await vault.commit(analysis(session: "session-0", item: "finding"))
        let alert = try #require(await vault.store.snapshot().alertDecisions.keys.first)
        let before = try await vault.store.persistedLayoutForTesting()
        _ = await spy.takeLedgerSeals()
        try await vault.store.recordAlertDelivery(alert, state: .delivered)
        let sealed = await spy.takeLedgerSeals()
        #expect(sealed.bytes <= 4 * 1024, "delivery sealed \(sealed.bytes) bytes")
        #expect(changedSegments(before, try await vault.store.persistedLayoutForTesting()) == ["header", "part-2"])
        try await vault.close()
    }

    @Test func findingCommitTouchesCoreAndOneBucketOnly() async throws {
        let vault = try await quietVault(500)
        defer { vault.remove() }
        var layout = try await vault.store.persistedLayoutForTesting()
        try await vault.commit(analysis(session: "session-0", item: "finding"))
        var next = try await vault.store.persistedLayoutForTesting()
        var changed = changedSegments(layout, next)
        #expect(changed.isSuperset(of: ["header", "part-1", "part-2"]) && !changed.contains("part-3"))
        #expect(changed.filter { $0.hasPrefix("bucket-") }.count == 1 && changed.count == 4)
        layout = next
        try await vault.commit(analysis(session: "brand-new-session", item: "finding", fingerprintByte: 2))
        next = try await vault.store.persistedLayoutForTesting()
        changed = changedSegments(layout, next)
        #expect(changed.isSuperset(of: ["header", "part-1", "part-2", "part-3"]))
        #expect(changed.filter { $0.hasPrefix("bucket-") }.count == 1)
        try await vault.close()
    }

    @Test func storeStateHoldsOnlyTheHeader() async throws {
        let vault = try await quietVault(500)
        defer { vault.remove() }
        try await vault.close()
        let (state, parts, buckets) = try withDatabase(vault.directory) { db in
            (try Int.fetchOne(db, sql: "SELECT length(encoded) FROM store_state") ?? .max,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ledger_parts") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ledger_buckets") ?? 0)
        }
        #expect(state < 4 * 1024 && parts == 3 && buckets == 64)
    }

    @Test func aFreshVaultIsPartitionedFromItsFirstRow() async throws {
        let vault = try LedgerVault()
        defer { vault.remove() }
        try await vault.open()
        let layout = try await vault.store.persistedLayoutForTesting()
        #expect(layout.format == 2 && layout.revision == 0 && layout.segments.count == 68)
        #expect(Set(layout.segments.map(\.id)).count == 68 && layout.segments.allSatisfy { $0.writtenAtRevision == 0 })
        try await vault.close()
        try await vault.open()
        #expect(try await vault.store.persistedLayoutForTesting() == layout)
        #expect(await vault.store.snapshot().sourceKinds.isEmpty)
        try await vault.close()
    }

    // MARK: Converting a version 1 vault

    private func removingTimes(from snapshot: InventorySnapshot, for sources: Set<SourceIdentity>) -> InventorySnapshot {
        InventorySnapshot(schemaVersion: snapshot.schemaVersion, records: snapshot.records, occurrences: snapshot.occurrences,
            obsoleteAppearances: snapshot.obsoleteAppearances, obsoleteMarkers: snapshot.obsoleteMarkers,
            alertDecisions: snapshot.alertDecisions, unlocatedResults: snapshot.unlocatedResults,
            analysisReceipts: snapshot.analysisReceipts, locationReceipts: snapshot.locationReceipts,
            strongSignalReceipts: snapshot.strongSignalReceipts, unlocatedReceipts: snapshot.unlocatedReceipts,
            sourceKinds: snapshot.sourceKinds, sourceTimes: snapshot.sourceTimes.filter { !sources.contains($0.key) },
            conversationLabels: snapshot.conversationLabels,
            historicalNotificationDecisions: snapshot.historicalNotificationDecisions,
            valueLabels: snapshot.valueLabels, unlocatedLabels: snapshot.unlocatedLabels, nextValueLabel: snapshot.nextValueLabel)
    }

    /// A version 1 vault with content of every kind, including sources recorded before content times existed.
    private func legacyVault() async throws -> (vault: LedgerVault, snapshot: InventorySnapshot) {
        let vault = try LedgerVault()
        try await vault.open()
        let now = Date()
        try await runRichLedgerScript(on: vault, now: now, compactingAt: now.addingTimeInterval(10 * 24 * 60 * 60)) { _ in }
        let rich = await vault.store.snapshot()
        #expect(rich.locationReceipts.values.contains(.removed) && !rich.unlocatedResults.isEmpty)
        #expect(rich.analysisReceipts.contains { $0.detectorVersion.hasSuffix("+partial") })
        #expect(rich.sourceKinds.count > Set(rich.analysisReceipts.map(\.source)).count)
        #expect(!rich.alertDecisions.isEmpty && !rich.historicalNotificationDecisions.isEmpty)
        let untimed = Set(rich.sourceTimes.keys.sorted { $0.itemID < $1.itemID }.prefix(2))
        let legacy = removingTimes(from: rich, for: untimed)
        try await vault.close()
        try await downgradeToLegacyLedger(at: vault.directory, snapshot: legacy, cryptography: vault.crypto)
        return (vault, legacy)
    }

    @Test func legacyV1VaultOpensUnchangedAndConvertsOnFirstWrite() async throws {
        let (vault, legacy) = try await legacyVault()
        defer { vault.remove() }
        let rows = try rowDump(of: vault.directory)
        try await vault.open()
        #expect(try rowDump(of: vault.directory) == rows, "opening a version 1 vault must not write")
        expectSnapshotsEqual(await vault.store.snapshot(), try InventoryLedger(snapshot: legacy).snapshot, "opened version 1 vault")
        #expect(try await vault.store.persistedLayoutForTesting().format == 1)

        try await vault.quiet("first-write-after-upgrade", session: "live")
        let layout = try await vault.store.persistedLayoutForTesting()
        #expect(layout.format == 2 && layout.segments.count == 68)
        #expect(layout.segments.allSatisfy { $0.writtenAtRevision == layout.revision })
        let converted = await vault.store.snapshot()
        #expect(converted.sourceKinds.count == legacy.sourceKinds.count + 1)
        try await vault.close()

        try await vault.open()
        expectSnapshotsEqual(await vault.store.snapshot(), converted, "reopened converted vault")
        #expect(try outboxRows(in: vault.directory) == expectedOutbox(for: converted))
        #expect(try await vault.store.persistedLayoutForTesting() == layout)
        try await vault.close()
    }

    @Test func conversionWriteIsAtomic() async throws {
        for point in [StorageFailpoint.beforeProcessingCommit, .afterProcessingCommit] {
            let (vault, legacy) = try await legacyVault()
            defer { vault.remove() }
            let rows = try rowDump(of: vault.directory)
            let trip = Trip()
            trip.point = point
            try await vault.open(failureInjector: trip.injector())
            let revision = await vault.store.stateRevision()
            await #expect(throws: StorageError.injectedFailure) { try await vault.quiet("converting", session: "live") }
            #expect(trip.fired == 1)
            if point == .beforeProcessingCommit {
                // The transaction rolled back: version 1 byte for byte, and the new tables still empty.
                #expect(try rowDump(of: vault.directory) == rows)
                #expect(await vault.store.stateRevision() == revision)
                #expect(try await vault.store.persistedLayoutForTesting().format == 1)
                trip.point = nil
                try await vault.quiet("converting", session: "live")
                #expect(try await vault.store.persistedLayoutForTesting().format == 2)
            } else {
                #expect(try await vault.store.persistedLayoutForTesting().format == 2)
            }
            let expected = await vault.store.snapshot()
            try await vault.close()
            try await vault.open()
            expectSnapshotsEqual(await vault.store.snapshot(), expected, "\(point)")
            #expect(expected.sourceKinds.count == legacy.sourceKinds.count + 1)
            let layout = try await vault.store.persistedLayoutForTesting()
            #expect(layout.format == 2 && layout.segments.count == 68)
            try await vault.close()
        }
    }

    // MARK: Refusing an inconsistent layout

    @Test func inconsistentLayoutFailsClosedWithoutWriting() async throws {
        let vault = try await quietVault(60)
        defer { vault.remove() }
        try await vault.commit(analysis(session: "session-1", item: "finding"))
        try await vault.close()
        let early = try copyVault(vault.directory)
        defer { try? FileManager.default.removeItem(at: early) }
        try await vault.open()
        let layoutBefore = try await vault.store.persistedLayoutForTesting()
        try await vault.quiet("later", session: "session-1")
        let touched = try #require(changedSegments(layoutBefore, try await vault.store.persistedLayoutForTesting())
            .first { $0.hasPrefix("bucket-") })
        let snapshot = await vault.store.snapshot()
        let total = try await vault.store.stateSizeBreakdownForTesting().totalBytes
        try await vault.close()

        func bucketNumber(_ id: String) -> Int { Int(id.dropFirst("bucket-".count))! }
        let salt = try await bucketSalt(of: vault.directory, crypto: vault.crypto)
        let misfiled = try #require(snapshot.sourceKinds.keys.first)

        func row(_ directory: URL, _ table: String, _ key: String, _ slot: Int) throws -> Data {
            try withDatabase(directory) { try #require(try Data.fetchOne($0, sql: "SELECT encoded FROM \(table) WHERE \(key) = ?", arguments: [slot])) }
        }
        let other = (0..<64).first { $0 != bucketNumber(touched) }!

        var cases: [(String, (URL) async throws -> Void)] = [
            ("version 1 row beside partitioned rows", { directory in
                let legacy = try await ProtectedStore.legacyLedgerRowForTesting(snapshot, cryptography: vault.crypto)
                try withDatabase(directory) { try $0.execute(sql: "UPDATE store_state SET encoded = ?", arguments: [legacy]) }
            }),
            ("missing bucket", { directory in
                try withDatabase(directory) { try $0.execute(sql: "DELETE FROM ledger_buckets WHERE bucket = ?", arguments: [other]) }
            }),
            ("missing part", { directory in
                try withDatabase(directory) { try $0.execute(sql: "DELETE FROM ledger_parts WHERE part = 2") }
            }),
            ("swapped bucket ciphertexts", { directory in
                let first = try row(directory, "ledger_buckets", "bucket", bucketNumber(touched)), second = try row(directory, "ledger_buckets", "bucket", other)
                try withDatabase(directory) { db in
                    try db.execute(sql: "UPDATE ledger_buckets SET encoded = ? WHERE bucket = ?", arguments: [second, bucketNumber(touched)])
                    try db.execute(sql: "UPDATE ledger_buckets SET encoded = ? WHERE bucket = ?", arguments: [first, other])
                }
            }),
            ("swapped part ciphertexts", { directory in
                let first = try row(directory, "ledger_parts", "part", 1), second = try row(directory, "ledger_parts", "part", 3)
                try withDatabase(directory) { db in
                    try db.execute(sql: "UPDATE ledger_parts SET encoded = ? WHERE part = 1", arguments: [second])
                    try db.execute(sql: "UPDATE ledger_parts SET encoded = ? WHERE part = 3", arguments: [first])
                }
            }),
            ("bucket restored from an older copy", { directory in
                let old = try row(early, "ledger_buckets", "bucket", bucketNumber(touched))
                try withDatabase(directory) { try $0.execute(sql: "UPDATE ledger_buckets SET encoded = ? WHERE bucket = ?", arguments: [old, bucketNumber(touched)]) }
            }),
            ("header revision differs from the column", { directory in
                try withDatabase(directory) { try $0.execute(sql: "UPDATE store_state SET revision = revision + 1") }
            }),
            ("entry filed under another bucket", { directory in
                let wrong = (LedgerPlacement.bucket(of: misfiled, salt: salt) + 1) % LedgerLayout.bucketCount
                try await rewriteSegment(in: directory, crypto: vault.crypto, table: "ledger_buckets", key: "bucket", slot: wrong, id: .bucket(wrong), as: LedgerBucketSegment.self) { moved in
                    moved.sessions = [LedgerBucketSegment.Session(session: misfiled.session,
                        items: [LedgerBucketSegment.Item(itemID: misfiled.itemID, kind: .toolOutput, time: nil, receipts: [])])]
                }
            }),
            ("repeated session in a bucket", { directory in
                try await rewriteSegment(in: directory, crypto: vault.crypto, table: "ledger_buckets", key: "bucket", slot: bucketNumber(touched), id: .bucket(bucketNumber(touched)),
                                  as: LedgerBucketSegment.self) { $0.sessions += $0.sessions }
            }),
            ("core written at another revision", { directory in
                try await rewriteSegment(in: directory, crypto: vault.crypto, table: "ledger_parts", key: "part", slot: 1, id: .part(.core),
                                  as: LedgerPartSegment<LedgerCore>.self) { $0.writtenAtRevision -= 1 }
            }),
            ("core filed in another slot", { directory in
                try await rewriteSegment(in: directory, crypto: vault.crypto, table: "ledger_parts", key: "part", slot: 1, id: .part(.core),
                                  as: LedgerPartSegment<LedgerCore>.self) { $0.part = 2 }
            }),
        ]
        cases.append(("bucket sealed for another vault", { directory in
            let stranger = try LedgerVault()
            defer { stranger.remove() }
            try await stranger.open()
            try await stranger.close()
            let foreign = try row(stranger.directory, "ledger_buckets", "bucket", bucketNumber(touched))
            try withDatabase(directory) { try $0.execute(sql: "UPDATE ledger_buckets SET encoded = ? WHERE bucket = ?", arguments: [foreign, bucketNumber(touched)]) }
        }))

        for (name, tamper) in cases {
            let directory = try copyVault(vault.directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            try await tamper(directory)
            let rows = try rowDump(of: directory)
            await #expect(throws: StorageError.corruptProtectedState, "\(name)") {
                try await ProtectedStore.open(at: directory, cryptography: vault.crypto)
            }
            #expect(try rowDump(of: directory) == rows, "\(name) must leave every row unchanged")
            #expect(try ProtectedStore.probe(at: directory).state == .protectedDataPresent)
        }

        // The lowered limit bounds the sum of every segment, and the exact sum is accepted.
        let limited = try copyVault(vault.directory)
        defer { try? FileManager.default.removeItem(at: limited) }
        let rows = try rowDump(of: limited)
        await #expect(throws: StorageError.stateTooLarge) {
            try await ProtectedStore.open(at: limited, cryptography: vault.crypto, limits: .init(maxProtectedStateBytes: total - 1))
        }
        #expect(try rowDump(of: limited) == rows)
        let exact = try await ProtectedStore.open(at: limited, cryptography: vault.crypto, limits: .init(maxProtectedStateBytes: total))
        try await exact.close()

        // Keys that cannot open the header are an unavailable vault, not a damaged one.
        let wrongKeys = try BackgroundCryptography.ephemeralForTesting(manifest: vault.crypto.manifest)
        await #expect(throws: StorageError.protectionUnavailable) {
            try await ProtectedStore.open(at: vault.directory, cryptography: wrongKeys)
        }

        // The tables hold no slot beyond the layout's.
        #expect(throws: DatabaseError.self) {
            try withDatabase(vault.directory) { try $0.execute(sql: "INSERT INTO ledger_buckets (bucket, encoded) VALUES (64, x'00')") }
        }
        #expect(throws: DatabaseError.self) {
            try withDatabase(vault.directory) { try $0.execute(sql: "INSERT INTO ledger_parts (part, encoded) VALUES (4, x'00')") }
        }
    }

    @Test func labelsNormalizedAtOpenAreWrittenByTheNextWriteAndNeverRenumbered() async throws {
        let vault = try await quietVault(6)
        defer { vault.remove() }
        try await vault.commit(analysis(session: "session-1", item: "first", fingerprintByte: 1))
        try await vault.commit(analysis(session: "session-2", item: "second", fingerprintByte: 2))
        let labelled = await vault.store.snapshot()
        #expect(labelled.valueLabels.count == 2 && labelled.conversationLabels.count == 5)
        try await vault.close()
        // Rows as a writer that predates labels would have left them: opening assigns them.
        try await rewriteSegment(in: vault.directory, crypto: vault.crypto, table: "ledger_parts", key: "part", slot: 3,
            id: .part(.conversations), as: LedgerPartSegment<LedgerConversations>.self) { $0.body.conversationLabels = [:] }
        try await rewriteSegment(in: vault.directory, crypto: vault.crypto, table: "ledger_parts", key: "part", slot: 1,
            id: .part(.core), as: LedgerPartSegment<LedgerCore>.self) { $0.body.valueLabels = [:]; $0.body.nextValueLabel = 1 }
        let rows = try rowDump(of: vault.directory)

        try await vault.open()
        #expect(try rowDump(of: vault.directory) == rows, "opening must not write")
        let normalized = await vault.store.snapshot()
        #expect(normalized.valueLabels.count == 2 && normalized.conversationLabels.count == 5 && normalized.nextValueLabel == 3)
        let before = try await vault.store.persistedLayoutForTesting()
        try await vault.quiet("ordinary", session: "session-1")
        let changed = changedSegments(before, try await vault.store.persistedLayoutForTesting())
        #expect(changed.isSuperset(of: ["header", "part-1", "part-2", "part-3"]), "the labels open assigned must be written once")
        let written = await vault.store.snapshot()
        try await vault.close()

        try await vault.open()
        expectSnapshotsEqual(await vault.store.snapshot(), written, "labels after the write")
        #expect(await vault.store.snapshot().valueLabels == normalized.valueLabels)
        try await vault.close()
    }

    @Test func olderBuildsCannotReadV2() async throws {
        let vault = try await quietVault(10)
        defer { vault.remove() }
        try await vault.close()
        let manifest = vault.crypto.manifest
        let stored = try withDatabase(vault.directory) { try #require(try Data.fetchOne($0, sql: "SELECT encoded FROM store_state")) }
        let header = try ProtectedPayload.decode(stored)
        // An older build opens store_state under the vault-wide ledger binding and nothing else.
        let version1 = PayloadBinding(reference: ProtectedPayloadReference(id: manifest.vaultID), ownerID: manifest.vaultID, kind: .ledgerSnapshot)
        await #expect(throws: (any Error).self) { try await vault.crypto.openBackground(header, binding: version1) }
        let plaintext = try await vault.crypto.openBackground(header, binding: header.binding)
        #expect(header.binding != version1 && header.binding.ownerID == manifest.vaultID)
        #expect((try? JSONDecoder().decode(InventorySnapshot.self, from: plaintext)) == nil)

        // Only the new tables remain: the vault still counts as holding protected data.
        let directory = try copyVault(vault.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try withDatabase(directory) { db in
            for table in ["store_state", "protection_manifest", "protected_payloads", "captures", "capture_receipts",
                          "source_checkpoints", "coverage_gaps", "notification_outbox", "collection_authorities",
                          "historical_progress", "protected_preferences", "historical_notification_outbox",
                          "coverage_omissions", "collection_health_incidents", "collection_work",
                          "successful_collection_reads", "codex_hook_content_slots"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
        #expect(try ProtectedStore.probe(at: directory).state == .protectedDataPresent)
        try withDatabase(directory) { try $0.execute(sql: "DELETE FROM ledger_buckets") }
        #expect(try ProtectedStore.probe(at: directory).state == .protectedDataPresent)
        try withDatabase(directory) { try $0.execute(sql: "DELETE FROM ledger_parts") }
        #expect(try ProtectedStore.probe(at: directory).state == .empty)
    }
}

@Suite("Ledger writes that leave parts alone")
struct LedgerWriteScopeTests {
    @Test func aCommitThatLeavesTheCoreAloneSkipsThePayloadPresenceCheck() async throws {
        let vault = try LedgerVault()
        defer { vault.remove() }
        try await vault.open()
        try await vault.commit(analysis(session: "session", item: "finding"))
        // An excerpt row lost behind the store's back is found by a commit that references payloads,
        // not by one that cannot: only the core holds payload references.
        try withDatabase(vault.directory) { try $0.execute(sql: "DELETE FROM protected_payloads WHERE kind = 'excerpt'") }
        try await vault.quiet("quiet", session: "session")
        #expect(await vault.store.snapshot().sourceKinds.count == 2)
        await #expect(throws: StorageError.payloadMissing) {
            try await vault.commit(analysis(session: "session", item: "second", fingerprintByte: 2))
        }
        #expect(await vault.store.snapshot().sourceKinds.count == 2)
        try await vault.close()
    }

    @Test func outboxTablesAreRewrittenOnlyWhenNotificationsChange() async throws {
        let vault = try LedgerVault()
        defer { vault.remove() }
        try await vault.open()
        try await vault.commit(analysis(session: "session", item: "finding"))
        let alert = try #require(await vault.store.snapshot().alertDecisions.keys.first)
        try withDatabase(vault.directory) { db in
            try db.execute(sql: "CREATE TABLE outbox_log (id INTEGER PRIMARY KEY AUTOINCREMENT)")
            try db.execute(sql: """
                CREATE TRIGGER outbox_rewritten AFTER DELETE ON notification_outbox BEGIN INSERT INTO outbox_log (id) VALUES (NULL); END
                """)
        }
        func rewrites() throws -> Int { try withDatabase(vault.directory) { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM outbox_log") ?? 0 } }

        try await vault.quiet("quiet", session: "session")
        try await vault.commit(analysis(session: "session", item: "second", fingerprintByte: 1))
        #expect(try rewrites() == 0, "writes that leave the notifications part alone must not rewrite the outbox")
        try await vault.store.recordAlertDelivery(alert, state: .delivered)
        #expect(try rewrites() == 1)
        #expect(try outboxRows(in: vault.directory) == expectedOutbox(for: await vault.store.snapshot()))

        // The first write after open resynchronizes the outbox, as every write did before.
        try await vault.close()
        try withDatabase(vault.directory) { try $0.execute(sql: "UPDATE notification_outbox SET delivery = 'pending'") }
        try await vault.open()
        try await vault.quiet("after-open", session: "session")
        #expect(try outboxRows(in: vault.directory) == expectedOutbox(for: await vault.store.snapshot()))
        let resynchronized = try rewrites()
        try await vault.quiet("later", session: "session")
        #expect(try rewrites() == resynchronized)
        try await vault.close()
    }
}

@Suite("Ledger compaction and its mirror")
struct LedgerCompactionTests {
    private func changedBuckets(_ before: ProtectedStore.PersistedLedgerLayout, _ after: ProtectedStore.PersistedLedgerLayout) -> Int {
        changedSegments(before, after).filter { $0.hasPrefix("bucket-") }.count
    }

    private func vaultWithStaleSources(_ stale: Int, recent: Int) async throws -> LedgerVault {
        let vault = try LedgerVault()
        try await vault.open()
        let old = Date().addingTimeInterval(-20 * 24 * 60 * 60)
        for index in 0..<stale {
            try await vault.commit(SourceAnalysis(source: sourceRecord(item: "stale-\(index)", contentTime: old),
                detectorVersion: "1", detections: []))
        }
        for index in 0..<recent { try await vault.quiet("recent-\(index)", session: "session-\(index % 4)") }
        return vault
    }

    @Test func compactionRewritesOnlyTheBucketsOfTheSourcesItPrunes() async throws {
        let vault = try await vaultWithStaleSources(3, recent: 50)
        defer { vault.remove() }
        let before = try await vault.store.persistedLayoutForTesting()
        #expect(try await vault.store.compactProcessedSources())
        let after = try await vault.store.persistedLayoutForTesting()
        #expect(await vault.store.snapshot().sourceKinds.count == 50)
        #expect(changedBuckets(before, after) <= 3 && changedBuckets(before, after) >= 1)
        #expect(!changedSegments(before, after).contains { $0.hasPrefix("part-") })
        try await vault.close()
        try await vault.open()
        #expect(await vault.store.snapshot().sourceKinds.count == 50)
        try await vault.close()
    }

    @Test func aMirrorThatDisagreesWithTheLedgerIsRewrittenInFullWhenCompactionRuns() async throws {
        for pruning in [false, true] {
            let vault = try await vaultWithStaleSources(pruning ? 2 : 0, recent: 40)
            defer { vault.remove() }
            #expect(await vault.store.damageSourceMirrorForTesting())
            let before = try await vault.store.persistedLayoutForTesting()
            #expect(try await vault.store.compactProcessedSources() == pruning)
            if !pruning { try await vault.quiet("next", session: "session-1") }
            let after = try await vault.store.persistedLayoutForTesting()
            #expect(changedBuckets(before, after) == 64, "pruning: \(pruning)")
            let expected = await vault.store.snapshot()
            try await vault.close()
            try await vault.open()
            expectSnapshotsEqual(await vault.store.snapshot(), expected, "pruning: \(pruning)")
            // The repaired mirror now follows the journal again.
            let settled = try await vault.store.persistedLayoutForTesting()
            try await vault.quiet("settled", session: "session-1")
            #expect(changedBuckets(settled, try await vault.store.persistedLayoutForTesting()) == 1)
            try await vault.close()
        }
    }
}
