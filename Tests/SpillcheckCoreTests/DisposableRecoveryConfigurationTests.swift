import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private struct RecoveryConfigurationFixture {
    let root: URL
    let token: Data
    let arguments: [String]
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("spillcheck-recovery-guard-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        token = Data(repeating: 71, count: 32)
        let tokenURL = root.appendingPathComponent("token")
        try token.write(to: tokenURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        arguments = ["--acceptance-recovery-root", root.path, "--store-directory", root.appendingPathComponent("store").path,
            "--acceptance-report", root.appendingPathComponent("report").path,
            "--acceptance-finish-file", root.appendingPathComponent("finish").path,
            "--acceptance-recovery-token", tokenURL.path]
    }
}

private struct RecoveryEmptyNormalizer: CaptureNormalizer {
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) async throws -> CollectionBatch { .init(sources: []) }
}

private struct RecoveryUnusedDetector: SecretDetector {
    func scan(_ source: SourceRecord) async throws -> DetectorOutput { throw DetectorFailure.invalidSource }
}

private actor RecoveryCaptureCompletions {
    private var ids: [UUID] = []
    func append(_ id: UUID) { ids.append(id) }
    func values() -> [UUID] { ids }
}

@Suite("Disposable signed recovery controls")
struct DisposableRecoveryConfigurationTests {
    @Test func refusesEscapesPublicTokensAndLinkedControls() throws {
        let fixture = try RecoveryConfigurationFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let selected = try DisposableRecoveryConfiguration(arguments: fixture.arguments)
        let control = try selected.controlURL("stop-processing")
        #expect(!selected.authorizes(control))
        try fixture.token.write(to: control)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: control.path)
        #expect(selected.authorizes(control))
        try Data(repeating: 72, count: 32).write(to: control)
        #expect(!selected.authorizes(control))
        try FileManager.default.removeItem(at: control)
        try FileManager.default.createSymbolicLink(at: control, withDestinationURL: fixture.root.appendingPathComponent("token"))
        #expect(!selected.authorizes(control))
        var escaped = fixture.arguments
        escaped[escaped.firstIndex(of: "--store-directory")! + 1] = "/private/tmp/existing-user-store"
        #expect(throws: ClaudeCollectionError.invalidConfiguration) { try DisposableRecoveryConfiguration(arguments: escaped) }
        #expect(throws: ClaudeCollectionError.invalidConfiguration) {
            try DisposableRecoveryConfiguration(arguments: fixture.arguments + ["--acceptance-report", control.path])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.root.appendingPathComponent("token").path)
        #expect(throws: ClaudeCollectionError.invalidConfiguration) { try DisposableRecoveryConfiguration(arguments: fixture.arguments) }
    }

    @Test func freshOwnerRefusesExistingEncryptedManifest() async throws {
        let fixture = try RecoveryConfigurationFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let selected = try DisposableRecoveryConfiguration(arguments: fixture.arguments)
        try selected.requireFreshOwner(ProtectedStore.probe(at: selected.store))
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: selected.store, cryptography: crypto)
        try await store.close()
        let before = try Data(contentsOf: selected.store.appendingPathComponent(ProtectedStore.databaseFilename))
        #expect(throws: KeyUnavailable.invalidManifest) { try selected.requireFreshOwner(ProtectedStore.probe(at: selected.store)) }
        #expect(try Data(contentsOf: selected.store.appendingPathComponent(ProtectedStore.databaseFilename)) == before)
    }

    @Test func ownedProfileRequiresObservedVersionAndPrivateDirectHome() throws {
        let fixture = try RecoveryConfigurationFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let selected = try DisposableRecoveryConfiguration(arguments: fixture.arguments)
        let home = fixture.root.appendingPathComponent("claude")
        let executable = fixture.root.appendingPathComponent("selected-claude")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let arguments = ["--acceptance-recovery-home", home.path, "--acceptance-recovery-executable", executable.path]
        #expect(throws: ClaudeCollectionError.invalidConfiguration) { try selected.claudeProfile(arguments: arguments) }
        #expect(throws: ClaudeCollectionError.invalidConfiguration) {
            try selected.claudeProfile(arguments: arguments + ["--acceptance-recovery-version", ""])
        }
        let versioned = arguments + ["--acceptance-recovery-version", "2.999.1"]
        let profile = try selected.claudeProfile(arguments: versioned)
        #expect(profile.home == home.path && profile.executable == executable.path && profile.version == "2.999.1")
        #expect(throws: ClaudeCollectionError.invalidConfiguration) {
            try selected.claudeProfile(arguments: versioned + ["--acceptance-recovery-version", "2.999.2"])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path)
        #expect(throws: ClaudeCollectionError.invalidConfiguration) { try selected.claudeProfile(arguments: versioned) }
        try FileManager.default.removeItem(at: home)
        try FileManager.default.createSymbolicLink(at: home, withDestinationURL: fixture.root)
        #expect(throws: ClaudeCollectionError.invalidConfiguration) { try selected.claudeProfile(arguments: versioned) }
    }

    @Test func exactPendingIdentitySurvivesRestartAndReportsOnlySuccessfulAtomicCompletion() async throws {
        let fixture = try RecoveryConfigurationFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let selected = try DisposableRecoveryConfiguration(arguments: fixture.arguments)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(), id = UUID()
        let packet = try CapturePacket(metadata: .init(agent: .claudeCode, interface: .standaloneCLI, profileID: "owned-fixture"),
                                       eventJSON: Data("{}".utf8))
        let store = try await ProtectedStore.open(at: selected.store, cryptography: crypto)
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(packet.body, id: id, capturedAt: now, permit: permit, at: now)
        #expect(try await store.captureIdentitiesForTesting().pending == [id])
        try await store.close()

        let interrupted = try await ProtectedStore.open(at: selected.store, cryptography: crypto, failureInjector: {
            if $0 == .beforeProcessingCommit { throw StorageError.injectedFailure }
        })
        let completions = RecoveryCaptureCompletions()
        let failedPipeline = DetectionPipeline(store: interrupted, cryptography: crypto, normalizer: RecoveryEmptyNormalizer(),
                                              detector: RecoveryUnusedDetector(), detectorVersion: "fixture")
        await failedPipeline.observeCaptureCompletionsForTesting { await completions.append($0) }
        #expect(try await failedPipeline.processNext() == .retryScheduled)
        #expect(await completions.values().isEmpty)
        #expect(try await interrupted.captureIdentitiesForTesting().pending == [id])
        #expect(try await interrupted.captureIdentitiesForTesting().consumed.isEmpty)
        try await interrupted.close()

        let restarted = try await ProtectedStore.open(at: selected.store, cryptography: crypto)
        let recoveredPipeline = DetectionPipeline(store: restarted, cryptography: crypto, normalizer: RecoveryEmptyNormalizer(),
                                                 detector: RecoveryUnusedDetector(), detectorVersion: "fixture")
        await recoveredPipeline.observeCaptureCompletionsForTesting { await completions.append($0) }
        #expect(try await recoveredPipeline.processNext(at: now.addingTimeInterval(30)) == .processed)
        #expect(await completions.values() == [id])
        #expect(try await restarted.captureIdentitiesForTesting().pending.isEmpty)
        #expect(try await restarted.captureIdentitiesForTesting().consumed == [id])
        try await restarted.close()

        let final = try await ProtectedStore.open(at: selected.store, cryptography: crypto, limits: .init(maxQueueAge: 5))
        let finalPermit = try #require(await final.processingPermit())
        #expect(try await final.enqueue(packet.body, id: id, capturedAt: now, permit: finalPermit) == .alreadyProcessed(id))
        #expect(try await final.captureIdentitiesForTesting().pending.isEmpty)
        #expect(try await final.captureIdentitiesForTesting().consumed == [id])
        await #expect(throws: StorageError.invalidPayload) { try await final.captureIdentitiesForTesting(limit: 0) }
        // Loss consumes a receipt too, so acceptance must also require the successful worker
        // completion observer. An automatic audit cannot stand in for this queued identity.
        let expiredID = UUID()
        _ = try await final.enqueue(packet.body, id: expiredID, capturedAt: now, permit: finalPermit, at: now)
        #expect(try await final.maintainQueue(at: now.addingTimeInterval(6)) == 1)
        #expect(try await final.captureIdentitiesForTesting().consumed.contains(expiredID))
        let idlePipeline = DetectionPipeline(store: final, cryptography: crypto, normalizer: RecoveryEmptyNormalizer(),
                                            detector: RecoveryUnusedDetector(), detectorVersion: "fixture")
        await idlePipeline.observeCaptureCompletionsForTesting { await completions.append($0) }
        #expect(try await idlePipeline.processNext(at: now.addingTimeInterval(7)) == .idle)
        #expect(await completions.values() == [id])
        try await final.close()
    }
}
