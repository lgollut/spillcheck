import Foundation
import Observation
import SpillcheckCore

struct AgentProfileDraft: Codable, Equatable, Sendable {
    var provider: AgentProvider
    var profileID: String
    var registrationID: UUID
    var executablePath: String
    var homePath: String
    var interface: AgentInterface
    var version: String
    var t3Version: String?
    var installed: Bool

    init(provider: AgentProvider, profileID: String = UUID().uuidString,
         registrationID: UUID = UUID(), executablePath: String = "", homePath: String = "",
         interface: AgentInterface = .standaloneCLI, version: String = "",
         t3Version: String? = nil, installed: Bool = false) {
        self.provider = provider
        self.profileID = profileID
        self.registrationID = registrationID
        self.executablePath = executablePath
        self.homePath = homePath
        self.interface = interface
        self.version = version
        self.t3Version = t3Version
        self.installed = installed
    }

    var isComplete: Bool { !executablePath.isEmpty && !homePath.isEmpty && !version.isEmpty }
}

enum AgentSetupState: String {
    case notChecked, notDetected, detected, installedUnverified, connected, unsupported, unavailable

    var label: String {
        switch self {
        case .notChecked: "Not checked yet"
        case .notDetected: "Not detected"
        case .detected: "Executable found"
        case .installedUnverified: "Hooks installed, verification pending"
        case .connected: "Connected"
        case .unsupported: "Unsupported version"
        case .unavailable: "Unavailable"
        }
    }
}

enum AppNotificationState {
    case notRequested, allowed, denied, unavailable

    var label: String {
        switch self {
        case .notRequested: "Not requested yet"
        case .allowed: "Allowed"
        case .denied: "Off"
        case .unavailable: "Unavailable"
        }
    }
}

enum MainRoute: Equatable {
    case inventory, coverage, settings(SettingsPage)
}

enum SettingsPage: String, CaseIterable {
    case general, agents
    var title: String { self == .general ? "General" : "Agents" }
    /// Both connected agents are terminal tools.
    var symbol: String { self == .general ? "slider.horizontal.3" : "terminal" }
}

enum InventorySort: String {
    case latest, confidence
}

enum RevealIssue {
    case cancelled, failed
}

/// One entry with the occurrence facts the list, detail, and menu all summarize the same way.
struct EntrySummary: Identifiable {
    let entry: InventoryEntry
    let occurrences: [InventoryOccurrencePresentation]
    let kind: ValueKind

    var id: InventoryEntryID { entry.id }
    var label: String { entry.label?.text ?? "" }
    var name: String { label.isEmpty ? kind.shortName : "\(kind.shortName) \(label)" }
    var unreviewed: Int { occurrences.filter { $0.review == .unreviewed }.count }
    var confirmed: Int { occurrences.filter { $0.review == .confirmedSecret }.count }
    var falsePositive: Int { occurrences.filter { $0.review == .falsePositive }.count }
    var reviewable: [InventoryOccurrencePresentation] { occurrences.filter { $0.review != nil } }
    var conversationCount: Int { Set(occurrences.map(\.conversation.id)).count }
    var agents: [String] { Array(Set(occurrences.map(\.conversation.provider.displayName))).sorted() }
    var strong: Bool { entry.detectorSignal == .strong }
    var acknowledged: Bool { entry.acknowledgement != nil }
    var unlocated: Bool { entry.kind == .unlocatedDetection }
    /// Values without an acknowledgement that still have unreviewed appearances.
    var needsReview: Bool { !acknowledged && (unreviewed > 0 || unlocated) }
    var allFalsePositive: Bool { unreviewed == 0 && confirmed == 0 && falsePositive > 0 }
    var nothingKept: Bool { acknowledged && !entry.canRevealRetainedValue }
    var latestOccurrence: Date? { occurrences.map(\.observedAt).max() }

    init(entry: InventoryEntry, occurrences: [InventoryOccurrencePresentation]) {
        self.entry = entry
        self.occurrences = occurrences
        if entry.evidence.isEmpty, let acknowledgement = entry.acknowledgement {
            kind = .remembered(acknowledgement)
        } else {
            kind = entry.valueKind
        }
    }

    func matches(search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        let haystack = ([kind.shortName, kind.title, kind.service ?? "", label]
            + occurrences.map(\.conversation.label.text)).joined(separator: " ").lowercased()
        return haystack.contains(query)
    }
}

struct InventoryGroups {
    var active: [EntrySummary] = []
    var notSecrets: [EntrySummary] = []
    var handled: [EntrySummary] = []
    var isEmpty: Bool { active.isEmpty && notSecrets.isEmpty && handled.isEmpty }
    var all: [EntrySummary] { active + notSecrets + handled }
}

/// A collection route the user can reason about: one provider profile through one interface.
struct AgentRoute: Identifiable {
    let provider: AgentProvider
    let profile: AgentProfileDraft?
    let state: AgentSetupState
    let waitingForEvent: Bool

    var id: AgentProvider { provider }
    var name: String {
        guard let profile, !profile.executablePath.isEmpty || profile.installed else { return provider.displayName }
        switch profile.interface {
        case .t3: return "\(provider.displayName) in T3"
        case .standaloneCLI: return "\(provider.displayName) CLI"
        case .desktopCode: return "\(provider.displayName) Desktop"
        }
    }
    var monogram: String { provider == .codex ? "CX" : "CC" }
    var collecting: Bool { state == .connected }
    var shownInCoverage: Bool { state != .notDetected && state != .notChecked }
}

@MainActor @Observable
final class AppModel {
    private(set) var monitoring = MonitoringState()
    @ObservationIgnored var onMonitoringChanged: (() -> Void)?
    @ObservationIgnored var onMonitoringRequested: ((Bool) -> Void)?
    var storageReady = false
    var storageMessage: String? = "Opening protected storage…"
    var monitoringTransition = false
    private var queueProcessing = false
    private(set) var lastCheckedAt: Date?
    var revealedContent: [UUID: String] = [:]
    var revealedExcerpts: [UUID: RetainedExcerpt] = [:]
    var revealedSourceMetadata: [UUID: RetainedSourceContext] = [:]
    var viewingAuthorized = false
    var viewingBusy = false
    var viewingMessage: String?
    var revealIssue: RevealIssue?
    var sourceActionMessages: [UUID: String] = [:]
    var terminalResumeCommand: String?
    var actionBusy = false
    var actionMessage: String? {
        didSet { if let actionMessage, actionMessage != oldValue { showToast(actionMessage) } }
    }
    var selectedEntryID: InventoryEntryID? {
        didSet {
            guard oldValue != selectedEntryID else { return }
            // Selecting a rotated or revoked value opens its section; collapsing it again is up to the user.
            if let selectedEntryID, groups.handled.contains(where: { $0.id == selectedEntryID }) { handledExpanded = true }
            pinnedEntryID = nil
            expandedOccurrenceID = nil
            detailSheet = nil
            selectedOccurrenceID = selectedEntryID.flatMap { defaultOccurrence(for: $0) }
            clearRevealedContent()
            viewingMessage = nil
            revealIssue = nil
            onSelectionChanged?(selectedEntryID)
        }
    }
    var selectedOccurrenceID: UUID? {
        didSet {
            guard oldValue != selectedOccurrenceID else { return }
            clearRevealedContent()
            viewingMessage = nil
            revealIssue = nil
            onOccurrenceSelectionChanged?(selectedOccurrenceID)
        }
    }
    var agentFilter: AgentProvider? {
        didSet { if oldValue != agentFilter { keepSelectionVisible() } }
    }
    var searchText = "" {
        didSet { if oldValue != searchText { keepSelectionVisible() } }
    }
    var sortOrder: InventorySort = .latest
    var route: MainRoute = .inventory
    var handledExpanded = false
    var expandedOccurrenceID: UUID?
    /// Keeps a value in place after a review until the user selects something else.
    var pinnedEntryID: InventoryEntryID?
    /// The value action sheet belongs to the selected value and closes when the selection changes.
    var detailSheet: DetailSheet?
    var toast: String?
    @ObservationIgnored private var toastToken = UUID()
    var dismissedBannerAuditID: UUID?
    private(set) var presentation: InventoryPresentation?
    private(set) var activity: AnalyzedActivity?
    var selectedID: UUID? {
        get { if case .value(let id) = selectedEntryID { id } else { nil } }
        set { selectedEntryID = newValue.map(InventoryEntryID.value) }
    }
    @ObservationIgnored var onSelectionChanged: ((InventoryEntryID?) -> Void)?
    @ObservationIgnored var onOccurrenceSelectionChanged: ((UUID?) -> Void)?
    @ObservationIgnored var onReveal: ((InventoryEntryID, UUID?) -> Void)?
    @ObservationIgnored var onMask: (() -> Void)?
    @ObservationIgnored var onReview: ((UUID, OccurrenceReview) -> Void)?
    @ObservationIgnored var onReviewAll: (([UUID], OccurrenceReview) -> Void)?
    @ObservationIgnored var onAcknowledge: ((ValueFingerprint, ObsoleteAcknowledgement) -> Void)?
    @ObservationIgnored var onRemoveContent: ((ValueFingerprint) -> Void)?
    @ObservationIgnored var onForgetMarker: ((ValueFingerprint) -> Void)?
    @ObservationIgnored var onOpenSource: ((UUID) -> Void)?
    @ObservationIgnored var onTerminalResume: ((UUID) -> Void)?
    var historyProgress: [StoredHistoricalProgress] = []
    var historicalSummaries: [HistoricalAuditSummary] = []
    var isDemo = false
    var windowVisible = false
    var agentProfiles: [AgentProvider: AgentProfileDraft] = [:]
    var agentSetupStates: [AgentProvider: AgentSetupState] = [:]
    var agentSetupMessages: [AgentProvider: String] = [:]
    var verificationPrompts: [AgentProvider: String] = [:]
    var agentSetupBusy: Set<AgentProvider> = []
    var detectingAgents = false
    var notificationState: AppNotificationState = .notRequested
    var notificationMessage: String?
    var notificationBusy = false
    var notificationIndicatorCount = 0
    var launchAtLogin = false
    var loginBusy = false
    var loginMessage: String?
    @ObservationIgnored var onDetectAgents: (() -> Void)?
    @ObservationIgnored var onInstallAgent: ((AgentProvider, AgentProfileDraft) -> Void)?
    @ObservationIgnored var onVerifyAgent: ((AgentProvider) -> Void)?
    @ObservationIgnored var onRepairAgent: ((AgentProvider) -> Void)?
    @ObservationIgnored var onRemoveAgent: ((AgentProvider) -> Void)?
    @ObservationIgnored var onRequestNotificationPermission: (() -> Void)?
    @ObservationIgnored var onLaunchAtLoginRequested: ((Bool) -> Void)?
    @ObservationIgnored var onOpenNotificationSettings: (() -> Void)?
    @ObservationIgnored var onQuit: (() -> Void)?
    var monitoringEnabled: Bool { monitoring.runState == .running && monitoring.mode == .enabled }
    var stopped: Bool { monitoring.runState == .stopped }
    var processing: Bool {
        if case .processing = monitoring.queueActivity { true } else { false }
    }
    var status: String {
        let queueStatus: String
        switch monitoring.queueActivity {
        case .idle: queueStatus = "Idle"
        case .waiting(let count): queueStatus = "Queued: \(count)"
        case .processing: queueStatus = "Processing"
        }
        let coverageStatus = switch monitoring.coverage {
        case .notConfigured: "No collection observed yet"
        case .complete: "No recent coverage gaps"
        case .partial: "Partial coverage"
        }
        return [stopped ? "Monitoring stopped" : (monitoringEnabled ? "Monitoring enabled" : "Monitoring paused"),
         queueStatus, coverageStatus].joined(separator: " · ")
    }

    // MARK: Inventory

    var summaries: [EntrySummary] {
        (presentation?.entries() ?? []).map { EntrySummary(entry: $0, occurrences: presentation?.occurrences(for: $0.id) ?? []) }
    }

    var hasEntries: Bool { !(presentation?.entries().isEmpty ?? true) }

    var filtersActive: Bool { agentFilter != nil || !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var groups: InventoryGroups {
        let visible = summaries.filter { summary in
            (agentFilter == nil || summary.occurrences.contains { $0.conversation.provider == agentFilter })
                && summary.matches(search: searchText)
        }
        let sorted = visible.sorted { left, right in
            if sortOrder == .confidence, left.strong != right.strong { return left.strong }
            return left.entry.observedAt > right.entry.observedAt
        }
        var groups = InventoryGroups()
        for summary in sorted {
            if summary.acknowledged { groups.handled.append(summary) }
            else if summary.allFalsePositive && summary.id != pinnedEntryID { groups.notSecrets.append(summary) }
            else { groups.active.append(summary) }
        }
        return groups
    }

    /// The order arrow keys follow, which includes the collapsed section only when it is open.
    var navigableEntries: [EntrySummary] {
        let groups = groups
        return groups.active + groups.notSecrets + (handledExpanded ? groups.handled : [])
    }

    var needsReview: [EntrySummary] {
        summaries.filter(\.needsReview).sorted { $0.entry.observedAt > $1.entry.observedAt }
    }

    var selectedSummary: EntrySummary? {
        guard let selectedEntryID, let entry = presentation?.entry(selectedEntryID) else { return nil }
        return EntrySummary(entry: entry, occurrences: presentation?.occurrences(for: selectedEntryID) ?? [])
    }

    var selectedRow: InventoryEntry? { selectedEntryID.flatMap { presentation?.entry($0) } }

    var selectedOccurrences: [InventoryOccurrencePresentation] {
        selectedEntryID.map { presentation?.occurrences(for: $0) ?? [] } ?? []
    }

    func moveSelection(by offset: Int) {
        let entries = navigableEntries
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.id == selectedEntryID } ?? (offset > 0 ? -1 : entries.count)
        let next = entries[max(0, min(entries.count - 1, index + offset))]
        if next.id != selectedEntryID { selectedEntryID = next.id }
    }

    func selectEntry(_ id: InventoryEntryID) {
        if route != .inventory { route = .inventory }
        selectedEntryID = id
    }

    func toggleOccurrence(_ id: UUID) {
        if selectedOccurrenceID != id { selectedOccurrenceID = id }
        expandedOccurrenceID = expandedOccurrenceID == id ? nil : id
    }

    func clearFilters() {
        searchText = ""
        agentFilter = nil
    }

    private func defaultOccurrence(for id: InventoryEntryID) -> UUID? {
        let occurrences = presentation?.occurrences(for: id) ?? []
        return (occurrences.first { $0.review == .unreviewed } ?? occurrences.first)?.id
    }

    private func keepSelectionVisible() {
        guard route == .inventory else { return }
        let entries = navigableEntries
        if let selectedEntryID, entries.contains(where: { $0.id == selectedEntryID }) { return }
        selectedEntryID = entries.first?.id
    }

    // MARK: Catch-up banner

    /// The latest recent-history catch-up that found new values or left gaps.
    var bannerSummary: HistoricalAuditSummary? {
        guard let latest = historicalSummaries.first, latest.audit.reason != .firstLaunch,
              latest.audit.id != dismissedBannerAuditID,
              latest.ordinaryValueCount > 0 || !coverageGaps.isEmpty else { return nil }
        return latest
    }

    func isNew(_ summary: EntrySummary) -> Bool {
        guard let banner = bannerSummary, let valueID = summary.entry.valueID else { return false }
        return banner.ordinaryValueIDs.contains(valueID)
    }

    // MARK: Monitoring and coverage

    var routes: [AgentRoute] {
        AgentProvider.allCases.map { provider in
            let state = agentSetupStates[provider] ?? .notChecked
            return AgentRoute(provider: provider, profile: agentProfiles[provider], state: state,
                              waitingForEvent: state == .installedUnverified && verificationPrompts[provider] != nil)
        }
    }

    /// Monitoring is proven only after a connected route has delivered an event.
    var monitoringProven: Bool { routes.contains(where: \.collecting) }

    var coverageWord: String {
        switch monitoring.coverage {
        case .notConfigured: "Not proven"
        case .complete: monitoringProven ? "No recent gaps" : "Not proven"
        case .partial: "Partial"
        }
    }

    var coverageStateText: String {
        switch monitoring.coverage {
        case .notConfigured: "Coverage not proven"
        case .complete: monitoringProven ? "No recent gaps" : "Coverage not proven"
        case .partial: "Partial coverage"
        }
    }

    struct CoverageGapRow: Identifiable {
        let id: String
        let text: String
        var action: (label: String, route: MainRoute)?
    }

    var coverageGaps: [CoverageGapRow] {
        var rows: [CoverageGapRow] = []
        for route in routes {
            switch route.state {
            case .unsupported:
                rows.append(.init(id: "route-\(route.provider.rawValue)",
                    text: "\(route.name): this version isn’t validated, so its sessions aren’t collected.",
                    action: ("Manage agents", .settings(.agents))))
            case .unavailable:
                rows.append(.init(id: "route-\(route.provider.rawValue)",
                    text: "\(route.name): hooks or configuration need repair. Its sessions aren’t collected.",
                    action: ("Manage agents", .settings(.agents))))
            default: break
            }
        }
        if case .partial(let gaps) = monitoring.coverage {
            let counts = Dictionary(grouping: gaps, by: \.reason).mapValues(\.count)
            for reason in counts.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                rows.append(.init(id: reason.rawValue, text: Self.gapText(reason)))
            }
        }
        return rows
    }

    static func gapText(_ reason: CoverageGapReason) -> String {
        switch reason {
        case .unsupportedContent: "Some content wasn’t in a supported format, so it wasn’t analyzed."
        case .unsupportedVersion: "An agent version isn’t supported, so its content wasn’t collected."
        case .sourceUnavailable: "A source couldn’t be read."
        case .missingTimestamp: "Some content had no usable time, so it couldn’t be placed in the last 7 days."
        case .queueSaturated: "The capture queue reached its limit and dropped content."
        case .queueExpired: "Some captured content expired before it was analyzed."
        case .captureRejected: "Some capture requests were rejected."
        case .deliveryUncertain: "Delivery from an agent couldn’t be confirmed."
        case .malformedSource: "Some source content couldn’t be parsed."
        case .incompleteMessage: "Some messages were incomplete when read."
        case .scannerUnavailable: "The scanner was unavailable, so some content wasn’t analyzed."
        case .budgetExhausted: "Unread history remains after a bounded catch-up."
        case .unresolvedCorrelation: "Some sources couldn’t be matched to their conversations."
        case .sourceChanged: "A source changed while it was being read."
        case .notificationBudgetExhausted: "Catch-up summaries stopped at the 1,000-record limit. Results are still listed here."
        }
    }

    var processingText: String {
        if stopped { return "Monitoring stopped" }
        if !monitoringEnabled { return "Not checking while paused" }
        switch monitoring.queueActivity {
        case .processing: return "Analyzing new content"
        case .waiting(let count): return "\(plural(Int(count), "item")) waiting"
        case .idle:
            return lastCheckedAt.map { "Up to date · last checked \($0.formatted(date: .omitted, time: .shortened))" } ?? "Up to date"
        }
    }

    var processingShort: String {
        if !monitoringEnabled { return "Not checking" }
        switch monitoring.queueActivity {
        case .processing: return "Analyzing"
        case .waiting(let count): return "\(count) waiting"
        case .idle: return "Up to date"
        }
    }

    var lastCatchUp: Date? { historyProgress.map(\.progress.audit.end).max() }

    // MARK: Toasts

    func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        toast = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4.2))
            guard let self, self.toastToken == token else { return }
            self.toast = nil
        }
    }

    // MARK: Runtime updates

    func loadDemo() {
        isDemo = true
        storageMessage = nil
        presentation = try? DemoInventory.presentation()
        if let snapshot = try? DemoInventory.snapshot() {
            activity = AnalyzedActivity(snapshot: snapshot, window: AnalyzedActivity.recentWindow(endingAt: .now))
        }
        DemoInventory.configure(self)
        route = .inventory
        selectedEntryID = navigableEntries.first?.id
        actionMessage = "Sample mode. Revealing and changing values are disabled."
    }

    func toggleMonitoring() {
        guard !stopped, !monitoringTransition else { return }
        if let onMonitoringRequested {
            onMonitoringRequested(!monitoringEnabled)
            return
        }
        if monitoringEnabled { monitoring.pause() } else { monitoring.resume() }
        onMonitoringChanged?()
    }

    func pauseAfterBarrier() { monitoring.pause(); onMonitoringChanged?() }
    func resumeAfterBarrier() { monitoring.resume(); onMonitoringChanged?() }
    func updateQueue(count: Int) {
        monitoring.updateQueueActivity(queueProcessing ? .processing(pendingCount: UInt(count), activeCount: 1)
            : count == 0 ? .idle : .waiting(itemCount: UInt(count)))
        if !queueProcessing && count == 0 { lastCheckedAt = .now }
        onMonitoringChanged?()
    }
    func updatePipeline(_ activity: PipelineActivity) {
        queueProcessing = activity.processing
        updateQueue(count: activity.pendingCount)
    }
    func updateCoverage(_ status: CoverageStatus) { monitoring.updateCoverage(status) }
    func clearRevealedContent() {
        revealedContent.removeAll()
        revealedExcerpts.removeAll()
        revealedSourceMetadata.removeAll()
        terminalResumeCommand = nil
        viewingAuthorized = false
    }
    func loadSnapshot(_ snapshot: InventorySnapshot) {
        guard !isDemo, let next = try? InventoryPresentation(snapshot: snapshot) else { return }
        historicalSummaries = (try? snapshot.historicalSummaries()) ?? []
        presentation = next
        activity = AnalyzedActivity(snapshot: snapshot, window: AnalyzedActivity.recentWindow(endingAt: .now))
        if let selectedEntryID, next.entry(selectedEntryID) == nil { self.selectedEntryID = nil }
        if let selectedOccurrenceID, !selectedOccurrences.contains(where: { $0.id == selectedOccurrenceID }) {
            self.selectedOccurrenceID = selectedEntryID.flatMap { defaultOccurrence(for: $0) }
        }
        if selectedEntryID == nil { selectedEntryID = navigableEntries.first?.id }
    }

    func selectValue(_ id: UUID) {
        agentFilter = nil
        searchText = ""
        route = .inventory
        selectedEntryID = .value(id)
    }

    func maskNow() {
        clearRevealedContent()
        revealIssue = nil
        onMask?()
    }

    func stop() {
        monitoring.stop()
    }
}

/// Masked-only preview state with synthetic labels. No payload is written to the production vault.
private enum DemoInventory {
    static func presentation() throws -> InventoryPresentation { try InventoryPresentation(snapshot: snapshot()) }

    static func snapshot() throws -> InventorySnapshot {
        var ledger = InventoryLedger()
        let now = Date()
        let day: TimeInterval = 86_400
        func record(_ provider: AgentProvider, _ session: String, _ item: String, _ type: ContentType,
                    _ interface: AgentInterface, at time: Date) throws -> SourceRecord {
            let bytes = Data("sample \(item)".utf8)
            let identity = try SourceIdentity(session: SessionIdentity(provider: provider, profileID: "sample", sessionID: session), itemID: item)
            let origin = try SourceOrigin(adapterID: "sample", adapterVersion: "1", agentVersion: "sample",
                interface: interface, provenance: .live, canonicalization: .exclusiveAuthority)
            let metadata = try SourceRecordMetadata(identity: identity, contentType: type, contentTime: time,
                observedAt: time, protectedMetadata: ProtectedPayloadReference(), origin: origin)
            return try SourceRecord(metadata: metadata, revision: ContentRevision(keyedDigest: Data(SHA256Like.digest(item))),
                segments: [SourceSegment(id: "body", utf8: bytes)])
        }
        @discardableResult
        func add(_ value: UInt8, rule: String, _ category: SecretCategory, _ signal: SignalStrength,
                 _ provider: AgentProvider, _ session: String, _ item: String, _ type: ContentType = .toolOutput,
                 _ interface: AgentInterface = .standaloneCLI, ago: TimeInterval) throws -> InventoryTransition {
            let source = try record(provider, session, item, type, interface, at: now.addingTimeInterval(-ago))
            let bytes = source.segments[0].utf8
            let location = try CanonicalLocation(segmentID: "body", range: UTF8Range(0, bytes.count))
            let evidence = DetectionEvidence(rule: try RuleIdentity(id: rule, version: "sample"), signal: signal,
                reason: .recognizedFormat, category: category)
            let detection = try LocatedDetection(extraction: ExactExtraction(valueUTF8: bytes, location: location, in: source),
                in: source, fingerprint: ValueFingerprint(keyedDigest: Data(repeating: value, count: 32)), evidence: [evidence],
                protectedValue: ProtectedPayloadReference(), protectedExcerpt: ProtectedPayloadReference())
            return try ledger.ingest(SourceAnalysis(source: source, detectorVersion: "sample", detections: [detection]))
        }
        func deliver(_ transition: InventoryTransition) throws {
            for alert in transition.alerts { try ledger.recordAlertDelivery(alert.id, state: .delivered) }
        }
        // Stripe key: both appearances confirmed, then acknowledged as rotated.
        try add(4, rule: "stripe-access-token", .apiKey, .strong, .claudeCode, "s1", "s1a", .toolOutput, .t3, ago: 6 * day)
        try add(4, rule: "stripe-access-token", .apiKey, .strong, .claudeCode, "s1", "s1b", .finalResponse, .t3, ago: 6 * day - 60)
        // An old AWS key: revoked, removed, then seen again as an obsolete appearance.
        try add(5, rule: "aws-access-token", .apiKey, .strong, .codex, "s12", "s12old", .toolOutput, .t3, ago: 2 * day)
        // OpenAI key with mixed reviews.
        try deliver(try add(2, rule: "openai-api-key", .apiKey, .strong, .codex, "s2", "s2a", .userPrompt, ago: 3 * day))
        try add(2, rule: "openai-api-key", .apiKey, .strong, .codex, "s2", "s2b", .finalResponse, ago: 3 * day - 60)
        // A generic value the user marked as not a secret.
        try add(8, rule: "generic-api-key", .apiKey, .ambiguous, .codex, "s3", "s3a", .toolOutput, ago: 4 * day)
        // Private key whose exact range could not be located.
        let unlocated = try record(.claudeCode, "s7", "s7key", .toolOutput, .standaloneCLI, at: now.addingTimeInterval(-day + 600))
        _ = try ledger.ingest(SourceAnalysis(source: unlocated, detectorVersion: "sample", detections: [],
            unlocated: [UnlocatedDetection(evidence: [DetectionEvidence(rule: try RuleIdentity(id: "private-key", version: "sample"),
                signal: .strong, reason: .privateKeyBlock, category: .privateKey)], reason: .ambiguousRange)]))
        // GitHub token: two appearances in one conversation, one in another.
        try deliver(try add(1, rule: "github-pat", .token, .strong, .claudeCode, "s7", "s7err", .toolError, ago: day))
        try deliver(try add(1, rule: "github-pat", .token, .strong, .codex, "s4", "s4a", .toolOutput, .t3, ago: 240))
        try add(1, rule: "github-pat", .token, .strong, .codex, "s4", "s4b", .toolOutput, .t3, ago: 230)
        // A database password that may be a local default.
        try add(3, rule: "postgres-credential-uri", .connectionCredential, .ambiguous, .claudeCode, "s9", "s9a", ago: 3 * 3600)
        // A replacement AWS key, which is a different value.
        try deliver(try add(7, rule: "aws-access-token", .apiKey, .strong, .codex, "s12", "s12new", .toolOutput, .t3, ago: 5 * 3600))

        let snapshot = ledger.snapshot
        for occurrence in snapshot.occurrences.values {
            switch occurrence.source.identity.itemID {
            case "s1a", "s1b", "s2a": try ledger.review(occurrence.id, as: .confirmedSecret)
            case "s2b", "s3a": try ledger.review(occurrence.id, as: .falsePositive)
            default: break
            }
        }
        let stripe = try ValueFingerprint(keyedDigest: Data(repeating: 4, count: 32))
        let oldAWS = try ValueFingerprint(keyedDigest: Data(repeating: 5, count: 32))
        try ledger.acknowledgeObsolete(stripe, as: .rotated, at: now.addingTimeInterval(-5 * day))
        try ledger.acknowledgeObsolete(oldAWS, as: .revoked, at: now.addingTimeInterval(-2 * day + 3600))
        _ = try ledger.removeContent(for: oldAWS)
        try add(5, rule: "aws-access-token", .apiKey, .strong, .codex, "s12", "s12again", .toolOutput, .t3, ago: day + 3600)
        return ledger.snapshot
    }

    @MainActor static func configure(_ model: AppModel) {
        model.agentProfiles = [
            .codex: AgentProfileDraft(provider: .codex, profileID: "sample", executablePath: "/opt/homebrew/bin/codex",
                                      homePath: "~/.codex", interface: .t3, version: "0.48.2", installed: true),
            .claudeCode: AgentProfileDraft(provider: .claudeCode, profileID: "sample", executablePath: "~/.local/bin/claude",
                                           homePath: "~/.claude", interface: .standaloneCLI, version: "2.2.4", installed: true),
        ]
        model.agentSetupStates = [.codex: .connected, .claudeCode: .connected]
        model.agentSetupMessages = [.codex: "Sample connection.", .claudeCode: "Sample connection."]
        model.notificationState = .allowed
        model.updateCoverage(.partial([CoverageGap(reason: .unsupportedContent)]))
    }

    /// Distinct, deterministic revision digests for synthetic items.
    private enum SHA256Like {
        static func digest(_ text: String) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 32)
            for (index, byte) in text.utf8.enumerated() { bytes[index % 32] = bytes[index % 32] &+ byte &+ UInt8(index % 251) }
            return bytes
        }
    }
}
