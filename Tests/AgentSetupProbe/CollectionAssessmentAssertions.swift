import Foundation
import SpillcheckCore

private enum CollectionAssessmentAssertionFailure: Error { case failed(String) }

private struct AssessmentOmissionFixture: Encodable {
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
func collectionAssessmentAssertions() throws -> [String] {
    func require(_ condition: Bool, _ name: String) throws {
        guard condition else { throw CollectionAssessmentAssertionFailure.failed(name) }
    }
    let now = Date()
    for provider in AgentProvider.allCases {
        let model = AppModel()
        model.storageReady = true
        let profileID = "synthetic-assessment-profile"
        let path: CollectionPath = provider == .claudeCode ? .versionedTranscript : .publicHistory
        let scope = CollectionScope(provider: provider, profileID: profileID, interface: .standaloneCLI, path: path)
        let sibling = CollectionScope(provider: provider, profileID: profileID, interface: .t3, path: path)
        let version = provider == .claudeCode ? "2.1.296" : "0.162.1"
        model.agentProfiles[provider] = .init(provider: provider, profileID: profileID,
            version: version, installed: true)
        model.agentSetupStates[provider] = .connected
        let successfulRead = CollectionAssessment(scope: scope, observedExecutableVersion: version,
            usableOperations: [.liveRead, .historicalRead])
        model.collectionAssessments[sibling] = .init(scope: sibling, observedExecutableVersion: version,
            usableOperations: [.liveRead, .historicalRead])
        let reference = CoverageRecoveryReference(session: try SessionIdentity(provider: provider,
            profileID: profileID, sessionID: "synthetic-session"), locator: .upstreamItem,
            itemID: "synthetic-item", contentTime: now, parserContract: "test-contract")
        let gap = CoverageGap(reason: .malformedSource, scope: scope, contentType: .toolOutput,
            recovery: reference, isRequiredFormatFailure: true)
        let event = StoredCoverageGapEvent(gap: gap, observedAt: now)
        func report(state: CoverageOmissionState) throws -> CoverageReport {
            let omission = try AssessmentOmissionFixture(gap: gap, firstObservedAt: now, state: state,
                resolvedAt: state == .recovered ? now.addingTimeInterval(1) : nil).decoded()
            return CoverageReport(window: AnalyzedActivity.recentWindow(endingAt: now.addingTimeInterval(2)),
                gapEvents: .init(items: [event], totalCount: 1), omissions: .init(items: [omission], totalCount: 1),
                history: .init(items: [], totalCount: 0),
                queue: .init(count: 0, encryptedBytes: 0, claimedCount: 0, historicalCount: 0), oldestPendingCaptureAt: nil)
        }
        func assessment(_ selected: CollectionScope) -> CollectionAssessment? {
            model.routes.first { $0.provider == provider }?.assessments.first { $0.scope == selected }
        }
        model.coverageReport = try report(state: .blocked)
        model.collectionLimitations = model.activeCollectionLimitations

        // Normalization publishes a successful read before its durable recovery commits. The
        // existing omission must still affect the route without contaminating that raw read.
        model.collectionAssessments[scope] = successfulRead
        try require(assessment(scope)?.status == .partial
            && assessment(scope)?.unavailableContent == [.toolOutput], "unsettled-omission-missing-from-route")
        try require(model.collectionAssessments[scope] == successfulRead
            && assessment(sibling)?.status == .compatible, "derived-failure-mutated-observation-or-sibling")

        // A refresh observes the commit. No new batch or executable assessment follows it.
        model.coverageReport = try report(state: .recovered)
        model.collectionLimitations = model.activeCollectionLimitations
        try require(assessment(scope)?.status == .compatible
            && assessment(scope)?.failures.isEmpty == true
            && assessment(scope)?.unavailableContent.isEmpty == true
            && model.recoveredCoverageGaps.count == 1 && model.coverageGaps.isEmpty,
            "settled-recovery-left-stale-route-failure-until-another-batch")

        let operationFailure = CompatibilityFailure(reason: .sourceUnavailable, operation: .historicalRead)
        let rawFailure = CollectionAssessment(scope: scope, observedExecutableVersion: version,
            usableOperations: [.liveRead], unavailableContent: [.toolError], failures: [operationFailure])
        model.collectionAssessments[scope] = rawFailure
        model.coverageReport = try report(state: .blocked)
        model.collectionLimitations = model.activeCollectionLimitations
        try require(assessment(scope)?.unavailableContent == [.toolOutput, .toolError],
            "durable-omission-replaced-intrinsic-reader-failure")
        model.coverageReport = try report(state: .recovered)
        model.collectionLimitations = model.activeCollectionLimitations
        try require(assessment(scope) == rawFailure, "recovery-erased-unrelated-reader-failure")
        let json = try JSONSerialization.jsonObject(with: CoverageDiagnostics(model: model,
            report: model.coverageReport!, at: now).encoded()) as! [String: Any]
        let routes = json["routes"] as! [[String: Any]]
        let exported = routes.first { $0["configuredInterface"] as? String == AgentInterface.standaloneCLI.rawValue }
        let failures = exported?["failures"] as? [[String: Any]]
        try require(failures?.count == 1
            && failures?.first?["operation"] as? String == CollectionOperation.historicalRead.rawValue,
            "diagnostics-retained-recovered-failure-or-lost-reader-failure")
        do {
            let shared = model.routes.first { $0.provider == provider }
            try require(shared?.name == provider.displayName && shared?.hostRoutes.count == 1
                && shared?.hostRoutes.first?.name == "Shared profile"
                && shared?.hostRoutes.first?.summary.contains("Host not identified") == true
                && shared?.hostRoutes.first?.acceptanceSummary.contains("shared \(provider.displayName) profile") == true
                && shared?.hostRoutes.first?.status == .partial && shared?.collecting == true
                && shared?.assessments.count == 2 && assessment(sibling)?.status == .compatible,
                "shared-profile-invented-host-or-lost-collection-and-scoped-failure")
            try require(routes.allSatisfy {
                $0["host"] == nil && $0["hostVersion"] == nil && $0["hostAttribution"] as? String == "unverified"
            }, "shared-profile-diagnostics-assigned-configured-interface-to-observed-host")
            model.collectionAssessments[scope] = successfulRead
            model.collectionAssessments[sibling] = .init(scope: sibling,
                failures: [.init(reason: .sourceUnavailable, operation: .liveRead)])
            let mixed = model.routes.first { $0.provider == provider }
            try require(mixed?.collecting == true && mixed?.hostRoutes.first?.status == .partial,
                "shared-profile-compatible-scope-hid-incompatible-sibling")
            model.collectionAssessments.removeAll()
            let unobserved = model.routes.first { $0.provider == provider }
            try require(unobserved?.collecting == false
                && unobserved?.hostRoutes.first?.status == .unverified
                && unobserved?.hostRoutes.first?.acceptanceSummary.contains("Collection is observed") == false,
                "shared-profile-registration-invented-content-observation")
            try require(unobserved?.hostRoutes.first?.partialDesktopSupport == false,
                "default-authorization-expanded-to-desktop")
            model.agentProfiles[provider]?.authorizedHosts.insert(.desktopCode)
            let optedInUnobserved = model.routes.first { $0.provider == provider }
            try require(optedInUnobserved?.hostRoutes.first?.status == .unverified
                && optedInUnobserved?.hostRoutes.first?.summary.contains(provider == .codex ? "Automatic side-chat collection unavailable" : "Desktop side questions unsupported") == true
                && optedInUnobserved?.collecting == false,
                "desktop-opt-in-invented-collection-or-hid-side-chat-limitation")
            model.collectionAssessments[scope] = successfulRead
            let optedInObserved = model.routes.first { $0.provider == provider }
            try require(optedInObserved?.collecting == true
                && optedInObserved?.hostRoutes.first?.status == .partial
                && optedInObserved?.hostRoutes.first?.name == "Shared profile"
                && optedInObserved?.assessments.allSatisfy { $0.acceptanceEvidence == .unverified } == true,
                "desktop-native-read-claimed-full-coverage-host-or-acceptance")
            model.agentProfiles[provider]?.authorizedHosts.remove(.desktopCode)
            try require(model.routes.first { $0.provider == provider }?.hostRoutes.first?.status == .compatible,
                "desktop-opt-out-damaged-existing-shared-native-read")
        }
    }
    let hookModel = AppModel()
    hookModel.storageReady = true
    hookModel.agentProfiles[.codex] = .init(provider: .codex, profileID: "hook-profile",
        version: "0.162.1", installed: true)
    hookModel.agentSetupStates[.codex] = .connected
    let hookScope = CollectionScope(provider: .codex, profileID: "hook-profile",
        interface: .standaloneCLI, path: .hook)
    let nativeScope = CollectionScope(provider: .codex, profileID: "hook-profile",
        interface: .standaloneCLI, path: .publicHistory)
    hookModel.collectionAssessments[hookScope] = .init(scope: hookScope, usableOperations: [.liveRead])
    let hookRoute = hookModel.routes.first { $0.provider == .codex }?.hostRoutes.first
    try require(hookRoute?.status == .partial
        && hookRoute?.summary.contains("Hook collection excludes intermediate replies") == true
        && hookRoute?.summary.contains("Hook content has no catch-up") == true
        && hookModel.collectionAssessments[hookScope]?.failures.isEmpty == true
        && hookModel.collectionAssessments[hookScope]?.acceptanceEvidence == .unverified,
        "hook-read-hid-known-limitation-or-invented-format-failure-or-acceptance")
    let emptyReport = CoverageReport(window: AnalyzedActivity.recentWindow(endingAt: now),
        gapEvents: .init(items: [], totalCount: 0), omissions: .init(items: [], totalCount: 0),
        history: .init(items: [], totalCount: 0),
        queue: .init(count: 0, encryptedBytes: 0, claimedCount: 0, historicalCount: 0), oldestPendingCaptureAt: nil)
    hookModel.restoreSuccessfulReads(from: emptyReport)
    try require(hookModel.collectionAssessments[hookScope]?.unavailableContent == [.intermediateResponse],
        "refresh-erased-hook-intermediate-limitation")
    hookModel.collectionAssessments[nativeScope] = .init(scope: nativeScope,
        usableOperations: [.liveRead, .historicalRead])
    try require(hookModel.collectionAssessments[nativeScope]?.status == .compatible
        && hookModel.routes.first { $0.provider == .codex }?.hostRoutes.first?.summary.contains("Catch-up available") == true,
        "hook-limitation-disabled-native-history-in-same-host")
    let hookExport = try JSONSerialization.jsonObject(with: CoverageDiagnostics(model: hookModel,
        report: emptyReport, at: now).encoded()) as! [String: Any]
    let hookExportRoutes = hookExport["routes"] as! [[String: Any]]
    try require(hookExportRoutes.first { $0["path"] as? String == "hook" }?["unavailableContent"] as? [String]
        == [ContentType.intermediateResponse.rawValue]
        && hookExportRoutes.first { $0["path"] as? String == "publicHistory" }?["unavailableContent"] as? [String] == [],
        "diagnostics-lost-hook-limitation-or-assigned-it-to-native-route")
    return ["settled-content-recovery-clears-derived-route-failures-without-new-provider-input",
            "recovery-preserves-intrinsic-reader-failures-and-sibling-host-assessments",
            "hook-limitation-stays-visible-without-inventing-failure-or-disabling-native-history",
            "shared-profiles-collect-without-assigning-host-and-preserve-scoped-status",
            "explicit-desktop-routes-keep-partial-status-without-host-or-acceptance-claims"]
}
