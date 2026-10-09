import Darwin
import Foundation

/// Private, disposable signed acceptance controls. No release app entry point uses this SPI.
@_spi(Testing) public struct DisposableRecoveryConfiguration: Sendable {
    public let root: URL
    public let store: URL
    public let report: URL
    public let finish: URL
    private let authorization: Data

    public init(arguments: [String]) throws {
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
    }

    public func controlURL(_ name: String) throws -> URL {
        guard ["stop-processing", "exit-with-pending", "owner-finish"].contains(name) else {
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
              CollectionCompatibility.isEligible(provider: .claudeCode, interface: .standaloneCLI, version: version) else {
            throw ClaudeCollectionError.invalidConfiguration
        }
        return (home, executable, version)
    }
}
