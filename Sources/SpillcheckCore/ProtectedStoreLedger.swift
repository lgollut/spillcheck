import Foundation
import GRDB

/// The ledger rows as stored: the state row's envelope and revision, and every part and bucket row.
struct StoredLedgerRows: Sendable {
    let revision: Int64
    let state: Data
    let parts: [Int: Data]
    let buckets: [Int: Data]
}

/// Sealed segments ready for one transaction, with the layout that holds once it commits.
struct SealedLedgerWrite: Sendable {
    let isConversion: Bool
    let header: Data
    let parts: [(Int, Data)]
    let buckets: [(Int, Data)]
    let layout: LedgerLayoutState
    let coreChanged: Bool
    let notificationsChanged: Bool

    /// The rows a conversion leaves behind, to prove they read back before anything is written.
    func rows(revision: Int64) -> StoredLedgerRows {
        StoredLedgerRows(revision: revision, state: header, parts: Dictionary(uniqueKeysWithValues: parts),
                         buckets: Dictionary(uniqueKeysWithValues: buckets))
    }
}

/// The ledger of a partitioned vault as its segments assembled it, before the ledger normalizes it.
struct LedgerRead {
    let snapshot: InventorySnapshot
    let layout: LedgerLayoutState
}

extension ProtectedStore {
    static func readLedgerRows(_ database: DatabaseQueue) throws -> StoredLedgerRows? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT encoded, revision FROM store_state WHERE id = 1") else { return nil }
            func rows(_ table: String, _ key: String) throws -> [Int: Data] {
                Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT \(key), encoded FROM \(table)").map {
                    ($0[key] as Int, $0["encoded"] as Data)
                })
            }
            return StoredLedgerRows(revision: row["revision"], state: row["encoded"],
                parts: try rows("ledger_parts", "part"), buckets: try rows("ledger_buckets", "bucket"))
        }
    }

    /// Seals the segments a plan changes, each under its own binding.
    static func seal(_ plan: LedgerWritePlan, manifest: ProtectionManifest,
                     cryptography: any BackgroundStoreCryptography) async throws -> SealedLedgerWrite {
        func sealed(_ id: LedgerSegmentID, _ plaintext: Data) async throws -> Data {
            try await cryptography.sealBackground(plaintext, binding: id.binding(vaultID: manifest.vaultID)).encoded()
        }
        do {
            var parts: [(Int, Data)] = []
            for part in LedgerPart.allCases {
                if let plaintext = plan.parts[part] { parts.append((part.rawValue, try await sealed(.part(part), plaintext))) }
            }
            var buckets: [(Int, Data)] = []
            for bucket in plan.buckets.keys.sorted() {
                buckets.append((bucket, try await sealed(.bucket(bucket), plan.buckets[bucket] ?? Data())))
            }
            return SealedLedgerWrite(isConversion: plan.isConversion, header: try await sealed(.header, plan.header),
                parts: parts, buckets: buckets, layout: plan.layout,
                coreChanged: plan.coreChanged, notificationsChanged: plan.notificationsChanged)
        } catch { throw StorageError.protectionUnavailable }
    }

    /// Opens whichever layout the state row holds. It never writes: a version 1 ledger is returned with
    /// a layout that converts it on the first ordinary write.
    static func openLedger(_ rows: StoredLedgerRows, manifest: ProtectionManifest, cryptography: any BackgroundStoreCryptography,
                           limits: StoreLimits) async throws -> (InventoryLedger, LedgerLayoutState) {
        let envelope = try decode(rows.state, maximumBytes: limits.maxProtectedStateBytes * 2 + 1024)
        guard envelope.binding == ledgerBinding(manifest) else {
            let read = try await readSegments(rows, manifest: manifest, cryptography: cryptography, limits: limits)
            let ledger: InventoryLedger
            do { ledger = try InventoryLedger(snapshot: read.snapshot) } catch { throw StorageError.corruptProtectedState }
            // Whatever normalization changed is written by the next write. The notifications part is
            // written once as well, which resynchronizes the outbox tables with the ledger.
            var layout = read.layout
            let normalized = ledger.snapshot
            layout.forced = [.notifications]
            if LedgerCore(normalized) != LedgerCore(read.snapshot) { layout.forced.insert(.core) }
            if LedgerConversations(normalized) != LedgerConversations(read.snapshot) { layout.forced.insert(.conversations) }
            return (ledger, layout)
        }
        guard rows.parts.isEmpty, rows.buckets.isEmpty else { throw StorageError.corruptProtectedState }
        let plaintext: Data
        do {
            plaintext = try await cryptography.openBackground(envelope, binding: ledgerBinding(manifest))
        } catch { throw StorageError.protectionUnavailable }
        guard plaintext.count <= limits.maxProtectedStateBytes else { throw StorageError.stateTooLarge }
        do {
            let ledger = try InventoryLedger(snapshot: JSONDecoder().decode(InventorySnapshot.self, from: plaintext))
            return (ledger, .unpartitioned(revision: rows.revision))
        } catch { throw StorageError.corruptProtectedState }
    }

    /// Opens and checks every segment of a partitioned vault. A header that cannot be opened means the
    /// keys are unavailable; any other disagreement between the rows is corruption.
    static func readSegments(_ rows: StoredLedgerRows, manifest: ProtectionManifest,
                             cryptography: any BackgroundStoreCryptography, limits: StoreLimits) async throws -> LedgerRead {
        let bound = limits.maxProtectedStateBytes * 2 + 1024
        let headerBinding = LedgerSegmentID.header.binding(vaultID: manifest.vaultID)
        let envelope = try decode(rows.state, maximumBytes: bound)
        let headerPlaintext: Data
        do {
            headerPlaintext = try await cryptography.openBackground(envelope, binding: headerBinding)
        } catch { throw StorageError.protectionUnavailable }
        var sizes = LedgerLayoutState.Sizes()
        sizes.header = headerPlaintext.count
        var total = headerPlaintext.count
        guard total <= limits.maxProtectedStateBytes else { throw StorageError.stateTooLarge }
        let header: LedgerHeader
        do {
            header = try JSONDecoder().decode(LedgerHeader.self, from: headerPlaintext)
            try header.validate()
        } catch { throw StorageError.corruptProtectedState }
        guard header.revision == rows.revision, Set(rows.parts.keys) == Set(LedgerPart.allCases.map(\.rawValue)),
              Set(rows.buckets.keys) == Set(0..<header.bucketCount) else { throw StorageError.corruptProtectedState }

        func open<Body: Decodable>(_ id: LedgerSegmentID, _ stored: Data?, as type: Body.Type) async throws -> (Body, Int) {
            guard let stored else { throw StorageError.corruptProtectedState }
            let payload = try decode(stored, maximumBytes: bound)
            let binding = id.binding(vaultID: manifest.vaultID)
            // The slot's binding is checked before decrypting, so a row moved to another slot never opens.
            guard payload.binding == binding else { throw StorageError.corruptProtectedState }
            let plaintext: Data
            do { plaintext = try await cryptography.openBackground(payload, binding: binding) }
            catch { throw StorageError.corruptProtectedState }
            total += plaintext.count
            guard total <= limits.maxProtectedStateBytes else { throw StorageError.stateTooLarge }
            do { return (try JSONDecoder().decode(type, from: plaintext), plaintext.count) }
            catch { throw StorageError.corruptProtectedState }
        }
        let core = try await open(.part(.core), rows.parts[LedgerPart.core.rawValue], as: LedgerPartSegment<LedgerCore>.self)
        let notifications = try await open(.part(.notifications), rows.parts[LedgerPart.notifications.rawValue],
                                           as: LedgerPartSegment<LedgerNotifications>.self)
        let conversations = try await open(.part(.conversations), rows.parts[LedgerPart.conversations.rawValue],
                                           as: LedgerPartSegment<LedgerConversations>.self)
        sizes.parts = [core.1, notifications.1, conversations.1]
        var buckets: [LedgerBucketSegment] = []
        for index in 0..<header.bucketCount {
            let bucket = try await open(.bucket(index), rows.buckets[index], as: LedgerBucketSegment.self)
            buckets.append(bucket.0)
            sizes.buckets[index] = bucket.1
        }
        let assembled = try LedgerAssembly.assemble(header: header, core: core.0, notifications: notifications.0,
                                                    conversations: conversations.0, buckets: buckets)
        return LedgerRead(snapshot: assembled.snapshot, layout: LedgerLayoutState(
            isPartitioned: true, header: header, mirror: assembled.mirror, sizes: sizes, forced: []))
    }
}
