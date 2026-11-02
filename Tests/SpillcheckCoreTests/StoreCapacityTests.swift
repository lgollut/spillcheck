import Foundation
import GRDB
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor CapacityCryptoSpy: BackgroundStoreCryptography {
    nonisolated let manifest: ProtectionManifest
    private let delegate: BackgroundCryptography
    private(set) var opens = 0
    init(_ delegate: BackgroundCryptography) { self.delegate = delegate; manifest = delegate.manifest }
    func sealBackground(_ plaintext: Data, binding: PayloadBinding) async throws -> ProtectedPayload {
        try await delegate.sealBackground(plaintext, binding: binding)
    }
    func openBackground(_ payload: ProtectedPayload, binding: PayloadBinding) async throws -> Data {
        opens += 1
        return try await delegate.openBackground(payload, binding: binding)
    }
    func revision(canonicalBytes: Data) async throws -> ContentRevision {
        try await delegate.revision(canonicalBytes: canonicalBytes)
    }
}

private let capacityMarker = "SPILLCHECK_FAKE_CAPACITY_PRIVATE"
private let capacityDate = Date(timeIntervalSince1970: 1_791_727_200)
/// The sealed ledger alone needs about 4 KB under a byte limit. Tests that lower the limit to the size
/// of an authority or slot row therefore pad the session until those rows are larger than the ledger.
private let capacityPadding = String(repeating: "p", count: 3500)
private func capacitySource(_ suffix: String = "first", session: String = capacityMarker) throws -> SourceIdentity {
    try .init(session: .init(provider: .codex, profileID: capacityMarker, sessionID: session),
        itemID: "codex-hook-v1:\(capacityMarker)-\(suffix)")
}
private func capacityChoice(_ source: SourceIdentity) throws -> CollectionAuthorityChoice {
    try .init(session: source.session, adapterVersion: "1", authorityID: CodexHookContentAdapter.authorityID)
}
private func capacityDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-capacity-\(UUID())")
}
private func capacityRevision() throws -> ContentRevision { try .init(keyedDigest: Data(repeating: 47, count: 32)) }

@Suite("Lifetime collection identity capacity")
struct StoreCapacityTests {
    @Test func thresholdsUseBothLimitsAndAreExactWithoutOverflow() {
        func usage(_ count: Int, _ bytes: Int = 0, countLimit: Int = 100, bytesLimit: Int = 100) -> StoreCapacityUsage {
            .init(count: count, encryptedBytes: bytes, countLimit: countLimit, encryptedBytesLimit: bytesLimit)
        }
        #expect(usage(79, 79).state == .available)
        #expect(usage(80).countState == .nearCapacity)
        #expect(usage(0, 80).bytesState == .nearCapacity)
        #expect(usage(0, 80).state == .nearCapacity)
        #expect(usage(100).state == .full)
        #expect(usage(0, 101).state == .overLimit)
        #expect(usage(100, 101).state == .overLimit)
        #expect(usage(101).remainingCount == 0)
        #expect(usage(0, 101).remainingEncryptedBytes == 0)
        #expect(usage(80, 95).remainingCount == 20)
        #expect(usage(80, 95).remainingEncryptedBytes == 5)
        #expect(usage(4, countLimit: 6).state == .available)
        #expect(usage(5, countLimit: 6).state == .nearCapacity)
        #expect(usage(0, countLimit: 0).state == .full)
        #expect(usage(1, countLimit: 0).state == .overLimit)
        #expect(usage(Int.max - Int.max / 5 - 1, countLimit: Int.max).state == .available)
        #expect(usage(Int.max - Int.max / 5, countLimit: Int.max).state == .nearCapacity)
    }

    @Test func metadataSnapshotIsExactPrivateAndRequiresNoDecryption() async throws {
        let directory = capacityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = CapacityCryptoSpy(try BackgroundCryptography.ephemeralForTesting())
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto,
            limits: .init(maxHookContentSlots: 5, maxSourceAuthorities: 5))
        let empty = try await store.capacitySnapshot()
        #expect(empty.sourceAuthorities.count == 0 && empty.sourceAuthorities.encryptedBytes == 0)
        #expect(empty.codexHookContentSlots.count == 0 && empty.codexHookContentSlots.encryptedBytes == 0)
        let permit = try #require(await store.processingPermit()), source = try capacitySource()
        try await store.selectAuthority(capacityChoice(source), permit: permit)
        for index in 0..<4 {
            _ = try await store.bindCodexHookContent(source: capacitySource(String(index)), revision: capacityRevision(),
                observedAt: capacityDate, permit: permit)
        }
        let before = await crypto.opens
        let snapshot = try await store.capacitySnapshot()
        #expect(await crypto.opens == before)
        #expect(snapshot.sourceAuthorities.count == 1 && snapshot.sourceAuthorities.remainingCount == 4)
        #expect(snapshot.codexHookContentSlots.count == 4 && snapshot.codexHookContentSlots.state == .nearCapacity)
        let db = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path)
        let bytes = try await db.read { db in
            (try Int.fetchOne(db, sql: "SELECT SUM(length(encoded)) FROM collection_authorities"),
             try Int.fetchOne(db, sql: "SELECT SUM(length(encoded)) FROM codex_hook_content_slots"))
        }
        try db.close()
        #expect(snapshot.sourceAuthorities.encryptedBytes == bytes.0)
        #expect(snapshot.codexHookContentSlots.encryptedBytes == bytes.1)
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(encoded.range(of: Data(capacityMarker.utf8)) == nil)
        #expect(encoded.range(of: Data("codex-hook-v1:".utf8)) == nil)
        #expect(encoded.range(of: Data(try capacityRevision().keyedDigest.base64EncodedString().utf8)) == nil)
        #expect(try JSONDecoder().decode(StoreCapacitySnapshot.self, from: encoded) == snapshot)
        let report = try await store.coverageReport(endingAt: capacityDate)
        #expect(report.capacity == snapshot)
        #expect(report.gapEvents.totalCount == 0 && report.omissions.totalCount == 0)
        try await store.close()
        await #expect(throws: StorageError.databaseUnavailable) { try await store.capacitySnapshot() }
    }

    @Test func loweredByteAndCountQuotasKeepBindingsAndReplayIntact() async throws {
        let directory = capacityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let padded = capacityMarker + capacityPadding
        let permit = try #require(await store.processingPermit()), source = try capacitySource(session: padded)
        try await store.selectAuthority(capacityChoice(source), permit: permit)
        _ = try await store.bindCodexHookContent(source: source, revision: capacityRevision(),
            observedAt: capacityDate, permit: permit)
        let original = try await store.capacitySnapshot()
        let other = try SourceIdentity(session: .init(provider: .codex, profileID: capacityMarker,
            sessionID: padded + "-second"), itemID: source.itemID)
        try await store.selectAuthority(capacityChoice(other), permit: permit)
        _ = try await store.bindCodexHookContent(source: other, revision: capacityRevision(),
            observedAt: capacityDate, permit: permit)
        try await store.close()
        // The sealed ledger is smaller than the padded source authority/slot envelopes.
        let byteLimit = min(original.sourceAuthorities.encryptedBytes, original.codexHookContentSlots.encryptedBytes) - 1
        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto,
            limits: .init(maxProtectedStateBytes: byteLimit, maxHookContentSlots: 1, maxSourceAuthorities: 1))
        let nextPermit = try #require(await reopened.processingPermit())
        let capacity = try await reopened.capacitySnapshot()
        #expect(capacity.sourceAuthorities.countState == .overLimit)
        #expect(capacity.sourceAuthorities.bytesState == .overLimit)
        #expect(capacity.codexHookContentSlots.countState == .overLimit)
        #expect(capacity.codexHookContentSlots.bytesState == .overLimit)
        #expect(capacity.sourceAuthorities.remainingCount == 0 && capacity.sourceAuthorities.remainingEncryptedBytes == 0)
        try await reopened.selectAuthority(capacityChoice(source), permit: nextPermit)
        #expect(try await reopened.bindCodexHookContent(source: source, revision: capacityRevision(),
            observedAt: capacityDate.addingTimeInterval(3600), permit: nextPermit) == .accepted(firstObservedAt: capacityDate))
        #expect(try await reopened.bindCodexHookContent(source: source,
            revision: ContentRevision(keyedDigest: Data(repeating: 48, count: 32)),
            observedAt: capacityDate, permit: nextPermit) == .conflict)
        await #expect(throws: StorageError.capacityExceeded(.codexHookContentSlots)) {
            try await reopened.bindCodexHookContent(source: capacitySource("new", session: padded), revision: capacityRevision(),
                observedAt: capacityDate, permit: nextPermit)
        }
        let newSession = try SessionIdentity(provider: .claudeCode, profileID: "other", sessionID: "new")
        await #expect(throws: StorageError.capacityExceeded(.sourceAuthorities)) {
            try await reopened.selectAuthority(.init(session: newSession, adapterVersion: "1", authorityID: "other"), permit: nextPermit)
        }
        #expect(try await reopened.capacitySnapshot() == capacity)
        #expect(try await reopened.authority(for: newSession) == nil)
        try await reopened.close()
    }

    @Test func encryptedByteThresholdAndExactFullRemainVisibleAcrossRestart() async throws {
        let directory = capacityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let padded = capacityMarker + capacityPadding
        let permit = try #require(await store.processingPermit()), source = try capacitySource(session: padded)
        try await store.selectAuthority(capacityChoice(source), permit: permit)
        _ = try await store.bindCodexHookContent(source: source, revision: capacityRevision(),
            observedAt: capacityDate, permit: permit)
        let usedBytes = try await store.capacitySnapshot().codexHookContentSlots.encryptedBytes
        try await store.close()
        for (limit, expected) in [(usedBytes * 5 / 4, StoreCapacityState.nearCapacity), (usedBytes, .full)] {
            let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto,
                limits: .init(maxProtectedStateBytes: limit))
            let snapshot = try await reopened.capacitySnapshot()
            #expect(snapshot.codexHookContentSlots.bytesState == expected)
            #expect(snapshot.codexHookContentSlots.state == expected)
            #expect(snapshot.codexHookContentSlots.remainingEncryptedBytes == limit - usedBytes)
            let nextPermit = try #require(await reopened.processingPermit())
            await #expect(throws: StorageError.capacityExceeded(.codexHookContentSlots)) {
                try await reopened.bindCodexHookContent(source: capacitySource("new", session: padded), revision: capacityRevision(),
                    observedAt: capacityDate, permit: nextPermit)
            }
            #expect(try await reopened.capacitySnapshot() == snapshot)
            try await reopened.close()
        }
    }
}
