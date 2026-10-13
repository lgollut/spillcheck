#if DEBUG
import AppKit
@_spi(Testing) import SpillcheckCore

/// A separate signed process retains only cleanup ownership while collector processes restart.
/// It never scans, accepts captures, reveals inventory, or authorizes a loaded manifest to delete keys.
@MainActor enum SignedRecoveryVaultOwner {
    /// A closed diagnostic projection. This never reads protection state or grants cleanup authority.
    nonisolated static func failureReport(_ error: any Error,
        startupPhase: StorageStartupFailure.Phase?, at time: Date = Date()) -> [String: Any] {
        var details: [String: Any] = ["failureCategory": error is KeyUnavailable || error is ProtectionBootstrapError
            ? "protection" : "owner-configuration-or-lifecycle"]
        if let startupPhase {
            let failure = StorageStartupFailure(error: error, phase: startupPhase, at: time)
            if let bytes = try? DiagnosticsExport.encode(failure),
               let encoded = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                details["startupFailure"] = encoded
            }
        }
        return details
    }

    static func run(arguments: [String]) async {
        var configuration: DisposableRecoveryConfiguration?
        var services: ProtectionServices?
        var startupPhase: StorageStartupFailure.Phase? = .preparingStorage
        var report: [String: Any] = ["ownerReady": false, "createdFreshVault": false, "cleanupPassed": false]
        func write() {
            guard let configuration,
                  let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
            try? data.write(to: configuration.report, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.report.path)
        }
        do {
            let selected = try DisposableRecoveryConfiguration(arguments: arguments)
            configuration = selected
            startupPhase = .probingStorage
            let probe = try ProtectedStore.probe(at: selected.store)
            try selected.requireFreshOwner(probe)
            startupPhase = .loadingDeviceKeys
            guard let accessGroup = Bundle.main.object(forInfoDictionaryKey: "SpillcheckKeychainAccessGroup") as? String,
                  !accessGroup.isEmpty, !accessGroup.contains("$(") else { throw KeyUnavailable.accessGroupUnavailable }
            let created = try await ProtectionBootstrap.prepare(at: selected.store, manifest: nil, storeState: .empty,
                configuration: .init(accessGroup: accessGroup))
            services = created
            startupPhase = .openingStore
            let store = try await ProtectedStore.open(at: selected.store, cryptography: created.background)
            try await store.close()
            startupPhase = .committingBootstrap
            try created.commitBootstrap()
            startupPhase = nil
            report["createdFreshVault"] = created.createdNewManifest
            report["ownerReady"] = true
            write()
            let deadline = ContinuousClock.now.advanced(by: .seconds(900))
            let finish = try selected.controlURL("owner-finish")
            while !selected.authorizes(finish), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }
            // A timed-out owner leaves its exact vault intact. The runner signals only after
            // its owned collector processes have exited and the registration is removed.
            guard selected.authorizes(finish) else { throw ClaudeCollectionError.invalidConfiguration }
            report["cleanupPassed"] = try await created.removeNewlyCreatedProtectionForTesting()
        } catch {
            if report["ownerReady"] as? Bool != true, let services, services.createdNewManifest {
                // No worker was admitted. Roll back only this attempt's fresh keys if opening
                // the empty owned store failed after protection preparation succeeded.
                report["cleanupPassed"] = (try? await services.removeNewlyCreatedProtectionForTesting()) == true
            }
            for (key, value) in failureReport(error, startupPhase: startupPhase) { report[key] = value }
            report["ownerReady"] = false
            // Bootstrap retains exact pending identities when rollback cannot be confirmed.
            // Never remove a ready vault because a worker or lifecycle signal was unavailable.
        }
        write()
    }
}
#endif
