import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

@Suite("Spillcheck rename compatibility")
struct RenameCompatibilityTests {
    private func temporarySupport() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spillcheck-rename-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return root
    }

    @Test func movedVaultPreservesCiphertextManifestAndEncryptedPreferences() async throws {
        let root = try temporarySupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = root.appendingPathComponent("Leakret", isDirectory: true)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: previous, cryptography: crypto)
        let preference = Data("synthetic profile configuration".utf8)
        try await store.setProtectedPreference(preference, for: .agentProfiles)
        try await store.close()
        let databaseBytes = try Data(contentsOf: previous.appendingPathComponent(ProtectedStore.databaseFilename))
        let current = try AppStorageLocation.prepare(in: root)
        #expect(current.lastPathComponent == "Spillcheck")
        #expect(!FileManager.default.fileExists(atPath: previous.path))
        #expect(try Data(contentsOf: current.appendingPathComponent(ProtectedStore.databaseFilename)) == databaseBytes)
        #expect(try AppStorageLocation.prepare(in: root) == current)
        #expect(try ProtectedStore.probe(at: current).manifest == crypto.manifest)
        let reopened = try await ProtectedStore.open(at: current, cryptography: crypto)
        #expect(try await reopened.protectedPreference(.agentProfiles) == preference)
        try await reopened.close()
    }

    @Test func newInstallationUsesSpillcheckDirectory() throws {
        let root = try temporarySupport()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try AppStorageLocation.prepare(in: root) == root.appendingPathComponent("Spillcheck", isDirectory: true))
    }

    @Test func conflictingStoresAreLeftUntouched() throws {
        let root = try temporarySupport()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Leakret", "Spillcheck"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        #expect(throws: StorageError.unsafeStorageLocation) { try AppStorageLocation.prepare(in: root) }
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["Leakret", "Spillcheck"])
    }

    @Test(arguments: ["Leakret", "Spillcheck"])
    func symbolicLinksAreRejected(name: String) throws {
        let root = try temporarySupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = root.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: StorageError.unsafeStorageLocation) { try AppStorageLocation.prepare(in: root) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    }

    @Test(arguments: [AgentProvider.codex, .claudeCode])
    func legacyOwnedHooksAreReplacedAndRemovableWithoutTouchingOtherRegistrations(provider: AgentProvider) throws {
        let id = UUID()
        let legacy = "Leakret hook \(id.uuidString.lowercased())"
        let current = "Spillcheck hook \(id.uuidString.lowercased())"
        let foreign = "Leakret hook other-registration"
        let original: [String: Any] = ["unrelated": 42, "hooks": ["Stop": [["hooks": [
            ["type": "command", "command": "old-helper", "statusMessage": legacy],
            ["type": "command", "command": "new-helper", "statusMessage": current],
            ["type": "command", "command": "foreign-helper", "statusMessage": foreign]
        ]]]]]
        let bytes = try JSONSerialization.data(withJSONObject: original)
        let installed: Data
        let removed: Data
        let helper = URL(fileURLWithPath: "/usr/bin/true")
        let socket = URL(fileURLWithPath: "/tmp/spillcheck-test.sock")
        if provider == .codex {
            let config = try CodexHookConfiguration(registrationID: id, helperURL: helper, socketURL: socket,
                                                   profileID: "synthetic", agentVersion: CodexAdapter.validatedAgentVersion)
            installed = try config.editing(bytes, action: .install)
            #expect(config.isInstalled(in: installed))
            removed = try config.editing(bytes, action: .remove)
        } else {
            let config = try ClaudeHookConfiguration(registrationID: id, helperURL: helper, socketURL: socket,
                                                    profileID: "synthetic", agentVersion: ClaudeAdapter.validatedAgentVersion)
            installed = try config.editing(bytes, action: .install)
            #expect(config.isInstalled(in: installed))
            removed = try config.editing(bytes, action: .remove)
        }
        let installedText = String(decoding: installed, as: UTF8.self)
        #expect(!installedText.contains(legacy))
        #expect(installedText.contains(current))
        #expect(installedText.contains(foreign))
        let expected: [String: Any] = ["unrelated": 42, "hooks": ["Stop": [["hooks": [
            ["type": "command", "command": "foreign-helper", "statusMessage": foreign]
        ]]]]]
        #expect(try JSONSerialization.jsonObject(with: removed) as? NSDictionary == expected as NSDictionary)
    }
}
