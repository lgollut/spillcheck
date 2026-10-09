// Standalone production-implementation probe. Compile this with SourceContracts.swift,
// StorageContracts.swift and Protection.swift; then package/sign it with Spillcheck's own
// app identity, provisioning profile and Keychain entitlement before running.
import AppKit
import Foundation
import LocalAuthentication
import Security
#if canImport(SpillcheckCore)
@_spi(Testing) import SpillcheckCore
#endif

private struct ProbeReport: Codable {
    let checks: [String: Bool]
    let interactiveAuthorizationRequested: Bool
    let interactiveAuthorizationPassed: Bool
    let failure: String?
    let errorCode: Int?
}

@MainActor
private final class ProbeAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var label: NSTextField?
    private var button: NSButton?
    private var started = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProtectionSignedProbe.isInteractive {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Spillcheck production vault probe"
            window.isReleasedWhenClosed = false
            let label = NSTextField(wrappingLabelWithString:
                "Verify Spillcheck's production vault with a synthetic value. Complete the macOS authentication prompt when requested.")
            label.frame = NSRect(x: 24, y: 76, width: 392, height: 60)
            window.contentView?.addSubview(label)
            self.label = label
            let button = NSButton(title: "Verify production vault", target: self, action: #selector(verify))
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 24, y: 22, width: 240, height: 34)
            window.contentView?.addSubview(button)
            self.button = button
            window.center()
            self.window = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else { startOnce() }
    }

    @objc private func verify() {
        NSApp.activate(ignoringOtherApps: true)
        button?.isEnabled = false
        label?.stringValue = "Running safe checks. Complete the system authentication prompt."
        startOnce()
    }

    func finished(passed: Bool, failure: String?) {
        label?.stringValue = passed
            ? "Production vault verified. Exact synthetic bytes were recovered and the private key was locked again."
            : "Verification did not pass: \(failure ?? "check-failed"). The safe report contains the result."
        button?.title = "Close probe"
        button?.action = #selector(closeProbe)
        button?.isEnabled = true
    }

    @objc private func closeProbe() { NSApp.terminate(nil) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func startOnce() {
        guard !started else { return }
        started = true
        Task { @MainActor in await ProtectionSignedProbe.run() }
    }
}

@main
private struct ProtectionSignedProbe {
    static var isInteractive: Bool {
        CommandLine.arguments.contains("--authorize") || !CommandLine.arguments.contains("--directory")
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ProbeAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(isInteractive ? .regular : .prohibited)
        app.run()
        withExtendedLifetime(delegate) {}
    }

    @MainActor static func run() async {
        let args = CommandLine.arguments
        func argument(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        guard let group = argument("--access-group") ?? Bundle.main.object(forInfoDictionaryKey: "SpillcheckKeychainAccessGroup") as? String,
              let directoryPath = argument("--directory") ?? Bundle.main.object(forInfoDictionaryKey: "SpillcheckProbeDirectory") as? String else {
            print("Usage: ProtectionSignedProbe --access-group TEAM.com.leakret.app --directory ISOLATED_DIRECTORY [--authorize]")
            exit(64)
        }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let configuration = ProtectionConfiguration(accessGroup: group,
                                                     identifierPrefix: "com.leakret.app.protection-probe")
        let authorize = isInteractive
        var checks: [String: Bool] = [:]
        var interactivePassed = false
        var failure: String?
        var errorCode: Int?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let manifestURL = directory.appendingPathComponent("manifest.json")
            let payloadURL = directory.appendingPathComponent("inventory.json")
            let existing = FileManager.default.fileExists(atPath: manifestURL.path)
                ? try JSONDecoder().decode(ProtectionManifest.self, from: Data(contentsOf: manifestURL)) : nil
            let state: StoreProtectionState = FileManager.default.fileExists(atPath: payloadURL.path)
                ? .protectedDataPresent : .empty
            let services = try await ProtectionBootstrap.prepare(manifest: existing, storeState: state,
                                                                 configuration: configuration)
            if services.createdNewManifest {
                try writePrivate(JSONEncoder().encode(services.manifest), to: manifestURL)
            }
            checks["bootstrap-with-real-keychain-and-persisted-right"] = true
            let backgroundBinding = PayloadBinding(reference: ProtectedPayloadReference(), ownerID: UUID(), kind: .queueEvent)
            let syntheticQueue = Data("SYNTHETIC-SPILLCHECK-PRODUCTION-QUEUE-Ä\n".utf8)
            let queue = try await services.background.sealBackground(syntheticQueue, binding: backgroundBinding)
            checks["real-queue-key-round-trip"] = try await services.background.openBackground(queue, binding: backgroundBinding) == syntheticQueue
            let reloaded = try await ProtectionBootstrap.prepare(manifest: services.manifest, storeState: .protectedDataPresent,
                                                                 configuration: configuration)
            checks["real-key-reload-opens-queue"] = try await reloaded.background.openBackground(queue, binding: backgroundBinding) == syntheticQueue
            let originalFingerprint = try await services.background.fingerprint(exactBytes: syntheticQueue)
            let reloadedFingerprint = try await reloaded.background.fingerprint(exactBytes: syntheticQueue)
            let revision = try await reloaded.background.revision(canonicalBytes: syntheticQueue)
            checks["real-identity-key-stable-and-domain-separated"] = reloadedFingerprint == originalFingerprint
                && revision.keyedDigest != originalFingerprint.keyedDigest
            let syntheticInventory = Data("SYNTHETIC-SPILLCHECK-PRODUCTION-VALUE-Ä-🔐\n".utf8)
            // This is an intentional disposable synthetic upstream fixture, never a queue spool.
            let sourceURL = directory.appendingPathComponent("disposable-synthetic-source.txt")
            try writePrivate(syntheticInventory, to: sourceURL)
            defer { try? FileManager.default.removeItem(at: sourceURL) }
            let sourceBytes = try Data(contentsOf: sourceURL)
            let payload: ProtectedPayload
            if FileManager.default.fileExists(atPath: payloadURL.path) {
                payload = try ProtectedPayload.decode(Data(contentsOf: payloadURL))
            } else {
                let context = PayloadBinding(reference: ProtectedPayloadReference(), ownerID: UUID(), kind: .value)
                payload = try await services.background.sealInventory(sourceBytes, binding: context)
                try writePrivate(payload.encoded(), to: payloadURL)
            }
            try FileManager.default.removeItem(at: sourceURL)
            checks["disposable-source-removed-before-reveal"] = sourceBytes == syntheticInventory
                && !FileManager.default.fileExists(atPath: sourceURL.path)
            checks["exported-LA-public-key-SecKey-wrap-while-locked"] = !services.viewingSession.isAuthorized && payload.wrappedDataKey?.isEmpty == false
            checks["production-private-operation-denied-while-locked"] = await services.viewingSession.privateOperationDeniedForTesting(payload)
            let right = try await LARightStore.shared.right(forIdentifier: services.manifest.inventoryRightID)
            await right.deauthorize()
            do {
                _ = try await right.key.decrypt(payload.wrappedDataKey!, algorithm: .eciesEncryptionStandardVariableIVX963SHA256AESGCM)
                checks["direct-private-operation-denied-while-locked"] = false
            } catch {
                checks["direct-private-operation-denied-while-locked"] = true
            }
            checks["disk-has-no-synthetic-plaintext"] = try [manifestURL, payloadURL].allSatisfy {
                let bytes = try Data(contentsOf: $0)
                return bytes.range(of: syntheticQueue) == nil && bytes.range(of: syntheticInventory) == nil
            }
            var unknownKey = services.manifest
            unknownKey = ProtectionManifest(vaultID: unknownKey.vaultID, queueKeyID: UUID(),
                                             identityKeyID: unknownKey.identityKeyID,
                                             inventoryRightID: unknownKey.inventoryRightID)
            do {
                _ = try await ProtectionBootstrap.prepare(manifest: unknownKey, storeState: .protectedDataPresent,
                                                           configuration: configuration)
                checks["missing-queue-key-fails-without-replacement"] = false
            } catch KeyUnavailable.missingKey(.queue) {
                checks["missing-queue-key-fails-without-replacement"] = true
            }
            let missingIdentity = ProtectionManifest(vaultID: services.manifest.vaultID,
                                                     queueKeyID: services.manifest.queueKeyID, identityKeyID: UUID(),
                                                     inventoryRightID: services.manifest.inventoryRightID)
            do {
                _ = try await ProtectionBootstrap.prepare(manifest: missingIdentity, storeState: .protectedDataPresent,
                                                           configuration: configuration)
                checks["missing-identity-key-fails-without-replacement"] = false
            } catch KeyUnavailable.missingKey(.identity) {
                checks["missing-identity-key-fails-without-replacement"] = true
            }
            let absentVaultID = UUID()
            let absentRight = ProtectionManifest(vaultID: absentVaultID, queueKeyID: services.manifest.queueKeyID,
                                                 identityKeyID: services.manifest.identityKeyID,
                                                 inventoryRightID: "\(configuration.identifierPrefix).inventory.v1.\(absentVaultID.uuidString)")
            do {
                _ = try await ProtectionBootstrap.prepare(manifest: absentRight, storeState: .protectedDataPresent,
                                                           configuration: configuration)
                checks["missing-inventory-right-fails-without-replacement"] = false
            } catch KeyUnavailable.missingKey(.inventory) {
                checks["missing-inventory-right-fails-without-replacement"] = true
            } catch KeyUnavailable.unusableKey(.inventory, _) {
                checks["missing-inventory-right-fails-without-replacement"] = true
            }
            do {
                _ = try await ProtectionBootstrap.prepare(manifest: nil, storeState: .protectedDataPresent,
                                                           configuration: configuration)
                checks["missing-manifest-preserves-protected-state"] = false
            } catch KeyUnavailable.missingManifest {
                checks["missing-manifest-preserves-protected-state"] = FileManager.default.fileExists(atPath: payloadURL.path)
            }
            if authorize {
                // Root/user controls this optional interactive run. No successful system
                // authorization or authentication method is inferred from a noninteractive run.
                // Use the fresh reloaded context for authorization, independently of the
                // earlier explicit unauthorized-operation probe on the first context.
                let revealed = try await reloaded.viewingSession.reveal(
                    payload, binding: payload.binding,
                    localizedReason: "Verify Spillcheck's production vault using a synthetic value"
                )
                interactivePassed = revealed == syntheticInventory
                checks["SecKey-wrapped-key-LA-authenticated-exact-unwrap"] = interactivePassed
                reloaded.viewingSession.invalidate(reason: .windowClose)
                checks["immediate-production-mask"] = reloaded.viewingSession.revealed.isEmpty && !reloaded.viewingSession.isAuthorized
                await reloaded.viewingSession.deauthorize()
                checks["private-operation-denied-after-production-mask"] = await reloaded.viewingSession.privateOperationDeniedForTesting(payload)
            }
        } catch {
            checks["probe-completed"] = false
            switch error {
            case ViewingAuthorizationError.cancelled: failure = "authorization-cancelled"
            case ViewingAuthorizationError.unavailable(let code): failure = "authorization-unavailable"; errorCode = code
            case ViewingAuthorizationError.denied(let code): failure = "authorization-denied"; errorCode = code
            case ViewingAuthorizationError.invalidated: failure = "authorization-invalidated"
            case ViewingAuthorizationError.busy: failure = "authorization-busy"
            case KeyUnavailable.unusableKey(_, let code): failure = "key-unusable"; errorCode = code
            case let error as KeyUnavailable: failure = "key-unavailable"; errorCode = (error as NSError).code
            case let error as ProtectionError: failure = "cryptography-failure"; errorCode = (error as NSError).code
            default: failure = "probe-failure"; errorCode = (error as NSError).code
            }
        }
        let report = ProbeReport(checks: checks, interactiveAuthorizationRequested: authorize,
                                 interactiveAuthorizationPassed: interactivePassed, failure: failure, errorCode: errorCode)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
            if let path = Bundle.main.object(forInfoDictionaryKey: "SpillcheckProbeReportPath") as? String {
                let url = URL(fileURLWithPath: path)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try? writePrivate(data, to: url)
            }
        }
        let passed = checks.values.allSatisfy { $0 } && (!authorize || interactivePassed)
        if isInteractive {
            (NSApp.delegate as? ProbeAppDelegate)?.finished(passed: passed, failure: failure)
        } else { exit(passed ? 0 : 1) }
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
