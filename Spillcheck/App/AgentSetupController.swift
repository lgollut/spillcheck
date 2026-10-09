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
    private var executableProbes: [AgentProvider: (signature: String, version: String?)] = [:]

    init(store: ProtectedStore, helperURL: URL, socketURL: URL) {
        self.store = store
        self.helperURL = helperURL
        self.socketURL = socketURL
    }

    func load() async throws {
        if let data = try await store.protectedPreference(.agentProfiles) {
            let saved = try JSONDecoder().decode(SavedAgentProfiles.self, from: data)
            guard saved.schemaVersion == 1, saved.profiles.count <= 2,
                  Set(saved.profiles.map(\.provider)).count == saved.profiles.count else {
                throw StorageError.corruptProtectedState
            }
            for profile in saved.profiles { profiles[profile.provider] = profile }
        }
        try restoreSetups()
        await check()
    }

    func snapshot() -> AgentSetupSnapshot {
        .init(profiles: profiles, states: states, messages: messages, verificationPrompts: prompts)
    }

    func selectedProfiles() -> [AgentProfileDraft] {
        profiles.values.filter { $0.installed && supported($0) && states[$0.provider] != .unsupported }
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
                  let version = await ProviderVersionProbe.read(executable: executable) else {
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
                ? "Executable found. Monitoring setup has not been installed or verified."
                : "This version has not been validated. Select a supported version before installing."
        }
    }

    func install(_ draft: AgentProfileDraft) async throws {
        guard supported(draft), draft.interface != .desktopCode,
              !draft.profileID.isEmpty, draft.profileID.utf8.count <= 256,
              draft.homePath.hasPrefix("/"), draft.executablePath.hasPrefix("/"),
              ![draft.profileID, draft.homePath, draft.executablePath].contains(where: { $0.utf8.contains(0) }),
              FileManager.default.isExecutableFile(atPath: draft.executablePath),
              FileManager.default.fileExists(atPath: draft.homePath),
              await ProviderVersionProbe.read(executable: URL(fileURLWithPath: draft.executablePath)) == draft.version else {
            throw CodexSetupError.invalidConfiguration
        }
        // Save ownership before editing a provider file. Even an interrupted installation retains
        // the UUID needed for scoped repair/removal; unrelated handlers are never claimed.
        var saved = draft
        if let prior = profiles[draft.provider], prior.installed,
           (prior.homePath != draft.homePath || prior.profileID != draft.profileID) {
            throw CodexSetupError.invalidConfiguration
        }
        if let prior = profiles[draft.provider] { saved.registrationID = prior.registrationID }
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
        states[draft.provider] = .installedUnverified
        prompts.removeValue(forKey: draft.provider)
        messages[draft.provider] = "Owned hooks installed. Verify a synthetic prompt before reporting connected."
    }

    func verify(_ provider: AgentProvider) async throws {
        await check()
        guard let profile = profiles[provider], profile.installed, supported(profile),
              states[provider] == .installedUnverified || states[provider] == .connected else {
            throw CodexSetupError.verificationFailed
        }
        if provider == .codex, let codex {
            prompts[provider] = try await codex.beginVerification().prompt
            messages[provider] = "Start Codex with this profile. Open /hooks, review the Spillcheck helper in UserPromptSubmit, trust it, then send the synthetic prompt below."
        } else if provider == .claudeCode, let claude {
            prompts[provider] = try await claude.beginVerification().prompt
            messages[provider] = "Start Claude Code with this profile and send the synthetic prompt below. Review the owned hooks if Claude requests it."
        } else { throw CodexSetupError.verificationFailed }
        states[provider] = .installedUnverified
    }

    func remove(_ provider: AgentProvider) async throws {
        if provider == .codex { try await codex?.remove() }
        else { try await claude?.remove() }
        if var profile = profiles[provider] {
            profile.installed = false
            profiles[provider] = profile
        }
        try await persist()
        states[provider] = .detected
        prompts.removeValue(forKey: provider)
        messages[provider] = "Spillcheck's owned hooks removed. Retained inventory remains available."
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
            prompts.removeValue(forKey: provider)
            states[provider] = .connected
            messages[provider] = "Synthetic prompt received and stored encrypted. This route is connected; coverage is shown separately."
        } catch { /* Other events cannot satisfy the exact one-use verification challenge. */ }
    }

    func check() async {
        for provider in [AgentProvider.codex, .claudeCode] {
            guard let profile = profiles[provider] else { continue }
            guard supported(profile) else {
                states[provider] = .unsupported
                messages[provider] = "This version has not been validated."
                continue
            }
            let executable = URL(fileURLWithPath: profile.executablePath)
            let attributes = try? FileManager.default.attributesOfItem(atPath: executable.resolvingSymlinksInPath().path)
            let signature = executable.resolvingSymlinksInPath().path + ":" +
                String(describing: attributes?[.systemFileNumber]) + ":" +
                String(describing: attributes?[.modificationDate]) + ":" + String(describing: attributes?[.size])
            if executableProbes[provider]?.signature != signature {
                let observed = await ProviderVersionProbe.read(executable: executable)
                executableProbes[provider] = (signature, observed)
            }
            guard executableProbes[provider]?.version == profile.version else {
                states[provider] = executableProbes[provider]?.version == nil ? .unavailable : .unsupported
                messages[provider] = "The selected executable changed or is unavailable. Recheck its version before monitoring."
                prompts.removeValue(forKey: provider)
                continue
            }
            guard profile.installed else { states[provider] = .detected; continue }
            do {
                let raw = provider == .codex ? try await codex?.check().rawValue : try await claude?.check().rawValue
                states[provider] = raw == "connected" ? .connected : .installedUnverified
                if raw == "needsRepair" {
                    states[provider] = .unavailable
                    messages[provider] = "Owned hook configuration changed or is missing. Repair it, then verify again."
                    prompts.removeValue(forKey: provider)
                }
            } catch {
                states[provider] = .unavailable
                messages[provider] = "Provider configuration could not be read safely. Existing settings are preserved."
            }
        }
    }

    private func supported(_ profile: AgentProfileDraft) -> Bool {
        guard profile.interface != .desktopCode else { return false }
        if profile.provider == .codex {
            return profile.version == CodexAdapter.validatedAgentVersion &&
                (profile.interface == .standaloneCLI || profile.interface == .t3 && profile.t3Version == CodexAdapter.validatedT3Version)
        }
        return profile.version == ClaudeAdapter.validatedAgentVersion
    }

    private func persist() async throws {
        let saved = SavedAgentProfiles(schemaVersion: 1, profiles: profiles.values.sorted { $0.provider.rawValue < $1.provider.rawValue })
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
    static func read(executable: URL) async -> String? {
        let task = Task.detached { readBlocking(executable: executable) }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func readBlocking(executable: URL) -> String? {
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
        let text = output.text()
        guard process.terminationStatus == 0,
              let range = text.range(of: #"\b[0-9]+\.[0-9]+\.[0-9]+\b"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }
}
