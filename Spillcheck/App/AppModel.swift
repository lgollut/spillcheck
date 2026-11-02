import Foundation
import Observation
import SpillcheckCore

struct AgentProfileDraft: Codable, Equatable, Sendable {
    var provider: AgentProvider
    var profileID: String
    var registrationID: UUID
    var executablePath: String
    var homePath: String
    /// Legacy Codable key: the owned hook's transport binding, not the producer host.
    var interface: AgentInterface
    var authorizedHosts: Set<AgentInterface>
    var version: String
    var t3Version: String?
    var installed: Bool
    var connectionProof: ConnectionVerificationProof?

    init(provider: AgentProvider, profileID: String = UUID().uuidString,
         registrationID: UUID = UUID(), executablePath: String = "", homePath: String = "",
         interface: AgentInterface = .standaloneCLI, version: String = "",
         t3Version: String? = nil, installed: Bool = false,
         connectionProof: ConnectionVerificationProof? = nil,
         authorizedHosts: Set<AgentInterface>? = nil) {
        self.provider = provider
        self.profileID = profileID
        self.registrationID = registrationID
        self.executablePath = executablePath
        self.homePath = homePath
        self.interface = interface
        self.authorizedHosts = authorizedHosts ?? Self.legacyHosts(interface: interface)
        self.version = version
        self.t3Version = t3Version
        self.installed = installed
        self.connectionProof = connectionProof
    }

    var isComplete: Bool { !executablePath.isEmpty && !homePath.isEmpty && !version.isEmpty }

    /// Existing and inferred authorization never expands when another route becomes eligible.
    static let defaultHosts: Set<AgentInterface> = [.standaloneCLI, .t3]
    static func supportedHosts(for provider: AgentProvider) -> Set<AgentInterface> {
        defaultHosts.union([.desktopCode])
    }
    static func legacyHosts(interface: AgentInterface) -> Set<AgentInterface> {
        interface == .desktopCode ? [] : defaultHosts
    }
    var collectionInterfaces: [AgentInterface] {
        authorizedHosts.sorted { $0.rawValue < $1.rawValue }
    }
    /// Shared hooks identify their registration transport. Removing that transport from
    /// authorization would silently discard events from other hosts using the same hook.
    var hasValidHostAuthorization: Bool {
        authorizedHosts.isSubset(of: Self.supportedHosts(for: provider))
            && (interface == .desktopCode && authorizedHosts.isEmpty || authorizedHosts.contains(interface))
    }
    var requiresDesktopDeliveryRoute: Bool {
        installed && interface == .desktopCode && authorizedHosts.contains(.desktopCode)
    }
    /// Says why this profile's sessions aren't collected, and what to choose instead.
    var unsupportedMessage: String {
        interface == .desktopCode
            ? "Enable partial desktop support for this shared \(provider.displayName) profile to collect saved local conversations."
            : "This collection route has not been established, so its sessions aren’t collected."
    }

    private enum CodingKeys: String, CodingKey {
        case provider, profileID, registrationID, executablePath, homePath, interface
        case authorizedHosts, version, t3Version, installed, connectionProof
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(AgentProvider.self, forKey: .provider)
        profileID = try values.decode(String.self, forKey: .profileID)
        registrationID = try values.decode(UUID.self, forKey: .registrationID)
        executablePath = try values.decode(String.self, forKey: .executablePath)
        homePath = try values.decode(String.self, forKey: .homePath)
        interface = try values.decode(AgentInterface.self, forKey: .interface)
        version = try values.decode(String.self, forKey: .version)
        t3Version = try values.decodeIfPresent(String.self, forKey: .t3Version)
        installed = try values.decode(Bool.self, forKey: .installed)
        connectionProof = try values.decodeIfPresent(ConnectionVerificationProof.self, forKey: .connectionProof)
        authorizedHosts = try values.decodeIfPresent(Set<AgentInterface>.self, forKey: .authorizedHosts)
            ?? Self.legacyHosts(interface: interface)
        guard hasValidHostAuthorization else {
            throw DecodingError.dataCorruptedError(forKey: .authorizedHosts, in: values,
                debugDescription: "Host authorization is not valid for this owned registration.")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(provider, forKey: .provider)
        try values.encode(profileID, forKey: .profileID)
        try values.encode(registrationID, forKey: .registrationID)
        try values.encode(executablePath, forKey: .executablePath)
        try values.encode(homePath, forKey: .homePath)
        try values.encode(interface, forKey: .interface)
        try values.encode(collectionInterfaces, forKey: .authorizedHosts)
        try values.encode(version, forKey: .version)
        try values.encodeIfPresent(t3Version, forKey: .t3Version)
        try values.encode(installed, forKey: .installed)
        try values.encodeIfPresent(connectionProof, forKey: .connectionProof)
    }
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
        case .unsupported: "Collection route unavailable"
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

/// The setup assistant: what Spillcheck does, which agents to connect, a test session per agent,
/// alert preferences, then a summary.
enum OnboardingStep: Int, CaseIterable, Comparable {
    case welcome, howItWorks, chooseAgents, connect, preferences, ready

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .howItWorks: "How it works"
        case .chooseAgents: "Choose agents"
        case .connect: "Connect"
        case .preferences: "Preferences"
        case .ready: "Ready"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// General preferences, or one agent's connection and setup.
enum SettingsPage: Hashable {
    case general, agent(AgentProvider)
    var title: String {
        switch self {
        case .general: "General"
        case .agent(let provider): provider.displayName
        }
    }
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
    var conversationCount: Int { Set(occurrences.map(\.conversation.id)).count }
    var agents: [String] { Array(Set(occurrences.map(\.conversation.provider.displayName))).sorted() }
    var strong: Bool { entry.detectorSignal == .strong }
    var acknowledged: Bool { entry.acknowledgement != nil }
    var unlocated: Bool { entry.kind == .unlocatedDetection }
    var decision: ValueDecision? { entry.decision }
    /// Neither decided nor acknowledged rotated or revoked yet.
    var needsReview: Bool { !acknowledged && decision == nil }
    var awaitingRotation: Bool { !acknowledged && decision == .needsRotation }
    /// Decided as needing no action: later appearances stay quiet.
    var dismissed: Bool { !acknowledged && decision?.dismissesValue == true }
    /// A rotated, revoked or decided value whose retained content was removed.
    var nothingKept: Bool { !unlocated && !entry.canRevealRetainedValue && (acknowledged || decision != nil) }
    var latestOccurrence: Date? { occurrences.map(\.observedAt).max() }
    /// The latest appearance. A later one than the user has seen makes the entry unread.
    var latestActivity: Date { latestOccurrence ?? entry.observedAt }
    var bucket: InventoryBucket {
        if acknowledged { return .done }
        if awaitingRotation { return .toRotate }
        return decision == nil ? .toReview : .done
    }

    init(entry: InventoryEntry, occurrences: [InventoryOccurrencePresentation]) {
        self.entry = entry
        self.occurrences = occurrences
        if entry.evidence.isEmpty, let acknowledgement = entry.acknowledgement {
            kind = .remembered(acknowledgement)
        } else if entry.kind == .rememberedDecision {
            kind = .removed
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

/// The Inbox's lists, by what a value still needs: a decision, a rotation, or nothing.
enum InventoryBucket: String, CaseIterable, Identifiable {
    case toReview, toRotate, done
    var id: Self { self }
    /// Names what still has to happen, never a bare verb that reads as if it already did.
    var title: String {
        switch self {
        case .toReview: "To review"
        case .toRotate: "To rotate"
        case .done: "Done"
        }
    }

    init(decision: ValueDecision?) {
        switch decision {
        case nil: self = .toReview
        case .needsRotation?: self = .toRotate
        case _?: self = .done
        }
    }
}

/// When the user last looked at each entry, so later appearances show as unread. Only the entry's
/// app-assigned number and a time leave the vault, never a value, title or path.
struct ReadMarks {
    private static let marksKey = "inventory.readMarks"
    private static let baselineKey = "inventory.readBaseline"
    private let defaults: UserDefaults?
    /// Appearances up to this time count as read, so the backlog that existed before unread marks
    /// doesn't all start out unread.
    let baseline: Date
    private var marks: [Int: Date]

    /// Without `defaults` the marks last only as long as the model, as in sample mode.
    init(defaults: UserDefaults?, now: Date = .now) {
        self.defaults = defaults
        if let stored = defaults?.object(forKey: Self.baselineKey) as? Double {
            baseline = Date(timeIntervalSince1970: stored)
        } else {
            baseline = now
            defaults?.set(now.timeIntervalSince1970, forKey: Self.baselineKey)
        }
        let stored = defaults?.dictionary(forKey: Self.marksKey) as? [String: Double] ?? [:]
        marks = Dictionary(stored.compactMap { key, time in Int(key).map { ($0, Date(timeIntervalSince1970: time)) } },
                           uniquingKeysWith: max)
    }

    func seenThrough(_ label: MaskedValueLabel) -> Date { max(baseline, marks[label.index] ?? baseline) }

    mutating func markSeen(_ label: MaskedValueLabel, through time: Date) {
        guard time > seenThrough(label) else { return }
        marks[label.index] = time
        save()
    }

    /// Entry numbers are never reused, so marks of removed entries can go.
    mutating func keep(only labels: Set<Int>) {
        guard marks.keys.contains(where: { !labels.contains($0) }) else { return }
        marks = marks.filter { labels.contains($0.key) }
        save()
    }

    private func save() {
        defaults?.set(Dictionary(uniqueKeysWithValues: marks.map { (String($0.key), $0.value.timeIntervalSince1970) }),
                      forKey: Self.marksKey)
    }
}

/// Going through values one at a time. The set is fixed when the session starts, so new detections
/// never reshuffle it; `current` is nil once every value in it has left its list.
struct FocusSession: Equatable {
    enum Start { case list, selection, rotationAfterReview }
    let bucket: InventoryBucket
    let ids: [InventoryEntryID]
    let title: String
    var current: InventoryEntryID?
}

/// A host-specific presentation or an aggregate for a profile whose transport
/// does not identify the current producer host.
struct AgentHostRoute: Identifiable {
    let provider: AgentProvider
    let interface: AgentInterface
    let assessments: [CollectionAssessment]
    let limitations: [CoverageGap]
    var lastReadAt: Date? = nil
    var sharedProfile = false
    var partialDesktopSupport = false
    var id: AgentInterface { interface }
    var name: String { sharedProfile ? "Shared profile" : interface.hostLabel }
    var collecting: Bool { assessments.contains { $0.canPerform(.liveRead) } }
    var summary: String {
        var parts = status == .partial ? ["Partial coverage"] : []
        parts += [operationSummary(.liveRead), operationSummary(.historicalRead)]
        if assessments.contains(where: { $0.scope.provider == .codex && $0.scope.path == .hook }) {
            parts.append("Hook collection excludes intermediate replies")
        }
        if sharedProfile { parts.append("Host not identified") }
        if partialDesktopSupport {
            parts.append(provider == .claudeCode ? "Desktop side questions unsupported" : "Automatic side-chat collection unavailable")
        }
        return parts.joined(separator: " · ")
    }
    var acceptanceSummary: String {
        if sharedProfile {
            return "Collection status applies to the shared \(provider.displayName) profile. Its configured route does not identify the app or CLI producing a session. Host-specific acceptance is separate."
        }
        return !assessments.isEmpty && assessments.allSatisfy { $0.acceptanceEvidence == .validated }
            ? "Recorded acceptance is verified for this route and version. Actual coverage is shown separately."
            : "Recorded acceptance is unverified for this route and version. This does not by itself prevent collection."
    }
    private func operationSummary(_ operation: CollectionOperation) -> String {
        let name = operation == .liveRead ? "Live reads" : "Catch-up"
        if operation == .historicalRead, !assessments.isEmpty,
           assessments.allSatisfy({ $0.scope.path == .hook }) {
            return "Hook content has no catch-up"
        }
        let failures = assessments.flatMap(\.failures).filter { $0.operation == operation }
        if assessments.contains(where: { $0.canPerform(operation) }) {
            return failures.isEmpty ? "\(name) available" : "\(name) partially available"
        }
        if !failures.isEmpty {
            return failures.allSatisfy { $0.reason == .transientFailure }
                ? "\(name) waiting to retry" : "\(name) unavailable"
        }
        return operation == .liveRead ? "Awaiting first live read" : "Catch-up not observed yet"
    }
    var status: CollectionCompatibilityStatus {
        if !limitations.isEmpty || assessments.contains(where: { $0.status == .partial }) { return .partial }
        if partialDesktopSupport, assessments.contains(where: { !$0.usableOperations.isEmpty }) { return .partial }
        if sharedProfile, assessments.contains(where: { $0.status == .compatible }),
           assessments.contains(where: { $0.status == .incompatible }) { return .partial }
        if assessments.contains(where: { $0.status == .compatible }) { return .compatible }
        return assessments.contains(where: { $0.status == .incompatible }) ? .incompatible : .unverified
    }
}

/// Shared owned registration with independently assessed, authorized collection transports.
struct AgentRoute: Identifiable {
    let provider: AgentProvider
    let profile: AgentProfileDraft?
    let state: AgentSetupState
    let waitingForEvent: Bool
    var assessment: CollectionAssessment? = nil
    var assessments: [CollectionAssessment] = []
    var limitations: [CoverageGap] = []
    var lastReadDates: [CollectionScope: Date] = [:]
    var monitoringActive = true
    var hostRoutes: [AgentHostRoute] {
        guard let profile, !profile.collectionInterfaces.isEmpty else { return [] }
        // Shared hooks and passive profile history carry a configured transport.
        // Keep distinct scopes for retry/deduplication without assigning a producer host.
        return [AgentHostRoute(provider: provider, interface: profile.interface, assessments: assessments,
            limitations: limitations, lastReadAt: lastReadDates.values.max(), sharedProfile: true,
            partialDesktopSupport: profile.authorizedHosts.contains(.desktopCode))]
    }

    var id: AgentProvider { provider }
    var name: String { provider.displayName }
    var collecting: Bool { monitoringActive && state == .connected && hostRoutes.contains(where: \.collecting) }
    var shownInCoverage: Bool { state != .notDetected && state != .notChecked }
    /// Found on an eligible route with a complete profile, so hooks can be added now.
    var connectable: Bool { state == .detected && profile?.isComplete == true }
    /// Hooks are added, whether or not delivery has been confirmed.
    var hooksAdded: Bool { state == .installedUnverified || state == .connected }
}

/// One terminal line that starts a fresh session of the selected agent with the setup prompt, so the
/// user doesn't have to open /hooks or paste the prompt into a session. The executable is the exact
/// one whose version was checked; a non-default profile is selected through the agent's own variable.
struct SetupCheckCommand {
    let provider: AgentProvider
    let profile: AgentProfileDraft
    let prompt: String

    var line: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let defaultProfile = home + (provider == .codex ? "/.codex" : "/.claude")
        var words: [String] = []
        if URL(fileURLWithPath: profile.homePath).standardizedFileURL.path != defaultProfile {
            words.append((provider == .codex ? "CODEX_HOME=" : "CLAUDE_CONFIG_DIR=") + Self.word(profile.homePath, home: home))
        }
        words.append(Self.word(profile.executablePath, home: home))
        words.append(Self.quote(prompt))
        return words.joined(separator: " ")
    }

    /// A path under the home folder reads as ~/…; anything with shell syntax is quoted instead.
    private static func word(_ path: String, home: String) -> String {
        let short = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        let plain = short.allSatisfy { $0.isLetter || $0.isNumber || "~/._-+".contains($0) }
        return plain ? short : quote(path)
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

@MainActor @Observable
final class AppModel {
    /// Reader observations only. Durable omission limitations are derived in `routes` so a
    /// completed recovery can clear them without requiring another provider batch.
    var collectionAssessments: [CollectionScope: CollectionAssessment] = [:]
    var collectionLimitations: [CoverageGap] = [] { didSet { collectionLimitationsRevision &+= 1 } }
    /// Identifies the limitations for the routes cache. Observed, so a view reading cached routes
    /// still redraws when they change.
    private(set) var collectionLimitationsRevision = 0
    var lastReadDates: [CollectionScope: Date] = [:]
    var lastOperationReads: [CollectionScope: [CollectionOperation: Date]] = [:]
    var coverageReport: CoverageReport? {
        didSet {
            switch (oldValue, coverageReport) {
            case (nil, nil): break
            case let (old?, new?) where old.hasSameRecords(as: new): break
            default: coverageRecordsRevision &+= 1
            }
        }
    }
    /// Identifies the report's records for the coverage caches. Reassigning identical records,
    /// with only a later window end, keeps the revision and the cached rows.
    private(set) var coverageRecordsRevision = 0
    @ObservationIgnored var coverageCache = CoveragePresentationCache()
    var retryingHistory: Set<AgentProvider> = []
    var exportingDiagnostics = false
    @ObservationIgnored var onRetryHistory: ((AgentProvider) -> Void)?
    @ObservationIgnored var onRetrySource: ((CoverageSourceRetryDescriptor) -> Void)?
    @ObservationIgnored var onRetrySources: (([CoverageSourceRetryDescriptor]) -> Void)?
    @ObservationIgnored var onExportDiagnostics: (() -> Void)?
    private(set) var monitoring = MonitoringState()
    @ObservationIgnored var onMonitoringChanged: (() -> Void)?
    @ObservationIgnored var onMonitoringRequested: ((Bool) -> Void)?
    var storageReady = false
    /// Protected storage couldn't open; `storageMessage` says why.
    var storageFailed = false
    var startupFailure: StorageStartupFailure?
    var storageMessage: String? = "Opening protected storage…"
    enum StorageAvailability { case opening, available, failed }
    var storageAvailability: StorageAvailability {
        if isDemo { return .available }
        if storageFailed { return .failed }
        return storageReady ? .available : .opening
    }
    var storageUnavailable: Bool { storageAvailability != .available }
    enum MonitoringIndicator { case unavailable, paused, waiting, active, attention }
    var monitoringIndicator: MonitoringIndicator {
        if storageUnavailable { return .unavailable }
        if !monitoringEnabled { return .paused }
        if coverageNeedsAttention || collectionStorageNeedsAttention { return .attention }
        return monitoringProven || busy || catchingUp ? .active : .waiting
    }
    var liveReadReadinessText: String {
        if storageUnavailable { return "Unavailable" }
        let shown = routes.filter(\.shownInCoverage)
        guard !shown.isEmpty else { return "Nothing connected" }
        return "\(shown.filter(\.collecting).count) of \(shown.count) ready for live reads"
    }
    var canExportStartupDiagnostics: Bool { storageFailed && startupFailure != nil }
    var storageStatusTitle: String? {
        guard storageUnavailable else { return nil }
        return storageFailed ? "Vault unavailable" : "Opening vault"
    }
    var storageSummaryText: String? {
        guard storageUnavailable else { return nil }
        return storageFailed ? "Analysis and inventory are unavailable until the vault opens."
            : "Analysis and inventory will be available after the vault opens."
    }
    var inventoryStatusTitle: String? {
        guard storageUnavailable else { return nil }
        return storageFailed ? "Inventory unavailable" : "Opening inventory"
    }
    var monitoringStatusText: String {
        storageStatusTitle ?? (monitoringEnabled ? "Monitoring on" : (stopped ? "Stopped" : "Paused"))
    }
    var monitoringTransition = false
    private var queueProcessing = false
    private(set) var lastCheckedAt: Date?
    var revealedContent: [UUID: String] = [:]
    var revealedExcerpts: [UUID: RetainedExcerpt] = [:]
    var revealedSourceMetadata: [UUID: RetainedSourceContext] = [:]
    /// The viewing session is authorized: every selection shows its value and context without a prompt.
    var viewingUnlocked = false
    /// Unlocked, but values are hidden until shown again or the session ends. No prompt either way.
    var valuesHidden = false
    /// The selection's protected content is on screen.
    var contentRevealed = false
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
            if selectedEntryID != nil, !multiSelection.isEmpty { multiSelection = [] }
            detailSheet = nil
            selectedOccurrenceID = selectedEntryID.flatMap { defaultOccurrence(for: $0) }
            clearRevealedContent()
            viewingMessage = nil
            revealIssue = nil
            onSelectionChanged?(selectedEntryID)
            markSelectionSeen()
        }
    }
    var selectedOccurrenceID: UUID? {
        didSet {
            guard oldValue != selectedOccurrenceID else { return }
            // A revealed value stays revealed across its appearances; the resume command is per appearance.
            terminalResumeCommand = nil
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
    var route: MainRoute = .inventory {
        didSet { if route == .inventory, oldValue != .inventory { markSelectionSeen() } }
    }
    /// The open list of the Inbox.
    private(set) var bucket: InventoryBucket = .toReview
    /// In memory until `useStoredReadMarks()`; the workflow probe sets its own baseline.
    var readMarks = ReadMarks(defaults: nil)
    /// Unread entries sort first. The set changes when the list reloads, not when an entry is read,
    /// so opening one clears its dot without moving its row.
    @ObservationIgnored private var pinnedUnread: Set<InventoryEntryID> = []
    /// The changes that take back the last decision, for the toast's Undo and Command-Z.
    var undo: [InventoryDecisionChange]?
    /// More than one entry selected with Command or Shift; decisions apply to all of them.
    private(set) var multiSelection: [InventoryEntryID] = []
    @ObservationIgnored private var selectionAnchor: InventoryEntryID?
    private(set) var focus: FocusSession?
    /// The toast on screen reports the decision `undo` takes back.
    var toastOffersUndo = false
    /// The value action sheet belongs to the selected value and closes when the selection changes.
    var detailSheet: DetailSheet?
    var toast: String?
    @ObservationIgnored private var toastToken = UUID()
    private(set) var presentation: InventoryPresentation?
    private(set) var activity: AnalyzedActivity?
    var selectedID: UUID? {
        get { if case .value(let id) = selectedEntryID { id } else { nil } }
        set { selectedEntryID = newValue.map(InventoryEntryID.value) }
    }
    @ObservationIgnored var onSelectionChanged: ((InventoryEntryID?) -> Void)?
    @ObservationIgnored var onOccurrenceSelectionChanged: ((UUID?) -> Void)?
    @ObservationIgnored var onShowValues: (() -> Void)?
    @ObservationIgnored var onHide: (() -> Void)?
    @ObservationIgnored var onUnlock: (() -> Void)?
    @ObservationIgnored var onLock: (() -> Void)?
    /// Applies decisions as one write. `undoing` is true when the changes take back the last ones.
    @ObservationIgnored var onApply: (([InventoryDecisionChange], _ undoing: Bool) -> Void)?
    @ObservationIgnored var onRemoveContent: ((ValueFingerprint) -> Void)?
    @ObservationIgnored var onForgetMarker: ((ValueFingerprint) -> Void)?
    @ObservationIgnored var onOpenSource: ((UUID) -> Void)?
    @ObservationIgnored var onTerminalResume: ((UUID) -> Void)?
    var historyProgress: [StoredHistoricalProgress] = []
    var historicalSummaries: [HistoricalAuditSummary] = []
    var isDemo = false
    var windowVisible = false {
        didSet {
            guard windowVisible, !oldValue else { return }
            refreshPinnedUnread()
            markSelectionSeen()
        }
    }
    /// Agents the user unticked in the setup assistant. Newly detected agents start ticked.
    var setupDeselected: Set<AgentProvider> = []
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
    /// Launch at login needs an installed app; a development build elsewhere can't register.
    var loginAvailable = true
    var loginBusy = false
    var loginMessage: String?
    @ObservationIgnored var onDetectAgents: (() -> Void)?
    @ObservationIgnored var onInstallAgent: ((AgentProvider, AgentProfileDraft) -> Void)?
    /// Adds hooks to several profiles one after another, starting each delivery check.
    @ObservationIgnored var onConnectAgents: (([AgentProfileDraft]) -> Void)?
    @ObservationIgnored var onOpenSetupTerminal: ((AgentProvider) -> Void)?
    @ObservationIgnored var onVerifyAgent: ((AgentProvider) -> Void)?
    @ObservationIgnored var onRepairAgent: ((AgentProvider) -> Void)?
    @ObservationIgnored var onRemoveAgent: ((AgentProvider) -> Void)?
    @ObservationIgnored var onRequestNotificationPermission: (() -> Void)?
    @ObservationIgnored var onLaunchAtLoginRequested: ((Bool) -> Void)?
    @ObservationIgnored var onOpenNotificationSettings: (() -> Void)?
    @ObservationIgnored var onOpenSetup: ((OnboardingStep) -> Void)?
    /// Rereads permissions that only System Settings changes.
    @ObservationIgnored var onRefreshPreferences: (() -> Void)?
    @ObservationIgnored var onQuit: (() -> Void)?
    var monitoringEnabled: Bool { monitoring.runState == .running && monitoring.mode == .enabled }
    var stopped: Bool { monitoring.runState == .stopped }
    /// The pipeline's instantaneous state. It changes many times a second while a session is active,
    /// so displays use `busy` and `catchingUp` instead.
    var processing: Bool {
        if case .processing = monitoring.queueActivity { true } else { false }
    }
    var status: String {
        if let storageStatusTitle { return storageStatusTitle }
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

    /// A bucket's entries that match the filters: unread first, then by the chosen order.
    func entries(in bucket: InventoryBucket) -> [EntrySummary] {
        summaries.filter { summary in
            summary.bucket == bucket
                && (agentFilter == nil || summary.occurrences.contains { $0.conversation.provider == agentFilter })
                && summary.matches(search: searchText)
        }
        .sorted { left, right in
            let leftPinned = pinnedUnread.contains(left.id), rightPinned = pinnedUnread.contains(right.id)
            if leftPinned != rightPinned { return leftPinned }
            if sortOrder == .confidence, left.strong != right.strong { return left.strong }
            return left.latestActivity > right.latestActivity
        }
    }

    /// The open list, which arrow keys follow.
    var bucketEntries: [EntrySummary] { entries(in: bucket) }

    /// Every entry per bucket, regardless of filters.
    var bucketCounts: [InventoryBucket: Int] { Dictionary(grouping: summaries, by: \.bucket).mapValues(\.count) }

    func hasUnread(in bucket: InventoryBucket) -> Bool {
        summaries.contains { $0.bucket == bucket && isUnread($0) }
    }

    /// An entry still to review or rotate with an appearance newer than the user has seen. A decided
    /// value only counts its new appearances.
    func isUnread(_ summary: EntrySummary) -> Bool {
        guard summary.bucket != .done, let label = summary.entry.label else { return false }
        return summary.latestActivity > readMarks.seenThrough(label)
    }

    func selectBucket(_ bucket: InventoryBucket) {
        if route != .inventory { route = .inventory }
        guard self.bucket != bucket else { return }
        self.bucket = bucket
        multiSelection = []
        refreshPinnedUnread()
        selectedEntryID = bucketEntries.first?.id
    }

    /// Stored marks survive restarts. Sample mode and tests keep them in memory.
    func useStoredReadMarks(_ defaults: UserDefaults = .standard) {
        readMarks = ReadMarks(defaults: defaults)
        refreshPinnedUnread()
    }

    /// What's on screen counts as read: the selected entry, while the window shows the inventory.
    private func markSelectionSeen() {
        guard windowVisible, route == .inventory, let summary = selectedSummary,
              let label = summary.entry.label, summary.latestActivity > readMarks.seenThrough(label) else { return }
        readMarks.markSeen(label, through: summary.latestActivity)
    }

    private func refreshPinnedUnread() {
        pinnedUnread = Set(summaries.filter(isUnread).map(\.id))
    }

    /// Records one decision for every given value. Values that leave their list make way for the
    /// next one, like an inbox; in Focus, the next value still to do opens.
    func decide(_ summaries: [EntrySummary], as decision: ValueDecision?) {
        let changes = summaries.compactMap { summary -> InventoryDecisionChange? in
            if case .unlocated(let resultID) = summary.id { return .decideUnlocated(resultID, decision) }
            return summary.entry.fingerprint.map { .decide($0, decision) }
        }
        let leaving = summaries.filter { InventoryBucket(decision: decision) != $0.bucket }.map(\.id)
        apply(changes, leaving: leaving)
    }

    func decide(_ summary: EntrySummary, as decision: ValueDecision?) { decide([summary], as: decision) }

    /// Records that values were rotated or revoked at their service. They move to Done.
    func acknowledge(_ summaries: [EntrySummary], as acknowledgement: ObsoleteAcknowledgement) {
        let eligible = summaries.filter { !$0.acknowledged && !$0.unlocated && $0.entry.fingerprint != nil }
        apply(eligible.compactMap { $0.entry.fingerprint.map { .acknowledge($0, acknowledgement) } },
              leaving: eligible.filter { $0.bucket != .done }.map(\.id))
    }

    func acknowledge(_ summary: EntrySummary, as acknowledgement: ObsoleteAcknowledgement) {
        acknowledge([summary], as: acknowledgement)
    }

    private func apply(_ changes: [InventoryDecisionChange], leaving: [InventoryEntryID]) {
        guard !changes.isEmpty else { return }
        let leaving = Set(leaving)
        let next = nextEntry(leaving: leaving)
        onApply?(changes, false)
        guard !leaving.isEmpty else { return }
        if focus != nil {
            advanceFocus(leaving: leaving)
        } else if !multiSelection.isEmpty || selectedEntryID.map(leaving.contains) == true {
            multiSelection = []
            selectedEntryID = next
        }
    }

    /// The entry after the first one leaving the open list, or the closest one before it.
    private func nextEntry(leaving: Set<InventoryEntryID>) -> InventoryEntryID? {
        let list = bucketEntries.map(\.id)
        guard let first = list.firstIndex(where: leaving.contains) else { return nil }
        let rest = list.enumerated().filter { !leaving.contains($0.element) }
        return (rest.first { $0.offset > first } ?? rest.last { $0.offset < first })?.element
    }

    /// T, N and R decide what's selected to review; D marks what's selected to rotate as rotated.
    func decide(byKey key: String) -> Bool {
        let targets = multiSelection.isEmpty ? (selectedSummary.map { [$0] } ?? []) : selectedSummaries
        guard let bucket = targets.first?.bucket, route == .inventory, storageReady, !isDemo, !actionBusy else { return false }
        switch (bucket, key) {
        case (.toReview, "t"): decide(targets, as: .testOrDevelopment)
        case (.toReview, "n"): decide(targets, as: .notSecret)
        case (.toReview, "r"): decide(targets, as: .needsRotation)
        case (.toRotate, "d"):
            guard targets.contains(where: { !$0.unlocated && $0.entry.fingerprint != nil }) else { return false }
            acknowledge(targets, as: .rotated)
        default: return false
        }
        return true
    }

    /// Takes back the last decision.
    func undoLastDecision() {
        guard let undo, storageReady, !isDemo, !actionBusy else { return }
        self.undo = nil
        toastOffersUndo = false
        toast = nil
        onApply?(undo, true)
    }

    /// After an undo, the value is selected again: in its session during Focus, otherwise in the list
    /// it returned to.
    func reselect(_ changes: [InventoryDecisionChange]) {
        let id = changes.lazy.compactMap { change -> InventoryEntryID? in
            switch change {
            case .decide(let fingerprint, _), .acknowledge(let fingerprint, _), .forgetMarker(let fingerprint):
                self.summaries.first { $0.entry.fingerprint == fingerprint }?.id
            case .decideUnlocated(let resultID, _): .unlocated(resultID)
            }
        }.first
        guard let id, let summary = summaries.first(where: { $0.id == id }) else { return }
        if var session = focus {
            guard session.ids.contains(id) else { return }
            session.current = id
            focus = session
            selectedEntryID = id
            return
        }
        if route != .inventory { route = .inventory }
        bucket = summary.bucket
        multiSelection = []
        refreshPinnedUnread()
        selectedEntryID = summary.id
    }

    // MARK: Selection

    enum SelectionGesture { case single, toggle, range }

    /// The selected entries, in list order. More than one only after Command- or Shift-clicking.
    var selectedSummaries: [EntrySummary] {
        let ids = Set(multiSelection)
        return bucketEntries.filter { ids.contains($0.id) }
    }

    func isSelected(_ id: InventoryEntryID) -> Bool {
        multiSelection.isEmpty ? selectedEntryID == id : multiSelection.contains(id)
    }

    /// A click selects one entry; with Command it adds or removes one, with Shift it selects a range.
    func select(_ id: InventoryEntryID, gesture: SelectionGesture) {
        switch gesture {
        case .single:
            multiSelection = []
            selectionAnchor = id
            selectEntry(id)
        case .toggle:
            var ids = multiSelection.isEmpty ? (selectedEntryID.map { [$0] } ?? []) : multiSelection
            if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
            selectionAnchor = id
            setSelection(ids)
        case .range:
            let list = bucketEntries.map(\.id)
            guard let anchor = selectionAnchor ?? selectedEntryID,
                  let from = list.firstIndex(of: anchor), let to = list.firstIndex(of: id) else {
                return select(id, gesture: .single)
            }
            setSelection(Array(list[min(from, to)...max(from, to)]))
        }
    }

    private func setSelection(_ ids: [InventoryEntryID]) {
        guard ids.count > 1 else {
            multiSelection = []
            if let id = ids.first { selectEntry(id) }
            return
        }
        // The detail lists the selection, so no single entry is on screen.
        selectedEntryID = nil
        multiSelection = ids
    }

    // MARK: Focus

    /// Goes through values one at a time: the open list from the top, the selection, or after a
    /// review session, the values it sent to To rotate.
    func startFocus(_ start: FocusSession.Start) {
        let bucket: InventoryBucket = start == .rotationAfterReview ? .toRotate : self.bucket
        guard bucket != .done else { return }
        let ids: [InventoryEntryID]
        switch start {
        case .list: ids = bucketEntries.map(\.id)
        case .selection: ids = selectedSummaries.map(\.id)
        case .rotationAfterReview:
            let toRotate = Set(summaries.filter { $0.bucket == .toRotate }.map(\.id))
            ids = (focus?.ids ?? []).filter(toRotate.contains)
        }
        guard let first = ids.first else { return }
        let noun = start == .selection ? "selected value" : "value"
        if self.bucket != bucket { self.bucket = bucket }
        multiSelection = []
        refreshPinnedUnread()
        focus = FocusSession(bucket: bucket, ids: ids, title: "\(plural(ids.count, noun)) to \(bucket == .toRotate ? "rotate" : "review")",
                             current: first)
        selectedEntryID = first
    }

    /// Back to the Inbox, on the value that was on screen when it's still in the list.
    func exitFocus() {
        guard let session = focus else { return }
        focus = nil
        bucket = session.bucket
        refreshPinnedUnread()
        let list = bucketEntries.map(\.id)
        selectedEntryID = session.current.flatMap { list.contains($0) ? $0 : nil }
            ?? pending(in: session).first.flatMap { list.contains($0) ? $0 : nil } ?? list.first
    }

    func moveFocus(by offset: Int) {
        guard var session = focus, !session.ids.isEmpty else { return }
        let index = session.current.flatMap { session.ids.firstIndex(of: $0) } ?? session.ids.count
        let next = session.ids[max(0, min(session.ids.count - 1, index + offset))]
        session.current = next
        focus = session
        selectedEntryID = next
    }

    /// The session's values still in its list.
    func pending(in session: FocusSession) -> [InventoryEntryID] {
        let open = Set(summaries.filter { $0.bucket == session.bucket }.map(\.id))
        return session.ids.filter(open.contains)
    }

    /// What became of each value of a session, for its summary.
    func outcomes(of session: FocusSession) -> [(label: String, count: Int)] {
        let byID = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var counts: [String: Int] = [:]
        var order: [String] = []
        for id in session.ids {
            let summary = byID[id]
            let label = summary?.entry.acknowledgement?.rawValue
                ?? summary?.decision.map { $0 == .needsRotation ? "to rotate" : $0.displayName.lowercased() }
                ?? (summary == nil ? "removed" : "still to review")
            if counts[label] == nil { order.append(label) }
            counts[label, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    /// A value left the session's list: the next one still to do opens, or the summary when none is left.
    private func advanceFocus(leaving: Set<InventoryEntryID>) {
        guard var session = focus, let current = session.current, leaving.contains(current) else { return }
        let open = pending(in: session).filter { !leaving.contains($0) }
        let at = session.ids.firstIndex(of: current) ?? 0
        session.current = open.first { (session.ids.firstIndex(of: $0) ?? 0) > at } ?? open.first
        focus = session
        selectedEntryID = session.current
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
        let entries = bucketEntries
        guard !entries.isEmpty else { return }
        multiSelection = []
        let index = entries.firstIndex { $0.id == selectedEntryID } ?? (offset > 0 ? -1 : entries.count)
        let next = entries[max(0, min(entries.count - 1, index + offset))]
        if next.id != selectedEntryID { selectedEntryID = next.id }
    }

    /// Selects an entry in the list it belongs to.
    func selectEntry(_ id: InventoryEntryID) {
        if route != .inventory { route = .inventory }
        if let summary = summaries.first(where: { $0.id == id }), summary.bucket != bucket {
            bucket = summary.bucket
            refreshPinnedUnread()
        }
        selectedEntryID = id
    }

    func clearFilters() {
        searchText = ""
        agentFilter = nil
    }

    private func defaultOccurrence(for id: InventoryEntryID) -> UUID? {
        presentation?.occurrences(for: id).first?.id
    }

    private func keepSelectionVisible() {
        guard route == .inventory, focus == nil else { return }
        let entries = bucketEntries
        if !multiSelection.isEmpty {
            let visible = Set(entries.map(\.id))
            let kept = multiSelection.filter(visible.contains)
            if kept.count > 1 { multiSelection = kept; return }
            multiSelection = []
            selectedEntryID = kept.first ?? entries.first?.id
            return
        }
        if let selectedEntryID, entries.contains(where: { $0.id == selectedEntryID }) { return }
        selectedEntryID = entries.first?.id
    }

    // MARK: Monitoring and coverage

    /// Views read this several times per redraw, and building it filters every current limitation
    /// for each agent and interface, so it is rebuilt only when one of its inputs changes.
    var routes: [AgentRoute] {
        let inputs = CoveragePresentationCache.RouteInputs(setupStates: agentSetupStates, profiles: agentProfiles,
            awaitingVerification: Set(verificationPrompts.keys), assessments: collectionAssessments,
            limitationsRevision: collectionLimitationsRevision, lastReadDates: lastReadDates,
            monitoringActive: monitoringEnabled)
        if let cached = coverageCache.routes, cached.inputs == inputs { return cached.value }
        let routes = buildRoutes()
        coverageCache.routes = (inputs, routes)
        return routes
    }

    private func buildRoutes() -> [AgentRoute] {
        AgentProvider.allCases.map { provider in
            let state = agentSetupStates[provider] ?? .notChecked
            let profile = agentProfiles[provider]
            let assessments = collectionAssessments.values.filter {
                guard $0.scope.provider == provider else { return false }
                guard let profile else { return true }
                return $0.scope.profileID == profile.profileID && profile.authorizedHosts.contains($0.scope.interface)
            }.map(assessmentWithCurrentLimitations)
            let assessment = assessments.first(where: { $0.canPerform(.liveRead) }) ?? assessments.first
            return AgentRoute(provider: provider, profile: agentProfiles[provider], state: state,
                              waitingForEvent: state == .installedUnverified && verificationPrompts[provider] != nil,
                              assessment: assessment, assessments: assessments.sorted {
                                  $0.scope.interface.rawValue < $1.scope.interface.rawValue
                              }, limitations: collectionLimitations.filter {
                                  $0.scope?.provider == provider && $0.scope?.profileID == profile?.profileID
                              }, lastReadDates: lastReadDates.filter {
                                  $0.key.provider == provider && $0.key.profileID == profile?.profileID
                              }, monitoringActive: monitoringEnabled)
        }
    }

    private func assessmentWithCurrentLimitations(_ assessment: CollectionAssessment) -> CollectionAssessment {
        let required = collectionLimitations.filter {
            $0.scope == assessment.scope && $0.isRequiredFormatFailure == true
                && ($0.contentType != nil || $0.recovery != nil
                    || ($0.operation.map { operation in
                        !assessment.canPerform(operation) || assessment.failures.contains { $0.operation == operation }
                    } ?? true))
        }
        return CollectionAssessment(scope: assessment.scope,
            observedExecutableVersion: assessment.observedExecutableVersion, format: assessment.format,
            usableOperations: assessment.usableOperations,
            unavailableContent: assessment.unavailableContent.union(required.compactMap(\.contentType)),
            failures: assessment.failures + required.map {
                .init(reason: $0.operation == nil ? .changedContentFormat : .sourceUnavailable,
                      operation: $0.operation, contentType: $0.contentType)
            }, acceptanceEvidence: assessment.acceptanceEvidence)
    }

    /// A remembered connection proof is separate from recent collection and analyzed coverage.
    var monitoringProven: Bool { routes.contains(where: \.collecting) }
    /// The agent page opened from elsewhere: the first found agent that isn't collecting, else the first found.
    var agentsPage: SettingsPage {
        let found = routes.filter(\.shownInCoverage)
        return .agent((found.first { !$0.collecting } ?? found.first)?.provider ?? .codex)
    }

    var hasAnalyzedContent: Bool { (activity?.messageCount ?? 0) > 0 }

    /// Retained analysis stays visible before this process observes another live read.
    var coverageSummaryText: String {
        if let storageSummaryText { return storageSummaryText }
        if hasAnalyzedContent || monitoringProven {
            let window = activity?.window ?? AnalyzedActivity.recentWindow(endingAt: .now)
            return "\(plural(activity?.messageCount ?? 0, "message")) analyzed · \(DisplayTime.day(window.start)) – \(DisplayTime.day(window.end))"
        }
        return routes.contains { $0.state == .connected }
            ? "Registration verified · waiting for content"
            : "Verify an agent to start monitoring"
    }

    /// Opens the setup assistant at `step`, or where the user still has something to do: confirming
    /// hooks that are already added, otherwise choosing agents.
    func openSetup(at step: OnboardingStep? = nil) {
        onOpenSetup?(step ?? (routes.contains { $0.state == .installedUnverified } ? .connect : .chooseAgents))
    }

    /// Leaves the setup assistant for the main window, which shows coverage until something is found.
    func finishSetup() {
        route = .inventory
        if selectedEntryID == nil { selectedEntryID = bucketEntries.first?.id }
    }

    /// Agents ticked for connection in the setup assistant.
    var setupSelection: [AgentRoute] {
        routes.filter { $0.connectable && !setupDeselected.contains($0.provider) }
    }

    /// Adds hooks to the ticked agents one after another, each followed by its delivery check.
    /// Returns the agents being connected.
    @discardableResult
    func connectSelectedAgents() -> Set<AgentProvider> {
        let drafts = setupSelection.compactMap(\.profile)
        guard !drafts.isEmpty else { return [] }
        if isDemo { DemoInventory.simulateConnection(self, providers: drafts.map(\.provider)) }
        else { onConnectAgents?(drafts) }
        return Set(drafts.map(\.provider))
    }

    func setupCommand(for provider: AgentProvider) -> SetupCheckCommand? {
        guard let profile = agentProfiles[provider], let prompt = verificationPrompts[provider],
              !profile.executablePath.isEmpty else { return nil }
        return SetupCheckCommand(provider: provider, profile: profile, prompt: prompt)
    }

    var coverageWord: String {
        if storageUnavailable { return storageFailed ? "Unavailable" : "Opening" }
        return switch monitoring.coverage {
        case .notConfigured: "Not proven"
        case .complete: monitoringProven ? "No recent gaps" : "Not proven"
        case .partial: "Partial"
        }
    }

    var coverageStateText: String {
        if storageUnavailable { return storageFailed ? "Coverage unavailable" : "Opening protected storage" }
        return switch monitoring.coverage {
        case .notConfigured: "Coverage not proven"
        case .complete: monitoringProven ? "No recent gaps" : "Coverage not proven"
        case .partial: "Partial coverage"
        }
    }

    nonisolated static func gapText(_ reason: CoverageGapReason) -> String {
        switch reason {
        case .unsupportedContent: "Some content wasn’t in a supported format, so it wasn’t analyzed."
        case .unsupportedVersion: "An earlier collector rejected a source version. Recovery requires available original content."
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
        if let storageStatusTitle { return storageStatusTitle }
        if stopped { return "Monitoring stopped" }
        if !monitoringEnabled { return "Not checking while paused" }
        if catchingUp { return "Reading recent history" }
        if busy { return "Analyzing new content" }
        if coverageNeedsAttention { return "Idle · coverage needs attention" }
        if !monitoringProven { return "Waiting for agent content" }
        return lastCheckedAt.map { "Idle · last analyzed \($0.formatted(date: .omitted, time: .shortened))" } ?? "Waiting for agent content"
    }

    var processingShort: String {
        if storageUnavailable { return storageFailed ? "Unavailable" : "Opening" }
        if !monitoringEnabled { return "Not checking" }
        if catchingUp { return "Catching up" }
        if busy { return "Analyzing" }
        return monitoringProven || hasAnalyzedContent ? "Idle" : "Waiting"
    }

    // MARK: Settled activity

    /// Shown activity changes only after the pipeline has worked for `busyDelay`, and returns to idle
    /// only after `idleDelay` without work. A burst of short items reads as one steady state.
    private(set) var busy = false
    /// While recent-history work is queued. Live activity alone never counts as catching up.
    private(set) var catchingUp = false
    /// The agents whose recent-history work is queued, so each row shows its own catch-up.
    private(set) var catchingUpProviders: Set<AgentProvider> = []
    @ObservationIgnored private var burstStart: Date?
    @ObservationIgnored private var lastActiveAt: Date?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    static let busyDelay: TimeInterval = 1
    static let idleDelay: TimeInterval = 2

    func beginCatchUp(_ providers: Set<AgentProvider> = []) {
        if !catchingUp { catchingUp = true }
        if !providers.isSubset(of: catchingUpProviders) { catchingUpProviders.formUnion(providers) }
        settleActivity(active: true)
    }

    /// The store's count of queued recent-history work, which ends a catch-up when it reaches zero,
    /// and the agents that work belongs to.
    func updateHistoryWork(queued: Int, providers: Set<AgentProvider> = []) {
        if catchingUp != (queued > 0) { catchingUp = queued > 0 }
        let reading = queued > 0 ? providers : []
        if catchingUpProviders != reading { catchingUpProviders = reading }
    }

    private func settleActivity(active: Bool, now: Date = Date()) {
        if let last = lastActiveAt, now.timeIntervalSince(last) >= Self.idleDelay { burstStart = nil }
        if active {
            burstStart = burstStart ?? now
            lastActiveAt = now
        }
        let recent = lastActiveAt.map { now.timeIntervalSince($0) < Self.idleDelay } ?? false
        // A single short item never counts: work must still be observed busyDelay after the burst began.
        let lasting = burstStart.flatMap { start in lastActiveAt.map { $0.timeIntervalSince(start) >= Self.busyDelay } } ?? false
        let nextBusy = recent && (busy || lasting)
        if busy != nextBusy { busy = nextBusy }
        settleTask?.cancel()
        guard recent, let lastActiveAt else { return }
        // Re-evaluate when the burst is long enough to show, or when it has been quiet long enough.
        let showAt = busy ? nil : burstStart.map { $0.addingTimeInterval(Self.busyDelay) }
        let quietAt = lastActiveAt.addingTimeInterval(Self.idleDelay)
        let next = [showAt, quietAt].compactMap { $0 }.filter { $0 > now }.min() ?? quietAt
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSince(Date()))))
            guard !Task.isCancelled, let self else { return }
            self.settleActivity(active: self.queueActive)
        }
    }

    var lastCatchUp: Date? { historyProgress.compactMap(\.completedAt).max() }
    var lastCatchUpAttempt: Date? { historyProgress.compactMap(\.lastAttemptedAt).max() }

    // MARK: Toasts

    func showToast(_ message: String, offeringUndo: Bool = false) {
        let token = UUID()
        toastToken = token
        toast = message
        toastOffersUndo = offeringUndo && undo != nil
        Task { @MainActor [weak self] in
            // A toast that can be undone stays a little longer.
            try? await Task.sleep(for: .seconds(offeringUndo ? 6 : 4.2))
            guard let self, self.toastToken == token else { return }
            self.toast = nil
            self.toastOffersUndo = false
        }
    }

    /// Reports a decision that Undo can take back.
    func offerUndo(_ undo: [InventoryDecisionChange], message: String) {
        self.undo = undo
        showToast(message, offeringUndo: true)
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
        // The last four hours count as new, so the sample shows unread values.
        readMarks = ReadMarks(defaults: nil, now: .now.addingTimeInterval(-4 * 3600))
        refreshPinnedUnread()
        selectedEntryID = bucketEntries.first?.id
        actionMessage = "Sample mode. Revealing and changing values are disabled."
    }

    /// Sample mode as if unlocked, for design review. The content is synthetic: nothing is decrypted.
    func showDemoContent() {
        guard isDemo, let summary = selectedSummary else { return }
        let value = "sample-value-not-a-secret"
        viewingUnlocked = true
        contentRevealed = true
        if let valueID = summary.entry.valueID { revealedContent[valueID] = value }
        if let occurrence = selectedOccurrenceID {
            revealedExcerpts[occurrence] = RetainedExcerpt(
                text: "NODE_ENV=development\nAPI_TOKEN=\(value)\nLOG_LEVEL=debug", clipped: true)
            revealedSourceMetadata[occurrence] = RetainedSourceContext(
                sessionIdentifier: "sample", title: "Fix the flaky deploy script", projectPath: "~/dev/sample-app",
                toolCall: RetainedToolCall(tool: "exec_command", program: "cat", paths: ["~/dev/sample-app/.env.local"]))
        }
    }

    /// Sample setup-assistant state matching a first launch: Codex found, Claude Code at an untested
    /// version. Nothing is installed and no session is started.
    func loadSetupDemo(step: OnboardingStep) {
        isDemo = true
        storageReady = true
        storageMessage = nil
        presentation = try? InventoryPresentation(snapshot: InventorySnapshot())
        DemoInventory.configureSetup(self, step: step)
    }

    /// Sample connected monitoring that has analyzed content and found nothing.
    func loadQuietDemo() {
        isDemo = true
        storageMessage = nil
        if let snapshot = try? DemoInventory.quietSnapshot() {
            presentation = try? InventoryPresentation(snapshot: snapshot)
            activity = AnalyzedActivity(snapshot: snapshot, window: AnalyzedActivity.recentWindow(endingAt: .now))
        }
        DemoInventory.configureSetup(self, step: .ready)
        updateCoverage(.partial([CoverageGap(reason: .queueExpired)]))
        route = .inventory
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
        let activity: QueueActivity = queueProcessing ? .processing(pendingCount: UInt(count), activeCount: 1)
            : count == 0 ? .idle : .waiting(itemCount: UInt(count))
        // Assigning an unchanged state would still invalidate every view that reads monitoring.
        if monitoring.queueActivity != activity { monitoring.updateQueueActivity(activity) }
        queueActive = queueProcessing || count > 0
        if !queueActive {
            // The display shows minutes, so record the check once per minute.
            let minute = Calendar.current.dateInterval(of: .minute, for: .now)?.start ?? .now
            if lastCheckedAt != minute { lastCheckedAt = minute }
        }
        settleActivity(active: queueActive)
    }
    @ObservationIgnored private var queueActive = false
    func updatePipeline(_ activity: PipelineActivity) {
        // Called twice per capture; an unchanged write would still invalidate its readers.
        if queueProcessing != activity.processing { queueProcessing = activity.processing }
        updateQueue(count: activity.pendingCount)
    }
    func updateCoverage(_ status: CoverageStatus) {
        if monitoring.coverage != status { monitoring.updateCoverage(status) }
    }
    func clearRevealedContent() {
        revealedContent.removeAll()
        revealedExcerpts.removeAll()
        revealedSourceMetadata.removeAll()
        terminalResumeCommand = nil
        contentRevealed = false
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
        // New unread entries join the top of the list; entries read since keep their place.
        pinnedUnread.formUnion(summaries.filter(isUnread).map(\.id))
        readMarks.keep(only: Set(next.entries().compactMap { $0.label?.index }))
        if !multiSelection.isEmpty { keepSelectionVisible() }
        if selectedEntryID == nil, multiSelection.isEmpty, focus == nil { selectedEntryID = bucketEntries.first?.id }
        markSelectionSeen()
    }

    /// Opens a value from a notification, in the list it belongs to. It leaves Focus, whose set is fixed.
    func selectValue(_ id: UUID) {
        if focus != nil { exitFocus() }
        agentFilter = nil
        searchText = ""
        selectEntry(.value(id))
    }

    /// Hides values, and keeps them hidden across selections, without locking.
    func hideValues() {
        valuesHidden = true
        clearRevealedContent()
        revealIssue = nil
        onHide?()
    }

    /// Shows values again. Unlocked, so there's no prompt.
    func showValues() {
        valuesHidden = false
        onShowValues?()
    }

    /// The one way to protected content: unlock when locked, or show hidden values.
    func unlockOrShowValues() {
        if viewingUnlocked { showValues() } else { onUnlock?() }
    }

    func lockNow() {
        clearRevealedContent()
        revealIssue = nil
        onLock?()
    }

    func stop() {
        monitoring.stop()
    }
}

/// Masked-only preview state with synthetic labels. No payload is written to the production vault.
/// Synthetic sample data for sample mode and the workflow probe.
enum DemoInventory {
    static func presentation() throws -> InventoryPresentation { try InventoryPresentation(snapshot: snapshot()) }

    private static func record(_ provider: AgentProvider, _ session: String, _ item: String, _ type: ContentType,
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

    /// Analyzed Codex content without detections, for the empty-inventory overview.
    static func quietSnapshot() throws -> InventorySnapshot {
        var ledger = InventoryLedger()
        let now = Date()
        for (index, type) in [ContentType.userPrompt, .toolOutput, .finalResponse].enumerated() {
            _ = try ledger.ingest(SourceAnalysis(source: record(.codex, "q1", "q1-\(index)", type, .standaloneCLI,
                at: now.addingTimeInterval(-Double(600 - index * 60))), detectorVersion: "sample", detections: []))
        }
        return ledger.snapshot
    }

    static func snapshot() throws -> InventorySnapshot {
        var ledger = InventoryLedger()
        let now = Date()
        let day: TimeInterval = 86_400
        @discardableResult
        func add(_ value: UInt8, rule: String, _ category: SecretCategory, _ signal: SignalStrength,
                 _ provider: AgentProvider, _ session: String, _ item: String, _ type: ContentType = .toolOutput,
                 _ interface: AgentInterface = .standaloneCLI, ago: TimeInterval) throws -> InventoryTransition {
            let source = try record(provider, session, item, type, interface, at: now.addingTimeInterval(-ago))
            let bytes = source.segments[0].utf8
            let location = try CanonicalLocation(segmentID: "body", range: UTF8Range(0, bytes.count))
            // The reasons the scanner mapping gives these rules.
            let reason: DetectionReason = switch rule {
            case "generic-api-key": .credentialField
            case "postgres-credential-uri": .connectionString
            default: .recognizedFormat
            }
            let evidence = DetectionEvidence(rule: try RuleIdentity(id: rule, version: "sample"), signal: signal,
                reason: reason, category: category)
            let detection = try LocatedDetection(extraction: ExactExtraction(valueUTF8: bytes, location: location, in: source),
                in: source, fingerprint: ValueFingerprint(keyedDigest: Data(repeating: value, count: 32)), evidence: [evidence],
                protectedValue: ProtectedPayloadReference(), protectedExcerpt: ProtectedPayloadReference())
            return try ledger.ingest(SourceAnalysis(source: source, detectorVersion: "sample", detections: [detection]))
        }
        func deliver(_ transition: InventoryTransition) throws {
            for alert in transition.alerts { try ledger.recordAlertDelivery(alert.id, state: .delivered) }
        }
        // Stripe key, acknowledged as rotated.
        try add(4, rule: "stripe-access-token", .apiKey, .strong, .claudeCode, "s1", "s1a", .toolOutput, .t3, ago: 6 * day)
        try add(4, rule: "stripe-access-token", .apiKey, .strong, .claudeCode, "s1", "s1b", .finalResponse, .t3, ago: 6 * day - 60)
        // An old AWS key: revoked, removed, then seen again as an obsolete appearance.
        try add(5, rule: "aws-access-token", .apiKey, .strong, .codex, "s12", "s12old", .toolOutput, .t3, ago: 2 * day)
        // OpenAI key the user still has to rotate.
        try deliver(try add(2, rule: "openai-api-key", .apiKey, .strong, .codex, "s2", "s2a", .userPrompt, ago: 3 * day))
        try add(2, rule: "openai-api-key", .apiKey, .strong, .codex, "s2", "s2b", .finalResponse, ago: 3 * day - 60)
        // A generic value the user decided isn't a secret.
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

        try ledger.decide(ValueFingerprint(keyedDigest: Data(repeating: 2, count: 32)), as: .needsRotation,
                          at: now.addingTimeInterval(-2 * day))
        try ledger.decide(ValueFingerprint(keyedDigest: Data(repeating: 8, count: 32)), as: .notSecret,
                          at: now.addingTimeInterval(-3 * day))
        let stripe = try ValueFingerprint(keyedDigest: Data(repeating: 4, count: 32))
        let oldAWS = try ValueFingerprint(keyedDigest: Data(repeating: 5, count: 32))
        try ledger.acknowledgeObsolete(stripe, as: .rotated, at: now.addingTimeInterval(-5 * day))
        try ledger.acknowledgeObsolete(oldAWS, as: .revoked, at: now.addingTimeInterval(-2 * day + 3600))
        _ = try ledger.removeContent(for: oldAWS)
        try add(5, rule: "aws-access-token", .apiKey, .strong, .codex, "s12", "s12again", .toolOutput, .t3, ago: day + 3600)
        return ledger.snapshot
    }

    @MainActor static func configureSetup(_ model: AppModel, step: OnboardingStep) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let codex = AgentProfileDraft(provider: .codex, profileID: "sample", executablePath: home + "/.local/bin/codex",
                                      homePath: home + "/.codex", version: CodexAdapter.validatedAgentVersion,
                                      installed: step >= .connect)
        let claude = AgentProfileDraft(provider: .claudeCode, profileID: "sample", executablePath: home + "/.local/bin/claude",
                                       homePath: home + "/.claude", interface: .desktopCode, version: "2.1.295")
        model.agentProfiles = [.codex: codex, .claudeCode: claude]
        let codexState: AgentSetupState = switch step {
        case .welcome, .howItWorks, .chooseAgents: .detected
        case .connect: .installedUnverified
        case .preferences, .ready: .connected
        }
        model.agentSetupStates = [.codex: codexState, .claudeCode: .unsupported]
        model.agentSetupMessages = [.claudeCode: claude.unsupportedMessage]
        model.verificationPrompts = step == .connect ? [.codex: SetupVerificationPrompt.make()] : [:]
        model.notificationState = .notRequested
        model.updateCoverage(.complete)
    }

    /// Plays a connection in sample mode: hooks are added, then the test prompt "arrives" a few
    /// seconds later. Nothing is written to any agent profile.
    @MainActor static func simulateConnection(_ model: AppModel, providers: [AgentProvider]) {
        Task { @MainActor [weak model] in
            for provider in providers {
                guard let model else { return }
                model.agentSetupBusy.insert(provider)
                try? await Task.sleep(for: .seconds(1.4))
                model.agentProfiles[provider]?.installed = true
                model.agentSetupStates[provider] = .installedUnverified
                model.verificationPrompts[provider] = SetupVerificationPrompt.make()
                model.agentSetupBusy.remove(provider)
            }
            try? await Task.sleep(for: .seconds(4))
            for provider in providers {
                model?.verificationPrompts.removeValue(forKey: provider)
                model?.agentSetupStates[provider] = .connected
            }
        }
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
