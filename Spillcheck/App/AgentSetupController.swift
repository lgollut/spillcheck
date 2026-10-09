import Foundation
import SpillcheckCore
import Darwin

struct AgentSetupSnapshot: Sendable {
    let profiles: [AgentProvider: AgentProfileDraft]
    let states: [AgentProvider: AgentSetupState]
    let messages: [AgentProvider: String]
    let verificationPrompts: [AgentProvider: String]
}

private struct SavedAgentProfiles: Codable {
    let schemaVersion: Int
    let profiles: [AgentProfileDraft]

    private struct RequiredAuthorization: Decodable { let authorizedHosts: Set<AgentInterface> }
    private enum CodingKeys: String, CodingKey { case schemaVersion, profiles }

    init(schemaVersion: Int, profiles: [AgentProfileDraft]) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        // Only legacy schemas may infer the shared-home default. A damaged new record
        // must not broaden a previously saved subset of authorized hosts.
        if schemaVersion >= 3 { _ = try values.decode([RequiredAuthorization].self, forKey: .profiles) }
        profiles = try values.decode([AgentProfileDraft].self, forKey: .profiles)
    }
}

/// Profile selection and owned hook edits are explicit settings actions. Discovery only probes
/// the executable's version; it does not open histories or install configuration.
actor AgentSetupController {
    private let store: ProtectedStore
    private let helperURL: URL
    private let socketURL: URL
    private var profiles: [AgentProvider: AgentProfileDraft] = [:]
    private var states: [AgentProvider: AgentSetupState] = [:]
    private var messages: [AgentProvider: String] = [:]
    private var prompts: [AgentProvider: String] = [:]
    private var claude: ClaudeHookSetup?
    private var codex: CodexHookSetup?
    private var executableProbes: [AgentProvider: (signature: String, version: String?, probedAt: TimeInterval)] = [:]
    private var changedExecutables: Set<AgentProvider> = []
    private var loadedProfileSchemaVersion: Int?

    init(store: ProtectedStore, helperURL: URL, socketURL: URL) {
        self.store = store
        self.helperURL = helperURL
        self.socketURL = socketURL
    }

    func load() async throws {
        if let data = try await store.protectedPreference(.agentProfiles) {
            let saved = try JSONDecoder().decode(SavedAgentProfiles.self, from: data)
            guard (1...3).contains(saved.schemaVersion), saved.profiles.count <= 2,
                  Set(saved.profiles.map(\.provider)).count == saved.profiles.count else {
                throw StorageError.corruptProtectedState
            }
            loadedProfileSchemaVersion = saved.schemaVersion
            let restored = Dictionary(uniqueKeysWithValues: saved.profiles.map { ($0.provider, $0) })
            // Publish migrated authorization only after its encrypted preference commits.
            if saved.schemaVersion < 3 { try await persist(profiles: restored) }
            profiles = restored
        }
        try restoreSetups()
        await check()
    }

    func snapshot() -> AgentSetupSnapshot {
        .init(profiles: profiles, states: states, messages: messages, verificationPrompts: prompts)
    }

    /// Numeric measurement only; used by explicit disposable signed recovery reports.
    /// Reading back the protected preference distinguishes an attempted migration from a commit.
    func profileSchemaVersions() async -> (loaded: Int?, saved: Int?) {
        guard let bytes = try? await store.protectedPreference(.agentProfiles),
              let saved = try? JSONDecoder().decode(SavedAgentProfiles.self, from: bytes),
              (1...3).contains(saved.schemaVersion) else { return (loadedProfileSchemaVersion, nil) }
        return (loadedProfileSchemaVersion, saved.schemaVersion)
    }

    func selectedProfiles() -> [AgentProfileDraft] {
        profiles.values.filter { $0.installed && !$0.authorizedHosts.isEmpty
            && supported($0) && states[$0.provider] != .unsupported }
    }

    func discover() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for provider in [AgentProvider.codex, .claudeCode] {
            guard profiles[provider] == nil else { continue }
            let name = provider == .codex ? "codex" : "claude"
            let paths = [home.appendingPathComponent(".local/bin/\(name)"),
                         URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
                         URL(fileURLWithPath: "/usr/local/bin/\(name)")]
            guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }),
                  let version = await ProviderVersionProbe.read(executable: executable, provider: provider) else {
                states[provider] = .notDetected
                messages[provider] = "Select an installed executable and its authorized profile."
                continue
            }
            let draft = AgentProfileDraft(provider: provider,
                executablePath: executable.path,
                homePath: home.appendingPathComponent(provider == .codex ? ".codex" : ".claude").path,
                version: version)
            profiles[provider] = draft
            states[provider] = supported(draft) ? .detected : .unsupported
            messages[provider] = supported(draft)
                ? "Found on this Mac. Not connected yet."
                : "This collection route has not been established."
        }
    }

    func install(_ draft: AgentProfileDraft) async throws {
        guard supported(draft), draft.interface != .desktopCode, draft.hasValidHostAuthorization,
              !draft.authorizedHosts.isEmpty, draft.authorizedHosts.contains(draft.interface),
              !draft.profileID.isEmpty, draft.profileID.utf8.count <= 256,
              draft.homePath.hasPrefix("/"), draft.executablePath.hasPrefix("/"),
              ![draft.profileID, draft.homePath, draft.executablePath].contains(where: { $0.utf8.contains(0) }),
              FileManager.default.isExecutableFile(atPath: draft.executablePath),
              FileManager.default.fileExists(atPath: draft.homePath),
              let observedVersion = await ProviderVersionProbe.read(executable: URL(fileURLWithPath: draft.executablePath), provider: draft.provider) else {
            throw CodexSetupError.invalidConfiguration
        }
        // Save ownership before editing a provider file. Even an interrupted installation retains
        // the UUID needed for scoped repair/removal; unrelated handlers are never claimed.
        var saved = draft
        saved.version = observedVersion
        if let prior = profiles[draft.provider], prior.installed,
           (prior.homePath != draft.homePath || prior.profileID != draft.profileID
                || prior.interface != draft.interface) {
            throw CodexSetupError.invalidConfiguration
        }
        if let prior = profiles[draft.provider] {
            saved.registrationID = prior.registrationID
            saved.connectionProof = prior.connectionProof
        }
        if saved.connectionProof?.applies(to: binding(for: saved)) != true { saved.connectionProof = nil }
        // This flag retains authorization and the ownership location for an attempted install.
        // Actual installed/connected status always comes from check() and the durable challenge.
        // A failure after provider rename must still expose removal and prevent abandoning its root.
        saved.installed = true
        profiles[draft.provider] = saved
        try await persist()
        try restoreSetups(only: draft.provider)
        if draft.provider == .codex { _ = try await codex?.install() }
        else { _ = try await claude?.install() }
        saved.installed = true
        profiles[draft.provider] = saved
        try await persist()
        states[draft.provider] = saved.connectionProof == nil ? .installedUnverified : .connected
        prompts.removeValue(forKey: draft.provider)
        messages[draft.provider] = saved.connectionProof == nil
            ? "Hooks added. A short test session confirms that events arrive."
            : "Hooks repaired. The earlier test session still applies; coverage is shown separately."
    }

    func verify(_ provider: AgentProvider) async throws {
        await check()
        guard let profile = profiles[provider], profile.installed, supported(profile),
              states[provider] == .installedUnverified || states[provider] == .connected else {
            throw CodexSetupError.verificationFailed
        }
        if provider == .codex, let codex {
            prompts[provider] = try await codex.beginVerification().prompt
            messages[provider] = "Waiting for the test prompt from a new Codex session."
        } else if provider == .claudeCode, let claude {
            prompts[provider] = try await claude.beginVerification().prompt
            messages[provider] = "Waiting for the test prompt from a new Claude Code session."
        } else { throw CodexSetupError.verificationFailed }
        states[provider] = .installedUnverified
    }

    /// Changes only protected collection authorization within the already chosen native home.
    /// The shared hook transport remains authorized and its owned registration/proof is untouched.
    /// No per-host producer suppression is promised for hooks whose payload cannot identify a host.
    func authorizeHosts(_ hosts: Set<AgentInterface>, for provider: AgentProvider) async throws {
        guard var profile = profiles[provider], profile.interface != .desktopCode,
              !hosts.isEmpty, hosts.isSubset(of: AgentProfileDraft.supportedHosts),
              hosts.contains(profile.interface) else { throw CodexSetupError.invalidConfiguration }
        let previous = profile
        profile.authorizedHosts = hosts
        profiles[provider] = profile
        do { try await persist() }
        catch { profiles[provider] = previous; throw error }
    }

    func remove(_ provider: AgentProvider) async throws {
        if provider == .codex { try await codex?.remove() }
        else { try await claude?.remove() }
        if var profile = profiles[provider] {
            profile.installed = false
            profile.connectionProof = nil
            profiles[provider] = profile
        }
        try await persist()
        states[provider] = .detected
        prompts.removeValue(forKey: provider)
        messages[provider] = "\(AppIdentity.name)’s hooks removed. The inventory keeps what was already found."
    }

    /// Called only after the receiver's encrypted enqueue succeeds.
    func received(_ packet: CapturePacket, durableQueueID: UUID) async {
        let provider = packet.metadata.agent
        guard prompts[provider] != nil else { return }
        await check()
        guard let profile = profiles[provider], profile.installed, supported(profile),
              states[provider] == .installedUnverified else { return }
        do {
            if provider == .codex, let codex {
                try await codex.acceptVerification(.init(packet: packet, durableQueueID: durableQueueID))
            } else if provider == .claudeCode, let claude {
                try await claude.acceptVerification(.init(packet: packet, durableQueueID: durableQueueID))
            } else { return }
            var verified = profile
            verified.connectionProof = ConnectionVerificationProof(binding: binding(for: profile),
                durableQueueID: durableQueueID, verifiedAt: .now)
            profiles[provider] = verified
            do { try await persist() }
            catch { profiles[provider] = profile; throw error }
            prompts.removeValue(forKey: provider)
            states[provider] = .connected
            messages[provider] = "Test prompt received. The hooks are verified; each host’s activity and coverage are shown separately."
        } catch { /* Other events cannot satisfy the exact one-use verification challenge. */ }
    }

    func check() async {
        for provider in [AgentProvider.codex, .claudeCode] {
            guard let profile = profiles[provider] else { continue }
            guard supported(profile) else {
                states[provider] = .unsupported
                messages[provider] = "This collection route has not been established."
                continue
            }
            let executable = URL(fileURLWithPath: profile.executablePath)
            let attributes = try? FileManager.default.attributesOfItem(atPath: executable.resolvingSymlinksInPath().path)
            let signature = executable.resolvingSymlinksInPath().path + ":" +
                String(describing: attributes?[.systemFileNumber]) + ":" +
                String(describing: attributes?[.modificationDate]) + ":" + String(describing: attributes?[.size])
            let priorProbe = executableProbes[provider]
            if priorProbe?.signature != signature || (priorProbe?.version == nil
                && ProcessInfo.processInfo.systemUptime - (priorProbe?.probedAt ?? 0) >= 30) {
                let observed = await ProviderVersionProbe.read(executable: executable, provider: provider)
                executableProbes[provider] = (signature, observed, ProcessInfo.processInfo.systemUptime)
                if let priorProbe, priorProbe.signature != signature || priorProbe.version != observed {
                    changedExecutables.insert(provider)
                }
            }
            guard let observedVersion = executableProbes[provider]?.version else {
                states[provider] = .unavailable
                messages[provider] = "The selected executable is unavailable or its provider identity could not be read. Queued work remains protected."
                continue
            }
            if observedVersion != profile.version {
                var refreshed = profile
                refreshed.version = observedVersion
                profiles[provider] = refreshed
                do { try await persist() }
                catch {
                    states[provider] = .unavailable
                    messages[provider] = "Updated executable metadata could not be saved. Existing registration and inventory are preserved."
                    continue
                }
                changedExecutables.insert(provider)
            }
            guard profile.installed else { states[provider] = .detected; continue }
            do {
                let raw = provider == .codex ? try await codex?.check().rawValue : try await claude?.check().rawValue
                let proof = profiles[provider]?.connectionProof
                let remembered = proof?.applies(to: binding(for: profile)) == true
                states[provider] = prompts[provider] == nil
                    && (raw == "connected" || remembered && raw == "installedUnverified") ? .connected : .installedUnverified
                if prompts[provider] == nil && remembered && raw == "installedUnverified" {
                    messages[provider] = "Owned registration retains encrypted verification. Recent activity and content coverage are shown separately."
                }
                if raw == "needsRepair" {
                    states[provider] = .unavailable
                    messages[provider] = "\(AppIdentity.name)’s hooks changed or are missing. Repair them, then run the test session again."
                    prompts.removeValue(forKey: provider)
                    if var invalidated = profiles[provider], invalidated.connectionProof != nil {
                        invalidated.connectionProof = nil
                        profiles[provider] = invalidated
                        try await persist()
                    }
                }
            } catch {
                states[provider] = .unavailable
                messages[provider] = "Provider configuration could not be read safely. Existing settings are preserved."
            }
        }
    }

    private func supported(_ profile: AgentProfileDraft) -> Bool {
        CollectionCompatibility.isEligible(provider: profile.provider, interface: profile.interface, version: profile.version)
    }

    func consumeChangedExecutables() -> Set<AgentProvider> {
        defer { changedExecutables.removeAll() }
        return changedExecutables
    }

    private func binding(for profile: AgentProfileDraft) -> HookRegistrationBinding {
        let home = URL(fileURLWithPath: profile.homePath).resolvingSymlinksInPath()
        return HookRegistrationBinding(provider: profile.provider, profileID: profile.profileID,
            registrationID: profile.registrationID, interface: profile.interface,
            configurationPath: home.appendingPathComponent(profile.provider == .codex ? "hooks.json" : "settings.json").path,
            helperPath: helperURL.path, socketPath: socketURL.path)
    }

    private func persist(profiles proposed: [AgentProvider: AgentProfileDraft]? = nil) async throws {
        let saved = SavedAgentProfiles(schemaVersion: 3,
            profiles: (proposed ?? profiles).values.sorted { $0.provider.rawValue < $1.provider.rawValue })
        try await store.setProtectedPreference(JSONEncoder().encode(saved), for: .agentProfiles)
    }

    /// Rebuilding a setup discards its in-memory verification, so an edit to one provider leaves
    /// the other's verified state intact.
    private func restoreSetups(only provider: AgentProvider? = nil) throws {
        if provider == nil || provider == .claudeCode { claude = nil }
        if provider == nil || provider == .codex { codex = nil }
        // Unsupported versions still need the exact owned registration for safe removal.
        for profile in profiles.values where provider == nil || profile.provider == provider {
            let home = URL(fileURLWithPath: profile.homePath, isDirectory: true)
            if profile.provider == .codex {
                codex = try CodexHookSetup(hooksURL: home.appendingPathComponent("hooks.json"), configuration:
                    .init(registrationID: profile.registrationID, helperURL: helperURL, socketURL: socketURL,
                          profileID: profile.profileID, interface: profile.interface, agentVersion: profile.version))
            } else {
                claude = try ClaudeHookSetup(settingsURL: home.appendingPathComponent("settings.json"), configuration:
                    .init(registrationID: profile.registrationID, helperURL: helperURL, socketURL: socketURL,
                          profileID: profile.profileID, interface: profile.interface, agentVersion: profile.version))
            }
        }
    }
}

private final class VersionBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(data.prefix(max(0, 4096 - bytes.count))) }
    func text() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
}

private enum ProviderVersionProbe {
    static func read(executable: URL, provider: AgentProvider) async -> String? {
        let task = Task.detached { readBlocking(executable: executable, provider: provider) }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func readBlocking(executable: URL, provider: AgentProvider) -> String? {
        let process = Process(), pipe = Pipe(), output = VersionBytes()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in output.append(handle.availableData) }
        do { try process.run() } catch { pipe.fileHandleForReading.readabilityHandler = nil; return nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning && !Task.isCancelled && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        if let remaining = try? pipe.fileHandleForReading.readToEnd() { output.append(remaining) }
        try? pipe.fileHandleForReading.close()
        let text = output.text().trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = provider == .codex ? #"^codex-cli ([0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?)$"#
            : #"^([0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?) \(Claude Code\)$"#
        guard process.terminationStatus == 0,
              text.range(of: pattern, options: .regularExpression) != nil,
              let range = text.range(of: #"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }
}
