import Darwin
import Foundation

public enum CodexSetupError: Error, Equatable, Sendable {
    case unsupportedVersion, invalidConfiguration, malformedHooks, unsafeHooksPath
    case hooksChanged, writeFailed, verificationFailed
}

public enum CodexSetupState: String, Sendable { case notInstalled, installedUnverified, connected, needsRepair, unsupportedVersion }
public enum CodexHookEdit: Sendable { case install, remove }

/// The ownership UUID comes from protected app settings. Only handlers bearing that exact marker
/// are replaced/removed. Other handlers, matchers and root settings survive semantically unchanged.
public struct CodexHookConfiguration: Sendable {
    public static let events = ["SessionStart", "UserPromptSubmit", "PostToolUse",
                                "SubagentStart", "SubagentStop", "Stop", "SessionEnd"]
    public let registrationID: UUID
    public let helperURL: URL
    public let socketURL: URL
    public let profileID: String
    public let interface: AgentInterface
    public let agentVersion: String
    public var ownershipMarker: String { "Spillcheck hook \(registrationID.uuidString.lowercased())" }
    private var legacyOwnershipMarker: String { "Leakret hook \(registrationID.uuidString.lowercased())" }
    public var arguments: [String] { ["--socket", socketURL.path, "--agent", "codex", "--interface", interface.rawValue, "--profile-id", profileID] }

    public init(registrationID: UUID, helperURL: URL, socketURL: URL, profileID: String,
                interface: AgentInterface = .standaloneCLI, agentVersion: String) throws {
        guard helperURL.isFileURL, socketURL.isFileURL, helperURL.path.hasPrefix("/"),
              socketURL.path.hasPrefix("/"), !profileID.isEmpty, profileID.utf8.count <= 256,
              ![helperURL.path, socketURL.path, profileID].contains(where: { $0.utf8.contains(0) }) else {
            throw CodexSetupError.invalidConfiguration
        }
        self.registrationID = registrationID; self.helperURL = helperURL; self.socketURL = socketURL
        self.profileID = profileID; self.interface = interface; self.agentVersion = agentVersion
    }

    public var command: String { ([helperURL.path] + arguments).map(Self.quote).joined(separator: " ") }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    /// The recognized hook settings contract accepts a shell command string. Quote fixed configuration;
    /// source text is never interpolated and hook trust remains Codex-owned.
    public func editing(_ data: Data?, action: CodexHookEdit) throws -> Data {
        if action == .install, !CollectionCompatibility.isEligible(provider: .codex, interface: interface, version: agentVersion) {
            throw CodexSetupError.unsupportedVersion
        }
        var root: [String: Any]
        if let data {
            guard data.count <= 1024 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: data), let settings = object as? [String: Any] else {
                throw CodexSetupError.malformedHooks
            }
            root = settings
        } else { root = [:] }
        guard root["hooks"] == nil || root["hooks"] is [String: Any] else { throw CodexSetupError.malformedHooks }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // Remove only this registration's exact handler, including duplicates left by interrupted repair.
        for event in hooks.keys {
            guard let groups = hooks[event] as? [[String: Any]] else { throw CodexSetupError.malformedHooks }
            var preserved: [[String: Any]] = []
            for var group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else { throw CodexSetupError.malformedHooks }
                let retained = handlers.filter {
                    let marker = $0["statusMessage"] as? String
                    return marker != ownershipMarker && marker != legacyOwnershipMarker
                }
                if retained.isEmpty, retained.count != handlers.count { continue }
                group["hooks"] = retained; preserved.append(group)
            }
            if preserved.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = preserved }
        }
        if action == .install {
            for event in Self.events {
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups.append(["hooks": [["type": "command", "command": command, "timeout": 2, "statusMessage": ownershipMarker]]])
                hooks[event] = groups
            }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        let encoded = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard encoded.count <= 1024 * 1024 else { throw CodexSetupError.malformedHooks }
        return encoded
    }

    public func isInstalled(in data: Data) -> Bool {
        guard let expected = try? editing(data, action: .install),
              let a = try? JSONSerialization.jsonObject(with: data) as? NSDictionary,
              let b = try? JSONSerialization.jsonObject(with: expected) as? NSDictionary else { return false }
        return a == b
    }
}

public struct CodexSetupChallenge: Sendable {
    public let prompt: String
    public let profileID: String
    public let configuration: CodexHookConfiguration
}

/// A receipt must come from the running receiver after encrypted enqueue has committed.
public struct CodexSetupEvidence: Sendable {
    public let packet: CapturePacket
    public let durableQueueID: UUID
    public init(packet: CapturePacket, durableQueueID: UUID) { self.packet = packet; self.durableQueueID = durableQueueID }
}

public actor CodexHookSetup {
    public let hooksURL: URL
    public let configuration: CodexHookConfiguration
    public private(set) var state: CodexSetupState = .notInstalled
    private var challenge: String?

    public init(hooksURL: URL, configuration: CodexHookConfiguration) throws {
        guard hooksURL.isFileURL, hooksURL.path.hasPrefix("/") else { throw CodexSetupError.invalidConfiguration }
        self.hooksURL = codexConfiguredURL(hooksURL.deletingLastPathComponent()).appendingPathComponent(hooksURL.lastPathComponent)
        self.configuration = configuration
        if !CollectionCompatibility.isEligible(provider: .codex, interface: configuration.interface, version: configuration.agentVersion) {
            state = .unsupportedVersion
        }
    }

    @discardableResult public func install() throws -> CodexSetupState {
        guard state != .unsupportedVersion else { throw CodexSetupError.unsupportedVersion }
        guard FileManager.default.isExecutableFile(atPath: configuration.helperURL.path) else {
            throw CodexSetupError.invalidConfiguration
        }
        try edit(.install); challenge = nil; state = .installedUnverified; return state
    }

    @discardableResult public func repair() throws -> CodexSetupState { try install() }

    public func remove() throws { try edit(.remove); challenge = nil; state = .notInstalled }

    public func check() throws -> CodexSetupState {
        guard state != .unsupportedVersion else { return state }
        let data = try readHooks()
        if let data, configuration.isInstalled(in: data) {
            if state != .connected { state = .installedUnverified }
        } else { state = .needsRepair; challenge = nil }
        return state
    }

    public func beginVerification() throws -> CodexSetupChallenge {
        guard try check() == .installedUnverified || state == .connected else { throw CodexSetupError.verificationFailed }
        let prompt = "SPILLCHECK_SETUP_SYNTHETIC_\(UUID().uuidString)"
        challenge = prompt; state = .installedUnverified
        return CodexSetupChallenge(prompt: prompt, profileID: configuration.profileID, configuration: configuration)
    }

    public func acceptVerification(_ evidence: CodexSetupEvidence) throws {
        guard let challenge, try check() == .installedUnverified,
              evidence.packet.metadata.agent == .codex,
              evidence.packet.metadata.profileID == configuration.profileID,
              evidence.packet.metadata.interface == configuration.interface,
              let hook = try? JSONSerialization.jsonObject(with: evidence.packet.eventJSON) as? [String: Any],
              hook["hook_event_name"] as? String == "UserPromptSubmit",
              hook["prompt"] as? String == challenge,
              let session = hook["session_id"] as? String, !session.isEmpty else {
            throw CodexSetupError.verificationFailed
        }
        self.challenge = nil; state = .connected
    }

    private func readHooks() throws -> Data? {
        let directory = try hooksDirectory()
        defer { close(directory) }
        return try readHooks(in: directory)
    }

    private func hooksDirectory() throws -> Int32 {
        let parent = hooksURL.deletingLastPathComponent()
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw CodexSetupError.unsafeHooksPath }
        do {
            for part in parent.path.split(separator: "/") {
                let next = String(part).withCString { openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                guard next >= 0 else { throw CodexSetupError.unsafeHooksPath }
                close(fd); fd = next
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid() else { throw CodexSetupError.unsafeHooksPath }
            return fd
        } catch { close(fd); throw error }
    }

    private func readHooks(in directory: Int32) throws -> Data? {
        var info = stat()
        let name = hooksURL.lastPathComponent
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }; throw CodexSetupError.unsafeHooksPath
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_size <= 1024 * 1024 else {
            throw CodexSetupError.unsafeHooksPath
        }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CodexSetupError.unsafeHooksPath }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev else {
            throw CodexSetupError.hooksChanged
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var bytes = Data()
        while let part = try handle.read(upToCount: min(64 * 1024, 1024 * 1024 + 1 - bytes.count)), !part.isEmpty {
            bytes.append(part)
            guard bytes.count <= 1024 * 1024 else { throw CodexSetupError.malformedHooks }
        }
        return bytes
    }

    private func edit(_ action: CodexHookEdit) throws {
        let directory = try hooksDirectory()
        defer { close(directory) }
        let original = try readHooks(in: directory)
        if action == .remove, original == nil { return }
        let updated = try configuration.editing(original, action: action)
        if original == updated { return }
        let temporary = ".spillcheck-hooks-\(UUID().uuidString).tmp"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CodexSetupError.writeFailed }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        try updated.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let n = write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw CodexSetupError.writeFailed }; written += n
            }
        }
        guard fsync(fd) == 0 else { throw CodexSetupError.writeFailed }
        // Refuse to replace settings changed since the merge; this is not a blind overwrite.
        guard try readHooks(in: directory) == original else { throw CodexSetupError.hooksChanged }
        guard renameat(directory, temporary, directory, hooksURL.lastPathComponent) == 0 else { throw CodexSetupError.writeFailed }
        guard fsync(directory) == 0 else { throw CodexSetupError.writeFailed }
    }
}
