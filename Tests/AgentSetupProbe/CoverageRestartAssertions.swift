import Foundation
@_spi(Testing) import SpillcheckCore

private enum RestartProbeError: Error { case failed(String) }
private struct RestartProbeDetector: SecretDetector {
    func scan(_ source: SourceRecord) async throws -> DetectorOutput {
        DetectorOutput(detectorVersion: "fake-only-detector", findings: [], unlocated: [])
    }
}
private struct RestartProbeNormalizer: CaptureNormalizer {
    let scope: CollectionScope
    let hasGap: Bool
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        let session = try SessionIdentity(provider: scope.provider, profileID: scope.profileID,
            sessionID: "PRIVATE_RESTART_SESSION")
        let origin = try SourceOrigin(adapterID: "fake-only", adapterVersion: "1", agentVersion: "0.161.0",
            interface: scope.interface, provenance: .live, canonicalization: .exclusiveAuthority)
        let source = try SourceRecord(metadata: .init(identity: .init(session: session,
            itemID: "PRIVATE_RESTART_ITEM_\(scope.interface.rawValue)_\(capturedAt.timeIntervalSince1970)"), contentType: .finalResponse,
            contentTime: capturedAt, observedAt: capturedAt, origin: origin),
            revision: await cryptography.revision(canonicalBytes: Data("FAKE_RESTART_TEXT".utf8)),
            segments: [.init(id: "text", utf8: Data("FAKE_RESTART_TEXT".utf8))])
        return CollectionBatch(sources: [.init(record: source)], coverageGaps: hasGap ? [
            .init(reason: .malformedSource, scope: scope, operation: .liveRead,
                isRequiredFormatFailure: true, diagnosticCode: .invalidFieldType, observedAt: capturedAt)
        ] : [])
    }
}

/// One real admission -> pipeline -> encrypted store -> close/reopen -> app presentation path.
/// Provider input and detector are synthetic; no provider app, Keychain or real vault is touched.
@MainActor
func coverageRestartAssertions() async throws -> [String] {
    func require(_ value: Bool, _ stage: String) throws {
        guard value else { throw RestartProbeError.failed(stage) }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-review-restart-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let crypto = try BackgroundCryptography.ephemeralForTesting()
    let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let profileID = "PRIVATE_RESTART_PROFILE"
    let good = CollectionScope(provider: .codex, profileID: profileID, interface: .standaloneCLI, path: .publicHistory)
    let bad = CollectionScope(provider: .codex, profileID: profileID, interface: .t3, path: .publicHistory)
    let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
    guard let permit = await store.processingPermit() else { throw RestartProbeError.failed("permit") }
    let live = try LiveCaptureScope(startedAt: now.addingTimeInterval(-10))
    for (index, scope) in [good, bad].enumerated() {
        let packet = try CapturePacket(metadata: .init(agent: .codex, interface: scope.interface, profileID: profileID),
            eventJSON: Data("{\"hook_event_name\":\"Stop\",\"session_id\":\"PRIVATE_RESTART_SESSION\"}".utf8))
        let route = CollectionCaptureRoute(scope: scope, readerVersion: "0.161.0")
        _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now,
            scope: live, workContext: route.context(for: packet, trigger: .helperDelivery))
        let pipeline = DetectionPipeline(store: store, cryptography: crypto,
            normalizer: RestartProbeNormalizer(scope: scope, hasGap: index == 1),
            detector: RestartProbeDetector(), detectorVersion: "fake-only-detector", liveSince: live.startedAt)
        try require(try await pipeline.processNext(at: now) == .processed, "pipeline-did-not-complete")
    }
    let before = try await store.coverageReport(endingAt: now)
    try require(before.successfulReads.items.count == 1 && before.successfulReads.items.first?.scope == good,
        "failed-format-read-published-success")
    try require(before.work.items.count == 2 && before.work.items.allSatisfy { $0.context.trigger == .helperDelivery },
        "admission-processing-correlation-missing")
    try await store.close()
    let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
    let report = try await reopened.coverageReport(endingAt: now)
    let model = AppModel()
    model.storageReady = true
    model.agentProfiles[.codex] = .init(provider: .codex, profileID: profileID,
        executablePath: "/PRIVATE_RESTART_EXECUTABLE", homePath: "/PRIVATE_RESTART_HOME",
        version: "0.161.0", installed: true)
    model.agentSetupStates[.codex] = .connected
    model.onRetrySource = { _ in }
    model.coverageReport = report
    model.restoreSuccessfulReads(from: report)
    try require(model.lastOperationReads[good]?[.liveRead] == now && model.lastOperationReads[bad] == nil,
        "reopened-screen-lost-or-invented-last-read")
    try require(model.collectionAssessments[good]?.acceptanceEvidence == .unverified
        && model.collectionAssessments[good]?.usableOperations.isEmpty == true,
        "configured-host-or-persisted-read-implied-acceptance-or-live-reader")
    try require(model.coverageGaps.contains { $0.text.contains("Codex") && $0.text.contains("Live")
        && $0.action.map { if case .retrySource = $0 { true } else { false } } == true },
        "reopened-screen-lost-source-retry-or-operation")
    let diagnostic = String(decoding: try DiagnosticsExport.encoded(model: model, report: report), as: UTF8.self)
    for forbidden in [profileID, "PRIVATE_RESTART_SESSION", "PRIVATE_RESTART_ITEM", "FAKE_RESTART_TEXT",
                      "PRIVATE_RESTART_HOME", "PRIVATE_RESTART_EXECUTABLE"] {
        try require(!diagnostic.contains(forbidden), "reopened-export-leaked-private-field")
    }
    let diagnosticObject = try JSONSerialization.jsonObject(with: Data(diagnostic.utf8)) as! [String: Any]
    for key in ["routes", "work", "successfulReads", "gaps"] {
        let records = diagnosticObject[key] as! [[String: Any]]
        try require(!records.isEmpty && records.allSatisfy {
            $0["host"] == nil && $0["hostAttribution"] as? String == "unverified"
                && $0["configuredInterface"] != nil
        }, "reopened-\(key)-assigned-shared-transport-to-host-or-lost-configured-route")
    }
    model.collectionAssessments[good] = .init(scope: good, observedExecutableVersion: "0.161.0",
        usableOperations: [.liveRead])
    model.restoreSuccessfulReads(from: report)
    try require(model.routes.first { $0.provider == .codex }?.collecting == true
        && model.collectionAssessments[good]?.acceptanceEvidence == .unverified,
        "shared-read-lost-provider-collection-or-invented-host-acceptance")
    model.collectionAssessments[good] = .init(scope: good, observedExecutableVersion: "0.161.0")
    model.agentProfiles[.codex]?.version = "0.162.1"
    model.restoreSuccessfulReads(from: report)
    try require(model.collectionAssessments[good]?.acceptanceEvidence == .unverified
        && model.lastOperationReads[good]?[.liveRead] == now, "version-change-reused-acceptance-or-erased-history")
    let restoredAt = now.addingTimeInterval(1)
    guard let restoredPermit = await reopened.processingPermit() else { throw RestartProbeError.failed("restored-permit") }
    let restoredPacket = try CapturePacket(metadata: .init(agent: .codex, interface: bad.interface, profileID: profileID),
        eventJSON: Data("{\"hook_event_name\":\"Stop\",\"session_id\":\"PRIVATE_RESTART_SESSION\"}".utf8))
    let restoredRoute = CollectionCaptureRoute(scope: bad, readerVersion: "0.161.0")
    _ = try await reopened.enqueue(restoredPacket.body, capturedAt: restoredAt, permit: restoredPermit,
        at: restoredAt, scope: live, workContext: restoredRoute.context(for: restoredPacket, trigger: .helperDelivery))
    let restoringPipeline = DetectionPipeline(store: reopened, cryptography: crypto,
        normalizer: RestartProbeNormalizer(scope: bad, hasGap: false), detector: RestartProbeDetector(),
        detectorVersion: "fake-only-detector", liveSince: live.startedAt)
    try require(try await restoringPipeline.processNext(at: restoredAt) == .processed, "restoring-pipeline-did-not-complete")
    try await reopened.close()
    let afterRestoration = try await ProtectedStore.open(at: directory, cryptography: crypto)
    let restoredReport = try await afterRestoration.coverageReport(endingAt: restoredAt)
    model.coverageReport = restoredReport
    model.restoreSuccessfulReads(from: restoredReport)
    try require(model.lastOperationReads[bad]?[.liveRead] == restoredAt
        && model.coverageGaps.contains { $0.state == .operationRestored }
        && model.recoveredCoverageGaps.isEmpty && model.coverageNeedsAttention && !model.monitoringProven,
        "pipeline-restoration-restart-lost-operation-evidence-or-claimed-content-recovery")
    let restoredExport = try DiagnosticsExport.encoded(model: model, report: restoredReport)
    try require(String(decoding: restoredExport, as: UTF8.self).contains("operationRestored"),
        "reopened-export-disagrees-with-restored-screen")
    try await afterRestoration.close()

    // Two captures can expire with identical reason/scope/timestamps. Only their atomic
    // omission links may select the original source, never a first matching event.
    let expiring = try await ProtectedStore.open(at: directory, cryptography: crypto, limits: .init(maxQueueAge: 5))
    guard let expiryPermit = await expiring.processingPermit() else { throw RestartProbeError.failed("expiry-permit") }
    for suffix in ["FIRST", "SECOND"] {
        let packet = try CapturePacket(metadata: .init(agent: .codex, interface: good.interface, profileID: profileID),
            eventJSON: Data("{\"session_id\":\"PRIVATE_EXPIRED_\(suffix)\"}".utf8))
        let route = CollectionCaptureRoute(scope: good, readerVersion: "0.161.0")
        _ = try await expiring.enqueue(packet.body, capturedAt: restoredAt, permit: expiryPermit,
            at: restoredAt, scope: live, workContext: route.context(for: packet, trigger: .helperDelivery))
    }
    let expiredAt = restoredAt.addingTimeInterval(6)
    try require(try await expiring.maintainQueue(at: expiredAt) == 2, "simultaneous-captures-did-not-expire")
    try await expiring.close()
    let expiredStore = try await ProtectedStore.open(at: directory, cryptography: crypto)
    let expiredReport = try await expiredStore.coverageReport(endingAt: expiredAt)
    model.coverageReport = expiredReport
    var retried: Set<String> = []
    model.onRetrySource = { source in if let sessionID = source.session?.sessionID { retried.insert(sessionID) } }
    let lostRows = model.coverageGaps.filter { $0.text.contains("expired") }
    try require(lostRows.count == 2 && lostRows.allSatisfy { $0.state == .retryable },
        "expired-sources-merged-or-mislabeled-as-format-or-permanent-loss")
    for row in lostRows {
        guard let action = row.action else { throw RestartProbeError.failed("expired-source-lost-retry") }
        try require(action.label == "Retry this source", "expired-source-widened-to-profile-retry")
        model.performCoverageAction(action)
    }
    try require(retried == ["PRIVATE_EXPIRED_FIRST", "PRIVATE_EXPIRED_SECOND"],
        "simultaneous-loss-retry-selected-wrong-original-source")
    let expiredExport = String(decoding: try DiagnosticsExport.encoded(model: model, report: expiredReport), as: UTF8.self)
    try require(!expiredExport.contains("PRIVATE_EXPIRED") && !expiredExport.contains(profileID),
        "expired-source-export-leaked-native-session-or-profile")
    try await expiredStore.close()
    return ["pipeline-admission-restart-screen-keeps-scoped-success-and-source-retry",
            "restart-diagnostics-correlates-work-without-native-identities",
            "persisted-read-retains-time-without-confering-host-acceptance",
            "pipeline-restoration-survives-encrypted-restart-without-claiming-content-recovery",
            "simultaneous-expired-captures-reopen-with-distinct-exact-source-retries"]
}
