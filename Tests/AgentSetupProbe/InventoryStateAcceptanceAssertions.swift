import Foundation
import CryptoKit
@_spi(Testing) import SpillcheckCore

enum InventoryStateAssertionFailure: Error { case failed(String) }

@MainActor
func inventoryStateAcceptanceAssertions() async throws -> [String] {
    func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw InventoryStateAssertionFailure.failed(name) }
    }
    func rejects(_ name: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw InventoryStateAssertionFailure.failed(name)
    }
    for (stopped, busy, count, claimed, pending) in [(false, false, 0, 0, 0), (true, true, 0, 0, 0),
        (true, false, 1, 0, 1), (true, false, 0, 1, 0), (true, false, 0, 0, 1)] {
        try rejects("inventory-state-refuses-active-or-pending-work") {
            try InventoryStateAcceptance.requireIdle(processingStopped: stopped, actionBusy: busy,
                queueCount: count, claimedCount: claimed, pendingCount: pending)
        }
    }
    try InventoryStateAcceptance.requireIdle(processingStopped: true, actionBusy: false,
        queueCount: 0, claimedCount: 0, pendingCount: 0)
    struct Shape: Encodable { let categories: [String]; let components: [Int] }
    let first = try InventoryStateAcceptance.canonicalBytes(Shape(categories: ["a", "b"], components: [1, 2]))
    try check(first == InventoryStateAcceptance.canonicalBytes(Shape(categories: ["b", "a"], components: [1, 2])),
        "inventory-state-canonicalizes-unordered-contract-fields")
    try check(first != InventoryStateAcceptance.canonicalBytes(Shape(categories: ["a", "b"], components: [2, 1])),
        "inventory-state-retains-ordered-array-semantics")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-inventory-state-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let crypto = try BackgroundCryptography.ephemeralForTesting()
    var store = try await ProtectedStore.open(at: root, cryptography: crypto)
    let bytes = Data(InventoryStateAcceptance.fixtureValue.utf8)
    let fingerprint = try await crypto.fingerprint(exactBytes: bytes)
    let now = Date()
    let session = try SessionIdentity(provider: .codex, profileID: "fake-inventory-profile", sessionID: "fake-inventory-session")
    let types: [ContentType] = [.userPrompt, .userPrompt, .toolOutput, .toolOutput, .toolError, .intermediateResponse, .finalResponse]
    var inputs: [(SourceAnalysis, [ProtectedPayload])] = []
    for (index, type) in types.enumerated() {
        let origin = try SourceOrigin(adapterID: "fake-retained-state", adapterVersion: "1", agentVersion: "0.162.1",
            interface: .t3, provenance: .live, canonicalization: .sharedUpstreamIdentity)
        let source = try SourceRecord(metadata: SourceRecordMetadata(identity: SourceIdentity(session: session, itemID: "fake-item-\(index)"),
            contentType: type, contentTime: now, observedAt: now, origin: origin),
            revision: await crypto.revision(canonicalBytes: bytes), segments: [SourceSegment(id: "text", utf8: bytes)])
        if index == 0 {
            let audit = try HistoricalAuditContext(reason: .resume, endingAt: now)
            let historicalOrigin = try SourceOrigin(adapterID: origin.adapterID, adapterVersion: origin.adapterVersion,
                agentVersion: origin.agentVersion, interface: origin.interface, provenance: .historical(audit),
                canonicalization: origin.canonicalization)
            let historical = try SourceRecord(metadata: SourceRecordMetadata(identity: source.metadata.identity,
                contentType: type, contentTime: now, observedAt: now, origin: historicalOrigin),
                revision: source.revision, segments: source.segments)
            // Codex finishHistory returns this shape: actual historical sources and progress,
            // while observedRead remains its default false. It is not an empty poll.
            let progress = HistoricalReadProgress(audit: audit, bytesRead: bytes.count, hasUnreadContent: false)
            let batch = CollectionBatch(sources: [.init(record: historical)], historicalProgress: progress,
                observedReaderVersion: "0.162.1")
            try check(!batch.observedRead && InventoryStateAcceptance.hasReadEvidence(batch),
                "inventory-replay-accepts-nonempty-historical-read-without-empty-poll-flag")
            try check(!InventoryStateAcceptance.hasReadEvidence(.init(sources: [.init(record: historical)],
                historicalProgress: progress, readEvidenceEligible: false)), "inventory-replay-refuses-ineligible-real-content")
            try check(!InventoryStateAcceptance.hasReadEvidence(.init(sources: [])), "inventory-replay-refuses-default-empty-batch")
            try check(!InventoryStateAcceptance.hasReadEvidence(.init(sources: [], historicalProgress:
                .init(audit: audit, bytesRead: 0, hasUnreadContent: true))), "inventory-replay-refuses-unread-empty-progress")
            try check(InventoryStateAcceptance.hasReadEvidence(.init(sources: [], observedRead: true)),
                "inventory-replay-recognizes-valid-empty-poll-evidence")
            try check(InventoryStateAcceptance.hasReadEvidence(.init(sources: [], historicalProgress: progress)),
                "inventory-replay-recognizes-measured-historical-progress")
        }
        let extraction = try ExactExtraction(valueUTF8: bytes, location: CanonicalLocation(segmentID: "text", range: UTF8Range(0, bytes.count)), in: source)
        let reference = ProtectedPayloadReference(), excerpt = ProtectedPayloadReference()
        let detection = try LocatedDetection(extraction: extraction, in: source, fingerprint: fingerprint,
            evidence: [DetectionEvidence(rule: RuleIdentity(id: "fake-rule", version: "1"), signal: .strong, reason: .localRule, category: .token),
                       DetectionEvidence(rule: RuleIdentity(id: "fake-other-rule", version: "1"), signal: .ambiguous, reason: .localRule, category: .password)],
            protectedValue: reference, protectedExcerpt: excerpt)
        let analysis = try SourceAnalysis(source: source, detectorVersion: "fake-detector", detections: [detection])
        let payloads = try await [crypto.sealInventory(bytes, binding: PayloadBinding(reference: reference, ownerID: reference.id, kind: .value)),
                                 crypto.sealInventory(bytes, binding: PayloadBinding(reference: excerpt, ownerID: excerpt.id, kind: .excerpt))]
        guard let permit = await store.processingPermit() else { throw InventoryStateAssertionFailure.failed("fixture-permit") }
        _ = try await store.commit(analysis, payloads: payloads, permit: permit)
        inputs.append((analysis, payloads))
    }
    let baseline = await store.snapshot()
    let plan = try InventoryStateAcceptance.reviewPlan(baseline, fingerprint: fingerprint)
    try check(plan.confirmed != plan.falsePositive && plan.receiptKind == "live", "inventory-state-selects-distinct-reviews-and-real-pending-receipt")
    let other = try await crypto.fingerprint(exactBytes: Data("other fake value".utf8))
    try rejects("inventory-state-refuses-wrong-fingerprint") { _ = try InventoryStateAcceptance.reviewPlan(baseline, fingerprint: other) }
    try rejects("inventory-state-refuses-empty-vault") { _ = try InventoryStateAcceptance.reviewPlan(InventorySnapshot(), fingerprint: fingerprint) }
    try await store.recordNotificationDelivery(identifier: plan.notificationIdentifier, state: .delivered)
    try await store.review(plan.confirmed, as: .confirmedSecret)
    try await store.review(plan.falsePositive, as: .falsePositive)
    let reviewed = await store.snapshot()
    try check(InventoryStateAcceptance.phase(reviewed, fingerprint: fingerprint) == "reviewed", "inventory-state-two-reviews-and-delivery-seed")
    try rejects("inventory-state-refuses-second-seed") { _ = try InventoryStateAcceptance.reviewPlan(reviewed, fingerprint: fingerprint) }
    let before = try await InventoryStateAcceptance.report(snapshot: reviewed, fingerprint: fingerprint, store: store, cryptography: crypto)
    try check(before.payloadRowCount == 8 && before.availableReferencedPayloadCount == 8 && before.reviewCounts["confirmedSecret"] == 1,
        "inventory-state-measures-protected-payloads-and-full-reviews")
    try await store.close()
    store = try await ProtectedStore.open(at: root, cryptography: crypto)
    let restarted = try await InventoryStateAcceptance.report(snapshot: await store.snapshot(), fingerprint: fingerprint, store: store, cryptography: crypto)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try check(encoder.encode(before) == encoder.encode(restarted), "inventory-state-full-digests-survive-restart")
    guard let permit = await store.processingPermit() else { throw InventoryStateAssertionFailure.failed("fixture-restart-permit") }
    for (analysis, payloads) in inputs {
        let transition = try await store.commit(analysis, payloads: payloads, permit: permit)
        try check(transition.outcome == .replay, "inventory-state-replay-is-genuine-reconciliation")
    }
    let replayed = try await InventoryStateAcceptance.report(snapshot: await store.snapshot(), fingerprint: fingerprint, store: store, cryptography: crypto)
    try check(encoder.encode(before) == encoder.encode(replayed), "inventory-state-replay-preserves-reviews-and-delivered-receipt")
    try await store.acknowledgeObsolete(fingerprint, as: .revoked, at: now)
    _ = try await store.removeContent(for: fingerprint)
    let removed = try await InventoryStateAcceptance.report(snapshot: await store.snapshot(), fingerprint: fingerprint, store: store, cryptography: crypto)
    try check(removed.phase == "removed" && removed.payloadRowCount == 0 && removed.removedLocationReceiptCount == 7,
        "inventory-state-removal-retains-obsolete-recognition-and-deletes-payload-rows")
    try await store.close()
    store = try await ProtectedStore.open(at: root, cryptography: crypto)
    guard let finalPermit = await store.processingPermit() else { throw InventoryStateAssertionFailure.failed("fixture-final-permit") }
    for (analysis, payloads) in inputs { _ = try await store.commit(analysis, payloads: payloads, permit: finalPermit) }
    let final = try await InventoryStateAcceptance.report(snapshot: await store.snapshot(), fingerprint: fingerprint, store: store, cryptography: crypto)
    try check(encoder.encode(removed) == encoder.encode(final), "inventory-state-cold-replay-cannot-resurrect-deleted-content-or-alerts")
    try await store.close()
    return ["inventory-replay-read-evidence-matches-production-without-requiring-empty-poll-flag",
        "inventory-state-authenticated-control-preconditions", "inventory-state-canonical-full-record-digests",
        "inventory-state-exact-fake-value-and-distinct-review-selection", "inventory-state-store-receipt-and-reviews-survive-cold-replay",
        "inventory-state-obsolete-removal-and-payload-row-absence-survive-cold-replay"]
        + (try await inventoryUpgradeStateAcceptanceAssertions())
        + (try await claudeInventoryStateAcceptanceAssertions())
}

@MainActor
private func inventoryUpgradeStateAcceptanceAssertions() async throws -> [String] {
    func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw InventoryStateAssertionFailure.failed(name) }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-upgrade-state-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let crypto = try BackgroundCryptography.ephemeralForTesting()
    var store = try await ProtectedStore.open(at: root, cryptography: crypto)
    let bytes = Data(InventoryStateAcceptance.fixtureValue.utf8)
    let fingerprint = try await crypto.fingerprint(exactBytes: bytes)
    let now = Date()
    let types: [ContentType] = [.userPrompt, .userPrompt, .toolOutput, .toolOutput, .toolError, .intermediateResponse, .finalResponse]
    var inputs: [(SourceAnalysis, [ProtectedPayload])] = []
    var sources: [SourceRecord] = []
    func appendFixture(_ version: String, at time: Date) async throws {
        let session = try SessionIdentity(provider: .codex, profileID: "owned-upgrade-profile", sessionID: UUID().uuidString.lowercased())
        for (index, type) in types.enumerated() {
            let origin = try SourceOrigin(adapterID: "codex", adapterVersion: CodexAdapter.adapterVersion, agentVersion: version,
                interface: .standaloneCLI, provenance: .live, canonicalization: .exclusiveAuthority)
            let segments = [try SourceSegment(id: "text", utf8: bytes)]
            let source = try SourceRecord(metadata: .init(identity: SourceIdentity(session: session, itemID: "owned-item-\(index)"),
                contentType: type, contentTime: time, observedAt: time, origin: origin),
                revision: await crypto.revision(canonicalBytes: WebResultAcceptance.canonicalSegments(segments)), segments: segments)
            let extraction = try ExactExtraction(valueUTF8: bytes,
                location: CanonicalLocation(segmentID: "text", range: UTF8Range(0, bytes.count)), in: source)
            let value = ProtectedPayloadReference(), excerpt = ProtectedPayloadReference()
            let detection = try LocatedDetection(extraction: extraction, in: source, fingerprint: fingerprint,
                evidence: [DetectionEvidence(rule: .init(id: "fixture", version: "1"), signal: .strong, reason: .localRule, category: .token)],
                protectedValue: value, protectedExcerpt: excerpt)
            let analysis = try SourceAnalysis(source: source, detectorVersion: BetterleaksSecretDetector.version, detections: [detection])
            let payloads = try await [crypto.sealInventory(bytes, binding: .init(reference: value, ownerID: value.id, kind: .value)),
                crypto.sealInventory(bytes, binding: .init(reference: excerpt, ownerID: excerpt.id, kind: .excerpt))]
            guard let permit = await store.processingPermit() else { throw InventoryStateAssertionFailure.failed("upgrade-state-permit") }
            _ = try await store.commit(analysis, payloads: payloads, permit: permit)
            inputs.append((analysis, payloads))
            sources.append(source)
        }
    }
    try await appendFixture("0.160.1", at: now)
    let baseline = await store.snapshot()
    let plan = try InventoryStateAcceptance.reviewPlan(baseline, fingerprint: fingerprint)
    do {
        try InventoryStateAcceptance.requireRetainedRevocation(baseline, fingerprint: fingerprint)
        throw InventoryStateAssertionFailure.failed("upgrade-state-acknowledged-unreviewed-state")
    } catch InventoryStateAcceptance.Failure.unexpectedInventory { }
    try await store.recordNotificationDelivery(identifier: plan.notificationIdentifier, state: .delivered)
    try await store.review(plan.confirmed, as: .confirmedSecret)
    try await store.review(plan.falsePositive, as: .falsePositive)
    let reviewed = await store.snapshot()
    try InventoryStateAcceptance.requireRetainedRevocation(reviewed, fingerprint: fingerprint)
    let beforeAcknowledgement = try await InventoryStateAcceptance.report(snapshot: reviewed, fingerprint: fingerprint,
        store: store, cryptography: crypto, upgradeState: true)
    try await store.acknowledgeObsolete(fingerprint, as: .revoked, at: now.addingTimeInterval(1))
    let revoked = await store.snapshot()
    let old = try await InventoryStateAcceptance.report(snapshot: revoked, fingerprint: fingerprint,
        store: store, cryptography: crypto, upgradeState: true)
    try check(old.phase == "reviewed-revoked7" && old.upgrade?.classificationCounts == ["ordinary": 7]
        && old.deliveryCounts == ["delivered": 1] && old.reviewCounts == ["confirmedSecret": 1, "falsePositive": 1, "unreviewed": 5]
        && old.payloadRowCount == 8 && old.revokedMarkerCount == 1, "upgrade-state-retains-reviewed-revoked-content-and-delivery")
    try check(InventoryStateAcceptance.phase(revoked, fingerprint: fingerprint) == "unexpected",
        "upgrade-state-does-not-widen-ordinary-inventory-phase")
    for domain in Set(old.digests.keys).subtracting(["obsoleteMarkers"]) {
        try check(old.digests[domain] == beforeAcknowledgement.digests[domain], "upgrade-state-acknowledgement-changes-only-marker")
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let decoder = JSONDecoder()
    func changed(_ snapshot: InventorySnapshot, from: String, to: String) throws -> InventorySnapshot {
        let text = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
        guard text.contains(from) else { throw InventoryStateAssertionFailure.failed("upgrade-state-negative-fixture-missing") }
        return try decoder.decode(InventorySnapshot.self, from: Data(text.replacingOccurrences(of: from, with: to).utf8))
    }
    let wrongHost = try changed(reviewed, from: "standalone-cli", to: "t3")
    do {
        try InventoryStateAcceptance.requireRetainedRevocation(wrongHost, fingerprint: fingerprint)
        throw InventoryStateAssertionFailure.failed("upgrade-state-accepted-wrong-source-host")
    } catch InventoryStateAcceptance.Failure.unexpectedInventory { }
    try await store.close()
    store = try await ProtectedStore.open(at: root, cryptography: crypto)
    let cold = try await InventoryStateAcceptance.report(snapshot: await store.snapshot(), fingerprint: fingerprint,
        store: store, cryptography: crypto, upgradeState: true)
    try check(encoder.encode(old) == encoder.encode(cold), "upgrade-state-full-revoked-and-reviewed-records-survive-cold-open")
    guard let permit = await store.processingPermit() else { throw InventoryStateAssertionFailure.failed("upgrade-state-replay-permit") }
    for (analysis, payloads) in inputs {
        let transition = try await store.commit(analysis, payloads: payloads, permit: permit)
        try check(transition.outcome == .replay, "upgrade-state-old-source-replay")
    }
    let reread = try await InventoryStateAcceptance.report(snapshot: await store.snapshot(), fingerprint: fingerprint,
        store: store, cryptography: crypto, upgradeState: true)
    try check(encoder.encode(old) == encoder.encode(reread), "upgrade-state-replay-preserves-nondefault-state")
    try await appendFixture("0.162.1", at: now.addingTimeInterval(60))
    let combined = await store.snapshot()
    let upgraded = try await InventoryStateAcceptance.report(snapshot: combined, fingerprint: fingerprint,
        store: store, cryptography: crypto, upgradeState: true)
    guard let prior = old.upgrade, let next = upgraded.upgrade else { throw InventoryStateAssertionFailure.failed("upgrade-state-report-missing") }
    try check(upgraded.phase == "reviewed-revoked14" && next.classificationCounts == ["ordinary": 7, "obsolete": 7]
        && next.producerClassificationCounts == ["0.160.1": ["ordinary": 7], "0.162.1": ["obsolete": 7]]
        && next.producerReviewCounts["0.162.1"] == ["unreviewed": 7]
        && next.producerReviewCounts["0.160.1"] == prior.producerReviewCounts["0.160.1"]
        && next.producerOccurrenceDigests["0.160.1"] == prior.producerOccurrenceDigests["0.160.1"]
        && upgraded.deliveryCounts == ["delivered": 1] && upgraded.payloadRowCount == 15,
        "upgrade-state-new-source-is-obsolete-with-old-reviews-and-delivery-unchanged")
    try check(prior.recordStableDigests == next.recordStableDigests && next.recordTimesMatchOccurrences
        && old.digests["records"] != upgraded.digests["records"]
        && old.digests["obsoleteMarkers"] == upgraded.digests["obsoleteMarkers"]
        && old.digests["alerts"] == upgraded.digests["alerts"], "upgrade-state-record-allows-only-observed-time-extension")
    for invalid in [try changed(combined, from: "\"obsolete\"", to: "\"ordinary\""),
                    try changed(combined, from: "0.162.1", to: "0.160.1"),
                    try changed(combined, from: "\"confirmedSecret\"", to: "\"unreviewed\""),
                    try changed(combined, from: "\"delivered\"", to: "\"pending\"")] {
        try check(InventoryStateAcceptance.phase(invalid, fingerprint: fingerprint, upgradeState: true) == "unexpected",
            "upgrade-state-rejects-ordinary-new-content-same-producer-or-reset-user-state")
    }
    let swappedText = String(decoding: try encoder.encode(combined), as: UTF8.self)
        .replacingOccurrences(of: "\"ordinary\"", with: "\"TEMP_CLASSIFICATION\"")
        .replacingOccurrences(of: "\"obsolete\"", with: "\"ordinary\"")
        .replacingOccurrences(of: "\"TEMP_CLASSIFICATION\"", with: "\"obsolete\"")
    let swapped = try decoder.decode(InventorySnapshot.self, from: Data(swappedText.utf8))
    try check(InventoryStateAcceptance.phase(swapped, fingerprint: fingerprint, upgradeState: true) == "unexpected",
        "upgrade-state-rejects-swapped-old-new-classifications")
    var changedRecords = combined.records
    guard let record = changedRecords[fingerprint] else { throw InventoryStateAssertionFailure.failed("upgrade-state-record") }
    guard var recordJSON = try JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any] else {
        throw InventoryStateAssertionFailure.failed("upgrade-state-record-json")
    }
    recordJSON["lastOccurrenceAt"] = now.addingTimeInterval(900).timeIntervalSinceReferenceDate
    changedRecords[fingerprint] = try decoder.decode(InventoryRecord.self, from: JSONSerialization.data(withJSONObject: recordJSON))
    let mismatched = InventorySnapshot(records: changedRecords, occurrences: combined.occurrences)
    try check(!InventoryStateAcceptance.recordTimesMatchOccurrences(mismatched), "upgrade-state-rejects-unexplained-record-time-change")
    try await store.close()
    store = try await ProtectedStore.open(at: root, cryptography: crypto)
    guard let finalPermit = await store.processingPermit() else { throw InventoryStateAssertionFailure.failed("upgrade-state-final-permit") }
    for (analysis, payloads) in inputs { _ = try await store.commit(analysis, payloads: payloads, permit: finalPermit) }
    let final = try await InventoryStateAcceptance.report(snapshot: await store.snapshot(), fingerprint: fingerprint,
        store: store, cryptography: crypto, upgradeState: true)
    try check(encoder.encode(upgraded) == encoder.encode(final), "upgrade-state-both-source-replays-preserve-full-state")
    try await store.close()
    let removedChecks = try await inventoryRemovedUpgradeStateAssertions(root: root.appendingPathComponent("removed"),
        crypto: crypto, fingerprint: fingerprint, inputs: inputs, sources: sources)
    return ["upgrade-state-revocation-retains-reviews-delivery-and-content",
        "upgrade-state-cold-open-and-replay-preserve-full-original-records",
        "upgrade-state-new-producer-adds-only-obsolete-unreviewed-appearances",
        "upgrade-state-rejects-source-state-and-record-time-corruption"] + removedChecks
}

@MainActor
private func inventoryRemovedUpgradeStateAssertions(root: URL, crypto: BackgroundCryptography, fingerprint: ValueFingerprint,
    inputs: [(SourceAnalysis, [ProtectedPayload])], sources: [SourceRecord]) async throws -> [String] {
    func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw InventoryStateAssertionFailure.failed(name) }
    }
    guard inputs.count == 14, sources.count == 14 else { throw InventoryStateAssertionFailure.failed("removed-upgrade-inputs") }
    var store = try await ProtectedStore.open(at: root, cryptography: crypto)
    guard let permit = await store.processingPermit() else { throw InventoryStateAssertionFailure.failed("removed-upgrade-permit") }
    for (analysis, payloads) in inputs.prefix(7) { _ = try await store.commit(analysis, payloads: payloads, permit: permit) }
    let plan = try InventoryStateAcceptance.reviewPlan(await store.snapshot(), fingerprint: fingerprint)
    try await store.recordNotificationDelivery(identifier: plan.notificationIdentifier, state: .delivered)
    try await store.review(plan.confirmed, as: .confirmedSecret)
    try await store.review(plan.falsePositive, as: .falsePositive)
    try InventoryStateAcceptance.requireRetainedRevocation(await store.snapshot(), fingerprint: fingerprint)
    try await store.acknowledgeObsolete(fingerprint, as: .revoked, at: .now)
    _ = try await store.removeContent(for: fingerprint)
    let removed = try await InventoryStateAcceptance.report(snapshot: await store.snapshot(), fingerprint: fingerprint,
        store: store, cryptography: crypto, upgradeState: true, upgradeRemovedState: true)
    guard case nil = removed.upgrade else { throw InventoryStateAssertionFailure.failed("removed-upgrade-retained-report-must-be-absent") }
    try check(removed.phase == "removed-upgrade7" && removed.removedUpgrade?.protectedRecordCount == 0
        && removed.removedUpgrade?.metadataOnlyRecordCount == 0 && removed.removedUpgrade?.recordTimesMatchObsoleteAppearances == true
        && removed.removedUpgrade?.removedLocationDigests.count == 7 && removed.payloadRowCount == 0
        && removed.reviewCounts.isEmpty && removed.deliveryCounts.isEmpty, "removed-upgrade-original-seven-deleted-with-no-retained-state-claim")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try await store.close()
    store = try await ProtectedStore.open(at: root, cryptography: crypto)
    let restored = try await InventoryStateAcceptance.report(snapshot: await store.snapshot(), fingerprint: fingerprint,
        store: store, cryptography: crypto, upgradeState: true, upgradeRemovedState: true)
    try check(encoder.encode(removed) == encoder.encode(restored), "removed-upgrade-exact-deleted-state-survives-cold-open")
    guard let reopenedPermit = await store.processingPermit() else { throw InventoryStateAssertionFailure.failed("removed-upgrade-reopened-permit") }
    for (analysis, payloads) in inputs.prefix(7) {
        let transition = try await store.commit(analysis, payloads: payloads, permit: reopenedPermit)
        try check(transition.outcome == .replay, "removed-upgrade-old-receipts-block-resurrection")
    }
    let profile = sources[0].metadata.identity.session.profileID
    let metadata = try CaptureMetadata(agent: .codex, interface: .standaloneCLI, profileID: profile)
    let witness = InventoryRemovedUpgradeAcceptance(profileID: profile)
    for _ in 0..<256 {
        await witness.observe(.init(sources: []), metadata: metadata, path: .publicHistory, cryptography: crypto)
    }
    let emptyWitness = try await witness.report(snapshot: await store.snapshot(), cryptography: crypto)
    try check(emptyWitness.failure == nil && emptyWitness.observedBatchCount == 0
        && !emptyWitness.allAppearancesHaveCommittedNativeSource, "removed-upgrade-empty-lifecycle-polls-cannot-create-or-exhaust-evidence")
    let sourceBatch = CollectionBatch(sources: sources.suffix(7).map { .init(record: $0) }, observedReaderVersion: "0.162.1")
    await witness.observe(sourceBatch, metadata: metadata, path: .publicHistory, cryptography: crypto)
    let notCommitted = try await witness.report(snapshot: await store.snapshot(), cryptography: crypto)
    try check(notCommitted.matchedAppearanceCount == 0 && !notCommitted.allAppearancesHaveCommittedNativeSource,
        "removed-upgrade-observation-alone-does-not-prove-commit")
    for (analysis, payloads) in inputs.suffix(7) { _ = try await store.commit(analysis, payloads: payloads, permit: reopenedPermit) }
    let combined = await store.snapshot()
    let state = try await InventoryStateAcceptance.report(snapshot: combined, fingerprint: fingerprint,
        store: store, cryptography: crypto, upgradeState: true, upgradeRemovedState: true)
    let evidence = try await witness.report(snapshot: combined, cryptography: crypto)
    try check(state.phase == "removed-upgrade14" && state.payloadRowCount == 0 && state.reviewCounts.isEmpty && state.deliveryCounts.isEmpty
        && state.counts["occurrences"] == 0 && state.counts["obsoleteAppearances"] == 7 && state.counts["records"] == 1
        && state.removedUpgrade?.metadataOnlyRecordCount == 1 && state.removedUpgrade?.protectedRecordCount == 0
        && state.removedUpgrade?.recordTimesMatchObsoleteAppearances == true
        && state.removedUpgrade?.removedLocationDigests == removed.removedUpgrade?.removedLocationDigests,
        "removed-upgrade-new-seven-are-metadata-only-original-seven-stay-removed")
    try check(evidence.failure == nil && evidence.allAppearancesHaveCommittedNativeSource && evidence.matchedAppearanceCount == 7
        && evidence.readerVersions == ["0.162.1"] && evidence.producerAppearanceCounts == ["0.162.1": 7]
        && evidence.producerSessionCounts == ["0.162.1": 1]
        && evidence.producerContentTypeCounts["0.162.1"] == state.removedUpgrade?.obsoleteAppearanceContentTypeCounts
        && evidence.producerAppearanceDigests["0.162.1"] == state.digests["obsoleteAppearances"],
        "removed-upgrade-new-producer-comes-from-committed-native-source-metadata")
    try check(Set(evidence.producerSourceDigests["0.162.1", default: []]).isSubset(of: Set(state.digests["sourceKinds", default: []]))
        && Set(evidence.producerReceiptDigests["0.162.1", default: []]).isSubset(of: Set(state.digests["analysisReceipts", default: []])),
        "removed-upgrade-source-and-receipt-commitments-join-full-ledger")
    for suffix in ["+partial", "+reduced", "-wrong"] {
        let invalidReceipts = Set(combined.analysisReceipts.map { AnalysisReceipt(source: $0.source, revision: $0.revision,
            detectorVersion: BetterleaksSecretDetector.version + suffix) })
        let invalid = InventorySnapshot(obsoleteAppearances: combined.obsoleteAppearances, analysisReceipts: invalidReceipts,
            locationReceipts: combined.locationReceipts, sourceKinds: combined.sourceKinds)
        let result = try await witness.report(snapshot: invalid, cryptography: crypto)
        try check(result.matchedAppearanceCount == 0 && !result.allAppearancesHaveCommittedNativeSource,
            "removed-upgrade-degraded-or-wrong-detector-is-not-full-receipt")
    }
    let unlinked = InventorySnapshot(obsoleteAppearances: combined.obsoleteAppearances,
        analysisReceipts: combined.analysisReceipts, sourceKinds: combined.sourceKinds)
    let unlinkedReport = try await witness.report(snapshot: unlinked, cryptography: crypto)
    try check(!unlinkedReport.allAppearancesHaveCommittedNativeSource && unlinkedReport.matchedAppearanceCount == 0,
        "removed-upgrade-unlinked-appearance-cannot-pass")
    let freshWitness = InventoryRemovedUpgradeAcceptance(profileID: profile)
    let unobserved = try await freshWitness.report(snapshot: combined, cryptography: crypto)
    try check(!unobserved.allAppearancesHaveCommittedNativeSource && unobserved.producerAppearanceCounts.isEmpty,
        "removed-upgrade-saved-profile-version-cannot-stand-in-for-observed-source")
    let foreign = InventoryRemovedUpgradeAcceptance(profileID: "different-profile")
    await foreign.observe(sourceBatch, metadata: metadata, path: .publicHistory, cryptography: crypto)
    try check(foreign.failure == .unsafeScope, "removed-upgrade-foreign-scope-rejected")
    let corrupt = InventoryRemovedUpgradeAcceptance(profileID: profile)
    let original = sources[7]
    let invalidRecord = try SourceRecord(metadata: original.metadata,
        revision: await crypto.revision(canonicalBytes: Data("unrelated revision".utf8)), segments: original.segments)
    await corrupt.observe(.init(sources: [.init(record: invalidRecord)], observedReaderVersion: "0.162.1"),
        metadata: metadata, path: .publicHistory, cryptography: crypto)
    try check(corrupt.failure == .invalidSource, "removed-upgrade-source-revision-must-bind-observed-original-bytes")
    let publicReport = String(decoding: try encoder.encode(evidence), as: UTF8.self)
    try check(!publicReport.contains(InventoryStateAcceptance.fixtureValue)
        && !publicReport.contains(original.metadata.identity.session.sessionID) && !publicReport.contains("owned-item"),
        "removed-upgrade-witness-exports-no-native-identities-or-source-content")
    try await store.close()
    store = try await ProtectedStore.open(at: root, cryptography: crypto)
    guard let finalPermit = await store.processingPermit() else { throw InventoryStateAssertionFailure.failed("removed-upgrade-final-permit") }
    for (analysis, payloads) in inputs { _ = try await store.commit(analysis, payloads: payloads, permit: finalPermit) }
    let final = try await InventoryStateAcceptance.report(snapshot: await store.snapshot(), fingerprint: fingerprint,
        store: store, cryptography: crypto, upgradeState: true, upgradeRemovedState: true)
    try check(encoder.encode(state) == encoder.encode(final), "removed-upgrade-both-source-replays-cannot-resurrect-content")
    try await store.close()
    return ["removed-upgrade-deleted-seven-survive-cold-open-and-original-replay",
        "removed-upgrade-new-seven-have-only-metadata-and-committed-native-provenance",
        "removed-upgrade-witness-rejects-unobserved-unlinked-degraded-foreign-or-corrupt-evidence",
        "removed-upgrade-replay-keeps-zero-payloads-and-original-removal-receipts"]
}


@MainActor
private func claudeInventoryStateAcceptanceAssertions() async throws -> [String] {
    func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw InventoryStateAssertionFailure.failed(name) }
    }
    func rejects(_ name: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw InventoryStateAssertionFailure.failed(name)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-claude-inventory-state-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let crypto = try BackgroundCryptography.ephemeralForTesting()
    var store = try await ProtectedStore.open(at: root, cryptography: crypto)
    let bytes = Data(InventoryStateAcceptance.fixtureValue.utf8)
    let fingerprint = try await crypto.fingerprint(exactBytes: bytes)
    let now = Date()
    let session = try SessionIdentity(provider: .claudeCode, profileID: InventoryStateAcceptance.ClaudeFixture.profile, sessionID: UUID().uuidString.lowercased())
    let fixture = InventoryStateAcceptance.Fixture.claude(session)
    let types: [ContentType] = [.userPrompt, .userPrompt, .userPrompt, .toolOutput, .toolError, .intermediateResponse, .finalResponse]
    let sessionUUID = UUID(uuidString: session.sessionID)!
    var inputs: [(SourceAnalysis, [ProtectedPayload])] = []
    for (index, type) in types.enumerated() {
        let origin = try SourceOrigin(adapterID: "claude-code", adapterVersion: ClaudeAdapter.adapterVersion, agentVersion: InventoryStateAcceptance.ClaudeFixture.version,
            interface: .standaloneCLI, provenance: .live, canonicalization: .sharedUpstreamIdentity)
        let source = try SourceRecord(metadata: SourceRecordMetadata(identity: SourceIdentity(session: session, itemID: "fake-item-\(index)"),
            contentType: type, contentTime: now, observedAt: now, locator: .transcriptByteOffset(documentID: sessionUUID, byteOffset: UInt64(index * 100)), origin: origin),
            revision: await crypto.revision(canonicalBytes: bytes), segments: [SourceSegment(id: "text", utf8: bytes)])
        let extraction = try ExactExtraction(valueUTF8: bytes, location: CanonicalLocation(segmentID: "text", range: UTF8Range(0, bytes.count)), in: source)
        let reference = ProtectedPayloadReference(), excerpt = ProtectedPayloadReference()
        let detection = try LocatedDetection(extraction: extraction, in: source, fingerprint: fingerprint,
            evidence: [DetectionEvidence(rule: RuleIdentity(id: "fake-rule", version: "1"), signal: .strong, reason: .localRule, category: .token),
                       DetectionEvidence(rule: RuleIdentity(id: "fake-other-rule", version: "1"), signal: .ambiguous, reason: .localRule, category: .password)],
            protectedValue: reference, protectedExcerpt: excerpt)
        let analysis = try SourceAnalysis(source: source, detectorVersion: "fake-detector", detections: [detection])
        let payloads = try await [crypto.sealInventory(bytes, binding: PayloadBinding(reference: reference, ownerID: reference.id, kind: .value)),
                                 crypto.sealInventory(bytes, binding: PayloadBinding(reference: excerpt, ownerID: excerpt.id, kind: .excerpt))]
        guard let permit = await store.processingPermit() else { throw InventoryStateAssertionFailure.failed("fixture-permit") }
        _ = try await store.commit(analysis, payloads: payloads, permit: permit)
        inputs.append((analysis, payloads))
    }
    let baseline = await store.snapshot()
    try check(!InventoryStateAcceptance.hasExactRetainedInventory(baseline, fingerprint: fingerprint),
        "claude-inventory-does-not-widen-default-codex-contract")
    let wrongSession = try SessionIdentity(provider: .claudeCode, profileID: session.profileID, sessionID: UUID().uuidString.lowercased())
    try check(!InventoryStateAcceptance.hasExactRetainedInventory(baseline, fingerprint: fingerprint, fixture: .claude(wrongSession)),
        "claude-inventory-rejects-other-session-with-same-counts")
    let encoderForMutation = JSONEncoder(), decoderForMutation = JSONDecoder()
    let encoded = String(decoding: try encoderForMutation.encode(baseline), as: UTF8.self)
    let wrongTypes = try decoderForMutation.decode(InventorySnapshot.self, from: Data(encoded.replacingOccurrences(of: "userPrompt", with: "toolOutput").utf8))
    try check(!InventoryStateAcceptance.hasExactRetainedInventory(wrongTypes, fingerprint: fingerprint, fixture: fixture),
        "claude-inventory-rejects-wrong-content-type-counts")
    let plan = try InventoryStateAcceptance.reviewPlan(baseline, fingerprint: fingerprint, fixture: fixture)
    try check(plan.confirmed != plan.falsePositive && plan.receiptKind == "live", "claude-inventory-state-selects-distinct-reviews-and-real-pending-receipt")
    let other = try await crypto.fingerprint(exactBytes: Data("other fake value".utf8))
    try rejects("claude-inventory-state-refuses-wrong-fingerprint") { _ = try InventoryStateAcceptance.reviewPlan(baseline, fingerprint: other, fixture: fixture) }
    try rejects("claude-inventory-state-refuses-empty-vault") { _ = try InventoryStateAcceptance.reviewPlan(InventorySnapshot(), fingerprint: fingerprint, fixture: fixture) }
    try await store.recordNotificationDelivery(identifier: plan.notificationIdentifier, state: .delivered)
    try await store.review(plan.confirmed, as: .confirmedSecret)
    try await store.review(plan.falsePositive, as: .falsePositive)
    let reviewed = await store.snapshot()
    try check(InventoryStateAcceptance.phase(reviewed, fingerprint: fingerprint, fixture: fixture) == "reviewed", "claude-inventory-state-two-reviews-and-delivery-seed")
    try rejects("claude-inventory-state-refuses-second-seed") { _ = try InventoryStateAcceptance.reviewPlan(reviewed, fingerprint: fingerprint, fixture: fixture) }
    let before = try await InventoryStateAcceptance.report(snapshot: reviewed, fingerprint: fingerprint, store: store, cryptography: crypto, fixture: fixture)
    try check(before.payloadRowCount == 8 && before.availableReferencedPayloadCount == 8 && before.reviewCounts["confirmedSecret"] == 1,
        "claude-inventory-state-measures-protected-payloads-and-full-reviews")
    try await store.close()
    store = try await ProtectedStore.open(at: root, cryptography: crypto)
    let restarted = try await InventoryStateAcceptance.report(snapshot: await store.snapshot(), fingerprint: fingerprint, store: store, cryptography: crypto, fixture: fixture)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try check(encoder.encode(before) == encoder.encode(restarted), "claude-inventory-state-full-digests-survive-restart")
    guard let permit = await store.processingPermit() else { throw InventoryStateAssertionFailure.failed("fixture-restart-permit") }
    for (analysis, payloads) in inputs {
        let transition = try await store.commit(analysis, payloads: payloads, permit: permit)
        try check(transition.outcome == .replay, "claude-inventory-state-replay-is-genuine-reconciliation")
    }
    let replayed = try await InventoryStateAcceptance.report(snapshot: await store.snapshot(), fingerprint: fingerprint, store: store, cryptography: crypto, fixture: fixture)
    try check(encoder.encode(before) == encoder.encode(replayed), "claude-inventory-state-replay-preserves-reviews-and-delivered-receipt")
    try await store.acknowledgeObsolete(fingerprint, as: .revoked, at: now)
    _ = try await store.removeContent(for: fingerprint)
    let removed = try await InventoryStateAcceptance.report(snapshot: await store.snapshot(), fingerprint: fingerprint, store: store, cryptography: crypto, fixture: fixture)
    try check(removed.phase == "removed" && removed.payloadRowCount == 0 && removed.removedLocationReceiptCount == 7,
        "claude-inventory-state-removal-retains-obsolete-recognition-and-deletes-payload-rows")
    try await store.close()
    store = try await ProtectedStore.open(at: root, cryptography: crypto)
    guard let finalPermit = await store.processingPermit() else { throw InventoryStateAssertionFailure.failed("fixture-final-permit") }
    for (analysis, payloads) in inputs { _ = try await store.commit(analysis, payloads: payloads, permit: finalPermit) }
    let final = try await InventoryStateAcceptance.report(snapshot: await store.snapshot(), fingerprint: fingerprint, store: store, cryptography: crypto, fixture: fixture)
    try check(encoder.encode(removed) == encoder.encode(final), "claude-inventory-state-cold-replay-cannot-resurrect-deleted-content-or-alerts")
    try await store.close()
    return ["claude-inventory-fixed-seven-appearance-contract-and-default-codex-isolation",
        "claude-inventory-exact-session-and-type-count-boundary",
        "claude-inventory-full-review-and-delivery-values-survive-restart",
        "claude-inventory-obsolete-removal-and-payload-absence-survive-replay"]
        + (try claudeInventoryDescriptorAssertions())
}

@MainActor
private func claudeInventoryDescriptorAssertions() throws -> [String] {
    func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw InventoryStateAssertionFailure.failed(name) }
    }
    func rejects(_ name: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw InventoryStateAssertionFailure.failed(name)
    }
    let fm = FileManager.default
    // Recovery admission uses POSIX realpath equality. Foundation can preserve a
    // /var alias when resolving a not-yet-created temporary child.
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("spillcheck-claude-descriptor-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }
    for name in ["claude", "claude/projects", "claude/projects/inventory"] {
        try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func write(_ bytes: Data, _ path: URL) throws {
        try bytes.write(to: path, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    let id = UUID().uuidString.lowercased()
    let source = root.appendingPathComponent("claude/projects/inventory/" + id + ".jsonl")
    let bytes = Data("{\"ownedFake\":true}\n".utf8)
    try write(bytes, source)
    try write(Data(repeating: 7, count: 32), root.appendingPathComponent("run-token"))
    let descriptor: [String: Any] = ["schemaVersion": 1, "sessionID": id, "sourcePath": source.path,
        "sourceSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
    let descriptorPath = root.appendingPathComponent("claude-inventory.json")
    try write(JSONSerialization.data(withJSONObject: descriptor), descriptorPath)
    let arguments = ["--store-directory", root.appendingPathComponent("protected-store").path,
        "--acceptance-recovery-root", root.path, "--acceptance-recovery-token", root.appendingPathComponent("run-token").path,
        "--acceptance-report", root.appendingPathComponent("report.json").path,
        "--acceptance-finish-file", root.appendingPathComponent("finish").path,
        "--acceptance-recovery-worker", "--acceptance-recovery-inventory-state", "--acceptance-claude-inventory",
        "--acceptance-no-profile-catchup", "--claude-profile", InventoryStateAcceptance.ClaudeFixture.profile,
        "--claude-version", InventoryStateAcceptance.ClaudeFixture.version,
        "--claude-source-root", root.appendingPathComponent("claude/projects").path,
        "--claude-authorized-host", "standalone-cli", "--claude-interface", "standalone-cli"]
    let recovery: DisposableRecoveryConfiguration
    do { recovery = try DisposableRecoveryConfiguration(arguments: arguments) }
    catch { throw InventoryStateAssertionFailure.failed("claude-inventory-descriptor-disposable-configuration") }
    guard let admitted = try InventoryStateAcceptance.ClaudeFixture.fromArguments(arguments, recovery: recovery) else {
        throw InventoryStateAssertionFailure.failed("claude-inventory-descriptor-not-admitted")
    }
    let replay = try admitted.retryDescriptor()
    try check(replay.sourceURL == source && replay.session == admitted.session && replay.scope == admitted.scope,
        "claude-inventory-replay-exactly-binds-original-source-and-session")
    try rejects("claude-inventory-requires-disposable-worker") {
        _ = try InventoryStateAcceptance.ClaudeFixture.fromArguments(arguments, recovery: nil)
    }
    for extras in [["--acceptance-claude-inventory"], ["--claude-authorized-host", "t3"],
        ["--claude-active-source", source.path, "--claude-session", id], ["--acceptance-recovery-install-profile"]] {
        try rejects("claude-inventory-rejects-extra-route-or-action") {
            _ = try InventoryStateAcceptance.ClaudeFixture.fromArguments(arguments + extras, recovery: recovery)
        }
    }
    for (key, value) in [("schemaVersion", true as Any), ("sourcePath", root.appendingPathComponent("outside.jsonl").path as Any),
        ("sessionID", UUID().uuidString.lowercased() as Any), ("sourceSHA256", String(repeating: "0", count: 64) as Any),
        ("appearanceCount", 7 as Any)] {
        var changed = descriptor; changed[key] = value
        try write(JSONSerialization.data(withJSONObject: changed), descriptorPath)
        try rejects("claude-inventory-rejects-unbound-or-expanded-descriptor") {
            _ = try InventoryStateAcceptance.ClaudeFixture.fromArguments(arguments, recovery: recovery)
        }
    }
    try write(JSONSerialization.data(withJSONObject: descriptor), descriptorPath)
    // The retained in-memory binding remains authoritative even if a caller rewrites the descriptor.
    try write(Data("{\"changedFake\":true}\n".utf8), source)
    try rejects("claude-inventory-replay-refuses-changed-original") { _ = try admitted.retryDescriptor() }
    try write(bytes, source)
    try fm.removeItem(at: source)
    let decoy = root.appendingPathComponent("decoy.jsonl")
    try write(bytes, decoy)
    try fm.createSymbolicLink(at: source, withDestinationURL: decoy)
    try rejects("claude-inventory-replay-refuses-source-symlink") { _ = try admitted.retryDescriptor() }
    try fm.removeItem(at: source)
    try fm.linkItem(at: decoy, to: source)
    try rejects("claude-inventory-replay-refuses-hardlink") { _ = try admitted.retryDescriptor() }
    try fm.removeItem(at: source)
    try write(bytes, source)
    try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
    try rejects("claude-inventory-replay-refuses-public-source") { _ = try admitted.retryDescriptor() }
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
    let directory = root.appendingPathComponent("claude/projects/inventory")
    let moved = root.appendingPathComponent("moved")
    try fm.moveItem(at: directory, to: moved)
    try fm.createSymbolicLink(at: directory, withDestinationURL: moved)
    try rejects("claude-inventory-replay-refuses-ancestor-symlink") { _ = try admitted.retryDescriptor() }
    try fm.removeItem(at: directory)
    try fm.moveItem(at: moved, to: directory)
    try write(Data(repeating: 65, count: 64 * 1024 + 1), source)
    try rejects("claude-inventory-replay-refuses-source-budget-exhaustion") { _ = try admitted.retryDescriptor() }
    try write(bytes, source)
    _ = try admitted.retryDescriptor()
    let record = try SourceRecord(metadata: .init(identity: .init(session: admitted.session, itemID: "owned-item"),
        contentType: .userPrompt, contentTime: .now, observedAt: .now,
        locator: .transcriptByteOffset(documentID: UUID(uuidString: id)!, byteOffset: 0),
        origin: .init(adapterID: "claude-code", adapterVersion: ClaudeAdapter.adapterVersion,
            agentVersion: InventoryStateAcceptance.ClaudeFixture.version, interface: .standaloneCLI, provenance: .live,
            canonicalization: .exclusiveAuthority)), revision: .init(keyedDigest: Data(repeating: 1, count: 32)),
        segments: [.init(id: "text", utf8: bytes)])
    let metadata = try CaptureMetadata(agent: .claudeCode, interface: .standaloneCLI, profileID: admitted.session.profileID)
    let batch = CollectionBatch(sources: [.init(record: record, context: .init(sessionIdentifier: id, transcriptPath: source.path))])
    try check(admitted.validBatch(batch, metadata: metadata, path: .versionedTranscript), "claude-inventory-observes-exact-original-batch")
    let outside = CollectionBatch(sources: [.init(record: record, context: .init(sessionIdentifier: id, transcriptPath: decoy.path))])
    try check(!admitted.validBatch(outside, metadata: metadata, path: .versionedTranscript)
        && !admitted.validBatch(batch, metadata: metadata, path: .hook), "claude-inventory-refuses-foreign-file-or-route")
    return ["claude-inventory-descriptor-is-private-bounded-fixed-and-disposable",
        "claude-inventory-exact-replay-refuses-changed-symlink-hardlink-public-or-oversized-source",
        "claude-inventory-batch-witness-rejects-other-source-path-or-route"]
}
