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
    case manageAgents, retryHistory(AgentProvider), retrySource(CoverageSourceRetryDescriptor)
    case retrySources([CoverageSourceRetryDescriptor]), exportDiagnostics
    var label: String {
        switch self {
        case .manageAgents: "Manage agents"
        case .retryHistory: "Retry profile history"
        case .retrySource: "Retry this source"
        case .retrySources(let sources): "Retry \(plural(sources.count, "source"))"
        case .exportDiagnostics: "Export diagnostics"
        }
    }
}

/// What was missed, independent of which source, audit or attempt recorded it.
enum CoverageCause: Hashable {
    case route(AgentProvider), diagnostic(CoverageDiagnosticCode), reason(CoverageGapReason)

    /// Codes with their own explanation. Any other code shares its reason's explanation.
    private static let explainedCodes: Set<CoverageDiagnosticCode> = [.encryptedContentUnavailable,
        .nativeChildInputUnavailable, .hookIdentityConflict, .hookInterrupted, .hookContentUnavailable,
        .hookStorageLimit, .authorityStorageLimit]

    init(_ key: CoverageGroupKey) {
        if let code = key.diagnosticCode, Self.explainedCodes.contains(code) { self = .diagnostic(code) }
        else { self = .reason(key.reason) }
    }

    var text: String {
        switch self {
        case .route: "This collection route needs attention."
        case .diagnostic(.encryptedContentUnavailable):
            "This input is encrypted in the Codex source and cannot be analyzed through this route."
        case .diagnostic(.nativeChildInputUnavailable):
            "Codex did not expose the subagent's original incoming instructions through this route."
        case .diagnostic(.hookIdentityConflict):
            "Codex delivered different content for the same hook identity. The later content could not be analyzed."
        case .diagnostic(.hookInterrupted): "This Codex turn was interrupted. A complete final reply could not be confirmed."
        case .diagnostic(.hookContentUnavailable): "This Codex hook did not provide a supported, complete text record."
        case .diagnostic(.hookStorageLimit): "Hook collection reached its storage limit. New hook content could not be analyzed."
        case .diagnostic(.authorityStorageLimit):
            "Conversation tracking reached its storage limit. This conversation could not be registered for collection."
        case .diagnostic: "Some content couldn’t be analyzed."
        case .reason(let reason): AppModel.gapText(reason)
        }
    }
}

/// This key is private model data. Exports assign fresh aliases instead of encoding it.
struct CoverageProfileKey: Hashable {
    let provider: AgentProvider
    let profileID: String
}

/// Views and refresh read coverage many times for each report. A result is reused only while
/// every input it was derived from is unchanged, so no caller has to invalidate it.
struct CoveragePresentationCache {
    struct ObservationInputs: Equatable {
        let recordsRevision: Int
        /// Used only while no report is available.
        let monitoredCoverage: CoverageStatus?
        let operationReads: [CollectionScope: [CollectionOperation: Date]]
        let assessments: [CollectionScope: CollectionAssessment]
    }
    struct RowInputs: Equatable {
        let observations: ObservationInputs
        let setupStates: [AgentProvider: AgentSetupState]
        let profileIDs: [AgentProvider: String]
        /// Row details name today and yesterday.
        let day: Date
    }
    var observations: (inputs: ObservationInputs, value: [AppModel.CoverageObservation])?
    var rows: (inputs: RowInputs, value: [AppModel.CoverageGapRow])?
    var issues: (inputs: RowInputs, value: [AppModel.CoverageIssue])?
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
        /// Operation and content type, which tell rows of one issue apart.
        var sourceLabel = ""
        var retry: CoverageSourceRetryDescriptor?
        var affectedStart: Date?
        var affectedEnd: Date?

        static func affectedText(start: Date?, end: Date?) -> String? {
            guard let start, let end else { return nil }
            return start == end ? "Affected content \(DisplayTime.full(start))"
                : "Affected period \(DisplayTime.full(start)) to \(DisplayTime.full(end))"
        }

        /// Another audit's or attempt's record of the same source and state.
        mutating func absorb(_ other: CoverageGapRow) {
            count += other.count
            firstObservedAt = [firstObservedAt, other.firstObservedAt].compactMap { $0 }.min()
            lastObservedAt = [lastObservedAt, other.lastObservedAt].compactMap { $0 }.max()
            affectedStart = [affectedStart, other.affectedStart].compactMap { $0 }.min()
            affectedEnd = [affectedEnd, other.affectedEnd].compactMap { $0 }.max()
            detail = Self.affectedText(start: affectedStart, end: affectedEnd)
        }

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

    /// Everything with one cause for one profile, however many sources, audits and attempts recorded
    /// it. Its rows keep each source and state apart, so every row's own retry remains available.
    struct CoverageIssue: Identifiable {
        struct ID: Hashable {
            let profile: CoverageProfileKey?
            let cause: CoverageCause
            let recovered: Bool
        }
        /// An operation and content type within the issue.
        struct Part: Identifiable {
            let id: String
            let amount: String
        }

        let id: ID
        let title: String
        /// Each source and state once, in report order.
        let rows: [CoverageGapRow]
        let sourceCount: Int
        let recordCount: Int
        let parts: [Part]
        let firstObservedAt: Date?
        let lastObservedAt: Date?
        let detail: String?
        let action: CoverageAction?

        private static let stateOrder: [CoverageIssueState] = [.blocked, .stalled, .retryable, .recoveryUnconfirmed,
            .historicalLoss, .operationRestored, .reading, .queued, .excluded, .recovered]

        /// `recorded` must not be empty.
        init(id: ID, rows recorded: [CoverageGapRow]) {
            // Each catch-up attempt records a failing source again. List it once per state.
            struct MergeKey: Hashable {
                let retry: CoverageSourceRetryDescriptor
                let state: CoverageIssueState
                let label: String
                let source: String
            }
            var rows: [CoverageGapRow] = []
            var merged: [MergeKey: Int] = [:]
            for row in recorded {
                guard let retry = row.retry else { rows.append(row); continue }
                let key = MergeKey(retry: retry, state: row.state, label: row.stateLabel, source: row.sourceLabel)
                if let index = merged[key] { rows[index].absorb(row) }
                else { merged[key] = rows.count; rows.append(row) }
            }
            self.id = id
            self.rows = rows
            if case .route = id.cause { title = rows[0].text }
            else { title = "\(id.profile?.provider.displayName ?? "Collection"): \(id.cause.text)" }
            sourceCount = Self.distinct(rows.compactMap(\.retry)).count
            recordCount = rows.reduce(0) { $0 + $1.count }
            var labels: [String] = []
            var labelled: [String: [CoverageGapRow]] = [:]
            for row in rows where !row.sourceLabel.isEmpty {
                if labelled[row.sourceLabel] == nil { labels.append(row.sourceLabel) }
                labelled[row.sourceLabel, default: []].append(row)
            }
            parts = labels.map { label in
                let rows = labelled[label] ?? []
                let sources = Self.distinct(rows.compactMap(\.retry)).count
                return Part(id: label, amount: sources > 0 ? plural(sources, "source")
                    : plural(rows.reduce(0) { $0 + $1.count }, "record"))
            }
            firstObservedAt = rows.compactMap(\.firstObservedAt).min()
            lastObservedAt = rows.compactMap(\.lastObservedAt).max()
            detail = CoverageGapRow.affectedText(start: rows.compactMap(\.affectedStart).min(),
                                                 end: rows.compactMap(\.affectedEnd).max())
            let targets = Self.distinct(rows.compactMap { row -> CoverageSourceRetryDescriptor? in
                if case .retrySource(let source)? = row.action { return source }
                return nil
            })
            func rank(_ action: CoverageAction) -> Int {
                switch action {
                case .retrySource, .retrySources: 0
                case .retryHistory: 1
                case .manageAgents: 2
                case .exportDiagnostics: 3
                }
            }
            action = targets.isEmpty ? rows.compactMap(\.action).min { rank($0) < rank($1) } : .retrySources(targets)
        }

        /// Reads in progress need no action, but their content is not analyzed yet.
        var isInProgress: Bool { rows.allSatisfy { $0.state == .queued || $0.state == .reading } }

        /// Each distinct state, most actionable first.
        var stateText: String {
            var labels: [String] = []
            let ordered = rows.sorted {
                (Self.stateOrder.firstIndex(of: $0.state) ?? 0) < (Self.stateOrder.firstIndex(of: $1.state) ?? 0)
            }
            for row in ordered where !labels.contains(row.stateLabel) { labels.append(row.stateLabel) }
            return labels.joined(separator: " · ")
        }

        /// Sources when they are known, otherwise records. A single operation is named here.
        var amountText: String {
            if case .route = id.cause { return "" }
            let amount = sourceCount > 0 ? "\(plural(sourceCount, "source")) · \(plural(recordCount, "record"))"
                : plural(recordCount, "record")
            return parts.count == 1 ? "\(parts[0].id) · \(amount)" : amount
        }

        /// Selections that read the same original source count once.
        static func distinct(_ sources: [CoverageSourceRetryDescriptor]) -> [CoverageSourceRetryDescriptor] {
            // A match requires the same scope and selection, so only those are compared.
            struct Bucket: Hashable {
                let scope: CollectionScope
                let session: SessionIdentity?
                let url: URL?
            }
            var buckets: [Bucket: [CoverageSourceRetryDescriptor]] = [:]
            var unique: [CoverageSourceRetryDescriptor] = []
            for source in sources {
                let bucket = Bucket(scope: source.scope,
                    session: source.scope.path == .publicHistory ? source.session : nil,
                    url: source.scope.path == .versionedTranscript ? source.sourceURL : nil)
                guard !(buckets[bucket] ?? []).contains(where: { $0.identifiesSameSource(as: source) }) else { continue }
                buckets[bucket, default: []].append(source)
                unique.append(source)
            }
            return unique
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
    /// Unrecovered issues, including reads in progress. Excluded content is a stated limit instead.
    var coverageIssues: [CoverageIssue] { allCoverageIssues.filter { !$0.id.recovered } }
    var recoveredCoverageIssues: [CoverageIssue] { allCoverageIssues.filter(\.id.recovered) }

    /// Records outside text analysis by design, by content type. No retry can recover them.
    var excludedCoverageCounts: String? {
        var counts: [ContentType?: Int] = [:]
        for row in coverageRows where row.state == .excluded {
            guard case .issue(let key) = row.id else { continue }
            counts[key.contentType, default: 0] += row.count
        }
        guard !counts.isEmpty else { return nil }
        let places = counts.map { (place: $0.key?.pluralLabel.lowercased() ?? "other content", count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.place < $1.place }
        return places.enumerated().map { index, entry in
            "\(index == 0 ? plural(entry.count, "record") : entry.count.formatted()) in \(entry.place)"
        }.joined(separator: " · ")
    }
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
        case .retrySource(let source): return canRetry(source) && onRetrySource != nil
        case .retrySources(let sources): return onRetrySources != nil && sources.contains(where: canRetry)
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
        case .manageAgents: route = .settings(agentsPage)
        case .retryHistory(let provider): onRetryHistory?(provider)
        case .retrySource(let source): onRetrySource?(source)
        case .retrySources(let sources): onRetrySources?(sources.filter(canRetry))
        case .exportDiagnostics: onExportDiagnostics?()
        }
    }

    private func canRetry(_ source: CoverageSourceRetryDescriptor) -> Bool {
        sourceRetryIsCurrent(source) && !catchingUp && retryingHistory.isEmpty
            && coverageReport?.hasPendingWork(for: source) != true
    }

    /// Whether the profile, host and connection that selected this source are still current.
    /// A retry already under way rechecks each later source with this alone, since its own reads keep
    /// the reader busy.
    func sourceRetryIsCurrent(_ source: CoverageSourceRetryDescriptor) -> Bool {
        source.hasExactSelection && !storageUnavailable && monitoringEnabled && !monitoringTransition
            && !agentSetupBusy.contains(source.scope.provider)
            && agentProfiles[source.scope.provider]?.installed == true
            && agentProfiles[source.scope.provider]?.profileID == source.scope.profileID
            && agentProfiles[source.scope.provider]?.authorizedHosts.contains(source.scope.interface) == true
            && agentSetupStates[source.scope.provider] == .connected
    }

    /// Historical loss and excluded media do not mean the current read operation is failing.
    var activeCollectionLimitations: [CoverageGap] {
        currentCoverageObservations.filter {
            ![.recovered, .queued, .reading, .historicalLoss, .excluded, .operationRestored].contains($0.state)
        }.map(\.gap)
    }

    /// Every route reads these limitations, so an unchanged result is not republished.
    @discardableResult func refreshCollectionLimitations() -> [CoverageGap] {
        let gaps = activeCollectionLimitations
        if collectionLimitations != gaps { collectionLimitations = gaps }
        return gaps
    }

    /// Acceptance still accounts for historical loss when the route can read again.
    var unresolvedCoverageGaps: [CoverageGap] {
        currentCoverageObservations.filter { ![.recovered, .queued, .reading, .excluded].contains($0.state) }.map(\.gap)
    }

    private var coverageObservationInputs: CoveragePresentationCache.ObservationInputs {
        .init(recordsRevision: coverageRecordsRevision, monitoredCoverage: coverageReport == nil ? monitoring.coverage : nil,
              operationReads: lastOperationReads, assessments: collectionAssessments)
    }

    private var currentCoverageObservations: [CoverageObservation] {
        let inputs = coverageObservationInputs
        if let cached = coverageCache.observations, cached.inputs == inputs { return cached.value }
        let observations = coverageObservations(report: coverageReport)
        coverageCache.observations = (inputs, observations)
        return observations
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

    private var coverageRowInputs: CoveragePresentationCache.RowInputs {
        .init(observations: coverageObservationInputs, setupStates: agentSetupStates,
              profileIDs: agentProfiles.mapValues(\.profileID), day: Calendar.current.startOfDay(for: .now))
    }

    private var coverageRows: [CoverageGapRow] {
        let inputs = coverageRowInputs
        if let cached = coverageCache.rows, cached.inputs == inputs { return cached.value }
        let rows = buildCoverageRows()
        coverageCache.rows = (inputs, rows)
        return rows
    }

    private var allCoverageIssues: [CoverageIssue] {
        let inputs = coverageRowInputs
        if let cached = coverageCache.issues, cached.inputs == inputs { return cached.value }
        let issues = buildCoverageIssues(from: coverageRows)
        coverageCache.issues = (inputs, issues)
        return issues
    }

    /// Issues keep the first-occurrence order of their rows.
    private func buildCoverageIssues(from rows: [CoverageGapRow]) -> [CoverageIssue] {
        var ids: [CoverageIssue.ID] = []
        var groups: [CoverageIssue.ID: [CoverageGapRow]] = [:]
        for row in rows where row.state != .excluded {
            let id: CoverageIssue.ID = switch row.id {
            case .route(let provider): .init(profile: nil, cause: .route(provider), recovered: false)
            case .issue(let key): .init(profile: key.profile, cause: .init(key), recovered: row.state == .recovered)
            }
            if groups[id] == nil { ids.append(id) }
            groups[id, default: []].append(row)
        }
        return ids.compactMap { id in groups[id].map { CoverageIssue(id: id, rows: $0) } }
    }

    private func buildCoverageRows() -> [CoverageGapRow] {
        // Same state as `routes`, without deriving assessments that these rows don't show.
        var rows = AgentProvider.allCases.compactMap { provider -> CoverageGapRow? in
            let state = agentSetupStates[provider] ?? .notChecked
            guard state == .unsupported || state == .unavailable else { return nil }
            return .init(id: .route(provider),
                text: "\(provider.displayName): \(state == .unsupported ? "this collection route has not been established." : "its executable, hooks, or configuration need attention.")",
                action: .manageAgents)
        }
        // First-occurrence ordering is stable within a snapshot without serializing private keys.
        var keys: [CoverageGroupKey] = []
        var groups: [CoverageGroupKey: [CoverageObservation]] = [:]
        for observation in currentCoverageObservations {
            let key = observation.groupKey
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(observation)
        }
        for key in keys {
            guard let group = groups[key], let observation = group.first else { continue }
            let gap = observation.gap
            let scopeText = gap.scope.map { "\($0.provider.displayName) shared profile" }
                ?? observation.profile?.provider.displayName ?? "Collection"
            let typeText = gap.contentType.map { " · \($0.pluralLabel)" } ?? ""
            let operationText = gap.operation.map { " · \($0.label)" } ?? ""
            let message = observation.state == .queued ? "This source is waiting to be read."
                : observation.state == .reading ? "This source is being read."
                : observation.state == .excluded ? "Images and other non-text content are excluded from analysis."
                : CoverageCause(key).text
            var row = CoverageGapRow(id: .issue(key), text: "\(scopeText)\(typeText)\(operationText): \(message)",
                state: observation.state, firstObservedAt: group.compactMap(\.first).min(),
                lastObservedAt: group.compactMap(\.last).max(), count: group.count,
                sourceLabel: [gap.operation?.label, gap.contentType?.pluralLabel].compactMap { $0 }.joined(separator: " · "),
                retry: observation.retry, affectedStart: group.compactMap(\.affectedStart).min(),
                affectedEnd: group.compactMap(\.affectedEnd).max())
            row.detail = CoverageGapRow.affectedText(start: row.affectedStart, end: row.affectedEnd)
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
