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
            value.controller.hide()
            try require(value.controller.state == .masked && value.controller.content.value == nil
                && value.controller.content.excerpts.isEmpty && value.session.revealed.isEmpty
                && value.controller.isAuthorized, "hide-keeps-session-unlocked")
            await value.controller.reveal(try value.selection())
            try require(value.controller.content.value == "SYNTHETIC-NATIVE-VIEWING-Ä-🔐" && value.key.authorizations == 1,
                "reveal-after-hide-without-prompt")
            value.controller.select(valueID: UUID())
            try require(value.controller.content.value == nil && value.session.revealed.isEmpty
                && value.controller.isAuthorized, "selection-change-keeps-session-unlocked")
            value.controller.select(valueID: value.valueID)
            await value.controller.reveal(try value.selection())
            try require(value.controller.content.value == "SYNTHETIC-NATIVE-VIEWING-Ä-🔐" && value.key.authorizations == 1,
                "reveal-after-selection-change-without-prompt")
            checks.append("hide-and-selection-change-keep-session-unlocked")
            value.controller.invalidate(.windowClose)
            try require(value.controller.content.value == nil && value.controller.content.excerpts.isEmpty
                && value.controller.content.sourceMetadata.isEmpty && value.session.revealed.isEmpty
                && !value.controller.isAuthorized, "immediate-mask")
            checks.append("authenticated-exact-fields-and-window-mask")
            await value.controller.reveal(try value.selection())
            try require(value.controller.content.value == "SYNTHETIC-NATIVE-VIEWING-Ä-🔐" && value.key.authorizations == 2,
                "lock-requires-authentication-again")
            checks.append("lock-requires-authentication-again")

            let unlocked = try await ViewingFixture()
            try await unlocked.controller.unlock()
            try require(unlocked.controller.isAuthorized && unlocked.key.authorizations == 1 && !unlocked.controller.unlocking
                && unlocked.controller.state == .masked && unlocked.controller.content.value == nil
                && unlocked.session.revealed.isEmpty, "unlock-reveals-nothing")
            await unlocked.controller.reveal(try unlocked.selection())
            try require(unlocked.controller.content.value == "SYNTHETIC-NATIVE-VIEWING-Ä-🔐" && unlocked.key.authorizations == 1,
                "reveal-after-unlock-without-prompt")
            checks.append("unlock-then-reveal-without-prompt")

            // The app shows every selection on its own while unlocked, and that must never prompt.
            let shown = try await ViewingFixture()
            await shown.controller.reveal(try shown.selection(), prompting: false)
            try require(shown.key.authorizations == 0 && shown.controller.state == .masked
                && shown.controller.content.value == nil && shown.session.revealed.isEmpty, "locked-show-stays-masked")
            try await shown.controller.unlock()
            await shown.controller.reveal(try .occurrenceWithValue(in: shown.ledger.snapshot, occurrenceID: shown.occurrenceID),
                prompting: false)
            try require(shown.controller.state == .revealed && shown.key.authorizations == 1
                && shown.controller.content.value == "SYNTHETIC-NATIVE-VIEWING-Ä-🔐"
                && shown.controller.content.excerpts[shown.occurrenceID] != nil, "unlocked-show-without-prompt")
            shown.controller.invalidate(.sessionLock)
            await shown.controller.reveal(try shown.selection(), prompting: false)
            try require(shown.key.authorizations == 1 && shown.controller.state == .masked
                && shown.controller.content.value == nil && !shown.controller.isAuthorized, "locked-again-show-stays-masked")
            checks.append("show-while-unlocked-never-prompts")

            let cancelledUnlock = try await ViewingFixture()
            cancelledUnlock.key.cancellation = true
            do {
                try await cancelledUnlock.controller.unlock()
                throw ProbeFailure.failed("cancelled-unlock-succeeded")
            } catch ViewingAuthorizationError.cancelled {}
            try require(!cancelledUnlock.controller.isAuthorized && !cancelledUnlock.controller.unlocking
                && cancelledUnlock.controller.state == .masked, "cancelled-unlock")
            checks.append("cancelled-unlock-stays-locked")

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
            var lateChanges = 0
            changed.controller.onChange = { lateChanges += 1 }
            changed.key.release()
            await oldTask.value
            // The completed authentication unlocks the session but reveals nothing for the new selection.
            try require(changed.controller.state == .masked && changed.controller.content.value == nil
                && changed.session.revealed.isEmpty && changed.controller.isAuthorized && lateChanges > 0, "changed-selection")
            checks.append("late-authentication-after-selection-change")

            let intraEntry = try await ViewingFixture()
            let secondOccurrence = try await intraEntry.addSecondOccurrence()
            let selectionModel = AppModel()
            selectionModel.loadSnapshot(intraEntry.ledger.snapshot)
            selectionModel.selectedEntryID = .value(intraEntry.valueID)
            var occurrenceSelectionChanges = 0
            selectionModel.onOccurrenceSelectionChanged = { _ in occurrenceSelectionChanges += 1 }
            selectionModel.selectedOccurrenceID = intraEntry.occurrenceID
            let initialSelectionChanges = occurrenceSelectionChanges
            selectionModel.revealedContent[intraEntry.valueID] = "synthetic previous value"
            selectionModel.revealedExcerpts[intraEntry.occurrenceID] = RetainedExcerpt(text: "synthetic cached A", clipped: false)
            selectionModel.revealedSourceMetadata[intraEntry.occurrenceID] = RetainedSourceContext(sessionIdentifier: "synthetic")
            selectionModel.terminalResumeCommand = "synthetic previous command"
            selectionModel.contentRevealed = true
            selectionModel.viewingMessage = "synthetic previous message"
            selectionModel.actionMessage = "synthetic previous action"
            selectionModel.selectedOccurrenceID = secondOccurrence
            // The value stays revealed across its appearances; only the per-appearance command resets.
            try require(selectionModel.selectedEntryID == .value(intraEntry.valueID)
                && occurrenceSelectionChanges == initialSelectionChanges + 1 && selectionModel.contentRevealed
                && selectionModel.revealedContent[intraEntry.valueID] == "synthetic previous value"
                && selectionModel.revealedExcerpts[intraEntry.occurrenceID] != nil
                && selectionModel.terminalResumeCommand == nil
                // Action messages are timed toasts, independent of retained occurrence content.
                && selectionModel.viewingMessage == nil && selectionModel.actionMessage == "synthetic previous action",
                "same-entry-selection-keeps-revealed-value")
            selectionModel.terminalResumeCommand = "synthetic command B"
            selectionModel.selectedOccurrenceID = secondOccurrence
            try require(occurrenceSelectionChanges == initialSelectionChanges + 1
                && selectionModel.terminalResumeCommand == "synthetic command B",
                "same-occurrence-selection-keeps-current-content")
            checks.append("intra-entry-occurrence-selection-keeps-revealed-value")
            checks.append("unchanged-occurrence-selection-keeps-current-content")

            // The Inbox: three lists, unread values first, the next value after a decision, keys and undo.
            let inbox = AppModel()
            inbox.readMarks = ReadMarks(defaults: nil, now: Date().addingTimeInterval(-4 * 3600))
            inbox.loadSnapshot(try DemoInventory.snapshot())
            inbox.storageReady = true
            let counts = inbox.bucketCounts
            try require(counts[.toReview] == 4 && counts[.toRotate] == 1 && counts[.done] == 3, "inbox-buckets")
            let review = inbox.bucketEntries
            try require(review.prefix(2).allSatisfy(inbox.isUnread) && !review.dropFirst(2).contains(where: inbox.isUnread)
                && inbox.selectedEntryID == review.first?.id, "inbox-unread-first")
            inbox.windowVisible = true
            // What's on screen is read, and it keeps its row until the list reloads.
            try require(!inbox.isUnread(review[0]) && inbox.isUnread(review[1])
                && inbox.bucketEntries.map(\.id) == review.map(\.id), "inbox-read-keeps-order")
            var applied: [[InventoryDecisionChange]] = []
            inbox.onApply = { changes, _ in applied.append(changes) }
            let decidedFirst = review[0].entry.fingerprint.map { InventoryDecisionChange.decide($0, .testOrDevelopment) }
            try require(inbox.decide(byKey: "t") && applied.count == 1 && applied.first?.first == decidedFirst
                && inbox.selectedEntryID == review[1].id, "inbox-decision-opens-next")
            try require(!inbox.decide(byKey: "d") && applied.count == 1, "inbox-keys-follow-the-list")
            let step: [InventoryDecisionChange] = [.decideUnlocated(UUID(), nil)]
            inbox.offerUndo(step, message: "synthetic decision")
            try require(inbox.toastOffersUndo, "inbox-undo-offered")
            inbox.undoLastDecision()
            try require(applied.last == step && inbox.undo == nil && !inbox.toastOffersUndo, "inbox-undo")
            inbox.selectBucket(.toRotate)
            try require(inbox.decide(byKey: "d") && inbox.selectedEntryID == nil
                && applied.last.map { $0.allSatisfy { if case .acknowledge(_, .rotated) = $0 { true } else { false } } } == true,
                "inbox-mark-rotated")
            checks.append("inbox-lists-unread-advance-and-undo")

            // Several values decided together, and Focus going through them one at a time.
            let batch = AppModel()
            batch.loadSnapshot(try DemoInventory.snapshot())
            batch.storageReady = true
            var batches: [[InventoryDecisionChange]] = []
            batch.onApply = { changes, _ in batches.append(changes) }
            let list = batch.bucketEntries.map(\.id)
            batch.select(list[0], gesture: .single)
            batch.select(list[2], gesture: .range)
            try require(batch.multiSelection == Array(list[0...2]) && batch.selectedEntryID == nil
                && batch.selectedSummaries.map(\.id) == Array(list[0...2]), "selection-range")
            batch.select(list[1], gesture: .toggle)
            try require(batch.multiSelection == [list[0], list[2]], "selection-toggle")
            try require(batch.decide(byKey: "n") && batches.last?.count == 2 && batch.multiSelection.isEmpty
                && batch.selectedEntryID == list[1], "selection-decides-together")
            batch.startFocus(.list)
            try require(batch.focus?.ids == list && batch.selectedEntryID == list[0], "focus-starts-at-the-top")
            try require(batch.decide(byKey: "r") && batch.focus?.current == list[1] && batch.selectedEntryID == list[1],
                "focus-opens-the-next")
            batch.moveFocus(by: -1)
            try require(batch.focus?.current == list[0], "focus-goes-back")
            batch.exitFocus()
            try require(batch.focus == nil && batch.bucket == .toReview && batch.selectedEntryID == list[0], "focus-exit")
            checks.append("selection-and-focus")

            // Focus titles count what's left, so they follow each decision and its undo. Decisions are
            // applied to a ledger and reloaded, as the app does once they're written.
            var ledger = try InventoryLedger(snapshot: try DemoInventory.snapshot())
            let live = AppModel()
            live.loadSnapshot(ledger.snapshot)
            live.storageReady = true
            var liveApplied: [[InventoryDecisionChange]] = []
            live.onApply = { changes, _ in
                liveApplied.append(changes)
                for change in changes { try? ledger.apply(change, at: Date()) }
                live.loadSnapshot(ledger.snapshot)
            }
            func focusTitle(_ model: AppModel) -> String? { model.focus.map { $0.title(left: model.pending(in: $0).count) } }
            live.startFocus(.list)
            try require(focusTitle(live) == "4 values to review", "focus-title-counts-the-list")
            let beforeDecision = ledger.snapshot
            try require(live.decide(byKey: "r") && focusTitle(live) == "3 values to review", "focus-title-follows-a-decision")
            live.offerUndo(InventoryDecisionChange.inverse(of: liveApplied.last ?? [], in: beforeDecision), message: "synthetic decision")
            live.undoLastDecision()
            try require(focusTitle(live) == "4 values to review", "focus-title-follows-undo")
            for _ in 0..<8 where live.focus?.current != nil { _ = live.decide(byKey: "n") }
            try require(live.focus?.current == nil && focusTitle(live) == "Nothing left to review", "focus-title-when-done")
            let picked = AppModel()
            picked.loadSnapshot(try DemoInventory.snapshot())
            let pickedList = picked.bucketEntries.map(\.id)
            picked.select(pickedList[0], gesture: .single)
            picked.select(pickedList[1], gesture: .toggle)
            picked.startFocus(.selection)
            try require(focusTitle(picked) == "2 selected values to review", "focus-title-names-a-selection")
            picked.exitFocus()
            picked.selectBucket(.toRotate)
            picked.startFocus(.list)
            try require(focusTitle(picked) == "1 value to rotate", "focus-title-to-rotate")
            checks.append("focus-title-counts-what-is-left")

            // Switching appearance while the prompt is open reveals only the newer one, after a single prompt.
            let firstAppearance = try InventoryRevealSelection.occurrenceWithValue(in: intraEntry.ledger.snapshot,
                occurrenceID: intraEntry.occurrenceID)
            let secondAppearance = try InventoryRevealSelection.occurrenceWithValue(in: intraEntry.ledger.snapshot,
                occurrenceID: secondOccurrence)
            intraEntry.key.hold = true
            let firstAppearanceTask = Task { await intraEntry.controller.reveal(firstAppearance) }
            try await until { intraEntry.key.gate != nil }
            let secondAppearanceTask = Task { await intraEntry.controller.reveal(secondAppearance) }
            for _ in 0..<10 { await Task.yield() }
            intraEntry.key.release()
            await firstAppearanceTask.value
            await secondAppearanceTask.value
            try require(intraEntry.controller.state == .revealed
                && intraEntry.controller.content.value == "SYNTHETIC-NATIVE-VIEWING-Ä-🔐"
                && Set(intraEntry.controller.content.excerpts.keys) == [secondOccurrence]
                && intraEntry.key.authorizations == 1, "superseded-appearance-reveal")
            checks.append("appearance-change-during-authentication-reveals-newer-appearance")

            // With the value revealed, another appearance adds its context without hiding the value or prompting.
            var shownStates: [InventoryViewingState] = []
            intraEntry.controller.onChange = { shownStates.append(intraEntry.controller.state) }
            await intraEntry.controller.reveal(firstAppearance)
            try require(shownStates == [.revealed] && intraEntry.controller.content.value == "SYNTHETIC-NATIVE-VIEWING-Ä-🔐"
                && Set(intraEntry.controller.content.excerpts.keys) == [intraEntry.occurrenceID, secondOccurrence]
                && intraEntry.controller.content.sourceMetadata[intraEntry.occurrenceID]?.title == "synthetic title"
                && intraEntry.key.authorizations == 1, "appearance-change-extends-revealed-content")
            checks.append("appearance-change-keeps-value-revealed")

            let cancelledSwitch = try await ViewingFixture()
            let cancelledSecond = try await cancelledSwitch.addSecondOccurrence()
            let cancelledFirst = try InventoryRevealSelection.occurrenceWithValue(in: cancelledSwitch.ledger.snapshot,
                occurrenceID: cancelledSwitch.occurrenceID)
            let cancelledNext = try InventoryRevealSelection.occurrenceWithValue(in: cancelledSwitch.ledger.snapshot,
                occurrenceID: cancelledSecond)
            cancelledSwitch.key.hold = true
            cancelledSwitch.key.cancellation = true
            let cancelledFirstTask = Task { await cancelledSwitch.controller.reveal(cancelledFirst) }
            try await until { cancelledSwitch.key.gate != nil }
            let cancelledNextTask = Task { await cancelledSwitch.controller.reveal(cancelledNext) }
            for _ in 0..<10 { await Task.yield() }
            cancelledSwitch.key.release()
            await cancelledFirstTask.value
            await cancelledNextTask.value
            try require(cancelledSwitch.controller.state == .cancelled && cancelledSwitch.controller.content.value == nil
                && !cancelledSwitch.controller.isAuthorized && cancelledSwitch.key.authorizations == 1,
                "cancelled-appearance-switch")
            checks.append("cancelled-prompt-during-appearance-change-reports-cancellation")

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
            activityModel.storageReady = true
            var busyChanges = 0, shownBusy = activityModel.busy, texts = Set<String>()
            for tick in 0..<16 {
                activityModel.updatePipeline(PipelineActivity(processing: tick.isMultiple(of: 2), pendingCount: 0))
                try await Task.sleep(for: .milliseconds(125))
                if activityModel.busy != shownBusy { busyChanges += 1; shownBusy = activityModel.busy }
                if tick >= 10 { texts.insert(activityModel.processingText) }
            }
            try require(busyChanges == 1 && activityModel.busy && texts == ["Analyzing new content"], "burst-activity-flickers")
            try await Task.sleep(for: .milliseconds(Int(AppModel.idleDelay * 1000) + 400))
            try require(!activityModel.busy && activityModel.processingText == "Waiting for agent content"
                && activityModel.processingShort == "Waiting", "idle-without-read-evidence-claimed-complete")
            checks.append("burst-activity-settles-without-flicker")

            let blipModel = AppModel()
            blipModel.storageReady = true
            blipModel.updatePipeline(PipelineActivity(processing: true, pendingCount: 0))
            try await Task.sleep(for: .milliseconds(100))
            blipModel.updatePipeline(PipelineActivity(processing: false, pendingCount: 0))
            for _ in 0..<25 {
                try await Task.sleep(for: .milliseconds(100))
                try require(!blipModel.busy, "single-short-item-shown-as-busy")
            }
            checks.append("single-short-item-stays-idle")

            // A catch-up lasts exactly as long as history work is queued; live work alone doesn't extend it.
            let catchUpModel = AppModel()
            catchUpModel.storageReady = true
            catchUpModel.beginCatchUp([.codex])
            try require(catchUpModel.catchingUp && catchUpModel.processingText == "Reading recent history", "catch-up-not-shown")
            try require(catchUpModel.catchingUpProviders == [.codex], "catch-up-not-shown-on-its-agent")
            catchUpModel.updatePipeline(PipelineActivity(processing: true, pendingCount: 4))
            catchUpModel.updateHistoryWork(queued: 1, providers: [.codex])
            try await Task.sleep(for: .milliseconds(Int(AppModel.idleDelay * 1000) + 400))
            try require(catchUpModel.catchingUp, "catch-up-ended-early")
            catchUpModel.updateHistoryWork(queued: 0)
            try require(!catchUpModel.catchingUp && catchUpModel.catchingUpProviders.isEmpty, "catch-up-held-by-live-work")
            checks.append("catch-up-follows-queued-history")

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
