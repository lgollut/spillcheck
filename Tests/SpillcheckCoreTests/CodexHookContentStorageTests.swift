import Foundation
import GRDB
import Testing
@_spi(Testing) @testable import SpillcheckCore

private let hookStorageTime = Date(timeIntervalSince1970: 1_791_727_200)
private let hookStorageMarker = "SPILLCHECK_FAKE_HOOK_STORAGE_PRIVATE"

private func hookStoreDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-hook-slots-\(UUID())", isDirectory: true)
}

private func hookStoreSource(session: String = "session", turn: String = "turn",
                             profile: String = "profile") throws -> SourceIdentity {
    try SourceIdentity(session: SessionIdentity(provider: .codex, profileID: profile, sessionID: session),
        itemID: "codex-hook-v1:" + JSONEncoder().encode([turn, "UserPromptSubmit"]).base64EncodedString())
}

private func hookStoreRevision(_ value: UInt8) throws -> ContentRevision {
    try ContentRevision(keyedDigest: Data(repeating: value, count: 32))
}

private func authorizeHookSource(_ source: SourceIdentity, in store: ProtectedStore,
                                 authority: String = "codex-hook-content-v1") async throws -> StoreProcessingPermit {
    let permit = try #require(await store.processingPermit())
    try await store.selectAuthority(CollectionAuthorityChoice(session: source.session,
        adapterVersion: "1", authorityID: authority), permit: permit)
    return permit
}

private func hookSlotRows(_ directory: URL) throws -> [(String, Data)] {
    let db = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path)
    defer { try? db.close() }
    return try db.read { try Row.fetchAll($0, sql: "SELECT id, encoded FROM codex_hook_content_slots ORDER BY id")
        .map { ($0["id"], $0["encoded"]) } }
}

private actor HookSlotBlockingCryptography: BackgroundStoreCryptography {
    nonisolated let manifest: ProtectionManifest
    private let delegate: BackgroundCryptography
    private var shouldBlockSeal = false
    private var blocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(_ delegate: BackgroundCryptography) { self.delegate = delegate; manifest = delegate.manifest }
    func blockNextSeal() { shouldBlockSeal = true; blocked = false }
    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
    func sealBackground(_ plaintext: Data, binding: PayloadBinding) async throws -> ProtectedPayload {
        if shouldBlockSeal && binding.kind == .sourceCheckpoint {
            shouldBlockSeal = false
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation; blocked = true
                for waiter in waiters { waiter.resume() }
                waiters.removeAll()
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

@Suite("Immutable encrypted Codex hook bindings")
struct CodexHookContentStorageTests {
    @Test func replayAndRestartPreserveFirstObservationAndRejectChangedContent() async throws {
        let directory = hookStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let source = try hookStoreSource(), first = try hookStoreRevision(1), other = try hookStoreRevision(2)
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let permit = try await authorizeHookSource(source, in: store)
        #expect(try await store.bindCodexHookContent(source: source, revision: first, observedAt: hookStorageTime,
            permit: permit) == .accepted(firstObservedAt: hookStorageTime))
        let original = try hookSlotRows(directory)
        #expect(try await store.bindCodexHookContent(source: source, revision: first,
            observedAt: hookStorageTime.addingTimeInterval(20), permit: permit) == .accepted(firstObservedAt: hookStorageTime))
        #expect(try await store.bindCodexHookContent(source: source, revision: other,
            observedAt: hookStorageTime.addingTimeInterval(30), permit: permit) == .conflict)
        try await store.close()
        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let nextPermit = try #require(await reopened.processingPermit())
        #expect(try await reopened.bindCodexHookContent(source: source, revision: first,
            observedAt: hookStorageTime.addingTimeInterval(-20), permit: nextPermit) == .accepted(firstObservedAt: hookStorageTime))
        #expect(try await reopened.bindCodexHookContent(source: source, revision: other,
            observedAt: hookStorageTime, permit: nextPermit) == .conflict)
        let after = try hookSlotRows(directory)
        #expect(after.count == 1 && original.first?.0 == after.first?.0 && original.first?.1 == after.first?.1)
        try await reopened.close()
    }

    @Test func legacyPrintedJSONErrorSlotIsNotSilentlyReclassifiedOnReplay() async throws {
        let directory = hookStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let session = try SessionIdentity(provider: .codex, profileID: "profile", sessionID: "session")
        let source = try SourceIdentity(session: session,
            itemID: CodexHookContentAdapter.itemPrefix
                + JSONEncoder().encode(["turn", "PostToolUse", "call"]).base64EncodedString())
        let printed = "{\"exit_code\":7,\"text\":\"" + hookStorageMarker + "\"}"
        // Reproduce the v2 revision of raw stdout misclassified as toolError.
        // The persisted slot must remain immutable when the new parser sees it.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var oldCanonical = Data("codex-hook-tool-content-v1".utf8)
        for bytes in [Data("Bash".utf8), Data(ContentType.toolError.rawValue.utf8),
            try encoder.encode(CodexJSON.string(printed)), Data("/tool_response".utf8), Data(printed.utf8)] {
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { oldCanonical.append(contentsOf: $0) }
            oldCanonical.append(bytes)
        }
        let oldRevision = try await crypto.revision(canonicalBytes: oldCanonical)
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let permit = try await authorizeHookSource(source, in: store)
        #expect(try await store.bindCodexHookContent(source: source, revision: oldRevision,
            observedAt: hookStorageTime, permit: permit) == .accepted(firstObservedAt: hookStorageTime))
        let originalRows = try hookSlotRows(directory)
        try await store.close()

        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let nextPermit = try #require(await reopened.processingPermit())
        let adapter = try CodexHookContentAdapter(profileID: "profile", interface: .desktopCode,
            authorityLookup: { try await reopened.authority(for: $0) },
            bind: { try await reopened.bindCodexHookContent(source: $0, revision: $1,
                observedAt: $2, permit: nextPermit) })
        let packet = try CapturePacket(metadata: .init(agent: .codex, interface: .desktopCode, profileID: "profile"),
            eventJSON: JSONSerialization.data(withJSONObject: ["hook_event_name": "PostToolUse",
                "session_id": "session", "turn_id": "turn", "tool_use_id": "call", "tool_name": "Bash",
                "tool_response": printed]))
        for offset in [600.0, 1200.0] {
            let replay = try await adapter.normalize(packet, capturedAt: hookStorageTime.addingTimeInterval(offset),
                cryptography: crypto)
            #expect(replay.sources.isEmpty && !replay.observedRead)
            let gap = try #require(replay.coverageGaps.first)
            #expect(replay.coverageGaps.count == 1 && gap.reason == .sourceChanged)
            #expect(gap.diagnosticCode == .hookIdentityConflict && gap.requiresAnalysis)
            #expect(gap.contentType == .toolOutput)
            #expect(gap.recovery?.parserContract == "codex-hook-observed-slots-v3")
            #expect(gap.recovery?.session == session && gap.recovery?.itemID == source.itemID)
        }
        #expect(try await reopened.bindCodexHookContent(source: source, revision: oldRevision,
            observedAt: hookStorageTime.addingTimeInterval(1800), permit: nextPermit)
                == .accepted(firstObservedAt: hookStorageTime))
        let afterRows = try hookSlotRows(directory)
        #expect(afterRows.count == 1 && afterRows.first?.0 == originalRows.first?.0
            && afterRows.first?.1 == originalRows.first?.1)
        try await reopened.close()
    }

    @Test func onlyAnExplicitHookAuthorityAndNamespacedCodexIdentityCanBind() async throws {
        let directory = hookStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
        let permit = try #require(await store.processingPermit()), revision = try hookStoreRevision(1)
        let missing = try hookStoreSource(session: "unselected")
        await #expect(throws: StorageError.invalidPayload) {
            try await store.bindCodexHookContent(source: missing, revision: revision, observedAt: hookStorageTime, permit: permit)
        }
        #expect(try await store.authority(for: missing.session) == nil)
        let native = try hookStoreSource(session: "public-native")
        _ = try await authorizeHookSource(native, in: store, authority: "codex-public-native-v1")
        await #expect(throws: StorageError.invalidPayload) {
            try await store.bindCodexHookContent(source: native, revision: revision, observedAt: hookStorageTime, permit: permit)
        }
        let valid = try hookStoreSource(session: "hook-authorized")
        _ = try await authorizeHookSource(valid, in: store)
        let unnamespaced = try SourceIdentity(session: valid.session, itemID: "native-item")
        let claude = try SourceIdentity(session: SessionIdentity(provider: .claudeCode, profileID: "profile", sessionID: "other"),
            itemID: valid.itemID)
        for source in [unnamespaced, claude, try hookStoreSource(profile: String(repeating: "x", count: 257)),
                       try hookStoreSource(session: "nul\0session")] {
            await #expect(throws: StorageError.invalidPayload) {
                try await store.bindCodexHookContent(source: source, revision: revision, observedAt: hookStorageTime, permit: permit)
            }
        }
        await #expect(throws: StorageError.invalidTime) {
            try await store.bindCodexHookContent(source: valid, revision: revision,
                observedAt: Date(timeIntervalSince1970: .infinity), permit: permit)
        }
        #expect(try hookSlotRows(directory).isEmpty)
        try await store.close()
    }

    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
    func concurrentFirstWritersKeepOnlyTheCommittedWinner(_ scenario: (Bool, Bool)) async throws {
        let (conflicting, separateStore) = scenario
        let directory = hookStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting(), blocking = HookSlotBlockingCryptography(crypto)
        let store = try await ProtectedStore.open(at: directory, cryptography: blocking)
        let source = try hookStoreSource(), first = try hookStoreRevision(1)
        let second = try hookStoreRevision(conflicting ? 2 : 1)
        let permit = try await authorizeHookSource(source, in: store)
        let independent = separateStore ? try await ProtectedStore.open(at: directory, cryptography: crypto) : store
        let independentPermit = try #require(await independent.processingPermit())
        await blocking.blockNextSeal()
        let waiting = Task { try await store.bindCodexHookContent(source: source, revision: first,
            observedAt: hookStorageTime, permit: permit) }
        await blocking.waitUntilBlocked()
        let winnerTime = hookStorageTime.addingTimeInterval(1)
        #expect(try await independent.bindCodexHookContent(source: source, revision: second,
            observedAt: winnerTime, permit: independentPermit) == .accepted(firstObservedAt: winnerTime))
        await blocking.release()
        #expect(try await waiting.value == (conflicting ? .conflict : .accepted(firstObservedAt: winnerTime)))
        #expect(try hookSlotRows(directory).count == 1)
        if separateStore { try await independent.close() }
        try await store.close()
    }

    @Test(arguments: [StorageFailpoint.beforeProcessingCommit, .afterProcessingCommit])
    func transactionFailureAndLostAcknowledgementRecoverAtTheCommitBoundary(_ failpoint: StorageFailpoint) async throws {
        let directory = hookStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto,
            failureInjector: { if $0 == failpoint { throw StorageError.injectedFailure } })
        let source = try hookStoreSource(), revision = try hookStoreRevision(1)
        let permit = try await authorizeHookSource(source, in: store)
        await #expect(throws: StorageError.injectedFailure) {
            try await store.bindCodexHookContent(source: source, revision: revision, observedAt: hookStorageTime, permit: permit)
        }
        #expect(try hookSlotRows(directory).count == (failpoint == .afterProcessingCommit ? 1 : 0))
        try await store.close()
        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let nextPermit = try #require(await reopened.processingPermit())
        let retryTime = hookStorageTime.addingTimeInterval(50)
        let expected = failpoint == .afterProcessingCommit ? hookStorageTime : retryTime
        #expect(try await reopened.bindCodexHookContent(source: source, revision: revision, observedAt: retryTime,
            permit: nextPermit) == .accepted(firstObservedAt: expected))
        try await reopened.close()
    }

    @Test func pauseDuringEncryptionRejectsTheOldPermitWithoutLeavingASlot() async throws {
        let directory = hookStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting(), blocking = HookSlotBlockingCryptography(crypto)
        let store = try await ProtectedStore.open(at: directory, cryptography: blocking)
        let source = try hookStoreSource(), revision = try hookStoreRevision(1)
        let permit = try await authorizeHookSource(source, in: store)
        await blocking.blockNextSeal()
        let waiting = Task { try await store.bindCodexHookContent(source: source, revision: revision,
            observedAt: hookStorageTime, permit: permit) }
        await blocking.waitUntilBlocked()
        await store.setMonitoring(enabled: false)
        await blocking.release()
        await #expect(throws: StorageError.monitoringPaused) { try await waiting.value }
        #expect(try hookSlotRows(directory).isEmpty)
        await store.setMonitoring(enabled: true)
        await #expect(throws: StorageError.staleProcessingPermit) {
            try await store.bindCodexHookContent(source: source, revision: revision, observedAt: hookStorageTime, permit: permit)
        }
        let nextPermit = try #require(await store.processingPermit())
        #expect(try await store.bindCodexHookContent(source: source, revision: revision, observedAt: hookStorageTime,
            permit: nextPermit) == .accepted(firstObservedAt: hookStorageTime))
        try await store.close()
    }

    @Test func countLimitIsGlobalAndExpiryNeverTurnsAnOldSlotIntoNewContent() async throws {
        let directory = hookStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting(),
            limits: StoreLimits(maxHookContentSlots: 1))
        let first = try hookStoreSource(), other = try hookStoreSource(session: "different", profile: "other-profile")
        let permit = try await authorizeHookSource(first, in: store)
        _ = try await authorizeHookSource(other, in: store)
        _ = try await store.bindCodexHookContent(source: first, revision: hookStoreRevision(1),
            observedAt: hookStorageTime, permit: permit)
        _ = try await store.maintainQueue(at: hookStorageTime.addingTimeInterval(31 * 24 * 3600))
        #expect(try await store.bindCodexHookContent(source: first, revision: hookStoreRevision(1),
            observedAt: hookStorageTime.addingTimeInterval(31 * 24 * 3600), permit: permit) == .accepted(firstObservedAt: hookStorageTime))
        #expect(try await store.bindCodexHookContent(source: first, revision: hookStoreRevision(2),
            observedAt: hookStorageTime, permit: permit) == .conflict)
        await #expect(throws: StorageError.capacityExceeded(.codexHookContentSlots)) {
            try await store.bindCodexHookContent(source: other, revision: hookStoreRevision(1),
                observedAt: hookStorageTime, permit: permit)
        }
        #expect(try hookSlotRows(directory).count == 1)
        try await store.close()
    }

    @Test func closeDuringEncryptionCannotCreateALateBinding() async throws {
        let directory = hookStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting(), blocking = HookSlotBlockingCryptography(crypto)
        let store = try await ProtectedStore.open(at: directory, cryptography: blocking)
        let source = try hookStoreSource(), revision = try hookStoreRevision(1)
        let permit = try await authorizeHookSource(source, in: store)
        await blocking.blockNextSeal()
        let waiting = Task { try await store.bindCodexHookContent(source: source, revision: revision,
            observedAt: hookStorageTime, permit: permit) }
        await blocking.waitUntilBlocked()
        try await store.close()
        await blocking.release()
        await #expect(throws: StorageError.databaseUnavailable) { try await waiting.value }
        #expect(try hookSlotRows(directory).isEmpty)
    }

    @Test func protectedByteLimitRollsBackANewSlotWithoutBlockingReplay() async throws {
        let directory = hookStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        // The sealed ledger alone needs about 4 KB under the limit, so the session is padded to make a slot larger.
        let session = String(repeating: "s", count: 3500)
        let source = try hookStoreSource(session: session), other = try hookStoreSource(session: session, turn: "other-turn")
        let permit = try await authorizeHookSource(source, in: store)
        _ = try await store.bindCodexHookContent(source: source, revision: hookStoreRevision(1), observedAt: hookStorageTime, permit: permit)
        let retainedBytes = try #require(hookSlotRows(directory).first?.1.count)
        try await store.close()
        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto,
            limits: StoreLimits(maxProtectedStateBytes: retainedBytes + 128))
        let nextPermit = try #require(await reopened.processingPermit())
        await #expect(throws: StorageError.capacityExceeded(.codexHookContentSlots)) {
            try await reopened.bindCodexHookContent(source: other, revision: hookStoreRevision(2),
                observedAt: hookStorageTime, permit: nextPermit)
        }
        #expect(try await reopened.bindCodexHookContent(source: source, revision: hookStoreRevision(1),
            observedAt: hookStorageTime.addingTimeInterval(1), permit: nextPermit) == .accepted(firstObservedAt: hookStorageTime))
        #expect(try hookSlotRows(directory).count == 1)
        try await reopened.close()
    }

    @Test func identitiesDigestsAndObservationTimesAreEncryptedAndSourcesStayDistinct() async throws {
        let directory = hookStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let first = try hookStoreSource(session: hookStorageMarker, profile: hookStorageMarker)
        let second = try hookStoreSource(session: hookStorageMarker, turn: "other", profile: hookStorageMarker)
        let revision = try await crypto.revision(canonicalBytes: Data(hookStorageMarker.utf8))
        let permit = try await authorizeHookSource(first, in: store)
        _ = try await store.bindCodexHookContent(source: first, revision: revision, observedAt: hookStorageTime, permit: permit)
        _ = try await store.bindCodexHookContent(source: second, revision: revision, observedAt: hookStorageTime, permit: permit)
        let rows = try hookSlotRows(directory)
        #expect(rows.count == 2 && Set(rows.map(\.0)).count == 2)
        for row in rows {
            let id = try #require(UUID(uuidString: row.0))
            let payload = try ProtectedPayload.decode(row.1)
            let plaintext = try await crypto.openBackground(payload, binding: PayloadBinding(
                reference: ProtectedPayloadReference(id: id), ownerID: id, kind: .sourceCheckpoint))
            let decoded = try JSONDecoder().decode(StoredCodexHookContent.self, from: plaintext)
            #expect([first, second].contains(decoded.source) && decoded.revision == revision)
        }
        try await store.close()
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: file)
            for marker in [Data(hookStorageMarker.utf8), Data(first.itemID.utf8), revision.keyedDigest,
                           Data(revision.keyedDigest.base64EncodedString().utf8)] {
                #expect(bytes.range(of: marker) == nil)
            }
        }
    }

    @Test func v6MigrationPreservesAuthorityAndOrphanedSlotPreventsEmptyBootstrap() async throws {
        let directory = hookStoreDirectory(), orphaned = hookStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: orphaned) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let source = try hookStoreSource()
        _ = try await authorizeHookSource(source, in: store)
        try await store.close()
        let db = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path)
        try await db.write {
            try $0.execute(sql: "DROP TABLE codex_hook_content_slots")
            try $0.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v7-codex-hook-content-slots'")
        }
        try db.close()
        let migrated = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let permit = try #require(await migrated.processingPermit())
        #expect(try await migrated.authority(for: source.session)?.authorityID == "codex-hook-content-v1")
        _ = try await migrated.bindCodexHookContent(source: source, revision: hookStoreRevision(1), observedAt: hookStorageTime, permit: permit)
        try await migrated.close()
        try FileManager.default.createDirectory(at: orphaned, withIntermediateDirectories: true)
        let orphanDB = try DatabaseQueue(path: orphaned.appendingPathComponent(ProtectedStore.databaseFilename).path)
        try await orphanDB.write {
            try $0.execute(sql: "CREATE TABLE codex_hook_content_slots (id TEXT PRIMARY KEY NOT NULL, encoded BLOB NOT NULL)")
            try $0.execute(sql: "INSERT INTO codex_hook_content_slots (id, encoded) VALUES (?, ?)", arguments: [UUID().uuidString, Data([1])])
        }
        try orphanDB.close()
        #expect(try ProtectedStore.probe(at: orphaned).state == .protectedDataPresent)
        await #expect(throws: StorageError.manifestMissing) {
            try await ProtectedStore.open(at: orphaned, cryptography: crypto)
        }
    }

    @Test func movingCiphertextToAnotherSlotFailsBindingValidation() async throws {
        let directory = hookStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let first = try hookStoreSource(), second = try hookStoreSource(turn: "second")
        let permit = try await authorizeHookSource(first, in: store)
        for source in [first, second] {
            _ = try await store.bindCodexHookContent(source: source, revision: hookStoreRevision(1),
                observedAt: hookStorageTime, permit: permit)
        }
        let rows = try hookSlotRows(directory)
        #expect(rows.count == 2)
        try await store.close()
        let db = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path)
        try await db.write {
            try $0.execute(sql: "UPDATE codex_hook_content_slots SET encoded = ? WHERE id = ?", arguments: [rows[1].1, rows[0].0])
            try $0.execute(sql: "UPDATE codex_hook_content_slots SET encoded = ? WHERE id = ?", arguments: [rows[0].1, rows[1].0])
        }
        try db.close()
        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let nextPermit = try #require(await reopened.processingPermit())
        for source in [first, second] {
            await #expect(throws: ProtectionError.invalidEnvelope) {
                try await reopened.bindCodexHookContent(source: source, revision: hookStoreRevision(1),
                    observedAt: hookStorageTime, permit: nextPermit)
            }
        }
        try await reopened.close()
    }
}
