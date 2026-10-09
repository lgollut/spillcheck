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
                            try await requireFailure("desktop-host-authorization-accepted") {
                                try await migrated.authorizeHosts([transport, .desktopCode], for: provider)
                            }
                            var changedTransport = restored
                            changedTransport.interface = other
                            try await requireFailure("installed-registration-transport-switch-accepted") {
                                try await migrated.install(changedTransport)
                            }
                            try require(await migrated.snapshot().profiles[provider] == verified
                                && (try Data(contentsOf: fixture.hooksURL(profile))) == installed,
                                "rejected-host-change-modified-owned-registration")
                            if provider == .claudeCode {
                                try await fixture.assertCanonicalClaudeReplay(before: verified, after: restored)
                            }
                            let reloaded = fixture.controller()
                            try await reloaded.load()
                            let finalSnapshot = await reloaded.snapshot()
                            try require(finalSnapshot.profiles[provider] == verified
                                && finalSnapshot.states[provider] == .connected,
                                "schema3-restart-lost-proof-or-host-authorization")
                        }
                        checks.append("\(provider.rawValue)-schema\(schema)-\(transport.rawValue)-migration-preserves-owned-proof-native-profile-and-queue")
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
                var invalid = legacyDesktop
                invalid.authorizedHosts = [.desktopCode]
                try await fixture.save([invalid], schemaVersion: 3)
                try await requireFailure("persisted-desktop-authorization-decoded") {
                    try await fixture.controller().load()
                }
            }
            checks.append("legacy-desktop-remains-uncollected-with-owned-removal-and-invalid-host-rejection")

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
                try require(route.hostRoutes.count == 2 && route.assessments.count == 2 && route.collecting,
                    "scoped-host-status-lost-usable-route-or-mixed-native-profile")
                try require(route.hostRoutes.first(where: { $0.interface == .standaloneCLI })?.status == .partial
                    && route.hostRoutes.first(where: { $0.interface == .t3 })?.status == .compatible
                    && route.hostRoutes.first(where: { $0.interface == .t3 })?.limitations.isEmpty == true,
                    "required-format-failure-spread-to-unaffected-host")
                model.collectionAssessments.removeAll()
                let unobserved = model.routes.first(where: { $0.provider == .claudeCode })!
                try require(!unobserved.collecting && unobserved.hostRoutes.allSatisfy { !$0.collecting },
                    "shared-registration-proof-invented-host-observation")

                let selected = fixture.root.appendingPathComponent("native-session.jsonl")
                let claudeArgs = ["--claude-profile", profile.profileID, "--claude-version", "2.1.295",
                    "--claude-source-root", fixture.root.path, "--claude-authorized-host", "standalone-cli"]
                try require(try CollectionConfiguration.fromArguments(claudeArgs)?.authorizedHosts == [.standaloneCLI],
                    "claude-runtime-configuration-ignored-authorized-hosts")
                try await requireFailure("claude-runtime-selected-unauthorized-host") {
                    _ = try CollectionConfiguration.fromArguments(claudeArgs + ["--claude-interface", "t3",
                        "--claude-active-source", selected.path, "--claude-session", "native-session"])
                }
                try await requireFailure("claude-runtime-authorized-desktop") {
                    _ = try CollectionConfiguration.fromArguments(claudeArgs + ["--claude-authorized-host", "desktop-code"])
                }
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
                let adapter = try ClaudeAdapter(profileID: profile.profileID, agentVersion: "2.1.295", allowedTranscriptRoots: [])
                let audit = try HistoricalAuditContext(reason: .firstLaunch, endingAt: .now)
                let originalHistory = try await adapter.initialHistoricalCapture(audit: audit)
                for interface in [AgentInterface.standaloneCLI, .t3] {
                    let wrapper = AuthorizedHistoricalCaptureProducer(producer: adapter, provider: .claudeCode,
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
