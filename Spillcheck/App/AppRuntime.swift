import AppKit
#if DEBUG
@_spi(Testing) import SpillcheckCore
#else
import SpillcheckCore
#endif

private actor CaptureAdmission {
    private var scope: LiveCaptureScope?
    private var profiles: Set<CaptureMetadata> = []
    func update(_ scope: LiveCaptureScope) { self.scope = scope }
    func currentScope() -> LiveCaptureScope? { scope }
    func allow(_ profiles: Set<CaptureMetadata>) { self.profiles = profiles }
    func accepts(_ packet: CapturePacket) -> Bool { profiles.contains(packet.metadata) }
}

private struct ObservedClaudeNormalizer: CaptureNormalizer {
    let adapter: ClaudeAdapter
    let onObservation: @Sendable ([ClaudeActiveSource]) async -> Void
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        let batch = try await adapter.normalize(packet, capturedAt: capturedAt, cryptography: cryptography)
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
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        // Hooks may arrive before Codex flushes public items. Retain the explicit session
        // selection for polling even when normalization must retry the encrypted capture.
        if adapter.authority == .publicNativeItems,
           packet.metadata.agent == .codex, packet.metadata.profileID == adapter.profileID,
           packet.metadata.interface == adapter.interface,
           adapter.capabilities().contains(where: { $0.validation == .validated }),
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
    private var refreshTask: Task<Void, Never>?
    private var pipeline: DetectionPipeline?
    private var activeMonitor: ClaudeActiveTranscriptMonitor?
    private var codexMonitor: CodexActiveHistoryMonitor?
    private var codexHistory: CodexAppServerHistoryClient?
    private var historyProducers: [any HistoricalCaptureProducer] = []
    private var collectionConfigured = false
    private var collectionObserved = false
    private var collectionDirectory: URL?
    private var setup: AgentSetupController?
    private var viewing: ViewingController?
    private var viewingGeneration = UUID()
    private var sourceOpening = SourceOpeningController()
    private var sourceExecutablePaths: [String] = []
    private let notifications = NotificationController()
    private let loginItem = LoginItemController()
    private var deliveringNotifications = false
    /// Notification delivery follows the requested monitoring state, held closed while an
    /// inventory change reconciles presentations. Both inputs change synchronously on this actor.
    private var monitoringRequested = true
    private var inventoryMutationActive = false
    private var actions: [UUID: Task<Void, Never>] = [:]
    var onShowInventory: (() -> Void)?
    #if DEBUG
    private var acceptanceReportURL: URL?
    private var acceptanceDeadline: Date?
    private var acceptanceFinishing = false
    private var acceptancePhase: String?
    private var workflowEvents: [String: Int] = [:]
    private var lastReportedViewingState: InventoryViewingState = .masked
    #endif
    private var terminating = false
    private var timer: Timer?
    private var eventMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        installWorkflowActions()
    }

    func start() {
        installViewingLifecycle()
        #if DEBUG
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--acceptance-report"), args.indices.contains(index + 1),
           let secondsIndex = args.firstIndex(of: "--acceptance-seconds"), args.indices.contains(secondsIndex + 1),
           let seconds = Double(args[secondsIndex + 1]), seconds >= 2, seconds <= 120 {
            acceptanceReportURL = URL(fileURLWithPath: args[index + 1])
            acceptanceDeadline = args.contains("--acceptance-hold") ? nil : Date().addingTimeInterval(seconds)
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
            let selectedDirectory = try overrideDirectory ?? AppStorageLocation.prepare(in: applicationSupport)
            #else
            let selectedDirectory = try AppStorageLocation.prepare(in: applicationSupport)
            #endif
            let directory = selectedDirectory
            let probe = try await Task.detached { try ProtectedStore.probe(at: directory) }.value
            #if DEBUG
            writeOpeningReport(phase: "loading-device-keys")
            #endif
            try Task.checkCancellation()
            let services = try await ProtectionBootstrap.prepare(manifest: probe.manifest, storeState: probe.state,
                configuration: ProtectionConfiguration(accessGroup: accessGroup))
            protection = services
            #if DEBUG
            writeOpeningReport(phase: "opening-encrypted-store")
            #endif
            try Task.checkCancellation()
            let opened = try await ProtectedStore.open(at: directory, cryptography: services.background)
            store = opened
            collectionDirectory = directory
            try await configureWorkflow(store: opened, services: services, directory: directory)
            if terminating || Task.isCancelled {
                await opened.setMonitoring(enabled: false)
                try await opened.close()
                return
            }
            let admission = admission
            let currentSetup = setup
            await admission.update(try LiveCaptureScope(startedAt: .now,
                catchupReason: probe.manifest == nil ? .firstLaunch : .restart))
            try await server.start(at: directory.appendingPathComponent("capture.sock"),
                accepting: { await opened.processingPermit() != nil },
                onCapture: { packet in
                    // Resume installs its scope before rotating the store generation.
                    // Fetching the permit first makes any intervening pause/resume stale.
                    guard let permit = await opened.processingPermit() else { throw StorageError.monitoringPaused }
                    guard let scope = await admission.currentScope() else { throw StorageError.monitoringPaused }
                    // No capture callback returns successfully before the encrypted transaction commits.
                    guard await admission.accepts(packet) else { throw CaptureTransportError.invalidMetadata }
                    let insertion = try await opened.enqueue(packet.body, capturedAt: .now, permit: permit, scope: scope)
                    let queueID: UUID
                    switch insertion {
                    case .inserted(let id), .alreadyQueued(let id), .alreadyProcessed(let id): queueID = id
                    }
                    await currentSetup?.received(packet, durableQueueID: queueID)
                }, onGap: { reason in
                    try? await opened.recordCoverageGap(reason: reason)
                })
            if terminating || Task.isCancelled {
                await opened.setMonitoring(enabled: false)
                await server.stop()
                try await opened.close()
                return
            }
            model.storageReady = true
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
        model.loadSnapshot(await store.snapshot())
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
        notifications.onPermissionChange = { [weak self] in self?.publishNotificationPermission() }
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
        guard let setup, !model.agentSetupBusy.contains(provider), !model.monitoringTransition else { return }
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
            case .verify:
                guard model.monitoringEnabled else {
                    model.agentSetupMessages[provider] = "Resume monitoring before verifying a synthetic prompt."
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
        await admission.allow([])
        await activeMonitor?.stop()
        await codexMonitor?.stop()
        await pipeline?.stop()
        await codexHistory?.close()
        activeMonitor = nil; codexMonitor = nil; pipeline = nil; codexHistory = nil
        historyProducers.removeAll()
        collectionConfigured = false; collectionObserved = false
        await startCollection(directory: directory, store: store, cryptography: protection.background)
    }

    private func refreshSetup(updateProfiles: Bool = false) async {
        guard let setup, !terminating else { return }
        await setup.check()
        let snapshot = await setup.snapshot()
        if updateProfiles { model.agentProfiles = snapshot.profiles }
        model.agentSetupStates = snapshot.states
        model.agentSetupMessages = snapshot.messages
        model.verificationPrompts = snapshot.verificationPrompts
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [snapshot.profiles[.codex]?.executablePath ?? home.appendingPathComponent(".local/bin/codex").path,
                     snapshot.profiles[.claudeCode]?.executablePath ?? home.appendingPathComponent(".local/bin/claude").path]
        if sourceExecutablePaths != paths {
            sourceOpening.cancel()
            sourceExecutablePaths = paths
            sourceOpening = SourceOpeningController(codexExecutableURL: URL(fileURLWithPath: paths[0]),
                                                     claudeExecutableURL: URL(fileURLWithPath: paths[1]))
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
        model.loginBusy = loginItem.isChanging
        model.loginMessage = loginItem.errorMessage ?? loginItem.state.message
    }

    private func deliverNotifications() async {
        guard !deliveringNotifications, let store, !terminating, model.monitoringEnabled else { return }
        deliveringNotifications = true
        defer { deliveringNotifications = false }
        do {
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
            await activeMonitor?.start()
            await codexMonitor?.start()
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
            _ = try await store.maintainQueue()
            let statistics = try await store.queueStatistics()
            // Status reflects current conditions: recent gaps and each profile's latest audit.
            // Persistent problems keep recording gaps; older rows stay listed until pruned.
            let gaps = try await store.coverageGaps(since: Date().addingTimeInterval(-Self.recentGapWindow))
            let progress = try await store.historicalProgress()
            model.historyProgress = progress
            model.updateQueue(count: statistics.count)
            let latestAudits = Dictionary(grouping: progress, by: { "\($0.provider.rawValue)\u{0}\($0.profileID)" })
                .compactMap { $0.value.max { $0.progress.audit.end < $1.progress.audit.end } }
            let unreadHistory = latestAudits.contains { $0.progress.hasUnreadContent }
            model.updateCoverage(gaps.isEmpty && !unreadHistory
                ? (collectionObserved ? .complete : .notConfigured)
                : .partial(gaps.isEmpty ? [.init(reason: .budgetExhausted)] : gaps))
            model.loadSnapshot(await store.snapshot())
            await refreshSetup()
            await deliverNotifications()
            #if DEBUG
            await writeAcceptanceReport(statistics: statistics, gaps: gaps)
            #endif
        } catch {
            model.storageMessage = Self.storageFailureMessage(error)
        }
    }

    #if DEBUG
    private func recordWorkflowEvent(_ event: String) {
        guard acceptanceReportURL != nil else { return }
        workflowEvents[event, default: 0] += 1
    }
    private static func controlledFailure(_ error: any Error) -> String {
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
        guard let url = acceptanceReportURL, let bytes = try? Data(contentsOf: url), bytes.count <= 64 * 1024,
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
        guard let url = acceptanceReportURL, let bytes = try? Data(contentsOf: url), bytes.count <= 64 * 1024,
              var report = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
        report["acceptancePhase"] = phase
        if let output = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? output.write(to: url, options: .atomic)
        }
    }
    /// Counts from the running signed app, restricted to an explicitly requested test report.
    /// This never exports values, excerpts, source paths, upstream IDs or error text.
    private func writeAcceptanceReport(statistics: StoreQueueStatistics, gaps: [CoverageGap]) async {
        guard let url = acceptanceReportURL, let store else { return }
        let snapshot = await store.snapshot()
        let kinds = Dictionary(grouping: snapshot.occurrences.values, by: { $0.source.contentType.rawValue }).mapValues(\.count)
        let syntheticFingerprint = try? await protection?.background.fingerprint(
            exactBytes: Data("ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS".utf8))
        let syntheticValueID = syntheticFingerprint.flatMap { snapshot.records[$0]?.id }
        let syntheticOccurrences = snapshot.occurrences.values.filter { $0.valueID == syntheticValueID }
        let syntheticKinds = Dictionary(grouping: syntheticOccurrences,
            by: { $0.source.contentType.rawValue }).mapValues(\.count)
        var report: [String: Any] = ["schemaVersion": 1, "storageReady": model.storageReady,
            "collectionConfigured": collectionConfigured, "queueCount": statistics.count,
            "valueCount": snapshot.records.count, "occurrenceCount": snapshot.occurrences.count,
            "occurrencesByContentType": kinds, "alertCount": snapshot.alertDecisions.count,
            "gapReasons": Array(Set(gaps.map(\.reason.rawValue))).sorted(), "processID": ProcessInfo.processInfo.processIdentifier,
            "syntheticValuePresent": syntheticValueID != nil,
            "syntheticOccurrenceCount": syntheticOccurrences.count,
            "syntheticOccurrencesByContentType": syntheticKinds,
            "syntheticSessionCount": Set(syntheticOccurrences.map { $0.source.identity.session }).count,
            "observedAgentVersions": Array(Set(syntheticOccurrences.map { $0.source.origin.agentVersion })).sorted()]
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
        while let store, !Task.isCancelled, ContinuousClock.now < deadline,
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
        if acceptanceReportURL != nil, CommandLine.arguments.contains("--acceptance-cleanup-new-vault"),
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
                        activeSources: [])
                }
            let codexConfiguration = codexOverride
                ?? selected.first(where: { $0.provider == .codex }).map { profile in
                    let home = URL(fileURLWithPath: profile.homePath, isDirectory: true)
                    return CodexCollectionConfiguration(profileID: profile.profileID, readerVersion: profile.version,
                        t3Version: profile.t3Version, interface: profile.interface, authority: .publicNativeItems,
                        home: home, executable: URL(fileURLWithPath: profile.executablePath),
                        transcriptRoots: [home.appendingPathComponent("sessions"), home.appendingPathComponent("archived_sessions")],
                        activeSources: [])
                }
            guard claudeConfiguration != nil || codexConfiguration != nil else {
                await admission.allow([])
                collectionConfigured = false
                return
            }
            let detector = try CollectionConfiguration.bundledDetector(
                workingDirectory: directory.appendingPathComponent("scanner-work", isDirectory: true))
            var routes: [CollectionRoute] = []
            var allowedProfiles = Set<CaptureMetadata>()
            let admission = admission
            let enqueue: @Sendable (CapturePacket, Date) async throws -> Void = { packet, date in
                guard let permit = await store.processingPermit(), let scope = await admission.currentScope() else {
                    throw StorageError.monitoringPaused
                }
                _ = try await store.enqueue(packet.body, capturedAt: date, permit: permit, scope: scope)
            }
            if let configuration = claudeConfiguration {
                let adapter = try ClaudeAdapter(profileID: configuration.profileID, agentVersion: configuration.agentVersion,
                    allowedTranscriptRoots: configuration.roots,
                    checkpointLookup: { id in try await store.checkpoint(documentID: id) })
                let normalizer = ObservedClaudeNormalizer(adapter: adapter,
                    onObservation: { [weak self] sources in await self?.markCollectionObserved(sources) })
                for interface in [AgentInterface.standaloneCLI, .t3] {
                    allowedProfiles.insert(try CaptureMetadata(agent: .claudeCode, interface: interface,
                                                               profileID: configuration.profileID))
                    routes.append(.init(provider: .claudeCode, profileID: configuration.profileID,
                                        interface: interface, normalizer: normalizer))
                }
                historyProducers.append(adapter)
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
                let adapter = try CodexAdapter(profileID: configuration.profileID, agentVersion: configuration.readerVersion,
                    interface: configuration.interface, t3Version: configuration.t3Version,
                    authority: configuration.authority, history: client,
                    allowedTranscriptRoots: configuration.transcriptRoots,
                    authorityLookup: { session in try await store.authority(for: session) },
                    authorityRecorder: { choice in
                        guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
                        try await store.selectAuthority(choice, permit: permit)
                    }, checkpointLookup: { id in try await store.checkpoint(documentID: id) })
                let normalizer = ObservedCodexNormalizer(adapter: adapter,
                    onSelection: { [weak self] sources in await self?.selectCodexSources(sources) },
                    onObservation: { [weak self] sources in await self?.markCodexObserved(sources) })
                routes.append(.init(provider: .codex, profileID: configuration.profileID,
                                    interface: configuration.interface, normalizer: normalizer))
                allowedProfiles.insert(try CaptureMetadata(agent: .codex, interface: configuration.interface,
                                                           profileID: configuration.profileID))
                historyProducers.append(adapter)
                codexMonitor = try CodexActiveHistoryMonitor(profileID: configuration.profileID,
                    sources: configuration.activeSources, enqueue: enqueue,
                    onGap: { gap in try? await store.recordCoverageGap(gap) })
            }
            let worker = DetectionPipeline(store: store, cryptography: cryptography,
                normalizer: try CollectionRouter(routes: routes),
                detector: detector, detectorVersion: BetterleaksSecretDetector.version,
                onActivity: { [weak model] activity in await model?.updatePipeline(activity) })
            pipeline = worker
            guard !terminating, !Task.isCancelled else { return }
            collectionConfigured = true
            await admission.allow(allowedProfiles)
            if model.monitoringEnabled {
                await worker.start()
                await activeMonitor?.start()
                await codexMonitor?.start()
                await enqueueHistory()
            }
        } catch {
            collectionConfigured = false
            await admission.allow([])
            model.storageMessage = "Collection unavailable. Select a supported agent version and authorized profile. The vault remains available."
            try? await store.recordCoverageGap(reason: error is DetectorFailure ? .scannerUnavailable : .unsupportedVersion)
        }
    }

    private func markCollectionObserved(_ sources: [ClaudeActiveSource]) async {
        collectionObserved = true
        for source in sources { await activeMonitor?.add(source: source) }
    }

    private func markCodexObserved(_ sources: [CodexActiveSource]) async {
        collectionObserved = true
        await selectCodexSources(sources)
    }

    private func selectCodexSources(_ sources: [CodexActiveSource]) async {
        for source in sources { try? await codexMonitor?.addSource(source) }
    }

    private func enqueueHistory() async {
        #if DEBUG
        // Acceptance against exact owned original-provider sessions must not enumerate unrelated history.
        if CommandLine.arguments.contains("--acceptance-no-profile-catchup") { return }
        #endif
        guard let store, let permit = await store.processingPermit(),
              let scope = await admission.currentScope(), !terminating else { return }
        do {
            let audit = try HistoricalAuditContext(id: scope.catchupAuditID ?? UUID(),
                reason: scope.catchupReason, endingAt: scope.startedAt)
            for producer in historyProducers {
                let packet = try await producer.initialHistoricalCapture(audit: audit)
                _ = try await store.enqueue(packet.body, capturedAt: .now, permit: permit,
                    scope: scope, historicalAudit: audit)
            }
        } catch {
            try? await store.recordCoverageGap(reason: .sourceUnavailable)
        }
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
                if let self, let deadline = self.acceptanceDeadline, Date() >= deadline {
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
    }

    static let recentGapWindow: TimeInterval = 24 * 60 * 60

    private static func storageFailureMessage(_ error: any Error) -> String {
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
