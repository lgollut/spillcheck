import Foundation
import SpillcheckCore

enum StartupDiagnosticAssertionFailure: Error { case failed(String) }

@MainActor
func startupDiagnosticsAssertions() throws -> [String] {
    func require(_ condition: Bool, _ name: String) throws {
        guard condition else { throw StartupDiagnosticAssertionFailure.failed(name) }
    }
    let opening = AppModel()
    try require(opening.processingText == "Opening vault", "unopened-vault-claims-monitoring-or-waiting-for-content")
    try require(opening.processingShort == "Opening" && opening.inventoryStatusTitle == "Opening inventory"
        && EmptyInventoryState(model: opening)?.kind == .storageUnavailable,
        "opening-vault-claims-empty-inventory")
    let failed = AppModel()
    failed.storageFailed = true
    failed.pauseAfterBarrier()
    try require(failed.processingText == "Vault unavailable", "failed-vault-reported-as-user-pause")
    try require(failed.coverageSummaryText == "Analysis and inventory are unavailable until the vault opens.",
        "failed-vault-directs-user-to-agent-setup")
    try require(failed.processingShort == "Unavailable" && failed.monitoringStatusText == "Vault unavailable"
        && failed.coverageStateText == "Coverage unavailable" && failed.inventoryStatusTitle == "Inventory unavailable"
        && EmptyInventoryState(model: failed)?.kind == .storageUnavailable,
        "failed-vault-claims-zero-inventory-or-coverage")

    let time = Date(timeIntervalSince1970: 1_792_000_000)
    let bootstrapCases: [(ProtectionBootstrapError, StorageStartupFailure.Reason)] = [
        (.busy, .bootstrapBusy), (.unsafeJournal, .bootstrapUnsafeJournal),
        (.journalUnavailable, .bootstrapJournalUnavailable),
        (.manifestMismatch, .bootstrapManifestMismatch), (.commitUnconfirmed, .bootstrapCommitUnconfirmed),
        (.rollbackIncomplete, .bootstrapRollbackIncomplete)
    ]
    for (error, reason) in bootstrapCases {
        let failure = StorageStartupFailure(error: error, phase: .loadingDeviceKeys, at: time)
        try require(failure.reason == reason && failure.component == nil && failure.nativeStatusCode == nil
            && failure.phase == .loadingDeviceKeys && failure.occurredAt == time,
            "startup-bootstrap-failure-lost-controlled-details")
        failed.startupFailure = failure
        let bytes = try DiagnosticsExport.encoded(model: failed, at: time)
        let json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let details = json["startupFailure"] as! [String: Any]
        try require(json["exportType"] as? String == "startupFailure"
            && json["coverageAvailable"] as? Bool == false && details["reason"] as? String == reason.rawValue
            && details["phase"] as? String == "loadingDeviceKeys", "startup-export-lost-typed-failure")
        for unavailableField in ["queue", "gaps", "routes", "audits", "window", "eventQuery", "omissionQuery", "historyQuery"] {
            try require(json[unavailableField] == nil, "startup-export-invented-coverage-evidence")
        }
        try require(bytes.count < 2048, "startup-diagnostics-exceeded-bounded-size")
    }

    for component in [KeyComponent.queue, .identity, .inventory] {
        let failure = StorageStartupFailure(error: KeyUnavailable.unusableKey(component, code: -25308),
            phase: .loadingDeviceKeys, at: time)
        try require(failure.reason == .keyUnusable && failure.component == component && failure.nativeStatusCode == -25308,
            "startup-key-failure-lost-component-or-native-status")
        let missing = StorageStartupFailure(error: KeyUnavailable.missingKey(component), phase: .loadingDeviceKeys)
        try require(missing.reason == .keyMissing && missing.component == component && missing.nativeStatusCode == nil,
            "startup-missing-key-invented-status")
    }
    let keyCases: [(KeyUnavailable, StorageStartupFailure.Reason)] = [
        (.missingManifest, .keyMissingManifest), (.invalidManifest, .keyInvalidManifest),
        (.accessGroupUnavailable, .keyAccessGroupUnavailable),
        (.unsupportedInventoryAlgorithm, .keyUnsupportedInventoryAlgorithm)
    ]
    for (error, reason) in keyCases {
        let failure = StorageStartupFailure(error: error, phase: .preparingStorage)
        try require(failure.reason == reason && failure.component == nil && failure.nativeStatusCode == nil,
            "startup-key-failure-classification-changed")
    }
    let storageCases: [(StorageError, StorageStartupFailure.Reason)] = [
        (.unsafeStorageLocation, .storageUnsafeLocation), (.databaseUnavailable, .storageDatabaseUnavailable),
        (.manifestMissing, .storageManifestMissing), (.manifestMismatch, .storageManifestMismatch),
        (.corruptProtectedState, .storageCorruptProtectedState), (.protectionUnavailable, .storageProtectionUnavailable),
        (.stateTooLarge, .storageUnavailable)
    ]
    for (error, reason) in storageCases {
        try require(StorageStartupFailure(error: error, phase: .openingStore).reason == reason,
            "startup-store-failure-classification-changed")
    }

    let privateSentinel = "PRIVATE_STARTUP_VALUE_PATH_KEY_ID_NATIVE_ERROR"
    let unknown = NSError(domain: privateSentinel, code: 783_261_054,
        userInfo: [NSLocalizedDescriptionKey: privateSentinel, NSFilePathErrorKey: "/\(privateSentinel)"])
    failed.startupFailure = StorageStartupFailure(error: unknown, phase: .openingStore, at: time)
    failed.storageMessage = privateSentinel
    failed.agentProfiles[.codex] = .init(provider: .codex, profileID: privateSentinel,
        executablePath: privateSentinel, homePath: privateSentinel, version: privateSentinel, installed: true)
    let unknownBytes = try DiagnosticsExport.encoded(model: failed, at: time)
    let unknownText = String(decoding: unknownBytes, as: UTF8.self)
    try require(failed.startupFailure?.reason == .unknown && failed.startupFailure?.nativeStatusCode == nil
        && !unknownText.contains(privateSentinel) && !unknownText.contains("783261054")
        && !unknownText.contains("userInfo") && !unknownText.contains("domain"),
        "startup-export-retained-unknown-error-or-private-model-fields")

    var exports = 0
    opening.onExportDiagnostics = { exports += 1 }
    opening.performCoverageAction(.exportDiagnostics)
    try require(!opening.canPerformCoverageAction(.exportDiagnostics) && exports == 0,
        "opening-vault-export-invented-a-report")
    failed.onExportDiagnostics = { exports += 1 }
    try require(failed.coverageReport == nil && failed.canPerformCoverageAction(.exportDiagnostics),
        "startup-export-requires-a-coverage-report")
    failed.performCoverageAction(.exportDiagnostics)
    try require(exports == 1, "startup-export-action-did-not-dispatch-before-storage")
    failed.exportingDiagnostics = true
    failed.performCoverageAction(.exportDiagnostics)
    try require(exports == 1 && !failed.canPerformCoverageAction(.exportDiagnostics),
        "startup-export-allows-duplicate-action")
    failed.exportingDiagnostics = false
    failed.isDemo = true
    try require(!failed.canPerformCoverageAction(.exportDiagnostics), "demo-startup-export-was-enabled")
    failed.isDemo = false

    let report = CoverageReport(window: AnalyzedActivity.recentWindow(endingAt: time),
        gapEvents: .init(items: [], totalCount: 0), omissions: .init(items: [], totalCount: 0),
        history: .init(items: [], totalCount: 0),
        queue: .init(count: 0, encryptedBytes: 0, claimedCount: 0, historicalCount: 0), oldestPendingCaptureAt: nil)
    // A failure after opening the store still cannot claim its partial snapshot as coverage.
    failed.coverageReport = report
    let partial = String(decoding: try DiagnosticsExport.encoded(model: failed, report: report, at: time), as: UTF8.self)
    try require(!partial.contains("\"queue\"") && partial.contains("startupFailure"),
        "partial-startup-exported-stale-coverage")

    let opened = AppModel()
    opened.storageReady = true
    opened.coverageReport = report
    opened.onExportDiagnostics = { exports += 1 }
    opened.pauseAfterBarrier()
    try require(opened.processingText == "Not checking while paused" && opened.processingShort == "Not checking"
        && opened.monitoringStatusText == "Paused" && !opened.storageUnavailable
        && opened.canPerformCoverageAction(.exportDiagnostics), "opened-paused-vault-was-reclassified-as-failed")
    let coverage = String(decoding: try DiagnosticsExport.encoded(model: opened, report: report, at: time), as: UTF8.self)
    try require(coverage.contains("\"queue\"") && !coverage.contains("startupFailure"),
        "opened-vault-lost-coverage-export")
    failed.storageReady = true
    failed.storageFailed = false
    failed.startupFailure = nil
    try require(!failed.canExportStartupDiagnostics && !failed.storageUnavailable,
        "successful-open-kept-stale-startup-failure-state")

    return ["unopened-vault-does-not-claim-paused-monitoring-or-empty-inventory",
            "startup-diagnostics-classify-all-bootstrap-and-key-failures-without-coverage-counts",
            "startup-diagnostics-exclude-unknown-error-content-and-private-model-data",
            "startup-diagnostics-export-without-vault-and-preserve-opened-paused-behavior"]
}
