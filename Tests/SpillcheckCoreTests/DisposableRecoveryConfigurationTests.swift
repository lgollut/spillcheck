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
    @Test func reviewAndDesktopModesRequireExclusivePrivateDescriptorsAndClosedStages() throws {
        let fixture = try RecoveryConfigurationFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let modes = [("review", ["queue", "resume", "replay"], 4096),
                     ("desktop-beta", ["scan", "replay"], 8192)]
        var selections: [[String]] = []
        for (mode, stages, limit) in modes {
            let path = fixture.root.appendingPathComponent(mode + "-descriptor.json")
            try Data("{}".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            let base = ["--acceptance-recovery-" + mode, "--acceptance-" + mode + "-descriptor", path.path]
            let stageFlags = stages.first.map { ["--acceptance-" + mode + "-stage", $0] } ?? []
            let selected = base + stageFlags
            selections.append(selected)
            for stage in stages.isEmpty ? [""] : stages {
                let flags = base + (stage.isEmpty ? [] : ["--acceptance-" + mode + "-stage", stage])
                let value = try DisposableRecoveryConfiguration(arguments: fixture.arguments + flags)
                #expect([value.reviewEnabled, value.desktopBetaEnabled].filter { $0 }.count == 1)
            }
            var invalid = [[base[0]], Array(base.dropFirst()), selected + [base[0]],
                selected + ["--acceptance-recovery-inventory-state"]]
            if !stages.isEmpty {
                invalid += [base, base + ["--acceptance-" + mode + "-stage", "other"], selected + stageFlags]
            }
            for flags in invalid {
                #expect(throws: ClaudeCollectionError.invalidConfiguration) {
                    try DisposableRecoveryConfiguration(arguments: fixture.arguments + flags)
                }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
            #expect(throws: ClaudeCollectionError.invalidConfiguration) { try DisposableRecoveryConfiguration(arguments: fixture.arguments + selected) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            try Data(repeating: 65, count: limit + 1).write(to: path)
            #expect(throws: ClaudeCollectionError.invalidConfiguration) { try DisposableRecoveryConfiguration(arguments: fixture.arguments + selected) }
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: fixture.root.appendingPathComponent("token"))
            #expect(throws: ClaudeCollectionError.invalidConfiguration) { try DisposableRecoveryConfiguration(arguments: fixture.arguments + selected) }
            try FileManager.default.removeItem(at: path)
            try Data("{}".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        for first in selections.indices {
            for second in selections.indices where first != second {
                #expect(throws: ClaudeCollectionError.invalidConfiguration) {
                    try DisposableRecoveryConfiguration(arguments: fixture.arguments + selections[first] + selections[second])
                }
            }
        }
    }

    @Test func nativeContentRequiresExclusiveModePrivateBoundedDescriptorAndAuthenticatedReplay() throws {
        let fixture = try RecoveryConfigurationFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let descriptor = fixture.root.appendingPathComponent("native-content-descriptor.json")
        try Data("{}".utf8).write(to: descriptor)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: descriptor.path)
        let flags = ["--acceptance-recovery-native-content", "--acceptance-native-content-descriptor", descriptor.path]
        let ordinary = try DisposableRecoveryConfiguration(arguments: fixture.arguments)
        #expect(!ordinary.nativeContentEnabled && ordinary.nativeContentDescriptorData == nil)
        #expect(throws: ClaudeCollectionError.invalidConfiguration) { try ordinary.controlURL("native-content-replay") }
        let native = try DisposableRecoveryConfiguration(arguments: fixture.arguments + flags)
        #expect(native.nativeContentEnabled && native.nativeContentDescriptorData == Data("{}".utf8)
            && !native.inventoryStateEnabled && !native.webResultsEnabled)
        let control = try native.controlURL("native-content-replay")
        #expect(!native.authorizes(control))
        try fixture.token.write(to: control)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: control.path)
        #expect(native.authorizes(control))
        for extra in [["--acceptance-recovery-native-content"], ["--acceptance-native-content-descriptor", descriptor.path],
            flags + ["--acceptance-recovery-native-content"], flags + ["--acceptance-native-content-descriptor", descriptor.path],
            flags + ["--acceptance-recovery-inventory-state"],
            flags + ["--acceptance-recovery-web-results", "--acceptance-web-source", UUID().uuidString.lowercased()]] {
            #expect(throws: ClaudeCollectionError.invalidConfiguration) {
                try DisposableRecoveryConfiguration(arguments: fixture.arguments + extra)
            }
        }
        for name in ["inventory-review-and-receipt", "inventory-replay-source", "web-result-replay"] {
            #expect(throws: ClaudeCollectionError.invalidConfiguration) { try native.controlURL(name) }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: descriptor.path)
        #expect(throws: ClaudeCollectionError.invalidConfiguration) { try DisposableRecoveryConfiguration(arguments: fixture.arguments + flags) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: descriptor.path)
        try Data(repeating: 65, count: 8193).write(to: descriptor)
        #expect(throws: ClaudeCollectionError.invalidConfiguration) { try DisposableRecoveryConfiguration(arguments: fixture.arguments + flags) }
        try FileManager.default.removeItem(at: descriptor)
        try FileManager.default.createSymbolicLink(at: descriptor, withDestinationURL: fixture.root.appendingPathComponent("token"))
        #expect(throws: ClaudeCollectionError.invalidConfiguration) { try DisposableRecoveryConfiguration(arguments: fixture.arguments + flags) }
    }

    @Test func removedUpgradeRequiresBothModesAndExposesOnlyRemovalControl() throws {
        let fixture = try RecoveryConfigurationFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let removed = ["--acceptance-recovery-upgrade-removed-state"]
        let flags = ["--acceptance-recovery-inventory-state", "--acceptance-recovery-upgrade-state"]
        for invalid in [removed, flags.prefix(1).map { $0 } + removed, flags + removed + removed] {
            #expect(throws: ClaudeCollectionError.invalidConfiguration) {
                try DisposableRecoveryConfiguration(arguments: fixture.arguments + invalid)
            }
        }
        let selected = try DisposableRecoveryConfiguration(arguments: fixture.arguments + flags + removed)
        #expect(selected.inventoryStateEnabled && selected.upgradeStateEnabled && selected.upgradeRemovedStateEnabled)
        let control = try selected.controlURL("inventory-obsolete-and-remove")
        #expect(!selected.authorizes(control))
        try fixture.token.write(to: control)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: control.path)
        #expect(selected.authorizes(control))
        for name in ["inventory-acknowledge-revoked", "inventory-replay-source", "web-result-replay"] {
            #expect(throws: ClaudeCollectionError.invalidConfiguration) { try selected.controlURL(name) }
        }
        let retained = try DisposableRecoveryConfiguration(arguments: fixture.arguments + flags)
        #expect(!retained.upgradeRemovedStateEnabled)
        #expect(throws: ClaudeCollectionError.invalidConfiguration) { try retained.controlURL("inventory-obsolete-and-remove") }
    }

    @Test func upgradeStateRequiresInventoryOptInAndDedicatedAuthenticatedControl() throws {
        let fixture = try RecoveryConfigurationFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inventory = ["--acceptance-recovery-inventory-state"]
        let upgrade = ["--acceptance-recovery-upgrade-state"]
        let ordinary = try DisposableRecoveryConfiguration(arguments: fixture.arguments + inventory)
        #expect(!ordinary.upgradeStateEnabled)
        #expect(throws: ClaudeCollectionError.invalidConfiguration) { try ordinary.controlURL("inventory-acknowledge-revoked") }
        let optedIn = try DisposableRecoveryConfiguration(arguments: fixture.arguments + inventory + upgrade)
        #expect(optedIn.inventoryStateEnabled && optedIn.upgradeStateEnabled && !optedIn.webResultsEnabled)
        let control = try optedIn.controlURL("inventory-acknowledge-revoked")
        #expect(!optedIn.authorizes(control))
        try fixture.token.write(to: control)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: control.path)
        #expect(optedIn.authorizes(control))
        for name in ["inventory-obsolete-and-remove", "inventory-replay-source", "web-result-replay"] {
            #expect(throws: ClaudeCollectionError.invalidConfiguration) { try optedIn.controlURL(name) }
        }
        for flags in [upgrade, inventory + upgrade + upgrade,
                      inventory + upgrade + ["--acceptance-recovery-web-results", "--acceptance-web-source", UUID().uuidString.lowercased()]] {
            #expect(throws: ClaudeCollectionError.invalidConfiguration) {
                try DisposableRecoveryConfiguration(arguments: fixture.arguments + flags)
            }
        }
    }

    @Test func webResultsRequireAnExclusiveModeExactSourceAndAuthenticatedControl() throws {
        let fixture = try RecoveryConfigurationFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let selected = UUID().uuidString.lowercased()
        let flags = ["--acceptance-recovery-web-results", "--acceptance-web-source", selected]
        let ordinary = try DisposableRecoveryConfiguration(arguments: fixture.arguments)
        #expect(!ordinary.webResultsEnabled && ordinary.webSourceID == nil)
        #expect(throws: ClaudeCollectionError.invalidConfiguration) { try ordinary.controlURL("web-result-replay") }
        let web = try DisposableRecoveryConfiguration(arguments: fixture.arguments + flags)
        #expect(web.webResultsEnabled && web.webSourceID == selected && !web.inventoryStateEnabled)
        let control = try web.controlURL("web-result-replay")
        #expect(!web.authorizes(control))
        try fixture.token.write(to: control)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: control.path)
        #expect(web.authorizes(control))
        #expect(throws: ClaudeCollectionError.invalidConfiguration) { try web.controlURL("inventory-replay-source") }
        for extra in [["--acceptance-recovery-web-results"], ["--acceptance-web-source", selected],
                      flags + ["--acceptance-recovery-web-results"], flags + ["--acceptance-web-source", selected],
                      flags + ["--acceptance-recovery-inventory-state"],
                      ["--acceptance-recovery-web-results", "--acceptance-web-source", "not-a-native-id"]] {
            #expect(throws: ClaudeCollectionError.invalidConfiguration) {
                try DisposableRecoveryConfiguration(arguments: fixture.arguments + extra)
            }
        }
    }

    @Test func inventoryMutationControlsRequireExplicitOptInAndPrivateToken() throws {
        let fixture = try RecoveryConfigurationFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ordinary = try DisposableRecoveryConfiguration(arguments: fixture.arguments)
        #expect(!ordinary.inventoryStateEnabled)
        let arguments = fixture.arguments + ["--acceptance-recovery-inventory-state"]
        let optedIn = try DisposableRecoveryConfiguration(arguments: arguments)
        #expect(optedIn.inventoryStateEnabled)
        for name in ["inventory-review-and-receipt", "inventory-obsolete-and-remove", "inventory-replay-source"] {
            #expect(throws: ClaudeCollectionError.invalidConfiguration) { try ordinary.controlURL(name) }
            let control = try optedIn.controlURL(name)
            #expect(!optedIn.authorizes(control))
            try Data(repeating: 3, count: 32).write(to: control)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: control.path)
            #expect(!optedIn.authorizes(control))
            try fixture.token.write(to: control)
            #expect(optedIn.authorizes(control))
        }
        #expect(throws: ClaudeCollectionError.invalidConfiguration) {
            try DisposableRecoveryConfiguration(arguments: arguments + ["--acceptance-recovery-inventory-state"])
        }
    }

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

    @Test func codexProfileAndRetryControlsStayInsideOwnedRoot() throws {
        let fixture = try RecoveryConfigurationFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let selected = try DisposableRecoveryConfiguration(arguments: fixture.arguments)
        let home = fixture.root.appendingPathComponent("codex")
        let executable = fixture.root.appendingPathComponent("selected-codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let arguments = ["--acceptance-recovery-home", home.path,
            "--acceptance-recovery-executable", executable.path, "--acceptance-recovery-version", "0.162.1"]
        let profile = try selected.codexProfile(arguments: arguments)
        #expect(profile.home == home.path && profile.executable == executable.path && profile.version == "0.162.1")
        for name in ["stop-codex-polling", "retry-terminal-codex-source"] {
            let control = try selected.controlURL(name)
            #expect(!selected.authorizes(control))
            try Data(repeating: 8, count: 32).write(to: control)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: control.path)
            #expect(!selected.authorizes(control))
            try fixture.token.write(to: control)
            #expect(selected.authorizes(control))
        }
        #expect(throws: ClaudeCollectionError.invalidConfiguration) { try selected.controlURL("retry-all-sources") }
        var outside = arguments
        outside[1] = "/private/tmp/personal-codex"
        #expect(throws: ClaudeCollectionError.invalidConfiguration) { try selected.codexProfile(arguments: outside) }
        #expect(throws: ClaudeCollectionError.invalidConfiguration) {
            try selected.codexProfile(arguments: arguments + ["--acceptance-recovery-version", "0.162.1"])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path)
        #expect(throws: ClaudeCollectionError.invalidConfiguration) { try selected.codexProfile(arguments: arguments) }
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
