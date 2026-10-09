import Darwin
import Foundation
import GRDB

private struct StoredCapture: Sendable {
    let id: UUID
    let encoded: Data
    let capturedAt: Date
    let expiresAt: Date
    let retryCount: UInt
}

private struct ProgressSettlementRow: Equatable, Sendable {
    let id: String
    let encoded: Data
}

/// SQLite persists ciphertext and controlled structural indexes. All upstream identifiers,
/// source coordinates, keyed fingerprints and checkpoints live inside background-encrypted state.
/// One actor owns domain transitions; the database revision also rejects stale independent writers.
public actor ProtectedStore {
    /// Existing vaults retain this on-disk name, including SQLite's WAL and SHM sidecars.
    public static let databaseFilename = "leakret.sqlite"
    public nonisolated let directory: URL
    public nonisolated let manifest: ProtectionManifest
    private let database: DatabaseQueue
    private let cryptography: any BackgroundStoreCryptography
    private let limits: StoreLimits
    private let failureInjector: StorageFailureInjector?
    private var ledger: InventoryLedger
    private var revision: Int64
    private var monitoringEnabled = true
    private var generation = UUID()
    private var closed = false
    private var consecutiveLiveClaims = 0

    private init(
        directory: URL, manifest: ProtectionManifest, database: DatabaseQueue,
        cryptography: any BackgroundStoreCryptography, limits: StoreLimits,
        ledger: InventoryLedger, revision: Int64, failureInjector: StorageFailureInjector?
    ) {
        self.directory = directory
        self.manifest = manifest
        self.database = database
        self.cryptography = cryptography
        self.limits = limits
        self.ledger = ledger
        self.revision = revision
        self.failureInjector = failureInjector
    }

    /// Read-only and before key bootstrap. Any protected rows, including an empty-looking ledger
    /// that retains only receipts/obsolete markers, prohibit silently replacing missing keys.
    public nonisolated static func probe(at directory: URL) throws -> StoreProtectionProbe {
        let url = directory.appendingPathComponent(databaseFilename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return StoreProtectionProbe(state: .empty, manifest: nil)
        }
        try verifyOwnedRegularFile(url)
        var configuration = Configuration()
        configuration.readonly = true
        do {
            let db = try DatabaseQueue(path: url.path, configuration: configuration)
            defer { try? db.close() }
            return try db.read { connection in
                var hasProtectedRows = false
                for table in ["protection_manifest", "store_state", "protected_payloads", "captures", "capture_receipts",
                              "source_checkpoints", "coverage_gaps", "notification_outbox",
                              "collection_authorities", "historical_progress", "protected_preferences", "historical_notification_outbox"] {
                    if try connection.tableExists(table),
                       try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 > 0 {
                        hasProtectedRows = true
                    }
                }
                let manifest: ProtectionManifest?
                if try connection.tableExists("protection_manifest"),
                   let bytes = try Data.fetchOne(connection, sql: "SELECT encoded FROM protection_manifest WHERE id = 1") {
                    do {
                        let decoded = try JSONDecoder().decode(ProtectionManifest.self, from: bytes)
                        try decoded.validate()
                        manifest = decoded
                    } catch { throw StorageError.corruptProtectedState }
                } else { manifest = nil }
                return StoreProtectionProbe(
                    state: hasProtectedRows ? .protectedDataPresent : .empty, manifest: manifest
                )
            }
        } catch let error as StorageError { throw error }
        catch { throw StorageError.databaseUnavailable }
    }

    public static func open(
        at directory: URL, cryptography: any BackgroundStoreCryptography,
        limits: StoreLimits = StoreLimits(), failureInjector: StorageFailureInjector? = nil
    ) async throws -> ProtectedStore {
        guard limits.maxEventBytes > 0, limits.maxQueueBytes > 0, limits.maxQueueAge > 0,
              limits.maxQueueAge.isFinite, limits.claimDuration > 0, limits.claimDuration.isFinite,
              limits.maxProtectedStateBytes > 0 else { throw StorageError.invalidTime }
        let probe = try probe(at: directory)
        let manifest = await cryptography.manifest
        do { try manifest.validate() } catch { throw StorageError.manifestMismatch }
        if let existing = probe.manifest {
            guard existing == manifest else { throw StorageError.manifestMismatch }
        } else if probe.state == .protectedDataPresent { throw StorageError.manifestMissing }
        try prepareDirectory(directory)
        let databaseURL = directory.appendingPathComponent(databaseFilename)
        try prepareDatabaseFile(databaseURL)
        var configuration = Configuration()
        configuration.busyMode = .timeout(0.15)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = FULL")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 256")
            try db.execute(sql: "PRAGMA journal_size_limit = 1048576")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let database: DatabaseQueue
        do {
            database = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
            try migrate(database)
        } catch { throw StorageError.databaseUnavailable }
        do {
            let manifestData = try JSONEncoder().encode(manifest)
            let state = try Self.read(database) { db -> (Data?, Int64) in
                guard let row = try Row.fetchOne(db, sql: "SELECT encoded, revision FROM store_state WHERE id = 1") else {
                    return (nil, 0)
                }
                return (row["encoded"], row["revision"])
            }
            let ledger: InventoryLedger
            if let encoded = state.0 {
                let payload = try decode(encoded, maximumBytes: limits.maxProtectedStateBytes * 2)
                let plaintext: Data
                do {
                    plaintext = try await cryptography.openBackground(payload, binding: ledgerBinding(manifest))
                } catch { throw StorageError.protectionUnavailable }
                guard plaintext.count <= limits.maxProtectedStateBytes else { throw StorageError.stateTooLarge }
                do {
                    ledger = try InventoryLedger(snapshot: JSONDecoder().decode(InventorySnapshot.self, from: plaintext))
                } catch { throw StorageError.corruptProtectedState }
            } else {
                // A missing state row alongside protected artifacts is corruption, never an empty inventory.
                if probe.state == .protectedDataPresent { throw StorageError.corruptProtectedState }
                ledger = InventoryLedger()
                let bytes = try JSONEncoder().encode(ledger.snapshot)
                let payload = try await cryptography.sealBackground(bytes, binding: ledgerBinding(manifest))
                let encoded = try payload.encoded()
                try Self.write(database) { db in
                    guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM protection_manifest") == 0,
                          try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM store_state") == 0 else {
                        throw StorageError.corruptProtectedState
                    }
                    // Bootstrap is one transaction; an existing manifest never licenses empty reset.
                    try db.execute(sql: "INSERT INTO protection_manifest (id, encoded) VALUES (1, ?)", arguments: [manifestData])
                    try db.execute(sql: "INSERT INTO store_state (id, revision, encoded) VALUES (1, 0, ?)", arguments: [encoded])
                }
            }
            try restrictFileModes(in: directory)
            return ProtectedStore(
                directory: directory, manifest: manifest, database: database,
                cryptography: cryptography, limits: limits, ledger: ledger,
                revision: state.1, failureInjector: failureInjector
            )
        } catch {
            try? database.close()
            if let error = error as? StorageError { throw error }
            if error is ProtectionError || error is KeyUnavailable { throw StorageError.protectionUnavailable }
            throw StorageError.databaseUnavailable
        }
    }

    public func close() throws {
        monitoringEnabled = false
        generation = UUID()
        guard !closed else { return }
        do { try database.close(); closed = true }
        catch { throw StorageError.databaseUnavailable }
    }

    public func setMonitoring(enabled: Bool) { monitoringEnabled = enabled; generation = UUID() }
    public func processingPermit() -> StoreProcessingPermit? {
        monitoringEnabled && !closed ? StoreProcessingPermit(generation: generation) : nil
    }
    public func snapshot() -> InventorySnapshot { ledger.snapshot }

    public func pendingLiveAlerts() -> [AlertDecision] {
        guard monitoringEnabled, !closed else { return [] }
        return ledger.alertDecisions.values.filter { ledger.alertIsEligible($0) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Unread or unsettled history stays in the in-app summary. It never creates a system summary.
    /// The final transaction rechecks both the empty queue and the exact progress rows after sealing.
    public func pendingHistoricalNotifications() async throws -> [HistoricalNotificationDecision] {
        guard let permit = processingPermit(), try queueStatistics().count == 0 else { return [] }
        let expectedRevision = revision
        let rows = try progressSettlementRows()
        guard rows.count <= 1000 else {
            try await recordNotificationBudgetGap(permit: permit)
            return []
        }
        let progress = try await decodeSettlement(rows)
        try check(permit)
        guard revision == expectedRevision else { return [] }
        let settled = Set(Dictionary(grouping: progress, by: { $0.progress.audit.id }).compactMap { id, values in
            values.allSatisfy { !$0.progress.hasUnreadContent } ? id : nil
        })
        let summaries = try ledger.snapshot.historicalSummaries()
        let needsDecision = summaries.contains {
            settled.contains($0.audit.id) && $0.shouldNotify && ledger.historicalNotificationDecisions[$0.audit.id] == nil
        }
        if needsDecision {
            try await mutateLedger(settlement: rows, notificationPermit: permit) {
                try $0.settleHistoricalNotifications(auditIDs: settled)
            }
        }
        try check(permit)
        guard try queueStatistics().count == 0, try progressSettlementRows() == rows else { return [] }
        return ledger.historicalNotificationDecisions.values.filter { $0.delivery == .pending && settled.contains($0.audit.id) }
            .sorted { $0.audit.end > $1.audit.end }
    }

    public func pendingNotifications() async throws -> [MaskedNotification] {
        let historical = try await pendingHistoricalNotifications().map(MaskedNotification.historical)
        let live = pendingLiveAlerts().compactMap { alert -> MaskedNotification? in
            guard let label = ledger.conversationLabels[alert.eligibility.session] else { return nil }
            return .live(alert, conversation: label)
        }
        return live + historical
    }

    public func notificationTargetExists(_ target: NotificationNavigationTarget) -> Bool {
        guard !closed else { return false }
        switch target {
        case .value(let id): return ledger.records.values.contains { $0.id == id }
        case .historicalAudit(let id): return (try? ledger.snapshot.historicalSummaries().contains { $0.audit.id == id }) == true
        }
    }

    public func notificationIsEligible(identifier: String) async throws -> Bool {
        try await pendingNotifications().contains { $0.identifier == identifier }
    }

    public func notificationIsEligible(_ notification: MaskedNotification) async throws -> Bool {
        try await pendingNotifications().contains(notification)
    }

    public func notificationCanRemain(identifier: String) throws -> Bool {
        try currentNotification(identifier: identifier) != nil
    }

    public func notificationCanRemain(_ notification: MaskedNotification) throws -> Bool {
        try currentNotification(identifier: notification.identifier) == notification
    }

    private func currentNotification(identifier: String) throws -> MaskedNotification? {
        guard !closed else { return nil }
        if let alert = ledger.alertDecisions.values.first(where: { $0.notificationIdentifier == identifier }),
           ledger.alertHasEligibleContent(alert), let label = ledger.conversationLabels[alert.eligibility.session] {
            return .live(alert, conversation: label)
        }
        guard let decision = ledger.historicalNotificationDecisions.values.first(where: { $0.notificationIdentifier == identifier }),
              decision.delivery != .cancelled,
              let summary = try ledger.snapshot.historicalSummaries().first(where: { $0.audit.id == decision.audit.id }), summary.shouldNotify else {
            return nil
        }
        return .historical(HistoricalNotificationDecision(summary: summary, delivery: decision.delivery))
    }

    public func recordNotificationDelivery(identifier: String, state: AlertDeliveryState) async throws {
        guard let permit = processingPermit() else { throw StorageError.monitoringPaused }
        if let alert = ledger.alertDecisions.values.first(where: { $0.notificationIdentifier == identifier }) {
            try await mutateLedger(notificationPermit: permit) { try $0.recordAlertDelivery(alert.id, state: state) }
        } else if let decision = ledger.historicalNotificationDecisions.values.first(where: { $0.notificationIdentifier == identifier }) {
            try await mutateLedger(notificationPermit: permit) { try $0.recordHistoricalNotificationDelivery(decision.audit.id, state: state) }
        } else { throw ContractError.invalidState }
    }

    public func recordHistoricalNotificationDelivery(auditID: UUID, state: AlertDeliveryState) async throws {
        try await recordNotificationDelivery(identifier: "leakret-audit-\(auditID.uuidString.lowercased())", state: state)
    }

    public func protectedPreference(_ key: ProtectedPreferenceKey) async throws -> Data? {
        guard !closed else { throw StorageError.databaseUnavailable }
        let id = try await preferenceID(key)
        guard let encoded = try Self.read(database, { db in
            try Data.fetchOne(db, sql: "SELECT encoded FROM protected_preferences WHERE id = ?", arguments: [id.uuidString])
        }) else { return nil }
        let payload = try Self.decode(encoded, maximumBytes: ProtectedPreferenceKey.maximumBytes * 2 + 4096)
        let bytes = try await cryptography.openBackground(payload, binding: Self.checkpointBinding(id))
        guard !closed, bytes.count <= ProtectedPreferenceKey.maximumBytes else { throw StorageError.invalidPayload }
        return bytes
    }

    public func setProtectedPreference(_ data: Data, for key: ProtectedPreferenceKey) async throws {
        guard !closed else { throw StorageError.databaseUnavailable }
        guard data.count <= ProtectedPreferenceKey.maximumBytes else { throw StorageError.stateTooLarge }
        let id = try await preferenceID(key)
        let payload = try await cryptography.sealBackground(data, binding: Self.checkpointBinding(id))
        let encoded = try payload.encoded()
        guard !closed else { throw StorageError.databaseUnavailable }
        try Self.write(database) { db in
            try db.execute(sql: "INSERT INTO protected_preferences (id, encoded) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET encoded = excluded.encoded",
                arguments: [id.uuidString, encoded])
        }
    }

    private func preferenceID(_ key: ProtectedPreferenceKey) async throws -> UUID {
        try await structuralID(Data("protected-app-preference-v1:\(key.rawValue)".utf8))
    }

    private func progressSettlementRows() throws -> [ProgressSettlementRow] {
        try Self.read(database) { db in
            try Row.fetchAll(db, sql: "SELECT id, encoded FROM historical_progress ORDER BY id LIMIT 1001").map {
                ProgressSettlementRow(id: $0["id"], encoded: $0["encoded"])
            }
        }
    }

    private func decodeSettlement(_ rows: [ProgressSettlementRow]) async throws -> [StoredHistoricalProgress] {
        var progress: [StoredHistoricalProgress] = []
        for row in rows {
            guard let id = UUID(uuidString: row.id) else { throw StorageError.corruptProtectedState }
            let plaintext = try await cryptography.openBackground(Self.decode(row.encoded), binding: Self.checkpointBinding(id))
            progress.append(try JSONDecoder().decode(StoredHistoricalProgress.self, from: plaintext))
        }
        return progress
    }

    public func enqueue(
        _ captureBody: Data, id: UUID = UUID(), capturedAt: Date,
        permit: StoreProcessingPermit, at now: Date = Date(), scope: LiveCaptureScope? = nil,
        historicalAudit: HistoricalAuditContext? = nil
    ) async throws -> QueueInsertion {
        try check(permit)
        guard capturedAt.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite else {
            throw StorageError.invalidTime
        }
        guard !captureBody.isEmpty, captureBody.count <= limits.maxEventBytes else {
            throw StorageError.captureTooLarge
        }
        let expiresAt = capturedAt.addingTimeInterval(limits.maxQueueAge)
        guard expiresAt > now else {
            try await recordGap(CoverageGap(reason: .queueExpired), at: now)
            throw StorageError.expiredCapture
        }
        try await expirePending(at: now, permit: permit)
        let payload: ProtectedPayload
        do {
            payload = try await cryptography.sealBackground(
                CapturedWorkCodec.encode(captureBody, scope: scope, historicalAudit: historicalAudit),
                binding: Self.captureBinding(id))
        }
        catch { throw StorageError.protectionUnavailable }
        let encoded = try payload.encoded()
        try check(permit)
        let maxBytes = limits.maxQueueBytes
        let injector = failureInjector
        do {
            let result = try Self.write(database) { db -> QueueInsertion in
                if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capture_receipts WHERE id = ?", arguments: [id.uuidString]) == 1 {
                    return .alreadyProcessed(id)
                }
                if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM captures WHERE id = ?", arguments: [id.uuidString]) == 1 {
                    return .alreadyQueued(id)
                }
                let bytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(byte_count), 0) FROM captures") ?? 0
                guard encoded.count <= maxBytes, bytes <= maxBytes - encoded.count else { throw StorageError.queueSaturated }
                try db.execute(sql: """
                    INSERT INTO captures (id, encoded, byte_count, captured_at, expires_at, retry_count, available_at, state, work_class)
                    VALUES (?, ?, ?, ?, ?, 0, ?, 0, ?)
                    """, arguments: [id.uuidString, encoded, encoded.count,
                                      capturedAt.timeIntervalSince1970, expiresAt.timeIntervalSince1970, now.timeIntervalSince1970,
                                      historicalAudit == nil ? 0 : 1])
                try injector?(.beforeEnqueueCommit)
                return .inserted(id)
            }
            try Self.restrictFileModes(in: directory)
            try injector?(.afterEnqueueCommit)
            return result
        } catch StorageError.queueSaturated {
            try await recordGap(CoverageGap(reason: .queueSaturated), at: now)
            throw StorageError.queueSaturated
        } catch let error as StorageError { throw error }
        catch { throw StorageError.databaseUnavailable }
    }

    public func queueStatistics() throws -> StoreQueueStatistics {
        do {
            return try Self.read(database) { db in
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM captures") ?? 0
                let bytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(byte_count), 0) FROM captures") ?? 0
                let claimed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM captures WHERE state = 1") ?? 0
                return StoreQueueStatistics(count: count, encryptedBytes: bytes, claimedCount: claimed)
            }
        } catch { throw StorageError.databaseUnavailable }
    }

    /// Age-limit maintenance also runs while paused. It never reads captured plaintext, scans,
    /// changes inventory, accepts a payload or creates an alert. Work is bounded per refresh.
    @discardableResult
    public func maintainQueue(at now: Date = Date(), limit: Int = 256) async throws -> Int {
        guard !closed else { throw StorageError.databaseUnavailable }
        guard now.timeIntervalSince1970.isFinite, limit > 0, limit <= 4096 else { throw StorageError.invalidTime }
        let ids: [String]
        do {
            ids = try Self.read(database) { db in
                try String.fetchAll(db, sql: "SELECT id FROM captures WHERE expires_at <= ? ORDER BY expires_at LIMIT ?",
                                    arguments: [now.timeIntervalSince1970, limit])
            }
        } catch { throw StorageError.databaseUnavailable }
        try pruneBookkeeping(at: now)
        guard !ids.isEmpty else { return 0 }
        let gap = try await sealedGap(CoverageGap(reason: .queueExpired), at: now)
        guard !closed else { throw StorageError.databaseUnavailable }
        do {
            return try Self.write(database) { db in
                var removed = 0
                for rawID in ids {
                    guard let id = UUID(uuidString: rawID) else { throw StorageError.corruptProtectedState }
                    if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM captures WHERE id = ? AND expires_at <= ?",
                                        arguments: [id.uuidString, now.timeIntervalSince1970]) == 1 {
                        try Self.consumeCapture(id, in: db)
                        removed += 1
                    }
                }
                if removed > 0 { try Self.insertGap(gap, at: now, in: db) }
                return removed
            }
        } catch let error as StorageError { throw error }
        catch { throw StorageError.databaseUnavailable }
    }

    /// Capture receipts only deduplicate retried deliveries of a pending capture, which expire with
    /// the queue. Gap rows remain visible for a bounded period; current status uses `recentGapWindow`.
    public static let captureReceiptRetention: TimeInterval = 2 * 24 * 60 * 60
    public static let coverageGapRetention: TimeInterval = 30 * 24 * 60 * 60
    private var lastBookkeepingPrune = Date.distantPast

    private func pruneBookkeeping(at now: Date) throws {
        guard now.timeIntervalSince(lastBookkeepingPrune) >= 60 * 60 || now < lastBookkeepingPrune else { return }
        let receiptCutoff = now.timeIntervalSince1970 - max(Self.captureReceiptRetention, 2 * limits.maxQueueAge)
        do {
            try Self.write(database) { db in
                try db.execute(sql: "DELETE FROM capture_receipts WHERE consumed_at < ?", arguments: [receiptCutoff])
                try db.execute(sql: "DELETE FROM coverage_gaps WHERE created_at < ?",
                               arguments: [now.timeIntervalSince1970 - Self.coverageGapRetention])
            }
        } catch { throw StorageError.databaseUnavailable }
        lastBookkeepingPrune = now
    }

    /// Bounded ledger growth: processed-source receipts beyond the analysis horizon cannot match
    /// future work. Runs between captures so it never invalidates an in-flight commit.
    @discardableResult
    public func compactProcessedSources(at now: Date = Date()) async throws -> Bool {
        guard !closed else { throw StorageError.databaseUnavailable }
        let cutoff = now.addingTimeInterval(-HistoricalAuditContext.receiptHorizon)
        guard ledger.needsProcessedSourceCompaction(before: cutoff) else { return false }
        try await mutateLedger { ledger in ledger.pruneProcessedSources(before: cutoff, stampingUntimedAt: now) }
        return true
    }

    public func nextPending(at now: Date, permit: StoreProcessingPermit) async throws -> PendingCapture? {
        try check(permit)
        try await expirePending(at: now, permit: permit)
        try check(permit)
        let claimID = UUID()
        let leaseEnd = now.addingTimeInterval(limits.claimDuration)
        let priority = consecutiveLiveClaims >= 4 ? "DESC" : "ASC"
        var claimedHistory = false
        do {
            let stored = try Self.write(database) { db -> StoredCapture? in
                try db.execute(sql: "UPDATE captures SET state = 0, claim_id = NULL, lease_until = NULL WHERE state = 1 AND lease_until <= ?",
                               arguments: [now.timeIntervalSince1970])
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT id, encoded, captured_at, expires_at, retry_count, work_class FROM captures
                    WHERE state = 0 AND available_at <= ? AND expires_at > ?
                    ORDER BY work_class \(priority), captured_at, id LIMIT 1
                    """, arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970]) else { return nil }
                guard let id = UUID(uuidString: row["id"]), let retryCount = UInt(exactly: row["retry_count"] as Int64) else {
                    throw StorageError.corruptProtectedState
                }
                claimedHistory = row["work_class"] as Int == 1
                try db.execute(sql: "UPDATE captures SET state = 1, claim_id = ?, lease_until = ? WHERE id = ?",
                               arguments: [claimID.uuidString, leaseEnd.timeIntervalSince1970, id.uuidString])
                return StoredCapture(id: id, encoded: row["encoded"], capturedAt: Date(timeIntervalSince1970: row["captured_at"]),
                                     expiresAt: Date(timeIntervalSince1970: row["expires_at"]), retryCount: retryCount)
            }
            guard let stored else { return nil }
            consecutiveLiveClaims = claimedHistory ? 0 : min(4, consecutiveLiveClaims + 1)
            let payload = try Self.decode(stored.encoded)
            guard payload.binding == Self.captureBinding(stored.id) else { throw StorageError.invalidPayload }
            return PendingCapture(id: stored.id, claimID: claimID, capturedAt: stored.capturedAt,
                                  expiresAt: stored.expiresAt, retryCount: stored.retryCount, encryptedPayload: payload)
        } catch let error as StorageError { throw error }
        catch { throw StorageError.databaseUnavailable }
    }

    public func openCapture(_ capture: PendingCapture) async throws -> Data {
        try await openCapturedWork(capture).body
    }

    public func openCapturedWork(_ capture: PendingCapture) async throws -> OpenedCapture {
        do {
            let bytes = try await cryptography.openBackground(capture.encryptedPayload, binding: Self.captureBinding(capture.id))
            return try CapturedWorkCodec.decode(bytes)
        }
        catch { throw StorageError.protectionUnavailable }
    }

    /// A current claim can be associated with already-known values before sealing/scanner retries.
    /// Content removal uses only these controlled inventory UUIDs to purge related retry work.
    public func associateDetectedValues(
        _ capture: PendingCapture, fingerprints: Set<ValueFingerprint>, permit: StoreProcessingPermit
    ) throws {
        try check(permit)
        let ids = fingerprints.compactMap { ledger.records[$0]?.id }
        do {
            try Self.write(database) { db in
                try Self.checkClaim(capture, in: db, at: Date())
                for id in ids {
                    try db.execute(sql: "INSERT OR IGNORE INTO capture_value_links (capture_id, value_id) VALUES (?, ?)",
                                   arguments: [capture.id.uuidString, id.uuidString])
                }
            }
        } catch let error as StorageError { throw error }
        catch { throw StorageError.databaseUnavailable }
    }

    public func retry(
        _ capture: PendingCapture, reason: CoverageGapReason, at now: Date,
        permit: StoreProcessingPermit
    ) async throws {
        try check(permit)
        let count = capture.retryCount + 1
        let shouldDrop = count > limits.maxRetryCount || capture.expiresAt <= now
        let gap = try await sealedGap(CoverageGap(reason: reason), at: now)
        try check(permit)
        do {
            try Self.write(database) { db in
                try Self.checkClaim(capture, in: db, at: now, allowExpired: true)
                if shouldDrop {
                    try Self.consumeCapture(capture.id, in: db)
                    try Self.insertGap(gap, at: now, in: db)
                } else {
                    let delay = min(60.0, pow(2.0, Double(min(count, 6))))
                    try db.execute(sql: """
                        UPDATE captures SET state = 0, claim_id = NULL, lease_until = NULL,
                        retry_count = ?, available_at = ? WHERE id = ?
                        """, arguments: [Int64(count), now.addingTimeInterval(delay).timeIntervalSince1970, capture.id.uuidString])
                }
            }
        } catch let error as StorageError { throw error }
        catch { throw StorageError.databaseUnavailable }
    }

    public func commit(
        _ analysis: SourceAnalysis, payloads: [ProtectedPayload], checkpoint: SourceCheckpoint? = nil,
        consuming capture: PendingCapture? = nil, linking linkedCapture: PendingCapture? = nil,
        permit: StoreProcessingPermit, at now: Date = Date()
    ) async throws -> InventoryTransition {
        try check(permit)
        let expectedRevision = revision
        var next = ledger
        let transition = try next.ingest(analysis)
        let encodedState = try await sealSnapshot(next.snapshot)
        let checkpointPayload: ProtectedPayload?
        if let checkpoint {
            do {
                checkpointPayload = try await cryptography.sealBackground(
                    JSONEncoder().encode(checkpoint), binding: Self.checkpointBinding(checkpoint.sourceDocumentID)
                )
            } catch { throw StorageError.protectionUnavailable }
        } else { checkpointPayload = nil }
        try check(permit)
        guard revision == expectedRevision else { throw StorageError.stateChanged }
        let required = try Self.requiredPayloads(in: next.snapshot)
        let inserts = try checkedPayloads(payloads, required: required)
        let injector = failureInjector
        let nextSnapshot = next.snapshot
        let linkedIDs = Set(analysis.detections.compactMap { nextSnapshot.records[$0.fingerprint]?.id })
        let checkpointEncoded = try checkpointPayload?.encoded()
        do {
            try Self.write(database) { db in
                try Self.checkRevision(expectedRevision, in: db)
                if let capture { try Self.checkClaim(capture, in: db, at: now) }
                if let linkedCapture { try Self.checkClaim(linkedCapture, in: db, at: now) }
                try Self.insertPayloads(inserts, required: required, in: db)
                try Self.writeState(encodedState, snapshot: nextSnapshot, revision: expectedRevision + 1, in: db)
                if let linkedCapture {
                    // Newly created values and their pending raw capture become related atomically.
                    // A deletion immediately after commit can purge this multi-record retry too.
                    for id in linkedIDs {
                        try db.execute(sql: "INSERT OR IGNORE INTO capture_value_links (capture_id, value_id) VALUES (?, ?)",
                            arguments: [linkedCapture.id.uuidString, id.uuidString])
                    }
                }
                if let checkpoint, let checkpointEncoded {
                    try db.execute(sql: "INSERT INTO source_checkpoints (document_id, encoded) VALUES (?, ?) ON CONFLICT(document_id) DO UPDATE SET encoded = excluded.encoded",
                                   arguments: [checkpoint.sourceDocumentID.uuidString, checkpointEncoded])
                }
                if let capture { try Self.consumeCapture(capture.id, in: db) }
                try injector?(.beforeProcessingCommit)
            }
            ledger = next
            revision = expectedRevision + 1
            try Self.restrictFileModes(in: directory)
            try injector?(.afterProcessingCommit)
            return transition
        } catch let error as StorageError { throw error }
        catch { throw StorageError.databaseUnavailable }
    }

    public func payload(_ reference: ProtectedPayloadReference) throws -> ProtectedPayload? {
        do {
            guard let encoded = try Self.read(database, { db in
                try Data.fetchOne(db, sql: "SELECT encoded FROM protected_payloads WHERE reference_id = ?", arguments: [reference.id.uuidString])
            }) else { return nil }
            let payload = try Self.decode(encoded)
            guard payload.binding.reference == reference else { throw StorageError.invalidPayload }
            return payload
        } catch let error as StorageError { throw error }
        catch { throw StorageError.databaseUnavailable }
    }

    /// Multi-record capture work keeps its encrypted queue row until all source commits finish.
    /// A crash before this transaction replays those source receipts; progress can lag, never lead.
    public func completeCapture(
        _ capture: PendingCapture, checkpoints: [SourceCheckpoint] = [],
        continuation: CapturePacket? = nil, historicalProgress: HistoricalReadProgress? = nil,
        permit: StoreProcessingPermit, at now: Date = Date()
    ) async throws {
        try check(permit)
        guard now.timeIntervalSince1970.isFinite else { throw StorageError.invalidTime }
        guard checkpoints.count <= 256,
              Set(checkpoints.map(\.sourceDocumentID)).count == checkpoints.count else {
            throw StorageError.invalidPayload
        }
        var prepared: [(UUID, Data)] = []
        for checkpoint in checkpoints {
            let bytes = try JSONEncoder().encode(checkpoint)
            guard bytes.count <= limits.maxProtectedStateBytes else { throw StorageError.stateTooLarge }
            let protected = try await cryptography.sealBackground(bytes, binding: Self.checkpointBinding(checkpoint.sourceDocumentID))
            prepared.append((checkpoint.sourceDocumentID, try protected.encoded()))
        }
        var nextCapture: (id: UUID, bytes: Data, workClass: Int)?
        var progressPayload: (id: UUID, bytes: Data)?
        if continuation != nil || historicalProgress != nil {
            let opened = try await openCapturedWork(capture)
            let original = try CapturePacket(body: opened.body)
            if let continuation {
                guard continuation.metadata == original.metadata,
                      continuation.body.count <= limits.maxEventBytes else { throw StorageError.invalidPayload }
                let id = UUID()
                let protected = try await cryptography.sealBackground(
                    CapturedWorkCodec.encode(continuation.body, scope: opened.scope, historicalAudit: opened.historicalAudit),
                    binding: Self.captureBinding(id))
                nextCapture = (id, try protected.encoded(), opened.historicalAudit == nil ? 0 : 1)
            }
            if let progress = historicalProgress {
                guard progress.bytesRead >= 0, progress.bytesRead <= 100 * 1024 * 1024,
                      progress.audit == opened.historicalAudit,
                      progress.oldestContentTime?.timeIntervalSince1970.isFinite != false,
                      progress.newestContentTime?.timeIntervalSince1970.isFinite != false else {
                    throw StorageError.invalidPayload
                }
                if let oldest = progress.oldestContentTime, !progress.audit.includes(contentTime: oldest) {
                    throw StorageError.invalidPayload
                }
                if let newest = progress.newestContentTime, !progress.audit.includes(contentTime: newest) {
                    throw StorageError.invalidPayload
                }
                if let oldest = progress.oldestContentTime, let newest = progress.newestContentTime,
                   oldest > newest { throw StorageError.invalidPayload }
                let keyBytes = try JSONEncoder().encode([progress.audit.id.uuidString,
                    original.metadata.agent.rawValue, original.metadata.profileID])
                let id = try await structuralID(Data("history-progress-v1".utf8) + keyBytes)
                let previous = try await storedProgress(id: id)
                let total = (previous?.progress.bytesRead ?? 0).addingReportingOverflow(progress.bytesRead)
                guard !total.overflow else { throw StorageError.invalidPayload }
                let oldest = [previous?.progress.oldestContentTime, progress.oldestContentTime].compactMap { $0 }.min()
                let newest = [previous?.progress.newestContentTime, progress.newestContentTime].compactMap { $0 }.max()
                let accumulated = HistoricalReadProgress(audit: progress.audit, bytesRead: total.partialValue,
                    oldestContentTime: oldest, newestContentTime: newest, hasUnreadContent: progress.hasUnreadContent)
                let record = StoredHistoricalProgress(provider: original.metadata.agent,
                    profileID: original.metadata.profileID, progress: accumulated)
                let protected = try await cryptography.sealBackground(JSONEncoder().encode(record),
                    binding: Self.checkpointBinding(id))
                progressPayload = (id, try protected.encoded())
            }
        }
        try check(permit)
        let injector = failureInjector
        try Self.write(database) { db in
            try Self.checkClaim(capture, in: db, at: now)
            for (id, encoded) in prepared {
                try db.execute(sql: """
                    INSERT INTO source_checkpoints (document_id, encoded) VALUES (?, ?)
                    ON CONFLICT(document_id) DO UPDATE SET encoded = excluded.encoded
                    """, arguments: [id.uuidString, encoded])
            }
            if let next = nextCapture {
                let bytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(byte_count), 0) FROM captures WHERE id != ?",
                                            arguments: [capture.id.uuidString]) ?? 0
                guard next.bytes.count <= limits.maxQueueBytes,
                      bytes <= limits.maxQueueBytes - next.bytes.count else { throw StorageError.queueSaturated }
                try db.execute(sql: """
                    INSERT INTO captures (id, encoded, byte_count, captured_at, expires_at, retry_count, available_at, state, work_class)
                    VALUES (?, ?, ?, ?, ?, 0, ?, 0, ?)
                    """, arguments: [next.id.uuidString, next.bytes, next.bytes.count, now.timeIntervalSince1970,
                        capture.expiresAt.timeIntervalSince1970, now.timeIntervalSince1970, next.workClass])
            }
            if let progress = progressPayload {
                try db.execute(sql: """
                    INSERT INTO historical_progress (id, updated_at, encoded) VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at, encoded = excluded.encoded
                    """, arguments: [progress.id.uuidString, now.timeIntervalSince1970, progress.bytes])
            }
            try Self.consumeCapture(capture.id, in: db)
            try injector?(.beforeProcessingCommit)
        }
        try injector?(.afterProcessingCommit)
    }

    public func authority(for session: SessionIdentity) async throws -> CollectionAuthorityChoice? {
        let id = try await authorityID(for: session)
        guard let bytes = try Self.read(database, { db in
            try Data.fetchOne(db, sql: "SELECT encoded FROM collection_authorities WHERE id = ?", arguments: [id.uuidString])
        }) else { return nil }
        let payload = try Self.decode(bytes)
        let plaintext = try await cryptography.openBackground(payload, binding: Self.checkpointBinding(id))
        let choice = try JSONDecoder().decode(CollectionAuthorityChoice.self, from: plaintext)
        guard choice.session == session else { throw StorageError.corruptProtectedState }
        return choice
    }

    public func selectAuthority(_ choice: CollectionAuthorityChoice, permit: StoreProcessingPermit) async throws {
        try check(permit)
        let id = try await authorityID(for: choice.session)
        if let existing = try await authority(for: choice.session) {
            guard existing.authorityID == choice.authorityID else { throw StorageError.invalidPayload }
            return
        }
        let payload = try await cryptography.sealBackground(JSONEncoder().encode(choice), binding: Self.checkpointBinding(id))
        let bytes = try payload.encoded()
        try check(permit)
        // A concurrent selector can only win once; a losing incompatible choice fails visibly.
        let inserted = try Self.write(database) { db in
            try db.execute(sql: "INSERT OR IGNORE INTO collection_authorities (id, encoded) VALUES (?, ?)",
                           arguments: [id.uuidString, bytes])
            return db.changesCount > 0
        }
        if !inserted {
            guard try await authority(for: choice.session)?.authorityID == choice.authorityID else {
                throw StorageError.invalidPayload
            }
        }
    }

    public func historicalProgress(limit: Int = 100) async throws -> [StoredHistoricalProgress] {
        guard limit > 0, limit <= 1000 else { throw StorageError.invalidPayload }
        let rows = try Self.read(database) { db in
            try Row.fetchAll(db, sql: "SELECT id, encoded FROM historical_progress ORDER BY updated_at DESC LIMIT ?", arguments: [limit])
        }
        var result: [StoredHistoricalProgress] = []
        for row in rows {
            guard let id = UUID(uuidString: row["id"]) else { throw StorageError.corruptProtectedState }
            let payload = try Self.decode(row["encoded"])
            let plaintext = try await cryptography.openBackground(payload, binding: Self.checkpointBinding(id))
            result.append(try JSONDecoder().decode(StoredHistoricalProgress.self, from: plaintext))
        }
        return result
    }

    private func storedProgress(id: UUID) async throws -> StoredHistoricalProgress? {
        guard let bytes = try Self.read(database, { db in
            try Data.fetchOne(db, sql: "SELECT encoded FROM historical_progress WHERE id = ?", arguments: [id.uuidString])
        }) else { return nil }
        let plaintext = try await cryptography.openBackground(Self.decode(bytes), binding: Self.checkpointBinding(id))
        return try JSONDecoder().decode(StoredHistoricalProgress.self, from: plaintext)
    }

    private func authorityID(for session: SessionIdentity) async throws -> UUID {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try await structuralID(Data("collection-authority-v1".utf8) + encoder.encode(session))
    }

    private func structuralID(_ bytes: Data) async throws -> UUID {
        let digest = try await cryptography.revision(canonicalBytes: bytes).keyedDigest
        let b = Array(digest.prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    public func checkpoint(documentID: UUID) async throws -> SourceCheckpoint? {
        let encoded: Data?
        do {
            encoded = try Self.read(database) { db in
                try Data.fetchOne(db, sql: "SELECT encoded FROM source_checkpoints WHERE document_id = ?", arguments: [documentID.uuidString])
            }
        } catch { throw StorageError.databaseUnavailable }
        guard let encoded else { return nil }
        do {
            let payload = try Self.decode(encoded)
            let bytes = try await cryptography.openBackground(payload, binding: Self.checkpointBinding(documentID))
            let checkpoint = try JSONDecoder().decode(SourceCheckpoint.self, from: bytes)
            guard checkpoint.sourceDocumentID == documentID else { throw StorageError.corruptProtectedState }
            return checkpoint
        } catch let error as StorageError { throw error }
        catch { throw StorageError.protectionUnavailable }
    }

    public func coverageGaps(limit: Int = 1000, since: Date? = nil) async throws -> [CoverageGap] {
        guard limit > 0, limit <= 10_000 else { throw StorageError.corruptProtectedState }
        let rows: [Data]
        do {
            rows = try Self.read(database) { db in
                try Data.fetchAll(db, sql: "SELECT encoded FROM coverage_gaps WHERE created_at >= ? ORDER BY created_at DESC LIMIT ?",
                                  arguments: [since?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude, limit])
            }
        } catch { throw StorageError.databaseUnavailable }
        var gaps: [CoverageGap] = []
        for encoded in rows {
            do {
                let payload = try Self.decode(encoded)
                guard payload.binding.kind == .sourceCheckpoint else { throw StorageError.invalidPayload }
                let bytes = try await cryptography.openBackground(payload, binding: payload.binding)
                gaps.append(try JSONDecoder().decode(CoverageGap.self, from: bytes))
            } catch let error as StorageError { throw error }
            catch { throw StorageError.protectionUnavailable }
        }
        return gaps
    }

    /// Records controlled loss metadata, including rejected capture while paused. No event bytes
    /// or upstream strings are accepted by this diagnostic API.
    public func recordCoverageGap(reason: CoverageGapReason, at time: Date = Date()) async throws {
        try await recordCoverageGap(CoverageGap(reason: reason), at: time)
    }

    /// Capability and interval are protected with the reason, so a bounded adapter's
    /// unfinished window remains available after restart.
    public func recordCoverageGap(_ gap: CoverageGap, at time: Date = Date()) async throws {
        guard !closed else { throw StorageError.databaseUnavailable }
        guard time.timeIntervalSince1970.isFinite else { throw StorageError.invalidTime }
        if let interval = gap.interval {
            guard interval.start.timeIntervalSince1970.isFinite,
                  interval.end.timeIntervalSince1970.isFinite,
                  interval.duration.isFinite, interval.duration >= 0 else { throw StorageError.invalidTime }
        }
        try await recordGap(gap, at: time)
    }

    public func review(_ occurrenceID: UUID, as state: OccurrenceReview) async throws {
        _ = try await mutateLedger { try $0.review(occurrenceID, as: state) }
    }

    public func acknowledgeObsolete(
        _ fingerprint: ValueFingerprint, as acknowledgement: ObsoleteAcknowledgement, at time: Date
    ) async throws {
        _ = try await mutateLedger { try $0.acknowledgeObsolete(fingerprint, as: acknowledgement, at: time) }
    }

    public func forgetObsoleteMarker(_ fingerprint: ValueFingerprint) async throws {
        _ = try await mutateLedger { try $0.forgetObsoleteMarker(fingerprint) }
    }

    public func recordAlertDelivery(_ alertID: UUID, state: AlertDeliveryState) async throws {
        _ = try await mutateLedger { try $0.recordAlertDelivery(alertID, state: state) }
    }

    public func removeContent(for fingerprint: ValueFingerprint) async throws -> ContentRemovalPlan {
        try await mutateLedger(removal: true) { try $0.removeContent(for: fingerprint) }
    }

    private func mutateLedger<Result: Sendable>(
        removal: Bool = false, settlement: [ProgressSettlementRow]? = nil, notificationPermit: StoreProcessingPermit? = nil,
        _ mutation: @Sendable (inout InventoryLedger) throws -> Result
    ) async throws -> Result {
        guard !closed else { throw StorageError.databaseUnavailable }
        let expectedRevision = revision
        var next = ledger
        let result = try mutation(&next)
        let encodedState = try await sealSnapshot(next.snapshot)
        let snapshot = next.snapshot
        let plan = result as? ContentRemovalPlan
        let removalTime = Date()
        let removalGap = plan == nil ? nil : try await sealedGap(CoverageGap(reason: .captureRejected), at: removalTime)
        guard revision == expectedRevision else { throw StorageError.stateChanged }
        if let notificationPermit { try check(notificationPermit) }
        do {
            try Self.write(database) { db in
                try Self.checkRevision(expectedRevision, in: db)
                if let settlement {
                    let current = try Row.fetchAll(db, sql: "SELECT id, encoded FROM historical_progress ORDER BY id LIMIT 1001").map {
                        ProgressSettlementRow(id: $0["id"], encoded: $0["encoded"])
                    }
                    guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM captures") == 0, current == settlement else {
                        throw StorageError.stateChanged
                    }
                }
                try Self.writeState(encodedState, snapshot: snapshot, revision: expectedRevision + 1, in: db)
                if let plan {
                    for reference in plan.payloadReferences {
                        try db.execute(sql: "DELETE FROM protected_payloads WHERE reference_id = ?", arguments: [reference.id.uuidString])
                    }
                    let ids = try String.fetchAll(db, sql: "SELECT capture_id FROM capture_value_links WHERE value_id = ?",
                                                  arguments: [plan.removedValueID.uuidString])
                    for id in ids {
                        guard let id = UUID(uuidString: id) else { throw StorageError.corruptProtectedState }
                        try Self.consumeCapture(id, in: db)
                    }
                    if !ids.isEmpty, let removalGap {
                        // A mixed-content capture may contain other values too. Its known loss is
                        // visible in the same transaction that removes associated retry work.
                        try Self.insertGap(removalGap, at: removalTime, in: db)
                    }
                }
            }
            ledger = next
            revision = expectedRevision + 1
            if removal { generation = UUID() }
            return result
        } catch let error as StorageError { throw error }
        catch { throw StorageError.databaseUnavailable }
    }

    private func check(_ permit: StoreProcessingPermit) throws {
        guard !closed else { throw StorageError.databaseUnavailable }
        guard monitoringEnabled else { throw StorageError.monitoringPaused }
        guard generation == permit.generation else { throw StorageError.staleProcessingPermit }
    }

    private func sealSnapshot(_ snapshot: InventorySnapshot) async throws -> Data {
        let bytes = try JSONEncoder().encode(snapshot)
        guard bytes.count <= limits.maxProtectedStateBytes else { throw StorageError.stateTooLarge }
        do {
            return try await cryptography.sealBackground(bytes, binding: Self.ledgerBinding(manifest)).encoded()
        } catch { throw StorageError.protectionUnavailable }
    }

    private func checkedPayloads(
        _ payloads: [ProtectedPayload], required: [ProtectedPayloadReference: ProtectedPayloadKind]
    ) throws -> [ProtectedPayload] {
        var seen: Set<ProtectedPayloadReference> = []
        return try payloads.compactMap { payload in
            guard let kind = required[payload.binding.reference] else { return nil }
            guard seen.insert(payload.binding.reference).inserted,
                  payload.binding.kind == kind, payload.binding.ownerID == payload.binding.reference.id,
                  payload.keyID == manifest.inventoryRightID,
                  payload.algorithm == .inventoryECIESAESGCM else { throw StorageError.invalidPayload }
            do { try payload.validate() } catch { throw StorageError.invalidPayload }
            return payload
        }
    }

    private func expirePending(at now: Date, permit: StoreProcessingPermit) async throws {
        _ = try await maintainQueue(at: now)
        try check(permit)
    }

    private func sealedGap(_ gap: CoverageGap, at _: Date) async throws -> ProtectedPayload {
        let id = UUID()
        do {
            return try await cryptography.sealBackground(
                JSONEncoder().encode(gap),
                binding: PayloadBinding(reference: ProtectedPayloadReference(id: id), ownerID: id, kind: .sourceCheckpoint)
            )
        } catch { throw StorageError.protectionUnavailable }
    }

    private func recordGap(_ gap: CoverageGap, at time: Date) async throws {
        let payload = try await sealedGap(gap, at: time)
        guard !closed else { throw StorageError.databaseUnavailable }
        do { try Self.write(database) { db in try Self.insertGap(payload, at: time, in: db) } }
        catch { throw StorageError.databaseUnavailable }
    }

    /// The bound is a durable coverage limitation, not a new gap on each notification poll.
    /// Only a keyed structural identifier is indexed; the controlled reason is encrypted.
    private func recordNotificationBudgetGap(permit: StoreProcessingPermit) async throws {
        let id = try await structuralID(Data("historical-notification-budget-gap-v1".utf8))
        try check(permit)
        let exists: Bool
        do {
            exists = try Self.read(database) { db in
                try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM coverage_gaps WHERE id = ?)",
                                  arguments: [id.uuidString]) == true
            }
        } catch { throw StorageError.databaseUnavailable }
        guard !exists else { return }
        let encoded: Data
        do {
            encoded = try await cryptography.sealBackground(
                JSONEncoder().encode(CoverageGap(reason: .notificationBudgetExhausted)),
                binding: Self.checkpointBinding(id)
            ).encoded()
        } catch { throw StorageError.protectionUnavailable }
        try check(permit)
        let time = Date()
        do {
            try Self.write(database) { db in
                try db.execute(sql: "INSERT OR IGNORE INTO coverage_gaps (id, created_at, encoded) VALUES (?, ?, ?)",
                               arguments: [id.uuidString, time.timeIntervalSince1970, encoded])
            }
        } catch { throw StorageError.databaseUnavailable }
    }

    private static func captureBinding(_ id: UUID) -> PayloadBinding {
        PayloadBinding(reference: ProtectedPayloadReference(id: id), ownerID: id, kind: .queueEvent)
    }
    private static func ledgerBinding(_ manifest: ProtectionManifest) -> PayloadBinding {
        PayloadBinding(reference: ProtectedPayloadReference(id: manifest.vaultID), ownerID: manifest.vaultID, kind: .ledgerSnapshot)
    }
    private static func checkpointBinding(_ id: UUID) -> PayloadBinding {
        PayloadBinding(reference: ProtectedPayloadReference(id: id), ownerID: id, kind: .sourceCheckpoint)
    }
    private static func decode(_ bytes: Data, maximumBytes: Int = 16 * 1024 * 1024) throws -> ProtectedPayload {
        do { return try ProtectedPayload.decode(bytes, maximumBytes: maximumBytes) }
        catch { throw StorageError.corruptProtectedState }
    }

    private static func checkRevision(_ revision: Int64, in db: Database) throws {
        guard try Int64.fetchOne(db, sql: "SELECT revision FROM store_state WHERE id = 1") == revision else {
            throw StorageError.stateChanged
        }
    }
    private static func checkClaim(_ capture: PendingCapture, in db: Database, at time: Date, allowExpired: Bool = false) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT claim_id, state, lease_until, expires_at FROM captures WHERE id = ?",
                                        arguments: [capture.id.uuidString]),
              row["state"] as Int == 1, row["claim_id"] as String? == capture.claimID.uuidString,
              (row["lease_until"] as Double) > time.timeIntervalSince1970,
              allowExpired || (row["expires_at"] as Double) > time.timeIntervalSince1970 else {
            throw StorageError.staleClaim
        }
    }
    private static func consumeCapture(_ id: UUID, in db: Database) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO capture_receipts (id, consumed_at) VALUES (?, ?)",
                       arguments: [id.uuidString, Date().timeIntervalSince1970])
        try db.execute(sql: "DELETE FROM captures WHERE id = ?", arguments: [id.uuidString])
    }
    private static func insertGap(_ payload: ProtectedPayload, at time: Date, in db: Database) throws {
        try db.execute(sql: "INSERT INTO coverage_gaps (id, created_at, encoded) VALUES (?, ?, ?)",
                       arguments: [payload.binding.reference.id.uuidString, time.timeIntervalSince1970, try payload.encoded()])
    }
    private static func requiredPayloads(in snapshot: InventorySnapshot) throws -> [ProtectedPayloadReference: ProtectedPayloadKind] {
        var references: [ProtectedPayloadReference: ProtectedPayloadKind] = [:]
        func add(_ reference: ProtectedPayloadReference?, kind: ProtectedPayloadKind) throws {
            guard let reference else { return }
            if let previous = references[reference], previous != kind { throw StorageError.invalidPayload }
            references[reference] = kind
        }
        for record in snapshot.records.values { try add(record.protectedValue, kind: .value) }
        for occurrence in snapshot.occurrences.values {
            try add(occurrence.protectedExcerpt, kind: .excerpt)
            try add(occurrence.source.protectedMetadata, kind: .sourceMetadata)
        }
        for result in snapshot.unlocatedResults.values { try add(result.source.protectedMetadata, kind: .sourceMetadata) }
        return references
    }
    private static func insertPayloads(
        _ payloads: [ProtectedPayload], required: [ProtectedPayloadReference: ProtectedPayloadKind], in db: Database
    ) throws {
        for payload in payloads {
            let existing = try Data.fetchOne(db, sql: "SELECT encoded FROM protected_payloads WHERE reference_id = ?",
                                             arguments: [payload.binding.reference.id.uuidString])
            if let existing {
                guard try decode(existing) == payload else { throw StorageError.invalidPayload }
            } else {
                try db.execute(sql: "INSERT INTO protected_payloads (reference_id, kind, encoded) VALUES (?, ?, ?)",
                               arguments: [payload.binding.reference.id.uuidString, payload.binding.kind.rawValue, try payload.encoded()])
            }
        }
        for (reference, kind) in required {
            guard let existing = try Data.fetchOne(db, sql: "SELECT encoded FROM protected_payloads WHERE reference_id = ?",
                                                  arguments: [reference.id.uuidString]),
                  try decode(existing).binding.kind == kind else { throw StorageError.payloadMissing }
        }
    }
    private static func writeState(_ encoded: Data, snapshot: InventorySnapshot, revision: Int64, in db: Database) throws {
        try db.execute(sql: "UPDATE store_state SET revision = ?, encoded = ? WHERE id = 1", arguments: [revision, encoded])
        try db.execute(sql: "DELETE FROM notification_outbox")
        for alert in snapshot.alertDecisions.values {
            try db.execute(sql: "INSERT INTO notification_outbox (id, value_id, delivery) VALUES (?, ?, ?)",
                           arguments: [alert.id.uuidString, alert.valueID.uuidString, alert.delivery.rawValue])
        }
        try db.execute(sql: "DELETE FROM historical_notification_outbox")
        for decision in snapshot.historicalNotificationDecisions.values {
            try db.execute(sql: "INSERT INTO historical_notification_outbox (audit_id, delivery) VALUES (?, ?)",
                arguments: [decision.audit.id.uuidString, decision.delivery.rawValue])
        }
    }

    // Choose GRDB's synchronous overload deliberately: a final generation check and its SQL
    // transaction must not have an actor suspension between them. This actor is never MainActor.
    private static func read<Value>(_ database: DatabaseQueue, _ body: (Database) throws -> Value) throws -> Value {
        try database.read(body)
    }
    private static func write<Value>(_ database: DatabaseQueue, _ body: (Database) throws -> Value) throws -> Value {
        try database.write(body)
    }

    private static func migrate(_ database: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-protected-ingestion") { db in
            try db.execute(sql: """
                CREATE TABLE protection_manifest (id INTEGER PRIMARY KEY CHECK (id = 1), encoded BLOB NOT NULL);
                CREATE TABLE store_state (id INTEGER PRIMARY KEY CHECK (id = 1), revision INTEGER NOT NULL, encoded BLOB NOT NULL);
                CREATE TABLE protected_payloads (reference_id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, encoded BLOB NOT NULL);
                CREATE TABLE captures (
                    id TEXT PRIMARY KEY NOT NULL, encoded BLOB NOT NULL, byte_count INTEGER NOT NULL,
                    captured_at REAL NOT NULL, expires_at REAL NOT NULL, retry_count INTEGER NOT NULL,
                    available_at REAL NOT NULL, state INTEGER NOT NULL CHECK (state IN (0, 1)),
                    claim_id TEXT, lease_until REAL);
                CREATE INDEX captures_ready ON captures (state, available_at, captured_at);
                CREATE TABLE capture_receipts (id TEXT PRIMARY KEY NOT NULL);
                CREATE TABLE capture_value_links (
                    capture_id TEXT NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
                    value_id TEXT NOT NULL, PRIMARY KEY (capture_id, value_id));
                CREATE TABLE source_checkpoints (document_id TEXT PRIMARY KEY NOT NULL, encoded BLOB NOT NULL);
                CREATE TABLE coverage_gaps (id TEXT PRIMARY KEY NOT NULL, created_at REAL NOT NULL, encoded BLOB NOT NULL);
                CREATE TABLE notification_outbox (id TEXT PRIMARY KEY NOT NULL, value_id TEXT NOT NULL, delivery TEXT NOT NULL);
                """)
        }
        migrator.registerMigration("v2-bounded-history") { db in
            try db.execute(sql: """
                ALTER TABLE captures ADD COLUMN work_class INTEGER NOT NULL DEFAULT 0 CHECK (work_class IN (0, 1));
                CREATE TABLE collection_authorities (id TEXT PRIMARY KEY NOT NULL, encoded BLOB NOT NULL);
                CREATE TABLE historical_progress (id TEXT PRIMARY KEY NOT NULL, updated_at REAL NOT NULL, encoded BLOB NOT NULL);
                """)
        }
        migrator.registerMigration("v3-user-workflow") { db in
            try db.execute(sql: """
                CREATE TABLE protected_preferences (id TEXT PRIMARY KEY NOT NULL, encoded BLOB NOT NULL);
                CREATE TABLE historical_notification_outbox (audit_id TEXT PRIMARY KEY NOT NULL, delivery TEXT NOT NULL);
                """)
        }
        migrator.registerMigration("v4-bounded-bookkeeping") { db in
            // Existing receipts have no time; they become prunable at the next maintenance pass.
            try db.execute(sql: """
                ALTER TABLE capture_receipts ADD COLUMN consumed_at REAL NOT NULL DEFAULT 0;
                CREATE INDEX capture_receipts_consumed ON capture_receipts (consumed_at);
                CREATE INDEX coverage_gaps_created ON coverage_gaps (created_at);
                """)
        }
        try migrator.migrate(database)
    }

    private static func prepareDirectory(_ directory: URL) throws {
        guard directory.isFileURL else { throw StorageError.unsafeStorageLocation }
        if !FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700]) }
            catch { throw StorageError.unsafeStorageLocation }
        }
        var info = stat()
        guard Darwin.lstat(directory.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, chmod(directory.path, 0o700) == 0 else {
            throw StorageError.unsafeStorageLocation
        }
    }
    private static func verifyOwnedRegularFile(_ url: URL) throws {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else {
            throw StorageError.unsafeStorageLocation
        }
    }
    private static func prepareDatabaseFile(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            let descriptor = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw StorageError.unsafeStorageLocation }
            Darwin.close(descriptor)
        }
        try verifyOwnedRegularFile(url)
        guard chmod(url.path, 0o600) == 0 else { throw StorageError.unsafeStorageLocation }
    }
    private static func restrictFileModes(in directory: URL) throws {
        for filename in [databaseFilename, databaseFilename + "-wal", databaseFilename + "-shm"] {
            let url = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) {
                try verifyOwnedRegularFile(url)
                guard chmod(url.path, 0o600) == 0 else { throw StorageError.unsafeStorageLocation }
            }
        }
    }
}
