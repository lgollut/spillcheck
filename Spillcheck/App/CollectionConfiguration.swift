import Darwin
import Foundation
import SpillcheckCore

/// Explicit source selection for the first complete path. Setup preferences join this in M5.
struct CollectionConfiguration {
    let profileID: String
    let agentVersion: String
    let roots: [URL]
    let activeSources: [ClaudeActiveSource]
    let authorizedHosts: Set<AgentInterface>
    let historicalInterface: AgentInterface

    init(profileID: String, agentVersion: String, roots: [URL], activeSources: [ClaudeActiveSource],
         authorizedHosts: Set<AgentInterface> = [.standaloneCLI, .t3], historicalInterface: AgentInterface? = nil) {
        self.profileID = profileID
        self.agentVersion = agentVersion
        self.roots = roots
        self.activeSources = activeSources
        self.authorizedHosts = authorizedHosts
        self.historicalInterface = historicalInterface
            ?? (authorizedHosts.contains(.standaloneCLI) ? .standaloneCLI : .t3)
    }

    static func fromArguments(_ args: [String]) throws -> CollectionConfiguration? {
        func values(_ name: String) throws -> [String] {
            try args.indices.filter { args[$0] == name }.map { index in
                guard args.indices.contains(index + 1), !args[index + 1].hasPrefix("--") else {
                    throw ClaudeCollectionError.invalidConfiguration
                }
                return args[index + 1]
            }
        }
        let profiles = try values("--claude-profile")
        guard !profiles.isEmpty else { return nil }
        let versions = try values("--claude-version")
        let interfaces = try values("--claude-interface")
        let hostNames = try values("--claude-authorized-host")
        let hosts = hostNames.isEmpty ? AgentProfileDraft.supportedHosts
            : Set(hostNames.compactMap(AgentInterface.init(rawValue:)))
        let rootPaths = try values("--claude-source-root")
        let paths = try values("--claude-active-source")
        let sessions = try values("--claude-session")
        guard profiles.count == 1, versions.count == 1, interfaces.count <= 1, !rootPaths.isEmpty,
              paths.count == sessions.count,
              let interface = AgentInterface(rawValue: interfaces.first ?? "t3"),
              (hostNames.isEmpty || hosts.count == hostNames.count), !hosts.isEmpty,
              hosts.isSubset(of: AgentProfileDraft.supportedHosts),
              (paths.isEmpty || hosts.contains(interface)),
              CollectionCompatibility.isEligible(provider: .claudeCode, interface: interface, version: versions[0]) else {
            throw ClaudeCollectionError.invalidConfiguration
        }
        let sources = try zip(paths, sessions).map { path, session in
            try ClaudeActiveSource(sessionID: session, transcriptURL: URL(fileURLWithPath: path), interface: interface)
        }
        return CollectionConfiguration(profileID: profiles[0], agentVersion: versions[0],
            roots: rootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }, activeSources: sources,
            authorizedHosts: hosts)
    }

    static func bundledDetector(workingDirectory: URL) throws -> BetterleaksSecretDetector {
        let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Scanner", isDirectory: true)
        let manifestURL = resources.appendingPathComponent("dependencies.json")
        guard let bytes = try? Data(contentsOf: manifestURL), bytes.count < 8192,
              let manifest = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              manifest["schemaVersion"] as? Int == 1,
              manifest["engine"] as? String == "betterleaks",
              manifest["version"] as? String == BetterleaksConfiguration.pinnedVersion,
              manifest["regexEngine"] as? String == "stdlib",
              let original = manifest["verifiedBeforeSigning"] as? [String: String],
              original["betterleaks"] == BetterleaksConfiguration.pinnedExecutableSHA256,
              original["betterleaks.toml"] == BetterleaksConfiguration.pinnedConfigurationSHA256,
              let signedHash = manifest["bundledExecutableSHA256"] as? String,
              signedHash.count == 64, signedHash.allSatisfy({ $0.isHexDigit }) else {
            throw DetectorFailure.invalidArtifacts
        }
        if mkdir(workingDirectory.path, 0o700) != 0, errno != EEXIST { throw DetectorFailure.unavailable }
        var info = stat()
        guard lstat(workingDirectory.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else { throw DetectorFailure.unavailable }
        return BetterleaksSecretDetector(configuration: BetterleaksConfiguration(
            executableURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/betterleaks"),
            configurationURL: resources.appendingPathComponent("betterleaks.toml"),
            workingDirectoryURL: workingDirectory, expectedExecutableSHA256: signedHash))
    }
}

/// A shared-home history request uses an authorized transport. Retagging metadata neither
/// changes the frozen audit/cursor nor establishes which host originally produced its content.
struct AuthorizedHistoricalCaptureProducer: HistoricalCaptureProducer {
    let producer: any HistoricalCaptureProducer
    let provider: AgentProvider
    let profileID: String
    let interface: AgentInterface

    func initialHistoricalCapture(audit: HistoricalAuditContext) async throws -> CapturePacket {
        let packet = try await producer.initialHistoricalCapture(audit: audit)
        guard packet.metadata.agent == provider, packet.metadata.profileID == profileID,
              interface != .desktopCode else { throw ContractError.invalidState }
        return try CapturePacket(metadata: .init(agent: provider, interface: interface, profileID: profileID),
            eventJSON: packet.eventJSON)
    }
}

struct CodexCollectionConfiguration {
    let profileID: String
    let readerVersion: String
    let t3Version: String?
    let interface: AgentInterface
    let authority: CodexCollectionAuthority
    let home: URL
    let executable: URL
    let transcriptRoots: [URL]
    let activeSources: [CodexActiveSource]
    let authorizedHosts: Set<AgentInterface>

    init(profileID: String, readerVersion: String, t3Version: String?, interface: AgentInterface,
         authority: CodexCollectionAuthority, home: URL, executable: URL,
         transcriptRoots: [URL], activeSources: [CodexActiveSource],
         authorizedHosts: Set<AgentInterface> = [.standaloneCLI, .t3]) {
        self.profileID = profileID
        self.readerVersion = readerVersion
        self.t3Version = t3Version
        self.interface = interface
        self.authority = authority
        self.home = home
        self.executable = executable
        self.transcriptRoots = transcriptRoots
        self.activeSources = activeSources
        self.authorizedHosts = authorizedHosts
    }

    static func fromArguments(_ args: [String]) throws -> CodexCollectionConfiguration? {
        func values(_ name: String) throws -> [String] {
            try args.indices.filter { args[$0] == name }.map { index in
                guard args.indices.contains(index + 1), !args[index + 1].hasPrefix("--") else {
                    throw CodexCollectionError.invalidConfiguration
                }
                return args[index + 1]
            }
        }
        let profiles = try values("--codex-profile")
        guard !profiles.isEmpty else { return nil }
        let versions = try values("--codex-version")
        let homes = try values("--codex-home")
        let executables = try values("--codex-executable")
        let interfaces = try values("--codex-interface")
        let hostNames = try values("--codex-authorized-host")
        let hosts = hostNames.isEmpty ? AgentProfileDraft.supportedHosts
            : Set(hostNames.compactMap(AgentInterface.init(rawValue:)))
        let t3Versions = try values("--codex-t3-version")
        let authorities = try values("--codex-authority")
        let threads = try values("--codex-active-thread")
        let paths = try values("--codex-active-source")
        let roots = try values("--codex-source-root")
        guard profiles.count == 1, versions.count == 1, homes.count == 1, executables.count == 1,
              interfaces.count <= 1, t3Versions.count <= 1, authorities.count <= 1,
              paths.isEmpty || paths.count == threads.count,
              let interface = AgentInterface(rawValue: interfaces.first ?? "standalone-cli"), interface != .desktopCode,
              (hostNames.isEmpty || hosts.count == hostNames.count), !hosts.isEmpty,
              hosts.isSubset(of: AgentProfileDraft.supportedHosts), hosts.contains(interface),
              let authority = CodexCollectionAuthority(rawValue: authorities.first ?? "codex-public-native-v1") else {
            throw CodexCollectionError.invalidConfiguration
        }
        let home = URL(fileURLWithPath: homes[0], isDirectory: true)
        let selectedRoots = roots.isEmpty ? [home.appendingPathComponent("sessions"), home.appendingPathComponent("archived_sessions")]
            : roots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let sources = try threads.enumerated().map { index, thread in
            try CodexActiveSource(threadID: thread, interface: interface, authority: authority,
                transcriptURL: paths.isEmpty ? nil : URL(fileURLWithPath: paths[index]))
        }
        return CodexCollectionConfiguration(profileID: profiles[0], readerVersion: versions[0],
            t3Version: t3Versions.first, interface: interface,
            authority: authority, home: home, executable: URL(fileURLWithPath: executables[0]),
            transcriptRoots: selectedRoots, activeSources: sources, authorizedHosts: hosts)
    }
}
