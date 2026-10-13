import Foundation
import GRDB
import Testing
@_spi(Testing) @testable import SpillcheckCore

/// Synthetic predecessor-schema coverage. Payloads use ephemeral keys and fake content;
/// this is not evidence of migration from a signed historical application or a real vault.
@Suite("Collection work evidence migration from schema v5")
struct CollectionWorkMigrationTests {
    private static let predecessorMigrations = [
        "v1-protected-ingestion", "v2-bounded-history", "v3-user-workflow",
        "v4-bounded-bookkeeping", "v5-scoped-coverage-recovery"
    ]
    private static let currentMigration = "v6-collection-work-evidence"
    private static let legacyTables = [
        "protection_manifest", "store_state", "protected_payloads", "captures", "capture_receipts",
        "capture_value_links", "source_checkpoints", "coverage_gaps", "notification_outbox",
        "collection_authorities", "historical_progress", "protected_preferences",
        "historical_notification_outbox", "coverage_omissions", "collection_health_incidents"
    ]
    private static let marker = "SPILLCHECK_SYNTHETIC_V5_MIGRATION_PRIVATE"

    /// A fixed v5 SQL layout, deliberately independent of ProtectedStore's migrator. New
    /// encrypted fixture rows are copied into this layout without opening it as a store.
    private static let predecessorSchema = """
        CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
        CREATE TABLE protection_manifest (id INTEGER PRIMARY KEY CHECK (id = 1), encoded BLOB NOT NULL);
        CREATE TABLE store_state (id INTEGER PRIMARY KEY CHECK (id = 1), revision INTEGER NOT NULL, encoded BLOB NOT NULL);
        CREATE TABLE protected_payloads (reference_id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, encoded BLOB NOT NULL);
        CREATE TABLE captures (
            id TEXT PRIMARY KEY NOT NULL, encoded BLOB NOT NULL, byte_count INTEGER NOT NULL,
            captured_at REAL NOT NULL, expires_at REAL NOT NULL, retry_count INTEGER NOT NULL,
            available_at REAL NOT NULL, state INTEGER NOT NULL CHECK (state IN (0, 1)),
            claim_id TEXT, lease_until REAL,
            work_class INTEGER NOT NULL DEFAULT 0 CHECK (work_class IN (0, 1)));
        CREATE INDEX captures_ready ON captures (state, available_at, captured_at);
        CREATE TABLE capture_receipts (id TEXT PRIMARY KEY NOT NULL, consumed_at REAL NOT NULL DEFAULT 0);
        CREATE INDEX capture_receipts_consumed ON capture_receipts (consumed_at);
        CREATE TABLE capture_value_links (
            capture_id TEXT NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
            value_id TEXT NOT NULL, PRIMARY KEY (capture_id, value_id));
        CREATE TABLE source_checkpoints (document_id TEXT PRIMARY KEY NOT NULL, encoded BLOB NOT NULL);
        CREATE TABLE coverage_gaps (id TEXT PRIMARY KEY NOT NULL, created_at REAL NOT NULL, encoded BLOB NOT NULL);
        CREATE INDEX coverage_gaps_created ON coverage_gaps (created_at);
        CREATE TABLE notification_outbox (id TEXT PRIMARY KEY NOT NULL, value_id TEXT NOT NULL, delivery TEXT NOT NULL);
        CREATE TABLE collection_authorities (id TEXT PRIMARY KEY NOT NULL, encoded BLOB NOT NULL);
        CREATE TABLE historical_progress (id TEXT PRIMARY KEY NOT NULL, updated_at REAL NOT NULL, encoded BLOB NOT NULL);
        CREATE TABLE protected_preferences (id TEXT PRIMARY KEY NOT NULL, encoded BLOB NOT NULL);
        CREATE TABLE historical_notification_outbox (audit_id TEXT PRIMARY KEY NOT NULL, delivery TEXT NOT NULL);
        CREATE TABLE coverage_omissions (
            id TEXT PRIMARY KEY NOT NULL, location_id TEXT NOT NULL, incident_key TEXT,
            created_at REAL NOT NULL, content_at REAL, state TEXT NOT NULL, resolved_at REAL, encoded BLOB NOT NULL);
        CREATE INDEX coverage_omissions_location ON coverage_omissions (location_id, state);
        CREATE INDEX coverage_omissions_incident ON coverage_omissions (incident_key, state);
        CREATE TABLE collection_health_incidents (
            id TEXT PRIMARY KEY NOT NULL, key_id TEXT NOT NULL, created_at REAL NOT NULL,
            resolved_at REAL, delivery TEXT NOT NULL, requires_assessment INTEGER NOT NULL, encoded BLOB NOT NULL);
        CREATE UNIQUE INDEX collection_health_active ON collection_health_incidents (key_id) WHERE resolved_at IS NULL;
        """

    private struct Fixture {
        let directory: URL
        let crypto: BackgroundCryptography
        let now: Date
        let audit: HistoricalAuditContext
        let liveScope: LiveCaptureScope
        let completedID: UUID
        let pendingID: UUID
        let originalPacket: CapturePacket
        let continuation: CapturePacket
        let analysis: SourceAnalysis
        let payloads: [ProtectedPayload]
        let checkpoint: SourceCheckpoint
        let authority: CollectionAuthorityChoice
        let snapshot: InventorySnapshot
        let gap: CoverageGap
        let notificationIDs: Set<String>
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-v5-migration-\(UUID())")
            .resolvingSymlinksInPath()
    }

    private func readDatabase<T>(_ directory: URL, _ body: (Database) throws -> T) throws -> T {
        var configuration = Configuration()
        configuration.readonly = true
        let database = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path,
            configuration: configuration)
        defer { try? database.close() }
        return try database.read(body)
    }

    private func legacyRows(_ directory: URL) throws -> [String: [Row]] {
        try readDatabase(directory) { db in
            try Dictionary(uniqueKeysWithValues: Self.legacyTables.map { table in
                (table, try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY 1, 2"))
            })
        }
    }

    private func createPredecessor(at directory: URL, rows: [String: [Row]]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let databaseURL = directory.appendingPathComponent(ProtectedStore.databaseFilename)
        let database = try DatabaseQueue(path: databaseURL.path)
        defer { try? database.close() }
        try database.write { db in
            try db.execute(sql: Self.predecessorSchema)
            for migration in Self.predecessorMigrations {
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [migration])
            }
            for table in Self.legacyTables {
                for row in rows[table, default: []] {
                    let columns = row.columnNames.joined(separator: ", ")
                    let placeholders = Array(repeating: "?", count: row.count).joined(separator: ", ")
                    try db.execute(sql: "INSERT INTO \(table) (\(columns)) VALUES (\(placeholders))",
                        arguments: StatementArguments(row.databaseValues))
                }
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
    }

    private func makeFixture(in root: URL) async throws -> Fixture {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let seedDirectory = root.appendingPathComponent("encrypted-seed")
        let directory = root.appendingPathComponent("v5-store")
        let store = try await ProtectedStore.open(at: seedDirectory, cryptography: crypto)
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let liveScope = try LiveCaptureScope(startedAt: now, catchupAuditID: audit.id)
        let permit = try #require(await store.processingPermit())
        let originalPacket = try CapturePacket(metadata: .init(agent: .codex, profileID: Self.marker),
            eventJSON: JSONEncoder().encode(["cursor": "\(Self.marker)-page-0"]))
        let continuation = try CapturePacket(metadata: originalPacket.metadata,
            eventJSON: JSONEncoder().encode(["cursor": "\(Self.marker)-page-1"]))
        let completedID = UUID()
        _ = try await store.enqueue(originalPacket.body, id: completedID, capturedAt: now, permit: permit, at: now,
            scope: liveScope, historicalAudit: audit)
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        let sourceAnalysis = try analysis(profile: Self.marker, session: "\(Self.marker)-session",
            provenance: .historical(audit), contentTime: now)
        var payloads: [ProtectedPayload] = []
        for detection in sourceAnalysis.detections {
            payloads.append(try await crypto.sealInventory(Data("SYNTHETIC_VALUE_A".utf8), binding: .init(
                reference: detection.protectedValue, ownerID: detection.protectedValue.id, kind: .value)))
            if let excerpt = detection.protectedExcerpt {
                payloads.append(try await crypto.sealInventory(Data(Self.marker.utf8),
                    binding: .init(reference: excerpt, ownerID: excerpt.id, kind: .excerpt)))
            }
        }
        _ = try await store.commit(sourceAnalysis, payloads: payloads, linking: capture, permit: permit, at: now)
        let occurrenceID = try #require(await store.snapshot().occurrences.keys.first)
        try await store.review(occurrenceID, as: .confirmedSecret)
        let documentID = UUID()
        let cursor = Data("\(Self.marker)-checkpoint".utf8)
        let checkpoint = SourceCheckpoint(capabilityID: documentID, sourceDocumentID: documentID,
            revision: try await crypto.revision(canonicalBytes: cursor), byteOffset: 64, adapterState: cursor)
        let authority = try CollectionAuthorityChoice(session: sourceAnalysis.source.identity.session,
            adapterVersion: "v5-synthetic-reader", authorityID: CodexCollectionAuthority.publicNativeItems.rawValue)
        try await store.selectAuthority(authority, permit: permit)
        try await store.setProtectedPreference(Data("\(Self.marker)-preferences".utf8), for: .agentProfiles)
        let scope = CollectionScope(provider: .codex, profileID: Self.marker, interface: .standaloneCLI, path: .publicHistory)
        let gap = CoverageGap(reason: .malformedSource, scope: scope, contentType: .toolOutput,
            recovery: .init(session: authority.session, locator: .upstreamItem, itemID: "\(Self.marker)-unread-item",
                contentTime: now, parserContract: "v5-synthetic-parser"), isRequiredFormatFailure: true)
        try await store.completeCapture(capture, checkpoints: [checkpoint], continuation: continuation,
            historicalProgress: .init(audit: audit, bytesRead: 64, oldestContentTime: now,
                newestContentTime: now, hasUnreadContent: true), coverageGaps: [gap], permit: permit, at: now)
        let notifications = try await store.pendingNotifications()
        for notification in notifications {
            try await store.recordNotificationDelivery(identifier: notification.identifier, state: .delivered)
        }
        let snapshot = await store.snapshot()
        try await store.close()
        let rows = try legacyRows(seedDirectory)
        let pendingRow = try #require(rows["captures"]?.first)
        let pendingID = try #require(UUID(uuidString: pendingRow["id"] as String))
        try createPredecessor(at: directory, rows: rows)
        #expect(try legacyRows(directory) == rows)
        try readDatabase(directory) { db throws -> Void in
            #expect(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") == Self.predecessorMigrations)
            #expect(try !db.tableExists("collection_work"))
            #expect(try !db.tableExists("successful_collection_reads"))
            #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
        }
        return Fixture(directory: directory, crypto: crypto, now: now, audit: audit, liveScope: liveScope,
            completedID: completedID, pendingID: pendingID, originalPacket: originalPacket, continuation: continuation,
            analysis: sourceAnalysis, payloads: payloads, checkpoint: checkpoint, authority: authority, snapshot: snapshot,
            gap: gap, notificationIDs: Set(notifications.map(\.identifier)))
    }

    private func assertEncrypted(_ directory: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let file = directory.appendingPathComponent(ProtectedStore.databaseFilename + suffix)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let bytes = try Data(contentsOf: file)
            for marker in [Self.marker, "SYNTHETIC_VALUE_A", Data("\(Self.marker)-checkpoint".utf8).base64EncodedString()] {
                #expect(bytes.range(of: Data(marker.utf8)) == nil)
            }
        }
    }

    @Test func upgradePreservesV5RowsWithoutInventingSuccessfulReadEvidence() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeFixture(in: root)
        let before = try legacyRows(fixture.directory)
        let store = try await ProtectedStore.open(at: fixture.directory, cryptography: fixture.crypto)
        #expect(try legacyRows(fixture.directory) == before)
        try readDatabase(fixture.directory) { db throws -> Void in
            #expect(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
                == Self.predecessorMigrations + [Self.currentMigration, "v7-codex-hook-content-slots", "v8-certified-source-recovery"])
            #expect(try db.tableExists("collection_work"))
            #expect(try db.tableExists("successful_collection_reads"))
        }
        let snapshot = await store.snapshot()
        #expect(snapshot.records == fixture.snapshot.records)
        #expect(snapshot.occurrences == fixture.snapshot.occurrences)
        #expect(snapshot.analysisReceipts == fixture.snapshot.analysisReceipts)
        #expect(snapshot.locationReceipts == fixture.snapshot.locationReceipts)
        #expect(snapshot.occurrences.values.first?.review == .confirmedSecret)
        #expect(try await store.protectedPreference(.agentProfiles) == Data("\(Self.marker)-preferences".utf8))
        #expect(try await store.checkpoint(documentID: fixture.checkpoint.sourceDocumentID) == fixture.checkpoint)
        #expect(try await store.authority(for: fixture.authority.session) == fixture.authority)
        #expect(try await store.coverageOmissions().first?.gap == fixture.gap)
        #expect(!fixture.notificationIDs.isEmpty)
        #expect(try await store.pendingNotifications().isEmpty)
        for payload in fixture.payloads {
            // Compare every encrypted envelope field; JSONEncoder key ordering is not canonical.
            #expect(try await store.payload(payload.binding.reference) == payload)
        }
        let report = try await store.coverageReport(endingAt: fixture.now)
        #expect(report.queue.historicalCount == 1)
        #expect(report.history.items.first?.progress.bytesRead == 64)
        #expect(report.history.items.first?.progress.hasUnreadContent == true)
        #expect(report.work.items.isEmpty)
        #expect(report.successfulReads.items.isEmpty)
        let permit = try #require(await store.processingPermit())
        #expect(try await store.enqueue(fixture.originalPacket.body, id: fixture.completedID, capturedAt: fixture.now,
            permit: permit, at: fixture.now, historicalAudit: fixture.audit) == .alreadyProcessed(fixture.completedID))
        #expect(try await store.enqueue(fixture.continuation.body, id: fixture.pendingID, capturedAt: fixture.now,
            permit: permit, at: fixture.now, historicalAudit: fixture.audit) == .alreadyQueued(fixture.pendingID))
        #expect(try legacyRows(fixture.directory) == before)
        try assertEncrypted(fixture.directory)
        try await store.close()
    }

    @Test func migratedContinuationAndNewEvidenceSurviveRestartAndReplay() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeFixture(in: root)
        let store = try await ProtectedStore.open(at: fixture.directory, cryptography: fixture.crypto)
        let permit = try #require(await store.processingPermit())
        let capture = try #require(try await store.nextPending(at: fixture.now, permit: permit))
        #expect(capture.id == fixture.pendingID)
        #expect(try await store.collectionWork(id: capture.id) == nil)
        let opened = try await store.openCapturedWork(capture)
        #expect(opened.body == fixture.continuation.body)
        #expect(opened.scope == fixture.liveScope)
        #expect(opened.historicalAudit == fixture.audit)
        let replay = try await store.commit(fixture.analysis, payloads: fixture.payloads, linking: capture,
            permit: permit, at: fixture.now)
        #expect(replay.outcome == .replay)
        #expect(replay.insertedOccurrenceIDs.isEmpty)
        try await store.close()

        let reopened = try await ProtectedStore.open(at: fixture.directory, cryptography: fixture.crypto)
        let nextPermit = try #require(await reopened.processingPermit())
        let later = fixture.now.addingTimeInterval(181)
        let resumed = try #require(try await reopened.nextPending(at: later, permit: nextPermit))
        #expect(resumed.id == fixture.pendingID)
        #expect(resumed.claimID != capture.claimID)
        let secondReplay = try await reopened.commit(fixture.analysis, payloads: fixture.payloads, linking: resumed,
            permit: nextPermit, at: later)
        #expect(secondReplay.outcome == .replay)
        try await reopened.completeCapture(resumed,
            historicalProgress: .init(audit: fixture.audit, bytesRead: 32, oldestContentTime: fixture.now,
                newestContentTime: fixture.now, hasUnreadContent: false),
            successfulRead: true, observedProducerVersions: ["synthetic-producer"], permit: nextPermit, at: later)
        // Legacy admission lacks route provenance: completing it cannot manufacture v6 evidence.
        #expect(try await reopened.coverageReport(endingAt: later).successfulReads.items.isEmpty)
        #expect(try await reopened.coverageOmissions().count == 1)
        let scope = CollectionScope(provider: .codex, profileID: Self.marker, interface: .standaloneCLI, path: .publicHistory)
        let context = CollectionWorkContext(scope: scope, operation: .liveRead,
            readerVersion: "synthetic-reader-v6", trigger: .activePoll)
        let newID = UUID()
        _ = try await reopened.enqueue(fixture.originalPacket.body, id: newID, capturedAt: later, permit: nextPermit,
            at: later, workContext: context)
        let newCapture = try #require(try await reopened.nextPending(at: later, permit: nextPermit))
        try await reopened.completeCapture(newCapture, successfulRead: true,
            observedReaderVersion: "synthetic-reader-v6", observedProducerVersions: ["synthetic-producer"], permit: nextPermit, at: later)
        try assertEncrypted(fixture.directory)
        try await reopened.close()

        let again = try await ProtectedStore.open(at: fixture.directory, cryptography: fixture.crypto)
        let finalPermit = try #require(await again.processingPermit())
        for (id, body) in [(fixture.pendingID, fixture.continuation.body), (newID, fixture.originalPacket.body)] {
            #expect(try await again.enqueue(body, id: id, capturedAt: later, permit: finalPermit, at: later) == .alreadyProcessed(id))
        }
        let final = try await again.coverageReport(endingAt: later)
        #expect(final.queue.count == 0)
        #expect(final.history.items.first?.progress.bytesRead == 96)
        #expect(final.history.items.first?.progress.hasUnreadContent == false)
        #expect(final.work.totalCount == 1)
        #expect(final.work.items.first?.id == newID)
        #expect(final.work.items.first?.state == .completed)
        #expect(final.successfulReads.totalCount == 1)
        #expect(final.successfulReads.items.first?.scope == scope)
        #expect(final.successfulReads.items.first?.succeededAt == later)
        #expect(final.successfulReads.items.first?.readerVersion == "synthetic-reader-v6")
        #expect(final.successfulReads.items.first?.producerVersions == ["synthetic-producer"])
        #expect(await again.snapshot().occurrences == fixture.snapshot.occurrences)
        #expect(await again.snapshot().analysisReceipts == fixture.snapshot.analysisReceipts)
        #expect(try await again.checkpoint(documentID: fixture.checkpoint.sourceDocumentID) == fixture.checkpoint)
        #expect(try await again.protectedPreference(.agentProfiles) == Data("\(Self.marker)-preferences".utf8))
        try await again.close()
        try readDatabase(fixture.directory) { db throws -> Void in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                arguments: [Self.currentMigration]) == 1)
            #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
        }
        try assertEncrypted(fixture.directory)
    }
}
