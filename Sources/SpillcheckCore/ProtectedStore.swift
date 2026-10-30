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

private struct RecoveryChainEvidence: Codable, Sendable {
    let schemaVersion: Int
    let targetWorkID: UUID
    let auditID: UUID
    let auditWindow: DateInterval
    let successfulPages: Bool
}

private struct CoverageReportRows {
    let events: (rows: [Row], count: Int)
    let omissions: (rows: [Row], count: Int)
    let history: (rows: [Row], count: Int)
    let queue: StoreQueueStatistics
    let oldestPendingAt: Double?
    let work: (rows: [Row], count: Int)
    let successes: (rows: [Row], count: Int)
    let omissionCounts: [CoverageOmissionState: Int]
    let capacity: StoreCapacitySnapshot
}

private struct PreparedCoverageOmission: Sendable {
    let id: UUID
    let locationID: UUID
    let incidentKey: UUID?
    let encoded: Data
    let time: Date?
    let state: CoverageOmissionState
    // Capture losses have a separate identity and no source-gap merge. Source omissions
    // require the exact ciphertext (or absence) whose age and semantics were inspected.
    var checksPrevious = false
    var previousEncoded: Data?
    var upgradesOmissionMeaning = false
    var reclassifiedLocalMedia: MetadataRecoveryRow?
}

private struct MetadataRecoveryRow: Equatable, Sendable {
    let id: UUID
    let locationID: UUID
    let encoded: Data
    let state: String
    let createdAt: Double
    let contentAt: Double?
    let incidentKey: String?
    let resolvedAt: Double?
}

private struct PreparedMetadataRecovery: Sendable {
    let locationID: UUID
    let rows: [MetadataRecoveryRow]
    let recoveredIDs: Set<UUID>
}

private struct PreparedCoverageSettlement: Sendable {
    var gaps: [ProtectedPayload] = []
    var omissions: [PreparedCoverageOmission] = []
    var incidents: [(id: UUID, key: UUID, encoded: Data, requiresAssessment: Bool)] = []
    var recoveredLocations: Set<UUID> = []
    var metadataRecoveries: [PreparedMetadataRecovery] = []
    var captureLossLinks: [(capture: UUID, omission: UUID)] = []
    var workWithGapEvidence: Set<UUID> = []
    mutating func append(_ other: Self) {
        gaps += other.gaps; omissions += other.omissions; incidents += other.incidents
        recoveredLocations.formUnion(other.recoveredLocations)
        metadataRecoveries += other.metadataRecoveries
        captureLossLinks += other.captureLossLinks
        workWithGapEvidence.formUnion(other.workWithGapEvidence)
    }
}

private struct RecoveryLocationKey: Codable {
    let session: SessionIdentity?
    let locator: SourceLocator
    let itemID: String?
    let sourceDocumentID: UUID?
    let sourceURL: URL?
    init(_ reference: CoverageRecoveryReference) {
        switch reference.locator {
        case .transcript, .transcriptByteOffset: session = nil
        case .upstreamItem, .unavailable: session = reference.session
        }
        locator = reference.locator; itemID = reference.itemID
        sourceDocumentID = reference.sourceDocumentID
        sourceURL = reference.locator == .unavailable && reference.sourceDocumentID == nil ? reference.sourceURL : nil
    }
}

private struct OmissionIdentityKey: Codable {
    let scope: CollectionScope
    let location: RecoveryLocationKey
    let contentType: ContentType?
    let reason: CoverageGapReason
    let operation: CollectionOperation?
}

/// Opened report rows, kept while their ciphertext is unchanged. Opening is a pure function of a
/// row's ciphertext and its row binding, so a kept value is exactly what reopening would return.
/// The app refreshes coverage every second; reopening up to a thousand unchanged rows of each kind
/// every time kept the store busy and delayed capture processing.
private struct OpenedRows<Value> {
    private static var capacity: Int { 2048 }
    private var entries: [UUID: (encoded: Data, value: Value)] = [:]

    func value(for id: UUID, encoded: Data) -> Value? {
        guard let entry = entries[id], entry.encoded == encoded else { return nil }
        return entry.value
    }
    mutating func keep(_ value: Value, for id: UUID, encoded: Data) {
        if entries[id] == nil, entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
        entries[id] = (encoded, value)
    }
    mutating func removeAll() { entries.removeAll() }
}

private enum OpenedGapEvent {
    case event(StoredCoverageGapEvent)
    /// Schema 1–3 stored the gap without its encrypted event envelope.
    case legacy(CoverageGap)
}

private struct HealthIdentityKey: Codable {
    let scope: CollectionScope
    let contentType: ContentType?
    let reason: CoverageGapReason
    /// Nil is omitted by Codable so existing content-only keys retain their exact bytes.
    let operation: CollectionOperation?
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
    private var openedOmissions = OpenedRows<CoverageOmission>()
    private var openedGapEvents = OpenedRows<OpenedGapEvent>()
    private var openedWorkContexts = OpenedRows<CollectionWorkContext>()

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
                              "collection_authorities", "historical_progress", "protected_preferences", "historical_notification_outbox",
                              "coverage_omissions", "collection_health_incidents", "collection_work", "successful_collection_reads",
                              "codex_hook_content_slots"] {
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
              limits.maxProtectedStateBytes > 0, limits.maxHookContentSlots > 0,
              limits.maxSourceAuthorities > 0 else { throw StorageError.invalidTime }
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
        openedOmissions.removeAll(); openedGapEvents.removeAll(); openedWorkContexts.removeAll()
        do { try database.close(); closed = true }
        catch { throw StorageError.databaseUnavailable }
    }

    public func setMonitoring(enabled: Bool) { monitoringEnabled = enabled; generation = UUID() }
    public func processingPermit() -> StoreProcessingPermit? {
        monitoringEnabled && !closed ? StoreProcessingPermit(generation: generation) : nil
    }
    public func snapshot() -> InventorySnapshot { ledger.snapshot }
    /// Every committed inventory change increments this value. Equal revisions have equal snapshots.
    public func stateRevision() -> Int64 { revision }

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
        let health = try await pendingHealthNotifications().map(MaskedNotification.health)
        return live + historical + health
    }

    public func notificationTargetExists(_ target: NotificationNavigationTarget) -> Bool {
        guard !closed else { return false }
        switch target {
        case .value(let id): return ledger.records.values.contains { $0.id == id }
        case .historicalAudit(let id): return (try? ledger.snapshot.historicalSummaries().contains { $0.audit.id == id }) == true
        case .collectionHealth(let id):
            return (try? Self.read(database) { db in
                try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM collection_health_incidents WHERE id = ?)",
                                  arguments: [id.uuidString]) == true
            }) == true
        }
    }

    public func notificationIsEligible(identifier: String) async throws -> Bool {
        try await pendingNotifications().contains { $0.identifier == identifier }
    }

    public func notificationIsEligible(_ notification: MaskedNotification) async throws -> Bool {
        try await pendingNotifications().contains(notification)
    }

    public func notificationCanRemain(identifier: String) async throws -> Bool {
        try await currentNotification(identifier: identifier) != nil
    }

    public func notificationCanRemain(_ notification: MaskedNotification) async throws -> Bool {
        try await currentNotification(identifier: notification.identifier) == notification
    }

    private func currentNotification(identifier: String) async throws -> MaskedNotification? {
        guard !closed else { return nil }
        if identifier.hasPrefix("spillcheck-health-"),
           let id = UUID(uuidString: String(identifier.dropFirst("spillcheck-health-".count))),
           let incident = try await healthIncident(id: id), incident.isActive, incident.delivery != .cancelled {
            return .health(incident)
        }
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
        } else if identifier.hasPrefix("spillcheck-health-"),
                  let id = UUID(uuidString: String(identifier.dropFirst("spillcheck-health-".count))) {
            try check(permit)
            try Self.write(database) { db in
                try db.execute(sql: "UPDATE collection_health_incidents SET delivery = ? WHERE id = ? AND resolved_at IS NULL AND delivery = ?",
                               arguments: [state.rawValue, id.uuidString, AlertDeliveryState.pending.rawValue])
            }
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
        historicalAudit: HistoricalAuditContext? = nil, workContext: CollectionWorkContext? = nil,
        recoveryOf: UUID? = nil
    ) async throws -> QueueInsertion {
        try check(permit)
        guard capturedAt.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite else {
            throw StorageError.invalidTime
        }
        guard !captureBody.isEmpty, captureBody.count <= limits.maxEventBytes else {
            throw StorageError.captureTooLarge
        }
        let workBytes = try await prepareWorkContext(workContext, id: id, body: captureBody, audit: historicalAudit,
            liveScope: scope, capturedAt: capturedAt)
        var recoveryChainBytes: Data?
        if let recoveryOf {
            guard let context = workContext, let prior = try await collectionWork(id: recoveryOf),
                  prior.context.retry != nil, context.retry.map({ prior.context.retry?.identifiesSameSource(as: $0) == true }) == true,
                  prior.context.scope == context.scope,
                  prior.context.operation == context.operation || (prior.context.operation == .liveRead && context.operation == .historicalRead),
                  prior.state == .terminal else { throw StorageError.invalidPayload }
            if context.operation == .historicalRead, let audit = historicalAudit {
                recoveryChainBytes = try await sealWorkValue(RecoveryChainEvidence(schemaVersion: 1,
                    targetWorkID: recoveryOf, auditID: audit.id, auditWindow: DateInterval(start: audit.start, end: audit.end),
                    successfulPages: true), id: id)
            }
        }
        let expiresAt = capturedAt.addingTimeInterval(limits.maxQueueAge)
        guard expiresAt > now else {
            let loss = try await prepareCaptureLoss(id: id, body: captureBody, capturedAt: capturedAt,
                                                  reason: .queueExpired, at: now, audit: historicalAudit, context: workContext)
            try check(permit)
            try Self.write(database) { db in
                if let workBytes,
                   try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection_work WHERE id = ?", arguments: [id.uuidString]) == 0 {
                    try Self.insertWork(id: id, context: workBytes, recoveryOf: recoveryOf, recoveryChain: recoveryChainBytes,
                        at: now, maximumBytes: limits.maxProtectedStateBytes, in: db)
                    try Self.updateWork(id: id, state: .terminal, at: now, in: db)
                }
                try Self.writeCoverageSettlement(loss, at: now, maximumBytes: limits.maxProtectedStateBytes, in: db)
            }
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
                if let recoveryOf {
                    guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection_work WHERE recovery_of = ? AND state IN (?, ?, ?)",
                        arguments: [recoveryOf.uuidString, CollectionWorkState.queued.rawValue,
                            CollectionWorkState.processing.rawValue, CollectionWorkState.stalled.rawValue]) == 0 else {
                        throw StorageError.stateChanged
                    }
                }
                let bytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(byte_count), 0) FROM captures") ?? 0
                guard encoded.count <= maxBytes, bytes <= maxBytes - encoded.count else { throw StorageError.queueSaturated }
                try db.execute(sql: """
                    INSERT INTO captures (id, encoded, byte_count, captured_at, expires_at, retry_count, available_at, state, work_class)
                    VALUES (?, ?, ?, ?, ?, 0, ?, 0, ?)
                    """, arguments: [id.uuidString, encoded, encoded.count,
                                      capturedAt.timeIntervalSince1970, expiresAt.timeIntervalSince1970, now.timeIntervalSince1970,
                                      historicalAudit == nil ? 0 : 1])
                if let workBytes {
                    try Self.insertWork(id: id, context: workBytes, recoveryOf: recoveryOf, recoveryChain: recoveryChainBytes,
                        at: now, maximumBytes: limits.maxProtectedStateBytes, in: db)
                }
                try Self.pruneCompletedWork(in: db, retaining: limits.maxSuccessfulWorkRecords)
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
            return try Self.read(database) { try Self.queueStatistics(in: $0) }
        } catch { throw StorageError.databaseUnavailable }
    }

    private static func queueStatistics(in db: Database) throws -> StoreQueueStatistics {
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM captures") ?? 0
        let bytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(byte_count), 0) FROM captures") ?? 0
        let claimed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM captures WHERE state = 1") ?? 0
        let historical = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM captures WHERE work_class = 1") ?? 0
        return StoreQueueStatistics(count: count, encryptedBytes: bytes, claimedCount: claimed, historicalCount: historical)
    }

    /// Bounded opaque queue identities for private disposable restart acceptance. A consumed
    /// receipt alone does not prove successful analysis: expiry and exhaustion consume too.
    @_spi(Testing) public func captureIdentitiesForTesting(limit: Int = 4096) throws -> (pending: [UUID], consumed: [UUID]) {
        guard limit > 0, limit <= 4096, !closed else { throw StorageError.invalidPayload }
        return try Self.read(database) { db in
            func identities(_ table: String) throws -> [UUID] {
                let strings = try String.fetchAll(db, sql: "SELECT id FROM \(table) ORDER BY id LIMIT ?", arguments: [limit + 1])
                guard strings.count <= limit else { throw StorageError.stateTooLarge }
                return try strings.map {
                    guard let id = UUID(uuidString: $0) else { throw StorageError.corruptProtectedState }
                    return id
                }
            }
            return (try identities("captures"), try identities("capture_receipts"))
        }
    }

    /// Read-only structural commitments for a disposable genuine old-writer migration.
    /// Rows retain ciphertext, never opened upstream content; the app exports keyed digests only.
    @_spi(Testing) public func legacyMigrationRowsForTesting() throws -> (migrations: [String], rows: [String: [Data]]) {
        guard !closed else { throw StorageError.databaseUnavailable }
        return try Self.read(database) { db in
            let columns: [(String, [String])] = [
                ("protection_manifest", ["id", "encoded"]), ("store_state", ["id", "revision", "encoded"]),
                ("protected_payloads", ["reference_id", "kind", "encoded"]),
                ("captures", ["id", "encoded", "byte_count", "captured_at", "expires_at", "retry_count", "available_at", "state", "work_class", "claim_id", "lease_until"]),
                ("capture_receipts", ["id", "consumed_at"]), ("capture_value_links", ["capture_id", "value_id"]),
                ("source_checkpoints", ["document_id", "encoded"]), ("coverage_gaps", ["id", "created_at", "encoded"]),
                ("notification_outbox", ["id", "value_id", "delivery"]), ("collection_authorities", ["id", "encoded"]),
                ("historical_progress", ["id", "updated_at", "encoded"]), ("protected_preferences", ["id", "encoded"]),
                ("historical_notification_outbox", ["audit_id", "delivery"]),
                ("coverage_omissions", ["id", "location_id", "incident_key", "created_at", "content_at", "state", "resolved_at", "encoded"]),
                ("collection_health_incidents", ["id", "key_id", "created_at", "resolved_at", "delivery", "requires_assessment", "encoded"]),
                ("collection_work", ["id", "state", "admitted_at", "updated_at", "attempted_at", "completed_at", "recovery_of", "omission_id", "retain_evidence", "encoded", "recovery_certificate", "recovery_chain"]),
                ("successful_collection_reads", ["id", "succeeded_at", "encoded"]),
                ("codex_hook_content_slots", ["id", "encoded"])
            ]
            let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier LIMIT 17")
            guard migrations.count <= 16 else { throw StorageError.stateTooLarge }
            var result: [String: [Data]] = [:], total = 0
            for (table, names) in columns {
                let rows = try Row.fetchAll(db, sql: "SELECT \(names.joined(separator: ",")) FROM \(table) LIMIT 129")
                guard rows.count <= 128 else { throw StorageError.stateTooLarge }
                result[table] = try rows.map { row in
                    var object: [String: Any] = [:]
                    for name in names {
                        let value: DatabaseValue = row[name]
                        switch value.storage {
                        case .null: object[name] = NSNull()
                        case .int64(let number): object[name] = number
                        case .double(let number):
                            guard number.isFinite else { throw StorageError.corruptProtectedState }
                            object[name] = number
                        case .string(let string):
                            guard string.utf8.count <= 4096 else { throw StorageError.stateTooLarge }
                            object[name] = string
                        case .blob(let data):
                            guard data.count <= 1024 * 1024 else { throw StorageError.stateTooLarge }
                            object[name] = data.base64EncodedString()
                        }
                    }
                    let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                    guard bytes.count <= 2 * 1024 * 1024, total <= 8 * 1024 * 1024 - bytes.count else {
                        throw StorageError.stateTooLarge
                    }
                    total += bytes.count
                    return bytes
                }
            }
            return (migrations, result)
        }
    }

    /// Age-limit maintenance also runs while paused. It opens each expiring capture in memory
    /// only to read its validated transport metadata, so the loss is attributed to its route.
    /// It never scans or retains event content, changes inventory, accepts a payload or creates
    /// an alert. Work is bounded per refresh.
    @discardableResult
    public func maintainQueue(at now: Date = Date(), limit: Int = 256) async throws -> Int {
        guard !closed else { throw StorageError.databaseUnavailable }
        guard now.timeIntervalSince1970.isFinite, limit > 0, limit <= 4096 else { throw StorageError.invalidTime }
        let rows: [StoredCapture]
        do {
            rows = try Self.read(database) { db in
                try Row.fetchAll(db, sql: "SELECT id, encoded, captured_at, expires_at, retry_count FROM captures WHERE expires_at <= ? ORDER BY expires_at LIMIT ?",
                                 arguments: [now.timeIntervalSince1970, limit]).map { row in
                    guard let id = UUID(uuidString: row["id"]), let count = UInt(exactly: row["retry_count"] as Int64) else {
                        throw StorageError.corruptProtectedState
                    }
                    return StoredCapture(id: id, encoded: row["encoded"], capturedAt: Date(timeIntervalSince1970: row["captured_at"]),
                        expiresAt: Date(timeIntervalSince1970: row["expires_at"]), retryCount: count)
                }
            }
        } catch { throw StorageError.databaseUnavailable }
        try pruneBookkeeping(at: now)
        guard !rows.isEmpty else { return 0 }
        var losses: [UUID: PreparedCoverageSettlement] = [:]
        for row in rows {
            // Decode at most the bounded queue volume, one capture at a time. Only validated
            // transport metadata survives; neither event JSON nor raw diagnostics is retained.
            let body = try? await cryptography.openBackground(Self.decode(row.encoded), binding: Self.captureBinding(row.id))
            let opened = body.flatMap { try? CapturedWorkCodec.decode($0) }
            losses[row.id] = try await prepareCaptureLoss(id: row.id, body: opened?.body,
                capturedAt: row.capturedAt, reason: .queueExpired, at: now, audit: opened?.historicalAudit, context: try await collectionWork(id: row.id)?.context)
        }
        guard !closed else { throw StorageError.databaseUnavailable }
        do {
            return try Self.write(database) { db in
                var removed = 0
                var settled = PreparedCoverageSettlement()
                for row in rows {
                    let id = row.id
                    if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM captures WHERE id = ? AND expires_at <= ?",
                                        arguments: [id.uuidString, now.timeIntervalSince1970]) == 1 {
                        try Self.updateWork(id: id, state: .terminal, at: now, in: db)
                        try Self.consumeCapture(id, in: db)
                        if let loss = losses[id] { settled.append(loss) }
                        removed += 1
                    }
                }
                if removed > 0 {
                    try Self.writeCoverageSettlement(settled, at: now, maximumBytes: limits.maxProtectedStateBytes, in: db)
                }
                return removed
            }
        } catch let error as StorageError { throw error }
        catch { throw StorageError.databaseUnavailable }
    }

    /// Capture receipts deduplicate queue deliveries. Legacy activity gaps have bounded retention;
    /// scoped omissions independently preserve loss attribution throughout the displayed period.
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
                try db.execute(sql: "DELETE FROM collection_work WHERE updated_at < ? AND id NOT IN (SELECT id FROM captures)",
                    arguments: [now.timeIntervalSince1970 - Self.coverageGapRetention])
                try db.execute(sql: "DELETE FROM coverage_omissions WHERE created_at < ? AND COALESCE(content_at, created_at) < ?",
                               arguments: [now.timeIntervalSince1970 - Self.coverageGapRetention,
                                   now.addingTimeInterval(-HistoricalAuditContext.lookback).timeIntervalSince1970])
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
        _ = try await mutateLedger { ledger in ledger.pruneProcessedSources(before: cutoff, stampingUntimedAt: now) }
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
                try db.execute(sql: "UPDATE collection_work SET state = ? WHERE state = ? AND id IN (SELECT id FROM captures WHERE state = 0)",
                    arguments: [CollectionWorkState.queued.rawValue, CollectionWorkState.processing.rawValue])
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
                try Self.updateWork(id: id, state: .processing, at: now, in: db)
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
        guard now.timeIntervalSince1970.isFinite else { throw StorageError.invalidTime }
        let count = capture.retryCount + 1
        let shouldDrop = count > limits.maxRetryCount || capture.expiresAt <= now
        let opened = try? await openCapturedWork(capture)
        let attempted = try await prepareFailedHistoricalAttempt(opened: opened, continuing: !shouldDrop, at: now)
        let loss: PreparedCoverageSettlement?
        if shouldDrop {
            loss = try await prepareCaptureLoss(id: capture.id, body: opened?.body,
                capturedAt: capture.capturedAt, reason: capture.expiresAt <= now ? .queueExpired : reason,
                at: now, audit: opened?.historicalAudit, context: try await collectionWork(id: capture.id)?.context)
        } else { loss = nil }
        try check(permit)
        do {
            try Self.write(database) { db in
                try Self.checkClaim(capture, in: db, at: now, allowExpired: true)
                if let attempted {
                    try db.execute(sql: """
                        INSERT INTO historical_progress (id, updated_at, encoded) VALUES (?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at, encoded = excluded.encoded
                        """, arguments: [attempted.id.uuidString, now.timeIntervalSince1970, attempted.bytes])
                }
                try Self.updateWork(id: capture.id, state: shouldDrop ? .terminal : .stalled, at: now, in: db)
                if shouldDrop {
                    try Self.consumeCapture(capture.id, in: db)
                    if let loss { try Self.writeCoverageSettlement(loss, at: now, maximumBytes: limits.maxProtectedStateBytes, in: db) }
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

    /// Aggregate deletion evidence for an explicitly opted-in disposable acceptance vault.
    /// This exports no references, kinds or encrypted payload bytes.
    @_spi(Testing) public func protectedPayloadCountForTesting() throws -> Int {
        guard !closed else { throw StorageError.databaseUnavailable }
        do {
            return try Self.read(database) { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM protected_payloads") ?? 0
            }
        } catch { throw StorageError.databaseUnavailable }
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
        coverageGaps: [CoverageGap] = [], recoveredReferences: [CoverageRecoveryReference] = [],
        successfulRead: Bool = false, observedReaderVersion: String? = nil, observedProducerVersions: Set<String> = [], permit: StoreProcessingPermit, at now: Date = Date()
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
        let currentWork = try await collectionWork(id: capture.id)
        let priorRecoveryID = try Self.read(database) { db in
            try String.fetchOne(db, sql: "SELECT recovery_of FROM collection_work WHERE id = ?", arguments: [capture.id.uuidString])
        }.flatMap(UUID.init(uuidString:))
        let recoveryTarget: StoredCollectionWork?
        if let priorRecoveryID { recoveryTarget = try await collectionWork(id: priorRecoveryID) }
        else { recoveryTarget = nil }
        let finished = continuation == nil && historicalProgress?.hasUnreadContent != true
        let chain: RecoveryChainEvidence?
        if let currentWork { chain = try await recoveryChain(for: currentWork) }
        else { chain = nil }
        let chainSuccessful = chain?.successfulPages == true && successfulRead && !coverageGaps.contains {
            $0.requiresAnalysis && ($0.reason != .budgetExhausted || continuation == nil)
        }
        var recoveryCertificateBytes: Data?
        var certifiedRows: [(UUID, Data)] = []
        var recoveryWindowCovered = false
        if finished, chainSuccessful, !coverageGaps.contains(where: \.requiresAnalysis),
           let target = recoveryTarget, target.state == .terminal,
           let targetWindow = try? Self.recoveryWindow(for: target, at: now),
           let currentWork, currentWork.context.operation == .historicalRead, currentWork.context.audit != nil,
           currentWork.context.scope == target.context.scope,
           currentWork.context.retry.map({ target.context.retry?.identifiesSameSource(as: $0) == true }) == true,
           let window = currentWork.context.auditWindow,
           window.duration == HistoricalAuditContext.lookback, window.end <= now {
            let previous = try await certifiedRecoveryEvidence(for: target)
            certifiedRows = previous.rows
            let certificate = CollectionRecoveryCertificate(targetWorkID: target.id, auditWindow: window, completedAt: now)
            recoveryCertificateBytes = try await sealWorkValue(certificate, id: capture.id)
            recoveryWindowCovered = Self.uncoveredRecoveryIntervals(targetWindow, covered: previous.windows + [window]).isEmpty
        }
        var nextWorkBytes: Data?
        var nextRecoveryChainBytes: Data?
        var successfulReadPayload: (id: UUID, bytes: Data)?
        if successfulRead, let context = currentWork?.context {
            guard !coverageGaps.contains(where: { $0.requiresAnalysis && $0.reason != .budgetExhausted }) else {
                throw StorageError.invalidPayload
            }
            guard observedReaderVersion.map({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) }) ?? true else {
                throw StorageError.invalidPayload
            }
            // Admission predates execution and may survive a reader upgrade. Native Codex
            // read evidence must come from the process that returned the content.
            let readerVersion = context.scope.provider == .codex && context.scope.path == .publicHistory
                ? observedReaderVersion : context.readerVersion
            let key = try await successfulReadID(context: context)
            let record = SuccessfulCollectionRead(scope: context.scope, operation: context.operation, succeededAt: now,
                producerVersions: observedProducerVersions, readerVersion: readerVersion, hostVersion: context.hostVersion)
            successfulReadPayload = (key, try await sealWorkValue(record, id: key))
        }
        var nextCapture: (id: UUID, bytes: Data, workClass: Int)?
        var progressPayload: (id: UUID, bytes: Data)?
        var gapAudit: CoverageAuditIdentity?
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
                if let context = currentWork?.context { nextWorkBytes = try await sealWorkValue(context, id: id) }
                if let chain {
                    nextRecoveryChainBytes = try await sealWorkValue(RecoveryChainEvidence(schemaVersion: 1,
                        targetWorkID: chain.targetWorkID, auditID: chain.auditID, auditWindow: chain.auditWindow,
                        successfulPages: chainSuccessful), id: id)
                }
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
                let id = try await historicalProgressID(audit: progress.audit, metadata: original.metadata)
                let previous = try await storedProgress(id: id)
                let total = (previous?.progress.bytesRead ?? 0).addingReportingOverflow(progress.bytesRead)
                guard !total.overflow else { throw StorageError.invalidPayload }
                let oldest = [previous?.progress.oldestContentTime, progress.oldestContentTime].compactMap { $0 }.min()
                let newest = [previous?.progress.newestContentTime, progress.newestContentTime].compactMap { $0 }.max()
                let accumulated = HistoricalReadProgress(audit: progress.audit, bytesRead: total.partialValue,
                    oldestContentTime: oldest, newestContentTime: newest, hasUnreadContent: progress.hasUnreadContent)
                let record = StoredHistoricalProgress(provider: original.metadata.agent,
                    profileID: original.metadata.profileID, progress: accumulated,
                    lastAttemptedAt: now,
                    completedAt: !progress.hasUnreadContent && continuation == nil ? now : nil,
                    continuationQueued: continuation != nil)
                gapAudit = CoverageAuditIdentity(auditID: progress.audit.id, provider: original.metadata.agent,
                    profileID: original.metadata.profileID)
                let protected = try await cryptography.sealBackground(JSONEncoder().encode(record),
                    binding: Self.checkpointBinding(id))
                progressPayload = (id, try protected.encoded())
            }
        }
        let coverage = try await prepareCoverageSettlement(gaps: coverageGaps,
            recoveredReferences: recoveredReferences, at: now, audit: gapAudit,
            continuationQueued: continuation != nil, workID: currentWork?.id,
            recoveryContext: currentWork?.context)
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
            if let next = nextCapture, let nextWorkBytes {
                try Self.insertWork(id: next.id, context: nextWorkBytes, recoveryOf: priorRecoveryID, recoveryChain: nextRecoveryChainBytes,
                    at: now, maximumBytes: limits.maxProtectedStateBytes, in: db)
            }
            if let read = successfulReadPayload {
                try db.execute(sql: """
                    INSERT INTO successful_collection_reads (id, succeeded_at, encoded) VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET succeeded_at = excluded.succeeded_at, encoded = excluded.encoded
                    WHERE excluded.succeeded_at >= successful_collection_reads.succeeded_at
                    """, arguments: [read.id.uuidString, now.timeIntervalSince1970, read.bytes])
                guard try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(encoded)), 0) FROM successful_collection_reads") ?? 0
                    <= limits.maxProtectedStateBytes else { throw StorageError.stateTooLarge }
            }
            let completed = continuation != nil || (finished && !coverageGaps.contains(where: \.requiresAnalysis))
            try Self.updateWork(id: capture.id, state: completed ? .completed : .terminal, at: now, in: db)
            if let bytes = recoveryCertificateBytes, let priorRecoveryID {
                // Crypto preparation yields the actor. Keep the exact certified evidence
                // and unresolved target present until this atomic settlement commits.
                guard try String.fetchOne(db, sql: "SELECT state FROM collection_work WHERE id = ?",
                    arguments: [priorRecoveryID.uuidString]) == CollectionWorkState.terminal.rawValue else { throw StorageError.stateChanged }
                for (id, expected) in certifiedRows {
                    guard try Data.fetchOne(db, sql: "SELECT recovery_certificate FROM collection_work WHERE id = ? AND state = ?",
                        arguments: [id.uuidString, CollectionWorkState.completed.rawValue]) == expected else { throw StorageError.stateChanged }
                }
                try db.execute(sql: "UPDATE collection_work SET recovery_certificate = ? WHERE id = ?",
                    arguments: [bytes, capture.id.uuidString])
                guard try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(encoded) + COALESCE(length(recovery_certificate), 0) + COALESCE(length(recovery_chain), 0)), 0) FROM collection_work") ?? 0
                    <= limits.maxProtectedStateBytes else { throw StorageError.stateTooLarge }
            }
            if let priorRecoveryID, recoveryWindowCovered {
                try Self.updateWork(id: priorRecoveryID, state: .recovered, at: now, in: db)
                try db.execute(sql: """
                    UPDATE coverage_omissions SET state = ?, resolved_at = ?
                    WHERE id IN (SELECT omission_id FROM collection_work WHERE id = ?) AND state IN (?, ?)
                    """, arguments: [CoverageOmissionState.recovered.rawValue, now.timeIntervalSince1970,
                        priorRecoveryID.uuidString, CoverageOmissionState.retryable.rawValue, CoverageOmissionState.blocked.rawValue])
            }
            if let progress = progressPayload {
                try db.execute(sql: """
                    INSERT INTO historical_progress (id, updated_at, encoded) VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at, encoded = excluded.encoded
                    """, arguments: [progress.id.uuidString, now.timeIntervalSince1970, progress.bytes])
            }
            try Self.writeCoverageSettlement(coverage, at: now, maximumBytes: limits.maxProtectedStateBytes, in: db)
            try Self.consumeCapture(capture.id, in: db)
            try Self.pruneCompletedWork(in: db, retaining: limits.maxSuccessfulWorkRecords)
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

    /// Reads only row counts and encrypted envelope lengths in one database snapshot.
    /// Existing bindings are lifetime state, so the result has no content-date filter.
    public func capacitySnapshot() throws -> StoreCapacitySnapshot {
        guard !closed else { throw StorageError.databaseUnavailable }
        return try Self.read(database) { try Self.capacitySnapshot(in: $0, limits: limits) }
    }

    private static func capacitySnapshot(in db: Database, limits: StoreLimits) throws -> StoreCapacitySnapshot {
        let authorities = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS count, COALESCE(SUM(length(encoded)), 0) AS bytes FROM collection_authorities
            """)
        let slots = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS count, COALESCE(SUM(length(encoded)), 0) AS bytes FROM codex_hook_content_slots
            """)
        guard let authorities, let slots else { throw StorageError.databaseUnavailable }
        return .init(
            sourceAuthorities: .init(count: authorities["count"], encryptedBytes: authorities["bytes"],
                countLimit: limits.maxSourceAuthorities, encryptedBytesLimit: limits.maxProtectedStateBytes),
            codexHookContentSlots: .init(count: slots["count"], encryptedBytes: slots["bytes"],
                countLimit: limits.maxHookContentSlots, encryptedBytesLimit: limits.maxProtectedStateBytes))
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
            // Check the key before quotas: existing choices remain readable and
            // idempotent even if an older store already exceeds today's limits.
            guard try Data.fetchOne(db, sql: "SELECT encoded FROM collection_authorities WHERE id = ?",
                                    arguments: [id.uuidString]) == nil else { return false }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection_authorities") ?? 0
            let retainedBytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(encoded)), 0) FROM collection_authorities") ?? 0
            guard count < limits.maxSourceAuthorities, bytes.count <= limits.maxProtectedStateBytes,
                  retainedBytes <= limits.maxProtectedStateBytes - bytes.count else {
                throw StorageError.capacityExceeded(.sourceAuthorities)
            }
            try db.execute(sql: "INSERT INTO collection_authorities (id, encoded) VALUES (?, ?)",
                           arguments: [id.uuidString, bytes])
            return db.changesCount > 0
        }
        if !inserted {
            guard try await authority(for: choice.session)?.authorityID == choice.authorityID else {
                throw StorageError.invalidPayload
            }
        }
    }

    /// Persist the immutable hook revision before analysis. Admission requires an
    /// already-selected hook authority; this operation never chooses one itself.
    /// A crash after binding is safe: retry accepts the same revision and returns
    /// the original observation time. Slots are bounded but never age-pruned.
    public func bindCodexHookContent(
        source: SourceIdentity, revision contentRevision: ContentRevision,
        observedAt: Date, permit: StoreProcessingPermit
    ) async throws -> CodexHookContentBinding {
        try check(permit)
        guard StoredCodexHookContent.validSource(source) else { throw StorageError.invalidPayload }
        guard observedAt.timeIntervalSince1970.isFinite else { throw StorageError.invalidTime }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let id = try await structuralID(Data("codex-hook-content-slot-v1".utf8) + encoder.encode(source))
        let authorityID = try await authorityID(for: source.session)

        // The only normal slot transition is absent -> bound. Re-read if another
        // actor/writer wins during encryption; never replace the winning bytes.
        for attempt in 0..<3 {
            try check(permit)
            let previous = try Self.read(database) { db in
                (try Data.fetchOne(db, sql: "SELECT encoded FROM collection_authorities WHERE id = ?",
                                   arguments: [authorityID.uuidString]),
                 try Data.fetchOne(db, sql: "SELECT encoded FROM codex_hook_content_slots WHERE id = ?",
                                   arguments: [id.uuidString]))
            }
            guard let authorityBytes = previous.0 else { throw StorageError.invalidPayload }
            let authorityPlaintext = try await cryptography.openBackground(
                Self.decode(authorityBytes), binding: Self.checkpointBinding(authorityID))
            let authority: CollectionAuthorityChoice
            do { authority = try JSONDecoder().decode(CollectionAuthorityChoice.self, from: authorityPlaintext) }
            catch { throw StorageError.corruptProtectedState }
            guard authority.session == source.session else { throw StorageError.corruptProtectedState }
            guard authority.authorityID == StoredCodexHookContent.authorityID else { throw StorageError.invalidPayload }

            let result: CodexHookContentBinding
            let encoded: Data
            if let existing = previous.1 {
                // Existing immutable bindings remain readable when admission quotas are
                // lowered. The envelope's fixed decoding bound still protects the read.
                let plaintext = try await cryptography.openBackground(
                    Self.decode(existing), binding: Self.checkpointBinding(id))
                let stored: StoredCodexHookContent
                do { stored = try JSONDecoder().decode(StoredCodexHookContent.self, from: plaintext) }
                catch { throw StorageError.corruptProtectedState }
                guard stored.source == source, stored.firstObservedAt.timeIntervalSince1970.isFinite else {
                    throw StorageError.corruptProtectedState
                }
                result = stored.revision == contentRevision ? .accepted(firstObservedAt: stored.firstObservedAt) : .conflict
                encoded = existing
            } else {
                let stored = StoredCodexHookContent(source: source, revision: contentRevision, firstObservedAt: observedAt)
                let plaintext = try encoder.encode(stored)
                guard plaintext.count <= limits.maxProtectedStateBytes else {
                    throw StorageError.capacityExceeded(.codexHookContentSlots)
                }
                encoded = try await cryptography.sealBackground(plaintext, binding: Self.checkpointBinding(id)).encoded()
                guard encoded.count <= limits.maxProtectedStateBytes else {
                    throw StorageError.capacityExceeded(.codexHookContentSlots)
                }
                result = .accepted(firstObservedAt: observedAt)
            }
            try check(permit)
            let injector = failureInjector
            do {
                try Self.write(database) { db in
                    guard try Data.fetchOne(db, sql: "SELECT encoded FROM collection_authorities WHERE id = ?",
                                            arguments: [authorityID.uuidString]) == authorityBytes,
                          try Data.fetchOne(db, sql: "SELECT encoded FROM codex_hook_content_slots WHERE id = ?",
                                            arguments: [id.uuidString]) == previous.1 else {
                        throw StorageError.stateChanged
                    }
                    guard previous.1 == nil else { return }
                    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM codex_hook_content_slots") ?? 0
                    let bytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(encoded)), 0) FROM codex_hook_content_slots") ?? 0
                    guard count < limits.maxHookContentSlots,
                          bytes <= limits.maxProtectedStateBytes - encoded.count else {
                        throw StorageError.capacityExceeded(.codexHookContentSlots)
                    }
                    try db.execute(sql: "INSERT INTO codex_hook_content_slots (id, encoded) VALUES (?, ?)",
                                   arguments: [id.uuidString, encoded])
                    try injector?(.beforeProcessingCommit)
                }
            } catch StorageError.stateChanged where attempt < 2 { continue }
            if previous.1 == nil { try injector?(.afterProcessingCommit) }
            return result
        }
        throw StorageError.stateChanged
    }

    private func sealWorkValue<T: Encodable>(_ value: T, id: UUID) async throws -> Data {
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count <= 32 * 1024 else { throw StorageError.stateTooLarge }
        return try await cryptography.sealBackground(bytes, binding: Self.checkpointBinding(id)).encoded()
    }

    private func prepareWorkContext(_ context: CollectionWorkContext?, id: UUID, body: Data,
                                    audit: HistoricalAuditContext?, liveScope: LiveCaptureScope?,
                                    capturedAt: Date) async throws -> Data? {
        guard let context else { return nil }
        let packet = try CapturePacket(body: body)
        guard context.scope.provider == packet.metadata.agent, context.scope.profileID == packet.metadata.profileID,
              context.scope.interface == packet.metadata.interface,
              context.readerVersion?.utf8.count ?? 0 <= 256, context.hostVersion?.utf8.count ?? 0 <= 256 else {
            throw StorageError.invalidPayload
        }
        if let identity = context.audit {
            guard identity.auditID == audit?.id, identity.provider == context.scope.provider,
                  identity.profileID == context.scope.profileID else { throw StorageError.invalidPayload }
        }
        if let retry = context.retry {
            // An exact transcript filename can select a child before its native session is
            // known. Retaining that selection grants no read access; the reader checks roots.
            // Other collection paths still need their existing session/document identity.
            let exactTranscriptFile = context.scope.path == .versionedTranscript && retry.sourceURL.map {
                $0.isFileURL && ($0.host?.isEmpty ?? true) && $0.path.hasPrefix("/") && $0.path != "/"
                    && !$0.path.utf8.contains(0) && $0.path.utf8.count <= 4096
                    && $0.query == nil && $0.fragment == nil
            } == true
            guard retry.scope == context.scope, retry.session != nil || retry.sourceDocumentID != nil || exactTranscriptFile,
                  retry.sourceURL == nil || (retry.sourceURL!.isFileURL && retry.sourceURL!.query == nil
                    && retry.sourceURL!.fragment == nil && retry.sourceURL!.path.utf8.count <= 4096) else {
                throw StorageError.invalidPayload
            }
            if let session = retry.session {
                guard session.provider == context.scope.provider, session.profileID == context.scope.profileID,
                      !session.sessionID.isEmpty, session.sessionID.utf8.count <= 4096 else { throw StorageError.invalidPayload }
            }
        }
        if let window = context.auditWindow {
            guard window.start.timeIntervalSince1970.isFinite, window.end.timeIntervalSince1970.isFinite,
                  window.duration <= (context.operation == .liveRead ? HistoricalAuditContext.analysisHorizon : HistoricalAuditContext.lookback),
                  audit == nil || window == audit.map({ DateInterval(start: $0.start, end: $0.end) }) else { throw StorageError.invalidTime }
        }
        let identity = context.audit ?? audit.map {
            CoverageAuditIdentity(auditID: $0.id, provider: packet.metadata.agent, profileID: packet.metadata.profileID)
        }
        var frozenWindow = audit.map { DateInterval(start: $0.start, end: $0.end) } ?? context.auditWindow
        if audit == nil, context.operation == .liveRead, let retry = context.retry,
           retry.identifiesSameSource(as: retry),
           let liveScope, liveScope.startedAt <= capturedAt {
            // Live nudges also discover the original monitoring period's history. A moving
            // seven-day window would drop its early slice. Preserve that responsibility,
            // bounded by the pipeline's absolute analysis horizon, without changing filtering.
            let start = max(liveScope.startedAt.addingTimeInterval(-HistoricalAuditContext.lookback),
                capturedAt.addingTimeInterval(-HistoricalAuditContext.analysisHorizon))
            frozenWindow = DateInterval(start: start, end: capturedAt)
        }
        let persisted = CollectionWorkContext(scope: context.scope, operation: context.operation, audit: identity,
            retry: context.retry, readerVersion: context.readerVersion, hostVersion: context.hostVersion,
            trigger: context.trigger, auditWindow: frozenWindow)
        return try await sealWorkValue(persisted, id: id)
    }

    /// Expedites an existing failed attempt without creating duplicate source reads.
    @discardableResult
    public func retryQueuedWork(id: UUID, permit: StoreProcessingPermit, at now: Date = Date()) throws -> Bool {
        try check(permit)
        guard now.timeIntervalSince1970.isFinite else { throw StorageError.invalidTime }
        return try Self.write(database) { db in
            try db.execute(sql: """
                UPDATE captures SET available_at = ? WHERE id = ? AND state = 0 AND expires_at > ?
                AND id IN (SELECT id FROM collection_work WHERE state = ?)
                """, arguments: [now.timeIntervalSince1970, id.uuidString, now.timeIntervalSince1970,
                    CollectionWorkState.stalled.rawValue])
            let changed = db.changesCount == 1
            if changed {
                try db.execute(sql: "UPDATE collection_work SET state = ?, updated_at = ? WHERE id = ?",
                    arguments: [CollectionWorkState.queued.rawValue, now.timeIntervalSince1970, id.uuidString])
            }
            return changed
        }
    }

    private func successfulReadID(context: CollectionWorkContext) async throws -> UUID {
        struct Key: Encodable { let scope: CollectionScope; let operation: CollectionOperation }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try await structuralID(Data("successful-read-v1".utf8)
            + encoder.encode(Key(scope: context.scope, operation: context.operation)))
    }

    private func captureLossID(_ captureID: UUID) async throws -> UUID {
        try await structuralID(Data("capture-loss-v1:\(captureID.uuidString)".utf8))
    }

    private static func insertWork(id: UUID, context: Data, recoveryOf: UUID?, recoveryChain: Data? = nil, at now: Date,
                                   maximumBytes: Int, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO collection_work (id, state, admitted_at, updated_at, recovery_of, encoded, recovery_chain)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id.uuidString, CollectionWorkState.queued.rawValue, now.timeIntervalSince1970,
                now.timeIntervalSince1970, recoveryOf?.uuidString, context, recoveryChain])
        guard try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(encoded) + COALESCE(length(recovery_certificate), 0) + COALESCE(length(recovery_chain), 0)), 0) FROM collection_work") ?? 0 <= maximumBytes else {
            throw StorageError.stateTooLarge
        }
    }

    /// Completed polls have no unresolved work to retry. Keep a bounded recent receipt set,
    /// while retaining exact work referenced by gap evidence and the separate latest-read rows.
    private static func pruneCompletedWork(in db: Database, retaining count: Int) throws {
        try db.execute(sql: """
            DELETE FROM collection_work WHERE id IN (
                SELECT id FROM collection_work WHERE state IN (?, ?) AND retain_evidence = 0
                AND NOT (recovery_certificate IS NOT NULL AND recovery_of IN
                    (SELECT id FROM collection_work WHERE state = 'terminal'))
                ORDER BY updated_at DESC, id LIMIT -1 OFFSET ?)
            """, arguments: [CollectionWorkState.completed.rawValue, CollectionWorkState.recovered.rawValue, count])
    }

    private static func updateWork(id: UUID, state: CollectionWorkState, at now: Date, in db: Database) throws {
        try db.execute(sql: """
            UPDATE collection_work SET state = ?, updated_at = ?, attempted_at = ?, completed_at = ? WHERE id = ?
            """, arguments: [state.rawValue, now.timeIntervalSince1970, now.timeIntervalSince1970,
                state == .recovered || state == .completed ? now.timeIntervalSince1970 : nil, id.uuidString])
    }

    public func collectionWork(id: UUID) async throws -> StoredCollectionWork? {
        guard !closed else { throw StorageError.databaseUnavailable }
        let rows = try Self.read(database) { db in
            try Row.fetchAll(db, sql: "SELECT * FROM collection_work WHERE id = ?", arguments: [id.uuidString])
        }
        return try await decodeWorkRows(rows, totalCount: rows.count).items.first
    }

    /// UI report pagination is unrelated to source retry eligibility. Search only unfinished
    /// work, authenticate each bounded page, and fail explicitly instead of silently truncating.
    public func retryableCollectionWork(for source: CoverageSourceRetryDescriptor) async throws -> [StoredCollectionWork] {
        guard !closed else { throw StorageError.databaseUnavailable }
        guard source.identifiesSameSource(as: source) else { throw StorageError.invalidPayload }
        var result: [StoredCollectionWork] = []
        var cursor: (time: Double, id: String)?
        for _ in 0..<64 {
            let rows = try Self.read(database) { db in
                if let cursor {
                    return try Row.fetchAll(db, sql: """
                        SELECT * FROM collection_work WHERE state IN ('queued', 'processing', 'stalled', 'terminal')
                        AND (admitted_at < ? OR (admitted_at = ? AND id > ?))
                        ORDER BY admitted_at DESC, id LIMIT 128
                        """, arguments: [cursor.time, cursor.time, cursor.id])
                }
                return try Row.fetchAll(db, sql: """
                    SELECT * FROM collection_work WHERE state IN ('queued', 'processing', 'stalled', 'terminal')
                    ORDER BY admitted_at DESC, id LIMIT 128
                    """)
            }
            let decoded = try await decodeWorkRows(rows, totalCount: rows.count).items
            result += decoded.filter { $0.context.retry?.identifiesSameSource(as: source) == true }
            guard result.count <= 128 else { throw StorageError.stateTooLarge }
            if rows.count < 128 { return result }
            if let last = rows.last { cursor = (last["admitted_at"], last["id"]) }
        }
        throw StorageError.stateTooLarge
    }

    /// Exact recovery chains have their own bound, independent of unrelated completed work.
    public func recoveryCollectionWork(for targetID: UUID) async throws -> [StoredCollectionWork] {
        guard let target = try await collectionWork(id: targetID) else { throw StorageError.invalidPayload }
        let rows = try Self.read(database) { db in
            try Row.fetchAll(db, sql: "SELECT * FROM collection_work WHERE recovery_of = ? ORDER BY admitted_at, id LIMIT 129",
                arguments: [targetID.uuidString])
        }
        guard rows.count <= 128 else { throw StorageError.stateTooLarge }
        let work = try await decodeWorkRows(rows, totalCount: rows.count).items
        guard work.allSatisfy({ $0.recoveryOf == targetID && $0.context.scope == target.context.scope
            && $0.context.retry.map({ target.context.retry?.identifiesSameSource(as: $0) == true }) == true }) else {
            throw StorageError.corruptProtectedState
        }
        return work
    }

    /// At most two ordinary seven-day exact-source audits cover an admitted live interval.
    /// Unknown/legacy intervals are not guessed; a completed audit certifies only its own span.
    public func remainingRecoveryAuditEnds(for id: UUID, at now: Date = Date()) async throws -> [Date] {
        guard now.timeIntervalSince1970.isFinite else { throw StorageError.invalidTime }
        guard let target = try await collectionWork(id: id) else { throw StorageError.invalidPayload }
        if target.state == .recovered { return [] }
        guard target.state == .terminal else { throw StorageError.stateChanged }
        let window = try Self.recoveryWindow(for: target, at: now)
        var covered = try await certifiedRecoveryEvidence(for: target).windows
        var ends: [Date] = []
        while let missing = Self.uncoveredRecoveryIntervals(window, covered: covered).first {
            guard ends.count < 2 else { throw StorageError.invalidPayload }
            let end = min(window.end, missing.start.addingTimeInterval(HistoricalAuditContext.lookback))
            ends.append(end)
            covered.append(DateInterval(start: end.addingTimeInterval(-HistoricalAuditContext.lookback), end: end))
        }
        return ends
    }

    private static func recoveryWindow(for target: StoredCollectionWork, at now: Date) throws -> DateInterval {
        guard target.admittedAt <= now, target.admittedAt >= now.addingTimeInterval(-HistoricalAuditContext.lookback) else {
            throw StorageError.invalidTime
        }
        guard let retry = target.context.retry, retry.identifiesSameSource(as: retry),
              let window = target.context.auditWindow, window.start.timeIntervalSince1970.isFinite,
              window.end.timeIntervalSince1970.isFinite, window.end <= now,
              window.duration > 0, window.duration <= HistoricalAuditContext.analysisHorizon else {
            throw StorageError.invalidPayload
        }
        return window
    }

    private static func uncoveredRecoveryIntervals(_ target: DateInterval, covered: [DateInterval]) -> [DateInterval] {
        var cursor = target.start
        var missing: [DateInterval] = []
        for window in covered.sorted(by: { $0.start < $1.start }) {
            guard window.end > cursor, window.start < target.end else { continue }
            if window.start > cursor { missing.append(DateInterval(start: cursor, end: min(window.start, target.end))) }
            cursor = max(cursor, min(window.end, target.end))
            if cursor >= target.end { break }
        }
        if cursor < target.end { missing.append(DateInterval(start: cursor, end: target.end)) }
        return missing
    }

    private func certifiedRecoveryEvidence(for target: StoredCollectionWork) async throws -> (windows: [DateInterval], rows: [(UUID, Data)]) {
        let rows = try Self.read(database) { db in
            try Row.fetchAll(db, sql: "SELECT * FROM collection_work WHERE recovery_of = ? AND recovery_certificate IS NOT NULL LIMIT 129",
                arguments: [target.id.uuidString])
        }
        guard rows.count <= 128 else { throw StorageError.stateTooLarge }
        let decoded = try await decodeWorkRows(rows, totalCount: rows.count).items
        var windows: [DateInterval] = []
        var retained: [(UUID, Data)] = []
        for (row, work) in zip(rows, decoded) {
            guard work.state == .completed, let certificate = work.recoveryCertificate,
                  work.recoveryOf == target.id, certificate.targetWorkID == target.id,
                  work.context.scope == target.context.scope,
                  work.context.retry.map({ target.context.retry?.identifiesSameSource(as: $0) == true }) == true else {
                throw StorageError.corruptProtectedState
            }
            windows.append(certificate.auditWindow)
            retained.append((work.id, row["recovery_certificate"]))
        }
        return (windows, retained)
    }

    private func recoveryChain(for work: StoredCollectionWork) async throws -> RecoveryChainEvidence? {
        let encoded = try Self.read(database) { db in
            try Data.fetchOne(db, sql: "SELECT recovery_chain FROM collection_work WHERE id = ?", arguments: [work.id.uuidString])
        }
        guard let encoded else { return nil }
        let bytes = try await cryptography.openBackground(Self.decode(encoded), binding: Self.checkpointBinding(work.id))
        let chain = try JSONDecoder().decode(RecoveryChainEvidence.self, from: bytes)
        guard chain.schemaVersion == 1, chain.targetWorkID == work.recoveryOf,
              chain.auditID == work.context.audit?.auditID, chain.auditWindow == work.context.auditWindow,
              chain.auditWindow.duration == HistoricalAuditContext.lookback,
              work.context.operation == .historicalRead else { throw StorageError.corruptProtectedState }
        return chain
    }

    private static func workRows(in db: Database, from: Double, through: Double,
                                 limit: Int) throws -> (rows: [Row], count: Int) {
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection_work WHERE updated_at >= ? AND updated_at <= ?",
            arguments: [from, through]) ?? 0
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM collection_work WHERE updated_at >= ? AND updated_at <= ?
            ORDER BY (state IN ('queued', 'processing', 'stalled')) DESC, updated_at DESC, id LIMIT ?
            """, arguments: [from, through, limit])
        return (rows, count)
    }

    private func decodeWorkRows(_ rows: [Row], totalCount: Int) async throws -> CoverageQueryPage<StoredCollectionWork> {
        var result: [StoredCollectionWork] = []
        for row in rows {
            guard let id = UUID(uuidString: row["id"]), let state = CollectionWorkState(rawValue: row["state"]) else {
                throw StorageError.corruptProtectedState
            }
            let encoded: Data = row["encoded"]
            let context: CollectionWorkContext
            if let kept = openedWorkContexts.value(for: id, encoded: encoded) { context = kept } else {
                let bytes = try await cryptography.openBackground(Self.decode(encoded), binding: Self.checkpointBinding(id))
                context = try JSONDecoder().decode(CollectionWorkContext.self, from: bytes)
                openedWorkContexts.keep(context, for: id, encoded: encoded)
            }
            let attempted: Double? = row["attempted_at"], completed: Double? = row["completed_at"]
            let omission: String? = row["omission_id"]
            let recoveryString: String? = row["recovery_of"]
            let recoveryID = recoveryString.flatMap(UUID.init(uuidString:))
            guard recoveryString == nil || recoveryID != nil else { throw StorageError.corruptProtectedState }
            var certificate: CollectionRecoveryCertificate?
            if let encoded: Data = row["recovery_certificate"] {
                let bytes = try await cryptography.openBackground(Self.decode(encoded), binding: Self.checkpointBinding(id))
                let value = try JSONDecoder().decode(CollectionRecoveryCertificate.self, from: bytes)
                guard value.schemaVersion == 1, value.targetWorkID == recoveryID,
                      context.operation == .historicalRead, context.audit != nil,
                      value.auditWindow == context.auditWindow,
                      value.auditWindow.duration == HistoricalAuditContext.lookback,
                      value.completedAt.timeIntervalSince1970.isFinite,
                      value.auditWindow.end <= value.completedAt else { throw StorageError.corruptProtectedState }
                certificate = value
            }
            result.append(.init(id: id, context: context, state: state,
                admittedAt: Date(timeIntervalSince1970: row["admitted_at"]),
                lastAttemptedAt: attempted.map(Date.init(timeIntervalSince1970:)),
                completedAt: completed.map(Date.init(timeIntervalSince1970:)),
                omissionID: omission.flatMap(UUID.init(uuidString:)), recoveryOf: recoveryID, recoveryCertificate: certificate))
        }
        return .init(items: result, totalCount: totalCount)
    }

    private static func successfulReadRows(in db: Database, limit: Int) throws -> (rows: [Row], count: Int) {
        (try Row.fetchAll(db, sql: "SELECT * FROM successful_collection_reads ORDER BY succeeded_at DESC, id LIMIT ?", arguments: [limit]),
         try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM successful_collection_reads") ?? 0)
    }

    private func decodeSuccessfulReadRows(_ rows: [Row], totalCount: Int) async throws -> CoverageQueryPage<SuccessfulCollectionRead> {
        var result: [SuccessfulCollectionRead] = []
        for row in rows {
            guard let id = UUID(uuidString: row["id"]) else { throw StorageError.corruptProtectedState }
            let bytes = try await cryptography.openBackground(Self.decode(row["encoded"]), binding: Self.checkpointBinding(id))
            result.append(try JSONDecoder().decode(SuccessfulCollectionRead.self, from: bytes))
        }
        return .init(items: result, totalCount: totalCount)
    }

    private static func omissionCounts(in db: Database, from: Double, through: Double) throws -> [CoverageOmissionState: Int] {
        var result: [CoverageOmissionState: Int] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT state, COUNT(*) AS count FROM coverage_omissions
            WHERE COALESCE(content_at, created_at) >= ? AND COALESCE(content_at, created_at) <= ? GROUP BY state
            """, arguments: [from, through]) {
            guard let state = CoverageOmissionState(rawValue: row["state"]) else { throw StorageError.corruptProtectedState }
            result[state] = row["count"]
        }
        return result
    }

    public func historicalProgress(limit: Int = 100) async throws -> [StoredHistoricalProgress] {
        try await historicalProgressPage(limit: limit).items
    }

    public func historicalProgressPage(limit: Int = 1000, since: Date? = nil,
                                       until: Date? = nil) async throws -> CoverageQueryPage<StoredHistoricalProgress> {
        guard !closed else { throw StorageError.databaseUnavailable }
        guard limit > 0, limit <= 1000 else { throw StorageError.invalidPayload }
        guard since?.timeIntervalSince1970.isFinite != false,
              until?.timeIntervalSince1970.isFinite != false,
              since == nil || until == nil || since! <= until! else { throw StorageError.invalidTime }
        let from = since?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
        let through = until?.timeIntervalSince1970 ?? Double.greatestFiniteMagnitude
        let (rows, count) = try Self.read(database) {
            try Self.historicalProgressRows(in: $0, from: from, through: through, limit: limit)
        }
        return try await decodeHistoricalProgress(rows: rows, count: count)
    }

    private static func historicalProgressRows(in db: Database, from: Double, through: Double,
                                               limit: Int) throws -> (rows: [Row], count: Int) {
        let count = try Int.fetchOne(db,
            sql: "SELECT COUNT(*) FROM historical_progress WHERE updated_at >= ? AND updated_at <= ?",
            arguments: [from, through]) ?? 0
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, encoded, updated_at FROM historical_progress WHERE updated_at >= ? AND updated_at <= ?
            ORDER BY updated_at DESC, id LIMIT ?
            """, arguments: [from, through, limit])
        return (rows, count)
    }

    private func decodeHistoricalProgress(rows: [Row], count: Int) async throws -> CoverageQueryPage<StoredHistoricalProgress> {
        var result: [StoredHistoricalProgress] = []
        for row in rows {
            guard let id = UUID(uuidString: row["id"]) else { throw StorageError.corruptProtectedState }
            let payload = try Self.decode(row["encoded"])
            let plaintext = try await cryptography.openBackground(payload, binding: Self.checkpointBinding(id))
            let stored = try JSONDecoder().decode(StoredHistoricalProgress.self, from: plaintext)
            let updated: Double = row["updated_at"]
            result.append(StoredHistoricalProgress(provider: stored.provider, profileID: stored.profileID,
                progress: stored.progress, lastAttemptedAt: stored.lastAttemptedAt ?? Date(timeIntervalSince1970: updated),
                completedAt: stored.completedAt, continuationQueued: stored.continuationQueued))
        }
        return CoverageQueryPage(items: result, totalCount: count)
    }

    private func storedProgress(id: UUID) async throws -> StoredHistoricalProgress? {
        guard let bytes = try Self.read(database, { db in
            try Data.fetchOne(db, sql: "SELECT encoded FROM historical_progress WHERE id = ?", arguments: [id.uuidString])
        }) else { return nil }
        let plaintext = try await cryptography.openBackground(Self.decode(bytes), binding: Self.checkpointBinding(id))
        return try JSONDecoder().decode(StoredHistoricalProgress.self, from: plaintext)
    }

    private func historicalProgressID(audit: HistoricalAuditContext, metadata: CaptureMetadata) async throws -> UUID {
        let keyBytes = try JSONEncoder().encode([audit.id.uuidString, metadata.agent.rawValue, metadata.profileID])
        return try await structuralID(Data("history-progress-v1".utf8) + keyBytes)
    }

    private func prepareFailedHistoricalAttempt(opened: OpenedCapture?, continuing: Bool,
                                                 at now: Date) async throws -> (id: UUID, bytes: Data)? {
        guard let opened, let audit = opened.historicalAudit,
              let packet = try? CapturePacket(body: opened.body) else { return nil }
        let id = try await historicalProgressID(audit: audit, metadata: packet.metadata)
        let previous = try await storedProgress(id: id)
        let progress = HistoricalReadProgress(audit: audit, bytesRead: previous?.progress.bytesRead ?? 0,
            oldestContentTime: previous?.progress.oldestContentTime, newestContentTime: previous?.progress.newestContentTime,
            hasUnreadContent: true)
        let record = StoredHistoricalProgress(provider: packet.metadata.agent, profileID: packet.metadata.profileID,
            progress: progress, lastAttemptedAt: now, completedAt: nil, continuationQueued: continuing)
        let protected = try await cryptography.sealBackground(JSONEncoder().encode(record), binding: Self.checkpointBinding(id))
        return (id, try protected.encoded())
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
        try await coverageGapEvents(limit: limit, since: since).items.map(\.gap)
    }

    public func coverageGapEvents(limit: Int = 1000, since: Date? = nil,
                                  until: Date? = nil) async throws -> CoverageQueryPage<StoredCoverageGapEvent> {
        guard !closed else { throw StorageError.databaseUnavailable }
        guard limit > 0, limit <= 10_000 else { throw StorageError.invalidPayload }
        guard since?.timeIntervalSince1970.isFinite != false,
              until?.timeIntervalSince1970.isFinite != false,
              since == nil || until == nil || since! <= until! else { throw StorageError.invalidTime }
        let from = since?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
        let through = until?.timeIntervalSince1970 ?? Double.greatestFiniteMagnitude
        let (rows, count) = try Self.read(database) {
            try Self.coverageEventRows(in: $0, from: from, through: through, limit: limit)
        }
        return try await decodeCoverageEvents(rows: rows, count: count)
    }

    private static func coverageEventRows(in db: Database, from: Double, through: Double,
                                          limit: Int) throws -> (rows: [Row], count: Int) {
        let count = try Int.fetchOne(db,
            sql: "SELECT COUNT(*) FROM coverage_gaps WHERE created_at >= ? AND created_at <= ?",
            arguments: [from, through]) ?? 0
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, created_at, encoded FROM coverage_gaps WHERE created_at >= ? AND created_at <= ?
            ORDER BY created_at DESC, id LIMIT ?
            """, arguments: [from, through, limit])
        return (rows, count)
    }

    private func decodeCoverageEvents(rows: [Row], count: Int) async throws -> CoverageQueryPage<StoredCoverageGapEvent> {
        var events: [StoredCoverageGapEvent] = []
        for row in rows {
            do {
                guard let id = UUID(uuidString: row["id"]) else { throw StorageError.corruptProtectedState }
                let encoded: Data = row["encoded"]
                let opened: OpenedGapEvent
                if let kept = openedGapEvents.value(for: id, encoded: encoded) { opened = kept } else {
                    let bytes = try await cryptography.openBackground(Self.decode(encoded), binding: Self.checkpointBinding(id))
                    if let event = try? JSONDecoder().decode(StoredCoverageGapEvent.self, from: bytes) {
                        opened = .event(event)
                    } else {
                        opened = .legacy(try JSONDecoder().decode(CoverageGap.self, from: bytes))
                    }
                    openedGapEvents.keep(opened, for: id, encoded: encoded)
                }
                let observed = Date(timeIntervalSince1970: row["created_at"])
                switch opened {
                case .event(let event):
                    guard event.id == id, abs(event.observedAt.timeIntervalSince(observed)) < 0.001 else {
                        throw StorageError.corruptProtectedState
                    }
                    events.append(event)
                case .legacy(let gap):
                    events.append(StoredCoverageGapEvent(id: id, gap: gap, observedAt: observed))
                }
            } catch let error as StorageError { throw error }
            catch { throw StorageError.protectionUnavailable }
        }
        return CoverageQueryPage(items: events, totalCount: count)
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
        let settlement = try await prepareCoverageSettlement(gaps: [gap], recoveredReferences: [], at: time)
        guard !closed else { throw StorageError.databaseUnavailable }
        try Self.write(database) { db in
            try Self.writeCoverageSettlement(settlement, at: time, maximumBytes: limits.maxProtectedStateBytes, in: db)
        }
    }

    /// Unresolved losses remain attributable beyond the short activity-gap window. Passing a
    /// displayed-period cutoff filters by original content time, or observation when unknown.
    public func coverageOmissions(limit: Int = 1000, since: Date? = nil,
                                  includeRecovered: Bool = false) async throws -> [CoverageOmission] {
        try await coverageOmissionPage(limit: limit, since: since, includeRecovered: includeRecovered).items
    }

    public func coverageOmissionPage(limit: Int = 1000, since: Date? = nil, until: Date? = nil,
                                     includeRecovered: Bool = false) async throws -> CoverageQueryPage<CoverageOmission> {
        guard !closed else { throw StorageError.databaseUnavailable }
        guard limit > 0, limit <= 10_000 else { throw StorageError.invalidPayload }
        guard since?.timeIntervalSince1970.isFinite != false, until?.timeIntervalSince1970.isFinite != false,
              since == nil || until == nil || since! <= until! else { throw StorageError.invalidTime }
        let from = since?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
        let through = until?.timeIntervalSince1970 ?? Double.greatestFiniteMagnitude
        let (rows, count) = try Self.read(database) {
            try Self.coverageOmissionRows(in: $0, from: from, through: through, limit: limit, includeRecovered: includeRecovered)
        }
        return try await decodeCoverageOmissions(rows: rows, count: count)
    }

    private static func coverageOmissionRows(in db: Database, from: Double, through: Double, limit: Int,
                                             includeRecovered: Bool) throws -> (rows: [Row], count: Int) {
        let count = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM coverage_omissions WHERE COALESCE(content_at, created_at) >= ?
            AND COALESCE(content_at, created_at) <= ? AND (? OR state != ?)
            """, arguments: [from, through, includeRecovered, CoverageOmissionState.recovered.rawValue]) ?? 0
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, encoded, state, resolved_at FROM coverage_omissions
            WHERE COALESCE(content_at, created_at) >= ? AND COALESCE(content_at, created_at) <= ?
                AND (? OR state != ?)
            ORDER BY (state = ?) ASC, created_at DESC, id LIMIT ?
            """, arguments: [from, through, includeRecovered, CoverageOmissionState.recovered.rawValue,
                CoverageOmissionState.recovered.rawValue, limit])
        return (rows, count)
    }

    private func decodeCoverageOmissions(rows: [Row], count: Int) async throws -> CoverageQueryPage<CoverageOmission> {
        var result: [CoverageOmission] = []
        for row in rows {
            guard let id = UUID(uuidString: row["id"]),
                  let state = CoverageOmissionState(rawValue: row["state"]) else { throw StorageError.corruptProtectedState }
            let encoded: Data = row["encoded"]
            let stored: CoverageOmission
            if let kept = openedOmissions.value(for: id, encoded: encoded) { stored = kept } else {
                let plaintext = try await cryptography.openBackground(Self.decode(encoded), binding: Self.checkpointBinding(id))
                stored = try JSONDecoder().decode(CoverageOmission.self, from: plaintext)
                guard stored.id == id else { throw StorageError.corruptProtectedState }
                openedOmissions.keep(stored, for: id, encoded: encoded)
            }
            let resolved: Double? = row["resolved_at"]
            result.append(CoverageOmission(id: id, gap: stored.gap, firstObservedAt: stored.firstObservedAt,
                state: state, resolvedAt: resolved.map(Date.init(timeIntervalSince1970:))))
        }
        return CoverageQueryPage(items: result, totalCount: count)
    }

    /// The UI and every bounded diagnostic query share the same seven calendar days.
    public func coverageReport(endingAt requestedEnd: Date? = nil, limit: Int = 1000,
                               calendar: Calendar = .current) async throws -> CoverageReport {
        guard !closed else { throw StorageError.databaseUnavailable }
        guard limit > 0, limit <= 10_000 else { throw StorageError.invalidPayload }
        let now = requestedEnd ?? Date()
        guard now.timeIntervalSince1970.isFinite else { throw StorageError.invalidTime }
        let window = AnalyzedActivity.recentWindow(endingAt: now, calendar: calendar)
        let from = window.start.timeIntervalSince1970, through = window.end.timeIntervalSince1970
        // All encrypted rows, counts and queue metadata come from one SQLite snapshot before
        // decryption yields the actor. A concurrent commit cannot make an earlier event page
        // appear to describe a later empty queue or a successfully completed audit.
        let rows = try Self.read(database) { db in
            try CoverageReportRows(
                events: Self.coverageEventRows(in: db, from: from, through: through, limit: limit),
                omissions: Self.coverageOmissionRows(in: db, from: from, through: through,
                    limit: limit, includeRecovered: true),
                history: Self.historicalProgressRows(in: db, from: from, through: through, limit: min(limit, 1000)),
                queue: Self.queueStatistics(in: db),
                oldestPendingAt: Double.fetchOne(db, sql: "SELECT MIN(captured_at) FROM captures"),
                work: Self.workRows(in: db, from: from, through: through, limit: limit),
                successes: Self.successfulReadRows(in: db, limit: limit),
                omissionCounts: Self.omissionCounts(in: db, from: from, through: through),
                capacity: Self.capacitySnapshot(in: db, limits: limits))
        }
        let events = try await decodeCoverageEvents(rows: rows.events.rows, count: rows.events.count)
        let omissions = try await decodeCoverageOmissions(rows: rows.omissions.rows, count: rows.omissions.count)
        let history = try await decodeHistoricalProgress(rows: rows.history.rows, count: rows.history.count)
        return CoverageReport(window: window, gapEvents: events, omissions: omissions, history: history,
            queue: rows.queue, oldestPendingCaptureAt: rows.oldestPendingAt.map(Date.init(timeIntervalSince1970:)),
            work: try await decodeWorkRows(rows.work.rows, totalCount: rows.work.count),
            omissionStateCounts: rows.omissionCounts,
            successfulReads: try await decodeSuccessfulReadRows(rows.successes.rows, totalCount: rows.successes.count),
            capacity: rows.capacity)
    }

    /// A blocked omission becomes retryable under another parser contract. This returns metadata
    /// for bounded original-source reads; it does not claim that those reads or recovery occurred.
    public func recoverableOmissions(scope: CollectionScope? = nil, session: SessionIdentity? = nil,
                                    documentID: UUID? = nil, parserContract: String? = nil,
                                    at now: Date = Date(), limit: Int = 1000) async throws -> [CoverageOmission] {
        guard now.timeIntervalSince1970.isFinite else { throw StorageError.invalidTime }
        return try await coverageOmissions(limit: limit, since: now.addingTimeInterval(-HistoricalAuditContext.lookback)).filter { omission in
            guard omission.isEligibleForRecovery(at: now), let reference = omission.gap.recovery else { return false }
            if let scope, omission.gap.scope != scope { return false }
            if let session, reference.session != session { return false }
            if let documentID {
                if let sourceDocumentID = reference.sourceDocumentID {
                    if sourceDocumentID != documentID { return false }
                } else {
                    switch reference.locator {
                    case .transcript(let id, _), .transcriptByteOffset(let id, _): if id != documentID { return false }
                    default: return false
                    }
                }
            }
            return parserContract == nil || omission.state == .retryable || reference.parserContract != parserContract
        }
    }

    /// Time changes eligibility, never recovery. Old unresolved losses are explicitly unavailable
    /// for further seven-day recovery and remain in the omission ledger. A content incident that
    /// can no longer recover settles; a recurrence opens and notifies a new incident.
    @discardableResult
    public func expireCoverageRecovery(at now: Date = Date()) throws -> Int {
        guard !closed, now.timeIntervalSince1970.isFinite else { throw StorageError.invalidTime }
        return try Self.write(database) { db in
            try db.execute(sql: """
                UPDATE coverage_omissions SET state = ?
                WHERE COALESCE(content_at, created_at) < ? AND state IN (?, ?)
                """, arguments: [CoverageOmissionState.unrecoverable.rawValue,
                    now.addingTimeInterval(-HistoricalAuditContext.lookback).timeIntervalSince1970,
                    CoverageOmissionState.retryable.rawValue, CoverageOmissionState.blocked.rawValue])
            let expired = db.changesCount
            _ = try Self.resolveHealthIncidents(where: """
                requires_assessment = 0
                    AND key_id IN (SELECT incident_key FROM coverage_omissions WHERE state = ?)
                """, arguments: [CoverageOmissionState.unrecoverable.rawValue], at: now, in: db)
            return expired
        }
    }

    public func healthIncidents(limit: Int = 1000, includeResolved: Bool = false) async throws -> [CollectionHealthIncident] {
        guard !closed else { throw StorageError.databaseUnavailable }
        guard limit > 0, limit <= 10_000 else { throw StorageError.invalidPayload }
        let rows = try Self.read(database) { db in
            try Row.fetchAll(db, sql: """
                SELECT id, encoded, resolved_at, delivery FROM collection_health_incidents
                WHERE ? OR resolved_at IS NULL ORDER BY created_at DESC, id LIMIT ?
                """, arguments: [includeResolved, limit])
        }
        var incidents: [CollectionHealthIncident] = []
        for row in rows { incidents.append(try await decodeHealthIncident(row)) }
        return incidents
    }

    public func pendingHealthNotifications() async throws -> [CollectionHealthIncident] {
        guard processingPermit() != nil else { return [] }
        return try await healthIncidents().filter { $0.delivery == .pending }
    }

    public func healthIncident(id: UUID) async throws -> CollectionHealthIncident? {
        guard !closed else { return nil }
        guard let row = try Self.read(database, { db in
            try Row.fetchOne(db, sql: "SELECT id, encoded, resolved_at, delivery FROM collection_health_incidents WHERE id = ?",
                             arguments: [id.uuidString])
        }) else { return nil }
        return try await decodeHealthIncident(row)
    }

    /// A fresh successful operation assessment settles only that route's operation incident.
    /// Native omissions must also be reparsed; content failures and sibling routes remain active.
    @discardableResult
    public func resolveHealthIncidents(scope: CollectionScope, operation: CollectionOperation,
                                       at now: Date = Date()) async throws -> Int {
        guard !closed, now.timeIntervalSince1970.isFinite else { throw StorageError.invalidTime }
        let ids = try await healthIncidents().filter {
            $0.scope == scope && $0.contentType == nil && $0.operation == operation
        }.map(\.id)
        guard !closed else { throw StorageError.databaseUnavailable }
        return try Self.write(database) { db in
            try ids.reduce(0) { resolved, id in
                resolved + (try Self.resolveHealthIncidents(where: "id = ? AND requires_assessment = 1",
                    arguments: [id.uuidString], at: now, in: db))
            }
        }
    }

    private func decodeHealthIncident(_ row: Row) async throws -> CollectionHealthIncident {
        guard let id = UUID(uuidString: row["id"]),
              let delivery = AlertDeliveryState(rawValue: row["delivery"]) else { throw StorageError.corruptProtectedState }
        let plaintext = try await cryptography.openBackground(Self.decode(row["encoded"]), binding: Self.checkpointBinding(id))
        let stored = try JSONDecoder().decode(CollectionHealthIncident.self, from: plaintext)
        guard stored.id == id else { throw StorageError.corruptProtectedState }
        let resolved: Double? = row["resolved_at"]
        return CollectionHealthIncident(id: id, scope: stored.scope, contentType: stored.contentType,
            operation: stored.operation, reason: stored.reason, firstObservedAt: stored.firstObservedAt,
            resolvedAt: resolved.map(Date.init(timeIntervalSince1970:)), delivery: delivery)
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
                        let related = try String.fetchAll(db, sql: """
                            WITH RECURSIVE related(id) AS (
                                SELECT ? UNION SELECT work.id FROM collection_work work JOIN related ON work.recovery_of = related.id
                            ) SELECT id FROM related
                            """, arguments: [id])
                        for relatedID in related {
                            guard let captureID = UUID(uuidString: relatedID) else { throw StorageError.corruptProtectedState }
                            try Self.consumeCapture(captureID, in: db)
                            try db.execute(sql: "DELETE FROM collection_work WHERE id = ?", arguments: [relatedID])
                        }
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

    private func prepareCaptureLoss(id captureID: UUID, body: Data?, capturedAt: Date,
                                    reason: CoverageGapReason, at now: Date,
                                    audit: HistoricalAuditContext? = nil, context: CollectionWorkContext? = nil) async throws -> PreparedCoverageSettlement {
        let metadata = body.flatMap { try? CapturePacket(body: $0).metadata }
        // Without persisted route authority we cannot infer the path from the provider.
        let scope = context?.scope
        let gap = CoverageGap(reason: reason, interval: context?.auditWindow ?? audit.map { DateInterval(start: $0.start, end: $0.end) }, scope: scope, operation: context?.operation,
            diagnosticCode: reason.defaultDiagnosticCode, observedAt: now)
        let id = try await captureLossID(captureID)
        // The queue copy ending says nothing about retention of the original source.
        let state: CoverageOmissionState = context?.retry == nil ? .blocked : .retryable
        let omission = CoverageOmission(id: id, gap: gap, firstObservedAt: now, state: state, resolvedAt: nil)
        let sealed = try await cryptography.sealBackground(JSONEncoder().encode(omission), binding: Self.checkpointBinding(id))
        var result = PreparedCoverageSettlement()
        let identity = context?.audit ?? audit.flatMap { audit in metadata.map {
            CoverageAuditIdentity(auditID: audit.id, provider: $0.agent, profileID: $0.profileID)
        } }
        result.gaps = [try await sealedGap(gap, at: now, audit: identity, workID: captureID)]
        result.captureLossLinks = [(captureID, id)]
        result.workWithGapEvidence = [captureID]
        result.omissions = [.init(id: id, locationID: id, incidentKey: nil,
            encoded: try sealed.encoded(), time: nil, state: state)]
        return result
    }

    private func prepareCoverageSettlement(gaps: [CoverageGap], recoveredReferences: [CoverageRecoveryReference],
                                          at now: Date, audit: CoverageAuditIdentity? = nil,
                                          continuationQueued: Bool = false, workID: UUID? = nil,
                                          recoveryContext: CollectionWorkContext? = nil) async throws -> PreparedCoverageSettlement {
        guard now.timeIntervalSince1970.isFinite else { throw StorageError.invalidTime }
        guard gaps.count <= CollectionBatch.maximumRecoveryEntries,
              recoveredReferences.count <= CollectionBatch.maximumRecoveryEntries else { throw StorageError.stateTooLarge }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var prepared = PreparedCoverageSettlement()
        if !gaps.isEmpty, let workID { prepared.workWithGapEvidence.insert(workID) }
        var incidentKeys: Set<UUID> = []
        var omittedLocations: Set<UUID> = []
        var omissionIDs: Set<UUID> = []
        var requiredLocations: Set<UUID> = []
        if gaps.contains(where: { $0.recovery?.constraint == .recognizedLocalMedia }) {
            for gap in gaps where gap.requiresAnalysis {
                if let reference = gap.recovery {
                    try Self.validateRecoveryReference(reference,
                        allowClaudeAvailabilityURLOnly: Self.isClaudeAvailabilityWarning(gap))
                    requiredLocations.insert(try await structuralID(Data("coverage-recovery-location-v1".utf8)
                        + encoder.encode(RecoveryLocationKey(reference))))
                }
            }
        }
        // Mixed media and required text can share one canonical source position. Keep
        // every event, but the durable omission must describe its required unread part.
        for gap in gaps.sorted(by: {
            if Self.isUnclassifiedMetadataWarning($0) != Self.isUnclassifiedMetadataWarning($1) {
                return !Self.isUnclassifiedMetadataWarning($0)
            }
            if $0.requiresAnalysis != $1.requiresAnalysis { return $0.requiresAnalysis }
            if $0.isRequiredFormatFailure == true, $1.isRequiredFormatFailure == true,
               Self.isLegacyLocalMediaWarning($0) != Self.isLegacyLocalMediaWarning($1) {
                return !Self.isLegacyLocalMediaWarning($0)
            }
            return $0.isRequiredFormatFailure == true && $1.isRequiredFormatFailure != true
        }) {
            guard gap.recovery?.constraint != .claudeSourceAvailability else { throw StorageError.invalidPayload }
            guard gap.observedAt?.timeIntervalSince1970.isFinite != false else { throw StorageError.invalidTime }
            if let interval = gap.interval {
                guard interval.start.timeIntervalSince1970.isFinite,
                      interval.end.timeIntervalSince1970.isFinite, interval.duration.isFinite else { throw StorageError.invalidTime }
            }
            if let scope = gap.scope {
                guard !scope.profileID.isEmpty, scope.profileID.utf8.count <= 4096 else { throw StorageError.invalidPayload }
            }
            if gap.recovery?.constraint == .recognizedLocalMedia,
               !Self.isRecognizedLocalMediaGap(gap) { throw StorageError.invalidPayload }
            prepared.gaps.append(try await sealedGap(gap, at: now, audit: audit,
                isIntermediateBacklog: continuationQueued && audit != nil
                    && gap.reason == .budgetExhausted && gap.recovery == nil, workID: workID))
            var incidentKey: UUID?
            let formatFailureReasons: Set<CoverageGapReason> = [.unsupportedContent, .malformedSource, .missingTimestamp, .unresolvedCorrelation]
            if gap.isRequiredFormatFailure == true, formatFailureReasons.contains(gap.reason),
               let scope = gap.scope, gap.contentType != nil || gap.operation != nil {
                let key = try await structuralID(Data("collection-health-scope-v1".utf8)
                    + encoder.encode(HealthIdentityKey(scope: scope, contentType: gap.contentType,
                        reason: gap.reason, operation: gap.operation)))
                incidentKey = key
                if incidentKeys.insert(key).inserted {
                    let id = UUID()
                    let incident = CollectionHealthIncident(id: id, scope: scope, contentType: gap.contentType,
                        operation: gap.operation, reason: gap.reason, firstObservedAt: now, resolvedAt: nil, delivery: .pending)
                    let sealed = try await cryptography.sealBackground(encoder.encode(incident), binding: Self.checkpointBinding(id))
                    prepared.incidents.append((id, key, try sealed.encoded(), gap.recovery == nil))
                } else if gap.recovery == nil,
                          let index = prepared.incidents.firstIndex(where: { $0.key == key }) {
                    prepared.incidents[index].requiresAssessment = true
                }
            }
            if let reference = gap.recovery, let scope = gap.scope {
                try Self.validateRecoveryReference(reference,
                    allowClaudeAvailabilityURLOnly: Self.isClaudeAvailabilityWarning(gap))
                if let session = reference.session,
                   session.provider != scope.provider || session.profileID != scope.profileID { throw StorageError.invalidPayload }
                let location = RecoveryLocationKey(reference)
                let locationID = try await structuralID(Data("coverage-recovery-location-v1".utf8) + encoder.encode(location))
                let id = try await structuralID(Data("coverage-omission-v1".utf8)
                    + encoder.encode(OmissionIdentityKey(scope: scope, location: location,
                        contentType: gap.contentType, reason: gap.reason, operation: gap.operation)))
                omittedLocations.insert(locationID)
                guard omissionIDs.insert(id).inserted else { continue }
                var state: CoverageOmissionState = [.unsupportedContent, .unsupportedVersion, .malformedSource,
                    .missingTimestamp, .unresolvedCorrelation].contains(gap.reason) ? .blocked : .retryable
                var omissionGap = gap
                var firstObservedAt = now
                var contentTime = reference.contentTime
                var previousEncoded: Data?
                var upgradesOmissionMeaning = false
                var reclassifiedLocalMedia: MetadataRecoveryRow?
                if let previous = try Self.read(database, { db in
                    try Row.fetchOne(db, sql: "SELECT id, location_id, created_at, content_at, encoded, state, incident_key, resolved_at FROM coverage_omissions WHERE id = ?",
                        arguments: [id.uuidString])
                }) {
                    let encoded: Data = previous["encoded"]
                    previousEncoded = encoded
                    let plaintext = try await cryptography.openBackground(Self.decode(encoded),
                        binding: Self.checkpointBinding(id))
                    let stored = try JSONDecoder().decode(CoverageOmission.self, from: plaintext)
                    guard stored.id == id else { throw StorageError.corruptProtectedState }
                    if reference.constraint == .recognizedLocalMedia {
                        let row = try Self.metadataRecoveryRow(previous)
                        // A local-media proof cannot use the generic upgrade/reopen paths.
                        // Preserve every other meaning, inactive row and legacy time ambiguity.
                        guard let context = recoveryContext, context.scope == scope,
                              context.operation == gap.operation,
                              Self.isRecognizedLocalMediaGap(gap),
                              !requiredLocations.contains(locationID), row.locationID == locationID,
                              row.state == CoverageOmissionState.blocked.rawValue
                                || row.state == CoverageOmissionState.retryable.rawValue,
                              row.resolvedAt == nil,
                              row.createdAt == stored.firstObservedAt.timeIntervalSince1970,
                              row.contentAt == reference.contentTime?.timeIntervalSince1970,
                              Self.isLegacyLocalMediaWarning(stored.gap),
                              stored.gap.scope == scope, stored.gap.operation == gap.operation,
                              let old = stored.gap.recovery, old.sourceURL == nil,
                              old.identifiesSameLocation(as: reference), old.contentTime == reference.contentTime,
                              stored.isEligibleForRecovery(at: now) else { continue }
                        try Self.validateRecoveryReference(old)
                        let expectedIncident = try await structuralID(Data("collection-health-scope-v1".utf8)
                            + encoder.encode(HealthIdentityKey(scope: scope, contentType: stored.gap.contentType,
                                reason: stored.gap.reason, operation: stored.gap.operation)))
                        guard row.incidentKey == nil || row.incidentKey == expectedIncident.uuidString else {
                            throw StorageError.corruptProtectedState
                        }
                        reclassifiedLocalMedia = row
                        state = CoverageOmissionState(rawValue: row.state)!
                    }
                    // A fresh required observation must invalidate an in-flight local
                    // media proof even when it repeats the legacy diagnostic exactly.
                    let refreshesLegacyRequiredMeaning = Self.isLegacyLocalMediaWarning(stored.gap)
                        && gap.isRequiredFormatFailure == true && gap.requiresAnalysis
                    // A fresh absence must invalidate an in-flight availability proof. Keep
                    // the original retention age, but never let a delayed older observation
                    // move the latest known absence backwards.
                    let refreshesClaudeAvailability = Self.isClaudeAvailabilityWarning(stored.gap)
                        && Self.isClaudeAvailabilityWarning(gap)
                    upgradesOmissionMeaning = (!stored.gap.requiresAnalysis && gap.requiresAnalysis
                        && !Self.isUnclassifiedMetadataWarning(gap))
                        || (Self.isUnclassifiedMetadataWarning(stored.gap) && !Self.isUnclassifiedMetadataWarning(gap))
                        || refreshesLegacyRequiredMeaning || refreshesClaudeAvailability
                    let previousCreated: Double = previous["created_at"]
                    let previousContent: Double? = previous["content_at"]
                    let previousState: String = previous["state"]
                    firstObservedAt = Date(timeIntervalSince1970: previousCreated)
                    // A new demonstrated failure can reopen the same canonical position, but it
                    // cannot renew that source's seven-day age. Newly known time can only tighten it.
                    // Without content time, the age is only when the loss was observed: a recovered
                    // position failing again after that age has passed is a new loss, not an expired one.
                    if previousState == CoverageOmissionState.recovered.rawValue, previousContent == nil,
                       firstObservedAt < now.addingTimeInterval(-HistoricalAuditContext.lookback) {
                        firstObservedAt = now
                    }
                    contentTime = previousContent.map(Date.init(timeIntervalSince1970:))
                        ?? reference.contentTime.map { min(firstObservedAt, $0) }
                    let preserved = reclassifiedLocalMedia == nil ? gap : stored.gap
                    omissionGap = CoverageGap(reason: gap.reason, capabilityID: preserved.capabilityID,
                        interval: preserved.interval, scope: gap.scope, contentType: gap.contentType, operation: gap.operation,
                        recovery: .init(session: reference.session, locator: reference.locator,
                            itemID: reference.itemID, contentTime: contentTime, parserContract: reference.parserContract,
                            sourceDocumentID: reference.sourceDocumentID, sourceURL: reference.sourceURL,
                            constraint: reference.constraint),
                        isRequiredFormatFailure: gap.isRequiredFormatFailure,
                        sourceKind: gap.sourceKind, diagnosticCode: gap.diagnosticCode,
                        excludedContent: gap.excludedContent,
                        observedAt: refreshesClaudeAvailability
                            ? max(stored.gap.observedAt ?? now, gap.observedAt ?? now)
                            : refreshesLegacyRequiredMeaning ? gap.observedAt ?? now : preserved.observedAt)
                }
                let omission = CoverageOmission(id: id, gap: omissionGap, firstObservedAt: firstObservedAt, state: state, resolvedAt: nil)
                let sealed = try await cryptography.sealBackground(encoder.encode(omission), binding: Self.checkpointBinding(id))
                prepared.omissions.append(.init(id: id, locationID: locationID, incidentKey: incidentKey,
                    encoded: try sealed.encoded(), time: contentTime, state: state, checksPrevious: true,
                    previousEncoded: previousEncoded, upgradesOmissionMeaning: upgradesOmissionMeaning,
                    reclassifiedLocalMedia: reclassifiedLocalMedia))
            }
        }
        var metadataLocations: Set<UUID> = []
        var metadataCandidateCount = 0
        for reference in recoveredReferences {
            try Self.validateRecoveryReference(reference)
            guard reference.constraint != .recognizedLocalMedia else { throw StorageError.invalidPayload }
            let locationID = try await structuralID(Data("coverage-recovery-location-v1".utf8)
                + encoder.encode(RecoveryLocationKey(reference)))
            // Even a caller incorrectly reporting a partially readable record as recovered cannot
            // settle its unread siblings in the same batch.
            guard !omittedLocations.contains(locationID) else { continue }
            if reference.constraint == .unclassifiedMetadata || reference.constraint == .claudeSourceAvailability {
                // Recovery of a metadata warning needs the current authorized route as well
                // as the old encrypted omission. Legacy captures without work context do
                // not acquire this authority from a native ID alone.
                guard let context = recoveryContext else { continue }
                let scope = context.scope
                let availability = reference.constraint == .claudeSourceAvailability
                if availability {
                    guard scope.provider == .claudeCode, scope.path == .versionedTranscript,
                          context.operation == .liveRead,
                          reference.session == nil || reference.session?.profileID == scope.profileID,
                          context.retry?.sourceURL == reference.sourceURL,
                          context.retry?.session == reference.session,
                          let observed = reference.availabilityObservedAt, observed <= now else { continue }
                } else {
                    guard scope.provider == .codex, scope.path == .publicHistory,
                          context.operation == .liveRead || context.operation == .historicalRead,
                          scope.profileID == reference.session?.profileID else { continue }
                }
                guard metadataLocations.insert(locationID).inserted else { continue }
                let remainingCandidates = 256 - metadataCandidateCount
                guard remainingCandidates > 0 else { continue }
                let rows = try Self.read(database) { db in
                    try Self.metadataRecoveryRows(locationID: locationID, at: now,
                        limit: remainingCandidates, in: db)
                }
                // Optional warning bookkeeping must not block unrelated text progress.
                // An overflowing location remains entirely unresolved; a later exact
                // selection can retry skipped locations with its own bounded budget.
                guard rows.count <= remainingCandidates else {
                    // The overflow sentinel consumed the remaining lookup allowance.
                    // Do not query every later overflowing location in this capture.
                    metadataCandidateCount = 256
                    continue
                }
                metadataCandidateCount += rows.count
                var recoveredIDs: Set<UUID> = []
                for row in rows {
                    let plaintext = try await cryptography.openBackground(Self.decode(row.encoded),
                        binding: Self.checkpointBinding(row.id))
                    let omission = try JSONDecoder().decode(CoverageOmission.self, from: plaintext)
                    guard omission.id == row.id else { throw StorageError.corruptProtectedState }
                    guard omission.gap.scope == scope, let old = omission.gap.recovery,
                          old.identifiesSameLocation(as: reference) else { continue }
                    if availability {
                        guard Self.isClaudeAvailabilityWarning(omission.gap),
                              old.session == reference.session, old.sourceURL == reference.sourceURL,
                              let lastMissing = omission.gap.observedAt,
                              let observed = reference.availabilityObservedAt, lastMissing <= observed else { continue }
                    } else {
                        guard row.incidentKey == nil, Self.isUnclassifiedMetadataWarning(omission.gap),
                              old.sourceURL == nil, old.contentTime == reference.contentTime else { continue }
                    }
                    try Self.validateRecoveryReference(old,
                        allowClaudeAvailabilityURLOnly: availability)
                    recoveredIDs.insert(row.id)
                }
                // Keep even an empty snapshot: an omission inserted during later crypto
                // preparation must not be silently cleared or treated as this observation.
                prepared.metadataRecoveries.append(.init(locationID: locationID, rows: rows, recoveredIDs: recoveredIDs))
            } else {
                prepared.recoveredLocations.insert(locationID)
            }
        }
        return prepared
    }

    private static func isUnclassifiedMetadataWarning(_ gap: CoverageGap) -> Bool {
        gap.scope?.provider == .codex && gap.scope?.path == .publicHistory
            && (gap.operation == .liveRead || gap.operation == .historicalRead)
            && gap.reason == .unsupportedContent && gap.sourceKind == .codexUnknownItem
            && gap.diagnosticCode == .unknownRecordKind && gap.contentType == nil
            && gap.isRequiredFormatFailure == false && gap.excludedContent == nil
            && gap.recovery?.constraint == nil
    }

    private static func isClaudeAvailabilityWarning(_ gap: CoverageGap) -> Bool {
        guard gap.scope?.provider == .claudeCode, gap.scope?.path == .versionedTranscript,
              gap.operation == .liveRead, gap.reason == .sourceUnavailable,
              gap.diagnosticCode == .unavailableSource, gap.contentType == nil,
              gap.sourceKind == nil, gap.isRequiredFormatFailure == nil, gap.excludedContent == nil,
              let reference = gap.recovery, reference.constraint == nil,
              reference.availabilityObservedAt == nil, reference.locator == .unavailable,
              reference.itemID == nil, reference.sourceDocumentID == nil,
              reference.contentTime == nil, reference.sourceURL != nil else { return false }
        return reference.session == nil || reference.session?.provider == .claudeCode
    }

    private static func isRecognizedLocalMediaGap(_ gap: CoverageGap) -> Bool {
        gap.scope?.provider == .codex && gap.scope?.path == .publicHistory
            && (gap.operation == .liveRead || gap.operation == .historicalRead)
            && gap.reason == .unsupportedContent && gap.contentType == .userPrompt
            && gap.sourceKind == .codexUserMessage && gap.diagnosticCode == .excludedBinaryContent
            && gap.isRequiredFormatFailure == false && gap.excludedContent == true
            && gap.recovery?.constraint == .recognizedLocalMedia
    }

    private static func isLegacyLocalMediaWarning(_ gap: CoverageGap) -> Bool {
        gap.scope?.provider == .codex && gap.scope?.path == .publicHistory
            && (gap.operation == .liveRead || gap.operation == .historicalRead)
            && gap.reason == .unsupportedContent && gap.contentType == .userPrompt
            && gap.sourceKind == .codexUserMessage && gap.diagnosticCode == .unknownBlockKind
            && gap.isRequiredFormatFailure == true && gap.excludedContent == nil
            && gap.recovery?.constraint == nil
    }

    private static func metadataRecoveryRows(locationID: UUID, at now: Date, limit: Int = 256,
                                             in db: Database) throws -> [MetadataRecoveryRow] {
        guard (1...256).contains(limit) else { throw StorageError.invalidPayload }
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, location_id, encoded, state, created_at, content_at, incident_key, resolved_at
            FROM coverage_omissions WHERE location_id = ? AND state IN (?, ?)
                AND COALESCE(content_at, created_at) >= ? AND COALESCE(content_at, created_at) <= ?
            ORDER BY id LIMIT ?
            """, arguments: [locationID.uuidString, CoverageOmissionState.blocked.rawValue,
                CoverageOmissionState.retryable.rawValue,
                now.addingTimeInterval(-HistoricalAuditContext.lookback).timeIntervalSince1970,
                now.timeIntervalSince1970, limit + 1])
        return try rows.map(metadataRecoveryRow)
    }

    private static func metadataRecoveryRow(_ row: Row) throws -> MetadataRecoveryRow {
        guard let id = UUID(uuidString: row["id"]), let locationID = UUID(uuidString: row["location_id"]) else {
            throw StorageError.corruptProtectedState
        }
        return MetadataRecoveryRow(id: id, locationID: locationID, encoded: row["encoded"], state: row["state"],
            createdAt: row["created_at"], contentAt: row["content_at"],
            incidentKey: row["incident_key"], resolvedAt: row["resolved_at"])
    }

    private static func validateRecoveryReference(_ reference: CoverageRecoveryReference,
                                                 allowClaudeAvailabilityURLOnly: Bool = false) throws {
        guard !reference.parserContract.isEmpty, reference.parserContract.utf8.count <= 256,
              reference.contentTime?.timeIntervalSince1970.isFinite != false,
              reference.itemID?.utf8.count ?? 0 <= 4096,
              reference.availabilityObservedAt?.timeIntervalSince1970.isFinite != false else { throw StorageError.invalidPayload }
        if reference.constraint == .claudeSourceAvailability {
            guard reference.session == nil || reference.session?.provider == .claudeCode,
                  reference.locator == .unavailable, reference.itemID == nil,
                  reference.contentTime == nil, reference.sourceDocumentID == nil,
                  reference.sourceURL != nil, reference.availabilityObservedAt != nil,
                  !reference.parserContract.utf8.contains(0) else { throw StorageError.invalidPayload }
        } else if reference.constraint != nil {
            func boundedNativeID(_ value: String?) -> Bool {
                guard let value, !value.isEmpty, value.utf8.count <= 256 else { return false }
                return !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
            }
            guard reference.session?.provider == .codex, reference.locator == .upstreamItem,
                  boundedNativeID(reference.session?.sessionID), boundedNativeID(reference.itemID),
                  reference.contentTime != nil, reference.sourceDocumentID == nil, reference.sourceURL == nil,
                  !reference.parserContract.utf8.contains(0) else { throw StorageError.invalidPayload }
        }
        if reference.constraint != .claudeSourceAvailability, reference.availabilityObservedAt != nil {
            throw StorageError.invalidPayload
        }
        if let session = reference.session {
            guard !session.profileID.isEmpty, !session.sessionID.isEmpty,
                  session.profileID.utf8.count <= 4096, session.sessionID.utf8.count <= 4096 else { throw StorageError.invalidPayload }
        }
        if let url = reference.sourceURL {
            guard url.isFileURL, url.path.utf8.count <= 4096, url.query == nil, url.fragment == nil else {
                throw StorageError.invalidPayload
            }
            if reference.constraint == .claudeSourceAvailability || allowClaudeAvailabilityURLOnly {
                guard url.path.hasPrefix("/"), url.pathExtension == "jsonl",
                      url.host == nil || url.host == "", !url.path.utf8.contains(0) else {
                    throw StorageError.invalidPayload
                }
            }
        }
        if reference.sourceDocumentID != nil {
            guard reference.locator == .unavailable,
                  reference.itemID == nil || reference.itemID == ClaudeAdapter.sourceAvailabilityItemID else {
                throw StorageError.invalidPayload
            }
        }
        switch reference.locator {
        case .transcript, .transcriptByteOffset: break
        case .upstreamItem:
            guard reference.session != nil else { throw StorageError.invalidPayload }
        case .unavailable:
            guard reference.session != nil || reference.sourceDocumentID != nil
                    || ((allowClaudeAvailabilityURLOnly || reference.constraint == .claudeSourceAvailability)
                        && reference.sourceURL != nil) else { throw StorageError.invalidPayload }
        }
    }

    /// Gap metadata, recoverable positions and health decisions settle with source progress.
    /// Structural indexes contain only keyed/random UUIDs, controlled states and timestamps.
    private static func writeCoverageSettlement(_ prepared: PreparedCoverageSettlement, at now: Date,
                                               maximumBytes: Int, in db: Database) throws {
        // Crypto preparation yields the actor. A concurrent insert or semantic upgrade
        // invalidates the old age/meaning we encrypted. Roll back all source progress so
        // the caller can prepare again, including when an absent row appeared meanwhile.
        for omission in prepared.omissions where omission.checksPrevious {
            let current = try Data.fetchOne(db, sql: "SELECT encoded FROM coverage_omissions WHERE id = ?",
                arguments: [omission.id.uuidString])
            guard current == omission.previousEncoded else { throw StorageError.stateChanged }
            if let previous = omission.reclassifiedLocalMedia {
                let row = try Row.fetchOne(db, sql: "SELECT id, location_id, encoded, state, created_at, content_at, incident_key, resolved_at FROM coverage_omissions WHERE id = ?",
                    arguments: [omission.id.uuidString])
                guard let row, try metadataRecoveryRow(row) == previous else { throw StorageError.stateChanged }
            }
        }
        for recovery in prepared.metadataRecoveries {
            guard try metadataRecoveryRows(locationID: recovery.locationID, at: now, in: db) == recovery.rows else {
                throw StorageError.stateChanged
            }
        }
        for gap in prepared.gaps { try insertGap(gap, at: now, in: db) }
        for id in prepared.workWithGapEvidence {
            try db.execute(sql: "UPDATE collection_work SET retain_evidence = 1 WHERE id = ?", arguments: [id.uuidString])
        }
        for link in prepared.captureLossLinks {
            try db.execute(sql: "UPDATE collection_work SET omission_id = ? WHERE id = ?",
                arguments: [link.omission.uuidString, link.capture.uuidString])
        }
        for omission in prepared.omissions {
            if omission.reclassifiedLocalMedia != nil {
                // Reclassification preserves the original lifecycle and age. It removes
                // only this obsolete format warning's incident membership, not the row.
                try db.execute(sql: "UPDATE coverage_omissions SET encoded = ?, incident_key = NULL WHERE id = ?",
                    arguments: [omission.encoded, omission.id.uuidString])
                continue
            }
            try db.execute(sql: """
                INSERT INTO coverage_omissions
                    (id, location_id, incident_key, created_at, content_at, state, encoded)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET incident_key = excluded.incident_key,
                    created_at = CASE WHEN coverage_omissions.content_at IS NULL AND coverage_omissions.created_at < ?
                        THEN excluded.created_at ELSE coverage_omissions.created_at END,
                    content_at = COALESCE(coverage_omissions.content_at, excluded.content_at),
                    state = excluded.state, resolved_at = NULL, encoded = excluded.encoded
                WHERE coverage_omissions.state = ?
                """, arguments: [omission.id.uuidString, omission.locationID.uuidString,
                    omission.incidentKey?.uuidString, now.timeIntervalSince1970,
                    omission.time?.timeIntervalSince1970, omission.state.rawValue, omission.encoded,
                    now.addingTimeInterval(-HistoricalAuditContext.lookback).timeIntervalSince1970,
                    CoverageOmissionState.recovered.rawValue])
            if omission.upgradesOmissionMeaning {
                // Required text dominates a previously excluded sibling without renewing
                // its age or resetting its lifecycle. An authenticated optional unknown
                // warning likewise cannot hide a later known or required failure. Recovered
                // rows follow the existing recurrence policy in the INSERT above.
                try db.execute(sql: """
                    UPDATE coverage_omissions SET encoded = ?,
                        content_at = COALESCE(content_at, ?)
                    WHERE id = ? AND state != ?
                    """, arguments: [omission.encoded, omission.time?.timeIntervalSince1970,
                        omission.id.uuidString, CoverageOmissionState.recovered.rawValue])
            }
            // A position first recorded without a required failure must still join the
            // later incident. Include expired losses so expiry can settle their incident.
            if let key = omission.incidentKey {
                try db.execute(sql: """
                    UPDATE coverage_omissions SET incident_key = ?
                    WHERE id = ? AND incident_key IS NULL AND state != ?
                    """, arguments: [key.uuidString, omission.id.uuidString,
                        CoverageOmissionState.recovered.rawValue])
            }
        }
        if !prepared.omissions.isEmpty {
            let bytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(encoded)), 0) FROM coverage_omissions") ?? 0
            guard bytes <= maximumBytes else { throw StorageError.stateTooLarge }
        }
        for incident in prepared.incidents {
            try db.execute(sql: """
                INSERT OR IGNORE INTO collection_health_incidents
                    (id, key_id, created_at, delivery, requires_assessment, encoded)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [incident.id.uuidString, incident.key.uuidString, now.timeIntervalSince1970,
                    AlertDeliveryState.pending.rawValue, incident.requiresAssessment, incident.encoded])
            if incident.requiresAssessment {
                try db.execute(sql: "UPDATE collection_health_incidents SET requires_assessment = 1 WHERE key_id = ? AND resolved_at IS NULL",
                               arguments: [incident.key.uuidString])
            }
        }
        for key in Set(prepared.omissions.compactMap { $0.reclassifiedLocalMedia?.incidentKey }) {
            _ = try resolveHealthIncidents(where: "requires_assessment = 0 AND key_id = ?",
                arguments: [key], at: now, in: db)
        }
        let cutoff = now.addingTimeInterval(-HistoricalAuditContext.lookback).timeIntervalSince1970
        for recovery in prepared.metadataRecoveries {
            for id in recovery.recoveredIDs {
                try db.execute(sql: """
                    UPDATE coverage_omissions SET state = ?, resolved_at = ?
                    WHERE id = ? AND state IN (?, ?) AND COALESCE(content_at, created_at) >= ?
                        AND COALESCE(content_at, created_at) <= ?
                    """, arguments: [CoverageOmissionState.recovered.rawValue, now.timeIntervalSince1970,
                        id.uuidString, CoverageOmissionState.blocked.rawValue, CoverageOmissionState.retryable.rawValue,
                        cutoff, now.timeIntervalSince1970])
            }
            for key in Set(recovery.rows.filter { recovery.recoveredIDs.contains($0.id) }.compactMap(\.incidentKey)) {
                _ = try resolveHealthIncidents(where: "requires_assessment = 0 AND key_id = ?",
                    arguments: [key], at: now, in: db)
            }
        }
        for locationID in prepared.recoveredLocations {
            try db.execute(sql: """
                UPDATE coverage_omissions SET state = ?, resolved_at = ?
                WHERE location_id = ? AND state IN (?, ?) AND COALESCE(content_at, created_at) >= ?
                    AND COALESCE(content_at, created_at) <= ?
                """, arguments: [CoverageOmissionState.recovered.rawValue, now.timeIntervalSince1970,
                    locationID.uuidString, CoverageOmissionState.blocked.rawValue, CoverageOmissionState.retryable.rawValue,
                    cutoff, now.timeIntervalSince1970])
            // Clearing one item cannot resolve the incident while another item remains omitted.
            _ = try resolveHealthIncidents(where: """
                requires_assessment = 0
                    AND key_id IN (SELECT incident_key FROM coverage_omissions WHERE location_id = ? AND state = ?)
                """, arguments: [locationID.uuidString, CoverageOmissionState.recovered.rawValue], at: now, in: db)
        }
    }

    /// Settles matching active incidents once none of their omissions can still be recovered.
    /// An unrecoverable loss stays in the omission ledger, but it cannot hold an incident open
    /// forever and silently absorb a later failure with the same identity.
    private static func resolveHealthIncidents(where condition: String, arguments: StatementArguments,
                                               at now: Date, in db: Database) throws -> Int {
        try db.execute(sql: """
            UPDATE collection_health_incidents SET resolved_at = ?,
                delivery = CASE WHEN delivery = ? THEN ? ELSE delivery END
            WHERE resolved_at IS NULL AND \(condition)
                AND NOT EXISTS (SELECT 1 FROM coverage_omissions
                    WHERE incident_key = collection_health_incidents.key_id AND state IN (?, ?))
            """, arguments: [now.timeIntervalSince1970, AlertDeliveryState.pending.rawValue,
                AlertDeliveryState.cancelled.rawValue] + arguments
                + [CoverageOmissionState.retryable.rawValue, CoverageOmissionState.blocked.rawValue])
        return db.changesCount
    }

    private func sealedGap(_ gap: CoverageGap, at time: Date, audit: CoverageAuditIdentity? = nil,
                           isIntermediateBacklog: Bool = false, workID: UUID? = nil) async throws -> ProtectedPayload {
        let id = UUID()
        do {
            return try await cryptography.sealBackground(
                JSONEncoder().encode(StoredCoverageGapEvent(id: id, gap: gap, observedAt: time,
                    audit: audit, isIntermediateBacklog: isIntermediateBacklog, workID: workID)),
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
        migrator.registerMigration("v5-scoped-coverage-recovery") { db in
            try db.execute(sql: """
                CREATE TABLE coverage_omissions (
                    id TEXT PRIMARY KEY NOT NULL, location_id TEXT NOT NULL, incident_key TEXT,
                    created_at REAL NOT NULL, content_at REAL, state TEXT NOT NULL, resolved_at REAL, encoded BLOB NOT NULL);
                CREATE INDEX coverage_omissions_location ON coverage_omissions (location_id, state);
                CREATE INDEX coverage_omissions_incident ON coverage_omissions (incident_key, state);
                CREATE TABLE collection_health_incidents (
                    id TEXT PRIMARY KEY NOT NULL, key_id TEXT NOT NULL, created_at REAL NOT NULL,
                    resolved_at REAL, delivery TEXT NOT NULL, requires_assessment INTEGER NOT NULL, encoded BLOB NOT NULL);
                CREATE UNIQUE INDEX collection_health_active ON collection_health_incidents (key_id) WHERE resolved_at IS NULL;
                """)
        }
        migrator.registerMigration("v6-collection-work-evidence") { db in
            try db.execute(sql: """
                CREATE TABLE collection_work (
                    id TEXT PRIMARY KEY NOT NULL, state TEXT NOT NULL, admitted_at REAL NOT NULL,
                    updated_at REAL NOT NULL, attempted_at REAL, completed_at REAL,
                    recovery_of TEXT, omission_id TEXT, retain_evidence INTEGER NOT NULL DEFAULT 0, encoded BLOB NOT NULL);
                CREATE INDEX collection_work_updated ON collection_work (updated_at);
                CREATE TABLE successful_collection_reads (
                    id TEXT PRIMARY KEY NOT NULL, succeeded_at REAL NOT NULL, encoded BLOB NOT NULL);
                """)
        }
        migrator.registerMigration("v7-codex-hook-content-slots") { db in
            try db.execute(sql: "CREATE TABLE codex_hook_content_slots (id TEXT PRIMARY KEY NOT NULL, encoded BLOB NOT NULL)")
        }
        migrator.registerMigration("v8-certified-source-recovery") { db in
            try db.execute(sql: "ALTER TABLE collection_work ADD COLUMN recovery_certificate BLOB")
            try db.execute(sql: "ALTER TABLE collection_work ADD COLUMN recovery_chain BLOB")
            try db.execute(sql: "CREATE INDEX collection_work_recovery ON collection_work (recovery_of)")
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
