import Darwin
import Foundation
#if DEBUG
@_spi(Testing) import SpillcheckCore
#else
import SpillcheckCore
#endif

/// Retains the configured scope when admission fails before a queue record exists.
struct CollectionCapacityRejection: Error, Sendable {
    let gap: CoverageGap

    init(resource: StorageCapacityResource, scope: CollectionScope, at time: Date = Date()) {
        gap = CoverageGap(reason: .budgetExhausted, scope: scope, operation: .hookDelivery,
            diagnosticCode: resource == .sourceAuthorities ? .authorityStorageLimit : .hookStorageLimit,
            observedAt: time)
    }
}

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
            ?? (authorizedHosts.contains(.standaloneCLI) ? .standaloneCLI
                : authorizedHosts.contains(.t3) ? .t3
                : authorizedHosts.contains(.desktopCode) ? .desktopCode : .standaloneCLI)
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
        let hosts = hostNames.isEmpty ? AgentProfileDraft.defaultHosts
            : Set(hostNames.compactMap(AgentInterface.init(rawValue:)))
        let rootPaths = try values("--claude-source-root")
        let paths = try values("--claude-active-source")
        let sessions = try values("--claude-session")
        guard profiles.count == 1, versions.count == 1, interfaces.count <= 1, !rootPaths.isEmpty,
              paths.count == sessions.count,
              let interface = AgentInterface(rawValue: interfaces.first ?? "t3"),
              (hostNames.isEmpty || hosts.count == hostNames.count), !hosts.isEmpty,
              hosts.isSubset(of: AgentProfileDraft.supportedHosts(for: .claudeCode)),
              (interface != .desktopCode || hosts.contains(.desktopCode)),
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
struct AuthorizedHistoricalCaptureProducer: SourceHistoricalCaptureProducer {
    let producer: any HistoricalCaptureProducer
    let provider: AgentProvider
    let profileID: String
    let interface: AgentInterface

    func initialHistoricalCapture(audit: HistoricalAuditContext,
                                  source: CoverageSourceRetryDescriptor) async throws -> CapturePacket {
        guard source.scope.provider == provider, source.scope.profileID == profileID,
              source.scope.interface == interface,
              let selected = producer as? any SourceHistoricalCaptureProducer else { throw ContractError.invalidState }
        return try await selected.initialHistoricalCapture(audit: audit, source: source)
    }

    func initialHistoricalCapture(audit: HistoricalAuditContext) async throws -> CapturePacket {
        let packet = try await producer.initialHistoricalCapture(audit: audit)
        guard packet.metadata.agent == provider, packet.metadata.profileID == profileID else { throw ContractError.invalidState }
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
        let hosts = hostNames.isEmpty ? AgentProfileDraft.defaultHosts
            : Set(hostNames.compactMap(AgentInterface.init(rawValue:)))
        let t3Versions = try values("--codex-t3-version")
        let authorities = try values("--codex-authority")
        let threads = try values("--codex-active-thread")
        let paths = try values("--codex-active-source")
        let roots = try values("--codex-source-root")
        guard profiles.count == 1, versions.count == 1, homes.count == 1, executables.count == 1,
              interfaces.count <= 1, t3Versions.count <= 1, authorities.count <= 1,
              paths.isEmpty || paths.count == threads.count,
              let interface = AgentInterface(rawValue: interfaces.first ?? "standalone-cli"),
              (hostNames.isEmpty || hosts.count == hostNames.count), !hosts.isEmpty,
              hosts.isSubset(of: AgentProfileDraft.supportedHosts(for: .codex)), hosts.contains(interface),
              let authority = CodexCollectionAuthority(rawValue: authorities.first ?? "codex-public-native-v1"),
              authority != .nativeRolloutTranscript || interface == .t3 else {
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

#if DEBUG
/// This opt-in observes only a new disposable vault's adapter-validated Claude sources.
/// The native filenames become known after the live producer starts; no profile discovery
/// or caller-supplied role label can stand in for the observed parent/own-child relation.
struct ClaudeAcceptanceRoles: Sendable {
    let profileID: String
    let roots: [URL]
    let interfaces: Set<AgentInterface>

    static func fromRecoveryArguments(_ args: [String], recovery: DisposableRecoveryConfiguration?,
                                      explicitStore: Bool, reportRequested: Bool) throws -> Self? {
        let count = args.filter { $0 == "--acceptance-recovery-claude-role-evidence" }.count
        guard count > 0 else { return nil }
        guard count == 1, explicitStore, reportRequested, let recovery,
              args.filter({ $0 == "--acceptance-recovery-worker" }).count == 1,
              !args.contains("--acceptance-cleanup-new-vault"),
              !args.contains("--acceptance-claude-role-evidence"),
              !args.contains("--acceptance-vault-owner"),
              !args.contains("--acceptance-recovery-install-codex-profile"),
              !args.contains(where: { $0.hasPrefix("--claude-") || $0.hasPrefix("--codex-") }),
              !recovery.inventoryStateEnabled, !recovery.webResultsEnabled,
              !recovery.nativeContentEnabled, !recovery.reviewEnabled,
              !recovery.desktopBetaEnabled else {
            throw ClaudeCollectionError.invalidConfiguration
        }
        let profile = try recovery.claudeProfile(arguments: args)
        let projects = URL(fileURLWithPath: profile.home, isDirectory: true).appendingPathComponent("projects", isDirectory: true)
        var info = stat()
        guard lstat(projects.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw ClaudeCollectionError.invalidConfiguration
        }
        return Self(profileID: "owned-signed-claude-recovery", roots: [projects], interfaces: [.standaloneCLI, .t3])
    }

    func requireMatchingRecoveryProfile(_ configuration: CollectionConfiguration?) throws {
        guard let configuration, configuration.profileID == profileID,
              configuration.roots.map(\.path) == roots.map(\.path), configuration.activeSources.isEmpty,
              configuration.authorizedHosts == interfaces, configuration.historicalInterface == .standaloneCLI else {
            throw ClaudeCollectionError.invalidConfiguration
        }
    }

    static func fromArguments(_ args: [String], configuration: CollectionConfiguration?,
                              explicitStore: Bool, reportRequested: Bool) throws -> Self? {
        let count = args.filter { $0 == "--acceptance-claude-role-evidence" }.count
        guard count > 0 else { return nil }
        guard count == 1, explicitStore, reportRequested,
              args.contains("--acceptance-cleanup-new-vault"),
              args.contains("--acceptance-no-profile-catchup"),
              !args.contains("--acceptance-recovery-worker"),
              let configuration, configuration.roots.count == 1,
              !configuration.authorizedHosts.isEmpty,
              configuration.authorizedHosts.isSubset(of: [.standaloneCLI, .t3, .desktopCode]) else {
            throw ClaudeCollectionError.invalidConfiguration
        }
        return Self(profileID: configuration.profileID,
                    roots: configuration.roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() },
                    interfaces: configuration.authorizedHosts)
    }
}

struct ClaudeAcceptanceRoleSummary: Sendable {
    let nativeLinkVerified: Bool
    let bounded: Bool
    let markers: [String: [String: Int]]
    let contentTypes: [String: [String]]
    let completePairsByProducer: [String: Int]
    var complete: Bool {
        nativeLinkVerified && bounded && ["parent", "child"].allSatisfy { role in
            let expected = ClaudeAcceptanceRoleEvidence.expected.filter {
                ($0.key.hasPrefix("CHILD_") ? "child" : "parent") == role
            }
            return Set(markers[role, default: [:]].keys) == Set(expected.keys)
                && markers[role, default: [:]].values.allSatisfy { $0 == 1 }
                && Set(contentTypes[role, default: []]) == Set(ContentType.allCases.map(\.rawValue))
        }
    }
}

/// Marker bytes stay transient. Reports contain only typed counts for one exact parent
/// file and one of its own native child files, never a union of unrelated children.
actor ClaudeAcceptanceRoleEvidence {
    static let token = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
    static let expected: [String: ContentType] = ["PROMPT": .userPrompt, "INTERMEDIATE": .intermediateResponse,
        "FINAL": .finalResponse, "SHELL_OK": .toolOutput, "SHELL_ERROR": .toolError,
        "MCP_OK": .toolOutput, "MCP_ERROR": .toolError, "CHILD_PROMPT": .userPrompt,
        "CHILD_INTERMEDIATE": .intermediateResponse, "CHILD_FINAL": .finalResponse,
        "CHILD_TOOL_OUTPUT": .toolOutput, "CHILD_TOOL_ERROR": .toolError]
    private struct Observation: Hashable {
        let receipt: AnalysisReceipt
        let contentType: ContentType
        let contentTime: Date
        let interface: AgentInterface
        let path: String
    }
    private struct NativeFile {
        let session: String
        let parentPath: String?
        let producer: String
    }
    let roles: ClaudeAcceptanceRoles
    private var files: [String: NativeFile] = [:]
    private var sourcePaths: [SourceIdentity: String] = [:]
    private var observations: [String: Set<Observation>] = [:]
    private var metadataConsistent = true
    private var bounded = true
    init(roles: ClaudeAcceptanceRoles) {
        // Admission retains exact owned profile paths. Compare roots with source paths
        // using the same Foundation canonicalization, including /private/tmp aliases.
        self.roles = ClaudeAcceptanceRoles(profileID: roles.profileID,
            roots: roles.roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() },
            interfaces: roles.interfaces)
    }

    func collect(_ batch: CollectionBatch) {
        for source in batch.sources {
            let record = source.record, session = record.metadata.identity.session
            guard session.provider == .claudeCode, session.profileID == roles.profileID,
                  roles.interfaces.contains(record.metadata.origin.interface),
                  let rawPath = source.context?.transcriptPath, rawPath.hasPrefix("/"),
                  UUID(uuidString: session.sessionID) != nil else { continue }
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath()
            guard roles.roots.contains(where: { url.path.hasPrefix($0.path + "/") }) else { continue }
            let path = url.path
            let parentPath: String?
            if url.deletingLastPathComponent().lastPathComponent == "subagents",
               url.lastPathComponent.hasPrefix("agent-"), url.pathExtension == "jsonl",
               url.deletingPathExtension().lastPathComponent.count > "agent-".count {
                let parentDirectory = url.deletingLastPathComponent().deletingLastPathComponent()
                guard UUID(uuidString: parentDirectory.lastPathComponent) != nil else { continue }
                parentPath = parentDirectory.appendingPathExtension("jsonl").path
            } else {
                guard url.pathExtension == "jsonl",
                      UUID(uuidString: url.deletingPathExtension().lastPathComponent) == UUID(uuidString: session.sessionID) else { continue }
                parentPath = nil
            }
            if let previous = files[path], previous.session != session.sessionID || previous.parentPath != parentPath
                || previous.producer != record.metadata.origin.agentVersion {
                metadataConsistent = false; continue
            }
            guard files.count < 64 || files[path] != nil else { bounded = false; continue }
            files[path] = NativeFile(session: session.sessionID, parentPath: parentPath, producer: record.metadata.origin.agentVersion)
            if let previous = sourcePaths[record.metadata.identity], previous != path {
                metadataConsistent = false; continue
            }
            guard sourcePaths.count < 8192 || sourcePaths[record.metadata.identity] != nil else { bounded = false; continue }
            sourcePaths[record.metadata.identity] = path
            for (marker, kind) in Self.expected where kind == record.metadata.contentType && marker.hasPrefix("CHILD_") == (parentPath != nil) {
                guard record.segments.contains(where: { segment in
                    let text = String(decoding: segment.utf8, as: UTF8.self)
                    return ["LEAKRET_M3_", "LEAKRET_M3_T3_"].contains { text.contains($0 + marker + " " + Self.token) }
                }) else { continue }
                let observation = Observation(receipt: AnalysisReceipt(source: record.metadata.identity,
                    revision: record.revision, detectorVersion: BetterleaksSecretDetector.version),
                    contentType: kind, contentTime: record.metadata.contentTime,
                    interface: record.metadata.origin.interface, path: path)
                guard observations[marker, default: []].count < 128 || observations[marker, default: []].contains(observation) else {
                    bounded = false; continue
                }
                observations[marker, default: []].insert(observation)
            }
        }
    }

    func summary(snapshot: InventorySnapshot, syntheticValueID: UUID?) -> ClaudeAcceptanceRoleSummary {
        var selected = ClaudeAcceptanceRoleSummary(nativeLinkVerified: false, bounded: bounded,
            markers: ["parent": [:], "child": [:]], contentTypes: ["parent": [], "child": []], completePairsByProducer: [:])
        guard metadataConsistent, let syntheticValueID else { return selected }
        var completePairsByProducer: [String: Int] = [:]
        for childPath in files.keys.sorted() {
            guard let parentPath = files[childPath]?.parentPath,
                  let parent = files[parentPath], parent.parentPath == nil,
                  parent.producer == files[childPath]?.producer else { continue }
            var markers: [String: [String: Int]] = ["parent": [:], "child": [:]]
            var types: [String: Set<String>] = ["parent": [], "child": []]
            for (marker, observations) in observations {
                let role = marker.hasPrefix("CHILD_") ? "child" : "parent"
                let path = role == "child" ? childPath : parentPath
                let committed = observations.filter { observation in
                    observation.path == path && snapshot.analysisReceipts.contains(observation.receipt)
                        && snapshot.occurrences.values.contains {
                            $0.valueID == syntheticValueID && $0.source.identity == observation.receipt.source
                                && $0.source.contentType == observation.contentType && $0.source.contentTime == observation.contentTime
                                && $0.source.origin.interface == observation.interface
                        }
                }
                let count = Set(committed.map { $0.receipt.source }).count
                guard count > 0 else { continue }
                markers[role, default: [:]][marker] = count
                types[role, default: []].formUnion(committed.map { $0.contentType.rawValue })
            }
            let candidate = ClaudeAcceptanceRoleSummary(nativeLinkVerified: true, bounded: bounded,
                markers: markers, contentTypes: types.mapValues { $0.sorted() }, completePairsByProducer: [:])
            if candidate.complete { completePairsByProducer[parent.producer, default: 0] += 1 }
            if (candidate.complete && !selected.complete) || (!selected.complete && (!selected.nativeLinkVerified
                || candidate.markers.values.reduce(0, { $0 + $1.count }) > selected.markers.values.reduce(0, { $0 + $1.count }))) {
                selected = candidate
            }
        }
        return .init(nativeLinkVerified: selected.nativeLinkVerified, bounded: selected.bounded,
            markers: selected.markers, contentTypes: selected.contentTypes, completePairsByProducer: completePairsByProducer)
    }
}

/// Only a new, explicitly selected acceptance vault may attribute controlled fixture markers.
/// Role flags select expected identities; original reader responses still have to prove the link.
struct CodexAcceptanceRoles: Sendable {
    let parent: String
    let child: String
    let profileID: String
    let interface: AgentInterface

    static func fromArguments(_ args: [String], configuration: CodexCollectionConfiguration?,
                              explicitStore: Bool, reportRequested: Bool) throws -> Self? {
        func values(_ name: String) throws -> [String] {
            try args.indices.filter { args[$0] == name }.map { index in
                guard args.indices.contains(index + 1), !args[index + 1].hasPrefix("--") else {
                    throw CodexCollectionError.invalidConfiguration
                }
                return args[index + 1]
            }
        }
        let parents = try values("--acceptance-codex-parent")
        let children = try values("--acceptance-codex-child")
        guard !parents.isEmpty || !children.isEmpty else { return nil }
        guard explicitStore, reportRequested, args.contains("--acceptance-cleanup-new-vault"),
              args.contains("--acceptance-no-profile-catchup"), parents.count == 1, children.count == 1,
              let configuration, configuration.authority == .publicNativeItems,
              configuration.activeSources.count == 2, parents[0] != children[0],
              UUID(uuidString: parents[0])?.uuidString.lowercased() == parents[0],
              UUID(uuidString: children[0])?.uuidString.lowercased() == children[0],
              Set(configuration.activeSources.map(\.threadID)) == Set([parents[0], children[0]]) else {
            throw CodexCollectionError.invalidConfiguration
        }
        return Self(parent: parents[0], child: children[0], profileID: configuration.profileID,
                    interface: configuration.interface)
    }
}

struct CodexAcceptanceRoleSummary: Sendable {
    let nativeLinkVerified: Bool
    let bounded: Bool
    let markers: [String: [String: Int]]
    let contentTypes: [String: [String]]
    var complete: Bool {
        nativeLinkVerified && bounded && ["parent", "child"].allSatisfy { role in
            let expected = CodexAcceptanceRoleEvidence.expected.filter { ($0.key.hasPrefix("CHILD_") ? "child" : "parent") == role }
            return Set(markers[role, default: [:]].keys) == Set(expected.keys)
                && markers[role, default: [:]].values.allSatisfy { $0 == 1 }
                && Set(contentTypes[role, default: []]) == Set(ContentType.allCases.map(\.rawValue))
        }
    }
}

/// Ephemeral test evidence only. Normalized text is inspected in memory and never exported.
actor CodexAcceptanceRoleEvidence {
    static let token = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
    static let expected: [String: ContentType] = ["PROMPT": .userPrompt, "INTERMEDIATE": .intermediateResponse,
        "FINAL": .finalResponse, "SHELL_OK": .toolOutput, "SHELL_ERROR": .toolError,
        "MCP_OK": .toolOutput, "MCP_ERROR": .toolError, "CHILD_PROMPT": .userPrompt,
        "CHILD_INTERMEDIATE": .intermediateResponse, "CHILD_FINAL": .finalResponse,
        "CHILD_TOOL_OUTPUT": .toolOutput, "CHILD_TOOL_ERROR": .toolError]
    private struct Observation: Hashable {
        let receipt: AnalysisReceipt
        let contentType: ContentType
        let contentTime: Date
    }
    let roles: CodexAcceptanceRoles
    private var verified: Set<String> = []
    private var metadataConsistent = true
    private var linked = false
    private var bounded = true
    private var observations: [String: Set<Observation>] = [:]
    init(roles: CodexAcceptanceRoles) { self.roles = roles }

    func verifyThread(_ requested: String, result: CodexThreadRead) {
        guard requested == roles.parent || requested == roles.child else { return }
        if result.thread["id"].string == requested { verified.insert(requested) }
        else { metadataConsistent = false }
    }

    func observeLinks(parent: String, page: CodexHistoryPage) {
        guard parent == roles.parent, verified.contains(parent) else { return }
        for entry in page.data {
            let item = entry["item"]
            guard ["subAgentActivity", "collabAgentToolCall"].contains(item["type"].string ?? "") else { continue }
            let references = [item["agentThreadId"].string].compactMap { $0 }
                + (item["receiverThreadIds"].array ?? []).compactMap(\.string)
            if references.contains(roles.child) { linked = true }
        }
    }

    func collect(_ batch: CollectionBatch) {
        for source in batch.sources {
            let record = source.record, session = record.metadata.identity.session
            guard session.provider == .codex, session.profileID == roles.profileID,
                  record.metadata.origin.interface == roles.interface,
                  session.sessionID == roles.parent || session.sessionID == roles.child else { continue }
            let child = session.sessionID == roles.child
            for (marker, kind) in Self.expected where kind == record.metadata.contentType && marker.hasPrefix("CHILD_") == child {
                // The exact marker and fake value must coexist in one actual canonical segment.
                guard record.segments.contains(where: {
                    String(decoding: $0.utf8, as: UTF8.self).contains("LEAKRET_M4_\(marker) \(Self.token)")
                }) else { continue }
                let observation = Observation(receipt: AnalysisReceipt(source: record.metadata.identity,
                    revision: record.revision, detectorVersion: BetterleaksSecretDetector.version),
                    contentType: kind, contentTime: record.metadata.contentTime)
                guard observations[marker, default: []].count < 128 || observations[marker, default: []].contains(observation) else {
                    bounded = false; continue
                }
                observations[marker, default: []].insert(observation)
            }
        }
    }

    func summary(snapshot: InventorySnapshot, syntheticValueID: UUID?) -> CodexAcceptanceRoleSummary {
        let nativeLinkVerified = metadataConsistent && linked && verified == Set([roles.parent, roles.child])
        var markers: [String: [String: Int]] = ["parent": [:], "child": [:]]
        var types: [String: Set<String>] = ["parent": [], "child": []]
        if nativeLinkVerified, let syntheticValueID {
            for (marker, observations) in observations {
                let committed = observations.filter { observation in
                    snapshot.analysisReceipts.contains(observation.receipt) && snapshot.occurrences.values.contains {
                        $0.valueID == syntheticValueID && $0.source.identity == observation.receipt.source
                            && $0.source.contentType == observation.contentType && $0.source.contentTime == observation.contentTime
                            && $0.source.origin.interface == roles.interface
                    }
                }
                let count = Set(committed.map { $0.receipt.source }).count
                guard count > 0 else { continue }
                let role = marker.hasPrefix("CHILD_") ? "child" : "parent"
                markers[role, default: [:]][marker] = count
                types[role, default: []].formUnion(committed.map { $0.contentType.rawValue })
            }
        }
        return .init(nativeLinkVerified: nativeLinkVerified, bounded: bounded,
                     markers: markers, contentTypes: types.mapValues { $0.sorted() })
    }
}

/// Pass through original passive responses unchanged; never derive a child prompt from a parent item.
struct CodexAcceptanceAuditedHistory: CodexHistoryReading {
    let client: any CodexHistoryReading
    let evidence: CodexAcceptanceRoleEvidence
    func readThread(_ id: String) async throws -> CodexThreadRead {
        let result = try await client.readThread(id)
        await evidence.verifyThread(id, result: result); return result
    }
    func readThread(_ id: String, budget: CodexRPCBudget) async throws -> CodexThreadRead {
        let result = try await client.readThread(id, budget: budget)
        await evidence.verifyThread(id, result: result); return result
    }
    func listThreads(cursor: String?, limit: Int, archived: Bool) async throws -> CodexHistoryPage {
        try await client.listThreads(cursor: cursor, limit: limit, archived: archived)
    }
    func listThreads(cursor: String?, limit: Int, archived: Bool, budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        try await client.listThreads(cursor: cursor, limit: limit, archived: archived, budget: budget)
    }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection) async throws -> CodexHistoryPage {
        try await client.listTurns(threadID: threadID, cursor: cursor, limit: limit, direction: direction)
    }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection,
                   budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        try await client.listTurns(threadID: threadID, cursor: cursor, limit: limit, direction: direction, budget: budget)
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int, direction: CodexHistoryDirection) async throws -> CodexHistoryPage {
        let result = try await client.listItems(threadID: threadID, turnID: turnID, cursor: cursor, limit: limit, direction: direction)
        await evidence.observeLinks(parent: threadID, page: result); return result
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int, direction: CodexHistoryDirection,
                   budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        let result = try await client.listItems(threadID: threadID, turnID: turnID, cursor: cursor, limit: limit, direction: direction, budget: budget)
        await evidence.observeLinks(parent: threadID, page: result); return result
    }
}
#endif
