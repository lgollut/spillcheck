import AppKit
import Security
import UniformTypeIdentifiers
#if DEBUG
@_spi(Testing) import SpillcheckCore
#else
import SpillcheckCore
#endif

private actor CaptureAdmission {
    private var scope: LiveCaptureScope?
    private var routes: [CaptureMetadata: CollectionCaptureRoute] = [:]
    private var codexRouters: [CaptureMetadata: CodexEnrolledSessionRouter] = [:]
    private var routeGeneration = UUID()
    func update(_ scope: LiveCaptureScope) { self.scope = scope }
    func currentScope() -> LiveCaptureScope? { scope }
    func allow(_ routes: [CaptureMetadata: CollectionCaptureRoute],
               codexRouters: [CaptureMetadata: CodexEnrolledSessionRouter] = [:]) {
        routeGeneration = UUID()
        self.routes = routes; self.codexRouters = codexRouters
    }
    func updateReaderVersion(provider: AgentProvider, profileID: String, version: String) {
        routeGeneration = UUID()
        for (metadata, route) in routes where metadata.agent == provider && metadata.profileID == profileID {
            routes[metadata] = .init(scope: route.scope, readerVersion: version, hostVersion: route.hostVersion)
            if let router = codexRouters[metadata] {
                codexRouters[metadata] = router.updatingReaderVersion(version)
            }
        }
    }
    func context(for packet: CapturePacket, trigger: CollectionWorkTrigger,
                 audit: HistoricalAuditContext? = nil,
                 recordAuthority: SourceAuthorityRecorder) async throws -> CollectionWorkContext {
        guard let route = routes[packet.metadata] else { throw CaptureTransportError.invalidMetadata }
        if let router = codexRouters[packet.metadata] {
            let generation = routeGeneration
            do {
                let context = try await router.context(for: packet, trigger: trigger, audit: audit, recordAuthority: recordAuthority)
                guard generation == routeGeneration else { throw CaptureTransportError.invalidMetadata }
                return context
            } catch StorageError.capacityExceeded(let resource) {
                guard generation == routeGeneration else { throw CaptureTransportError.invalidMetadata }
                // Pollers report their own scoped capacity failure. Helper admission must
                // retain this configured scope before the transport sends its rejection.
                if trigger == .helperDelivery {
                    throw CollectionCapacityRejection(resource: resource, scope: route.scope)
                }
                throw StorageError.capacityExceeded(resource)
            }
        }
        return try route.context(for: packet, trigger: trigger, audit: audit)
    }
}

private struct ObservedCodexHookNormalizer: CaptureNormalizer {
    let adapter: CodexHookContentAdapter
    let onBatch: @Sendable (CollectionBatch, CaptureMetadata) async -> Void
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        let batch = try await adapter.normalize(packet, capturedAt: capturedAt, cryptography: cryptography)
        await onBatch(batch, packet.metadata)
        return batch
    }
}

private struct ObservedClaudeNormalizer: CaptureNormalizer {
    let adapter: ClaudeAdapter
    let onObservation: @Sendable ([ClaudeActiveSource]) async -> Void
    let onBatch: @Sendable (CollectionBatch, CaptureMetadata) async -> Void
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        let batch = try await adapter.normalize(packet, capturedAt: capturedAt, cryptography: cryptography)
        await onBatch(batch, packet.metadata)
        if !batch.sources.isEmpty {
            var observed: [ClaudeActiveSource] = []
            var paths = Set<String>()
            for source in batch.sources {
                guard case .live = source.record.metadata.origin.provenance else { continue }
                guard let path = source.context?.transcriptPath, paths.insert(path).inserted else { continue }
                if let active = try? ClaudeActiveSource(sessionID: source.record.metadata.identity.session.sessionID,
                    transcriptURL: URL(fileURLWithPath: path), interface: source.record.metadata.origin.interface) {
                    observed.append(active)
                }
            }
            await onObservation(observed)
        }
        return batch
    }
}

private struct ObservedCodexNormalizer: CaptureNormalizer {
    let adapter: CodexAdapter
    let onSelection: @Sendable ([CodexActiveSource]) async -> Void
    let onObservation: @Sendable ([CodexActiveSource]) async -> Void
    let onBatch: @Sendable (CollectionBatch, CaptureMetadata) async -> Void
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        // Hooks may arrive before Codex flushes public items. Retain the explicit session
        // selection for polling even when normalization must retry the encrypted capture.
        if adapter.authority == .publicNativeItems,
           packet.metadata.agent == .codex, packet.metadata.profileID == adapter.profileID,
           packet.metadata.interface == adapter.interface,
           CollectionCompatibility.isEligible(provider: .codex, interface: adapter.interface, version: adapter.agentVersion),
           let hook = try? JSONSerialization.jsonObject(with: packet.eventJSON) as? [String: Any],
           let event = hook["hook_event_name"] as? String, CodexHookConfiguration.events.contains(event),
           let session = hook["session_id"] as? String,
           let selected = try? CodexActiveSource(threadID: session, interface: adapter.interface,
                                                authority: adapter.authority) {
            var selections = [selected]
            if ["SubagentStart", "SubagentStop"].contains(event),
               let child = hook["agent_id"] as? String, child != session,
               let childSelection = try? CodexActiveSource(threadID: child, interface: adapter.interface,
                                                          authority: adapter.authority) {
                selections.append(childSelection)
            }
            await onSelection(selections)
        }
        let batch = try await adapter.normalize(packet, capturedAt: capturedAt, cryptography: cryptography)
        await onBatch(batch, packet.metadata)
        if !batch.sources.isEmpty {
            var observed: [CodexActiveSource] = []
            var threads = Set<String>()
            for source in batch.sources {
                guard case .live = source.record.metadata.origin.provenance,
                      threads.insert(source.record.metadata.identity.session.sessionID).inserted else { continue }
                if let selected = try? CodexActiveSource(threadID: source.record.metadata.identity.session.sessionID,
                    interface: source.record.metadata.origin.interface, authority: adapter.authority,
                    transcriptURL: source.context?.transcriptPath.map { URL(fileURLWithPath: $0) }) {
                    observed.append(selected)
                }
            }
            await onObservation(observed)
        }
        return batch
    }
}

/// The app owns capture and persistence for its entire process lifetime.
@MainActor
final class AppRuntime {
    private let model: AppModel
    private let server = LocalCaptureServer()
    private let admission = CaptureAdmission()
    private(set) var store: ProtectedStore?
    private(set) var protection: ProtectionServices?
    private var startup: Task<Void, Never>?
    private var startupPhase = StorageStartupFailure.Phase.preparingStorage
    private var refreshTask: Task<Void, Never>?
    private var pipeline: DetectionPipeline?
    private var activeMonitor: ClaudeActiveTranscriptMonitor?
    private var codexMonitor: CodexActiveHistoryMonitor?
    private var codexHistory: CodexAppServerHistoryClient?
    private var historyProducers: [(route: CollectionCaptureRoute, producer: any HistoricalCaptureProducer)] = []
    private var sourceProducers: [CollectionScope: (route: CollectionCaptureRoute, producer: any SourceHistoricalCaptureProducer)] = [:]
    private var collectionConfigured = false
    private var collectionObserved = false
    private var collectionDirectory: URL?
    private var setup: AgentSetupController?
    private var viewing: ViewingController?
    private var viewingGeneration = UUID()
    private var sourceOpening = SourceOpeningController()
    private var sourceOpeningConfiguration: SourceOpeningConfiguration?
    private let notifications = NotificationController()
    private let loginItem = LoginItemController()
    private var deliveringNotifications = false
    /// Notification delivery follows the requested monitoring state, held closed while an
    /// inventory change reconciles presentations. Both inputs change synchronously on this actor.
    private var monitoringRequested = true
    private var inventoryMutationActive = false
    private var actions: [UUID: Task<Void, Never>] = [:]
    /// The inventory revision and day last published, so an unchanged store isn't republished every second.
    private var publishedRevision: Int64?
    private var publishedDay: Date?
    var onShowInventory: (() -> Void)?
    #if DEBUG
    private var acceptanceReportURL: URL?
    private var acceptanceDeadline: Date?
    private var acceptanceFinishFile: URL?
    private var acceptanceFinishing = false
    private var acceptanceNativeChildSources: Set<SourceIdentity> = []
    private var acceptanceCodexRoleEvidence: CodexAcceptanceRoleEvidence?
    private var acceptanceClaudeRoleEvidence: ClaudeAcceptanceRoleEvidence?
    private var acceptanceTransportRejections: [CaptureRejectionDiagnostic: Int] = [:]
    private var acceptanceUsesExplicitStore = false
    private var acceptancePhase: String?
    private var acceptanceRecovery: DisposableRecoveryConfiguration?
    private var acceptanceProcessingStopped = false
    private var acceptanceExitWithPending = false
    private var acceptanceLoadedExistingManifest = false
    private var acceptanceCheckpointIDs: Set<UUID> = []
    private var acceptanceLoadedCheckpointIDs: Set<UUID> = []
    private var acceptanceCompletedCaptureIDs: Set<UUID> = []
    private var acceptanceCodexPollingStopped = false
    private var acceptanceCodexRetryControlConsumed = false
    private var acceptanceCodexRetryActionAvailable = false
    private var acceptanceCodexRetryInvoked = false
    private var acceptanceCodexRetryTarget: StoredCollectionWork?
    private var acceptanceClaudeInventory: InventoryStateAcceptance.ClaudeFixture?
    private var acceptanceClaudePollingStopped = false
    private var acceptanceInventoryFixture: InventoryStateAcceptance.Fixture {
        acceptanceClaudeInventory?.fixture ?? .codex
    }
    private var acceptanceInventoryPollingStopped: Bool {
        acceptanceClaudeInventory == nil ? acceptanceCodexPollingStopped : acceptanceClaudePollingStopped
    }
    private var acceptanceInventoryReviewConsumed = false
    private var acceptanceInventoryAcknowledgementConsumed = false
    private var acceptanceInventoryAcknowledgementApplied = false
    private var acceptanceInventoryRemovedUpgrade: InventoryRemovedUpgradeAcceptance?
    private var acceptanceInventoryReviewApplied = false
    private var acceptanceInventoryRemovalConsumed = false
    private var acceptanceInventoryRemovalApplied = false
    private var acceptanceInventoryControlFailure: InventoryStateAcceptance.Failure?
    private var acceptanceInventorySeededReceiptKind: String?
    private var acceptanceInventoryReplayConsumed = false
    private var acceptanceInventoryReplayCapture: UUID?
    private var acceptanceInventoryReplayAudit: HistoricalAuditContext?
    private var acceptanceInventoryReplaySource: CoverageSourceRetryDescriptor?
    private var acceptanceInventoryReplayExpectedSources: Set<SourceIdentity> = []
    private var acceptanceInventoryReplayObservedSources: Set<SourceIdentity> = []
    private var acceptanceInventoryReplayObservedKinds: Set<ContentType> = []
    private var acceptanceInventoryReplayBatches = 0
    private var acceptanceInventoryReplayClean = true
    private var acceptanceWebResults: WebResultAcceptance?
    private var acceptanceWebReplayConsumed = false
    private var acceptanceWebReplayCapture: UUID?
    private var acceptanceWebReplayAudit: HistoricalAuditContext?
    private var acceptanceWebReplaySource: CoverageSourceRetryDescriptor?
    private var acceptanceWebReplayExpectedSources: Set<SourceIdentity> = []
    private var acceptanceWebReplayObservedSources: Set<SourceIdentity> = []
    private var acceptanceWebReplayBatches = 0
    private var acceptanceWebReplayClean = true
    private var acceptanceReview: ReviewAcceptance?
    private var acceptanceDesktopBeta: DesktopBetaAcceptance?
    private var acceptanceNativeContent: NativeContentAcceptance?
    private var acceptanceNativeContentReplayConsumed = false
    private var acceptanceNativeContentReplayCapture: UUID?
    private var acceptanceNativeContentReplayAudit: HistoricalAuditContext?
    private var acceptanceNativeContentReplaySource: CoverageSourceRetryDescriptor?
    private var acceptanceNativeContentReplayExpectedSources: Set<SourceIdentity> = []
    private var acceptanceNativeContentReplayObservedSources: Set<SourceIdentity> = []
    private var acceptanceNativeContentReplayBatches = 0
    private var acceptanceNativeContentReplayClean = true
    private var acceptanceNativeContentReplayNativeReadsBefore = 0
    private var workflowEvents: [String: Int] = [:]
    private var lastReportedViewingState: InventoryViewingState = .masked
    #endif
    private var terminating = false
    private var timer: Timer?
    private var eventMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        installWorkflowActions()
    }

    func start() {
        installViewingLifecycle()
        // Permissions change in System Settings; coming back to the app shows the current state.
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPreferences() }
        }
        #if DEBUG
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--acceptance-report"), args.indices.contains(index + 1),
           let secondsIndex = args.firstIndex(of: "--acceptance-seconds"), args.indices.contains(secondsIndex + 1),
           let seconds = Double(args[secondsIndex + 1]), seconds >= 2, seconds <= 120 {
            acceptanceReportURL = URL(fileURLWithPath: args[index + 1])
            acceptanceDeadline = args.contains("--acceptance-hold") ? nil : Date().addingTimeInterval(seconds)
            if let finishIndex = args.firstIndex(of: "--acceptance-finish-file"),
               args.indices.contains(finishIndex + 1), args[finishIndex + 1].hasPrefix("/") {
                acceptanceFinishFile = URL(fileURLWithPath: args[finishIndex + 1])
            }
            writeOpeningReport(phase: "starting")
        }
        #endif
        startup = Task { [weak self] in await self?.openStorage() }
    }

    private func openStorage() async {
        do {
            guard let accessGroup = Bundle.main.object(forInfoDictionaryKey: "SpillcheckKeychainAccessGroup") as? String,
                  !accessGroup.isEmpty, !accessGroup.contains("$(") else { throw KeyUnavailable.accessGroupUnavailable }
            let applicationSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            #if DEBUG
            // Disposable acceptance vaults only; release builds always use the application store.
            let args = CommandLine.arguments
            let overrideDirectory = args.firstIndex(of: "--store-directory").flatMap { index in
                args.indices.contains(index + 1) ? URL(fileURLWithPath: args[index + 1], isDirectory: true) : nil
            }
            acceptanceUsesExplicitStore = overrideDirectory != nil
            if args.contains("--acceptance-recovery-worker") {
                guard acceptanceReportURL != nil, overrideDirectory != nil else { throw ClaudeCollectionError.invalidConfiguration }
                acceptanceRecovery = try DisposableRecoveryConfiguration(arguments: args)
            }
            guard !args.contains("--acceptance-recovery-inventory-state") || acceptanceRecovery?.inventoryStateEnabled == true else {
                throw ClaudeCollectionError.invalidConfiguration
            }
            acceptanceClaudeInventory = try InventoryStateAcceptance.ClaudeFixture.fromArguments(args, recovery: acceptanceRecovery)
            acceptanceClaudePollingStopped = acceptanceClaudeInventory != nil

            guard !args.contains("--acceptance-recovery-upgrade-state") || acceptanceRecovery?.upgradeStateEnabled == true else {
                throw ClaudeCollectionError.invalidConfiguration
            }
            guard !args.contains("--acceptance-recovery-upgrade-removed-state") || acceptanceRecovery?.upgradeRemovedStateEnabled == true else {
                throw ClaudeCollectionError.invalidConfiguration
            }
            guard (!args.contains("--acceptance-recovery-web-results") && !args.contains("--acceptance-web-source"))
                || acceptanceRecovery?.webResultsEnabled == true else { throw ClaudeCollectionError.invalidConfiguration }
            guard (!args.contains("--acceptance-recovery-native-content") && !args.contains("--acceptance-native-content-descriptor"))
                || acceptanceRecovery?.nativeContentEnabled == true else { throw ClaudeCollectionError.invalidConfiguration }
            guard (!args.contains("--acceptance-recovery-review") && !args.contains("--acceptance-review-descriptor") && !args.contains("--acceptance-review-stage"))
                || acceptanceRecovery?.reviewEnabled == true else { throw ClaudeCollectionError.invalidConfiguration }
            guard (!args.contains("--acceptance-recovery-desktop-beta") && !args.contains("--acceptance-desktop-beta-descriptor") && !args.contains("--acceptance-desktop-beta-stage"))
                || acceptanceRecovery?.desktopBetaEnabled == true else { throw ClaudeCollectionError.invalidConfiguration }
            let selectedDirectory = try overrideDirectory ?? AppStorageLocation.prepare(in: applicationSupport)
            #else
            let selectedDirectory = try AppStorageLocation.prepare(in: applicationSupport)
            #endif
            let directory = selectedDirectory
            startupPhase = .probingStorage
            let probe = try await Task.detached { try ProtectedStore.probe(at: directory) }.value
            #if DEBUG
            if args.contains("--acceptance-codex-parent") || args.contains("--acceptance-codex-child") {
                let configuration = try CodexCollectionConfiguration.fromArguments(args)
                let roles = try CodexAcceptanceRoles.fromArguments(args, configuration: configuration,
                    explicitStore: acceptanceUsesExplicitStore, reportRequested: acceptanceReportURL != nil)
                guard probe.manifest == nil, probe.state == .empty, let roles else {
                    throw CodexCollectionError.invalidConfiguration
                }
                acceptanceCodexRoleEvidence = CodexAcceptanceRoleEvidence(roles: roles)
            }
            if args.contains("--acceptance-claude-role-evidence") {
                let configuration = try CollectionConfiguration.fromArguments(args)
                let roles = try ClaudeAcceptanceRoles.fromArguments(args, configuration: configuration,
                    explicitStore: acceptanceUsesExplicitStore, reportRequested: acceptanceReportURL != nil)
                guard probe.manifest == nil, probe.state == .empty, let roles else {
                    throw ClaudeCollectionError.invalidConfiguration
                }
                acceptanceClaudeRoleEvidence = ClaudeAcceptanceRoleEvidence(roles: roles)
            }
            if args.contains("--acceptance-recovery-claude-role-evidence") {
                let roles = try ClaudeAcceptanceRoles.fromRecoveryArguments(args, recovery: acceptanceRecovery,
                    explicitStore: acceptanceUsesExplicitStore, reportRequested: acceptanceReportURL != nil)
                guard probe.manifest != nil, let roles, acceptanceClaudeRoleEvidence == nil else {
                    throw ClaudeCollectionError.invalidConfiguration
                }
                // The separately retained creator owns cleanup. This loaded worker can only
                // measure sources under its token-bound disposable provider home.
                acceptanceClaudeRoleEvidence = ClaudeAcceptanceRoleEvidence(roles: roles)
            }
            acceptanceLoadedExistingManifest = probe.manifest != nil
            writeOpeningReport(phase: "loading-device-keys")
            #endif
            try Task.checkCancellation()
            startupPhase = .loadingDeviceKeys
            let services = try await ProtectionBootstrap.prepare(at: directory, manifest: probe.manifest, storeState: probe.state,
                configuration: ProtectionConfiguration(accessGroup: accessGroup))
            protection = services
            #if DEBUG
            writeOpeningReport(phase: "opening-encrypted-store")
            #endif
            try Task.checkCancellation()
            startupPhase = .openingStore
            let opened = try await ProtectedStore.open(at: directory, cryptography: services.background)
            store = opened
            startupPhase = .committingBootstrap
            try services.commitBootstrap()
            collectionDirectory = directory
            startupPhase = .configuringCollection
            try await configureWorkflow(store: opened, services: services, directory: directory)
            if terminating || Task.isCancelled {
                await opened.setMonitoring(enabled: false)
                try await opened.close()
                return
            }
            let admission = admission
            let currentSetup = setup
            #if DEBUG
            let acceptanceHistoryAdmission = acceptanceReportURL != nil && acceptanceUsesExplicitStore
                && CommandLine.arguments.contains("--acceptance-allow-history-request")
            let acceptanceCodexHistoryAdmission = acceptanceHistoryAdmission
                && (acceptanceRecovery?.inventoryStateEnabled == true || acceptanceRecovery?.webResultsEnabled == true || acceptanceRecovery?.nativeContentEnabled == true)
            #endif
            await admission.update(try LiveCaptureScope(startedAt: .now,
                catchupReason: probe.manifest == nil ? .firstLaunch : .restart))
            startupPhase = .startingCapture
            var rejectionObserver: LocalCaptureServer.RejectionHandler?
            #if DEBUG
            if acceptanceReportURL != nil && acceptanceUsesExplicitStore {
                rejectionObserver = { [weak self] diagnostic in
                    await self?.recordAcceptanceTransportRejection(diagnostic)
                }
            }
            #endif
            try await server.start(at: directory.appendingPathComponent("capture.sock"),
                accepting: { await opened.processingPermit() != nil },
                onCapture: { packet in
                    // Resume installs its scope before rotating the store generation.
                    // Fetching the permit first makes any intervening pause/resume stale.
                    guard let permit = await opened.processingPermit() else { throw StorageError.monitoringPaused }
                    guard let scope = await admission.currentScope() else { throw StorageError.monitoringPaused }
                    // No capture callback returns successfully before the encrypted transaction commits.
                    var historicalAudit: HistoricalAuditContext?
                    #if DEBUG
                    if acceptanceHistoryAdmission {
                        historicalAudit = try ClaudeAdapter.historicalAuditForTesting(in: packet)
                    }
                    if acceptanceCodexHistoryAdmission {
                        historicalAudit = try CodexAdapter.historicalAuditForTesting(in: packet) ?? historicalAudit
                    }
                    #endif
                    let context: CollectionWorkContext
                    do {
                        context = try await admission.context(for: packet, trigger: .helperDelivery, audit: historicalAudit,
                            recordAuthority: { try await opened.selectAuthority($0, permit: permit) })
                    } catch let failure as CollectionCapacityRejection {
                        // Suppress the generic transport gap only after this precise gap
                        // commits. A failed diagnostic write retains the generic fallback.
                        try await opened.recordCoverageGap(failure.gap)
                        throw CaptureTransportError.rejectionRecorded
                    }
                    let insertion = try await opened.enqueue(packet.body, capturedAt: .now, permit: permit,
                        scope: scope, historicalAudit: historicalAudit, workContext: context)
                    let queueID: UUID
                    switch insertion {
                    case .inserted(let id), .alreadyQueued(let id), .alreadyProcessed(let id): queueID = id
                    }
                    await currentSetup?.received(packet, durableQueueID: queueID)
                }, onGap: { reason in
                    try? await opened.recordCoverageGap(CoverageGap(reason: reason,
                        operation: .hookDelivery, diagnosticCode: reason.defaultDiagnosticCode, observedAt: .now))
                }, onRejection: rejectionObserver)
            if terminating || Task.isCancelled {
                await opened.setMonitoring(enabled: false)
                await server.stop()
                try await opened.close()
                return
            }
            model.storageReady = true
            model.storageFailed = false
            model.startupFailure = nil
            model.storageMessage = nil
            await startCollection(directory: directory, store: opened, cryptography: services.background)
            await refresh()
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                    await self?.refresh()
                }
            }
        } catch is CancellationError {
            mask(.windowClose)
        } catch {
            mask(.authorizationFailure)
            if let store { await store.setMonitoring(enabled: false) }
            await server.stop()
            monitoringRequested = false
            updateNotificationGate()
            model.storageReady = false
            model.storageFailed = true
            model.startupFailure = StorageStartupFailure(error: error, phase: startupPhase)
            model.storageMessage = Self.storageFailureMessage(error)
            model.pauseAfterBarrier()
            #if DEBUG
            writeOpeningReport(phase: Self.controlledFailure(error))
            #endif
        }
    }

    private func configureWorkflow(store: ProtectedStore, services: ProtectionServices, directory: URL) async throws {
        let controller = ViewingController(session: services.viewingSession,
            loadPayload: { reference in try await store.payload(reference) },
            selectionIsCurrent: { selection in selection.isCurrent(in: await store.snapshot()) })
        viewing = controller
        controller.onChange = { [weak self] in self?.publishViewing() }
        services.viewingSession.onInvalidate = { [weak self] reason in
            #if DEBUG
            self?.recordWorkflowEvent("mask-" + reason.rawValue)
            #endif
            self?.viewingGeneration = UUID()
            self?.viewing?.didInvalidate(reason)
            self?.model.clearRevealedContent()
        }
        let ownedSetup = AgentSetupController(store: store,
            helperURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/spillcheck-hook"),
            socketURL: directory.appendingPathComponent("capture.sock"))
        setup = ownedSetup
        try await ownedSetup.load()
        #if DEBUG
        if let recovery = acceptanceRecovery, CommandLine.arguments.contains("--acceptance-recovery-install-profile") {
            guard !CommandLine.arguments.contains("--acceptance-recovery-install-codex-profile") else {
                throw CodexSetupError.invalidConfiguration
            }
            let profile = try recovery.claudeProfile(arguments: CommandLine.arguments)
            try await ownedSetup.install(.init(provider: .claudeCode, profileID: "owned-signed-claude-recovery",
                executablePath: profile.executable, homePath: profile.home, version: profile.version))
            try await ownedSetup.verify(.claudeCode)
        }
        if let recovery = acceptanceRecovery, CommandLine.arguments.contains("--acceptance-recovery-install-codex-profile") {
            guard CommandLine.arguments.filter({ $0 == "--acceptance-recovery-install-codex-profile" }).count == 1,
                  !CommandLine.arguments.contains(where: { $0.hasPrefix("--codex-") }) else {
                throw CodexSetupError.invalidConfiguration
            }
            let profile = try recovery.codexProfile(arguments: CommandLine.arguments)
            try await ownedSetup.install(.init(provider: .codex, profileID: "owned-signed-codex-omission-recovery",
                executablePath: profile.executable, homePath: profile.home, version: profile.version,
                authorizedHosts: [.standaloneCLI]))
            try await ownedSetup.verify(.codex)
        }
        #endif
        await publishSnapshot(from: store)
        await refreshSetup(updateProfiles: true)
        notifications.navigationIsCurrent = { target in await store.notificationTargetExists(target) }
        notifications.onNavigate = { [weak self] target in
            guard let self, !self.terminating else { return }
            #if DEBUG
            self.recordWorkflowEvent("notification-navigation")
            #endif
            self.mask()
            switch target {
            case .value(let id): self.model.selectValue(id)
            case .historicalAudit(let id):
                self.model.selectedEntryID = nil
                self.model.actionMessage = "Recent-history summary selected. Review its measured coverage and inventory."
                if let valueID = self.model.historicalSummaries.first(where: { $0.audit.id == id })?.ordinaryValueIDs.first {
                    self.model.selectValue(valueID)
                }
            case .collectionHealth:
                self.model.selectedEntryID = nil
                self.model.route = .coverage
                self.model.actionMessage = "Collection has a scoped limitation. Review the affected route and content in Coverage."
            }
            self.onShowInventory?()
        }
        await notifications.refreshPermission()
        publishLoginPreference()
    }

    private func installWorkflowActions() {
        model.onSelectionChanged = { [weak self] entry in
            self?.viewingGeneration = UUID()
            let id: UUID?
            switch entry {
            case .value(let valueID), .unlocated(let valueID): id = valueID
            case .obsoleteMarker, nil: id = nil
            }
            self?.viewing?.select(valueID: id)
            self?.sourceOpening.cancel()
        }
        model.onOccurrenceSelectionChanged = { [weak self] _ in
            self?.viewingGeneration = UUID()
            self?.viewing?.invalidate(.userMask)
            self?.sourceOpening.cancel()
        }
        model.onMask = { [weak self] in self?.mask() }
        model.onReveal = { [weak self] entry, occurrence in
            guard let self else { return }
            self.model.selectedOccurrenceID = occurrence
            let generation = self.viewingGeneration
            self.performAction { runtime in
                await runtime.reveal(entry: entry, occurrenceID: occurrence, generation: generation)
            }
        }
        model.onReview = { [weak self] id, state in
            self?.performAction { runtime in await runtime.mutateInventory(.review(id, state)) }
        }
        model.onReviewAll = { [weak self] ids, state in
            self?.performAction { runtime in await runtime.mutateInventory(.reviewAll(ids, state)) }
        }
        model.onAcknowledge = { [weak self] fingerprint, acknowledgement in
            self?.performAction { runtime in await runtime.mutateInventory(.acknowledge(fingerprint, acknowledgement)) }
        }
        model.onRemoveContent = { [weak self] fingerprint in
            self?.performAction { runtime in await runtime.mutateInventory(.remove(fingerprint)) }
        }
        model.onForgetMarker = { [weak self] fingerprint in
            self?.performAction { runtime in await runtime.mutateInventory(.forget(fingerprint)) }
        }
        model.onOpenSource = { [weak self] id in
            guard let self else { return }
            let generation = self.viewingGeneration, entry = self.model.selectedEntryID
            self.performAction { runtime in await runtime.openSource(id: id, entry: entry, generation: generation) }
        }
        model.onTerminalResume = { [weak self] id in
            guard let self else { return }
            let generation = self.viewingGeneration, entry = self.model.selectedEntryID
            self.performAction { runtime in await runtime.prepareTerminalResume(id: id, entry: entry, generation: generation) }
        }
        model.onDetectAgents = { [weak self] in
            self?.performAction { runtime in
                runtime.model.detectingAgents = true
                await runtime.setup?.discover()
                await runtime.refreshSetup(updateProfiles: true)
                runtime.model.detectingAgents = false
            }
        }
        model.onInstallAgent = { [weak self] provider, draft in
            self?.performAction { runtime in await runtime.editSetup(provider: provider, action: .install(draft)) }
        }
        model.onConnectAgents = { [weak self] drafts in
            // Setup edits are exclusive, so several agents connect one after another.
            self?.performAction { runtime in
                for draft in drafts { await runtime.editSetup(provider: draft.provider, action: .install(draft)) }
            }
        }
        model.onOpenSetupTerminal = { [weak self] provider in
            guard let self, let command = self.model.setupCommand(for: provider) else { return }
            if !SetupTerminal.open(command) {
                self.model.showToast("Terminal couldn’t be opened. Copy the command and run it in any terminal.")
            }
        }
        model.onRepairAgent = { [weak self] provider in
            self?.performAction { runtime in
                guard let draft = runtime.model.agentProfiles[provider] else { return }
                await runtime.editSetup(provider: provider, action: .install(draft))
            }
        }
        model.onVerifyAgent = { [weak self] provider in
            self?.performAction { runtime in await runtime.editSetup(provider: provider, action: .verify) }
        }
        model.onRemoveAgent = { [weak self] provider in
            self?.performAction { runtime in await runtime.editSetup(provider: provider, action: .remove) }
        }
        model.onRequestNotificationPermission = { [weak self] in
            self?.performAction { runtime in await runtime.notifications.requestPermission() }
        }
        model.onLaunchAtLoginRequested = { [weak self] enabled in
            self?.performAction { runtime in
                runtime.model.loginBusy = true
                await runtime.loginItem.setEnabled(enabled)
                runtime.publishLoginPreference()
            }
        }
        model.onRetryHistory = { [weak self] provider in
            self?.performAction { runtime in await runtime.retryHistory(provider) }
        }
        model.onRetrySource = { [weak self] source in
            self?.performAction { runtime in await runtime.retrySource(source) }
        }
        model.onExportDiagnostics = { [weak self] in
            self?.requestDiagnosticsExport()
        }
        model.onRefreshPreferences = { [weak self] in self?.refreshPreferences() }
        notifications.onPermissionChange = { [weak self] in self?.publishNotificationPermission() }
    }

    /// Reads the notification permission and login item again, which only System Settings changes.
    private func refreshPreferences() {
        guard !terminating, !model.isDemo else { return }
        publishLoginPreference()
        Task { [weak self] in await self?.notifications.refreshPermission() }
    }

    private func performAction(_ operation: @escaping @MainActor (AppRuntime) async -> Void) {
        guard !terminating, model.storageReady, !model.isDemo else { return }
        let id = UUID()
        actions[id] = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await operation(self)
            self.actions.removeValue(forKey: id)
        }
    }

    /// Startup failure export is the only action allowed before storage opens.
    private func requestDiagnosticsExport() {
        guard !terminating, model.canPerformCoverageAction(.exportDiagnostics) else { return }
        let id = UUID()
        actions[id] = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.exportCoverageDiagnostics()
            self.actions.removeValue(forKey: id)
        }
    }

    private func publishViewing() {
        guard let viewing else { return }
        #if DEBUG
        if lastReportedViewingState != viewing.state {
            recordWorkflowEvent("viewing-" + String(describing: viewing.state))
            lastReportedViewingState = viewing.state
        }
        #endif
        model.clearRevealedContent()
        model.viewingBusy = viewing.state == .authenticating
        model.viewingMessage = viewing.state.message
        model.revealIssue = switch viewing.state {
        case .cancelled: .cancelled
        case .unavailable: .failed
        case .masked, .authenticating, .revealed: nil
        }
        model.viewingAuthorized = viewing.isAuthorized && viewing.state == .revealed
        guard model.viewingAuthorized else { return }
        if let valueID = model.selectedID, let value = viewing.content.value { model.revealedContent[valueID] = value }
        model.revealedExcerpts = viewing.content.excerpts
        model.revealedSourceMetadata = viewing.content.sourceMetadata
    }

    private func reveal(entry: InventoryEntryID, occurrenceID: UUID?, generation: UUID) async {
        guard let store, let viewing, entry == model.selectedEntryID,
              occurrenceID == model.selectedOccurrenceID,
              generation == viewingGeneration, model.windowVisible else { return }
        do {
            let snapshot = await store.snapshot()
            let selection: InventoryRevealSelection
            switch entry {
            case .value(let valueID):
                // One authentication shows the value with the selected appearance's retained context.
                // Metadata-only obsolete appearances have no context, so they reveal the value alone.
                if let occurrenceID, snapshot.occurrences[occurrenceID] != nil {
                    selection = try InventoryRevealSelection.occurrenceWithValue(in: snapshot, occurrenceID: occurrenceID)
                } else {
                    selection = try InventoryRevealSelection.retainedValue(in: snapshot, valueID: valueID)
                }
                guard selection.valueID == valueID else { return }
            case .unlocated(let resultID):
                selection = try InventoryRevealSelection.unlocatedSource(in: snapshot, resultID: resultID)
            case .obsoleteMarker: return
            }
            guard model.selectedEntryID == entry, generation == viewingGeneration,
                  occurrenceID == model.selectedOccurrenceID,
                  model.windowVisible, !terminating, !Task.isCancelled else { return }
            viewing.select(valueID: selection.valueID)
            await viewing.reveal(selection)
        } catch {
            if model.selectedEntryID == entry, generation == viewingGeneration,
               occurrenceID == model.selectedOccurrenceID {
                model.viewingMessage = "No retained content is available for this appearance."
            }
        }
    }

    private enum InventoryMutation {
        case review(UUID, OccurrenceReview)
        case reviewAll([UUID], OccurrenceReview)
        case acknowledge(ValueFingerprint, ObsoleteAcknowledgement)
        case remove(ValueFingerprint)
        case forget(ValueFingerprint)
    }

    private func mutateInventory(_ mutation: InventoryMutation) async {
        guard let store, !model.actionBusy else { return }
        model.actionBusy = true
        model.actionMessage = nil
        inventoryMutationActive = true
        updateNotificationGate()
        defer {
            model.actionBusy = false
            inventoryMutationActive = false
            updateNotificationGate()
        }
        let before = await store.snapshot()
        let oldLive = before.alertDecisions.values.compactMap { alert -> MaskedNotification? in
            before.conversationLabels[alert.eligibility.session].map { .live(alert, conversation: $0) }
        }
        let oldPresentations = oldLive + before.historicalNotificationDecisions.values.map(MaskedNotification.historical)
        do {
            switch mutation {
            case .review(let id, let state):
                try await store.review(id, as: state)
                #if DEBUG
                recordWorkflowEvent("review-" + state.rawValue)
                #endif
                model.actionMessage = "Review saved for this appearance. Other appearances are unchanged."
            case .reviewAll(let ids, let state):
                for id in ids { try await store.review(id, as: state) }
                #if DEBUG
                recordWorkflowEvent("review-all-" + state.rawValue)
                #endif
                model.actionMessage = state == .falsePositive
                    ? "Marked as not a secret. New appearances are still checked."
                    : "Marked as possibly a secret again."
            case .acknowledge(let fingerprint, let acknowledgement):
                try await store.acknowledgeObsolete(fingerprint, as: acknowledgement, at: .now)
                #if DEBUG
                recordWorkflowEvent("acknowledge-" + acknowledgement.rawValue)
                #endif
                // The selected value moves into the rotated or revoked section; keep it in view.
                model.handledExpanded = true
                model.actionMessage = "Acknowledged as \(acknowledgement.rawValue). Later appearances will show as obsolete, without alerts. This wasn’t checked with the service."
            case .remove(let fingerprint):
                mask()
                let plan = try await store.removeContent(for: fingerprint)
                #if DEBUG
                recordWorkflowEvent("content-removed")
                #endif
                notifications.cancel(identifiers: plan.notificationIdentifiers)
                model.actionMessage = plan.retainedObsoleteMarker == nil
                    ? "Retained content removed. Agent histories weren’t touched. If it appears again, it’s treated as new."
                    : "Retained content removed. It stays recognized as obsolete."
            case .forget(let fingerprint):
                mask()
                try await store.forgetObsoleteMarker(fingerprint)
                #if DEBUG
                recordWorkflowEvent("marker-forgotten")
                #endif
                model.actionMessage = "Obsolete recognition forgotten. New appearances will be evaluated normally."
            }
            for presentation in oldPresentations {
                if try await store.notificationCanRemain(presentation) == false {
                    if try await store.notificationCanRemain(identifier: presentation.identifier) {
                        notifications.invalidatePresentations(identifiers: [presentation.identifier])
                    } else {
                        notifications.cancel(identifiers: [presentation.identifier])
                    }
                }
            }
            await refresh()
        } catch {
            model.actionMessage = "The change could not be saved. Reload the inventory and try again."
        }
    }

    private func sourceReference(id: UUID, snapshot: InventorySnapshot) -> (SessionIdentity, Bool)? {
        if let occurrence = snapshot.occurrences[id] { return (occurrence.source.identity.session, occurrence.protectedExcerpt != nil) }
        if let appearance = snapshot.obsoleteAppearances[id] { return (appearance.source.session, false) }
        if let unlocated = snapshot.unlocatedResults[id] { return (unlocated.source.identity.session, false) }
        return nil
    }

    private func openSource(id: UUID, entry selected: InventoryEntryID?, generation: UUID) async {
        guard model.selectedEntryID == selected, model.selectedOccurrenceID == id,
              generation == viewingGeneration, model.windowVisible else { return }
        guard let store, let (session, retained) = sourceReference(id: id, snapshot: await store.snapshot()),
              model.selectedEntryID == selected, generation == viewingGeneration,
              model.selectedOccurrenceID == id,
              !terminating, !Task.isCancelled, model.windowVisible else { return }
        let capability = model.revealedSourceMetadata[id]?.openingCapability ?? .unverified
        let result = await sourceOpening.open(session: session, capability: capability, hasRetainedContext: retained)
        if !terminating, model.selectedEntryID == selected, model.selectedOccurrenceID == id,
           generation == viewingGeneration {
            model.sourceActionMessages[id] = result.message
            model.showToast(result.message)
        }
    }

    private func prepareTerminalResume(id: UUID, entry selected: InventoryEntryID?, generation: UUID) async {
        guard model.selectedEntryID == selected, model.selectedOccurrenceID == id,
              generation == viewingGeneration, model.windowVisible else { return }
        guard model.viewingAuthorized, let metadata = model.revealedSourceMetadata[id], let store else {
            model.sourceActionMessages[id] = "Reveal this occurrence's retained references before preparing a terminal command."
            return
        }
        let snapshot = await store.snapshot()
        protection?.viewingSession.expireIfNeeded()
        guard !terminating, !Task.isCancelled, model.selectedEntryID == selected,
              model.selectedOccurrenceID == id,
              generation == viewingGeneration, model.viewingAuthorized, viewing?.isAuthorized == true,
              model.revealedSourceMetadata[id] == metadata,
              let (session, _) = sourceReference(id: id, snapshot: snapshot) else { return }
        do { model.terminalResumeCommand = try sourceOpening.terminalResumePlan(session: session).displayCommand }
        catch { model.sourceActionMessages[id] = "The source has no available terminal route." }
    }

    private enum SetupAction { case install(AgentProfileDraft), verify, remove }

    private func editSetup(provider: AgentProvider, action: SetupAction) async {
        guard let setup, !model.agentSetupBusy.contains(provider) else { return }
        // Edits run one at a time. A request made during another edit, or during a pause or resume,
        // waits its turn instead of being dropped, which would leave its agent waiting forever.
        while model.monitoringTransition {
            guard !terminating, !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !model.agentSetupBusy.contains(provider) else { return }
        model.agentSetupBusy.insert(provider)
        model.monitoringTransition = true
        defer {
            model.agentSetupBusy.remove(provider)
            model.monitoringTransition = false
        }
        do {
            switch action {
            case .install(let draft):
                guard draft.provider == provider else { return }
                try await setup.install(draft)
                await restartCollection()
                // Adding hooks and checking delivery are one step for the user: start the check now,
                // unless a repair kept an earlier test session that still applies to these hooks.
                if model.monitoringEnabled, await setup.snapshot().states[provider] != .connected {
                    try await setup.verify(provider)
                }
            case .verify:
                guard model.monitoringEnabled else {
                    model.agentSetupMessages[provider] = "Resume monitoring before running the test session."
                    return
                }
                try await setup.verify(provider)
            case .remove:
                try await setup.remove(provider)
                await restartCollection()
            }
            await refreshSetup(updateProfiles: true)
        } catch {
            await refreshSetup(updateProfiles: true)
            model.agentSetupMessages[provider] = "Setup could not complete safely. Check the executable version and profile path; existing unrelated settings are preserved."
        }
    }

    private func restartCollection() async {
        guard let store, let protection, let directory = collectionDirectory, !terminating else { return }
        // Reconfiguration revokes in-flight authority and queue permits before
        // admission changes. A callback that already awaited routing cannot
        // commit under the previous profile authorization afterward.
        await store.setMonitoring(enabled: false)
        await admission.allow([:])
        await activeMonitor?.stop()
        await codexMonitor?.stop()
        await pipeline?.stop()
        await codexHistory?.close()
        activeMonitor = nil; codexMonitor = nil; pipeline = nil; codexHistory = nil
        historyProducers.removeAll()
        sourceProducers.removeAll()
        collectionConfigured = false; collectionObserved = false
        guard !terminating, !Task.isCancelled else { return }
        await store.setMonitoring(enabled: model.monitoringEnabled)
        await startCollection(directory: directory, store: store, cryptography: protection.background)
    }

    private func refreshSetup(updateProfiles: Bool = false) async {
        guard let setup, !terminating else { return }
        await setup.check()
        let snapshot = await setup.snapshot()
        if updateProfiles || model.agentProfiles != snapshot.profiles { model.agentProfiles = snapshot.profiles }
        let changed = await setup.consumeChangedExecutables()
        if !changed.isEmpty {
            model.collectionAssessments = model.collectionAssessments.filter { !changed.contains($0.key.provider) }
            model.lastReadDates = model.lastReadDates.filter { !changed.contains($0.key.provider) }
            model.lastOperationReads = model.lastOperationReads.filter { !changed.contains($0.key.provider) }
        }
        if changed.contains(.codex) { _ = await codexHistory?.refreshExecutableIfChanged() }
        for provider in changed {
            guard let profile = snapshot.profiles[provider] else { continue }
            // Only future admissions change. Durable queued contexts keep their original
            // configuration; successful Codex reads carry independent execution evidence.
            for (scope, source) in sourceProducers where scope.provider == provider && scope.profileID == profile.profileID {
                sourceProducers[scope] = (.init(scope: scope, readerVersion: profile.version,
                    hostVersion: source.route.hostVersion), source.producer)
            }
            historyProducers = historyProducers.map { source in
                guard source.route.scope.provider == provider, source.route.scope.profileID == profile.profileID else { return source }
                return (.init(scope: source.route.scope, readerVersion: profile.version,
                    hostVersion: source.route.hostVersion), source.producer)
            }
            await admission.updateReaderVersion(provider: provider, profileID: profile.profileID, version: profile.version)
        }
        if let profile = snapshot.profiles[.codex], let codexHistory {
            for interface in profile.collectionInterfaces {
                let scope = CollectionScope(provider: .codex, profileID: profile.profileID,
                    interface: interface, path: .publicHistory)
                let assessment = await codexHistory.assessment(scope: scope)
                if model.collectionAssessments[scope] != assessment { model.collectionAssessments[scope] = assessment }
                for operation in assessment.usableOperations where Self.operationAssessed(assessment, operation) {
                    _ = try? await store?.resolveHealthIncidents(scope: scope, operation: operation)
                }
            }
        }
        // Unchanged values are not reassigned, so views reading them aren't invalidated every second.
        if model.agentSetupStates != snapshot.states { model.agentSetupStates = snapshot.states }
        if model.agentSetupMessages != snapshot.messages { model.agentSetupMessages = snapshot.messages }
        if model.verificationPrompts != snapshot.verificationPrompts { model.verificationPrompts = snapshot.verificationPrompts }
        for provider in changed where model.monitoringEnabled {
            await enqueueHistory(provider: provider, reassessing: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let openingConfiguration = SourceOpeningConfiguration(profiles: snapshot.profiles, homeURL: home)
        if sourceOpeningConfiguration != openingConfiguration {
            sourceOpening.cancel()
            sourceOpeningConfiguration = openingConfiguration
            sourceOpening = SourceOpeningController(configuration: openingConfiguration)
        }
    }

    private func publishNotificationPermission() {
        switch notifications.permission {
        case .notRequested: model.notificationState = .notRequested
        case .allowed: model.notificationState = .allowed
        case .denied: model.notificationState = .denied
        case .unavailable: model.notificationState = .unavailable
        }
        model.notificationBusy = notifications.requestingPermission
        model.notificationMessage = model.notificationState == .denied
            ? "Detections remain visible in the inventory and menu bar. Enable banners in macOS notification settings if wanted."
            : nil
    }

    private func publishLoginPreference() {
        loginItem.refresh()
        model.launchAtLogin = loginItem.state == .enabled || loginItem.state == .requiresApproval
        model.loginAvailable = loginItem.state != .unavailable
        model.loginBusy = loginItem.isChanging
        model.loginMessage = loginItem.errorMessage ?? loginItem.state.message
    }

    private func deliverNotifications() async {
        guard !deliveringNotifications, let store, !terminating, model.monitoringEnabled else { return }
        deliveringNotifications = true
        defer { deliveringNotifications = false }
        do {
            #if DEBUG
            if acceptanceRecovery?.reviewEnabled == true || acceptanceRecovery?.desktopBetaEnabled == true { return }
            if acceptanceRecovery?.inventoryStateEnabled == true || acceptanceRecovery?.webResultsEnabled == true || acceptanceRecovery?.nativeContentEnabled == true {
                // Settlement and failures use the ordinary store path and lifecycle guards.
                // Only system presentation is suppressed in this authenticated test mode.
                _ = try await store.pendingHistoricalNotifications()
                return
            }
            #endif
            for notification in try await store.pendingNotifications() {
                guard !terminating, !Task.isCancelled else { return }
                let outcome = await notifications.deliver(notification,
                    isEligible: { (try? await store.notificationIsEligible(notification)) == true })
                switch outcome {
                case .delivered: try await store.recordNotificationDelivery(identifier: notification.identifier, state: .delivered)
                case .permissionDenied: try await store.recordNotificationDelivery(identifier: notification.identifier, state: .permissionDenied)
                case .retry, .cancelled: break
                }
            }
            let snapshot = await store.snapshot()
            model.notificationIndicatorCount = snapshot.alertDecisions.values.filter { $0.delivery == .permissionDenied }.count
        } catch {
            model.notificationMessage = "Notification delivery is pending. Detections remain available in the inventory."
        }
    }

    func requestMonitoring(enabled: Bool) {
        performAction { runtime in await runtime.setMonitoring(enabled: enabled) }
    }

    private func updateNotificationGate() {
        notifications.setMonitoring(enabled: monitoringRequested && !inventoryMutationActive && !terminating)
    }

    func setMonitoring(enabled: Bool) async {
        guard let store, model.storageReady, !terminating, !model.monitoringTransition else { return }
        model.monitoringTransition = true
        monitoringRequested = enabled
        updateNotificationGate()
        if enabled, let scope = try? LiveCaptureScope(startedAt: .now, catchupReason: .resume) {
            await admission.update(scope)
        }
        await store.setMonitoring(enabled: enabled)
        if enabled {
            await pipeline?.start()
            await startClaudeMonitor()
            await startCodexMonitor()
            await enqueueHistory()
        } else {
            await activeMonitor?.stop()
            await codexMonitor?.stop()
            await pipeline?.stop()
        }
        // The displayed pause takes effect only after stale store permits are invalidated.
        if enabled { model.resumeAfterBarrier() } else { model.pauseAfterBarrier() }
        model.monitoringTransition = false
        await refresh()
    }

    func refresh() async {
        guard let store, !terminating else { return }
        do {
            #if DEBUG
            if let recovery = acceptanceRecovery, !acceptanceCodexPollingStopped,
               recovery.authorizes(try recovery.controlURL("stop-codex-polling")) {
                acceptanceCodexPollingStopped = true
                await codexMonitor?.stop()
            }
            if let recovery = acceptanceRecovery, !acceptanceProcessingStopped,
               recovery.authorizes(try recovery.controlURL("stop-processing")) {
                await activeMonitor?.stop()
                await codexMonitor?.stop()
                await pipeline?.stop()
                acceptanceProcessingStopped = true
            }
            if let recovery = acceptanceRecovery,
               recovery.authorizes(try recovery.controlURL("exit-with-pending")), !acceptanceFinishing {
                acceptanceExitWithPending = true
                Task { await self.finishAcceptance() }
            }
            #endif
            _ = try await store.maintainQueue()
            try await store.expireCoverageRecovery(at: .now)
            let report = try await store.coverageReport()
            // Unchanged records are not reassigned, so views reading the report aren't invalidated
            // every second. The kept report's window ends earlier; exports query a fresh report.
            if model.coverageReport?.hasSameRecords(as: report) != true { model.coverageReport = report }
            if model.historyProgress != report.history.items { model.historyProgress = report.history.items }
            model.updateQueue(count: report.queue.count)
            model.updateHistoryWork(queued: report.queue.historicalCount)
            model.refreshCollectionLimitations()
            await refreshSetup()
            #if DEBUG
            await performAcceptanceInventoryReplay()
            await performAcceptanceWebReplay()
            await performAcceptanceNativeContentReplay()
            await performAcceptanceInventoryControl()
            if let recovery = acceptanceRecovery, !acceptanceCodexRetryControlConsumed,
               recovery.authorizes(try recovery.controlURL("retry-terminal-codex-source")) {
                // Consume once even when ineligible. The token never supplies a native selection.
                acceptanceCodexRetryControlConsumed = true
                let candidates = report.work.items.filter {
                    $0.state == .terminal && $0.omissionID != nil && $0.context.scope.provider == .codex
                        && $0.context.scope.path == .publicHistory && $0.context.retry?.hasExactSelection == true
                }
                if !report.work.isTruncated, let target = candidates.max(by: { $0.admittedAt < $1.admittedAt }),
                   let source = target.context.retry {
                    acceptanceCodexRetryTarget = target
                    acceptanceCodexRetryActionAvailable = model.canPerformCoverageAction(.retrySource(source))
                    if acceptanceCodexRetryActionAvailable { model.performCoverageAction(.retrySource(source)) }
                }
            }
            #endif
            model.restoreSuccessfulReads(from: report)
            // The report retains recovered incidents for inspection, while current collection
            // health considers only unresolved omissions and operation failures.
            let gaps = model.refreshCollectionLimitations()
            model.updateCoverage(model.coverageNeedsAttention || model.coverageHasUnreadHistory
                ? .partial(gaps.isEmpty ? [.init(reason: .budgetExhausted)] : gaps)
                : (collectionObserved ? .complete : .notConfigured))
            await publishSnapshot(from: store)
            await deliverNotifications()
            #if DEBUG
            await writeAcceptanceReport(statistics: report.queue, gaps: model.unresolvedCoverageGaps)
            #endif
        } catch {
            model.storageMessage = Self.storageFailureMessage(error)
        }
    }

    /// Republishes the inventory after a committed change, or when the day changes the 7-day window.
    private func publishSnapshot(from store: ProtectedStore) async {
        let revision = await store.stateRevision()
        let day = Calendar.current.startOfDay(for: .now)
        guard revision != publishedRevision || day != publishedDay else { return }
        model.loadSnapshot(await store.snapshot())
        publishedRevision = revision
        publishedDay = day
    }

    #if DEBUG

    private func performAcceptanceWebReplay() async {
        guard let recovery = acceptanceRecovery, recovery.webResultsEnabled,
              let evidence = acceptanceWebResults, evidence.failure == nil,
              !acceptanceWebReplayConsumed, let store else { return }
        do {
            guard recovery.authorizes(try recovery.controlURL("web-result-replay")) else { return }
            acceptanceWebReplayConsumed = true
            let statistics = try await store.queueStatistics()
            guard acceptanceCodexPollingStopped, !acceptanceProcessingStopped, !model.actionBusy,
                  model.monitoringEnabled, !model.monitoringTransition,
                  statistics.count == 0, statistics.claimedCount == 0,
                  try await store.captureIdentitiesForTesting().pending.isEmpty else { throw WebResultAcceptance.Failure.unsafeState }
            let snapshot = await store.snapshot()
            guard WebResultAcceptance.hasNoFindings(snapshot), !snapshot.sourceKinds.isEmpty,
                  snapshot.sourceKinds.count <= WebResultAcceptance.maximumSources,
                  snapshot.sourceKinds.keys.allSatisfy({ $0.session == evidence.session }),
                  snapshot.analysisReceipts.allSatisfy({ $0.source.session == evidence.session
                    && $0.detectorVersion == BetterleaksSecretDetector.version }) else { throw WebResultAcceptance.Failure.unsafeState }
            let routes = sourceProducers.filter { scope, _ in
                scope.provider == .codex && scope.profileID == evidence.session.profileID
                    && scope.interface == .standaloneCLI && scope.path == .publicHistory
            }
            guard routes.count == 1, let (scope, route) = routes.first,
                  let permit = await store.processingPermit(), let liveScope = await admission.currentScope() else {
                throw WebResultAcceptance.Failure.unsafeState
            }
            let source = CoverageSourceRetryDescriptor(scope: scope, session: evidence.session)
            let audit = try HistoricalAuditContext(reason: .resume, endingAt: .now)
            let packet = try await route.producer.initialHistoricalCapture(audit: audit, source: source)
            guard let current = sourceProducers[scope]?.route, current.scope == route.route.scope,
                  current.readerVersion == route.route.readerVersion, current.hostVersion == route.route.hostVersion else {
                throw WebResultAcceptance.Failure.unsafeState
            }
            let context = try current.context(for: packet, trigger: .historyRequest, audit: audit, retry: source)
            acceptanceWebReplayExpectedSources = Set(snapshot.sourceKinds.keys)
            acceptanceWebReplayAudit = audit
            acceptanceWebReplaySource = source
            guard case .inserted(let id) = try await store.enqueue(packet.body, capturedAt: .now, permit: permit,
                scope: liveScope, historicalAudit: audit, workContext: context) else { throw WebResultAcceptance.Failure.unsafeState }
            acceptanceWebReplayCapture = id
        } catch { evidence.reject((error as? WebResultAcceptance.Failure) ?? .reportUnavailable) }
    }

    private func performAcceptanceNativeContentReplay() async {
        guard let recovery = acceptanceRecovery, recovery.nativeContentEnabled,
              let evidence = acceptanceNativeContent, evidence.failure == nil,
              !acceptanceNativeContentReplayConsumed, let store else { return }
        do {
            guard recovery.authorizes(try recovery.controlURL("native-content-replay")) else { return }
            acceptanceNativeContentReplayConsumed = true
            let statistics = try await store.queueStatistics()
            guard acceptanceCodexPollingStopped, !acceptanceProcessingStopped, !model.actionBusy,
                  model.monitoringEnabled, !model.monitoringTransition,
                  statistics.count == 0, statistics.claimedCount == 0,
                  try await store.captureIdentitiesForTesting().pending.isEmpty else { throw NativeContentAcceptance.Failure.unsafeState }
            let snapshot = await store.snapshot()
            guard NativeContentAcceptance.hasNoFindings(snapshot), !snapshot.sourceKinds.isEmpty,
                  snapshot.sourceKinds.count <= NativeContentAcceptance.maximumSources,
                  snapshot.sourceKinds.keys.allSatisfy({ $0.session == evidence.session }),
                  snapshot.analysisReceipts.allSatisfy({ $0.source.session == evidence.session
                    && $0.detectorVersion == BetterleaksSecretDetector.version }) else { throw NativeContentAcceptance.Failure.unsafeState }
            let routes = sourceProducers.filter { scope, _ in
                scope.provider == .codex && scope.profileID == evidence.session.profileID
                    && scope.interface == .standaloneCLI && scope.path == .publicHistory
            }
            guard routes.count == 1, let (scope, route) = routes.first,
                  let permit = await store.processingPermit(), let liveScope = await admission.currentScope() else {
                throw NativeContentAcceptance.Failure.unsafeState
            }
            let source = CoverageSourceRetryDescriptor(scope: scope, session: evidence.session)
            let audit = try HistoricalAuditContext(reason: .resume, endingAt: .now)
            let packet = try await route.producer.initialHistoricalCapture(audit: audit, source: source)
            guard let current = sourceProducers[scope]?.route, current.scope == route.route.scope,
                  current.readerVersion == route.route.readerVersion, current.hostVersion == route.route.hostVersion else {
                throw NativeContentAcceptance.Failure.unsafeState
            }
            let context = try current.context(for: packet, trigger: .historyRequest, audit: audit, retry: source)
            acceptanceNativeContentReplayNativeReadsBefore = evidence.nativeReadCount
            acceptanceNativeContentReplayExpectedSources = Set(snapshot.sourceKinds.keys)
            acceptanceNativeContentReplayAudit = audit
            acceptanceNativeContentReplaySource = source
            guard case .inserted(let id) = try await store.enqueue(packet.body, capturedAt: .now, permit: permit,
                scope: liveScope, historicalAudit: audit, workContext: context) else { throw NativeContentAcceptance.Failure.unsafeState }
            acceptanceNativeContentReplayCapture = id
        } catch { evidence.reject((error as? NativeContentAcceptance.Failure) ?? .reportUnavailable) }
    }


    private func performAcceptanceInventoryReplay() async {
        guard let recovery = acceptanceRecovery, recovery.inventoryStateEnabled, !recovery.upgradeStateEnabled,
              !acceptanceInventoryReplayConsumed, acceptanceInventoryControlFailure == nil,
              let store, let protection else { return }
        do {
            guard recovery.authorizes(try recovery.controlURL("inventory-replay-source")) else { return }
            acceptanceInventoryReplayConsumed = true
            let statistics = try await store.queueStatistics()
            guard acceptanceInventoryPollingStopped, !acceptanceProcessingStopped, !model.actionBusy,
                  model.monitoringEnabled, !model.monitoringTransition,
                  statistics.count == 0, statistics.claimedCount == 0,
                  try await store.captureIdentitiesForTesting().pending.isEmpty else {
                throw InventoryStateAcceptance.Failure.unsafeState
            }
            let fingerprint = try await protection.background.fingerprint(exactBytes: Data(InventoryStateAcceptance.fixtureValue.utf8))
            let snapshot = await store.snapshot()
            guard ["reviewed", "removed"].contains(InventoryStateAcceptance.phase(snapshot, fingerprint: fingerprint, fixture: acceptanceInventoryFixture)),
                  !snapshot.sourceKinds.isEmpty, snapshot.sourceKinds.count <= InventoryStateAcceptance.maximumRows else {
                throw InventoryStateAcceptance.Failure.unexpectedInventory
            }
            let sessions = Set(snapshot.sourceKinds.keys.map(\.session))
            guard sessions.count == 1, let session = sessions.first, acceptanceInventoryFixture.accepts(session) else {
                throw InventoryStateAcceptance.Failure.unexpectedInventory
            }
            // Selection is derived exclusively from this vault's already admitted source.
            let candidates = sourceProducers.filter { scope, _ in
                scope.provider == acceptanceInventoryFixture.provider && scope.profileID == session.profileID
                    && scope.path == (acceptanceClaudeInventory == nil ? .publicHistory : .versionedTranscript)
            }
            let matching = candidates.filter { scope, _ in
                snapshot.occurrences.values.contains { $0.source.origin.interface == scope.interface }
            }
            // After removal only the source receipt remains; authorized runtime configuration
            // must still supply one unambiguous route, rather than guessing a different host.
            let routes = snapshot.occurrences.isEmpty ? candidates : matching
            guard routes.count == 1, let (scope, route) = routes.first,
                  let permit = await store.processingPermit(), let liveScope = await admission.currentScope() else {
                throw InventoryStateAcceptance.Failure.unsafeState
            }
            let source: CoverageSourceRetryDescriptor
            if let fixture = acceptanceClaudeInventory {
                source = try fixture.retryDescriptor()
                guard source.scope == scope, source.session == session else { throw InventoryStateAcceptance.Failure.unsafeState }
            } else { source = CoverageSourceRetryDescriptor(scope: scope, session: session) }
            let audit = try HistoricalAuditContext(reason: .resume, endingAt: .now)
            let packet = try await route.producer.initialHistoricalCapture(audit: audit, source: source)
            guard let currentRoute = sourceProducers[scope]?.route,
                  currentRoute.scope == route.route.scope, currentRoute.readerVersion == route.route.readerVersion,
                  currentRoute.hostVersion == route.route.hostVersion else {
                throw InventoryStateAcceptance.Failure.unsafeState
            }
            let context = try currentRoute.context(for: packet, trigger: .historyRequest, audit: audit, retry: source)
            acceptanceInventoryReplayExpectedSources = Set(snapshot.sourceKinds.keys)
            acceptanceInventoryReplayAudit = audit
            acceptanceInventoryReplaySource = source
            guard case .inserted(let id) = try await store.enqueue(packet.body, capturedAt: .now, permit: permit,
                scope: liveScope, historicalAudit: audit, workContext: context) else {
                throw InventoryStateAcceptance.Failure.postconditionFailed
            }
            acceptanceInventoryReplayCapture = id
        } catch {
            acceptanceInventoryControlFailure = (error as? InventoryStateAcceptance.Failure) ?? .postconditionFailed
        }
    }

    private func performAcceptanceInventoryControl() async {
        guard let recovery = acceptanceRecovery, recovery.inventoryStateEnabled,
              let store, let protection, acceptanceInventoryControlFailure == nil else { return }
        do {
            let reviewControl = try recovery.controlURL("inventory-review-and-receipt")
            let review = !acceptanceInventoryReviewConsumed
                && recovery.authorizes(reviewControl)
            let removal: Bool
            let acknowledgement: Bool
            if recovery.upgradeStateEnabled && !recovery.upgradeRemovedStateEnabled {
                let control = try recovery.controlURL("inventory-acknowledge-revoked")
                acknowledgement = !acceptanceInventoryAcknowledgementConsumed && recovery.authorizes(control)
                removal = false
            } else {
                let control = try recovery.controlURL("inventory-obsolete-and-remove")
                removal = !acceptanceInventoryRemovalConsumed && recovery.authorizes(control)
                acknowledgement = false
            }
            guard review || removal || acknowledgement else { return }
            // Mark before awaiting a mutation: the normal mutation path refreshes recursively.
            if review { acceptanceInventoryReviewConsumed = true }
            if removal { acceptanceInventoryRemovalConsumed = true }
            if acknowledgement { acceptanceInventoryAcknowledgementConsumed = true }
            guard [review, removal, acknowledgement].filter({ $0 }).count == 1 else {
                throw InventoryStateAcceptance.Failure.unsafeState
            }
            let statistics = try await store.queueStatistics()
            let captures = try await store.captureIdentitiesForTesting()
            try InventoryStateAcceptance.requireIdle(processingStopped: acceptanceProcessingStopped,
                actionBusy: model.actionBusy, queueCount: statistics.count,
                claimedCount: statistics.claimedCount, pendingCount: captures.pending.count)
            let fingerprint = try await protection.background.fingerprint(
                exactBytes: Data(InventoryStateAcceptance.fixtureValue.utf8))
            let snapshot = await store.snapshot()
            try acceptanceClaudeInventory?.requireOriginalSource()
            if review {
                let plan = try InventoryStateAcceptance.reviewPlan(snapshot, fingerprint: fingerprint, fixture: acceptanceInventoryFixture)
                guard try await store.notificationIsEligible(identifier: plan.notificationIdentifier) else {
                    throw InventoryStateAcceptance.Failure.missingPendingReceipt
                }
                // This is an explicit store-level receipt seed, never an OS-delivery observation.
                try await store.recordNotificationDelivery(identifier: plan.notificationIdentifier, state: .delivered)
                acceptanceInventorySeededReceiptKind = plan.receiptKind
                await mutateInventory(.review(plan.confirmed, .confirmedSecret))
                await mutateInventory(.review(plan.falsePositive, .falsePositive))
                guard InventoryStateAcceptance.phase(await store.snapshot(), fingerprint: fingerprint, fixture: acceptanceInventoryFixture) == "reviewed" else {
                    throw InventoryStateAcceptance.Failure.postconditionFailed
                }
                acceptanceInventoryReviewApplied = true
            } else if acknowledgement {
                try InventoryStateAcceptance.requireRetainedRevocation(snapshot, fingerprint: fingerprint)
                await mutateInventory(.acknowledge(fingerprint, .revoked))
                guard InventoryStateAcceptance.phase(await store.snapshot(), fingerprint: fingerprint, upgradeState: true)
                        == "reviewed-revoked7" else { throw InventoryStateAcceptance.Failure.postconditionFailed }
                acceptanceInventoryAcknowledgementApplied = true
            } else {
                guard InventoryStateAcceptance.phase(snapshot, fingerprint: fingerprint, fixture: acceptanceInventoryFixture) == "reviewed" else {
                    throw InventoryStateAcceptance.Failure.unexpectedInventory
                }
                if recovery.upgradeRemovedStateEnabled {
                    try InventoryStateAcceptance.requireRetainedRevocation(snapshot, fingerprint: fingerprint)
                }
                await mutateInventory(.acknowledge(fingerprint, .revoked))
                guard await store.snapshot().obsoleteMarkers[fingerprint]?.acknowledgement == .revoked else {
                    throw InventoryStateAcceptance.Failure.postconditionFailed
                }
                await mutateInventory(.remove(fingerprint))
                guard InventoryStateAcceptance.phase(await store.snapshot(), fingerprint: fingerprint, fixture: acceptanceInventoryFixture) == "removed",
                      try await store.protectedPayloadCountForTesting() == 0 else {
                    throw InventoryStateAcceptance.Failure.postconditionFailed
                }
                acceptanceInventoryRemovalApplied = true
            }
        } catch {
            acceptanceInventoryControlFailure = (error as? InventoryStateAcceptance.Failure) ?? .postconditionFailed
        }
    }

    private func recordWorkflowEvent(_ event: String) {
        guard acceptanceReportURL != nil else { return }
        workflowEvents[event, default: 0] += 1
    }
    private static func controlledFailure(_ error: any Error) -> String {
        if let error = error as? ProtectionBootstrapError {
            switch error {
            case .busy: return "bootstrap-busy"
            case .unsafeJournal: return "bootstrap-unsafe-journal"
            case .journalUnavailable: return "bootstrap-journal-unavailable"
            case .manifestMismatch: return "bootstrap-manifest-mismatch"
            case .commitUnconfirmed: return "bootstrap-commit-unconfirmed"
            case .rollbackIncomplete: return "bootstrap-rollback-incomplete"
            }
        }
        if let error = error as? KeyUnavailable {
            switch error {
            case .unusableKey(let component, let code): return "key-unavailable-\(component.rawValue)-\(code)"
            default: return "key-unavailable"
            }
        }
        if let error = error as? StorageError { return "store-\(String(describing: error))" }
        return "storage-unavailable"
    }
    private func writeOpeningReport(phase: String) {
        guard let url = acceptanceReportURL else { return }
        let report: [String: Any] = ["schemaVersion": 1, "phase": phase,
            "storageReady": model.storageReady, "collectionConfigured": collectionConfigured,
            "processID": ProcessInfo.processInfo.processIdentifier]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
    private func writeAcceptanceCleanup(passed: Bool, failure: String? = nil,
                                        probe: ProtectionCleanupProbeFailure? = nil) {
        guard let url = acceptanceReportURL, let bytes = try? Data(contentsOf: url), bytes.count <= 256 * 1024,
              var report = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
        report["newVaultCleanupPassed"] = passed
        if let failure { report["newVaultCleanupFailure"] = failure }
        if let probe, let encoded = try? JSONEncoder().encode(probe),
           let observation = try? JSONSerialization.jsonObject(with: encoded) {
            report["cleanupProbe"] = observation
        }
        if let output = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? output.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
    private func writeAcceptancePhase(_ phase: String) {
        acceptancePhase = phase
        guard let url = acceptanceReportURL, let bytes = try? Data(contentsOf: url), bytes.count <= 256 * 1024,
              var report = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
        report["acceptancePhase"] = phase
        if let output = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? output.write(to: url, options: .atomic)
        }
    }
    /// Keyed digest that lets a recovery report compare state across restarts without exporting it.
    private func recoveryDigest<T: Encodable & Sendable>(_ value: T?) async -> String? {
        guard let value, let protection else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(value),
              let revision = try? await protection.background.revision(canonicalBytes: bytes) else { return nil }
        return revision.keyedDigest.base64EncodedString()
    }

    private func recoveryDigests<T: Encodable & Sendable>(_ values: [T]) async -> [String] {
        var digests: [String] = []
        for value in values { if let digest = await recoveryDigest(value) { digests.append(digest) } }
        return digests.sorted()
    }

    private func observedRecoveryCheckpoint(_ checkpoint: SourceCheckpoint?) {
        guard acceptanceRecovery != nil, let checkpoint else { return }
        acceptanceLoadedCheckpointIDs.insert(checkpoint.sourceDocumentID)
    }

    private func observedRecoveryCaptureCompletion(_ id: UUID) {
        guard acceptanceRecovery != nil else { return }
        acceptanceCompletedCaptureIDs.insert(id)
    }

    private func recordAcceptanceTransportRejection(_ diagnostic: CaptureRejectionDiagnostic) {
        guard acceptanceReportURL != nil && acceptanceUsesExplicitStore else { return }
        // Keys are closed enums and counters saturate. No upstream bytes or errors enter the report.
        acceptanceTransportRejections[diagnostic] = min(1_000_000,
            (acceptanceTransportRejections[diagnostic] ?? 0) + 1)
    }

    /// Counts from the running signed app, restricted to an explicitly requested test report.
    /// This never exports values, excerpts, source paths, upstream IDs or error text. A recovery
    /// run's private report also carries its own one-time synthetic verification prompt.
    private func writeAcceptanceReport(statistics: StoreQueueStatistics, gaps: [CoverageGap]) async {
        guard let url = acceptanceReportURL, let store else { return }
        let snapshot = await store.snapshot()
        let kinds = Dictionary(grouping: snapshot.occurrences.values, by: { $0.source.contentType.rawValue }).mapValues(\.count)
        let syntheticFingerprint = try? await protection?.background.fingerprint(
            exactBytes: Data(InventoryStateAcceptance.fixtureValue.utf8))
        let syntheticValueID = syntheticFingerprint.flatMap { snapshot.records[$0]?.id }
        let syntheticOccurrences = snapshot.occurrences.values.filter { $0.valueID == syntheticValueID }
        let syntheticKinds = Dictionary(grouping: syntheticOccurrences,
            by: { $0.source.contentType.rawValue }).mapValues(\.count)
        let syntheticChildren = syntheticOccurrences.filter {
            acceptanceNativeChildSources.contains($0.source.identity)
        }
        let historicalProgress = try? await store.historicalProgress()
        var report: [String: Any] = ["schemaVersion": 1, "storageReady": model.storageReady,
            "collectionConfigured": collectionConfigured, "queueCount": statistics.count,
            "valueCount": snapshot.records.count, "occurrenceCount": snapshot.occurrences.count,
            "occurrencesByContentType": kinds, "alertCount": snapshot.alertDecisions.count,
            "gapReasons": Array(Set(gaps.map(\.reason.rawValue)
                + (model.coverageReport?.isTruncated == true ? [CoverageGapReason.budgetExhausted.rawValue] : []))).sorted(),
            // Closed enum/count diagnostics distinguish transport failures from failed
            // source admissions without exporting source identities or captured text.
            "gapCountsByOperation": Dictionary(grouping: gaps,
                by: { $0.operation?.rawValue ?? "unknown" }).mapValues { rows in
                    Dictionary(grouping: rows, by: { $0.reason.rawValue }).mapValues(\.count)
                },
            "scopedGapCount": gaps.filter { $0.scope != nil }.count,
            "coverageReportTruncated": model.coverageReport?.isTruncated ?? false,
            "excludedMediaCount": model.coverageGaps.filter { $0.state == .excluded }.reduce(0) { $0 + $1.count }, "processID": ProcessInfo.processInfo.processIdentifier,
            "syntheticValuePresent": syntheticValueID != nil,
            "syntheticOccurrenceCount": syntheticOccurrences.count,
            "syntheticOccurrencesByContentType": syntheticKinds,
            "syntheticSessionCount": Set(syntheticOccurrences.map { $0.source.identity.session }).count,
            "syntheticOccurrencesByProducerVersionAndContentType": Dictionary(grouping: syntheticOccurrences,
                by: { $0.source.origin.agentVersion }).mapValues { occurrences in
                    Dictionary(grouping: occurrences, by: { $0.source.contentType.rawValue }).mapValues(\.count)
                },
            "syntheticNativeChildOccurrenceCount": syntheticChildren.count,
            "syntheticNativeChildContentTypes": Array(Set(syntheticChildren.map { $0.source.contentType.rawValue })).sorted(),
            "observedAgentVersions": Array(Set(syntheticOccurrences.map { $0.source.origin.agentVersion })).sorted()]
        report["transportRejectionCountsByStageAndReason"] = Dictionary(grouping: acceptanceTransportRejections.keys,
            by: { $0.stage.rawValue }).mapValues { diagnostics in
                Dictionary(uniqueKeysWithValues: diagnostics.map { ($0.reason.rawValue, acceptanceTransportRejections[$0] ?? 0) })
            }
        report["codexIndividualRoleCoverageMeasured"] = acceptanceCodexRoleEvidence != nil
        report["codexIndividualRoleCoveragePassed"] = false
        if let evidence = acceptanceCodexRoleEvidence {
            let roles = await evidence.summary(snapshot: snapshot, syntheticValueID: syntheticValueID)
            report["codexNativeParentChildLinkVerified"] = roles.nativeLinkVerified
            report["codexRoleEvidenceWithinBudget"] = roles.bounded
            report["codexTypedCommittedMarkersByRole"] = roles.markers
            report["codexCommittedContentTypesByRole"] = roles.contentTypes
            report["codexIndividualRoleCoveragePassed"] = roles.complete
        }
        report["historicalProgressMeasurementAvailable"] = historicalProgress != nil
        report["claudeIndividualRoleCoverageMeasured"] = acceptanceClaudeRoleEvidence != nil
        report["claudeIndividualRoleCoveragePassed"] = false
        if let evidence = acceptanceClaudeRoleEvidence {
            let roles = await evidence.summary(snapshot: snapshot, syntheticValueID: syntheticValueID)
            report["claudeNativeParentChildLinkVerified"] = roles.nativeLinkVerified
            report["claudeRoleEvidenceWithinBudget"] = roles.bounded
            report["claudeTypedCommittedMarkersByRole"] = roles.markers
            report["claudeCommittedContentTypesByRole"] = roles.contentTypes
            report["claudeCommittedNativeParentChildPairCountByProducer"] = roles.completePairsByProducer
            report["claudeIndividualRoleCoveragePassed"] = roles.complete
        }
        report["settledHistoricalAuditCount"] = Set((historicalProgress ?? []).map { $0.progress.audit.id }).count
        report["unreadHistoricalProgressCount"] = (historicalProgress ?? []).filter { $0.progress.hasUnreadContent }.count
        report["workflowEvents"] = workflowEvents
        report["alertsByDeliveryState"] = Dictionary(grouping: snapshot.alertDecisions.values,
            by: { $0.delivery.rawValue }).mapValues(\.count)
        report["viewingAuthorized"] = model.viewingAuthorized
        report["revealedValueCount"] = model.revealedContent.count
        report["revealedExcerptCount"] = model.revealedExcerpts.count
        report["revealedSourceMetadataCount"] = model.revealedSourceMetadata.count
        report["windowVisible"] = model.windowVisible
        report["notificationState"] = model.notificationState.label
        report["launchAtLogin"] = model.launchAtLogin
        report["monitoringEnabled"] = model.monitoringEnabled
        if acceptanceRecovery != nil {
            report["recoveryReviewEnabled"] = acceptanceRecovery?.reviewEnabled == true
            if let evidence = acceptanceReview { report["recoveryReviewState"] = evidence.report }
            report["recoveryDesktopBetaEnabled"] = acceptanceRecovery?.desktopBetaEnabled == true
            if let evidence = acceptanceDesktopBeta { report["recoveryDesktopBetaState"] = evidence.report }
            report["recoveryWebResultsEnabled"] = acceptanceRecovery?.webResultsEnabled == true
            if acceptanceRecovery?.webResultsEnabled == true {
                var replay: [String: Any] = ["controlConsumed": acceptanceWebReplayConsumed,
                    "queued": acceptanceWebReplayCapture != nil, "batchCount": acceptanceWebReplayBatches,
                    "cleanBatches": acceptanceWebReplayClean,
                    "expectedSourceCount": acceptanceWebReplayExpectedSources.count,
                    "observedSourceCount": acceptanceWebReplayObservedSources.count,
                    "allExpectedSourcesObserved": !acceptanceWebReplayExpectedSources.isEmpty
                        && acceptanceWebReplayExpectedSources == acceptanceWebReplayObservedSources]
                replay["auditDigest"] = await recoveryDigest(acceptanceWebReplayAudit?.id)
                replay["captureDigest"] = await recoveryDigest(acceptanceWebReplayCapture)
                let progress = historicalProgress?.filter { $0.progress.audit.id == acceptanceWebReplayAudit?.id } ?? []
                replay["completeProgress"] = progress.count == 1 && progress.allSatisfy {
                    $0.completedAt != nil && $0.continuationQueued == false && !$0.progress.hasUnreadContent && $0.progress.bytesRead > 0
                }
                replay["bytesRead"] = progress.reduce(0) { $0 + $1.progress.bytesRead }
                replay["completionObserved"] = acceptanceWebReplayCapture.map { acceptanceCompletedCaptureIDs.contains($0) } ?? false
                if let id = acceptanceWebReplayCapture, let work = try? await store.collectionWork(id: id) {
                    replay["workCompleted"] = work.state == .completed && work.completedAt != nil && work.omissionID == nil
                        && work.context.audit?.auditID == acceptanceWebReplayAudit?.id && work.context.retry == acceptanceWebReplaySource
                } else { replay["workCompleted"] = false }
                replay["successfulReadMatched"] = model.coverageReport?.successfulReads.items.contains { read in
                    read.scope == acceptanceWebReplaySource?.scope && read.operation == .historicalRead
                        && read.readerVersion != nil && read.succeededAt >= (acceptanceWebReplayAudit?.end ?? .distantFuture)
                } ?? false
                report["recoveryWebResultReplay"] = replay
                do {
                    guard let evidence = acceptanceWebResults, let protection else { throw WebResultAcceptance.Failure.reportUnavailable }
                    let payloadRows = try await store.protectedPayloadCountForTesting()
                    let state = try await evidence.report(snapshot: snapshot,
                        payloadRows: payloadRows, cryptography: protection.background)
                    report["recoveryWebResultState"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
                    report["recoveryWebResultFailure"] = evidence.failure?.rawValue
                } catch {
                    report["recoveryWebResultState"] = ["measured": false, "truncated": true]
                    report["recoveryWebResultFailure"] = (error as? WebResultAcceptance.Failure)?.rawValue ?? "reportUnavailable"
                }
            }
            report["recoveryNativeContentEnabled"] = acceptanceRecovery?.nativeContentEnabled == true
            if acceptanceRecovery?.nativeContentEnabled == true {
                var replay: [String: Any] = ["controlConsumed": acceptanceNativeContentReplayConsumed,
                    "queued": acceptanceNativeContentReplayCapture != nil, "batchCount": acceptanceNativeContentReplayBatches,
                    "cleanBatches": acceptanceNativeContentReplayClean,
                    "expectedSourceCount": acceptanceNativeContentReplayExpectedSources.count,
                    "observedSourceCount": acceptanceNativeContentReplayObservedSources.count,
                    "allExpectedSourcesObserved": !acceptanceNativeContentReplayExpectedSources.isEmpty
                        && acceptanceNativeContentReplayExpectedSources == acceptanceNativeContentReplayObservedSources]
                replay["nativeTargetReadAfterControl"] = (acceptanceNativeContent?.nativeReadCount ?? 0) > acceptanceNativeContentReplayNativeReadsBefore
                replay["auditDigest"] = await recoveryDigest(acceptanceNativeContentReplayAudit?.id)
                replay["captureDigest"] = await recoveryDigest(acceptanceNativeContentReplayCapture)
                let progress = historicalProgress?.filter { $0.progress.audit.id == acceptanceNativeContentReplayAudit?.id } ?? []
                replay["completeProgress"] = progress.count == 1 && progress.allSatisfy {
                    $0.completedAt != nil && $0.continuationQueued == false && !$0.progress.hasUnreadContent && $0.progress.bytesRead > 0
                }
                replay["bytesRead"] = progress.reduce(0) { $0 + $1.progress.bytesRead }
                replay["completionObserved"] = acceptanceNativeContentReplayCapture.map { acceptanceCompletedCaptureIDs.contains($0) } ?? false
                if let id = acceptanceNativeContentReplayCapture, let work = try? await store.collectionWork(id: id) {
                    replay["workCompleted"] = work.state == .completed && work.completedAt != nil && work.omissionID == nil
                        && work.context.audit?.auditID == acceptanceNativeContentReplayAudit?.id && work.context.retry == acceptanceNativeContentReplaySource
                } else { replay["workCompleted"] = false }
                replay["successfulReadMatched"] = model.coverageReport?.successfulReads.items.contains { read in
                    read.scope == acceptanceNativeContentReplaySource?.scope && read.operation == .historicalRead
                        && read.readerVersion == acceptanceNativeContent?.descriptor.producerVersion && read.succeededAt >= (acceptanceNativeContentReplayAudit?.end ?? .distantFuture)
                } ?? false
                report["recoveryNativeContentReplay"] = replay
                do {
                    guard let evidence = acceptanceNativeContent, let protection else { throw NativeContentAcceptance.Failure.reportUnavailable }
                    let payloadRows = try await store.protectedPayloadCountForTesting()
                    var excludedGaps: [CoverageGap] = []
                    if evidence.descriptor.fixtureKind == .localImage {
                        let events = try await store.coverageGapEvents(limit: 129)
                        guard !events.isTruncated else { throw NativeContentAcceptance.Failure.reportUnavailable }
                        excludedGaps = events.items.map(\.gap)
                    }
                    let state = try await evidence.report(snapshot: snapshot,
                        payloadRows: payloadRows, gaps: excludedGaps, cryptography: protection.background)
                    report["recoveryNativeContentState"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
                    report["recoveryNativeContentFailure"] = evidence.failure?.rawValue
                } catch {
                    report["recoveryNativeContentState"] = ["measured": false, "truncated": true]
                    report["recoveryNativeContentFailure"] = (error as? NativeContentAcceptance.Failure)?.rawValue ?? "reportUnavailable"
                }
            }
            report["recoveryInventoryStateEnabled"] = acceptanceRecovery?.inventoryStateEnabled == true
            report["recoveryInventoryUpgradeStateEnabled"] = acceptanceRecovery?.upgradeStateEnabled == true
            report["recoveryInventoryRemovedUpgradeStateEnabled"] = acceptanceRecovery?.upgradeRemovedStateEnabled == true
            if acceptanceRecovery?.inventoryStateEnabled == true {
                report["recoveryInventoryReviewControlConsumed"] = acceptanceInventoryReviewConsumed
                report["recoveryInventoryReviewApplied"] = acceptanceInventoryReviewApplied
                report["recoveryInventoryAcknowledgementControlConsumed"] = acceptanceInventoryAcknowledgementConsumed
                report["recoveryInventoryAcknowledgementApplied"] = acceptanceInventoryAcknowledgementApplied
                report["recoveryInventoryRemovalControlConsumed"] = acceptanceInventoryRemovalConsumed
                report["recoveryInventoryRemovalApplied"] = acceptanceInventoryRemovalApplied
                report["recoveryInventoryControlFailure"] = acceptanceInventoryControlFailure?.rawValue
                report["recoveryInventoryStoreReceiptSeeded"] = acceptanceInventorySeededReceiptKind != nil
                report["recoveryInventorySeededReceiptKind"] = acceptanceInventorySeededReceiptKind
                var replay: [String: Any] = ["controlConsumed": acceptanceInventoryReplayConsumed,
                    "queued": acceptanceInventoryReplayCapture != nil,
                    "batchCount": acceptanceInventoryReplayBatches, "cleanBatches": acceptanceInventoryReplayClean,
                    "expectedSourceCount": acceptanceInventoryReplayExpectedSources.count,
                    "observedSourceCount": acceptanceInventoryReplayObservedSources.count,
                    "observedContentTypes": acceptanceInventoryReplayObservedKinds.map(\.rawValue).sorted(),
                    "allExpectedSourcesObserved": !acceptanceInventoryReplayExpectedSources.isEmpty
                        && acceptanceInventoryReplayExpectedSources.isSubset(of: acceptanceInventoryReplayObservedSources)]
                replay["auditDigest"] = await recoveryDigest(acceptanceInventoryReplayAudit?.id)
                replay["captureDigest"] = await recoveryDigest(acceptanceInventoryReplayCapture)
                let progress = historicalProgress?.filter { $0.progress.audit.id == acceptanceInventoryReplayAudit?.id } ?? []
                replay["completeProgress"] = progress.count == 1 && progress.allSatisfy {
                    $0.completedAt != nil && $0.continuationQueued == false && !$0.progress.hasUnreadContent && $0.progress.bytesRead > 0
                }
                replay["bytesRead"] = progress.reduce(0) { $0 + $1.progress.bytesRead }
                replay["completionObserved"] = acceptanceInventoryReplayCapture.map { acceptanceCompletedCaptureIDs.contains($0) } ?? false
                if let id = acceptanceInventoryReplayCapture, let work = try? await store.collectionWork(id: id) {
                    replay["workCompleted"] = work.state == .completed && work.completedAt != nil && work.omissionID == nil
                        && work.context.audit?.auditID == acceptanceInventoryReplayAudit?.id
                        && work.context.retry == acceptanceInventoryReplaySource
                } else { replay["workCompleted"] = false }
                replay["successfulReadMatched"] = model.coverageReport?.successfulReads.items.contains { read in
                    read.scope == acceptanceInventoryReplaySource?.scope && read.operation == .historicalRead
                        && read.readerVersion != nil
                        && (acceptanceClaudeInventory == nil || read.readerVersion == InventoryStateAcceptance.ClaudeFixture.version)
                        && read.succeededAt >= (acceptanceInventoryReplayAudit?.end ?? .distantFuture)
                } ?? false
                report["recoveryInventoryReplay"] = replay
                do {
                    guard let syntheticFingerprint, let protection else { throw InventoryStateAcceptance.Failure.reportUnavailable }
                    let state = try await InventoryStateAcceptance.report(snapshot: snapshot, fingerprint: syntheticFingerprint,
                        store: store, cryptography: protection.background,
                        upgradeState: acceptanceRecovery?.upgradeStateEnabled == true,
                        upgradeRemovedState: acceptanceRecovery?.upgradeRemovedStateEnabled == true,
                        fixture: acceptanceInventoryFixture)
                    report["recoveryInventoryState"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
                } catch {
                    report["recoveryInventoryState"] = ["measured": false, "truncated": true,
                        "failure": "reportUnavailable", "systemNotificationDeliveryEstablished": false]
                }
                if acceptanceRecovery?.upgradeRemovedStateEnabled == true {
                    do {
                        guard let witness = acceptanceInventoryRemovedUpgrade, let protection else {
                            throw InventoryRemovedUpgradeAcceptance.Failure.reportUnavailable
                        }
                        let evidence = try await witness.report(snapshot: snapshot, cryptography: protection.background)
                        report["recoveryInventoryRemovedUpgradeWitness"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence))
                    } catch {
                        report["recoveryInventoryRemovedUpgradeWitness"] = ["measured": false, "truncated": true,
                            "failure": "reportUnavailable"]
                    }
                }
            }
            report["recoveryLoadedExistingManifest"] = acceptanceLoadedExistingManifest
            report["recoveryProcessingStopped"] = acceptanceProcessingStopped
            report["recoveryQueueClaimedCount"] = statistics.claimedCount
            report["recoveryEncryptedQueueBytes"] = statistics.encryptedBytes
            let profiles = await setup?.snapshot()
            let schemas = await setup?.profileSchemaVersions()
            report["recoveryLoadedProfileSchemaVersion"] = schemas?.loaded ?? 0
            report["recoverySavedProfileSchemaVersion"] = schemas?.saved ?? 0
            report["recoveryProfileSchemaMeasurementAvailable"] = schemas?.loaded != nil && schemas?.saved != nil
            let profile = profiles?.profiles[.claudeCode]
            report["recoverySavedSetupConnected"] = profiles?.states[.claudeCode] == .connected
            report["recoveryObservedExecutableVersion"] = profile?.version
            report["recoveryRegistrationDigest"] = await recoveryDigest(profile?.registrationID)
            report["recoveryConnectionProofDigest"] = await recoveryDigest(profile?.connectionProof)
            // Only this private owned-run report includes the one-time synthetic verification prompt.
            report["recoveryVerificationPrompt"] = profiles?.verificationPrompts[.claudeCode]
            let codexProfile = profiles?.profiles[.codex]
            report["recoveryCodexSetupConnected"] = profiles?.states[.codex] == .connected
            report["recoveryCodexProfileInstalled"] = codexProfile?.installed == true
            report["recoveryCodexObservedExecutableVersion"] = codexProfile?.version
            report["recoveryCodexRegistrationDigest"] = await recoveryDigest(codexProfile?.registrationID)
            report["recoveryCodexConnectionProofDigest"] = await recoveryDigest(codexProfile?.connectionProof)
            report["recoveryCodexVerificationPrompt"] = profiles?.verificationPrompts[.codex]
            report["recoveryCodexPollingStopped"] = acceptanceCodexPollingStopped
            report["recoveryClaudePollingStopped"] = acceptanceClaudePollingStopped
            report["recoveryClaudeInventoryFixtureEnabled"] = acceptanceClaudeInventory != nil
            report["recoveryCodexRetryControlConsumed"] = acceptanceCodexRetryControlConsumed
            report["recoveryCodexRetryActionAvailable"] = acceptanceCodexRetryActionAvailable
            report["recoveryCodexRetryInvoked"] = acceptanceCodexRetryInvoked
            report["recoveryCodexRetryTargetWorkDigest"] = await recoveryDigest(acceptanceCodexRetryTarget?.id)
            report["recoveryCodexRetryTargetOmissionDigest"] = await recoveryDigest(acceptanceCodexRetryTarget?.omissionID)
            let coverage = model.coverageReport
            var workRows: [[String: Any]] = []
            var workMeasured = coverage != nil
            for work in (coverage?.work.items ?? []).prefix(128) {
                guard let digest = await recoveryDigest(work.id) else { workMeasured = false; continue }
                var row: [String: Any] = ["workDigest": digest, "state": work.state.rawValue,
                    "operation": work.context.operation.rawValue, "auditWindowPresent": work.context.auditWindow != nil]
                row["readerVersion"] = work.context.readerVersion
                row["admittedAt"] = work.admittedAt.timeIntervalSince1970
                row["omissionDigest"] = await recoveryDigest(work.omissionID)
                row["retrySelectionDigest"] = await recoveryDigest(work.context.retry)
                row["contentIntervalStart"] = work.context.auditWindow?.start.timeIntervalSince1970
                row["contentIntervalEnd"] = work.context.auditWindow?.end.timeIntervalSince1970
                row["recoveryOfDigest"] = await recoveryDigest(work.recoveryOf)
                row["certificateTargetDigest"] = await recoveryDigest(work.recoveryCertificate?.targetWorkID)
                row["certificateWindowStart"] = work.recoveryCertificate?.auditWindow.start.timeIntervalSince1970
                row["certificateWindowEnd"] = work.recoveryCertificate?.auditWindow.end.timeIntervalSince1970
                row["certificateCompletedAt"] = work.recoveryCertificate?.completedAt.timeIntervalSince1970
                for (present, key) in [(work.omissionID != nil, "omissionDigest"),
                    (work.context.retry != nil, "retrySelectionDigest"), (work.recoveryOf != nil, "recoveryOfDigest"),
                    (work.recoveryCertificate != nil, "certificateTargetDigest")] where present && row[key] == nil {
                    workMeasured = false
                }
                workRows.append(row)
            }
            report["recoveryWorkMeasurementAvailable"] = workMeasured
            report["recoveryWorkTruncated"] = coverage?.work.isTruncated == true || (coverage?.work.items.count ?? 0) > 128
            report["recoveryWorkRecords"] = workRows
            var readRows: [[String: Any]] = []
            var readsMeasured = coverage != nil
            for read in (coverage?.successfulReads.items ?? []).prefix(128) {
                guard let digest = await recoveryDigest(read.scope) else { readsMeasured = false; continue }
                var row: [String: Any] = ["scopeDigest": digest, "provider": read.scope.provider.rawValue,
                    "interface": read.scope.interface.rawValue, "path": read.scope.path.rawValue,
                    "operation": read.operation.rawValue, "producerVersions": read.producerVersions.sorted(),
                    "succeededAt": read.succeededAt.timeIntervalSince1970]
                row["readerVersion"] = read.readerVersion
                readRows.append(row)
            }
            report["recoverySuccessfulReadMeasurementAvailable"] = readsMeasured
            report["recoverySuccessfulReadTruncated"] = coverage?.successfulReads.isTruncated == true
                || (coverage?.successfulReads.items.count ?? 0) > 128
            report["recoverySuccessfulReadRecords"] = readRows
            var omissionRows: [[String: Any]] = []
            var omissionsMeasured = coverage != nil
            for omission in (coverage?.omissions.items ?? []).prefix(128) {
                guard let digest = await recoveryDigest(omission.id) else { omissionsMeasured = false; continue }
                omissionRows.append(["omissionDigest": digest, "state": omission.state.rawValue,
                    "reason": omission.gap.reason.rawValue])
            }
            report["recoveryOmissionMeasurementAvailable"] = omissionsMeasured
            report["recoveryOmissionTruncated"] = coverage?.omissions.isTruncated == true || (coverage?.omissions.items.count ?? 0) > 128
            report["recoveryOmissionRecords"] = omissionRows
            report["recoveryManifestDigest"] = await recoveryDigest(protection?.manifest)
            report["recoveryOccurrenceDigests"] = await recoveryDigests(snapshot.occurrences.keys.map { $0 })
            report["recoveryReceiptDigests"] = await recoveryDigests(Array(snapshot.analysisReceipts))
            report["recoveryAlertDigests"] = await recoveryDigests(snapshot.alertDecisions.keys.map { $0 })
            report["recoveryCheckpointDigests"] = await recoveryDigests(Array(acceptanceCheckpointIDs))
            report["recoveryLoadedCheckpointDigests"] = await recoveryDigests(Array(acceptanceLoadedCheckpointIDs))
            let captures = try? await store.captureIdentitiesForTesting()
            report["recoveryCaptureIdentityMeasurementAvailable"] = captures != nil
            report["recoveryPendingCaptureDigests"] = await recoveryDigests(captures?.pending ?? [])
            report["recoveryConsumedCaptureDigests"] = await recoveryDigests(captures?.consumed ?? [])
            report["recoverySuccessfullyProcessedCaptureDigests"] = await recoveryDigests(Array(acceptanceCompletedCaptureIDs))
            report["recoveryNativeChildTypesByProducer"] = Dictionary(grouping: syntheticChildren,
                by: { $0.source.origin.agentVersion }).mapValues { occurrences in
                    Dictionary(grouping: occurrences, by: { $0.source.contentType.rawValue }).mapValues(\.count)
                }
        }
        if let acceptancePhase { report["acceptancePhase"] = acceptancePhase }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        if let deadline = acceptanceDeadline, Date() >= deadline {
            // AppKit termination waits for startup and refresh tasks to finish.
            // Request it from a separate task so neither owned task waits on itself.
            Task { await self.finishAcceptance() }
        }
    }

    private func finishAcceptance() async {
        guard !acceptanceFinishing else { return }
        acceptanceFinishing = true
        acceptanceDeadline = nil
        // Stop producing test work before evaluating the queue-drain criterion.
        writeAcceptancePhase("stopping-live-polling")
        await activeMonitor?.stop()
        await codexMonitor?.stop()
        writeAcceptancePhase("stopping-transport")
        await server.stop()
        writeAcceptancePhase("draining-queue")
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !acceptanceExitWithPending, let store, !Task.isCancelled, ContinuousClock.now < deadline,
              (try? await store.queueStatistics().count) ?? 0 > 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        writeAcceptancePhase("stopping-scanner")
        await pipeline?.stop()
        writeAcceptancePhase("final-report")
        await refresh()
        writeAcceptancePhase("requesting-termination")
        // terminateLater enters AppKit's modal run loop. Leave the Swift executor
        // first so the delegate's async shutdown can run and reply to AppKit.
        NSApplication.shared.perform(#selector(NSApplication.terminate(_:)), with: nil,
                                     afterDelay: 0, inModes: [.common])
    }
    #endif

    func mask(_ reason: ViewingInvalidationReason = .userMask) {
        viewingGeneration = UUID()
        if let viewing { viewing.invalidate(reason) }
        else { protection?.viewingSession.invalidate(reason: reason) }
        sourceOpening.cancel()
        model.clearRevealedContent()
    }

    func shutdown() async {
        terminating = true
        #if DEBUG
        writeAcceptancePhase("stopping")
        #endif
        mask(.windowClose)
        await sourceOpening.shutdown()
        notifications.shutdown()
        let ownedActions = Array(actions.values)
        for action in ownedActions { action.cancel() }
        startup?.cancel()
        refreshTask?.cancel()
        if let store { await store.setMonitoring(enabled: false) }
        await startup?.value
        for action in ownedActions { await action.value }
        #if DEBUG
        writeAcceptancePhase("startup-stopped")
        #endif
        refreshTask?.cancel()
        await activeMonitor?.stop()
        await codexMonitor?.stop()
        await pipeline?.stop()
        #if DEBUG
        writeAcceptancePhase("workers-stopped")
        #endif
        await codexHistory?.close()
        await server.stop()
        await refreshTask?.value
        #if DEBUG
        writeAcceptancePhase("capture-stopped")
        #endif
        await protection?.viewingSession.deauthorize()
        try? await store?.close()
        #if DEBUG
        writeAcceptancePhase("store-closed")
        // A disposable acceptance run may remove only keys created by this process.
        // Existing manifests and normal application launches cannot enter this cleanup.
        if acceptanceReportURL != nil, acceptanceUsesExplicitStore,
           CommandLine.arguments.contains("--acceptance-cleanup-new-vault"),
           let protection {
            do {
                let cleaned = try await protection.removeNewlyCreatedProtectionForTesting()
                writeAcceptanceCleanup(passed: cleaned)
            } catch {
                let probe = error as? ProtectionCleanupProbeFailure
                writeAcceptanceCleanup(passed: false,
                    failure: probe.map { "cleanup-probe-\($0.stage)" } ?? Self.controlledFailure(error), probe: probe)
            }
        }
        writeAcceptancePhase("shutdown-complete")
        #endif
        model.stop()
        removeViewingLifecycle()
    }

    private func startCollection(directory: URL, store: ProtectedStore, cryptography: BackgroundCryptography) async {
        do {
            let selected = await setup?.selectedProfiles() ?? []
            #if DEBUG
            // Exact disposable acceptance sources. Release builds use only profiles chosen in Settings.
            let claudeOverride = try CollectionConfiguration.fromArguments(CommandLine.arguments)
            let codexOverride = try CodexCollectionConfiguration.fromArguments(CommandLine.arguments)
            #else
            let claudeOverride: CollectionConfiguration? = nil
            let codexOverride: CodexCollectionConfiguration? = nil
            #endif
            let claudeConfiguration = claudeOverride
                ?? selected.first(where: { $0.provider == .claudeCode }).map { profile in
                    CollectionConfiguration(profileID: profile.profileID, agentVersion: profile.version,
                        roots: [URL(fileURLWithPath: profile.homePath, isDirectory: true).appendingPathComponent("projects")],
                        activeSources: [], authorizedHosts: profile.authorizedHosts, historicalInterface: profile.interface)
                }
            let codexConfiguration = codexOverride
                ?? selected.first(where: { $0.provider == .codex }).map { profile in
                    let home = URL(fileURLWithPath: profile.homePath, isDirectory: true)
                    return CodexCollectionConfiguration(profileID: profile.profileID, readerVersion: profile.version,
                        t3Version: profile.t3Version, interface: profile.interface, authority: .publicNativeItems,
                        home: home, executable: URL(fileURLWithPath: profile.executablePath),
                        transcriptRoots: [home.appendingPathComponent("sessions"), home.appendingPathComponent("archived_sessions")],
                        activeSources: [], authorizedHosts: profile.authorizedHosts)
                }
            #if DEBUG
            if CommandLine.arguments.contains("--acceptance-recovery-claude-role-evidence") {
                guard acceptanceLoadedExistingManifest, acceptanceClaudeRoleEvidence != nil,
                      claudeOverride == nil, codexConfiguration == nil,
                      let roles = try ClaudeAcceptanceRoles.fromRecoveryArguments(CommandLine.arguments,
                        recovery: acceptanceRecovery, explicitStore: acceptanceUsesExplicitStore,
                        reportRequested: acceptanceReportURL != nil) else {
                    throw ClaudeCollectionError.invalidConfiguration
                }
                try roles.requireMatchingRecoveryProfile(claudeConfiguration)
            }
            #endif
            guard claudeConfiguration != nil || codexConfiguration != nil else {
                await admission.allow([:])
                collectionConfigured = false
                return
            }
            #if DEBUG
            if let recovery = acceptanceRecovery, recovery.reviewEnabled {
                guard acceptanceLoadedExistingManifest, claudeConfiguration == nil,
                      let configuration = codexOverride,
                      CommandLine.arguments.contains("--acceptance-no-profile-catchup"),
                      acceptanceCodexRoleEvidence == nil, acceptanceClaudeRoleEvidence == nil,
                      acceptanceReview == nil else { throw ClaudeCollectionError.invalidConfiguration }
                // The coordinator owns a bounded manual production worker, never a
                // second automatic loop. Its passive reader closes before return.
                acceptanceCodexPollingStopped = true
                acceptanceProcessingStopped = true
                let evidence = ReviewAcceptance()
                acceptanceReview = evidence
                await admission.allow([:])
                try await evidence.run(recovery: recovery, configuration: configuration,
                    store: store, cryptography: cryptography)
                collectionConfigured = true
                return
            }
            if let recovery = acceptanceRecovery, recovery.desktopBetaEnabled {
                guard acceptanceLoadedExistingManifest, claudeConfiguration == nil,
                      let configuration = codexOverride,
                      CommandLine.arguments.contains("--acceptance-no-profile-catchup"),
                      acceptanceCodexRoleEvidence == nil, acceptanceClaudeRoleEvidence == nil,
                      acceptanceDesktopBeta == nil else { throw ClaudeCollectionError.invalidConfiguration }
                // The coordinator owns a bounded manual production worker, never a
                // second automatic loop. Its passive reader closes before return.
                acceptanceCodexPollingStopped = true
                acceptanceProcessingStopped = true
                let evidence = DesktopBetaAcceptance()
                acceptanceDesktopBeta = evidence
                await admission.allow([:])
                try await evidence.run(recovery: recovery, configuration: configuration,
                    store: store, cryptography: cryptography)
                collectionConfigured = true
                return
            }
            if let recovery = acceptanceRecovery, recovery.upgradeRemovedStateEnabled {
                guard claudeConfiguration == nil, let configuration = codexConfiguration,
                      CommandLine.arguments.contains("--acceptance-no-profile-catchup") else {
                    throw InventoryRemovedUpgradeAcceptance.Failure.unsafeScope
                }
                let profile = try InventoryRemovedUpgradeAcceptance.configuredProfile(configuration, recovery: recovery)
                if let existing = acceptanceInventoryRemovedUpgrade {
                    guard existing.profileID == profile else { throw InventoryRemovedUpgradeAcceptance.Failure.unsafeScope }
                } else { acceptanceInventoryRemovedUpgrade = .init(profileID: profile) }
            }
            if let recovery = acceptanceRecovery, recovery.nativeContentEnabled {
                guard claudeConfiguration == nil, let configuration = codexOverride,
                      CommandLine.arguments.contains("--acceptance-no-profile-catchup"),
                      acceptanceCodexRoleEvidence == nil, acceptanceClaudeRoleEvidence == nil else {
                    throw NativeContentAcceptance.Failure.unsafeConfiguration
                }
                let evidence = try NativeContentAcceptance.selected(configuration: configuration, recovery: recovery)
                if let existing = acceptanceNativeContent {
                    guard existing.session == evidence.session, existing.descriptor == evidence.descriptor,
                          existing.producerWorkPath == evidence.producerWorkPath else { throw NativeContentAcceptance.Failure.unsafeConfiguration }
                } else {
                    try await evidence.captureInitial(await store.snapshot(), cryptography: cryptography)
                    acceptanceNativeContent = evidence
                }
            }
            if let recovery = acceptanceRecovery, recovery.webResultsEnabled {
                guard claudeConfiguration == nil, let configuration = codexOverride,
                      CommandLine.arguments.contains("--acceptance-no-profile-catchup"),
                      acceptanceCodexRoleEvidence == nil, acceptanceClaudeRoleEvidence == nil else {
                    throw WebResultAcceptance.Failure.unsafeConfiguration
                }
                let session = try WebResultAcceptance.selectedSession(configuration: configuration, recovery: recovery)
                if let existing = acceptanceWebResults {
                    guard existing.session == session else { throw WebResultAcceptance.Failure.unsafeConfiguration }
                } else {
                    let evidence = WebResultAcceptance(session: session)
                    try await evidence.captureInitial(await store.snapshot(), cryptography: cryptography)
                    acceptanceWebResults = evidence
                }
            }
            #endif
            let detector = try CollectionConfiguration.bundledDetector(
                workingDirectory: directory.appendingPathComponent("scanner-work", isDirectory: true))
            var routes: [CollectionRoute] = []
            var allowedRoutes: [CaptureMetadata: CollectionCaptureRoute] = [:]
            var codexRouters: [CaptureMetadata: CodexEnrolledSessionRouter] = [:]
            let admission = admission
            let enqueue: @Sendable (CapturePacket, Date) async throws -> Void = { packet, date in
                guard let permit = await store.processingPermit(), let scope = await admission.currentScope() else {
                    throw StorageError.monitoringPaused
                }
                let context = try await admission.context(for: packet, trigger: .activePoll,
                    recordAuthority: { try await store.selectAuthority($0, permit: permit) })
                _ = try await store.enqueue(packet.body, capturedAt: date, permit: permit, scope: scope, workContext: context)
            }
            if let configuration = claudeConfiguration {
                let adapter = try ClaudeAdapter(profileID: configuration.profileID, agentVersion: configuration.agentVersion,
                    allowedTranscriptRoots: configuration.roots,
                    checkpointLookup: { [weak self] id in
                        let checkpoint = try await store.checkpoint(documentID: id)
                        #if DEBUG
                        await self?.observedRecoveryCheckpoint(checkpoint)
                        #endif
                        return checkpoint
                    })
                let normalizer = ObservedClaudeNormalizer(adapter: adapter,
                    onObservation: { [weak self] sources in await self?.markCollectionObserved(sources) },
                    onBatch: { [weak self] batch, metadata in await self?.observeCollection(batch, metadata: metadata,
                        path: .versionedTranscript) })
                for interface in configuration.authorizedHosts.sorted(by: { $0.rawValue < $1.rawValue }) {
                    let metadata = try CaptureMetadata(agent: .claudeCode, interface: interface, profileID: configuration.profileID)
                    let route = CollectionCaptureRoute(scope: .init(provider: .claudeCode,
                        profileID: configuration.profileID, interface: interface, path: .versionedTranscript),
                        readerVersion: configuration.agentVersion,
                        hostVersion: interface == .t3 ? selected.first(where: { $0.provider == .claudeCode })?.t3Version : nil)
                    allowedRoutes[metadata] = route
                    sourceProducers[route.scope] = (route, AuthorizedHistoricalCaptureProducer(producer: adapter,
                        provider: .claudeCode, profileID: configuration.profileID, interface: interface))
                    routes.append(.init(provider: .claudeCode, profileID: configuration.profileID,
                                        interface: interface, normalizer: normalizer))
                }
                let historyMetadata = try CaptureMetadata(agent: .claudeCode, interface: configuration.historicalInterface,
                    profileID: configuration.profileID)
                if let route = allowedRoutes[historyMetadata] {
                    historyProducers.append((route, AuthorizedHistoricalCaptureProducer(producer: adapter,
                        provider: .claudeCode, profileID: configuration.profileID, interface: configuration.historicalInterface)))
                }
                activeMonitor = try ClaudeActiveTranscriptMonitor(profileID: configuration.profileID,
                    sources: configuration.activeSources, enqueue: enqueue,
                    onGap: { gap in try? await store.recordCoverageGap(gap) })
            }
            if let configuration = codexConfiguration {
                let work = directory.appendingPathComponent("codex-history-work", isDirectory: true)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let client = CodexAppServerHistoryClient(configuration: try .init(executableURL: configuration.executable,
                    codexHomeURL: configuration.home, workingDirectoryURL: work))
                codexHistory = client
                let selectedHistory: any CodexHistoryReading
                #if DEBUG
                if let evidence = acceptanceNativeContent {
                    selectedHistory = NativeContentAcceptanceHistory(client: client, evidence: evidence)
                } else if let evidence = acceptanceCodexRoleEvidence {
                    selectedHistory = CodexAcceptanceAuditedHistory(client: client, evidence: evidence)
                } else { selectedHistory = client }
                #else
                selectedHistory = client
                #endif
                let interfaces: [AgentInterface] = configuration.authority == .publicNativeItems
                    ? configuration.authorizedHosts.sorted(by: { $0.rawValue < $1.rawValue }) : [configuration.interface]
                for interface in interfaces {
                let adapter = try CodexAdapter(profileID: configuration.profileID, agentVersion: configuration.readerVersion,
                    interface: interface, t3Version: configuration.t3Version,
                    authority: configuration.authority, history: selectedHistory,
                    allowedTranscriptRoots: configuration.transcriptRoots,
                    authorityLookup: { session in try await store.authority(for: session) },
                    authorityRecorder: { choice in
                        guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
                        try await store.selectAuthority(choice, permit: permit)
                    }, checkpointLookup: { id in try await store.checkpoint(documentID: id) })
                let normalizer = ObservedCodexNormalizer(adapter: adapter,
                    onSelection: { [weak self] sources in await self?.selectCodexSources(sources) },
                    onObservation: { [weak self] sources in await self?.markCodexObserved(sources) },
                    onBatch: { [weak self] batch, metadata in await self?.observeCollection(batch, metadata: metadata,
                        path: configuration.authority.collectionPath) })
                let metadata = try CaptureMetadata(agent: .codex, interface: interface, profileID: configuration.profileID)
                let route = CollectionCaptureRoute(scope: .init(provider: .codex, profileID: configuration.profileID,
                    interface: interface, path: configuration.authority.collectionPath),
                    readerVersion: configuration.readerVersion,
                    hostVersion: interface == .t3 ? configuration.t3Version : nil)
                allowedRoutes[metadata] = route
                let hookAdapter = try CodexHookContentAdapter(profileID: configuration.profileID, interface: interface,
                    authorityLookup: { try await store.authority(for: $0) }, bind: { source, revision, date in
                        guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
                        return try await store.bindCodexHookContent(source: source, revision: revision,
                            observedAt: date, permit: permit)
                    })
                let hookNormalizer = ObservedCodexHookNormalizer(adapter: hookAdapter,
                    onBatch: { [weak self] batch, metadata in await self?.observeCollection(batch, metadata: metadata, path: .hook) })
                let router = try CodexEnrolledSessionRouter(native: normalizer, hooks: hookNormalizer,
                    nativeRoute: route, nativeAuthority: configuration.authority,
                    authorityLookup: { try await store.authority(for: $0) })
                codexRouters[metadata] = router
                routes.append(.init(provider: .codex, profileID: configuration.profileID,
                                    interface: interface, normalizer: router))
                sourceProducers[route.scope] = (route, adapter)
                if interface == configuration.interface { historyProducers.append((route, adapter)) }
                }
                codexMonitor = try CodexActiveHistoryMonitor(profileID: configuration.profileID,
                    sources: configuration.activeSources, enqueue: enqueue,
                    authorityLookup: { try await store.authority(for: $0) },
                    onGap: { gap in try? await store.recordCoverageGap(gap) })
            }
            let worker = DetectionPipeline(store: store, cryptography: cryptography,
                normalizer: try CollectionRouter(routes: routes),
                detector: detector, detectorVersion: BetterleaksSecretDetector.version,
                onActivity: { [weak model] activity in await model?.updatePipeline(activity) })
            pipeline = worker
            #if DEBUG
            if acceptanceRecovery != nil {
                await worker.observeCaptureCompletionsForTesting { [weak self] id in
                    await self?.observedRecoveryCaptureCompletion(id)
                }
            }
            #endif
            guard !terminating, !Task.isCancelled else { return }
            collectionConfigured = true
            await admission.allow(allowedRoutes, codexRouters: codexRouters)
            if model.monitoringEnabled {
                await worker.start()
                await startClaudeMonitor()
                await startCodexMonitor()
                await enqueueHistory()
            }
        } catch {
            collectionConfigured = false
            await admission.allow([:])
            model.storageMessage = "Collection unavailable. Check the authorized profile and required collection operations. The vault remains available."
            try? await store.recordCoverageGap(reason: error is DetectorFailure ? .scannerUnavailable : .sourceUnavailable)
        }
    }

    private func markCollectionObserved(_ sources: [ClaudeActiveSource]) async {
        collectionObserved = true
        for source in sources { await activeMonitor?.add(source: source) }
    }

    private func startClaudeMonitor() async {
        #if DEBUG
        if acceptanceClaudePollingStopped { return }
        #endif
        await activeMonitor?.start()
    }

    private func startCodexMonitor() async {
        #if DEBUG
        if acceptanceCodexPollingStopped { return }
        #endif
        await codexMonitor?.start()
    }

    private static func operationAssessed(_ assessment: CollectionAssessment, _ operation: CollectionOperation) -> Bool {
        assessment.canPerform(operation) && !assessment.failures.contains { $0.operation == operation }
    }

    private func observeCollection(_ batch: CollectionBatch, metadata: CaptureMetadata, path: CollectionPath) async {
        #if DEBUG
        if metadata.agent == .codex { await acceptanceCodexRoleEvidence?.collect(batch) }
        if metadata.agent == .claudeCode { await acceptanceClaudeRoleEvidence?.collect(batch) }
        if acceptanceRecovery != nil { acceptanceCheckpointIDs.formUnion(batch.checkpoints.map(\.sourceDocumentID)) }
        if let evidence = acceptanceInventoryRemovedUpgrade, let protection {
            await evidence.observe(batch, metadata: metadata, path: path, cryptography: protection.background)
        }
        if let evidence = acceptanceWebResults, let protection {
            await evidence.observe(batch, metadata: metadata, path: path, cryptography: protection.background)
            if let audit = acceptanceWebReplayAudit, batch.historicalProgress?.audit.id == audit.id {
                acceptanceWebReplayBatches += 1
                let identities = Set(batch.sources.map { $0.record.metadata.identity })
                if acceptanceWebReplayBatches > WebResultAcceptance.maximumSources
                    || acceptanceWebReplayObservedSources.union(identities).count > WebResultAcceptance.maximumSources {
                    acceptanceWebReplayClean = false
                } else { acceptanceWebReplayObservedSources.formUnion(identities) }
                if batch.coverageGaps.contains(where: { $0.requiresAnalysis && ($0.reason != .budgetExhausted || batch.continuation == nil) })
                    || identities.contains(where: { $0.session != evidence.session })
                    || batch.observedReaderVersion == nil || !InventoryStateAcceptance.hasReadEvidence(batch) {
                    acceptanceWebReplayClean = false
                }
            }
        }
        if let evidence = acceptanceNativeContent, let protection {
            await evidence.observe(batch, metadata: metadata, path: path, cryptography: protection.background)
            if let audit = acceptanceNativeContentReplayAudit, batch.historicalProgress?.audit.id == audit.id {
                acceptanceNativeContentReplayBatches += 1
                let identities = Set(batch.sources.map { $0.record.metadata.identity })
                if acceptanceNativeContentReplayBatches > NativeContentAcceptance.maximumSources
                    || acceptanceNativeContentReplayObservedSources.union(identities).count > NativeContentAcceptance.maximumSources {
                    acceptanceNativeContentReplayClean = false
                } else { acceptanceNativeContentReplayObservedSources.formUnion(identities) }
                if !evidence.acceptsCoverage(batch)
                    || identities.contains(where: { $0.session != evidence.session })
                    || batch.observedReaderVersion == nil || !InventoryStateAcceptance.hasReadEvidence(batch) {
                    acceptanceNativeContentReplayClean = false
                }
            }
        }
        if let fixture = acceptanceClaudeInventory,
           (!fixture.validBatch(batch, metadata: metadata, path: path)
                || batch.coverageGaps.contains(where: { $0.requiresAnalysis })) {
            acceptanceInventoryControlFailure = .unexpectedInventory
        }
        if acceptanceRecovery?.inventoryStateEnabled == true,
           metadata.agent == acceptanceInventoryFixture.provider,
           path == (acceptanceClaudeInventory == nil ? .publicHistory : .versionedTranscript),
           let audit = acceptanceInventoryReplayAudit, batch.historicalProgress?.audit.id == audit.id {
            acceptanceInventoryReplayBatches += 1
            let identities = Set(batch.sources.map { $0.record.metadata.identity })
            if acceptanceInventoryReplayBatches > InventoryStateAcceptance.maximumRows
                || acceptanceInventoryReplayObservedSources.union(identities).count > InventoryStateAcceptance.maximumRows {
                acceptanceInventoryReplayClean = false
            } else {
                acceptanceInventoryReplayObservedSources.formUnion(identities)
                acceptanceInventoryReplayObservedKinds.formUnion(batch.sources.map { $0.record.metadata.contentType })
            }
            if batch.coverageGaps.contains(where: { $0.requiresAnalysis && $0.reason != .budgetExhausted })
                || identities.contains(where: { $0.session != acceptanceInventoryReplaySource?.session })
                || (acceptanceClaudeInventory == nil && batch.observedReaderVersion == nil)
                || !InventoryStateAcceptance.hasReadEvidence(batch) {
                acceptanceInventoryReplayClean = false
            }
        }
        if acceptanceReportURL != nil {
            for source in batch.sources where source.record.metadata.identity.session.provider == .claudeCode
                && source.context?.transcriptPath?.contains("/subagents/agent-") == true {
                acceptanceNativeChildSources.insert(source.record.metadata.identity)
            }
        }
        #endif
        let scope = CollectionScope(provider: metadata.agent, profileID: metadata.profileID,
            interface: metadata.interface, path: path)
        let previous = model.collectionAssessments[scope]
        let version = metadata.agent == .codex && path == .publicHistory
            ? batch.observedReaderVersion : model.agentProfiles[metadata.agent]?.version
        // Observations of another executable are no longer evidence; this batch starts afresh.
        var operations = previous.map { $0.observedExecutableVersion == version ? $0.usableOperations : [] } ?? []
        for source in batch.sources {
            switch source.record.metadata.origin.provenance {
            case .live:
                operations.insert(.liveRead)
            case .historical:
                operations.insert(.historicalRead)
            }
        }
        let required = batch.coverageGaps.filter { $0.requiresAnalysis && $0.reason != .budgetExhausted }
        if required.contains(where: { $0.operation == nil }) { operations.removeAll() }
        operations.subtract(required.compactMap(\.operation))
        model.collectionAssessments[scope] = CollectionAssessment(scope: scope,
            observedExecutableVersion: version,
            format: path == .hook ? nil : metadata.agent == .claudeCode ? .claudeTranscript
                : path == .versionedTranscript ? .codexNativeRollout : .codexPublicHistory,
            usableOperations: operations, unavailableContent: Set(required.compactMap(\.contentType)),
            failures: required.map { .init(reason: $0.operation == nil ? .changedContentFormat : .sourceUnavailable,
                                          operation: $0.operation, contentType: $0.contentType) })
    }

    private func markCodexObserved(_ sources: [CodexActiveSource]) async {
        collectionObserved = true
        await selectCodexSources(sources)
    }

    private func selectCodexSources(_ sources: [CodexActiveSource]) async {
        for source in sources { try? await codexMonitor?.addSource(source) }
    }

    /// Starts a new bounded audit of the selected owned profile. It never changes registrations.
    private func retryHistory(_ provider: AgentProvider) async {
        guard model.canPerformCoverageAction(.retryHistory(provider)), let store else { return }
        model.retryingHistory.insert(provider)
        defer { model.retryingHistory.remove(provider) }
        guard (try? await store.queueStatistics().historicalCount) == 0,
              model.monitoringEnabled, !model.monitoringTransition,
              !model.agentSetupBusy.contains(provider) else { return }
        let queued = await enqueueHistory(provider: provider, reassessing: true)
        model.showToast(queued ? "Reading the last 7 days of this agent’s history."
                               : "History could not be queued. Check this agent in Settings.")
        await refresh()
    }

    /// Retries the retained original selection. Readers revalidate its authorized root and authority.
    private func retrySource(_ source: CoverageSourceRetryDescriptor) async {
        guard model.canPerformCoverageAction(.retrySource(source)), let store,
              let route = sourceProducers[source.scope], let permit = await store.processingPermit(),
              let liveScope = await admission.currentScope() else { return }
        let provider = source.scope.provider
        let selectedProfile = model.agentProfiles[provider]
        model.retryingHistory.insert(provider)
        defer { model.retryingHistory.remove(provider) }
        do {
            let related = try await store.retryableCollectionWork(for: source)
            guard !related.contains(where: { $0.state == .queued || $0.state == .processing }) else { return }
            let stalled = related.filter { $0.state == .stalled }
            if !stalled.isEmpty {
                for work in stalled { _ = try await store.retryQueuedWork(id: work.id, permit: permit) }
                model.showToast("Retrying the affected original source.")
            } else {
                let failed = related.filter { $0.state == .terminal }.max { $0.admittedAt < $1.admittedAt }
                #if DEBUG
                if acceptanceCodexRetryControlConsumed, !acceptanceCodexRetryInvoked,
                   let target = acceptanceCodexRetryTarget {
                    guard failed?.id == target.id, target.context.retry?.identifiesSameSource(as: source) == true else {
                        throw StorageError.stateChanged
                    }
                    acceptanceCodexRetryInvoked = true
                }
                #endif
                if let failed, failed.context.auditWindow == nil {
                    model.showToast("This older failure has no recorded time window. Its missing content cannot be verified automatically.")
                    return
                }
                // Freeze the target once. A live responsibility interval may span up to eight days,
                // so recover it with at most two ordinary seven-day reads, one after the other.
                let endings: [Date]
                if let failed { endings = try await store.remainingRecoveryAuditEnds(for: failed.id) }
                else { endings = [.now] }
                guard endings.count <= 2 else { throw StorageError.invalidPayload }
                model.showToast("Retrying the affected original source.")
                for ending in endings {
                    try Task.checkCancellation()
                    guard !terminating, model.monitoringEnabled, !model.monitoringTransition,
                          model.agentProfiles[provider] == selectedProfile,
                          model.agentSetupStates[provider] == .connected,
                          !model.agentSetupBusy.contains(provider),
                          await admission.currentScope() == liveScope,
                          let currentPermit = await store.processingPermit() else { throw StorageError.stateChanged }
                    let audit = try HistoricalAuditContext(id: UUID(), reason: .resume, endingAt: ending)
                    let packet = try await route.producer.initialHistoricalCapture(audit: audit, source: source)
                    guard model.agentProfiles[provider] == selectedProfile,
                          let currentRoute = sourceProducers[source.scope]?.route else { throw StorageError.stateChanged }
                    let context = try currentRoute.context(for: packet, trigger: .historyRequest, audit: audit, retry: source)
                    _ = try await store.enqueue(packet.body, capturedAt: .now, permit: currentPermit, scope: liveScope,
                        historicalAudit: audit, workContext: context, recoveryOf: failed?.id)
                    if let failed {
                        let outcome = try await waitForSourceRecoveryAudit(audit.id, target: failed.id,
                            store: store, liveScope: liveScope, profile: selectedProfile)
                        guard outcome == .certified else {
                            model.showToast(outcome == .stillReading
                                ? "This source is still being read. Retry after it finishes if missing content remains."
                                : "The source was retried, but the missing content is not fully recovered.")
                            await refresh()
                            return
                        }
                    }
                }
                if let failed {
                    let remaining = try await store.remainingRecoveryAuditEnds(for: failed.id)
                    model.showToast(remaining.isEmpty ? "The missing content for this failure was recovered."
                        : "The source was retried, but some missing content remains.")
                }
            }
        } catch is CancellationError {
            return
        } catch {
            model.showToast("This source could not be queued. Check the agent in Settings or export diagnostics.")
        }
        await refresh()
    }

    /// Completion alone is insufficient: require an authenticated certificate for this audit.
    /// Continuations settle atomically, so a clean last page cannot skip preceding failed work.
    private enum RecoveryAuditOutcome { case certified, incomplete, stillReading }
    private func waitForSourceRecoveryAudit(_ auditID: UUID, target: UUID, store: ProtectedStore,
                                           liveScope: LiveCaptureScope, profile: AgentProfileDraft?) async throws -> RecoveryAuditOutcome {
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard !terminating, model.monitoringEnabled, !model.monitoringTransition,
                  let profile, model.agentProfiles[profile.provider] == profile,
                  !model.agentSetupBusy.contains(profile.provider),
                  await admission.currentScope() == liveScope else { throw StorageError.stateChanged }
            let chain = try await store.recoveryCollectionWork(for: target).filter { $0.context.audit?.auditID == auditID }
            if chain.contains(where: { $0.state == .terminal || $0.state == .stalled }) { return .incomplete }
            if !chain.isEmpty, !chain.contains(where: { $0.state == .queued || $0.state == .processing }) {
                return chain.contains { $0.state == .completed && $0.recoveryCertificate?.targetWorkID == target }
                    ? .certified : .incomplete
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return .stillReading
    }

    private func exportCoverageDiagnostics() async {
        guard !terminating, model.canPerformCoverageAction(.exportDiagnostics) else { return }
        model.exportingDiagnostics = true
        defer { model.exportingDiagnostics = false }
        do {
            let bytes: Data
            if model.canExportStartupDiagnostics {
                // No store, journal, or Keychain access on this branch, even after partial startup.
                bytes = try DiagnosticsExport.encoded(model: model)
            } else {
                guard model.storageReady, let store else { return }
                let report = try await store.coverageReport()
                bytes = try DiagnosticsExport.encoded(model: model, report: report)
            }
            guard !terminating, !Task.isCancelled else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Spillcheck-diagnostics.json"
            panel.message = DiagnosticsExport.help
            let response = await withCheckedContinuation { continuation in
                panel.begin { continuation.resume(returning: $0) }
            }
            guard response == .OK, let url = panel.url, !terminating, !Task.isCancelled else { return }
            try bytes.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            model.showToast("Diagnostics exported.")
        } catch {
            model.showToast("Diagnostics could not be exported. Try another location.")
        }
    }

    @discardableResult
    private func enqueueHistory(provider: AgentProvider? = nil, reassessing: Bool = false) async -> Bool {
        #if DEBUG
        // Acceptance against exact owned original-provider sessions must not enumerate unrelated history.
        if CommandLine.arguments.contains("--acceptance-no-profile-catchup") { return false }
        #endif
        guard let store, let permit = await store.processingPermit(),
              let scope = await admission.currentScope(), !terminating else { return false }
        var queued = false
        do {
            let audit = try HistoricalAuditContext(id: reassessing ? UUID() : scope.catchupAuditID ?? UUID(),
                reason: reassessing ? .resume : scope.catchupReason, endingAt: reassessing ? .now : scope.startedAt)
            for route in historyProducers where provider == nil || route.route.scope.provider == provider {
                do {
                    let packet = try await route.producer.initialHistoricalCapture(audit: audit)
                    guard let currentRoute = sourceProducers[route.route.scope]?.route else { throw StorageError.stateChanged }
                    let context = try currentRoute.context(for: packet, trigger: .historyRequest, audit: audit)
                    let insertion = try await store.enqueue(packet.body, capturedAt: .now, permit: permit,
                        scope: scope, historicalAudit: audit, workContext: context)
                    switch insertion {
                    case .inserted, .alreadyQueued: queued = true
                    case .alreadyProcessed: break
                    }
                } catch {
                    try? await store.recordCoverageGap(CoverageGap(reason: .sourceUnavailable,
                        scope: route.route.scope, operation: .historicalRead,
                        diagnosticCode: .unavailableSource, observedAt: .now))
                }
            }
            if queued { model.beginCatchUp() }
        } catch {
            try? await store.recordCoverageGap(reason: .sourceUnavailable)
        }
        return queued
    }

    private func installViewingLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let reason: ViewingInvalidationReason = note.name == NSWorkspace.willSleepNotification ? .sleep : .sessionLock
                MainActor.assumeIsolated {
                    self?.mask(reason)
                }
            })
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.mask(.sessionLock) }
            }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.protection?.viewingSession.expireIfNeeded()
                #if DEBUG
                if let self, self.acceptanceReportURL != nil,
                   self.acceptanceDeadline.map({ Date() >= $0 }) == true
                    || self.acceptanceFinishFile.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                    Task { await self.finishAcceptance() }
                }
                #endif
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) {
            [weak self] event in
            MainActor.assumeIsolated {
                let kind: ViewingActivityKind = event.type == .keyDown ? .keyDown
                    : event.type == .scrollWheel ? .scroll : .mouseDown
                self?.protection?.viewingSession.acceptActivity(kind)
            }
            return event
        }
    }

    private func removeViewingLifecycle() {
        timer?.invalidate()
        timer = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        lockObserver = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    private static func storageFailureMessage(_ error: any Error) -> String {
        if let error = error as? ProtectionBootstrapError {
            switch error {
            case .busy:
                return "Another Spillcheck process is opening this vault. Quit the other instance, then reopen Spillcheck."
            case .rollbackIncomplete:
                return "Vault setup could not finish. Its key identities are preserved; quit and reopen Spillcheck to continue setup with them."
            case .unsafeJournal, .journalUnavailable, .manifestMismatch, .commitUnconfirmed:
                return "Vault startup could not verify its recovery information. Existing keys and storage are preserved."
            }
        }
        if let keyError = error as? KeyUnavailable, case .unusableKey(_, let code) = keyError,
           code == Int(errSecInteractionNotAllowed) {
            return "macOS is preventing access to the vault’s device keys. Make sure your Mac is unlocked, then quit and reopen Spillcheck. Existing storage is preserved."
        }
        if error is KeyUnavailable { return "Vault unavailable. Required device keys could not be loaded. Existing storage is preserved." }
        if let error = error as? StorageError {
            switch error {
            case .manifestMissing, .manifestMismatch, .corruptProtectedState:
                return "Protected storage is unavailable. Its saved identity or data could not be verified. Existing storage is preserved."
            case .unsafeStorageLocation:
                return "Storage location is unavailable. Spillcheck requires a private directory owned by this user."
            default: break
            }
        }
        return "Protected storage could not be opened. Monitoring is paused."
    }
}

/// Opens Terminal on a short script holding the setup command, so starting the test session takes one
/// click. The script holds no credential, is readable only by this user, and is replaced on each use.
@MainActor
private enum SetupTerminal {
    static func open(_ command: SetupCheckCommand) -> Bool {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(AppIdentity.name, isDirectory: true)
        let script = directory.appendingPathComponent("setup-check-\(command.provider.rawValue).command")
        let body = """
            #!/bin/zsh
            # \(AppIdentity.name) setup check: starts a new \(command.provider.displayName) session that sends one test prompt.
            \(command.line)

            """
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(body.utf8).write(to: script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch { return false }
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
