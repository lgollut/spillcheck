import Foundation
import SpillcheckCore

private enum CoverageAssertionFailure: Error { case failed(String) }

private struct CoverageOmissionFixture: Encodable {
    let id = UUID()
    let gap: CoverageGap
    let firstObservedAt: Date
    let state: CoverageOmissionState
    let resolvedAt: Date?

    func decoded() throws -> CoverageOmission {
        try JSONDecoder().decode(CoverageOmission.self, from: JSONEncoder().encode(self))
    }
}

@MainActor
func coveragePresentationAssertions() throws -> [String] {
    func require(_ condition: Bool, _ name: String) throws {
        guard condition else { throw CoverageAssertionFailure.failed(name) }
    }
    let now = Date()
    let profile = "SYNTHETIC_PRIVATE_PROFILE_NEVER_EXPORT"
    let nativeSession = "SYNTHETIC_PRIVATE_SESSION_NEVER_EXPORT"
    let nativeItem = "SYNTHETIC_PRIVATE_ITEM_NEVER_EXPORT"
    let parser = "SYNTHETIC_PRIVATE_PARSER_INPUT_NEVER_EXPORT"
    let privatePath = "/SYNTHETIC_PRIVATE_PATH_NEVER_EXPORT/provider"
    let privateValue = "SYNTHETIC_PRIVATE_VALUE_NEVER_EXPORT"
    let scope = CollectionScope(provider: .codex, profileID: profile, interface: .standaloneCLI, path: .publicHistory)
    let t3 = CollectionScope(provider: .codex, profileID: profile, interface: .t3, path: .publicHistory)
    let audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
    func report(events: [StoredCoverageGapEvent] = [], omissions: [CoverageOmission] = [],
                history: [StoredHistoricalProgress] = [], omissionTotal: Int? = nil,
                work: [StoredCollectionWork] = [], reads: [SuccessfulCollectionRead] = [],
                omissionCounts: [CoverageOmissionState: Int] = [:]) -> CoverageReport {
        CoverageReport(window: .init(start: audit.start, end: now), gapEvents: .init(items: events, totalCount: events.count),
            omissions: .init(items: omissions, totalCount: omissionTotal ?? omissions.count),
            history: .init(items: history, totalCount: history.count),
            queue: .init(count: 0, encryptedBytes: 0, claimedCount: 0, historicalCount: 0), oldestPendingCaptureAt: nil,
            work: .init(items: work, totalCount: work.count), omissionStateCounts: omissionCounts,
            successfulReads: .init(items: reads, totalCount: reads.count))
    }
    let model = AppModel()
    model.storageReady = true
    model.agentProfiles[.codex] = .init(provider: .codex, profileID: profile, executablePath: privatePath,
        homePath: privatePath, version: "0.161.0", t3Version: "0.0.46-nightly.20261007.2761", installed: true)
    model.agentSetupStates[.codex] = .connected
    model.collectionAssessments[scope] = .init(scope: scope, observedExecutableVersion: privateValue,
        usableOperations: [.liveRead, .historicalRead])
    model.collectionAssessments[t3] = .init(scope: t3, observedExecutableVersion: "0.161.0",
        usableOperations: [.liveRead, .historicalRead])

    let operation = StoredCoverageGapEvent(gap: .init(reason: .malformedSource, scope: scope,
        operation: .liveRead, isRequiredFormatFailure: true), observedAt: now)
    model.coverageReport = report(events: [operation])
    model.lastReadDates[scope] = now.addingTimeInterval(-1)
    model.lastOperationReads[scope] = [.liveRead: now.addingTimeInterval(-1)]
    try require(model.coverageGaps.first?.state == .recoveryUnconfirmed && model.recoveredCoverageGaps.isEmpty,
        "stale-read-falsely-restored-operation")
    model.lastReadDates.removeValue(forKey: scope)
    model.lastOperationReads.removeValue(forKey: scope)
    model.lastReadDates[t3] = now.addingTimeInterval(10)
    model.lastOperationReads[t3] = [.liveRead: now.addingTimeInterval(10)]
    try require(model.coverageGaps.first?.state == .recoveryUnconfirmed, "sibling-host-falsely-restored-operation")
    model.lastReadDates[scope] = now.addingTimeInterval(10)
    model.lastOperationReads[scope] = [.historicalRead: now.addingTimeInterval(10)]
    try require(model.coverageGaps.first?.state == .recoveryUnconfirmed, "sibling-operation-falsely-restored-live-read")
    model.lastOperationReads[scope]?[.liveRead] = now.addingTimeInterval(10)
    try require(model.coverageGaps.first?.state == .operationRestored && model.recoveredCoverageGaps.isEmpty
        && model.coverageNeedsAttention && model.activeCollectionLimitations.isEmpty
        && model.unresolvedCoverageGaps.count == 1, "operation-restoration-claimed-historical-recovery")

    let legacy = StoredCoverageGapEvent(gap: .init(reason: .deliveryUncertain), observedAt: now)
    let terminal = StoredCoverageGapEvent(gap: .init(reason: .budgetExhausted, scope: scope,
        operation: .historicalRead, isRequiredFormatFailure: true), observedAt: now)
    model.coverageReport = report(events: [legacy, terminal])
    try require(model.coverageGaps.count == 2 && model.coverageGaps.allSatisfy { $0.state == .recoveryUnconfirmed }
        && model.recoveredCoverageGaps.isEmpty, "current-read-erased-terminal-or-legacy-loss")

    let loss = CoverageGap(reason: .sourceUnavailable, scope: scope)
    let omission = try CoverageOmissionFixture(gap: loss, firstObservedAt: now, state: .unrecoverable, resolvedAt: nil).decoded()
    model.coverageReport = report(events: [.init(gap: loss, observedAt: now)], omissions: [omission])
    try require(model.coverageGaps.count == 1 && model.coverageGaps.first?.state == .historicalLoss
        && model.activeCollectionLimitations.isEmpty && model.unresolvedCoverageGaps.count == 1,
        "terminal-loss-counted-as-both-active-event-and-historical-omission")

    let reference = CoverageRecoveryReference(session: try SessionIdentity(provider: .codex, profileID: profile,
        sessionID: nativeSession), locator: .upstreamItem, itemID: nativeItem, contentTime: now, parserContract: parser)
    let missing = CoverageGap(reason: .malformedSource, capabilityID: UUID(), scope: scope,
        contentType: .toolOutput, recovery: reference, isRequiredFormatFailure: true,
        sourceKind: .codexMCPToolCall, diagnosticCode: .invalidFieldType)
    let missingEvent = StoredCoverageGapEvent(gap: missing, observedAt: now)
    let recovered = try CoverageOmissionFixture(gap: missing, firstObservedAt: now, state: .recovered,
        resolvedAt: now.addingTimeInterval(10)).decoded()
    model.coverageReport = report(events: [missingEvent], omissions: [recovered])
    try require(model.coverageGaps.isEmpty && model.recoveredCoverageGaps.count == 1,
        "recovered-native-omission-revived-by-event")
    model.coverageReport = report(events: [missingEvent], omissionTotal: 1)
    try require(model.coverageGaps.count == 1 && model.coverageNeedsAttention,
        "truncated-omission-query-silently-hid-native-event")
    model.coverageReport = report(events: [.init(gap: .init(reason: .malformedSource, recovery: reference), observedAt: now)])
    try require(model.coverageGaps.count == 1, "unscoped-native-event-silently-hidden")

    let earliest = now.addingTimeInterval(-6 * 86_400)
    model.coverageReport = report(events: [
        .init(gap: .init(reason: .sourceUnavailable, interval: .init(start: earliest, duration: 86_400), scope: scope),
              observedAt: now.addingTimeInterval(-100)),
        .init(gap: .init(reason: .sourceUnavailable, interval: .init(start: now.addingTimeInterval(-86_400), end: now), scope: scope),
              observedAt: now)
    ])
    try require(model.coverageGaps.count == 1 && model.coverageGaps[0].count == 2
        && model.coverageGaps[0].detail == "Affected period \(DisplayTime.full(earliest)) to \(DisplayTime.full(now))",
        "grouped-coverage-period-omits-earlier-or-later-failure")

    let progress = StoredHistoricalProgress(provider: .codex, profileID: profile,
        progress: .init(audit: audit, bytesRead: 100, hasUnreadContent: false),
        lastAttemptedAt: now.addingTimeInterval(10), completedAt: now.addingTimeInterval(10), continuationQueued: false)
    let diagnosticReport = report(events: [legacy, terminal, operation, missingEvent], omissions: [recovered], history: [progress])
    model.coverageReport = diagnosticReport
    let bytes = try CoverageDiagnostics(model: model, report: diagnosticReport, at: now).encoded()
    let output = String(decoding: bytes, as: UTF8.self)
    for forbidden in [profile, nativeSession, nativeItem, parser, privatePath,
                      "SYNTHETIC_PRIVATE_PATH_NEVER_EXPORT", privateValue,
                      audit.id.uuidString, recovered.id.uuidString, missingEvent.id.uuidString,
                      missing.capabilityID!.uuidString] {
        try require(!output.contains(forbidden), "diagnostics-exported-protected-identity-or-content")
    }
    try require(output.contains("operationRestored") && output.contains("invalidFieldType")
        && output.contains("codexMCPToolCall") && output.contains("0.0.46-nightly.20261007.2761"),
        "diagnostics-dropped-controlled-evidence-or-host-version")
    try require(CoverageDiagnostics.version("0.161.0") == "0.161.0"
        && CoverageDiagnostics.version("1.2.3 \(privateValue)") == nil
        && CoverageDiagnostics.version(privatePath) == nil, "diagnostic-version-allowed-arbitrary-provider-output")
    let json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    let routes = json["routes"] as! [[String: Any]]
    let t3Route = routes.first { $0["configuredInterface"] as? String == AgentInterface.t3.rawValue }
    try require(routes.allSatisfy { $0["host"] == nil && $0["hostVersion"] == nil
            && $0["hostAttribution"] as? String == "unverified" }
        && t3Route?["configuredHostVersion"] as? String == "0.0.46-nightly.20261007.2761",
        "diagnostics-inferred-host-from-shared-configured-route-or-lost-version-hint")

    let bounded = report(events: Array(repeating: missingEvent, count: 1000),
        omissions: Array(repeating: recovered, count: 1000), history: Array(repeating: progress, count: 1000), omissionTotal: 2000)
    let boundedBytes = try CoverageDiagnostics(model: model, report: bounded, at: now).encoded()
    try require(boundedBytes.count < 3 * 1024 * 1024 && bounded.isTruncated,
        "bounded-diagnostics-exceeded-content-free-size-or-lost-truncation")

    let retiredHistory = StoredHistoricalProgress(provider: .codex, profileID: "retired-private-profile",
        progress: .init(audit: audit, bytesRead: 10, hasUnreadContent: true),
        lastAttemptedAt: now, continuationQueued: false)
    model.coverageReport = report(history: [retiredHistory])
    try require(model.coverageGaps.count == 1 && model.coverageGaps[0].text.hasPrefix("Codex")
        && !model.coverageGaps[0].text.contains("CLI") && !model.coverageGaps[0].text.contains("T3")
        && model.unresolvedCoverageGaps.first?.scope == nil,
        "unknown-audit-host-inferred-from-current-registration")
    if case .some(.exportDiagnostics) = model.coverageGaps[0].action {} else {
        throw CoverageAssertionFailure.failed("retired-profile-offered-retry-of-current-profile")
    }
    let media = StoredCoverageGapEvent(gap: .init(reason: .unsupportedContent, scope: scope,
        diagnosticCode: .excludedBinaryContent, excludedContent: true), observedAt: now)
    model.coverageReport = report(events: [media])
    try require(model.coverageGaps.first?.text.contains("Images and other non-text content are excluded") == true
        && !model.coverageNeedsAttention && model.unresolvedCoverageGaps.isEmpty,
        "recognized-media-exclusion-described-as-format-failure")

    let encrypted = CoverageGap(reason: .unsupportedContent, scope: scope, contentType: .userPrompt,
        recovery: reference, isRequiredFormatFailure: true, sourceKind: .codexUserMessage,
        diagnosticCode: .encryptedContentUnavailable)
    let encryptedOmission = try CoverageOmissionFixture(gap: encrypted, firstObservedAt: now,
        state: .blocked, resolvedAt: nil).decoded()
    model.coverageReport = report(omissions: [encryptedOmission])
    try require(model.coverageNeedsAttention && model.unresolvedCoverageGaps.count == 1
        && model.activeCollectionLimitations.count == 1 && model.coverageGaps.first?.state == .blocked
        && model.coverageGaps.first?.stateLabel == "Encrypted input unavailable"
        && model.coverageGaps.first?.text.contains("encrypted in the Codex source") == true,
        "encrypted-required-input-hidden-as-optional-media")
    if case .some(.exportDiagnostics) = model.coverageGaps.first?.action {} else {
        throw CoverageAssertionFailure.failed("encrypted-input-offered-ineffective-reread")
    }
    let encryptedDiagnostics = try CoverageDiagnostics(model: model, report: model.coverageReport!, at: now).encoded()
    try require(String(decoding: encryptedDiagnostics, as: UTF8.self).contains("encryptedContentUnavailable"),
        "encrypted-input-diagnostic-code-lost")

    let absentChildInput = CoverageGap(reason: .unsupportedContent, scope: scope, contentType: .userPrompt,
        recovery: reference, isRequiredFormatFailure: true, diagnosticCode: .nativeChildInputUnavailable)
    let absentChildOmission = try CoverageOmissionFixture(gap: absentChildInput, firstObservedAt: now,
        state: .blocked, resolvedAt: nil).decoded()
    model.coverageReport = report(omissions: [absentChildOmission])
    try require(model.coverageNeedsAttention && model.unresolvedCoverageGaps.count == 1
        && model.activeCollectionLimitations.count == 1
        && model.coverageGaps.first?.stateLabel == "Subagent input unavailable"
        && model.coverageGaps.first?.text.contains("original incoming instructions") == true
        && model.coverageGaps.first?.text.contains("encrypted") == false,
        "absent-native-child-input-hidden-or-mislabeled-as-encrypted")
    if case .some(.exportDiagnostics) = model.coverageGaps.first?.action {} else {
        throw CoverageAssertionFailure.failed("unexposed-child-input-offered-ineffective-reread")
    }
    let childDiagnostics = try CoverageDiagnostics(model: model, report: model.coverageReport!, at: now).encoded()
    let childDiagnosticText = String(decoding: childDiagnostics, as: UTF8.self)
    try require(childDiagnosticText.contains("nativeChildInputUnavailable")
        && !childDiagnosticText.contains(nativeSession) && !childDiagnosticText.contains(nativeItem),
        "unexposed-child-input-diagnostic-lost-or-exported-private-identity")

    let hookScope = CollectionScope(provider: .codex, profileID: scope.profileID,
        interface: scope.interface, path: .hook)
    for (code, label, text) in [
        (CoverageDiagnosticCode.hookIdentityConflict, "Hook identity conflict", "different content"),
        (.hookInterrupted, "Turn interrupted", "interrupted"),
        (.hookContentUnavailable, "Hook content unavailable", "supported, complete text"),
        (.hookStorageLimit, "Hook storage limit reached", "storage limit")
    ] {
        let hookGap = CoverageGap(reason: .sourceChanged, scope: hookScope, operation: .hookDelivery,
            recovery: reference, isRequiredFormatFailure: true, sourceKind: .codexHookEvent,
            diagnosticCode: code)
        model.coverageReport = report(omissions: [try CoverageOmissionFixture(gap: hookGap,
            firstObservedAt: now, state: .blocked, resolvedAt: nil).decoded()])
        try require(model.coverageNeedsAttention && model.coverageGaps.first?.stateLabel == label
            && model.coverageGaps.first?.text.contains(text) == true,
            "hook-gap-missing-specific-explanation")
        if case .some(.exportDiagnostics) = model.coverageGaps.first?.action {} else {
            throw CoverageAssertionFailure.failed("hook-only-loss-offered-unsupported-history-retry")
        }
    }

    let waiting = AppModel()
    waiting.storageReady = true
    waiting.agentProfiles[.codex] = model.agentProfiles[.codex]
    waiting.agentSetupStates[.codex] = .connected
    waiting.coverageReport = report()
    try require(waiting.processingText == "Waiting for agent content" && waiting.processingShort == "Waiting",
        "idle-unobserved-route-claimed-up-to-date")
    var retries = 0
    waiting.onRetryHistory = { _ in retries += 1 }
    try require(waiting.canPerformCoverageAction(.retryHistory(.codex)), "verified-idle-profile-cannot-retry")
    waiting.performCoverageAction(.retryHistory(.claudeCode))
    try require(retries == 0, "unconfigured-provider-retry-was-dispatched")
    waiting.updateHistoryWork(queued: 1)
    try require(!waiting.canPerformCoverageAction(.retryHistory(.codex)), "queued-audit-allows-duplicate-retry")
    waiting.updateHistoryWork(queued: 0)
    waiting.pauseAfterBarrier()
    try require(waiting.processingText == "Not checking while paused" && waiting.processingShort == "Not checking"
        && !waiting.canPerformCoverageAction(.retryHistory(.codex)), "paused-profile-claimed-activity-or-allowed-retry")
    // A current unscoped receipt is unknown collection, not evidence from an earlier collector.
    model.coverageReport = report(events: [legacy])
    try require(model.coverageGaps.first?.text.hasPrefix("Collection:") == true
        && model.coverageGaps.first?.detail == nil, "unscoped-current-event-invented-historical-origin-or-content-time")
    let historicalReference = CoverageRecoveryReference(session: reference.session, locator: .upstreamItem,
        itemID: nativeItem, contentTime: earliest, parserContract: parser)
    let datedGap = CoverageGap(reason: .malformedSource, scope: scope, recovery: historicalReference)
    model.coverageReport = report(events: [.init(gap: datedGap, observedAt: now)])
    try require(model.coverageGaps.first?.detail == "Affected content \(DisplayTime.full(earliest))",
        "affected-content-time-replaced-by-recent-observation-time")

    // Each audit owns its work. A stale continuation flag and another audit's queue cannot make it active.
    let secondAudit = try HistoricalAuditContext(reason: .restart, endingAt: now.addingTimeInterval(-10))
    let auditID = CoverageAuditIdentity(auditID: audit.id, provider: .codex, profileID: profile)
    let secondID = CoverageAuditIdentity(auditID: secondAudit.id, provider: .codex, profileID: profile)
    let queuedWork = StoredCollectionWork(id: UUID(), context: .init(scope: scope,
        operation: .historicalRead, audit: auditID), state: .queued, admittedAt: now)
    let terminalWork = StoredCollectionWork(id: UUID(), context: .init(scope: scope,
        operation: .historicalRead, audit: secondID), state: .terminal, admittedAt: now)
    let unread = StoredHistoricalProgress(provider: .codex, profileID: profile,
        progress: .init(audit: audit, bytesRead: 100, hasUnreadContent: true), lastAttemptedAt: now, continuationQueued: true)
    let otherUnread = StoredHistoricalProgress(provider: .codex, profileID: profile,
        progress: .init(audit: secondAudit, bytesRead: 100, hasUnreadContent: true), lastAttemptedAt: now, continuationQueued: true)
    let auditReport = report(history: [unread, otherUnread], work: [queuedWork, terminalWork])
    model.coverageReport = auditReport
    try require(model.coverageGaps.count == 2 && Set(model.coverageGaps.map(\.state)) == [.queued, .recoveryUnconfirmed],
        "profile-latest-audit-or-global-queue-hid-terminal-unread-work")
    model.coverageReport = report(history: [unread], work: [queuedWork])
    try require(model.coverageGaps.map(\.state) == [.queued] && !model.coverageNeedsAttention
        && model.coverageHasUnreadHistory, "queued-unread-history-counted-as-complete-coverage")
    let completedNewer = progress
    model.coverageReport = report(history: [completedNewer, otherUnread], work: [terminalWork])
    try require(model.coverageGaps.count == 1 && model.coverageGaps.first?.state == .recoveryUnconfirmed,
        "newer-completed-audit-erased-earlier-terminal-unread-work")

    let exactSource = CoverageSourceRetryDescriptor(scope: scope, session: reference.session,
        sourceDocumentID: UUID(), sourceURL: URL(fileURLWithPath: privatePath))
    let stalledWork = StoredCollectionWork(id: UUID(), context: .init(scope: scope, operation: .liveRead,
        retry: exactSource), state: .stalled, admittedAt: now)
    let retryableWork = StoredCollectionWork(id: UUID(), context: .init(scope: scope, operation: .liveRead,
        retry: exactSource), state: .terminal, admittedAt: now)
    let stalledEvent = StoredCoverageGapEvent(gap: .init(reason: .sourceUnavailable, scope: scope),
        observedAt: now, workID: stalledWork.id)
    let endedEvent = StoredCoverageGapEvent(gap: .init(reason: .queueExpired, scope: scope),
        observedAt: now, workID: retryableWork.id)
    let workReport = report(events: [stalledEvent, endedEvent], omissions: [recovered],
        history: [unread, otherUnread], omissionTotal: 2_000,
        work: [queuedWork, terminalWork, stalledWork, retryableWork],
        omissionCounts: [.recovered: 1_250, .blocked: 500, .retryable: 249, .unrecoverable: 1])
    model.coverageReport = workReport
    try require(model.coverageGaps.contains { $0.state == .stalled }
        && model.coverageGaps.contains { $0.state == .retryable }, "live-work-terminal-and-stalled-state-lost")
    var retriedSource: CoverageSourceRetryDescriptor?
    model.onRetrySource = { retriedSource = $0 }
    guard let retryAction = model.coverageGaps.first(where: { $0.state == .stalled })?.action else {
        throw CoverageAssertionFailure.failed("exact-source-retry-action-missing")
    }
    model.performCoverageAction(retryAction)
    try require(retriedSource == exactSource && retryAction.label == "Retry this source"
        && CoverageAction.retryHistory(.codex).label == "Retry profile history", "retry-widened-exact-source-to-profile")
    let retiredSource = CoverageSourceRetryDescriptor(scope: .init(provider: .codex, profileID: "retired-private-profile",
        interface: .standaloneCLI, path: .publicHistory), session: reference.session)
    try require(!model.canPerformCoverageAction(.retrySource(retiredSource)), "retired-source-retry-used-current-profile")

    let claudeScope = CollectionScope(provider: .claudeCode, profileID: profile,
        interface: .standaloneCLI, path: .versionedTranscript)
    let parentSession = try SessionIdentity(provider: .claudeCode, profileID: profile, sessionID: nativeSession)
    let parentURL = URL(fileURLWithPath: privatePath + "/parent.jsonl")
    let childURL = URL(fileURLWithPath: privatePath + "/child.jsonl")
    let childDocument = UUID()
    let parentSelection = CoverageSourceRetryDescriptor(scope: claudeScope, session: parentSession, sourceURL: parentURL)
    let parentWork = StoredCollectionWork(id: UUID(), context: .init(scope: claudeScope,
        operation: .liveRead, retry: parentSelection), state: .terminal, admittedAt: now)
    let childReference = CoverageRecoveryReference(session: parentSession,
        locator: .transcriptByteOffset(documentID: childDocument, byteOffset: 40),
        contentTime: now, parserContract: parser, sourceURL: childURL)
    let childGap = CoverageGap(reason: .malformedSource, scope: claudeScope, recovery: childReference)
    let childEvent = StoredCoverageGapEvent(gap: childGap, observedAt: now, workID: parentWork.id)
    let childReport = report(events: [childEvent], work: [parentWork])
    let childObservation = model.coverageObservations(report: childReport).first
    try require(childObservation?.retry?.sourceURL == childURL
        && childObservation?.retry?.sourceDocumentID == childDocument
        && childObservation?.retry?.identifiesSameSource(as: parentSelection) == false,
        "child-record-retry-selected-parent-admission-file-or-lost-document-identity")
    let unknownChild = CoverageRecoveryReference(session: parentSession,
        locator: .transcriptByteOffset(documentID: childDocument, byteOffset: 40), parserContract: parser)
    let unknownReport = report(events: [.init(gap: .init(reason: .malformedSource, scope: claudeScope,
        recovery: unknownChild), observedAt: now, workID: parentWork.id)], work: [parentWork])
    try require(model.coverageObservations(report: unknownReport).first?.retry == nil,
        "child-record-without-original-file-fell-back-to-parent-source")

    let workBytes = try CoverageDiagnostics(model: model, report: workReport, at: now).encoded()
    let workText = String(decoding: workBytes, as: UTF8.self)
    let workJSON = try JSONSerialization.jsonObject(with: workBytes) as! [String: Any]
    let exportedWork = workJSON["work"] as! [[String: Any]]
    let exportedGaps = workJSON["gaps"] as! [[String: Any]]
    let exportedAudits = workJSON["audits"] as! [[String: Any]]
    let counts = workJSON["omissionStateCounts"] as! [String: Int]
    try require(counts["recovered"] == 1_250 && counts["unrecoverable"] == 1
        && workJSON["omissionStateCountsComplete"] as? Bool == true,
        "truncated-export-derived-state-counts-from-returned-page")
    try require(exportedGaps.compactMap { $0["state"] as? String }
        == model.coverageObservations(report: workReport).map { $0.state.rawValue }, "export-and-ui-disagree-on-resolved-state")
    let profileAliases = Set((exportedWork + exportedGaps + exportedAudits).compactMap { $0["profileAlias"] as? String })
    try require(profileAliases.count == 1 && Set(exportedAudits.compactMap { $0["auditAlias"] as? String }).count == 2,
        "export-aliases-lost-profile-linkage-or-distinct-audits")
    let stalledCapture = exportedWork.first { $0["state"] as? String == "stalled" }?["captureAlias"] as? String
    try require(stalledCapture != nil && exportedGaps.first { $0["state"] as? String == "stalled" }?["captureAlias"] as? String == stalledCapture,
        "export-capture-alias-does-not-link-event-and-work")
    for forbidden in [profile, nativeSession, nativeItem, parser, privatePath, privateValue,
                      audit.id.uuidString, secondAudit.id.uuidString, stalledWork.id.uuidString,
                      exactSource.sourceDocumentID!.uuidString] {
        try require(!workText.contains(forbidden), "work-diagnostics-exported-native-identity-path-or-content")
    }

    let unsettledDrop = try CoverageOmissionFixture(gap: .init(reason: .queueExpired, scope: scope),
        firstObservedAt: now, state: .blocked, resolvedAt: nil).decoded()
    let dropReport = report(omissions: [unsettledDrop])
    try require(model.coverageObservations(report: dropReport).first?.state == .recoveryUnconfirmed,
        "expired-capture-with-unknown-original-mislabeled-as-format-support-or-history-loss")

    let splitProfiles = report(history: [unread, retiredHistory])
    let splitBytes = try CoverageDiagnostics(model: model, report: splitProfiles, at: now).encoded()
    let splitJSON = try JSONSerialization.jsonObject(with: splitBytes) as! [String: Any]
    let splitAudits = splitJSON["audits"] as! [[String: Any]]
    try require(Set(splitAudits.compactMap { $0["profileAlias"] as? String }).count == 2
        && Set(splitAudits.compactMap { $0["auditAlias"] as? String }).count == 2
        && !String(decoding: splitBytes, as: UTF8.self).contains("retired-private-profile"),
        "export-merged-retired-profile-or-exported-private-profile-identity")

    // Durable successful reads can restore the same operation after restart. They do not prove live readiness.
    let restarted = AppModel()
    restarted.storageReady = true
    restarted.agentProfiles = model.agentProfiles
    restarted.agentSetupStates = model.agentSetupStates
    let persisted = SuccessfulCollectionRead(scope: scope, operation: .liveRead, succeededAt: now.addingTimeInterval(5),
        producerVersions: ["0.161.0", privateValue], readerVersion: privateValue, hostVersion: privatePath)
    restarted.coverageReport = report(events: [operation], reads: [persisted])
    try require(restarted.coverageGaps.first?.state == .operationRestored && !restarted.monitoringProven,
        "restart-lost-operation-restoration-or-invented-live-readiness")
    let siblingPersisted = SuccessfulCollectionRead(scope: t3, operation: .liveRead, succeededAt: now.addingTimeInterval(5))
    restarted.coverageReport = report(events: [operation], reads: [siblingPersisted])
    try require(restarted.coverageGaps.first?.state == .recoveryUnconfirmed,
        "persisted-sibling-host-read-restored-wrong-operation")
    restarted.coverageReport = report(reads: [persisted])
    let persistedText = String(decoding: try CoverageDiagnostics(model: restarted, report: restarted.coverageReport!, at: now).encoded(), as: UTF8.self)
    try require(!persistedText.contains(privateValue) && !persistedText.contains(privatePath),
        "persisted-read-provenance-exported-unvalidated-version-output")
    model.storageFailed = true
    try require(model.storageAvailability == .failed && model.monitoringIndicator == .unavailable
        && !model.canPerformCoverageAction(retryAction), "failed-storage-kept-ready-indicator-or-enabled-retry")
    model.storageFailed = false
    return ["coverage-distinguishes-restored-operation-from-unrecovered-content",
            "coverage-preserves-terminal-legacy-and-truncated-omissions-without-duplicates",
            "coverage-diagnostics-redact-native-identities-values-paths-and-arbitrary-versions",
            "coverage-preserves-unknown-host-provenance-and-enforces-paused-scoped-retries",
            "coverage-retains-each-audit-and-exact-work-state",
            "coverage-ui-and-export-share-states-content-periods-and-private-aliases",
            "coverage-retry-targets-exact-source-with-explicit-profile-fallback",
            "coverage-keeps-encrypted-required-input-visible-without-ineffective-retry",
            "coverage-keeps-unexposed-native-child-input-visible-without-guessing-encryption",
            "coverage-explains-hook-conflicts-interruption-content-and-capacity-without-history-retry",
            "coverage-restoration-survives-restart-without-inventing-live-readiness"]
}
