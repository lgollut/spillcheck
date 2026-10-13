import Darwin
import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private enum BootstrapFixtureError: Error { case create, cleanup, unavailable }

@MainActor
private final class BootstrapFixture {
    let directory: URL
    let configuration = ProtectionConfiguration(accessGroup: "synthetic.bootstrap.group",
                                                 identifierPrefix: "com.spillcheck.test.bootstrap")
    var probe = StoreProtectionProbe(state: .empty, manifest: nil)
    var effects: [String] = []
    var items: Set<KeyComponent> = []

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-bootstrap-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    func discard() { try? FileManager.default.removeItem(at: directory) }
    var recordURL: URL { directory.appendingPathComponent(".protection-bootstrap.json") }
    var lockURL: URL { directory.appendingPathComponent(".protection-bootstrap.lock") }

    func begin() throws -> ProtectionBootstrapAttempt {
        try ProtectionBootstrapAttempt(at: directory, manifest: probe.manifest, storeState: probe.state,
                                       configuration: configuration, probe: { probe })
    }

    func record() throws -> ProtectionBootstrapRecord {
        try JSONDecoder().decode(ProtectionBootstrapRecord.self, from: Data(contentsOf: recordURL))
    }

    func create(_ component: KeyComponent, in attempt: ProtectionBootstrapAttempt) async throws {
        try await attempt.create(component, existing: { [self] in
            guard items.contains(component) else { return nil }
            effects.append("reuse-" + component.rawValue)
            return ()
        }) {
            let persisted = try record()
            #expect(persisted.manifest == attempt.manifest)
            #expect(persisted.attempted.contains(component))
            effects.append("create-" + component.rawValue)
            items.insert(component)
        }
    }

    func rollback(_ attempt: ProtectionBootstrapAttempt, failing: KeyComponent? = nil,
                  cause: KeyUnavailable? = nil) async throws {
        try await attempt.rollback(cause: cause, remove: { component in
            effects.append("remove-" + component.rawValue)
            if component == failing { throw BootstrapFixtureError.cleanup }
            items.remove(component)
        }, verifyAbsent: { component in
            effects.append("verify-" + component.rawValue)
            if items.contains(component) { throw BootstrapFixtureError.unavailable }
        })
    }
}

@Suite("Durable protection bootstrap")
struct ProtectionBootstrapTests {
    @Test @MainActor func intentIsPrivateAndDurableBeforeEveryCreate() async throws {
        let fixture = try BootstrapFixture()
        defer { fixture.discard() }
        let attempt = try fixture.begin()
        let initial = try fixture.record()
        #expect(initial.manifest == attempt.manifest)
        #expect(initial.phase == .prepared)
        for url in [fixture.recordURL, fixture.lockURL] {
            var info = stat()
            #expect(lstat(url.path, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o600)
            #expect(info.st_nlink == 1)
        }
        for component in [KeyComponent.queue, .identity, .inventory] {
            try await fixture.create(component, in: attempt)
        }
        let final = try fixture.record()
        #expect(final.created == [.queue, .identity, .inventory])
        #expect(fixture.effects == ["create-queue", "create-identity", "create-inventory"])
        try await fixture.rollback(attempt)
        #expect(fixture.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.recordURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.lockURL.path))
    }

    @Test @MainActor func failedFirstCreateNeedsVerifiedAbsenceBeforeJournalRetirement() async throws {
        let fixture = try BootstrapFixture()
        defer { fixture.discard() }
        let attempt = try fixture.begin()
        await #expect(throws: BootstrapFixtureError.self) {
            try await attempt.create(.queue) { throw BootstrapFixtureError.create }
        }
        try await fixture.rollback(attempt)
        #expect(fixture.effects == ["verify-queue"])
        #expect(!FileManager.default.fileExists(atPath: fixture.recordURL.path))
        _ = try fixture.begin()
    }

    @Test @MainActor func ambiguousFailedCreatePreservesIdentityWithoutDeleteAuthority() async throws {
        let fixture = try BootstrapFixture()
        defer { fixture.discard() }
        var attempt: ProtectionBootstrapAttempt? = try fixture.begin()
        let manifest = try #require(attempt).manifest
        await #expect(throws: BootstrapFixtureError.self) {
            try await #require(attempt).create(.queue) {
                fixture.items.insert(.queue) // Simulate a framework side effect followed by an error.
                throw BootstrapFixtureError.create
            }
        }
        await #expect(throws: ProtectionBootstrapError.rollbackIncomplete) {
            try await fixture.rollback(#require(attempt), cause: .unusableKey(.queue, code: -25308))
        }
        #expect(fixture.effects == ["verify-queue"])
        #expect(try fixture.record().manifest == manifest)
        #expect(try fixture.record().unresolved == [.queue])
        #expect(try fixture.record().failure == .init(.unusableKey(.queue, code: -25308)))
        attempt = nil
        let resumed = try fixture.begin()
        #expect(resumed.manifest == manifest && resumed.createsNewManifest)
        try await fixture.create(.queue, in: resumed)
        #expect(fixture.items == [.queue])
        #expect(fixture.effects == ["verify-queue", "reuse-queue"])
    }

    @Test @MainActor func laterFailureRollsBackOnlySuccessfullyCreatedItems() async throws {
        let fixture = try BootstrapFixture()
        defer { fixture.discard() }
        let attempt = try fixture.begin()
        try await fixture.create(.queue, in: attempt)
        await #expect(throws: BootstrapFixtureError.self) {
            try await attempt.create(.identity) { throw BootstrapFixtureError.create }
        }
        try await fixture.rollback(attempt)
        #expect(fixture.effects == ["create-queue", "verify-identity", "remove-queue"])
        #expect(fixture.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.recordURL.path))
    }

    @Test @MainActor func rollbackFailureRetainsExactOriginalIdentityAcrossRestart() async throws {
        let fixture = try BootstrapFixture()
        defer { fixture.discard() }
        var attempt: ProtectionBootstrapAttempt? = try fixture.begin()
        let manifest = try #require(attempt).manifest
        try await fixture.create(.queue, in: #require(attempt))
        try await fixture.create(.identity, in: #require(attempt))
        await #expect(throws: ProtectionBootstrapError.rollbackIncomplete) {
            try await fixture.rollback(#require(attempt), failing: .queue)
        }
        #expect(fixture.items == [.queue])
        #expect(try fixture.record().manifest == manifest)
        #expect(try fixture.record().unresolved == [.queue])
        #expect(fixture.effects == ["create-queue", "create-identity", "remove-identity", "remove-queue"])
        attempt = nil
        let resumed = try fixture.begin()
        #expect(resumed.manifest == manifest)
        for component in [KeyComponent.queue, .identity, .inventory] {
            try await fixture.create(component, in: resumed)
        }
        #expect(fixture.effects.suffix(3) == ["reuse-queue", "create-identity", "create-inventory"])
        fixture.probe = StoreProtectionProbe(state: .protectedDataPresent, manifest: manifest)
        try resumed.commit { fixture.probe }
        #expect(!FileManager.default.fileExists(atPath: fixture.recordURL.path))
    }

    @Test @MainActor func cancellationDuringCreateRecordsSuccessBeforeRollback() async throws {
        let fixture = try BootstrapFixture()
        defer { fixture.discard() }
        let attempt = try fixture.begin()
        let task = Task { @MainActor in
            try await attempt.create(.queue) {
                fixture.items.insert(.queue)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try fixture.record().created == [.queue])
        try await fixture.rollback(attempt)
        #expect(fixture.effects == ["remove-queue"])
        #expect(fixture.items.isEmpty)
    }

    @Test @MainActor func storeOpenFailureOrAbandonmentPreservesPendingRecord() async throws {
        let fixture = try BootstrapFixture()
        defer { fixture.discard() }
        var attempt: ProtectionBootstrapAttempt? = try fixture.begin()
        let manifest = try #require(attempt).manifest
        try await fixture.create(.queue, in: #require(attempt))
        #expect(throws: ProtectionBootstrapError.commitUnconfirmed) {
            try #require(attempt).commit { fixture.probe }
        }
        attempt = nil // Also represents cancellation between preparation and store commit.
        let resumed = try fixture.begin()
        #expect(resumed.manifest == manifest && resumed.createsNewManifest)
        #expect(try fixture.record().manifest == manifest)
        #expect(fixture.effects == ["create-queue"])
    }

    @Test @MainActor func interruptedSetupResumesWithItsIdentitiesAndReusesCreatedKeys() async throws {
        let fixture = try BootstrapFixture()
        defer { fixture.discard() }
        var attempt: ProtectionBootstrapAttempt? = try fixture.begin()
        let manifest = try #require(attempt).manifest
        for component in [KeyComponent.queue, .identity, .inventory] {
            try await fixture.create(component, in: #require(attempt))
        }
        attempt = nil // Exit after key creation and before the store committed its manifest.
        let resumed = try fixture.begin()
        #expect(resumed.manifest == manifest && resumed.createsNewManifest)
        for component in [KeyComponent.queue, .identity, .inventory] {
            try await fixture.create(component, in: resumed)
        }
        await #expect(throws: ProtectionBootstrapError.unsafeJournal) { try await fixture.create(.queue, in: resumed) }
        #expect(fixture.effects == ["create-queue", "create-identity", "create-inventory",
                                    "reuse-queue", "reuse-identity", "reuse-inventory"])
        fixture.probe = StoreProtectionProbe(state: .protectedDataPresent, manifest: manifest)
        try resumed.commit { fixture.probe }
        #expect(!FileManager.default.fileExists(atPath: fixture.recordURL.path))
        #expect(fixture.items == [.queue, .identity, .inventory])
    }

    @Test @MainActor func failedResumeNeverRemovesReusedKeysOrReplacesTheirIdentities() async throws {
        let fixture = try BootstrapFixture()
        defer { fixture.discard() }
        var attempt: ProtectionBootstrapAttempt? = try fixture.begin()
        let manifest = try #require(attempt).manifest
        try await fixture.create(.queue, in: #require(attempt))
        try await fixture.create(.identity, in: #require(attempt))
        attempt = nil
        var resumed: ProtectionBootstrapAttempt? = try fixture.begin()
        try await fixture.create(.queue, in: #require(resumed))
        try await fixture.create(.identity, in: #require(resumed))
        await #expect(throws: BootstrapFixtureError.self) {
            try await #require(resumed).create(.inventory) { throw BootstrapFixtureError.create }
        }
        await #expect(throws: ProtectionBootstrapError.rollbackIncomplete) {
            try await fixture.rollback(#require(resumed), cause: .unusableKey(.inventory, code: -34018))
        }
        #expect(fixture.items == [.queue, .identity])
        #expect(!fixture.effects.contains { $0.hasPrefix("remove-") })
        #expect(try fixture.record().unresolved == [.identity, .queue])
        resumed = nil
        #expect(try fixture.begin().manifest == manifest)
    }

    @Test @MainActor func matchingCommittedManifestCanReconcileAfterSuccessfulLoad() async throws {
        let fixture = try BootstrapFixture()
        defer { fixture.discard() }
        var attempt: ProtectionBootstrapAttempt? = try fixture.begin()
        let manifest = try #require(attempt).manifest
        fixture.probe = StoreProtectionProbe(state: .protectedDataPresent, manifest: manifest)
        attempt = nil // Crash after the database transaction and before retirement.
        let loaded = try fixture.begin()
        #expect(!loaded.createsNewManifest)
        #expect(try fixture.record().manifest == manifest) // Load failure must leave this intact.
        await #expect(throws: ProtectionBootstrapError.unsafeJournal) {
            try await fixture.create(.queue, in: loaded)
        }
        try loaded.commit { fixture.probe }
        #expect(!FileManager.default.fileExists(atPath: fixture.recordURL.path))
        #expect(fixture.effects.isEmpty)
        #expect(fixture.items.isEmpty)
    }

    @Test @MainActor func committedManifestMismatchAndStaleProbeNeverPermitEffects() throws {
        let fixture = try BootstrapFixture()
        defer { fixture.discard() }
        var attempt: ProtectionBootstrapAttempt? = try fixture.begin()
        let pending = try #require(attempt).manifest
        attempt = nil
        fixture.probe = StoreProtectionProbe(state: .protectedDataPresent,
            manifest: .fresh(identifierPrefix: fixture.configuration.identifierPrefix))
        #expect(throws: ProtectionBootstrapError.manifestMismatch) { try fixture.begin() }
        #expect(try fixture.record().manifest == pending)
        #expect(throws: ProtectionBootstrapError.manifestMismatch) {
            try ProtectionBootstrapAttempt(at: fixture.directory, manifest: nil, storeState: .empty,
                                           configuration: fixture.configuration, probe: { fixture.probe })
        }
        #expect(fixture.effects.isEmpty)
    }

    @Test @MainActor func existingVaultNeverCreatesOrRollsBackKeys() async throws {
        let fixture = try BootstrapFixture()
        defer { fixture.discard() }
        fixture.probe = StoreProtectionProbe(state: .protectedDataPresent,
            manifest: .fresh(identifierPrefix: fixture.configuration.identifierPrefix))
        let attempt = try fixture.begin()
        #expect(!attempt.createsNewManifest)
        await #expect(throws: ProtectionBootstrapError.unsafeJournal) {
            try await fixture.create(.queue, in: attempt)
        }
        try await fixture.rollback(attempt)
        try attempt.retireAfterVerifiedCleanup()
        #expect(fixture.effects.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.recordURL.path))
        try attempt.commit { fixture.probe }
    }

    @Test @MainActor func lockCoversAwaitAndStoreCommitAndIsNotUnlinked() async throws {
        let fixture = try BootstrapFixture()
        defer { fixture.discard() }
        let attempt = try fixture.begin()
        try await attempt.create(.queue) {
            await Task.yield()
            #expect(throws: ProtectionBootstrapError.busy) { try fixture.begin() }
        }
        #expect(throws: ProtectionBootstrapError.busy) { try fixture.begin() }
        fixture.probe = StoreProtectionProbe(state: .protectedDataPresent, manifest: attempt.manifest)
        try attempt.commit { fixture.probe }
        #expect(FileManager.default.fileExists(atPath: fixture.lockURL.path))
        let loaded = try fixture.begin()
        try loaded.commit { fixture.probe }
    }

    @Test @MainActor func actualStoreTransactionIsRequiredForCommit() async throws {
        let fixture = try BootstrapFixture()
        defer { fixture.discard() }
        let attempt = try fixture.begin()
        let cryptography = try BackgroundCryptography.ephemeralForTesting(manifest: attempt.manifest)
        #expect(throws: ProtectionBootstrapError.commitUnconfirmed) {
            try attempt.commit { try ProtectedStore.probe(at: fixture.directory) }
        }
        let store = try await ProtectedStore.open(at: fixture.directory, cryptography: cryptography)
        try attempt.commit { try ProtectedStore.probe(at: fixture.directory) }
        #expect(!FileManager.default.fileExists(atPath: fixture.recordURL.path))
        try await store.close()
    }

    @Test @MainActor func corruptOversizedSymlinkAndHardlinkedRecordsAreRejected() throws {
        for variant in ["corrupt", "oversized", "symlink", "hardlink", "directory", "permissions"] {
            let fixture = try BootstrapFixture()
            defer { fixture.discard() }
            let target = fixture.directory.appendingPathComponent("untouched")
            try Data("sentinel".utf8).write(to: target)
            switch variant {
            case "corrupt": try Data("{".utf8).write(to: fixture.recordURL)
            case "oversized": try Data(repeating: 0, count: 16 * 1024 + 1).write(to: fixture.recordURL)
            case "symlink": try FileManager.default.createSymbolicLink(at: fixture.recordURL, withDestinationURL: target)
            case "hardlink": try FileManager.default.linkItem(at: target, to: fixture.recordURL)
            case "directory": try FileManager.default.createDirectory(at: fixture.recordURL, withIntermediateDirectories: false)
            default:
                let record = ProtectionBootstrapRecord(manifest: .fresh(identifierPrefix: fixture.configuration.identifierPrefix),
                                                       configuration: fixture.configuration)
                try JSONEncoder().encode(record).write(to: fixture.recordURL)
            }
            if variant != "symlink" && variant != "directory" {
                #expect(chmod(fixture.recordURL.path, variant == "permissions" ? 0o644 : 0o600) == 0)
            }
            #expect(throws: ProtectionBootstrapError.unsafeJournal) { try fixture.begin() }
            #expect(try Data(contentsOf: target) == Data("sentinel".utf8))
            #expect(fixture.effects.isEmpty)
        }
    }

    @Test @MainActor func unsafeLockOrDirectoryMakesNoKeyCalls() throws {
        for variant in ["lock-symlink", "lock-permissions", "directory-permissions"] {
            let fixture = try BootstrapFixture()
            defer { fixture.discard() }
            let target = fixture.directory.appendingPathComponent("untouched")
            try Data("sentinel".utf8).write(to: target)
            switch variant {
            case "lock-symlink": try FileManager.default.createSymbolicLink(at: fixture.lockURL, withDestinationURL: target)
            case "lock-permissions":
                try Data().write(to: fixture.lockURL)
                #expect(chmod(fixture.lockURL.path, 0o644) == 0)
            default: #expect(chmod(fixture.directory.path, 0o755) == 0)
            }
            #expect(throws: ProtectionBootstrapError.unsafeJournal) { try fixture.begin() }
            #expect(!FileManager.default.fileExists(atPath: fixture.recordURL.path))
            #expect(try Data(contentsOf: target) == Data("sentinel".utf8))
        }
    }

    @Test @MainActor func syncFailuresPreventKeyEffectsAndPreserveFailClosedIntent() async throws {
        for point in [ProtectionBootstrapIOFailurePoint.fileSync, .directorySync] {
            let fixture = try BootstrapFixture()
            defer { fixture.discard() }
            await #expect(throws: BootstrapFixtureError.self) {
                let attempt = try ProtectionBootstrapAttempt(
                    at: fixture.directory, manifest: nil, storeState: .empty,
                    configuration: fixture.configuration,
                    failureInjector: { observed in
                        if observed == point { throw BootstrapFixtureError.unavailable }
                    }, probe: { fixture.probe })
                try await fixture.create(.queue, in: attempt)
            }
            #expect(fixture.effects.isEmpty)
            #expect(fixture.items.isEmpty)
            #expect(try fixture.begin().manifest == fixture.record().manifest)
        }
    }

    @Test @MainActor func laterJournalSyncFailureStillPrecedesKeyEffect() async throws {
        let fixture = try BootstrapFixture()
        defer { fixture.discard() }
        var fileSyncs = 0
        var attempt: ProtectionBootstrapAttempt? = try ProtectionBootstrapAttempt(
            at: fixture.directory, manifest: nil, storeState: .empty,
            configuration: fixture.configuration,
            failureInjector: { point in
                if point == .fileSync {
                    fileSyncs += 1
                    if fileSyncs == 2 { throw BootstrapFixtureError.unavailable }
                }
            }, probe: { fixture.probe })
        await #expect(throws: BootstrapFixtureError.self) {
            try await fixture.create(.queue, in: #require(attempt))
        }
        #expect(fixture.effects.isEmpty)
        #expect(fixture.items.isEmpty)
        let manifest = try #require(attempt).manifest
        attempt = nil
        #expect(try fixture.begin().manifest == manifest)
        #expect(try fixture.record().attempted.isEmpty)
    }

    @Test @MainActor func replacedDirectoryCannotSeparateKeyEffectsFromJournal() async throws {
        let fixture = try BootstrapFixture()
        let moved = fixture.directory.appendingPathExtension("original")
        defer {
            fixture.discard()
            try? FileManager.default.removeItem(at: moved)
        }
        let attempt = try fixture.begin()
        let manifest = attempt.manifest
        try FileManager.default.moveItem(at: fixture.directory, to: moved)
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        await #expect(throws: ProtectionBootstrapError.unsafeJournal) {
            try await fixture.create(.queue, in: attempt)
        }
        #expect(throws: ProtectionBootstrapError.unsafeJournal) {
            try attempt.commit { StoreProtectionProbe(state: .protectedDataPresent, manifest: manifest) }
        }
        let retained = try JSONDecoder().decode(ProtectionBootstrapRecord.self,
            from: Data(contentsOf: moved.appendingPathComponent(".protection-bootstrap.json")))
        #expect(retained.manifest == manifest)
        #expect(fixture.effects.isEmpty)
        #expect(fixture.items.isEmpty)
    }

    @Test @MainActor func replacedLockCannotPermitEffectsUnderDetachedLockInode() async throws {
        let fixture = try BootstrapFixture()
        defer { fixture.discard() }
        let attempt = try fixture.begin()
        try FileManager.default.moveItem(at: fixture.lockURL, to: fixture.lockURL.appendingPathExtension("old"))
        try Data().write(to: fixture.lockURL)
        #expect(chmod(fixture.lockURL.path, 0o600) == 0)
        await #expect(throws: ProtectionBootstrapError.unsafeJournal) {
            try await fixture.create(.queue, in: attempt)
        }
        #expect(fixture.effects.isEmpty)
        #expect(try fixture.record().manifest == attempt.manifest)
    }

    @Test @MainActor func brandNewDirectoryHierarchyIsDurableBeforeCreate() async throws {
        let fixture = try BootstrapFixture()
        defer { fixture.discard() }
        let nested = fixture.directory.appendingPathComponent("new-parent/vault")
        let attempt = try ProtectionBootstrapAttempt(
            at: nested, manifest: nil, storeState: .empty, configuration: fixture.configuration,
            probe: { fixture.probe })
        try await attempt.create(.queue) {
            let record = try JSONDecoder().decode(ProtectionBootstrapRecord.self,
                from: Data(contentsOf: nested.appendingPathComponent(".protection-bootstrap.json")))
            #expect(record.manifest == attempt.manifest)
            #expect(record.attempted == [.queue])
        }
        try await attempt.rollback(remove: { _ in }, verifyAbsent: { _ in })
    }
}
