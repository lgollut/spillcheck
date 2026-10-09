import Foundation
import GRDB
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor WorkflowBlockingCryptography: BackgroundStoreCryptography {
    nonisolated let manifest: ProtectionManifest
    private let delegate: BackgroundCryptography
    private var shouldBlock = false
    private var blocked = false
    private var gate: CheckedContinuation<Void, Never>?
    private var checkpointOpens = 0
    init(_ delegate: BackgroundCryptography) { self.delegate = delegate; manifest = delegate.manifest }
    func blockNextLedger() { shouldBlock = true; blocked = false }
    func isBlocked() -> Bool { blocked }
    func release() { gate?.resume(); gate = nil }
    func checkpointOpenCount() -> Int { checkpointOpens }
    func sealBackground(_ plaintext: Data, binding: PayloadBinding) async throws -> ProtectedPayload {
        if shouldBlock && binding.kind == .ledgerSnapshot {
            shouldBlock = false
            await withCheckedContinuation { gate = $0; blocked = true }
        }
        return try await delegate.sealBackground(plaintext, binding: binding)
    }
    func openBackground(_ payload: ProtectedPayload, binding: PayloadBinding) async throws -> Data {
        if binding.kind == .sourceCheckpoint { checkpointOpens += 1 }
        return try await delegate.openBackground(payload, binding: binding)
    }
    func revision(canonicalBytes: Data) async throws -> ContentRevision { try await delegate.revision(canonicalBytes: canonicalBytes) }
}

private func workflowWait(_ crypto: WorkflowBlockingCryptography) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await crypto.isBlocked()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(await crypto.isBlocked())
}

private func workflowDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-workflow-test-\(UUID())").resolvingSymlinksInPath()
}

private func workflowCommit(_ analysis: SourceAnalysis, store: ProtectedStore, crypto: BackgroundCryptography) async throws {
    var payloads: [ProtectedPayload] = []
    for finding in analysis.detections {
        payloads.append(try await crypto.sealInventory(Data("SYNTHETIC_VALUE_A".utf8),
            binding: PayloadBinding(reference: finding.protectedValue, ownerID: finding.protectedValue.id, kind: .value)))
        if let reference = finding.protectedExcerpt {
            payloads.append(try await crypto.sealInventory(Data("SYNTHETIC_EXCERPT".utf8),
                binding: PayloadBinding(reference: reference, ownerID: reference.id, kind: .excerpt)))
        }
    }
    let permit = try #require(await store.processingPermit())
    _ = try await store.commit(analysis, payloads: payloads, permit: permit)
}

private func workflowProgress(_ store: ProtectedStore, audit: HistoricalAuditContext, unread: Bool,
                              provider: AgentProvider = .codex, profile: String = "fixture-profile") async throws {
    let now = Date()
    let permit = try #require(await store.processingPermit())
    let packet = try CapturePacket(metadata: CaptureMetadata(agent: provider, profileID: profile), eventJSON: Data("{}".utf8))
    _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, historicalAudit: audit)
    let capture = try #require(try await store.nextPending(at: now, permit: permit))
    try await store.completeCapture(capture, historicalProgress: HistoricalReadProgress(audit: audit, bytesRead: 1,
        oldestContentTime: fixtureTime, newestContentTime: fixtureTime, hasUnreadContent: unread), permit: permit, at: now)
}

private func workflowWriteProgressFixture(_ rows: [(id: UUID, encoded: Data)], directory: URL) throws {
    let database = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path)
    defer { try? database.close() }
    try database.write { db in
        for row in rows {
            try db.execute(sql: "INSERT INTO historical_progress (id, updated_at, encoded) VALUES (?, ?, ?)",
                           arguments: [row.id.uuidString, fixtureTime.timeIntervalSince1970, row.encoded])
        }
    }
}

private func workflowGapCountAndRemoveProgress(_ id: UUID? = nil, directory: URL) throws -> Int {
    let database = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path)
    defer { try? database.close() }
    return try database.write { db in
        if let id { try db.execute(sql: "DELETE FROM historical_progress WHERE id = ?", arguments: [id.uuidString]) }
        return try #require(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM coverage_gaps"))
    }
}

@Suite("Encrypted workflow state and notification races")
struct WorkflowStorageTests {
    @Test func historicalNotificationBudgetIsVisibleDurableAndDeduplicated() async throws {
        let directory = workflowDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let observedCrypto = WorkflowBlockingCryptography(crypto)
        let store = try await ProtectedStore.open(at: directory, cryptography: observedCrypto)
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixtureTime)
        try await workflowCommit(analysis(provenance: .historical(audit)), store: store, crypto: crypto)
        try await store.close()

        // Match the production structural ID and AAD bindings without running 1,001 providers.
        let marker = "LEAKRET_SYNTHETIC_NOTIFICATION_BUDGET_PRIVATE_PROFILE"
        var rows: [(id: UUID, encoded: Data)] = []
        for index in 0...1000 {
            let profile = "\(marker)-\(index)"
            let keyBytes = try JSONEncoder().encode([audit.id.uuidString, AgentProvider.codex.rawValue, profile])
            let digest = try await crypto.revision(canonicalBytes: Data("history-progress-v1".utf8) + keyBytes).keyedDigest
            let b = Array(digest.prefix(16))
            let id = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                                 b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
            let progress = StoredHistoricalProgress(provider: .codex, profileID: profile,
                progress: HistoricalReadProgress(audit: audit, bytesRead: 1,
                    oldestContentTime: fixtureTime, newestContentTime: fixtureTime, hasUnreadContent: false))
            let payload = try await crypto.sealBackground(JSONEncoder().encode(progress),
                binding: PayloadBinding(reference: ProtectedPayloadReference(id: id), ownerID: id, kind: .sourceCheckpoint))
            rows.append((id, try payload.encoded()))
        }
        try workflowWriteProgressFixture(rows, directory: directory)
        let reopened = try await ProtectedStore.open(at: directory, cryptography: observedCrypto)
        let allWithheld = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 { group.addTask { try await reopened.pendingHistoricalNotifications().isEmpty } }
            var allEmpty = true
            for try await empty in group { allEmpty = allEmpty && empty }
            return allEmpty
        }
        #expect(allWithheld)
        #expect(await observedCrypto.checkpointOpenCount() == 0)
        #expect(await reopened.snapshot().historicalNotificationDecisions.isEmpty)
        #expect(try await reopened.snapshot().historicalSummaries().count == 1)
        #expect(try await reopened.coverageGaps().map(\.reason) == [.notificationBudgetExhausted])
        for _ in 0..<4 { #expect(try await reopened.pendingHistoricalNotifications().isEmpty) }
        #expect(await observedCrypto.checkpointOpenCount() == 1)
        try await reopened.close()
        #expect(try workflowGapCountAndRemoveProgress(directory: directory) == 1)

        let restarted = try await ProtectedStore.open(at: directory, cryptography: observedCrypto)
        #expect(try await restarted.pendingHistoricalNotifications().isEmpty)
        #expect(try await restarted.coverageGaps().map(\.reason) == [.notificationBudgetExhausted])
        try await restarted.close()
        #expect(try workflowGapCountAndRemoveProgress(rows[0].id, directory: directory) == 1)

        let atLimit = try await ProtectedStore.open(at: directory, cryptography: observedCrypto)
        #expect(try await atLimit.pendingHistoricalNotifications().count == 1)
        #expect(try await atLimit.coverageGaps().map(\.reason) == [.notificationBudgetExhausted])
        try await atLimit.close()
        #expect(try workflowGapCountAndRemoveProgress(directory: directory) == 1)
        for suffix in ["", "-wal", "-shm"] {
            let url = directory.appendingPathComponent(ProtectedStore.databaseFilename + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                let bytes = try Data(contentsOf: url)
                #expect(bytes.range(of: Data(marker.utf8)) == nil)
                #expect(bytes.range(of: Data(CoverageGapReason.notificationBudgetExhausted.rawValue.utf8)) == nil)
            }
        }
    }

    @Test func protectedPreferencesAreBoundedEncryptedAndSurviveRestart() async throws {
        let directory = workflowDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let marker = Data("SYNTHETIC_PRIVATE_AGENT_PATH_/profiles/auth".utf8)
        #expect(try await store.protectedPreference(.agentProfiles) == nil)
        try await store.setProtectedPreference(marker, for: .agentProfiles)
        #expect(try await store.protectedPreference(.agentProfiles) == marker)
        let maximum = Data(repeating: 42, count: ProtectedPreferenceKey.maximumBytes)
        try await store.setProtectedPreference(maximum, for: .agentProfiles)
        #expect(try await store.protectedPreference(.agentProfiles) == maximum)
        try await store.setProtectedPreference(marker, for: .agentProfiles)
        await #expect(throws: StorageError.stateTooLarge) {
            try await store.setProtectedPreference(Data(repeating: 1, count: ProtectedPreferenceKey.maximumBytes + 1), for: .agentProfiles)
        }
        try await store.close()
        let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])).allObjects as? [URL] ?? []
        for file in files {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let bytes = try Data(contentsOf: file)
                #expect(bytes.range(of: marker) == nil)
                #expect(bytes.range(of: Data(marker.base64EncodedString().utf8)) == nil)
            }
        }
        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        #expect(try await reopened.protectedPreference(.agentProfiles) == marker)
        try await reopened.close()
    }

    @Test func historicalNotificationWaitsForCompleteProgressAndItsReceiptSurvivesRestart() async throws {
        let directory = workflowDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixtureTime)
        try await workflowCommit(analysis(provenance: .historical(audit)), store: store, crypto: crypto)
        #expect(try await store.pendingNotifications().isEmpty)
        try await workflowProgress(store, audit: audit, unread: true)
        #expect(try await store.pendingNotifications().isEmpty)
        try await workflowProgress(store, audit: audit, unread: false, provider: .claudeCode, profile: "other-profile")
        #expect(try await store.pendingNotifications().isEmpty)
        try await workflowProgress(store, audit: audit, unread: false)
        let message = try #require(try await store.pendingNotifications().first)
        #expect(message.identifier == "leakret-audit-\(audit.id.uuidString.lowercased())")
        #expect(try await store.notificationIsEligible(message))
        try await store.recordNotificationDelivery(identifier: message.identifier, state: .permissionDenied)
        #expect(try await store.pendingNotifications().isEmpty)
        #expect(try await store.notificationCanRemain(message))
        #expect(await store.notificationTargetExists(message.target))
        try await store.close()
        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        #expect(try await reopened.pendingNotifications().isEmpty)
        #expect(await reopened.snapshot().historicalNotificationDecisions[audit.id]?.delivery == .permissionDenied)
        try await reopened.close()
    }

    @Test func deletionRevisesPendingSummaryAndRejectsAnAlreadyCopiedPresentation() async throws {
        let directory = workflowDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixtureTime)
        try await workflowCommit(analysis(item: "first", provenance: .historical(audit)), store: store, crypto: crypto)
        try await workflowCommit(analysis(item: "second", fingerprintByte: 2, provenance: .historical(audit)), store: store, crypto: crypto)
        try await workflowProgress(store, audit: audit, unread: false)
        let copied = try #require(try await store.pendingNotifications().first)
        _ = try await store.removeContent(for: fingerprint())
        let refreshed = try #require(try await store.pendingNotifications().first)
        #expect(copied.identifier == refreshed.identifier && copied != refreshed)
        #expect(!(try await store.notificationIsEligible(copied)))
        #expect(!(try await store.notificationCanRemain(copied)))
        #expect(try await store.notificationCanRemain(identifier: copied.identifier))
        try await store.acknowledgeObsolete(fingerprint(2), as: .rotated, at: fixtureTime)
        #expect(try await store.pendingNotifications().isEmpty)
        #expect(!(try await store.notificationCanRemain(identifier: copied.identifier)))
        #expect(await store.snapshot().historicalNotificationDecisions[audit.id]?.delivery == .cancelled)
        try await store.close()
    }

    @Test func queueAdmissionWhileSummaryIsSealingPreventsPrematureSettlement() async throws {
        let directory = workflowDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let blocker = WorkflowBlockingCryptography(crypto)
        let store = try await ProtectedStore.open(at: directory, cryptography: blocker)
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixtureTime)
        try await workflowCommit(analysis(provenance: .historical(audit)), store: store, crypto: crypto)
        try await workflowProgress(store, audit: audit, unread: false)
        await blocker.blockNextLedger()
        let settlement = Task { try await store.pendingNotifications() }
        try await workflowWait(blocker)
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(Data("NEW_SYNTHETIC_CAPTURE".utf8), capturedAt: Date(), permit: permit)
        await blocker.release()
        await #expect(throws: StorageError.stateChanged) { try await settlement.value }
        #expect(await store.snapshot().historicalNotificationDecisions.isEmpty)
        #expect(try await store.queueStatistics().count == 1)
        try await store.close()
    }

    @Test func pauseDuringDeliveryReceiptSealingLeavesTheDecisionPending() async throws {
        let directory = workflowDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let blocker = WorkflowBlockingCryptography(crypto)
        let store = try await ProtectedStore.open(at: directory, cryptography: blocker)
        try await workflowCommit(analysis(), store: store, crypto: crypto)
        let message = try #require(try await store.pendingNotifications().first)
        await blocker.blockNextLedger()
        let receipt = Task { try await store.recordNotificationDelivery(identifier: message.identifier, state: .delivered) }
        try await workflowWait(blocker)
        await store.setMonitoring(enabled: false)
        await blocker.release()
        await #expect(throws: StorageError.monitoringPaused) { try await receipt.value }
        #expect(try await store.pendingNotifications().isEmpty)
        #expect(await store.snapshot().alertDecisions.values.first?.delivery == .pending)
        await store.setMonitoring(enabled: true)
        #expect(try await store.notificationIsEligible(message))
        try await store.recordNotificationDelivery(identifier: message.identifier, state: .delivered)
        #expect(try await store.pendingNotifications().isEmpty)
        #expect(try await store.notificationCanRemain(message))
        try await store.close()
    }
}
