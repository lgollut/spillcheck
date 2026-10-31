import Foundation
import GRDB
import Testing
@_spi(Testing) @testable import SpillcheckCore

/// Records what the store seals under the ledger binding, by size and slot only. It never keeps plaintext.
actor LedgerSealSpy: BackgroundStoreCryptography {
    struct Seals {
        var bytes = 0
        var count = 0
        var largest = 0
        var references: [UUID] = []
    }

    nonisolated let manifest: ProtectionManifest
    private let delegate: BackgroundCryptography
    private var seals = Seals()

    init(_ delegate: BackgroundCryptography) { self.delegate = delegate; manifest = delegate.manifest }

    /// Everything sealed since the last call.
    func takeLedgerSeals() -> Seals {
        defer { seals = Seals() }
        return seals
    }

    func sealBackground(_ plaintext: Data, binding: PayloadBinding) async throws -> ProtectedPayload {
        if binding.kind == .ledgerSnapshot {
            seals.bytes += plaintext.count
            seals.count += 1
            seals.largest = max(seals.largest, plaintext.count)
            seals.references.append(binding.reference.id)
        }
        return try await delegate.sealBackground(plaintext, binding: binding)
    }
    func openBackground(_ payload: ProtectedPayload, binding: PayloadBinding) async throws -> Data {
        try await delegate.openBackground(payload, binding: binding)
    }
    func revision(canonicalBytes: Data) async throws -> ContentRevision {
        try await delegate.revision(canonicalBytes: canonicalBytes)
    }
}

/// Holds the next seal of one payload kind until released, so a test can run other work in between.
actor BlockingStoreCryptography: BackgroundStoreCryptography {
    nonisolated let manifest: ProtectionManifest
    let delegate: BackgroundCryptography
    var nextBlockedKind: ProtectedPayloadKind?
    var blocked = false
    var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    var releaseContinuation: CheckedContinuation<Void, Never>?

    init(_ delegate: BackgroundCryptography) { self.delegate = delegate; manifest = delegate.manifest }
    func blockNext(_ kind: ProtectedPayloadKind) { nextBlockedKind = kind; blocked = false }
    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
    func sealBackground(_ plaintext: Data, binding: PayloadBinding) async throws -> ProtectedPayload {
        if nextBlockedKind == binding.kind {
            nextBlockedKind = nil
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                blocked = true
                for waiter in blockedWaiters { waiter.resume() }
                blockedWaiters.removeAll()
            }
        }
        return try await delegate.sealBackground(plaintext, binding: binding)
    }
    func openBackground(_ payload: ProtectedPayload, binding: PayloadBinding) async throws -> Data {
        try await delegate.openBackground(payload, binding: binding)
    }
    func revision(canonicalBytes: Data) async throws -> ContentRevision {
        try await delegate.revision(canonicalBytes: canonicalBytes)
    }
}

/// Inventory payloads the store requires for an analysis' detections and source metadata.
func ledgerTestPayloads(for analysis: SourceAnalysis, crypto: BackgroundCryptography) async throws -> [ProtectedPayload] {
    var payloads: [ProtectedPayload] = []
    var references: Set<ProtectedPayloadReference> = []
    for finding in analysis.detections {
        if references.insert(finding.protectedValue).inserted {
            payloads.append(try await crypto.sealInventory(Data("SYNTHETIC_VALUE".utf8), binding: PayloadBinding(
                reference: finding.protectedValue, ownerID: finding.protectedValue.id, kind: .value)))
        }
        if let excerpt = finding.protectedExcerpt, references.insert(excerpt).inserted {
            payloads.append(try await crypto.sealInventory(Data("synthetic excerpt".utf8), binding: PayloadBinding(
                reference: excerpt, ownerID: excerpt.id, kind: .excerpt)))
        }
    }
    if let metadata = analysis.source.protectedMetadata, references.insert(metadata).inserted {
        payloads.append(try await crypto.sealInventory(Data("synthetic metadata".utf8), binding: PayloadBinding(
            reference: metadata, ownerID: metadata.id, kind: .sourceMetadata)))
    }
    return payloads
}

func ledgerTestDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-ledger-\(UUID())")
}

/// Compares all eighteen snapshot fields, so a failure names the field that differs.
func expectSnapshotsEqual(_ actual: InventorySnapshot, _ expected: InventorySnapshot, _ context: String = "",
                          sourceLocation: SourceLocation = #_sourceLocation) {
    let note = Comment(rawValue: context)
    #expect(actual.schemaVersion == expected.schemaVersion, note, sourceLocation: sourceLocation)
    #expect(actual.records == expected.records, note, sourceLocation: sourceLocation)
    #expect(actual.occurrences == expected.occurrences, note, sourceLocation: sourceLocation)
    #expect(actual.obsoleteAppearances == expected.obsoleteAppearances, note, sourceLocation: sourceLocation)
    #expect(actual.obsoleteMarkers == expected.obsoleteMarkers, note, sourceLocation: sourceLocation)
    #expect(actual.alertDecisions == expected.alertDecisions, note, sourceLocation: sourceLocation)
    #expect(actual.unlocatedResults == expected.unlocatedResults, note, sourceLocation: sourceLocation)
    #expect(actual.analysisReceipts == expected.analysisReceipts, note, sourceLocation: sourceLocation)
    #expect(actual.locationReceipts == expected.locationReceipts, note, sourceLocation: sourceLocation)
    #expect(actual.strongSignalReceipts == expected.strongSignalReceipts, note, sourceLocation: sourceLocation)
    #expect(actual.unlocatedReceipts == expected.unlocatedReceipts, note, sourceLocation: sourceLocation)
    #expect(actual.sourceKinds == expected.sourceKinds, note, sourceLocation: sourceLocation)
    #expect(actual.sourceTimes == expected.sourceTimes, note, sourceLocation: sourceLocation)
    #expect(actual.conversationLabels == expected.conversationLabels, note, sourceLocation: sourceLocation)
    #expect(actual.historicalNotificationDecisions == expected.historicalNotificationDecisions, note, sourceLocation: sourceLocation)
    #expect(actual.valueLabels == expected.valueLabels, note, sourceLocation: sourceLocation)
    #expect(actual.unlocatedLabels == expected.unlocatedLabels, note, sourceLocation: sourceLocation)
    #expect(actual.nextValueLabel == expected.nextValueLabel, note, sourceLocation: sourceLocation)
}

/// Both outbox tables as sorted strings, read through a second read-only connection.
func outboxRows(in directory: URL) throws -> (live: [String], historical: [String]) {
    var configuration = Configuration()
    configuration.readonly = true
    let database = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path,
        configuration: configuration)
    defer { try? database.close() }
    return try database.read { db in
        (try Row.fetchAll(db, sql: "SELECT id, value_id, delivery FROM notification_outbox ORDER BY id")
            .map { "\($0["id"] as String) \($0["value_id"] as String) \($0["delivery"] as String)" },
         try Row.fetchAll(db, sql: "SELECT audit_id, delivery FROM historical_notification_outbox ORDER BY audit_id")
            .map { "\($0["audit_id"] as String) \($0["delivery"] as String)" })
    }
}

/// What the outbox must hold for a snapshot.
func expectedOutbox(for snapshot: InventorySnapshot) -> (live: [String], historical: [String]) {
    (snapshot.alertDecisions.values.map { "\($0.id.uuidString) \($0.valueID.uuidString) \($0.delivery.rawValue)" }.sorted(),
     snapshot.historicalNotificationDecisions.values.map { "\($0.audit.id.uuidString) \($0.delivery.rawValue)" }.sorted())
}

/// A vault in a temporary directory that tests can close and reopen.
final class LedgerVault {
    let directory = ledgerTestDirectory()
    let crypto: BackgroundCryptography
    private(set) var store: ProtectedStore!

    init(crypto: BackgroundCryptography? = nil) throws {
        self.crypto = try crypto ?? BackgroundCryptography.ephemeralForTesting()
    }

    func open(cryptography: (any BackgroundStoreCryptography)? = nil, limits: StoreLimits = StoreLimits(),
              failureInjector: StorageFailureInjector? = nil) async throws {
        store = try await ProtectedStore.open(at: directory, cryptography: cryptography ?? crypto, limits: limits,
            failureInjector: failureInjector)
    }

    func close() async throws { try await store.close() }
    func remove() { try? FileManager.default.removeItem(at: directory) }

    func commit(_ analysis: SourceAnalysis) async throws {
        let permit = try #require(await store.processingPermit())
        _ = try await store.commit(analysis, payloads: ledgerTestPayloads(for: analysis, crypto: crypto), permit: permit)
    }

    func quiet(_ item: String, session: String = "session-1", revision: UInt8 = 1) async throws {
        try await commit(SourceAnalysis(source: sourceRecord(session: session, item: item, revision: revision),
            detectorVersion: "1", detections: []))
    }
}

/// Mutations of every kind the ledger supports, followed by `after(step name)`. Compaction runs last.
func runRichLedgerScript(on vault: LedgerVault, now: Date, compactingAt compaction: Date? = nil,
                         after: (String) async throws -> Void) async throws {
    let day: TimeInterval = 24 * 60 * 60
    func store() -> ProtectedStore { vault.store }
    try await after("empty vault")
    try await vault.commit(analysis(session: "live", item: "a", fingerprintByte: 1))
    try await after("live commit with a finding")
    try await vault.commit(SourceAnalysis(source: sourceRecord(session: "live", item: "quiet", revision: 2),
        detectorVersion: "fixture-1", detections: []))
    try await after("quiet commit")
    try await vault.commit(analysis(session: "live", item: "a", fingerprintByte: 1, detectorVersion: "fixture-1+partial"))
    try await after("partial analysis of a known source")
    try await vault.commit(analysis(session: "live", item: "quiet", fingerprintByte: 2, revision: 3))
    try await after("new revision with a new value")
    let unlocated = try sourceRecord(session: "live", item: "unlocated")
    try await vault.commit(SourceAnalysis(source: unlocated, detectorVersion: "fixture-1", detections: [],
        unlocated: [UnlocatedDetection(evidence: [evidence()], reason: .unavailableRange)]))
    try await after("unlocated result")

    let occurrence = try #require(await store().snapshot().occurrences.values.first { $0.identity.source.itemID == "a" })
    try await store().review(occurrence.id, as: .confirmedSecret)
    try await after("review")
    let pending = try #require(await store().snapshot().alertDecisions.values.first)
    try await store().recordAlertDelivery(pending.id, state: .delivered)
    try await after("alert delivery")

    let old = now.addingTimeInterval(-3 * day)
    try await vault.commit(analysis(session: "other", item: "old", fingerprintByte: 3, contentTime: old))
    try await store().acknowledgeObsolete(fingerprint(3), as: .revoked, at: now)
    try await after("acknowledge")
    _ = try await store().removeContent(for: fingerprint(3))
    try await after("remove content")
    try await vault.commit(analysis(session: "other", item: "after-removal", fingerprintByte: 3, contentTime: old))
    try await after("obsolete appearance")
    try await store().forgetObsoleteMarker(fingerprint(3))
    try await after("forget marker")
    // Content newer than the compaction cutoff keeps its removed-location receipt.
    try await vault.commit(analysis(session: "fresh", item: "fresh", fingerprintByte: 5, contentTime: now.addingTimeInterval(2 * day)))
    _ = try await store().removeContent(for: fingerprint(5))
    try await after("removed fresh content")

    let audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
    let permit = try #require(await store().processingPermit())
    let body = try CapturePacket(metadata: .init(agent: .codex, profileID: "fixture-profile"),
        eventJSON: JSONEncoder().encode(["page": "1"])).body
    _ = try await store().enqueue(body, capturedAt: now, permit: permit, at: now, historicalAudit: audit)
    let capture = try #require(try await store().nextPending(at: now, permit: permit))
    let historical = try analysis(session: "history", item: "h", fingerprintByte: 4, provenance: .historical(audit),
        contentTime: now.addingTimeInterval(-day))
    _ = try await store().commit(historical, payloads: ledgerTestPayloads(for: historical, crypto: vault.crypto),
        linking: capture, permit: permit, at: now)
    try await store().completeCapture(capture, historicalProgress: .init(audit: audit, bytesRead: 8,
        oldestContentTime: historical.source.contentTime, newestContentTime: historical.source.contentTime,
        hasUnreadContent: false), permit: permit, at: now)
    try await after("historical commit")
    let notifications = try await store().pendingNotifications()
    try #require(await store().snapshot().historicalNotificationDecisions.count == 1)
    try await after("historical settlement")
    for notification in notifications where notification.identifier.hasPrefix("leakret-audit-") {
        try await store().recordNotificationDelivery(identifier: notification.identifier, state: .delivered)
    }
    try await after("historical delivery")

    if let compaction {
        let before = await store().snapshot().sourceKinds.count
        #expect(try await store().compactProcessedSources(at: compaction))
        #expect(await store().snapshot().sourceKinds.count < before)
        try await after("compaction")
    }
}

/// Every row of every store table except the migration list, as comparable text.
func rowDump(of directory: URL) throws -> [String: [String]] {
    var configuration = Configuration()
    configuration.readonly = true
    let database = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path,
        configuration: configuration)
    defer { try? database.close() }
    return try database.read { db in
        var dump: [String: [String]] = [:]
        let tables = try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
            ORDER BY name
            """)
        for table in tables {
            dump[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY 1").map { row in
                row.databaseValues.map { value -> String in
                    switch value.storage {
                    case .null: "NULL"
                    case .int64(let number): String(number)
                    case .double(let number): String(number)
                    case .string(let string): string
                    case .blob(let data): data.base64EncodedString()
                    }
                }.joined(separator: "|")
            }
        }
        return dump
    }
}

/// Puts a vault back into the layout of a build before the partitioned ledger: the whole snapshot in
/// store_state and no partitioned rows. The store must be closed.
func downgradeToLegacyLedger(at directory: URL, snapshot: InventorySnapshot,
                             cryptography: any BackgroundStoreCryptography) async throws {
    let row = try await ProtectedStore.legacyLedgerRowForTesting(snapshot, cryptography: cryptography)
    let database = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path)
    defer { try? database.close() }
    try await database.write { db in
        try db.execute(sql: "DELETE FROM ledger_parts")
        try db.execute(sql: "DELETE FROM ledger_buckets")
        try db.execute(sql: "UPDATE store_state SET encoded = ? WHERE id = 1", arguments: [row])
    }
}
