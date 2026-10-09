import Foundation
@_spi(Testing) import SpillcheckCore

private enum ProbeFailure: Error {
    case failed(String)
}

private struct SavedProfiles: Codable {
    let schemaVersion: Int
    let profiles: [AgentProfileDraft]
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
    let store: ProtectedStore
    let helper: URL
    let socket: URL
    let helperMarker: URL
    let providerLog: URL

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

    func save(_ profiles: [AgentProfileDraft]) async throws {
        try await store.setProtectedPreference(JSONEncoder().encode(SavedProfiles(schemaVersion: 1, profiles: profiles)),
            for: .agentProfiles)
    }

    func savedProfiles() async throws -> [AgentProfileDraft] {
        guard let bytes = try await store.protectedPreference(.agentProfiles) else {
            throw ProbeFailure.failed("missing-protected-profile")
        }
        return try JSONDecoder().decode(SavedProfiles.self, from: bytes).profiles
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

@main
private struct AgentSetupProbe {
    @MainActor static func main() async {
        do {
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
                    try require(await controller.snapshot().states[.codex] == .unsupported, "unsupported-t3-state")
                    try require(await controller.selectedProfiles().isEmpty, "unsupported-t3-selected")
                    try await requireFailure("unsupported-t3-install-accepted") { try await controller.install(profile) }
                    try await requireFailure("unsupported-t3-verification-accepted") { try await controller.verify(.codex) }
                    try require(try Data(contentsOf: fixture.hooksURL(profile)) == owned, "unsupported-t3-modified-hooks")
                }
                checks.append(t3Version == nil ? "missing-T3-version-rejects-install-and-verification"
                    : "unsupported-T3-version-rejects-install-and-verification")
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
                    try require(await controller.snapshot().states[profile.provider] == .unsupported, "saved-version-state")
                    try await controller.remove(profile.provider)
                    try require(try sameJSON(Data(contentsOf: fixture.hooksURL(profile)), original), "unsupported-removal-changed-unrelated")
                }
                let saved = try await fixture.savedProfiles()
                try require(saved.count == 2 && saved.allSatisfy { !$0.installed }, "unsupported-removal-not-persisted")
                try require(Set(saved.map(\.registrationID)) == Set(profiles.map(\.registrationID)), "removal-lost-registration")
            }
            checks.append("unsupported-saved-Codex-and-Claude-registrations-remove-only-owned-hooks")

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
                    try require(saved[0].registrationID == profile.registrationID && saved[0].homePath == profile.homePath,
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
                try require(await controller.snapshot().states[.codex] == .unsupported, "changed-executable-still-connected")
                try require(await controller.selectedProfiles().isEmpty, "changed-executable-selected")
                try await requireFailure("changed-executable-verification-accepted") { try await controller.verify(.codex) }
                try require(try Data(contentsOf: fixture.hooksURL(profile)) == installed, "version-check-modified-hooks")
                try await controller.remove(.codex)
                try require(try sameJSON(Data(contentsOf: fixture.hooksURL(profile)), original), "changed-executable-removal")
            }
            checks.append("changed-executable-invalidates-connected-state-and-verification")

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
                // No explicit check between replacement and receipt: received must reject stale state.
                await controller.received(packet, durableQueueID: queueID)
                let snapshot = await controller.snapshot()
                try require(snapshot.states[.codex] == .unsupported, "changed-executable-accepted-pending-challenge")
                try require(snapshot.verificationPrompts[.codex] == nil, "changed-executable-retained-challenge")
                try require(await controller.selectedProfiles().isEmpty, "stale-verification-selected-profile")
                try await controller.remove(.codex)
            }
            checks.append("executable-change-during-challenge-cannot-promote-stale-delivery")

            let report: [String: Any] = ["passed": true, "checks": checks, "checkCount": checks.count,
                "systemAuthentication": "not-exercised-ephemeral-testing-keys", "providerSessionsStarted": 0,
                "hookHelperExecutions": 0, "credentialsRead": false, "profiles": "owned-disposable",
                "verificationEvidence": "synthetic-controller-contract-with-durable-enqueue"]
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        } catch {
            let stage: String
            if case ProbeFailure.failed(let name) = error { stage = name }
            else { stage = "agent-setup-probe" }
            let report: [String: Any] = ["passed": false, "failure": stage]
            if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                print(String(decoding: bytes, as: UTF8.self))
            }
            exit(1)
        }
    }
}
