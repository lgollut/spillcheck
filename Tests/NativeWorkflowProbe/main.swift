import Foundation
import Security
@testable import SpillcheckCore

private enum ProbeFailure: Error { case failed(String), key }

@MainActor
private func require(_ condition: Bool, _ name: String) throws {
    guard condition else { throw ProbeFailure.failed(name) }
}

@MainActor
private final class ProbePrivateKey: InventoryPrivateKeyAccess {
    private let key: SecKey
    let exportedPublicKey: Data
    var isAuthorized = false
    var authorizations = 0
    var cancellation = false
    var hold = false
    var gate: CheckedContinuation<Void, Never>?

    init() throws {
        guard let key = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256,
        ] as CFDictionary, nil), let publicKey = SecKeyCopyPublicKey(key),
              let bytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { throw ProbeFailure.key }
        self.key = key
        exportedPublicKey = bytes
    }

    func authorize(localizedReason: String) async throws {
        authorizations += 1
        if hold { await withCheckedContinuation { gate = $0 } }
        if cancellation { throw ViewingAuthorizationError.cancelled }
        // Deliberately ignore task cancellation, as a framework completion may arrive late.
        isAuthorized = true
    }

    func decrypt(_ wrappedKey: Data) async throws -> Data {
        guard isAuthorized, let bytes = SecKeyCreateDecryptedData(key,
            .eciesEncryptionStandardVariableIVX963SHA256AESGCM, wrappedKey as CFData, nil) as Data? else {
            throw ViewingAuthorizationError.denied(code: -1)
        }
        return bytes
    }

    func deauthorize() async { isAuthorized = false }
    func release() { hold = false; gate?.resume(); gate = nil }
}

@MainActor
private final class ViewingFixture {
    let key: ProbePrivateKey
    let session: InventoryViewingSession
    let crypto: BackgroundCryptography
    var ledger = InventoryLedger()
    var payloads: [ProtectedPayloadReference: ProtectedPayload] = [:]
    let valueID: UUID
    let occurrenceID: UUID
    var controller: ViewingController!

    init() async throws {
        let key = try ProbePrivateKey()
        self.key = key
        let manifest = ProtectionManifest.fresh(identifierPrefix: "com.spillcheck.native-probe")
        crypto = try BackgroundCryptography(manifest: manifest, queueKey: Data(repeating: 0x17, count: 32),
            identityKey: Data(repeating: 0x29, count: 32), inventoryPublicKey: key.exportedPublicKey)
        session = InventoryViewingSession(manifest: manifest, privateKey: key)
        let sourceReference = ProtectedPayloadReference()
        let sourceSession = try SessionIdentity(provider: .codex, profileID: "synthetic", sessionID: UUID().uuidString)
        let source = try SourceRecord(metadata: SourceRecordMetadata(
            identity: SourceIdentity(session: sourceSession, itemID: "synthetic-item"),
            contentType: .toolOutput, contentTime: Date(), observedAt: Date(), protectedMetadata: sourceReference,
            origin: SourceOrigin(adapterID: "synthetic", adapterVersion: "1", agentVersion: "synthetic",
                interface: .standaloneCLI, provenance: .live, canonicalization: .sharedUpstreamIdentity)),
            revision: ContentRevision(keyedDigest: Data(repeating: 0x12, count: 32)),
            segments: [SourceSegment(id: "text", utf8: Data("SYNTHETIC-NATIVE-VIEWING-Ä-🔐".utf8))])
        let location = try CanonicalLocation(segmentID: "text", range: UTF8Range(0, source.segments[0].utf8.count))
        let valueReference = ProtectedPayloadReference(), excerptReference = ProtectedPayloadReference()
        let detection = try LocatedDetection(extraction: ExactExtraction(valueUTF8: source.segments[0].utf8,
            location: location, in: source), in: source,
            fingerprint: ValueFingerprint(keyedDigest: Data(repeating: 0x23, count: 32)),
            evidence: [DetectionEvidence(rule: RuleIdentity(id: "synthetic", version: "1"), signal: .strong,
                reason: .recognizedFormat, category: .token)], protectedValue: valueReference,
            protectedExcerpt: excerptReference)
        let inserted = try ledger.ingest(SourceAnalysis(source: source, detectorVersion: "1", detections: [detection]))
        guard let valueID = inserted.createdValueIDs.first,
              let occurrenceID = inserted.insertedOccurrenceIDs.first else { throw ProbeFailure.failed("fixture") }
        self.valueID = valueID
        self.occurrenceID = occurrenceID
        for (reference, kind, bytes) in [
            (valueReference, ProtectedPayloadKind.value, source.segments[0].utf8),
            (excerptReference, .excerpt, try JSONEncoder().encode(RetainedExcerpt(text: "synthetic context", clipped: true))),
            (sourceReference, .sourceMetadata, try JSONEncoder().encode(RetainedSourceContext(
                sessionIdentifier: sourceSession.sessionID, title: "synthetic title", projectPath: "/synthetic/project"))),
        ] {
            payloads[reference] = try await crypto.sealInventory(bytes,
                binding: PayloadBinding(reference: reference, ownerID: reference.id, kind: kind))
        }
        controller = ViewingController(session: session, loadPayload: { [weak self] reference in
            self?.payloads[reference]
        }, selectionIsCurrent: { [weak self] selection in
            self.map { selection.isCurrent(in: $0.ledger.snapshot) } ?? false
        })
        session.onInvalidate = { [weak self] reason in self?.controller.didInvalidate(reason) }
        controller.select(valueID: valueID)
    }

    func selection() throws -> InventoryRevealSelection {
        try InventoryRevealSelection.retainedValue(in: ledger.snapshot, valueID: valueID)
    }

    func addSecondOccurrence() async throws -> UUID {
        guard let first = ledger.occurrences[occurrenceID], let record = ledger.records.values.first else {
            throw ProbeFailure.failed("second-occurrence-fixture")
        }
        let metadataReference = ProtectedPayloadReference(), excerptReference = ProtectedPayloadReference()
        let source = try SourceRecord(metadata: SourceRecordMetadata(
            identity: SourceIdentity(session: first.source.identity.session, itemID: "synthetic-item-B"),
            contentType: first.source.contentType, contentTime: first.source.contentTime,
            observedAt: first.source.observedAt, protectedMetadata: metadataReference, origin: first.source.origin),
            revision: ContentRevision(keyedDigest: Data(repeating: 0x34, count: 32)),
            segments: [SourceSegment(id: "text", utf8: Data("SYNTHETIC-NATIVE-VIEWING-Ä-🔐".utf8))])
        let location = try CanonicalLocation(segmentID: "text", range: UTF8Range(0, source.segments[0].utf8.count))
        let detection = try LocatedDetection(extraction: ExactExtraction(valueUTF8: source.segments[0].utf8,
            location: location, in: source), in: source, fingerprint: record.fingerprint, evidence: first.evidence,
            protectedValue: ProtectedPayloadReference(), protectedExcerpt: excerptReference)
        let transition = try ledger.ingest(SourceAnalysis(source: source, detectorVersion: "1", detections: [detection]))
        guard let id = transition.insertedOccurrenceIDs.first,
              ledger.occurrences[id]?.valueID == valueID else { throw ProbeFailure.failed("same-value-occurrence") }
        payloads[excerptReference] = try await crypto.sealInventory(
            JSONEncoder().encode(RetainedExcerpt(text: "synthetic context B", clipped: false)),
            binding: PayloadBinding(reference: excerptReference, ownerID: excerptReference.id, kind: .excerpt))
        payloads[metadataReference] = try await crypto.sealInventory(
            JSONEncoder().encode(RetainedSourceContext(sessionIdentifier: first.source.identity.session.sessionID,
                title: "synthetic title B")),
            binding: PayloadBinding(reference: metadataReference, ownerID: metadataReference.id, kind: .sourceMetadata))
        return id
    }
}

@MainActor
private final class ProbeNotificationSystem: NotificationSystem {
    var permission = NotificationPermission.allowed
    var permissionAfterRequestFailure: NotificationPermission?
    var requests = 0
    var submits = 0
    var submitted: [MaskedNotification] = []
    var identifiers: Set<String> = []
    var removedPending: [String] = []
    var removedDelivered: [String] = []
    var hold = false
    var gate: CheckedContinuation<Void, Never>?
    func currentPermission() async -> NotificationPermission { permission }
    func requestPermission() async throws {
        requests += 1
        if let permissionAfterRequestFailure {
            permission = permissionAfterRequestFailure
            throw ProbeFailure.failed("synthetic-permission-request")
        }
        permission = .allowed
    }
    func existingIdentifiers() async -> Set<String> { identifiers }
    func submit(_ notification: MaskedNotification) async throws {
        submits += 1
        if hold { await withCheckedContinuation { gate = $0 } }
        identifiers.insert(notification.identifier)
        submitted.append(notification)
    }
    func removePending(_ identifiers: [String]) { removedPending += identifiers; self.identifiers.subtract(identifiers) }
    func removeDelivered(_ identifiers: [String]) { removedDelivered += identifiers; self.identifiers.subtract(identifiers) }
    func release() { hold = false; gate?.resume(); gate = nil }
}

@MainActor
private final class ProbeEligibility {
    var gate: CheckedContinuation<Void, Never>?
    func check() async -> Bool {
        await withCheckedContinuation { gate = $0 }
        return true
    }
    func release() { gate?.resume(); gate = nil }
}

@MainActor
private func until(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while !predicate() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProbeFailure.failed("probe-timeout") }
        try await Task.sleep(for: .milliseconds(1))
    }
}

@main
private struct NativeWorkflowProbe {
    @MainActor static func main() async {
        do {
            var checks: [String] = []
            let value = try await ViewingFixture()
            try require(value.controller.content.value == nil, "initial-masked")
            await value.controller.reveal(try value.selection())
            try require(value.controller.content.value == "SYNTHETIC-NATIVE-VIEWING-Ä-🔐", "exact-value")
            try require(value.key.authorizations == 1, "authentication-required")
            await value.controller.reveal(try .occurrence(in: value.ledger.snapshot, occurrenceID: value.occurrenceID))
            try require(value.controller.content.excerpts[value.occurrenceID]?.clipped == true, "excerpt")
            try require(value.controller.content.sourceMetadata[value.occurrenceID]?.title == "synthetic title", "source")
            try require(value.key.authorizations == 1, "viewing-session-reuse")
            value.controller.invalidate(.windowClose)
            try require(value.controller.content.value == nil && value.controller.content.excerpts.isEmpty
                && value.controller.content.sourceMetadata.isEmpty && value.session.revealed.isEmpty, "immediate-mask")
            checks.append("authenticated-exact-fields-and-window-mask")

            let cancelled = try await ViewingFixture()
            cancelled.key.cancellation = true
            await cancelled.controller.reveal(try cancelled.selection())
            try require(cancelled.controller.state == .cancelled && cancelled.controller.content.value == nil
                && cancelled.session.revealed.isEmpty, "cancelled-authentication")
            checks.append("cancelled-authentication")

            for reason in [ViewingInvalidationReason.sleep, .sessionLock, .userMask] {
                let delayed = try await ViewingFixture()
                delayed.key.hold = true
                let request = try delayed.selection()
                let task = Task { await delayed.controller.reveal(request) }
                try await until { delayed.key.gate != nil }
                delayed.controller.invalidate(reason)
                delayed.key.release()
                await task.value
                try require(delayed.controller.content.value == nil && delayed.session.revealed.isEmpty
                    && delayed.controller.state == .masked, "late-lifecycle-completion")
                checks.append("late-authentication-after-\(reason.rawValue)")
            }

            let changed = try await ViewingFixture()
            changed.key.hold = true
            let oldSelection = try changed.selection()
            let oldTask = Task { await changed.controller.reveal(oldSelection) }
            try await until { changed.key.gate != nil }
            changed.controller.select(valueID: UUID())
            changed.key.release()
            await oldTask.value
            try require(changed.controller.state == .masked && changed.controller.content.value == nil, "changed-selection")
            checks.append("late-authentication-after-selection-change")

            let intraEntry = try await ViewingFixture()
            let secondOccurrence = try await intraEntry.addSecondOccurrence()
            let selectionModel = AppModel()
            selectionModel.loadSnapshot(intraEntry.ledger.snapshot)
            selectionModel.selectedEntryID = .value(intraEntry.valueID)
            var occurrenceSelectionChanges = 0
            selectionModel.onOccurrenceSelectionChanged = { _ in
                occurrenceSelectionChanges += 1
                intraEntry.controller.invalidate(.userMask)
            }
            selectionModel.selectedOccurrenceID = intraEntry.occurrenceID
            let initialSelectionChanges = occurrenceSelectionChanges
            let firstContext = try InventoryRevealSelection.occurrence(in: intraEntry.ledger.snapshot,
                occurrenceID: intraEntry.occurrenceID)
            intraEntry.key.hold = true
            let firstContextTask = Task { await intraEntry.controller.reveal(firstContext) }
            try await until { intraEntry.key.gate != nil }
            selectionModel.revealedContent[intraEntry.valueID] = "synthetic previous value"
            selectionModel.revealedExcerpts[intraEntry.occurrenceID] = RetainedExcerpt(text: "synthetic cached A", clipped: false)
            selectionModel.revealedSourceMetadata[intraEntry.occurrenceID] = RetainedSourceContext(sessionIdentifier: "synthetic")
            selectionModel.terminalResumeCommand = "synthetic previous command"
            selectionModel.viewingAuthorized = true
            selectionModel.viewingMessage = "synthetic previous message"
            selectionModel.actionMessage = "synthetic previous action"
            selectionModel.selectedOccurrenceID = secondOccurrence
            try require(selectionModel.selectedEntryID == .value(intraEntry.valueID)
                && occurrenceSelectionChanges == initialSelectionChanges + 1 && selectionModel.revealedContent.isEmpty
                && selectionModel.revealedExcerpts.isEmpty && selectionModel.revealedSourceMetadata.isEmpty
                && selectionModel.terminalResumeCommand == nil && !selectionModel.viewingAuthorized
                // Action messages are timed toasts, independent of retained occurrence content.
                && selectionModel.viewingMessage == nil && selectionModel.actionMessage == "synthetic previous action",
                "same-entry-selection-masks-immediately")
            intraEntry.key.release()
            await firstContextTask.value
            try require(intraEntry.controller.state == .masked && intraEntry.controller.content.excerpts.isEmpty
                && intraEntry.controller.content.sourceMetadata.isEmpty && intraEntry.session.revealed.isEmpty,
                "same-entry-late-authentication-denied")
            let secondContext = try InventoryRevealSelection.occurrence(in: intraEntry.ledger.snapshot,
                occurrenceID: secondOccurrence)
            await intraEntry.controller.reveal(secondContext)
            selectionModel.revealedExcerpts = intraEntry.controller.content.excerpts
            selectionModel.revealedSourceMetadata = intraEntry.controller.content.sourceMetadata
            selectionModel.viewingAuthorized = intraEntry.controller.isAuthorized
            selectionModel.terminalResumeCommand = "synthetic command B"
            selectionModel.selectedOccurrenceID = secondOccurrence
            try require(occurrenceSelectionChanges == initialSelectionChanges + 1 && selectionModel.viewingAuthorized
                && selectionModel.revealedExcerpts[secondOccurrence]?.text == "synthetic context B"
                && selectionModel.revealedSourceMetadata[secondOccurrence]?.title == "synthetic title B"
                && selectionModel.terminalResumeCommand == "synthetic command B",
                "same-occurrence-selection-keeps-current-content")
            checks.append("intra-entry-occurrence-selection-rejects-late-authentication")
            checks.append("unchanged-occurrence-selection-keeps-current-content")

            let deleted = try await ViewingFixture()
            deleted.key.hold = true
            let deletedSelection = try deleted.selection()
            let deletedTask = Task { await deleted.controller.reveal(deletedSelection) }
            try await until { deleted.key.gate != nil }
            let fingerprint = try ValueFingerprint(keyedDigest: Data(repeating: 0x23, count: 32))
            _ = try deleted.ledger.removeContent(for: fingerprint)
            deleted.payloads.removeAll()
            deleted.key.release()
            await deletedTask.value
            try require(deleted.controller.content.value == nil && deleted.session.revealed.isEmpty, "deleted-while-authenticating")
            checks.append("deletion-during-authentication")

            let mismatched = try await ViewingFixture()
            let mismatchedSelection = try mismatched.selection()
            let field = mismatchedSelection.fields[0]
            mismatched.payloads[field.reference] = try await mismatched.crypto.sealInventory(Data("synthetic-wrong-owner".utf8),
                binding: PayloadBinding(reference: field.reference, ownerID: UUID(), kind: .value))
            await mismatched.controller.reveal(mismatchedSelection)
            try require(mismatched.key.authorizations == 0 && mismatched.controller.content.value == nil, "wrong-binding")
            checks.append("binding-rejected-before-authentication")

            let alert = value.ledger.alertDecisions.values.first!
            let notification = MaskedNotification.live(alert, conversation: MaskedConversationLabel(index: 1))
            let system = ProbeNotificationSystem()
            let notifications = NotificationController(system: system)
            try require(await notifications.deliver(notification, isEligible: { true }) == .delivered, "notification-allowed")
            try require(await notifications.deliver(notification, isEligible: { true }) == .delivered
                && system.submits == 1 && system.requests == 0, "notification-stable-retry")
            checks.append("allowed-notification-stable-retry")
            for permission in [NotificationPermission.denied, .notRequested] {
                let deniedSystem = ProbeNotificationSystem()
                deniedSystem.permission = permission
                let denied = NotificationController(system: deniedSystem)
                try require(await denied.deliver(notification, isEligible: { true }) == .permissionDenied
                    && deniedSystem.submits == 0 && deniedSystem.requests == 0, "permission-denied-no-prompt")
            }
            checks.append("denied-or-unrequested-permission-never-prompts")
            let requestedSystem = ProbeNotificationSystem()
            requestedSystem.permission = .notRequested
            let requested = NotificationController(system: requestedSystem)
            await requested.requestPermission()
            try require(requestedSystem.requests == 1 && requested.permission == .allowed, "explicit-permission")
            checks.append("explicit-notification-permission-action")

            let failedRequestSystem = ProbeNotificationSystem()
            failedRequestSystem.permission = .notRequested
            failedRequestSystem.permissionAfterRequestFailure = .denied
            let failedRequest = NotificationController(system: failedRequestSystem)
            await failedRequest.requestPermission()
            try require(failedRequest.permission == .denied && !failedRequest.requestingPermission
                && failedRequestSystem.requests == 1, "permission-request-error-keeps-denied-state")
            await failedRequest.refreshPermission()
            try require(await failedRequest.deliver(notification, isEligible: { true }) == .permissionDenied
                && failedRequest.permission == .denied && failedRequestSystem.requests == 1
                && failedRequestSystem.submits == 0, "permission-request-error-never-repeats-prompt")
            checks.append("permission-request-error-keeps-denied-state-without-reprompting")

            for pause in [false, true] {
                let raceSystem = ProbeNotificationSystem()
                raceSystem.hold = true
                let race = NotificationController(system: raceSystem)
                let delivery = Task { await race.deliver(notification, isEligible: { true }) }
                try await until { raceSystem.gate != nil }
                if pause { race.setMonitoring(enabled: false) }
                else { race.cancel(identifiers: [notification.identifier]) }
                raceSystem.release()
                try require(await delivery.value == .cancelled && raceSystem.identifiers.isEmpty
                    && raceSystem.removedDelivered.contains(notification.identifier), "late-notification-cancelled")
                checks.append(pause ? "pause-during-notification-submit" : "deletion-during-notification-submit")
            }
            let waitingSystem = ProbeNotificationSystem()
            let waiting = NotificationController(system: waitingSystem)
            let eligibility = ProbeEligibility()
            let waitingDelivery = Task { await waiting.deliver(notification, isEligible: { await eligibility.check() }) }
            try await until { eligibility.gate != nil }
            waiting.setMonitoring(enabled: false)
            eligibility.release()
            try require(await waitingDelivery.value == .cancelled && waitingSystem.submits == 0,
                "pause-during-eligibility")
            checks.append("pause-during-notification-eligibility")

            let audit = try HistoricalAuditContext(reason: .restart, endingAt: .now)
            var summary = HistoricalAuditSummary(audit: audit)
            try summary.include(HistoricalContribution(audit: audit, ordinaryOccurrenceIDs: [UUID()],
                obsoleteOccurrenceIDs: [], ordinaryValueIDs: [UUID()]))
            let oldAudit = MaskedNotification.historical(HistoricalNotificationDecision(summary: summary))
            try summary.include(HistoricalContribution(audit: audit, ordinaryOccurrenceIDs: [UUID()],
                obsoleteOccurrenceIDs: [], ordinaryValueIDs: [UUID()]))
            let updatedAudit = MaskedNotification.historical(HistoricalNotificationDecision(summary: summary))
            let revisionSystem = ProbeNotificationSystem()
            revisionSystem.hold = true
            let revision = NotificationController(system: revisionSystem)
            let oldAuditDelivery = Task { await revision.deliver(oldAudit, isEligible: { true }) }
            try await until { revisionSystem.gate != nil }
            revision.invalidatePresentations(identifiers: [oldAudit.identifier])
            revisionSystem.release()
            try require(await oldAuditDelivery.value == .cancelled && revisionSystem.identifiers.isEmpty,
                "old-audit-presentation-retired")
            try require(oldAudit.identifier == updatedAudit.identifier && oldAudit.body != updatedAudit.body,
                "same-audit-id-new-counts")
            try require(await revision.deliver(updatedAudit, isEligible: { true }) == .delivered
                && revisionSystem.submitted.last == updatedAudit, "updated-audit-id-not-blacklisted")
            checks.append("changed-audit-counts-reuse-stable-identifier")

            let launching = NotificationController(system: ProbeNotificationSystem())
            await launching.receiveNavigation(notification.target)
            var opened: [NotificationNavigationTarget] = []
            launching.navigationIsCurrent = { $0 == notification.target }
            launching.onNavigate = { opened.append($0) }
            await launching.flushPendingNavigation()
            try require(opened == [notification.target], "launch-navigation-not-lost")
            launching.shutdown()
            await launching.receiveNavigation(notification.target)
            try require(opened == [notification.target], "shutdown-navigation-denied")
            checks.append("notification-navigation-waits-for-protected-storage")

            let startedAt = ProcessInfo.processInfo.systemUptime
            let timedOut = await BoundedSourceCommand.run(SourceCommandPlan(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"]), seconds: 0.05)
            try require(timedOut == .timedOut && ProcessInfo.processInfo.systemUptime - startedAt < 2,
                "source-command-timeout")
            checks.append("owned-source-command-timeout")
            let cancelledCommand = Task { await BoundedSourceCommand.run(SourceCommandPlan(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"]), seconds: 5) }
            try await Task.sleep(for: .milliseconds(50))
            cancelledCommand.cancel()
            try require(await cancelledCommand.value == .cancelled, "source-command-cancellation")
            checks.append("owned-source-command-cancellation")

            // Live polling alternates processing and idle several times a second. The displayed state
            // settles once instead of following each item, then returns to idle after a quiet period.
            let activityModel = AppModel()
            var busyChanges = 0, shownBusy = activityModel.busy, texts = Set<String>()
            for tick in 0..<16 {
                activityModel.updatePipeline(PipelineActivity(processing: tick.isMultiple(of: 2), pendingCount: 0))
                try await Task.sleep(for: .milliseconds(125))
                if activityModel.busy != shownBusy { busyChanges += 1; shownBusy = activityModel.busy }
                if tick >= 10 { texts.insert(activityModel.processingText) }
            }
            try require(busyChanges == 1 && activityModel.busy && texts == ["Analyzing new content"], "burst-activity-flickers")
            try await Task.sleep(for: .milliseconds(Int(AppModel.idleDelay * 1000) + 400))
            try require(!activityModel.busy && activityModel.processingText.hasPrefix("Up to date"), "burst-activity-never-settles")
            checks.append("burst-activity-settles-without-flicker")

            let blipModel = AppModel()
            blipModel.updatePipeline(PipelineActivity(processing: true, pendingCount: 0))
            try await Task.sleep(for: .milliseconds(100))
            blipModel.updatePipeline(PipelineActivity(processing: false, pendingCount: 0))
            for _ in 0..<25 {
                try await Task.sleep(for: .milliseconds(100))
                try require(!blipModel.busy, "single-short-item-shown-as-busy")
            }
            checks.append("single-short-item-stays-idle")

            let catchUpModel = AppModel()
            catchUpModel.beginCatchUp()
            try require(catchUpModel.catchingUp && catchUpModel.processingText == "Reading recent history", "catch-up-not-shown")
            catchUpModel.updatePipeline(PipelineActivity(processing: false, pendingCount: 0))
            try await Task.sleep(for: .milliseconds(Int(AppModel.idleDelay * 1000) + 400))
            try require(!catchUpModel.catchingUp, "catch-up-never-ends")
            checks.append("catch-up-ends-after-queue-drains")

            let output: [String: Any] = ["passed": true, "checks": checks, "checkCount": checks.count,
                "systemAuthentication": "not-exercised-synthetic-private-key", "systemNotifications": "injected-backend",
                "sourceSessionsStarted": 0, "credentialsRead": false]
            print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
        } catch {
            // Probe diagnostics use only controlled test stage names, never framework errors or content.
            let stage: String
            if case ProbeFailure.failed(let name) = error { stage = name }
            else { stage = "native-workflow-probe" }
            let report: [String: Any] = ["passed": false, "failure": stage]
            if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                print(String(decoding: bytes, as: UTF8.self))
            }
            exit(1)
        }
    }
}
