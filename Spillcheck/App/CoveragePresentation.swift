import Foundation
import SpillcheckCore

enum CoverageIssueState: String, Codable, CaseIterable {
    case recoveryUnconfirmed, retryable, blocked, queued, reading, stalled, historicalLoss, excluded, recovered, operationRestored

    var label: String {
        switch self {
        case .recoveryUnconfirmed: "Recovery not confirmed"
        case .retryable: "Can retry"
        case .blocked: "Needs format support"
        case .queued: "Waiting to read"
        case .reading: "Read in progress"
        case .stalled: "Read stalled"
        case .historicalLoss: "History unavailable"
        case .excluded: "Outside text analysis"
        case .recovered: "Recovered"
        case .operationRestored: "Read restored · earlier coverage unconfirmed"
        }
    }
}

extension CoverageSourceRetryDescriptor {
    var hasExactSelection: Bool {
        if let session, session.provider != scope.provider || session.profileID != scope.profileID { return false }
        switch scope.path {
        case .publicHistory: return scope.provider == .codex && session != nil
        case .versionedTranscript: return sourceURL?.isFileURL == true
        case .hook: return false
        }
    }
}

enum CoverageAction {
    case manageAgents, retryHistory(AgentProvider), retrySource(CoverageSourceRetryDescriptor), exportDiagnostics
    var label: String {
        switch self {
        case .manageAgents: "Manage agents"
        case .retryHistory: "Retry profile history"
        case .retrySource: "Retry this source"
        case .exportDiagnostics: "Export diagnostics"
        }
    }
}

/// This key is private model data. Exports assign fresh aliases instead of encoding it.
struct CoverageProfileKey: Hashable {
    let provider: AgentProvider
    let profileID: String
}

struct CoverageGroupKey: Hashable {
    let profile: CoverageProfileKey?
    let interface: AgentInterface?
    let path: CollectionPath?
    let operation: CollectionOperation?
    let contentType: ContentType?
    let reason: CoverageGapReason
    let sourceKind: CoverageSourceKind?
    let diagnosticCode: CoverageDiagnosticCode?
    let state: CoverageIssueState
    let audit: CoverageAuditIdentity?
    let retry: CoverageSourceRetryDescriptor?
    let workID: UUID?
}

extension AppModel {
    struct CollectionStorageWarning: Identifiable {
        let id: StorageCapacityResource
        let usage: StoreCapacityUsage

        var title: String {
            let name = id == .sourceAuthorities ? "Conversation tracking storage" : "Codex hook storage"
            return name + (usage.state == .nearCapacity ? " is nearly full" : " has reached its limit")
        }
        var detail: String {
            if usage.state == .nearCapacity {
                return id == .sourceAuthorities
                    ? "New conversations may soon be unable to start collection."
                    : "New Codex hook content may soon be unable to enter analysis."
            }
            return id == .sourceAuthorities
                ? "New conversations cannot be registered at this limit. Existing registrations are preserved."
                : "New Codex hook records cannot be stored at this limit. Existing replay checks are preserved."
        }
        var countText: String {
            "\(usage.count.formatted()) of \(usage.countLimit.formatted()) records used · \(usage.remainingCount.formatted()) remaining"
        }
        var byteText: String {
            func bytes(_ count: Int) -> String {
                ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
            }
            return "\(bytes(usage.encryptedBytes)) of \(bytes(usage.encryptedBytesLimit)) encrypted storage used · \(bytes(usage.remainingEncryptedBytes)) remaining"
        }
    }

    /// Lifetime collection metadata is distinct from content gaps in the report window.
    var collectionStorageWarnings: [CollectionStorageWarning] {
        guard !storageUnavailable, let capacity = coverageReport?.capacity else { return [] }
        return [CollectionStorageWarning(id: .sourceAuthorities, usage: capacity.sourceAuthorities),
                CollectionStorageWarning(id: .codexHookContentSlots, usage: capacity.codexHookContentSlots)]
            .filter { $0.usage.state != .available }
    }
    var collectionStorageNeedsAttention: Bool { !collectionStorageWarnings.isEmpty }

    enum CoverageRowID: Hashable { case route(AgentProvider), issue(CoverageGroupKey) }
    struct CoverageGapRow: Identifiable {
        let id: CoverageRowID
        let text: String
        var state: CoverageIssueState = .recoveryUnconfirmed
        var firstObservedAt: Date?
        var lastObservedAt: Date?
        var count = 1
        var action: CoverageAction?
        var detail: String?

        var stateLabel: String {
            if case .issue(let key) = id,
               ![.recovered, .excluded, .queued, .reading].contains(state) {
                switch key.diagnosticCode {
                case .hookIdentityConflict: return "Hook identity conflict"
                case .hookInterrupted: return "Turn interrupted"
                case .hookContentUnavailable: return "Hook content unavailable"
                case .hookStorageLimit: return "Hook storage limit reached"
                case .authorityStorageLimit: return "Conversation storage limit reached"
                case .nativeChildInputUnavailable: return "Subagent input unavailable"
                default: break
                }
            }
            if case .issue(let key) = id, key.diagnosticCode == .encryptedContentUnavailable,
               [.blocked, .recoveryUnconfirmed, .retryable].contains(state) {
                return "Encrypted input unavailable"
            }
            return state.label
        }
    }

    /// The UI and export consume the same resolved observations. Native identity stays private.
    struct CoverageObservation {
        let gap: CoverageGap
        let state: CoverageIssueState
        let first: Date?
        let last: Date?
        var profile: CoverageProfileKey?
        var audit: CoverageAuditIdentity? = nil
        var resolvedAt: Date? = nil
        var retry: CoverageSourceRetryDescriptor? = nil
        var workID: UUID? = nil
        var affectedStart: Date? {
            [gap.interval?.start, gap.recovery?.contentTime].compactMap { $0 }.min()
        }
        var affectedEnd: Date? {
            [gap.interval?.end, gap.recovery?.contentTime].compactMap { $0 }.max()
        }
        var groupKey: CoverageGroupKey {
            .init(profile: profile, interface: gap.scope?.interface, path: gap.scope?.path,
                  operation: gap.operation, contentType: gap.contentType, reason: gap.reason,
                  sourceKind: gap.sourceKind, diagnosticCode: gap.diagnosticCode, state: state, audit: audit, retry: retry, workID: audit == nil ? workID : nil)
        }
    }

    var coverageGaps: [CoverageGapRow] { coverageRows.filter { $0.state != .recovered } }
    var recoveredCoverageGaps: [CoverageGapRow] { coverageRows.filter { $0.state == .recovered } }
    var coverageNeedsAttention: Bool {
        coverageGaps.contains { ![.queued, .reading, .excluded].contains($0.state) } || coverageReport?.isTruncated == true
    }
    /// Waiting and in-progress reads need no action, but their content is not yet analyzed.
    var coverageHasUnreadHistory: Bool {
        coverageGaps.contains { $0.state == .queued || $0.state == .reading }
    }

    func canPerformCoverageAction(_ action: CoverageAction) -> Bool {
        guard !isDemo, !actionBusy else { return false }
        switch action {
        case .manageAgents: return true
        case .exportDiagnostics:
            return !exportingDiagnostics && onExportDiagnostics != nil
                && (canExportStartupDiagnostics || (!storageUnavailable && coverageReport != nil))
        case .retrySource(let source):
            return source.hasExactSelection && !storageUnavailable && monitoringEnabled && !monitoringTransition
                && !agentSetupBusy.contains(source.scope.provider) && !catchingUp && retryingHistory.isEmpty
                && agentProfiles[source.scope.provider]?.installed == true
                && agentProfiles[source.scope.provider]?.profileID == source.scope.profileID
                && agentProfiles[source.scope.provider]?.authorizedHosts.contains(source.scope.interface) == true
                && agentSetupStates[source.scope.provider] == .connected && onRetrySource != nil
                && coverageReport?.hasPendingWork(for: source) != true
        case .retryHistory(let provider):
            return !storageUnavailable && monitoringEnabled && !monitoringTransition && !agentSetupBusy.contains(provider)
                && !catchingUp && retryingHistory.isEmpty
                && coverageReport?.queue.historicalCount == 0
                && agentProfiles[provider]?.installed == true
                && agentSetupStates[provider] == .connected
                && onRetryHistory != nil
        }
    }

    func performCoverageAction(_ action: CoverageAction) {
        guard canPerformCoverageAction(action) else { return }
        switch action {
        case .manageAgents: route = .settings(.agents)
        case .retryHistory(let provider): onRetryHistory?(provider)
        case .retrySource(let source): onRetrySource?(source)
        case .exportDiagnostics: onExportDiagnostics?()
        }
    }

    /// Historical loss and excluded media do not mean the current read operation is failing.
    var activeCollectionLimitations: [CoverageGap] {
        coverageObservations(report: coverageReport).filter {
            ![.recovered, .queued, .reading, .historicalLoss, .excluded, .operationRestored].contains($0.state)
        }.map(\.gap)
    }

    /// Acceptance still accounts for historical loss when the route can read again.
    var unresolvedCoverageGaps: [CoverageGap] {
        coverageObservations(report: coverageReport).filter { ![.recovered, .queued, .reading, .excluded].contains($0.state) }.map(\.gap)
    }

    func coverageObservations(report: CoverageReport?) -> [CoverageObservation] {
        func profile(_ gap: CoverageGap, audit: CoverageAuditIdentity? = nil) -> CoverageProfileKey? {
            if let scope = gap.scope { return .init(provider: scope.provider, profileID: scope.profileID) }
            if let audit { return .init(provider: audit.provider, profileID: audit.profileID) }
            if let session = gap.recovery?.session { return .init(provider: session.provider, profileID: session.profileID) }
            return nil
        }
        guard let report else {
            guard case .partial(let gaps) = monitoring.coverage else { return [] }
            return gaps.map { .init(gap: $0, state: $0.excludedContent == true ? .excluded : .recoveryUnconfirmed,
                first: nil, last: nil, profile: profile($0)) }
        }
        var observations = report.independentlyReportedEvents.map { event -> CoverageObservation in
            let gap = event.gap
            let state: CoverageIssueState
            if report.hasRecoveredBacklog(event) { state = .recovered }
            else if hasRestoredOperation(event, report: report) { state = .operationRestored }
            else if gap.excludedContent == true { state = .excluded }
            else if event.isIntermediateBacklog, let audit = event.audit {
                state = auditIssueState(audit, scope: gap.scope, report: report)
            } else if let workID = event.workID, let work = report.work(id: workID) {
                state = workIssueState(work)
            } else { state = .recoveryUnconfirmed }
            return .init(gap: gap, state: state, first: event.observedAt, last: event.observedAt,
                         profile: profile(gap, audit: event.audit), audit: event.audit,
                         retry: sourceRetry(for: gap, audit: event.audit, workID: event.workID, report: report), workID: event.workID)
        }
        observations += report.omissions.items.map { omission in
            // Capture losses have no native row locator. Their atomic ledger link identifies
            // the exact lost work even when several sources expired at the same instant.
            let work = report.work(omissionID: omission.id)
            let state: CoverageIssueState = switch omission.state {
            case .recovered: .recovered
            case .unrecoverable: .historicalLoss
            case .retryable: omission.gap.excludedContent == true ? .excluded : .retryable
            case .blocked:
                omission.gap.excludedContent == true ? .excluded
                    : omission.gap.isRequiredFormatFailure == true ? .blocked
                    : work?.context.retry?.hasExactSelection == true ? .retryable : .recoveryUnconfirmed
            }
            return .init(gap: omission.gap, state: state, first: omission.firstObservedAt,
                last: omission.resolvedAt ?? omission.firstObservedAt,
                profile: profile(omission.gap, audit: work?.context.audit), audit: work?.context.audit,
                resolvedAt: omission.resolvedAt,
                retry: sourceRetry(for: omission.gap, audit: work?.context.audit, workID: work?.id, report: report),
                workID: work?.id)
        }
        // Keep every unread audit. A later audit for the same profile cannot erase earlier unread work.
        var unreadAudits = Set(observations.filter { $0.gap.reason == .budgetExhausted && $0.state != .recovered }
            .compactMap(\.audit))
        var eventScopes: [CoverageAuditIdentity: Set<CollectionScope>] = [:]
        for event in report.gapEvents.items {
            if let audit = event.audit, let scope = event.gap.scope { eventScopes[audit, default: []].insert(scope) }
        }
        for history in report.history.items where history.progress.hasUnreadContent {
            let audit = CoverageAuditIdentity(auditID: history.progress.audit.id,
                provider: history.provider, profileID: history.profileID)
            guard !unreadAudits.contains(audit) else { continue }
            let scopes = eventScopes[audit] ?? []
            // A shared native profile cannot establish which host produced an old audit.
            let scope = scopes.count == 1 ? scopes.first : nil
            let gap = CoverageGap(reason: .budgetExhausted,
                interval: DateInterval(start: history.progress.audit.start, end: history.progress.audit.end),
                scope: scope, operation: .historicalRead)
            let state = auditIssueState(audit, scope: scope, report: report)
            if state != .recovered { unreadAudits.insert(audit) }
            observations.append(.init(gap: gap, state: state,
                first: history.lastAttemptedAt, last: history.lastAttemptedAt,
                profile: .init(provider: history.provider, profileID: history.profileID), audit: audit,
                retry: sourceRetry(for: gap, audit: audit, report: report)))
        }
        return observations
    }

    private func sourceRetry(for gap: CoverageGap, audit: CoverageAuditIdentity? = nil, workID: UUID? = nil,
                             report: CoverageReport) -> CoverageSourceRetryDescriptor? {
        // A record can come from a child file selected during a parent capture. Its own
        // recovery coordinates take precedence over the parent capture's admission source.
        if let reference = gap.recovery {
            guard let scope = gap.scope else { return nil }
            let selected = CoverageSourceRetryDescriptor(scope: scope, session: reference.session,
                sourceDocumentID: reference.retrySourceDocumentID, sourceURL: reference.sourceURL)
            return selected.hasExactSelection ? selected : nil
        }
        if let workID, let work = report.work(id: workID),
           let retry = work.context.retry, retry.hasExactSelection { return retry }
        guard let audit else { return nil }
        let matching = report.work(audit: audit).filter {
            gap.scope == nil || $0.context.scope == gap.scope
        }.compactMap { $0.context.retry }.filter(\.hasExactSelection)
        if let only = matching.first, matching.allSatisfy({ $0.identifiesSameSource(as: only) }) { return only }
        return nil
    }

    private func auditIssueState(_ audit: CoverageAuditIdentity, scope: CollectionScope?,
                                 report: CoverageReport) -> CoverageIssueState {
        let work = report.work(audit: audit).filter { scope == nil || $0.context.scope == scope }
        if work.contains(where: { $0.state == .processing }) { return .reading }
        if work.contains(where: { $0.state == .queued }) { return .queued }
        if work.contains(where: { $0.state == .stalled }) { return .stalled }
        if work.contains(where: { $0.state == .terminal && $0.context.retry?.hasExactSelection == true }) { return .retryable }
        return .recoveryUnconfirmed
    }

    private func workIssueState(_ work: StoredCollectionWork) -> CoverageIssueState {
        switch work.state {
        case .queued: .queued
        case .processing: .reading
        case .stalled: .stalled
        case .terminal: work.context.retry?.hasExactSelection == true ? .retryable : .recoveryUnconfirmed
        case .completed, .recovered: .recoveryUnconfirmed // Work completion alone cannot settle omitted content.
        }
    }

    func hasRestoredOperation(_ event: StoredCoverageGapEvent, report: CoverageReport? = nil) -> Bool {
        let gap = event.gap
        guard gap.isRequiredFormatFailure == true,
              [.malformedSource, .sourceUnavailable].contains(gap.reason),
              gap.recovery == nil, gap.contentType == nil, let scope = gap.scope, let operation = gap.operation,
              operation != .hookDelivery else { return false }
        let persistedRead = (report ?? coverageReport)?.latestSuccessfulRead(scope: scope, operation: operation)
        let readAt = [lastOperationReads[scope]?[operation], persistedRead].compactMap { $0 }.max()
        guard let readAt, readAt > event.observedAt else { return false }
        // A read restores the operation, not the skipped content. A newer known failure still wins.
        if let assessment = collectionAssessments[scope] {
            return !assessment.failures.contains { $0.operation == operation }
                && (assessment.canPerform(operation) || persistedRead != nil)
        }
        return persistedRead != nil
    }

    private var coverageRows: [CoverageGapRow] {
        var rows = routes.compactMap { route -> CoverageGapRow? in
            guard route.state == .unsupported || route.state == .unavailable else { return nil }
            return .init(id: .route(route.provider),
                text: "\(route.name): \(route.state == .unsupported ? "this collection route has not been established." : "its executable, hooks, or configuration need attention.")",
                action: .manageAgents)
        }
        let observations = coverageObservations(report: coverageReport)
        let grouped = Dictionary(grouping: observations, by: \.groupKey)
        // First-occurrence ordering is stable within a snapshot without serializing private keys.
        var seen = Set<CoverageGroupKey>()
        for observation in observations where seen.insert(observation.groupKey).inserted {
            let key = observation.groupKey
            guard let group = grouped[key] else { continue }
            let gap = observation.gap
            let scopeText = gap.scope.map { "\($0.provider.displayName) shared profile" }
                ?? observation.profile?.provider.displayName ?? "Collection"
            let typeText = gap.contentType.map { " · \($0.pluralLabel)" } ?? ""
            let operationText = gap.operation.map { " · \($0.label)" } ?? ""
            let message = observation.state == .queued ? "This source is waiting to be read."
                : observation.state == .reading ? "This source is being read."
                : observation.state == .excluded ? "Images and other non-text content are excluded from analysis."
                : gap.diagnosticCode == .encryptedContentUnavailable
                    ? "This input is encrypted in the Codex source and cannot be analyzed through this route."
                : gap.diagnosticCode == .nativeChildInputUnavailable
                    ? "Codex did not expose the subagent's original incoming instructions through this route."
                : gap.diagnosticCode == .hookIdentityConflict
                    ? "Codex delivered different content for the same hook identity. The later content could not be analyzed."
                : gap.diagnosticCode == .hookInterrupted
                    ? "This Codex turn was interrupted. A complete final reply could not be confirmed."
                : gap.diagnosticCode == .hookContentUnavailable
                    ? "This Codex hook did not provide a supported, complete text record."
                : gap.diagnosticCode == .hookStorageLimit
                    ? "Hook collection reached its storage limit. New hook content could not be analyzed."
                : gap.diagnosticCode == .authorityStorageLimit
                    ? "Conversation tracking reached its storage limit. This conversation could not be registered for collection."
                : Self.gapText(gap.reason)
            var row = CoverageGapRow(id: .issue(key), text: "\(scopeText)\(typeText)\(operationText): \(message)",
                state: observation.state, firstObservedAt: group.compactMap(\.first).min(),
                lastObservedAt: group.compactMap(\.last).max(), count: group.count)
            if let start = group.compactMap(\.affectedStart).min(), let end = group.compactMap(\.affectedEnd).max() {
                row.detail = start == end ? "Affected content \(DisplayTime.full(start))"
                    : "Affected period \(DisplayTime.full(start)) to \(DisplayTime.full(end))"
            }
            switch observation.state {
            case .recovered, .excluded, .queued, .reading, .historicalLoss: break
            case .operationRestored: row.action = .exportDiagnostics
            case .blocked: row.action = observation.retry.map(CoverageAction.retrySource) ?? .exportDiagnostics
            case .recoveryUnconfirmed, .retryable, .stalled:
                if let retry = observation.retry { row.action = .retrySource(retry) }
                else if let profile = observation.profile, profile.profileID == agentProfiles[profile.provider]?.profileID {
                    row.action = agentSetupStates[profile.provider] == .connected ? .retryHistory(profile.provider) : .manageAgents
                } else { row.action = .exportDiagnostics }
            }
            // Unexposed or opaque input and hook-only content have no supported history repair.
            if gap.diagnosticCode == .encryptedContentUnavailable || gap.diagnosticCode == .authorityStorageLimit
                || gap.diagnosticCode == .nativeChildInputUnavailable
                || gap.diagnosticCode == .hookStorageLimit || gap.scope?.path == .hook,
               ![.recovered, .excluded, .queued, .reading, .historicalLoss].contains(observation.state) {
                row.action = .exportDiagnostics
            }
            rows.append(row)
        }
        return rows
    }
}
