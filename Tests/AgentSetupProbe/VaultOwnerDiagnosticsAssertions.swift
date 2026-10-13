import Foundation
import SpillcheckCore

enum VaultOwnerDiagnosticAssertionFailure: Error { case failed(String) }

func vaultOwnerDiagnosticsAssertions() throws -> [String] {
    func require(_ condition: Bool, _ name: String) throws {
        guard condition else { throw VaultOwnerDiagnosticAssertionFailure.failed(name) }
    }
    let time = Date(timeIntervalSince1970: 1_792_000_000)
    for phase in [StorageStartupFailure.Phase.preparingStorage, .probingStorage, .loadingDeviceKeys,
                  .openingStore, .committingBootstrap] {
        let report = SignedRecoveryVaultOwner.failureReport(KeyUnavailable.unusableKey(.queue, code: -25291),
            startupPhase: phase, at: time)
        let details = report["startupFailure"] as? [String: Any]
        try require(report["failureCategory"] as? String == "protection"
            && details?["phase"] as? String == phase.rawValue
            && details?["reason"] as? String == "keyUnusable"
            && details?["component"] as? String == "queue" && details?["nativeStatusCode"] as? Int == -25291,
            "vault-owner-lost-exact-startup-phase-or-controlled-key-status")
        try require(Set(report.keys) == ["failureCategory", "startupFailure"]
            && Set(details?.keys.map { $0 } ?? []) == ["phase", "reason", "occurredAt", "component", "nativeStatusCode"],
            "vault-owner-diagnostic-added-uncontrolled-fields")
    }
    for failure in [ProtectionBootstrapError.busy, .rollbackIncomplete, .commitUnconfirmed] {
        let report = SignedRecoveryVaultOwner.failureReport(failure, startupPhase: .committingBootstrap, at: time)
        let details = report["startupFailure"] as? [String: Any]
        let expected = StorageStartupFailure(error: failure, phase: .committingBootstrap, at: time)
        try require(report["failureCategory"] as? String == "protection"
            && details?["reason"] as? String == expected.reason.rawValue
            && details?["component"] == nil && details?["nativeStatusCode"] == nil,
            "vault-owner-bootstrap-failure-invented-key-status")
    }
    let sentinel = "PRIVATE_OWNER_PATH_KEY_ID_FRAMEWORK_MESSAGE"
    let unknown = NSError(domain: sentinel, code: 783_261_054,
        userInfo: [NSLocalizedDescriptionKey: sentinel, NSFilePathErrorKey: "/\(sentinel)"])
    let report = SignedRecoveryVaultOwner.failureReport(unknown, startupPhase: .openingStore, at: time)
    let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    let text = String(decoding: bytes, as: UTF8.self)
    let details = report["startupFailure"] as? [String: Any]
    try require(report["failureCategory"] as? String == "owner-configuration-or-lifecycle"
        && details?["phase"] as? String == "openingStore" && details?["reason"] as? String == "unknown"
        && details?["nativeStatusCode"] == nil && bytes.count < 1024
        && !text.contains(sentinel) && !text.contains("783261054") && !text.contains("userInfo")
        && !text.contains("domain"), "vault-owner-diagnostic-retained-private-error-content")

    let lifecycle = SignedRecoveryVaultOwner.failureReport(KeyUnavailable.unusableKey(.inventory, code: -25291),
        startupPhase: nil, at: time)
    try require(Set(lifecycle.keys) == ["failureCategory"] && lifecycle["failureCategory"] as? String == "protection",
        "vault-owner-lifecycle-failure-mislabeled-as-startup")
    for report in [report, lifecycle] {
        for field in ["cleanupPassed", "createdFreshVault", "ownerReady", "rollbackSucceeded", "manifest", "keyID"] {
            try require(report[field] == nil, "vault-owner-diagnostic-inferred-cleanup-or-exported-identity")
        }
    }
    return ["vault-owner-diagnostics-preserve-startup-phase-and-controlled-key-status",
            "vault-owner-bootstrap-failures-do-not-invent-key-status",
            "vault-owner-diagnostics-exclude-unknown-error-content",
            "vault-owner-lifecycle-failure-does-not-infer-startup-or-cleanup-success"]
}
