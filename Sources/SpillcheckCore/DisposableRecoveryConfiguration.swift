import Darwin
import Foundation

/// Private, disposable signed acceptance controls. No release app entry point uses this SPI.
@_spi(Testing) public struct DisposableRecoveryConfiguration: Sendable {
    public let root: URL
    public let store: URL
    public let report: URL
    public let finish: URL
    public let inventoryStateEnabled: Bool
    public let upgradeStateEnabled: Bool
    public let upgradeRemovedStateEnabled: Bool
    public let webResultsEnabled: Bool
    public let webSourceID: String?
    public let nativeContentEnabled: Bool
    public let nativeContentDescriptorData: Data?
    public let reviewEnabled: Bool
    public let reviewDescriptorData: Data?
    public let reviewStage: String?
    public let desktopBetaEnabled: Bool
    public let desktopBetaStage: String?
    public let desktopBetaDescriptorData: Data?
    private let authorization: Data

    public init(arguments: [String]) throws {
        let inventoryFlags = arguments.filter { $0 == "--acceptance-recovery-inventory-state" }.count
        guard inventoryFlags <= 1 else { throw ClaudeCollectionError.invalidConfiguration }
        inventoryStateEnabled = inventoryFlags == 1
        let upgradeFlags = arguments.filter { $0 == "--acceptance-recovery-upgrade-state" }.count
        guard upgradeFlags <= 1, upgradeFlags == 0 || inventoryStateEnabled else {
            throw ClaudeCollectionError.invalidConfiguration
        }
        upgradeStateEnabled = upgradeFlags == 1
        let removedUpgradeFlags = arguments.filter { $0 == "--acceptance-recovery-upgrade-removed-state" }.count
        guard removedUpgradeFlags <= 1, removedUpgradeFlags == 0 || upgradeStateEnabled else {
            throw ClaudeCollectionError.invalidConfiguration
        }
        upgradeRemovedStateEnabled = removedUpgradeFlags == 1
        let webFlags = arguments.filter { $0 == "--acceptance-recovery-web-results" }.count
        let sourcePositions = arguments.indices.filter { arguments[$0] == "--acceptance-web-source" }
        guard webFlags <= 1, !(inventoryStateEnabled && webFlags == 1) else {
            throw ClaudeCollectionError.invalidConfiguration
        }
        webResultsEnabled = webFlags == 1
        let nativeFlags = arguments.filter { $0 == "--acceptance-recovery-native-content" }.count
        let nativePositions = arguments.indices.filter { arguments[$0] == "--acceptance-native-content-descriptor" }
        guard nativeFlags <= 1, nativeFlags == 0 || (!inventoryStateEnabled && !webResultsEnabled),
              nativePositions.count == nativeFlags else { throw ClaudeCollectionError.invalidConfiguration }
        nativeContentEnabled = nativeFlags == 1
        let reviewFlags = arguments.filter { $0 == "--acceptance-recovery-review" }.count
        let reviewPositions = arguments.indices.filter { arguments[$0] == "--acceptance-review-descriptor" }
        let reviewStages = arguments.indices.filter { arguments[$0] == "--acceptance-review-stage" }
        guard reviewFlags <= 1, reviewFlags == 0 || (!inventoryStateEnabled && !webResultsEnabled && !nativeContentEnabled),
              reviewPositions.count == reviewFlags, reviewStages.count == reviewFlags else {
            throw ClaudeCollectionError.invalidConfiguration
        }
        reviewEnabled = reviewFlags == 1
        if reviewEnabled {
            guard let i = reviewStages.first, arguments.indices.contains(i + 1),
                  ["queue", "resume", "replay"].contains(arguments[i + 1]) else { throw ClaudeCollectionError.invalidConfiguration }
            reviewStage = arguments[i + 1]
        } else { reviewStage = nil }
        let desktopFlags = arguments.filter { $0 == "--acceptance-recovery-desktop-beta" }.count
        let desktopPositions = arguments.indices.filter { arguments[$0] == "--acceptance-desktop-beta-descriptor" }
        let desktopStages = arguments.indices.filter { arguments[$0] == "--acceptance-desktop-beta-stage" }
        guard desktopFlags <= 1, desktopFlags == 0 || (!inventoryStateEnabled && !webResultsEnabled && !nativeContentEnabled && !reviewEnabled),
              desktopPositions.count == desktopFlags, desktopStages.count == desktopFlags else { throw ClaudeCollectionError.invalidConfiguration }
        desktopBetaEnabled = desktopFlags == 1
        if desktopBetaEnabled {
            guard let i = desktopStages.first, arguments.indices.contains(i + 1),
                  ["scan", "replay"].contains(arguments[i + 1]) else { throw ClaudeCollectionError.invalidConfiguration }
            desktopBetaStage = arguments[i + 1]
        } else { desktopBetaStage = nil }
        if webResultsEnabled {
            guard sourcePositions.count == 1, let index = sourcePositions.first,
                  arguments.indices.contains(index + 1), let id = UUID(uuidString: arguments[index + 1]),
                  id.uuidString.lowercased() == arguments[index + 1] else {
                throw ClaudeCollectionError.invalidConfiguration
            }
            webSourceID = arguments[index + 1]
        } else {
            guard sourcePositions.isEmpty else { throw ClaudeCollectionError.invalidConfiguration }
            webSourceID = nil
        }
        func option(_ name: String) throws -> String {
            let positions = arguments.indices.filter { arguments[$0] == name }
            guard positions.count == 1, let i = positions.first, arguments.indices.contains(i + 1),
                  arguments[i + 1].hasPrefix("/"), !arguments[i + 1].utf8.contains(0) else {
                throw ClaudeCollectionError.invalidConfiguration
            }
            return arguments[i + 1]
        }
        let rootPath = try option("--acceptance-recovery-root")
        // Foundation can alias an existing /private/tmp directory to /tmp while keeping
        // nonexistent children under /private/tmp. Compare POSIX paths consistently instead.
        guard let canonicalRoot = realpath(rootPath, nil) else { throw ClaudeCollectionError.invalidConfiguration }
        defer { free(canonicalRoot) }
        guard String(cString: canonicalRoot) == rootPath else { throw ClaudeCollectionError.invalidConfiguration }
        let selectedRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
        root = selectedRoot
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              root.path != "/" else {
            throw ClaudeCollectionError.invalidConfiguration
        }
        func child(_ value: String) throws -> URL {
            let url = URL(fileURLWithPath: value)
            guard value == url.path, url.deletingLastPathComponent().path == selectedRoot.path,
                  ![".", ".."].contains(url.lastPathComponent) else {
                throw ClaudeCollectionError.invalidConfiguration
            }
            var childInfo = stat()
            if lstat(value, &childInfo) == 0 {
                guard (childInfo.st_mode & S_IFMT) != S_IFLNK else { throw ClaudeCollectionError.invalidConfiguration }
            } else if errno != ENOENT { throw ClaudeCollectionError.invalidConfiguration }
            return url
        }
        store = try child(option("--store-directory"))
        report = try child(option("--acceptance-report"))
        finish = try child(option("--acceptance-finish-file"))
        let token = try child(option("--acceptance-recovery-token"))
        guard Set([store.path, report.path, finish.path, token.path]).count == 4 else {
            throw ClaudeCollectionError.invalidConfiguration
        }
        let fd = open(token.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ClaudeCollectionError.invalidConfiguration }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size == 32 else {
            throw ClaudeCollectionError.invalidConfiguration
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let readCount = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard readCount == bytes.count else { throw ClaudeCollectionError.invalidConfiguration }
        authorization = Data(bytes)
        let reservedDescriptorPaths = Set([store.path, report.path, finish.path, token.path])
        func newDescriptor(_ optionName: String, basename: String, maximum: Int) throws -> Data {
            let descriptor = try child(option(optionName))
            guard descriptor.lastPathComponent == basename,
                  !reservedDescriptorPaths.contains(descriptor.path) else {
                throw ClaudeCollectionError.invalidConfiguration
            }
            let fd = open(descriptor.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw ClaudeCollectionError.invalidConfiguration }
            defer { close(fd) }
            var before = stat(), after = stat(), named = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                  before.st_uid == getuid(), before.st_mode & 0o077 == 0, before.st_nlink == 1,
                  before.st_size > 0, before.st_size <= maximum else { throw ClaudeCollectionError.invalidConfiguration }
            var content = [UInt8](repeating: 0, count: Int(before.st_size))
            let count = content.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count == content.count, fstat(fd, &after) == 0, lstat(descriptor.path, &named) == 0,
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_size == after.st_size, before.st_mode == after.st_mode,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                  before.st_dev == named.st_dev, before.st_ino == named.st_ino,
                  named.st_mode == before.st_mode, named.st_nlink == 1 else {
                throw ClaudeCollectionError.invalidConfiguration
            }
            return Data(content)
        }
        nativeContentDescriptorData = nativeContentEnabled
            ? try newDescriptor("--acceptance-native-content-descriptor", basename: "native-content-descriptor.json", maximum: 8192) : nil
        reviewDescriptorData = reviewEnabled
            ? try newDescriptor("--acceptance-review-descriptor", basename: "review-descriptor.json", maximum: 4096) : nil
        desktopBetaDescriptorData = desktopBetaEnabled
            ? try newDescriptor("--acceptance-desktop-beta-descriptor", basename: "desktop-beta-descriptor.json", maximum: 8192) : nil
    }

    public func controlURL(_ name: String) throws -> URL {
        let ordinary = ["stop-processing", "stop-codex-polling", "retry-terminal-codex-source",
                        "exit-with-pending", "owner-finish"]
        let inventory: [String]
        if upgradeRemovedStateEnabled { inventory = ["inventory-review-and-receipt", "inventory-obsolete-and-remove"] }
        else if upgradeStateEnabled { inventory = ["inventory-review-and-receipt", "inventory-acknowledge-revoked"] }
        else { inventory = ["inventory-review-and-receipt", "inventory-obsolete-and-remove", "inventory-replay-source"] }
        guard ordinary.contains(name) || (inventoryStateEnabled && inventory.contains(name))
            || (webResultsEnabled && name == "web-result-replay")
            || (nativeContentEnabled && name == "native-content-replay")
            else {
            throw ClaudeCollectionError.invalidConfiguration
        }
        return root.appendingPathComponent(name)
    }

    /// File contents are an opaque run token, never an instruction, source body or diagnostic.
    public func authorizes(_ url: URL) -> Bool {
        guard url.deletingLastPathComponent().path == root.path else { return false }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size == 32 else { return false }
        var bytes = [UInt8](repeating: 0, count: 32)
        let readCount = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        return readCount == bytes.count && Data(bytes) == authorization
    }

    public func requireFreshOwner(_ probe: StoreProtectionProbe) throws {
        guard probe.state == .empty, probe.manifest == nil else { throw KeyUnavailable.invalidManifest }
    }

    /// The runner observes this version; the production installer independently probes again.
    public func claudeProfile(arguments: [String]) throws -> (home: String, executable: String, version: String) {
        try ownedProfile(arguments: arguments, provider: .claudeCode)
    }

    public func codexProfile(arguments: [String]) throws -> (home: String, executable: String, version: String) {
        try ownedProfile(arguments: arguments, provider: .codex)
    }

    private func ownedProfile(arguments: [String], provider: AgentProvider) throws -> (home: String, executable: String, version: String) {
        func option(_ name: String) throws -> String {
            let positions = arguments.indices.filter { arguments[$0] == name }
            guard positions.count == 1, let i = positions.first, arguments.indices.contains(i + 1),
                  !arguments[i + 1].hasPrefix("--"), !arguments[i + 1].utf8.contains(0) else {
                throw ClaudeCollectionError.invalidConfiguration
            }
            return arguments[i + 1]
        }
        let home = try option("--acceptance-recovery-home")
        let executable = try option("--acceptance-recovery-executable")
        let version = try option("--acceptance-recovery-version")
        for path in [home, executable] {
            let url = URL(fileURLWithPath: path)
            guard path.hasPrefix("/"), url.path == path,
                  url.deletingLastPathComponent().path == root.path,
                  ![".", ".."].contains(url.lastPathComponent) else { throw ClaudeCollectionError.invalidConfiguration }
        }
        var info = stat()
        guard lstat(home, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw ClaudeCollectionError.invalidConfiguration }
        guard lstat(executable, &info) == 0, info.st_uid == getuid(),
              [S_IFREG, S_IFLNK].contains(info.st_mode & S_IFMT),
              CollectionCompatibility.isEligible(provider: provider, interface: .standaloneCLI, version: version) else {
            throw ClaudeCollectionError.invalidConfiguration
        }
        return (home, executable, version)
    }
}
