import Foundation
import SpillcheckCore

enum StorageCapacityAssertionFailure: Error { case failed(String) }

@MainActor
func storageCapacityAssertions() throws -> [String] {
    func require(_ condition: Bool, _ name: String) throws {
        guard condition else { throw StorageCapacityAssertionFailure.failed(name) }
    }
    let now = Date()
    let model = AppModel()
    model.storageReady = true
    let profile = "PRIVATE_CAPACITY_PROFILE_NEVER_EXPORT"
    let scope = CollectionScope(provider: .codex, profileID: profile, interface: .standaloneCLI, path: .publicHistory)
    model.agentProfiles[.codex] = .init(provider: .codex, profileID: profile, version: "0.162.1", installed: true)
    model.agentSetupStates[.codex] = .connected
    model.collectionAssessments[scope] = .init(scope: scope, usableOperations: [.liveRead, .historicalRead])
    model.onExportDiagnostics = {}
    let available = StoreCapacityUsage(count: 2, encryptedBytes: 20, countLimit: 10, encryptedBytesLimit: 100)
    let roomyWork = StoreCapacityUsage(count: 2, encryptedBytes: 20, countLimit: .max, encryptedBytesLimit: 100)
    func report(_ capacity: StoreCapacitySnapshot? = nil, gaps: [CoverageGap] = []) -> CoverageReport {
        CoverageReport(window: AnalyzedActivity.recentWindow(endingAt: now),
            gapEvents: .init(items: gaps.map { .init(gap: $0, observedAt: now) }, totalCount: gaps.count),
            omissions: .init(items: [], totalCount: 0), history: .init(items: [], totalCount: 0),
            queue: .init(count: 0, encryptedBytes: 0, claimedCount: 0, historicalCount: 0),
            oldestPendingCaptureAt: nil, capacity: capacity)
    }
    model.coverageReport = report()
    try require(model.collectionStorageWarnings.isEmpty, "missing-capacity-invented-warning")
    model.coverageReport = report(.init(sourceAuthorities: available, codexHookContentSlots: available, collectionWork: roomyWork))
    try require(!model.collectionStorageNeedsAttention, "healthy-capacity-shown-as-full")

    let near = StoreCapacityUsage(count: 8, encryptedBytes: 20, countLimit: 10, encryptedBytesLimit: 100)
    model.coverageReport = report(.init(sourceAuthorities: near, codexHookContentSlots: available, collectionWork: roomyWork))
    try require(model.collectionStorageWarnings.count == 1
        && model.collectionStorageWarnings.first?.title.contains("nearly full") == true
        && model.collectionStorageWarnings.first?.countText.contains("2 remaining") == true
        && model.collectionStorageNeedsAttention && model.monitoringIndicator == .attention,
        "near-capacity-warning-or-headroom-missing")
    try require(model.coverageGaps.isEmpty && !model.coverageNeedsAttention
        && model.activeCollectionLimitations.isEmpty && model.unresolvedCoverageGaps.isEmpty
        && model.collectionAssessments[scope]?.status == .compatible,
        "capacity-warning-invented-content-loss-or-disabled-reader")

    let byteFull = StoreCapacityUsage(count: 2, encryptedBytes: 100, countLimit: 10, encryptedBytesLimit: 100)
    let over = StoreCapacityUsage(count: 12, encryptedBytes: 20, countLimit: 10, encryptedBytesLimit: 100)
    model.coverageReport = report(.init(sourceAuthorities: over, codexHookContentSlots: byteFull, collectionWork: roomyWork))
    try require(model.collectionStorageWarnings.count == 2
        && model.collectionStorageWarnings.allSatisfy { $0.title.contains("reached its limit") }
        && model.collectionStorageWarnings[0].usage.remainingCount == 0
        && model.collectionStorageWarnings[1].usage.remainingEncryptedBytes == 0,
        "lowered-or-byte-capacity-limit-hidden")
    let encoded = try CoverageDiagnostics(model: model, report: model.coverageReport!, at: now).encoded()
    let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    let capacity = json["capacity"] as! [String: Any]
    let authority = capacity["sourceAuthorities"] as! [String: Any]
    let hooks = capacity["codexHookContentSlots"] as! [String: Any]
    try require(json["schemaVersion"] as? Int == 4
        && authority["count"] as? Int == 12 && authority["remainingCount"] as? Int == 0
        && authority["state"] as? String == "overLimit"
        && hooks["countState"] as? String == "available" && hooks["bytesState"] as? String == "full"
        && hooks["remainingEncryptedBytes"] as? Int == 0
        && !String(decoding: encoded, as: UTF8.self).contains(profile),
        "capacity-export-lost-bounds-or-exposed-native-identity")

    let rejection = CollectionCapacityRejection(resource: .sourceAuthorities, scope: scope, at: now)
    try require(rejection.gap.scope == scope && rejection.gap.operation == .hookDelivery
        && rejection.gap.diagnosticCode == .authorityStorageLimit && rejection.gap.observedAt == now
        && rejection.gap.recovery == nil && rejection.gap.isRequiredFormatFailure != true,
        "capacity-rejection-lost-scope-or-invented-format-failure")
    model.coverageReport = report(gaps: [rejection.gap])
    try require(model.coverageGaps.count == 1
        && model.coverageGaps.first?.stateLabel == "Conversation storage limit reached"
        && model.coverageGaps.first?.text.contains("could not be registered") == true,
        "admission-capacity-described-as-generic-delivery-failure")
    if case .some(.exportDiagnostics) = model.coverageGaps.first?.action {} else {
        throw StorageCapacityAssertionFailure.failed("capacity-failure-offered-ineffective-history-retry")
    }

    // A work ledger with nothing left to prune refuses every capture until it has room again.
    let nearWork = StoreCapacityUsage(count: 9, encryptedBytes: 85, countLimit: .max, encryptedBytesLimit: 100)
    model.coverageReport = report(.init(sourceAuthorities: available, codexHookContentSlots: available, collectionWork: nearWork))
    try require(model.collectionStorageWarnings.count == 1
        && model.collectionStorageWarnings.first?.title == "Collection storage is nearly full"
        && model.collectionStorageWarnings.first?.countText == "9 records stored"
        && model.collectionStorageWarnings.first?.isLifetime == false
        && model.collectionStorageNeedsAttention && model.monitoringIndicator == .attention,
        "work-storage-warning-missing-or-shown-with-a-record-limit")
    let fullWork = StoreCapacityUsage(count: 9, encryptedBytes: 100, countLimit: .max, encryptedBytesLimit: 100)
    model.coverageReport = report(.init(sourceAuthorities: available, codexHookContentSlots: available, collectionWork: fullWork))
    try require(model.collectionStorageWarnings.first?.title == "Collection storage has reached its limit"
        && model.collectionStorageWarnings.first?.detail.contains("cannot be collected") == true,
        "full-work-storage-not-named")
    let workExport = try CoverageDiagnostics(model: model, report: model.coverageReport!, at: now).encoded()
    let workCapacity = (try JSONSerialization.jsonObject(with: workExport) as! [String: Any])["capacity"] as! [String: Any]
    let work = workCapacity["collectionWork"] as! [String: Any]
    try require(work["count"] as? Int == 9 && work["bytesState"] as? String == "full"
        && work["remainingEncryptedBytes"] as? Int == 0 && work["countState"] as? String == "available",
        "work-storage-export-lost-usage")

    for operation in [CollectionOperation.hookDelivery, .historicalRead] {
        let refused = CollectionCapacityRejection(resource: .collectionWork, scope: scope, operation: operation, at: now)
        try require(refused.gap.scope == scope && refused.gap.operation == operation
            && refused.gap.diagnosticCode == .workStorageLimit && refused.gap.recovery == nil,
            "work-storage-refusal-lost-scope-or-cause")
    }
    // A history page whose next page was refused keeps its own reason, but names the same cause.
    let lostPage = CoverageGap(reason: .captureRejected, scope: scope, operation: .historicalRead,
        diagnosticCode: .workStorageLimit, observedAt: now)
    model.coverageReport = report(gaps: [CollectionCapacityRejection(resource: .collectionWork, scope: scope, at: now).gap, lostPage])
    try require(model.coverageIssues.count == 1
        && model.coverageIssues.first?.title.contains("Collection storage reached its limit") == true
        && model.coverageGaps.count == 2
        && model.coverageGaps.allSatisfy { $0.stateLabel == "Collection storage limit reached" },
        "work-storage-refusals-described-as-generic-rejections")
    for row in model.coverageGaps {
        if case .some(.exportDiagnostics) = row.action {} else {
            throw StorageCapacityAssertionFailure.failed("work-storage-refusal-offered-ineffective-retry")
        }
    }
    model.coverageReport = report(.init(sourceAuthorities: near, codexHookContentSlots: available, collectionWork: roomyWork))
    model.pauseAfterBarrier()
    try require(model.collectionStorageNeedsAttention && model.monitoringIndicator == .paused,
        "capacity-warning-overrode-paused-monitoring")
    model.storageFailed = true
    try require(model.collectionStorageWarnings.isEmpty && model.monitoringIndicator == .unavailable,
        "unavailable-vault-displayed-stale-capacity")
    return ["capacity-warning-and-headroom-do-not-invent-content-loss",
            "count-byte-and-lowered-capacity-limits-export-without-native-identities",
            "admission-capacity-retains-route-and-offers-diagnostics-without-history-retry",
            "work-storage-warning-and-export-show-bytes-without-a-record-limit",
            "work-storage-refusals-name-their-cause-and-offer-diagnostics",
            "capacity-presentation-respects-paused-and-unavailable-storage"]
}
