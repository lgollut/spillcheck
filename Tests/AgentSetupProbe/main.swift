import Foundation
@_spi(Testing) import SpillcheckCore

private enum ProbeFailure: Error {
    case failed(String)
}

private struct SavedProfiles: Codable {
    let schemaVersion: Int
    let profiles: [AgentProfileDraft]
}

/// Freeze one actual adapter packet so byte preservation tests the wrapper itself. Separate
/// JSONEncoder calls may order the same request's object keys differently.
private struct FixedHistoricalCaptureProducer: HistoricalCaptureProducer {
    let packet: CapturePacket
    let expectedAudit: HistoricalAuditContext

    func initialHistoricalCapture(audit: HistoricalAuditContext) async throws -> CapturePacket {
        guard audit == expectedAudit else {
            throw ProbeFailure.failed("authorized-history-wrapper-changed-requested-audit")
        }
        return packet
    }
}

private func require(_ condition: Bool, _ stage: String) throws {
    guard condition else { throw ProbeFailure.failed(stage) }
}

@MainActor
private func requireFailure(_ stage: String, _ action: @MainActor () async throws -> Void) async throws {
    do { try await action() }
    catch { return }
    throw ProbeFailure.failed(stage)
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

/// The only executable used as a provider is an owned script accepting --version alone.
/// The hook helper is a separate sentinel script and must never be executed by setup actions.
@MainActor
private final class Fixture {
    let root: URL
    private(set) var store: ProtectedStore
    let helper: URL
    let socket: URL
    let helperMarker: URL
    let providerLog: URL
    let cryptography: BackgroundCryptography

    init() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spillcheck-agent-setup-probe-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        self.root = root
        helper = root.appendingPathComponent("spillcheck-hook")
        socket = root.appendingPathComponent("capture.sock")
        helperMarker = root.appendingPathComponent("helper-was-run")
        providerLog = root.appendingPathComponent("provider-arguments.log")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let script = "#!/bin/sh\nprintf '%s\\n' 'unexpected execution' > \(shellQuote(helperMarker.path))\nexit 64\n"
            try Data(script.utf8).write(to: helper, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            let crypto = try BackgroundCryptography.ephemeralForTesting()
            cryptography = crypto
            store = try await ProtectedStore.open(at: root.appendingPathComponent("store", isDirectory: true),
                cryptography: crypto)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func close() async throws {
        try await store.close()
        try FileManager.default.removeItem(at: root)
    }

    func reopenStore() async throws {
        try await store.close()
        store = try await ProtectedStore.open(at: root.appendingPathComponent("store", isDirectory: true),
            cryptography: cryptography)
    }

    func controller() -> AgentSetupController {
        AgentSetupController(store: store, helperURL: helper, socketURL: socket)
    }

    func profile(_ provider: AgentProvider, version: String? = nil,
                 interface: AgentInterface = .standaloneCLI, t3Version: String? = nil) throws -> AgentProfileDraft {
        let executable = root.appendingPathComponent(provider == .codex ? "codex-fixture" : "claude-fixture")
        let home = root.appendingPathComponent(provider == .codex ? "codex-profile" : "claude-profile", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let version = version ?? (provider == .codex ? CodexAdapter.validatedAgentVersion : ClaudeAdapter.validatedAgentVersion)
        try replaceExecutable(at: executable, provider: provider, version: version)
        return AgentProfileDraft(provider: provider, executablePath: executable.path, homePath: home.path,
            interface: interface, version: version, t3Version: t3Version)
    }

    func replaceExecutable(at executable: URL, provider: AgentProvider, version: String) throws {
        let output = provider == .codex ? "codex-cli \(version)" : "\(version) (Claude Code)"
        let script = """
        #!/bin/sh
        if [ "$#" -ne 1 ] || [ "$1" != '--version' ]; then
          printf '%s\\n' 'unexpected-arguments' >> \(shellQuote(providerLog.path))
          exit 64
        fi
        printf '%s\\n' '--version' >> \(shellQuote(providerLog.path))
        printf '%s\\n' \(shellQuote(output))
        exit 0

        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func hooksURL(_ profile: AgentProfileDraft) -> URL {
        URL(fileURLWithPath: profile.homePath, isDirectory: true)
            .appendingPathComponent(profile.provider == .codex ? "hooks.json" : "settings.json")
    }

    func unrelatedSettings() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "unrelatedRoot": ["retained": true, "number": 47],
            "hooks": ["Stop": [["matcher": "unrelated", "hooks": [
                ["type": "command", "command": "unrelated-handler", "timeout": 17],
                ["type": "command", "command": "foreign-spillcheck-handler", "statusMessage": "Spillcheck hook another-registration"],
            ]]]],
        ], options: [.sortedKeys])
    }

    func seedOwnedHooks(_ profile: AgentProfileDraft, preserving original: Data) throws -> Data {
        let installed: Data
        if profile.provider == .codex {
            let config = try CodexHookConfiguration(registrationID: profile.registrationID,
                helperURL: helper, socketURL: socket, profileID: profile.profileID,
                interface: profile.interface, agentVersion: CodexAdapter.validatedAgentVersion)
            installed = try config.editing(original, action: .install)
        } else {
            let config = try ClaudeHookConfiguration(registrationID: profile.registrationID,
                helperURL: helper, socketURL: socket, profileID: profile.profileID,
                interface: profile.interface, agentVersion: ClaudeAdapter.validatedAgentVersion)
            installed = try config.editing(original, action: .install)
        }
        try installed.write(to: hooksURL(profile), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hooksURL(profile).path)
        return installed
    }

    func savedData(_ profiles: [AgentProfileDraft], schemaVersion: Int = 1) throws -> Data {
        let encoded = try JSONEncoder().encode(SavedProfiles(schemaVersion: schemaVersion, profiles: profiles))
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        if schemaVersion < 3 {
            object["profiles"] = (object["profiles"] as! [[String: Any]]).map { value in
                var legacy = value
                legacy.removeValue(forKey: "authorizedHosts")
                return legacy
            }
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    func save(_ profiles: [AgentProfileDraft], schemaVersion: Int = 1) async throws {
        try await store.setProtectedPreference(savedData(profiles, schemaVersion: schemaVersion), for: .agentProfiles)
    }

    func savedProfiles() async throws -> [AgentProfileDraft] {
        guard let bytes = try await store.protectedPreference(.agentProfiles) else {
            throw ProbeFailure.failed("missing-protected-profile")
        }
        return try JSONDecoder().decode(SavedProfiles.self, from: bytes).profiles
    }

    func assertCanonicalClaudeReplay(before: AgentProfileDraft, after: AgentProfileDraft) async throws {
        let session = UUID().uuidString, item = UUID().uuidString, document = UUID()
        let row = try JSONSerialization.data(withJSONObject: ["type": "user", "sessionId": session,
            "uuid": item, "timestamp": "2026-10-09T12:00:00Z", "version": "2.1.293",
            "message": ["role": "user", "content": "synthetic route migration é🙂"]]) + Data([10])
        let original = try ClaudeAdapter(profileID: before.profileID, agentVersion: before.version, allowedTranscriptRoots: [])
        let migrated = try ClaudeAdapter(profileID: after.profileID, agentVersion: after.version, allowedTranscriptRoots: [])
        let a = try await original.importTranscript(row, documentID: document, interface: .standaloneCLI,
            observedAt: .now, cryptography: cryptography)
        let b = try await migrated.importTranscript(row, documentID: document, interface: .t3,
            observedAt: .now, cryptography: cryptography)
        guard let first = a.sources.first?.record, let replay = b.sources.first?.record,
              let permit = await store.processingPermit() else { throw ProbeFailure.failed("migration-native-source-unavailable") }
        try require(a.coverageGaps.isEmpty && b.coverageGaps.isEmpty, "migration-native-source-gap")
        try require(first.metadata.identity == replay.metadata.identity && first.revision == replay.revision
            && first.segments == replay.segments, "migration-changed-native-identity-or-content")
        _ = try await store.commit(SourceAnalysis(source: first, detectorVersion: "route-migration-fixture", detections: []),
            payloads: [], permit: permit)
        let receipts = await store.snapshot().analysisReceipts
        _ = try await store.commit(SourceAnalysis(source: replay, detectorVersion: "route-migration-fixture", detections: []),
            payloads: [], permit: permit)
        try require(await store.snapshot().analysisReceipts == receipts && !receipts.isEmpty,
            "migration-host-replay-created-new-receipt")
    }

    func durablePacket(profile: AgentProfileDraft, prompt: String) async throws -> (CapturePacket, UUID) {
        let event = try JSONSerialization.data(withJSONObject: ["hook_event_name": "UserPromptSubmit",
            "prompt": prompt, "session_id": UUID().uuidString])
        let packet = try CapturePacket(metadata: CaptureMetadata(agent: profile.provider,
            interface: profile.interface, profileID: profile.profileID), eventJSON: event)
        guard let permit = await store.processingPermit() else { throw ProbeFailure.failed("missing-processing-permit") }
        let insertion = try await store.enqueue(packet.body, capturedAt: .now, permit: permit)
        let id: UUID
        switch insertion {
        case .inserted(let value), .alreadyQueued(let value), .alreadyProcessed(let value): id = value
        }
        return (packet, id)
    }

    func assertOnlyVersionCommands() throws {
        try require(!FileManager.default.fileExists(atPath: helperMarker.path), "hook-helper-was-executed")
        if let text = try? String(contentsOf: providerLog, encoding: .utf8) {
            try require(text.split(separator: "\n").allSatisfy { $0 == "--version" }, "provider-session-was-started")
        }
    }
}

@MainActor
private func withFixture(_ action: @MainActor (Fixture) async throws -> Void) async throws {
    let fixture = try await Fixture()
    do {
        try await action(fixture)
        try fixture.assertOnlyVersionCommands()
        try await fixture.close()
    } catch {
        try? await fixture.close()
        throw error
    }
}

private func sameJSON(_ left: Data, _ right: Data) throws -> Bool {
    guard let a = try JSONSerialization.jsonObject(with: left) as? NSDictionary,
          let b = try JSONSerialization.jsonObject(with: right) as? NSDictionary else { return false }
    return a == b
}

@MainActor
private func codexProfileHomeAssertions() async throws -> [String] {
    try await withFixture { fixture in
        var profile = try fixture.profile(.codex)
        let originalHome = try CodexResumeProfile(profileID: profile.profileID,
            homeURL: URL(fileURLWithPath: profile.homePath),
            executableURL: URL(fileURLWithPath: profile.executablePath)).homeURL.path
        let alias = fixture.root.appendingPathComponent("selected-profile")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: originalHome)
        profile.homePath = alias.path
        let unrelated = try fixture.unrelatedSettings()
        try unrelated.write(to: fixture.hooksURL(profile), options: .atomic)
        let controller = fixture.controller()
        try await controller.load()
        try await controller.install(profile)
        try await controller.verify(.codex)
        guard let prompt = await controller.snapshot().verificationPrompts[.codex] else {
            throw ProbeFailure.failed("canonical-home-challenge-missing")
        }
        let (packet, queueID) = try await fixture.durablePacket(profile: profile, prompt: prompt)
        await controller.received(packet, durableQueueID: queueID)
        try await controller.install(profile) // The same home through an alias is a repair.
        guard let verified = await controller.snapshot().profiles[.codex] else {
            throw ProbeFailure.failed("canonical-home-profile-missing")
        }
        try require(verified.homePath == originalHome && verified.profileID == profile.profileID
            && verified.registrationID == profile.registrationID && verified.connectionProof?.durableQueueID == queueID,
            "same-canonical-home-lost-identity-or-proof")
        try require(try await fixture.savedProfiles().first == verified, "canonical-home-not-persisted")
        try await controller.remove(.codex)
        let oldHooks = fixture.hooksURL(verified)
        try require(try sameJSON(Data(contentsOf: oldHooks), unrelated), "old-home-removal-changed-unowned-settings")
        let newHome = fixture.root.appendingPathComponent("replacement-profile", isDirectory: true)
        try FileManager.default.createDirectory(at: newHome, withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: newHome)
        try unrelated.write(to: newHome.appendingPathComponent("hooks.json"), options: .atomic)
        try await controller.install(profile)
        guard let replacement = await controller.snapshot().profiles[.codex] else {
            throw ProbeFailure.failed("replacement-home-profile-missing")
        }
        let canonicalNewHome = try CodexResumeProfile(profileID: replacement.profileID,
            homeURL: newHome, executableURL: URL(fileURLWithPath: replacement.executablePath)).homeURL.path
        try require(replacement.homePath == canonicalNewHome && replacement.profileID != verified.profileID
            && replacement.registrationID != verified.registrationID && replacement.connectionProof == nil,
            "changed-home-reused-native-profile-identity")
        let oldSession = try SessionIdentity(provider: .codex, profileID: verified.profileID, sessionID: UUID().uuidString)
        let opening = SourceOpeningController(configuration: .init(profiles: [.codex: replacement], homeURL: fixture.root))
        try await requireFailure("retained-finding-followed-replacement-home") {
            _ = try opening.terminalResumePlan(session: oldSession)
        }
        let reloaded = fixture.controller()
        try await reloaded.load()
        let restored = await reloaded.snapshot()
        try require(restored.profiles[.codex] == replacement && restored.states[.codex] == .installedUnverified,
            "restart-lost-new-home-identity-or-invented-proof")
        try await reloaded.remove(.codex)
        try require(try sameJSON(Data(contentsOf: oldHooks), unrelated)
            && sameJSON(Data(contentsOf: newHome.appendingPathComponent("hooks.json")), unrelated),
            "replacement-home-removal-altered-unowned-settings")
    }
    try await withFixture { fixture in
        let profile = try fixture.profile(.codex)
        let controller = fixture.controller()
        try await controller.load()
        try await controller.install(profile)
        try await controller.remove(.codex)
        let before = await controller.snapshot()
        let oldHooks = try Data(contentsOf: fixture.hooksURL(profile))
        var changed = profile
        let newHome = fixture.root.appendingPathComponent("uncommitted-profile", isDirectory: true)
        try FileManager.default.createDirectory(at: newHome, withIntermediateDirectories: false)
        changed.homePath = newHome.path
        try await fixture.store.close()
        try await requireFailure("failed-new-home-save-reported-success") { try await controller.install(changed) }
        let after = await controller.snapshot()
        try require(after.profiles == before.profiles && after.states == before.states
            && (try Data(contentsOf: fixture.hooksURL(profile))) == oldHooks
            && !FileManager.default.fileExists(atPath: fixture.hooksURL(changed).path),
            "failed-new-home-save-published-identity-or-edited-hooks")
    }
    try await withFixture { fixture in
        var legacy = try fixture.profile(.codex)
        let alias = fixture.root.appendingPathComponent("legacy-profile-alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: legacy.homePath)
        legacy.homePath = alias.path
        try await fixture.save([legacy], schemaVersion: 3)
        let saved = try await fixture.store.protectedPreference(.agentProfiles)
        let controller = fixture.controller()
        try await controller.load()
        let loaded = await controller.snapshot()
        let retained = try await fixture.store.protectedPreference(.agentProfiles)
        try require(loaded.profiles[.codex] == legacy && retained == saved,
            "load-invented-legacy-home-or-rewrote-profile-identity")
    }
    return ["codex-canonical-home-repair-preserves-identity-and-changed-home-rekeys-after-removal",
        "failed-codex-home-change-save-preserves-old-identity-and-provider-files",
        "legacy-codex-home-load-does-not-invent-historical-binding"]
}

@main
private struct AgentSetupProbe {
    @MainActor static func main() async {
        var assertionGroup = "agent-setup-probe"
        do {
            if CommandLine.arguments.contains("--owner-diagnostics-only") {
                let checks = try vaultOwnerDiagnosticsAssertions()
                let report: [String: Any] = ["passed": true, "checks": checks, "checkCount": checks.count,
                    "keychainAccessed": false, "vaultOpened": false, "providerSessionsStarted": 0,
                    "verificationEvidence": "pure-owner-failure-diagnostic-projection"]
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                return
            }
            var checks: [String] = []
            for t3Version in [nil, "unsupported-T3-version"] as [String?] {
                try await withFixture { fixture in
                    var profile = try fixture.profile(.codex, interface: .t3, t3Version: t3Version)
                    profile.installed = true
                    let original = try fixture.unrelatedSettings()
                    let owned = try fixture.seedOwnedHooks(profile, preserving: original)
                    try await fixture.save([profile])
                    let controller = fixture.controller()
                    try await controller.load()
                    try require(await controller.snapshot().states[.codex] == .installedUnverified, "t3-unverified-state")
                    try require(await controller.selectedProfiles().count == 1, "t3-selected")
                    try await controller.install(profile)
                    try await controller.verify(.codex)
                    try require(try Data(contentsOf: fixture.hooksURL(profile)) == owned, "unsupported-t3-modified-hooks")
                }
                checks.append(t3Version == nil ? "missing-T3-version-permits-native-configuration"
                    : "unfamiliar-T3-version-permits-native-configuration")
            }

            try await withFixture { fixture in
                var profiles = try [fixture.profile(.codex, version: "0.160.0"),
                                    fixture.profile(.claudeCode, version: "2.1.0")]
                let original = try fixture.unrelatedSettings()
                for index in profiles.indices {
                    profiles[index].installed = true
                    _ = try fixture.seedOwnedHooks(profiles[index], preserving: original)
                }
                try await fixture.save(profiles)
                let controller = fixture.controller()
                try await controller.load()
                for profile in profiles {
                    try require(await controller.snapshot().states[profile.provider] == .installedUnverified, "saved-version-state")
                    try await controller.remove(profile.provider)
                    try require(try sameJSON(Data(contentsOf: fixture.hooksURL(profile)), original), "unsupported-removal-changed-unrelated")
                }
                let saved = try await fixture.savedProfiles()
                try require(saved.count == 2 && saved.allSatisfy { !$0.installed }, "unsupported-removal-not-persisted")
                try require(Set(saved.map(\.registrationID)) == Set(profiles.map(\.registrationID)), "removal-lost-registration")
            }
            checks.append("unfamiliar-saved-versions-remove-only-owned-hooks")

            for provider in [AgentProvider.codex, .claudeCode] {
                try await withFixture { fixture in
                    let profile = try fixture.profile(provider)
                    let malformed = Data("{malformed-synthetic-settings".utf8)
                    try malformed.write(to: fixture.hooksURL(profile), options: .atomic)
                    let controller = fixture.controller()
                    try await controller.load()
                    try await requireFailure("malformed-install-accepted") { try await controller.install(profile) }
                    try require(try Data(contentsOf: fixture.hooksURL(profile)) == malformed, "malformed-install-overwrote-settings")
                    let saved = try await fixture.savedProfiles()
                    try require(saved.count == 1 && saved[0].installed, "install-attempt-lost-removal-authorization")
                    let expectedHome = provider == .codex
                        ? try CodexResumeProfile(profileID: profile.profileID,
                            homeURL: URL(fileURLWithPath: profile.homePath),
                            executableURL: URL(fileURLWithPath: profile.executablePath)).homeURL.path : profile.homePath
                    try require(saved[0].registrationID == profile.registrationID && saved[0].homePath == expectedHome,
                        "install-attempt-lost-owned-location")
                    let reloaded = fixture.controller()
                    try await reloaded.load()
                    try require(await reloaded.snapshot().profiles[provider]?.installed == true, "install-attempt-not-restored")
                    try require(await reloaded.snapshot().states[provider] == .unavailable, "partial-install-wrong-state")
                    var relocated = profile
                    let newHome = fixture.root.appendingPathComponent("new-\(provider.rawValue)-profile", isDirectory: true)
                    try FileManager.default.createDirectory(at: newHome, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                    relocated.homePath = newHome.path
                    try await requireFailure("partial-install-root-switch-accepted") { try await reloaded.install(relocated) }
                    try require(!FileManager.default.fileExists(atPath: fixture.hooksURL(relocated).path), "root-switch-created-hooks")
                    try await requireFailure("malformed-removal-accepted") { try await reloaded.remove(provider) }
                    try require(try await fixture.savedProfiles().first?.installed == true, "failed-removal-abandoned-location")
                    // Model a surviving owned edit after the failure; removal must use the retained UUID.
                    let original = try fixture.unrelatedSettings()
                    _ = try fixture.seedOwnedHooks(profile, preserving: original)
                    try await reloaded.remove(provider)
                    try require(try sameJSON(Data(contentsOf: fixture.hooksURL(profile)), original), "partial-removal-changed-unrelated")
                    try require(try await fixture.savedProfiles().first?.installed == false, "successful-removal-not-persisted")
                    try await reloaded.install(relocated)
                    try await reloaded.remove(provider)
                    try require(try sameJSON(Data(contentsOf: fixture.hooksURL(relocated)), Data("{}".utf8)),
                        "relocated-removal-left-owned-hooks")
                }
                checks.append("\(provider.rawValue)-failed-install-retains-removal-and-blocks-root-change")
            }

            try await withFixture { fixture in
                let profile = try fixture.profile(.codex)
                let original = try fixture.unrelatedSettings()
                try original.write(to: fixture.hooksURL(profile), options: .atomic)
                let controller = fixture.controller()
                try await controller.load()
                try await controller.install(profile)
                await controller.check()
                try await controller.verify(.codex)
                guard let prompt = await controller.snapshot().verificationPrompts[.codex] else {
                    throw ProbeFailure.failed("missing-synthetic-challenge")
                }
                let (packet, queueID) = try await fixture.durablePacket(profile: profile, prompt: prompt)
                await controller.received(packet, durableQueueID: queueID)
                try require(await controller.snapshot().states[.codex] == .connected, "valid-controller-verification")
                let installed = try Data(contentsOf: fixture.hooksURL(profile))
                try fixture.replaceExecutable(at: URL(fileURLWithPath: profile.executablePath), provider: .codex, version: "0.162.0")
                await controller.check()
                try require(await controller.snapshot().states[.codex] == .connected, "compatible-upgrade-lost-proof")
                try require(await controller.snapshot().profiles[.codex]?.version == "0.162.0", "upgrade-version-not-refreshed")
                try require(await controller.selectedProfiles().count == 1, "compatible-upgrade-not-selected")
                let reloaded = fixture.controller()
                try await reloaded.load()
                try require(await reloaded.snapshot().states[.codex] == .connected, "restart-lost-connection-proof")
                try require(await reloaded.snapshot().profiles[.codex]?.registrationID == profile.registrationID, "upgrade-lost-owned-registration")
                try require(try Data(contentsOf: fixture.hooksURL(profile)) == installed, "version-check-modified-hooks")
                try await reloaded.verify(.codex)
                await reloaded.check()
                let pending = await reloaded.snapshot()
                try require(pending.states[.codex] == .installedUnverified, "saved-proof-hid-new-challenge")
                guard let nextPrompt = pending.verificationPrompts[.codex] else {
                    throw ProbeFailure.failed("missing-reverification-challenge")
                }
                let (nextPacket, nextQueueID) = try await fixture.durablePacket(profile: profile, prompt: nextPrompt)
                await reloaded.received(nextPacket, durableQueueID: nextQueueID)
                try require(await reloaded.snapshot().states[.codex] == .connected, "reverification-not-accepted")
                try require(await reloaded.snapshot().profiles[.codex]?.connectionProof?.durableQueueID == nextQueueID,
                    "reverification-proof-not-replaced")
                try await controller.remove(.codex)
                try require(try sameJSON(Data(contentsOf: fixture.hooksURL(profile)), original), "changed-executable-removal")
            }
            checks.append("compatible-upgrade-and-restart-preserve-owned-registration-and-proof")

            try await withFixture { fixture in
                let profile = try fixture.profile(.codex)
                let controller = fixture.controller()
                try await controller.load()
                try await controller.install(profile)
                try await controller.verify(.codex)
                guard let prompt = await controller.snapshot().verificationPrompts[.codex] else {
                    throw ProbeFailure.failed("missing-pending-challenge")
                }
                let (packet, queueID) = try await fixture.durablePacket(profile: profile, prompt: prompt)
                try fixture.replaceExecutable(at: URL(fileURLWithPath: profile.executablePath), provider: .codex, version: "0.162.0")
                // A release change leaves the same registration and one-use challenge applicable.
                await controller.received(packet, durableQueueID: queueID)
                let snapshot = await controller.snapshot()
                try require(snapshot.states[.codex] == .connected, "compatible-upgrade-rejected-pending-challenge")
                try require(snapshot.verificationPrompts[.codex] == nil, "changed-executable-retained-challenge")
                try require(await controller.selectedProfiles().count == 1, "verified-upgrade-not-selected")
                try await controller.remove(.codex)
            }
            checks.append("compatible-executable-change-preserves-pending-registration-challenge")

            for provider in AgentProvider.allCases {
                for transport in [AgentInterface.standaloneCLI, .t3] {
                    for schema in [1, 2] {
                        try await withFixture { fixture in
                            let profile = try fixture.profile(provider, interface: transport)
                            let unrelated = try fixture.unrelatedSettings()
                            try unrelated.write(to: fixture.hooksURL(profile), options: .atomic)
                            let original = fixture.controller()
                            try await original.load()
                            try await original.install(profile)
                            let inventory = try await MigrationInventoryAssertions.seed(
                                store: fixture.store, cryptography: fixture.cryptography, profile: profile)
                            try await original.verify(provider)
                            guard let prompt = await original.snapshot().verificationPrompts[provider] else {
                                throw ProbeFailure.failed("legacy-migration-challenge-unavailable")
                            }
                            let (packet, queueID) = try await fixture.durablePacket(profile: profile, prompt: prompt)
                            await original.received(packet, durableQueueID: queueID)
                            guard let verified = await original.snapshot().profiles[provider], verified.connectionProof != nil else {
                                throw ProbeFailure.failed("legacy-migration-proof-unavailable")
                            }
                            let installed = try Data(contentsOf: fixture.hooksURL(profile))
                            let queued = try await fixture.store.captureIdentitiesForTesting()
                            try await fixture.save([verified], schemaVersion: schema)
                            try await fixture.reopenStore()
                            let migrated = fixture.controller()
                            try await migrated.load()
                            let snapshot = await migrated.snapshot()
                            guard let restored = snapshot.profiles[provider] else {
                                throw ProbeFailure.failed("legacy-migration-profile-unavailable")
                            }
                            try require(snapshot.states[provider] == .connected && restored == verified,
                                "legacy-migration-changed-registration-profile-or-proof")
                            try require(restored.authorizedHosts == [.standaloneCLI, .t3]
                                && restored.interface == transport, "legacy-migration-confused-host-with-transport")
                            try require(try Data(contentsOf: fixture.hooksURL(profile)) == installed,
                                "legacy-migration-edited-provider-hooks")
                            try require(try await fixture.store.captureIdentitiesForTesting().pending == queued.pending,
                                "legacy-migration-lost-pending-capture")
                            guard let permit = await fixture.store.processingPermit(),
                                  let capture = try await fixture.store.nextPending(at: .now, permit: permit) else {
                                throw ProbeFailure.failed("legacy-migration-encrypted-capture-unavailable")
                            }
                            let opened = try await fixture.store.openCapture(capture)
                            try require(capture.id == queueID && opened == packet.body,
                                "legacy-migration-changed-encrypted-capture-body")
                            guard let saved = try await fixture.store.protectedPreference(.agentProfiles) else {
                                throw ProbeFailure.failed("legacy-migration-preference-unavailable")
                            }
                            try require(try JSONDecoder().decode(SavedProfiles.self, from: saved).schemaVersion == 3,
                                "legacy-migration-schema-not-persisted")
                            let roundTrip = try JSONDecoder().decode(AgentProfileDraft.self, from: JSONEncoder().encode(restored))
                            try require(roundTrip == restored, "schema3-round-trip-changed-authorization-or-proof")
                            try await migrated.authorizeHosts([transport], for: provider)
                            let restricted = await migrated.snapshot().profiles[provider]
                            try require(restricted?.authorizedHosts == [transport]
                                && restricted?.connectionProof == verified.connectionProof,
                                "host-authorization-update-lost-registration-proof")
                            try await migrated.authorizeHosts([.standaloneCLI, .t3], for: provider)
                            try require(await migrated.snapshot().profiles[provider] == verified,
                                "adding-host-created-a-different-canonical-profile")
                            let other: AgentInterface = transport == .t3 ? .standaloneCLI : .t3
                            try await requireFailure("shared-transport-removal-accepted") {
                                try await migrated.authorizeHosts([other], for: provider)
                            }
                            try await requireFailure("empty-host-authorization-accepted") {
                                try await migrated.authorizeHosts([], for: provider)
                            }
                            do {
                                try await migrated.authorizeHosts([transport, .desktopCode], for: provider)
                                let optedIn = await migrated.snapshot().profiles[provider]
                                try require(optedIn?.authorizedHosts == [transport, .desktopCode]
                                    && optedIn?.profileID == verified.profileID
                                    && optedIn?.interface == verified.interface
                                    && optedIn?.registrationID == verified.registrationID
                                    && optedIn?.connectionProof == verified.connectionProof
                                    && (try Data(contentsOf: fixture.hooksURL(profile))) == installed,
                                    "desktop-opt-in-changed-canonical-profile-registration-proof-or-hooks")
                                let optedInReload = fixture.controller()
                                try await optedInReload.load()
                                try require(await optedInReload.snapshot().profiles[provider] == optedIn,
                                    "desktop-opt-in-restart-lost-host-authorization-or-proof")
                                try await migrated.authorizeHosts([.standaloneCLI, .t3], for: provider)
                                var configured = verified
                                configured.authorizedHosts.insert(.desktopCode)
                                try await migrated.install(configured)
                                let configuredSnapshot = await migrated.snapshot()
                                try require(configuredSnapshot.profiles[provider] == configured
                                    && configuredSnapshot.states[provider] == .connected
                                    && (try Data(contentsOf: fixture.hooksURL(profile))) == installed,
                                    "desktop-configure-save-changed-owned-profile-proof-or-hooks")
                                let configuredReload = fixture.controller()
                                try await configuredReload.load()
                                try require(await configuredReload.snapshot().profiles[provider] == configured,
                                    "desktop-configure-save-restart-lost-authorization-or-proof")
                                try await migrated.authorizeHosts([.standaloneCLI, .t3], for: provider)
                            }
                            var changedTransport = restored
                            changedTransport.interface = other
                            try await requireFailure("installed-registration-transport-switch-accepted") {
                                try await migrated.install(changedTransport)
                            }
                            try require(await migrated.snapshot().profiles[provider] == verified
                                && (try Data(contentsOf: fixture.hooksURL(profile))) == installed,
                                "rejected-host-change-modified-owned-registration")
                            try await inventory.assertPreserved(in: fixture.store)
                            try await inventory.replay(in: fixture.store, profile: restored,
                                cryptography: fixture.cryptography)
                            try await fixture.reopenStore()
                            let reloaded = fixture.controller()
                            try await reloaded.load()
                            let finalSnapshot = await reloaded.snapshot()
                            try require(finalSnapshot.profiles[provider] == verified
                                && finalSnapshot.states[provider] == .connected,
                                "schema3-restart-lost-proof-or-host-authorization")
                            try await inventory.assertPreserved(in: fixture.store)
                            try require(try await fixture.store.captureIdentitiesForTesting().pending == queued.pending,
                                "schema3-restart-lost-pending-verification-capture")
                            if provider == .claudeCode {
                                try await fixture.assertCanonicalClaudeReplay(before: verified, after: restored)
                            }
                        }
                        checks.append("\(provider.rawValue)-schema\(schema)-\(transport.rawValue)-migration-preserves-owned-proof-native-profile-and-queue")
                        checks.append("\(provider.rawValue)-schema\(schema)-\(transport.rawValue)-migration-restart-replay-preserves-review-obsolete-marker-receipts-and-alerts")
                    }
                }
            }

            try await withFixture { fixture in
                var legacyDesktop = try fixture.profile(.claudeCode, interface: .desktopCode)
                legacyDesktop.installed = true
                let unrelated = try fixture.unrelatedSettings()
                var legacyOwnership = legacyDesktop
                legacyOwnership.interface = .standaloneCLI
                let installed = try fixture.seedOwnedHooks(legacyOwnership, preserving: unrelated)
                try await fixture.save([legacyDesktop], schemaVersion: 2)
                let controller = fixture.controller()
                try await controller.load()
                let snapshot = await controller.snapshot()
                try require(snapshot.profiles[.claudeCode]?.authorizedHosts.isEmpty == true
                    && snapshot.profiles[.claudeCode]?.profileID == legacyDesktop.profileID
                    && snapshot.profiles[.claudeCode]?.registrationID == legacyDesktop.registrationID,
                    "legacy-desktop-auto-authorized-new-host-or-lost-ownership")
                try require(await controller.selectedProfiles().isEmpty
                    && (try Data(contentsOf: fixture.hooksURL(legacyDesktop))) == installed,
                    "legacy-desktop-migration-enabled-collection-or-edited-hooks")
                try await controller.remove(.claudeCode)
                try require(try sameJSON(Data(contentsOf: fixture.hooksURL(legacyDesktop)), unrelated),
                    "legacy-desktop-removal-lost-owned-location")
                var explicit = legacyDesktop
                explicit.authorizedHosts = [.desktopCode]
                try await fixture.save([explicit], schemaVersion: 3)
                let explicitController = fixture.controller()
                try await explicitController.load()
                try require(await explicitController.snapshot().profiles[.claudeCode] == explicit,
                    "explicit-claude-desktop-authorization-did-not-round-trip")
                var invalid = explicit
                invalid.authorizedHosts = [.standaloneCLI]
                try await fixture.save([invalid], schemaVersion: 3)
                try await requireFailure("persisted-desktop-missing-owned-transport-decoded") {
                    try await fixture.controller().load()
                }
            }
            checks.append("legacy-desktop-remains-uncollected-until-explicit-authorization-with-owned-removal")

            try await withFixture { fixture in
                var legacy = try fixture.profile(.codex, interface: .desktopCode)
                legacy.installed = true
                let unrelated = try fixture.unrelatedSettings()
                var oldTransport = legacy
                oldTransport.interface = .standaloneCLI
                let originalHooks = try fixture.seedOwnedHooks(oldTransport, preserving: unrelated)
                try await fixture.save([legacy], schemaVersion: 2)
                let controller = fixture.controller()
                try await controller.load()
                let initial = await controller.snapshot()
                let initiallySelected = await controller.selectedProfiles()
                try require(initial.profiles[.codex]?.authorizedHosts.isEmpty == true
                    && initial.profiles[.codex]?.requiresDesktopDeliveryRoute == false
                    && initial.states[.codex] == .unsupported
                    && initiallySelected.isEmpty
                    && (try Data(contentsOf: fixture.hooksURL(legacy))) == originalHooks,
                    "legacy-codex-desktop-auto-enabled-or-prevented-explicit-opt-in")
                try await requireFailure("legacy-codex-desktop-installed-without-opt-in") {
                    try await controller.install(legacy)
                }
                var optedIn = legacy
                optedIn.authorizedHosts = [.desktopCode]
                try await controller.install(optedIn)
                let installed = await controller.snapshot()
                let selected = await controller.selectedProfiles()
                try require(installed.profiles[.codex]?.profileID == legacy.profileID
                    && installed.profiles[.codex]?.registrationID == legacy.registrationID
                    && installed.profiles[.codex]?.requiresDesktopDeliveryRoute == true
                    && installed.profiles[.codex]?.authorizedHosts == [.desktopCode]
                    && installed.states[.codex] == .installedUnverified
                    && selected.count == 1,
                    "explicit-codex-desktop-install-lost-ownership-or-invented-proof")
                try await controller.verify(.codex)
                guard let prompt = await controller.snapshot().verificationPrompts[.codex] else {
                    throw ProbeFailure.failed("codex-desktop-delivery-verification-missing")
                }
                let (packet, queueID) = try await fixture.durablePacket(profile: optedIn, prompt: prompt)
                await controller.received(packet, durableQueueID: queueID)
                let verified = await controller.snapshot().profiles[.codex]
                try require(await controller.snapshot().states[.codex] == .connected
                    && verified?.connectionProof?.durableQueueID == queueID,
                    "codex-desktop-durable-delivery-proof-rejected")
                try await fixture.reopenStore()
                let reloaded = fixture.controller()
                try await reloaded.load()
                let restarted = await reloaded.snapshot()
                try require(restarted.profiles[.codex] == verified
                    && restarted.states[.codex] == .connected,
                    "codex-desktop-restart-expanded-authorization-or-lost-proof")
                try await reloaded.remove(.codex)
                try require(try sameJSON(Data(contentsOf: fixture.hooksURL(legacy)), unrelated),
                    "codex-desktop-removal-damaged-unowned-hooks")
            }
            checks.append("legacy-codex-desktop-needs-explicit-opt-in-preserves-ownership-and-verifies-shared-delivery")

            try await withFixture { fixture in
                let profile = try fixture.profile(.codex)
                let controller = fixture.controller()
                try await controller.load()
                try await controller.install(profile)
                let previous = await controller.snapshot()
                let hooks = try Data(contentsOf: fixture.hooksURL(profile))
                try await fixture.store.close()
                try await requireFailure("failed-codex-desktop-authorization-save-reported-success") {
                    try await controller.authorizeHosts([.standaloneCLI, .t3, .desktopCode], for: .codex)
                }
                guard var edited = previous.profiles[.codex] else {
                    throw ProbeFailure.failed("failed-opt-in-prior-profile-missing")
                }
                edited.authorizedHosts.insert(.desktopCode)
                try await requireFailure("failed-codex-desktop-install-save-reported-success") {
                    try await controller.install(edited)
                }
                let failed = await controller.snapshot()
                try require(failed.profiles == previous.profiles && failed.states == previous.states
                    && (try Data(contentsOf: fixture.hooksURL(profile))) == hooks,
                    "failed-codex-desktop-authorization-save-expanded-collection-or-edited-hooks")
            }
            checks.append("failed-codex-desktop-opt-in-save-preserves-prior-authorization-and-provider-hooks")

            try await withFixture { fixture in
                let profile = try fixture.profile(.claudeCode)
                let controller = fixture.controller()
                try await controller.load()
                try await controller.install(profile)
                let before = await controller.snapshot()
                guard let saved = try await fixture.store.protectedPreference(.agentProfiles) else {
                    throw ProbeFailure.failed("schema3-guard-preference-unavailable")
                }
                var object = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
                object["profiles"] = (object["profiles"] as! [[String: Any]]).map { value in
                    var missing = value
                    missing.removeValue(forKey: "authorizedHosts")
                    return missing
                }
                try await fixture.store.setProtectedPreference(JSONSerialization.data(withJSONObject: object), for: .agentProfiles)
                try await requireFailure("damaged-schema3-broadened-host-authorization") {
                    try await fixture.controller().load()
                }
                try await fixture.store.close()
                try await requireFailure("failed-host-preference-write-reported-success") {
                    try await controller.authorizeHosts([.standaloneCLI], for: .claudeCode)
                }
                let after = await controller.snapshot()
                try require(after.profiles == before.profiles && after.states == before.states,
                    "failed-host-preference-write-changed-in-memory-authorization")
            }
            checks.append("schema3-does-not-infer-missing-authorization-and-failed-update-rolls-back")

            try await withFixture { fixture in
                var profile = try fixture.profile(.claudeCode)
                profile.executablePath = ""
                let baseline = try fixture.savedData([profile], schemaVersion: 2)
                profile.executablePath = String(repeating: "x", count: ProtectedPreferenceKey.maximumBytes - baseline.count - 8)
                let legacy = try fixture.savedData([profile], schemaVersion: 2)
                try require(legacy.count < ProtectedPreferenceKey.maximumBytes,
                    "bounded-legacy-migration-failure-fixture-too-large")
                try await fixture.store.setProtectedPreference(legacy, for: .agentProfiles)
                let controller = fixture.controller()
                try await requireFailure("oversized-schema3-migration-reported-success") {
                    try await controller.load()
                }
                let snapshot = await controller.snapshot()
                let retained = try await fixture.store.protectedPreference(.agentProfiles)
                try require(snapshot.profiles.isEmpty && snapshot.states.isEmpty
                    && retained == legacy,
                    "failed-legacy-migration-published-or-overwrote-uncommitted-configuration")
            }
            checks.append("failed-legacy-migration-keeps-original-encrypted-preference-and-unpublished-status")

            try await withFixture { fixture in
                let profile = try fixture.profile(.claudeCode)
                let model = AppModel()
                model.storageReady = true
                model.agentProfiles[.claudeCode] = profile
                model.agentSetupStates[.claudeCode] = .connected
                let cli = CollectionScope(provider: .claudeCode, profileID: profile.profileID,
                    interface: .standaloneCLI, path: .versionedTranscript)
                let t3 = CollectionScope(provider: .claudeCode, profileID: profile.profileID,
                    interface: .t3, path: .versionedTranscript)
                let unowned = CollectionScope(provider: .claudeCode, profileID: "different-native-profile",
                    interface: .t3, path: .versionedTranscript)
                let gap = CoverageGap(reason: .malformedSource, scope: cli, contentType: .toolOutput,
                    isRequiredFormatFailure: true)
                model.collectionAssessments[cli] = .init(scope: cli, usableOperations: [.liveRead],
                    unavailableContent: [.toolOutput], failures: [.init(reason: .changedContentFormat, contentType: .toolOutput)])
                model.collectionAssessments[t3] = .init(scope: t3, usableOperations: [.liveRead, .historicalRead])
                model.collectionAssessments[unowned] = .init(scope: unowned,
                    failures: [.init(reason: .sourceUnavailable)])
                model.collectionLimitations = [gap]
                guard let route = model.routes.first(where: { $0.provider == .claudeCode }) else {
                    throw ProbeFailure.failed("scoped-host-route-unavailable")
                }
                try require(route.hostRoutes.count == 1 && route.hostRoutes.first?.sharedProfile == true
                    && route.assessments.count == 2 && route.collecting,
                    "scoped-host-status-lost-usable-route-or-mixed-native-profile")
                try require(route.hostRoutes.first?.status == .partial
                    && route.assessments.first(where: { $0.scope.interface == .t3 })?.status == .compatible
                    && route.limitations.allSatisfy { $0.scope?.interface == .standaloneCLI },
                    "required-format-failure-spread-to-unaffected-transport")
                model.collectionAssessments.removeAll()
                let unobserved = model.routes.first(where: { $0.provider == .claudeCode })!
                try require(!unobserved.collecting && unobserved.hostRoutes.allSatisfy { !$0.collecting },
                    "shared-registration-proof-invented-host-observation")
                try require(model.coverageSummaryText == "Registration verified · waiting for content",
                    "verified-registration-displayed-as-unverified-before-live-observation")

                let identity = try SourceIdentity(session: SessionIdentity(provider: .claudeCode,
                    profileID: profile.profileID, sessionID: "coverage-summary-fixture"), itemID: "prompt")
                let source = try SourceRecord(metadata: SourceRecordMetadata(identity: identity,
                    contentType: .userPrompt, contentTime: .now, observedAt: .now,
                    origin: SourceOrigin(adapterID: "coverage-summary", adapterVersion: "1",
                        agentVersion: "synthetic", interface: .standaloneCLI, provenance: .live,
                        canonicalization: .sharedUpstreamIdentity)),
                    revision: ContentRevision(keyedDigest: Data(repeating: 1, count: 32)),
                    segments: [SourceSegment(id: "text", utf8: Data("synthetic prompt".utf8))])
                var ledger = InventoryLedger()
                _ = try ledger.ingest(SourceAnalysis(source: source, detectorVersion: "fixture", detections: []))
                model.loadSnapshot(ledger.snapshot)
                try require(!model.monitoringProven && model.coverageSummaryText.hasPrefix("1 message analyzed"),
                    "analyzed-history-hidden-without-current-live-observation")
                model.agentSetupStates[.claudeCode] = .installedUnverified
                try require(model.coverageSummaryText.hasPrefix("1 message analyzed"),
                    "historical-analysis-hidden-after-registration-needs-verification")
                model.loadSnapshot(InventoryLedger().snapshot)
                try require(model.coverageSummaryText == "Verify an agent to start monitoring",
                    "unverified-empty-profile-claimed-analysis")
                model.agentSetupStates[.claudeCode] = .connected

                let selected = fixture.root.appendingPathComponent("native-session.jsonl")
                let claudeArgs = ["--claude-profile", profile.profileID, "--claude-version", "2.1.295",
                    "--claude-source-root", fixture.root.path, "--claude-authorized-host", "standalone-cli"]
                try require(try CollectionConfiguration.fromArguments(claudeArgs)?.authorizedHosts == [.standaloneCLI],
                    "claude-runtime-configuration-ignored-authorized-hosts")
                try await requireFailure("claude-runtime-selected-unauthorized-host") {
                    _ = try CollectionConfiguration.fromArguments(claudeArgs + ["--claude-interface", "t3",
                        "--claude-active-source", selected.path, "--claude-session", "native-session"])
                }
                let claudeDesktopArgs = ["--claude-profile", profile.profileID, "--claude-version", "2.1.296",
                    "--claude-source-root", fixture.root.path, "--claude-interface", "desktop-code",
                    "--claude-active-source", selected.path, "--claude-session", "native-session"]
                try await requireFailure("claude-runtime-default-auto-authorized-desktop") {
                    _ = try CollectionConfiguration.fromArguments(claudeDesktopArgs)
                }
                try await requireFailure("claude-runtime-history-only-default-auto-authorized-desktop") {
                    _ = try CollectionConfiguration.fromArguments(Array(claudeDesktopArgs.prefix(8)))
                }
                let claudeDesktop = try CollectionConfiguration.fromArguments(claudeDesktopArgs
                    + ["--claude-authorized-host", "desktop-code"])
                try require(claudeDesktop?.authorizedHosts == [.desktopCode]
                    && claudeDesktop?.activeSources.first?.interface == .desktopCode
                    && claudeDesktop?.historicalInterface == .desktopCode,
                    "claude-runtime-explicit-desktop-lost-selected-source-or-history-route")
                let claudeSharedDesktop = try CollectionConfiguration.fromArguments(claudeDesktopArgs
                    + ["--claude-authorized-host", "desktop-code", "--claude-authorized-host", "standalone-cli"])
                try require(claudeSharedDesktop?.authorizedHosts == [.standaloneCLI, .desktopCode]
                    && claudeSharedDesktop?.historicalInterface == .standaloneCLI,
                    "claude-runtime-desktop-retagged-shared-profile-history")
                let codexArgs = ["--codex-profile", profile.profileID, "--codex-version", "0.161.0",
                    "--codex-home", fixture.root.path, "--codex-executable", profile.executablePath,
                    "--codex-authorized-host", "t3", "--codex-interface", "t3"]
                try require(try CodexCollectionConfiguration.fromArguments(codexArgs)?.authorizedHosts == [.t3],
                    "codex-runtime-configuration-ignored-authorized-hosts")
                try await requireFailure("codex-runtime-selected-unauthorized-transport") {
                    var unauthorized = codexArgs
                    unauthorized[unauthorized.count - 1] = "standalone-cli"
                    _ = try CodexCollectionConfiguration.fromArguments(unauthorized)
                }
                let desktopArgs = ["--codex-profile", profile.profileID, "--codex-version", "0.162.1",
                    "--codex-home", fixture.root.path, "--codex-executable", profile.executablePath,
                    "--codex-interface", "desktop-code"]
                try await requireFailure("codex-runtime-default-auto-authorized-desktop") {
                    _ = try CodexCollectionConfiguration.fromArguments(desktopArgs)
                }
                let explicitDesktop = desktopArgs + ["--codex-authorized-host", "desktop-code"]
                let desktop = try CodexCollectionConfiguration.fromArguments(explicitDesktop
                    + ["--codex-active-thread", "fake-native-main"])
                try require(desktop?.authorizedHosts == [.desktopCode] && desktop?.interface == .desktopCode
                    && desktop?.authority == .publicNativeItems && desktop?.t3Version == nil
                    && desktop?.activeSources.first?.threadID == "fake-native-main",
                    "codex-runtime-explicit-desktop-selection-lost-native-authority")
                try await requireFailure("codex-runtime-desktop-selected-transcript-authority") {
                    _ = try CodexCollectionConfiguration.fromArguments(explicitDesktop
                        + ["--codex-authority", CodexCollectionAuthority.nativeRolloutTranscript.rawValue])
                }
                let adapter = try ClaudeAdapter(profileID: profile.profileID, agentVersion: "2.1.295", allowedTranscriptRoots: [])
                let audit = try HistoricalAuditContext(reason: .firstLaunch, endingAt: .now)
                let originalHistory = try await adapter.initialHistoricalCapture(audit: audit)
                let fixedProducer = FixedHistoricalCaptureProducer(packet: originalHistory, expectedAudit: audit)
                for interface in [AgentInterface.standaloneCLI, .t3, .desktopCode] {
                    let wrapper = AuthorizedHistoricalCaptureProducer(producer: fixedProducer, provider: .claudeCode,
                        profileID: profile.profileID, interface: interface)
                    let history = try await wrapper.initialHistoricalCapture(audit: audit)
                    try require(history.metadata.interface == interface && history.eventJSON == originalHistory.eventJSON
                        && (try ClaudeAdapter.historicalAuditForTesting(in: history)) == audit,
                        "authorized-history-transport-changed-request-or-audit")
                    let router = try CollectionRouter(routes: [.init(provider: .claudeCode,
                        profileID: profile.profileID, interface: interface, normalizer: adapter)])
                    let batch = try await router.normalize(history, capturedAt: .now, cryptography: fixture.cryptography)
                    try require(batch.coverageGaps.isEmpty && batch.historicalProgress != nil,
                        "authorized-history-request-not-routable")
                }
            }
            checks.append("authorized-host-runtime-selection-and-scoped-status-do-not-infer-host-connection")
            checks += try await codexProfileHomeAssertions()
            checks += try await sourceOpeningAssertions()
            checks += try startupDiagnosticsAssertions()
            checks += try vaultOwnerDiagnosticsAssertions()
            checks += try coveragePresentationAssertions()
            checks += try await coverageRestartAssertions()
            checks += try collectionAssessmentAssertions()
            checks += try storageCapacityAssertions()
            checks += try await schemaOneWithoutConnectionProofAssertions()
            assertionGroup = "inventory-state-acceptance-assertions"
            checks += try await inventoryStateAcceptanceAssertions()
            checks += try await webResultAcceptanceAssertions()
            checks += try await nativeContentAcceptanceAssertions()
            assertionGroup = "review-acceptance-assertions"
            checks += try reviewAcceptanceAssertions()
            assertionGroup = "desktop-beta-acceptance-assertions"
            checks += try desktopBetaAcceptanceAssertions()

            let report: [String: Any] = ["passed": true, "checks": checks, "checkCount": checks.count,
                "systemAuthentication": "not-exercised-ephemeral-testing-keys", "providerSessionsStarted": 0,
                "hookHelperExecutions": 0, "credentialsRead": false, "profiles": "owned-disposable",
                "verificationEvidence": "synthetic-controller-contract-with-durable-enqueue"]
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        } catch {
            let stage: String
            if case ProbeFailure.failed(let name) = error { stage = name }
            else if case MigrationInventoryAssertionFailure.failed(let name) = error { stage = name }
            else if case InventoryStateAssertionFailure.failed(let name) = error { stage = name }
            else if let failure = error as? InventoryStateAcceptance.Failure {
                stage = "inventory-state-helper-" + failure.rawValue
            }
            else if case StartupDiagnosticAssertionFailure.failed(let name) = error { stage = name }
            else if case VaultOwnerDiagnosticAssertionFailure.failed(let name) = error { stage = name }
            else if case StorageCapacityAssertionFailure.failed(let name) = error { stage = name }
            else if case SourceOpeningAssertionFailure.failed(let name) = error { stage = name }
            else if case CollectionAssessmentAssertionFailure.failed(let name) = error { stage = name }
            else if case ReviewAssertionFailure.failed(let name) = error { stage = name }
            else if case NativeAssertionFailure.failed(let name) = error { stage = name }
            else if case DesktopBetaAssertionFailure.failed(let name) = error { stage = name }
            else { stage = assertionGroup }
            let report: [String: Any] = ["passed": false, "failure": stage]
            if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                print(String(decoding: bytes, as: UTF8.self))
            }
            exit(1)
        }
    }
}
