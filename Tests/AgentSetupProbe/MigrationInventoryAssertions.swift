import Foundation
@_spi(Testing) import SpillcheckCore

enum MigrationInventoryAssertionFailure: Error { case failed(String) }

private func migrationRequire(_ condition: Bool, _ stage: String) throws {
    guard condition else { throw MigrationInventoryAssertionFailure.failed(stage) }
}

/// Real encrypted store mutations around profile migration, with constructed detections and
/// ephemeral keys. This exercises retained user state, not a scanner or system authentication.
@MainActor
struct MigrationInventoryAssertions {
    private struct Input {
        let index: Int
        let analysis: SourceAnalysis
        let captureBody: Data
        let captureID: UUID
        let payload: ProtectedPayload
    }

    private let inputs: [Input]
    private let expected: InventorySnapshot
    private let expectedNotifications: [MaskedNotification]
    private let expectedCaptureReceipts: [UUID]
    private let contentTime: Date

    static func seed(store: ProtectedStore, cryptography: BackgroundCryptography,
                     profile: AgentProfileDraft) async throws -> Self {
        let now = Date()
        var inputs: [Input] = []
        for index in 0..<4 {
            let prepared = try await prepare(index: index, profile: profile,
                interface: profile.interface, contentTime: now, cryptography: cryptography)
            // The fixture starts before the verification packet is queued, so this claim must
            // belong to this synthetic finding. Its body never reaches a real provider.
            let body = Data("SYNTHETIC_MIGRATION_CAPTURE_\(index)".utf8)
            guard let permit = await store.processingPermit(),
                  case .inserted(let captureID) = try await store.enqueue(body, capturedAt: now, permit: permit),
                  let capture = try await store.nextPending(at: .now, permit: permit),
                  capture.id == captureID else {
                throw MigrationInventoryAssertionFailure.failed("migration-seed-capture-unavailable")
            }
            let transition = try await store.commit(prepared.analysis, payloads: [prepared.payload],
                consuming: capture, permit: permit)
            try migrationRequire(transition.outcome == .processed && transition.insertedOccurrenceIDs.count == 1
                && transition.alerts.count == 1, "migration-seed-did-not-create-finding-and-alert")
            guard let occurrenceID = transition.insertedOccurrenceIDs.first, let alert = transition.alerts.first else {
                throw MigrationInventoryAssertionFailure.failed("migration-seed-missing-disposition-target")
            }
            switch index {
            case 0:
                try await store.recordAlertDelivery(alert.id, state: .delivered)
                try await store.review(occurrenceID, as: .confirmedSecret)
            case 1:
                // A false-positive decision withdraws its still-pending notification.
                try await store.review(occurrenceID, as: .falsePositive)
            case 2:
                let fingerprint = prepared.analysis.detections[0].fingerprint
                try await store.acknowledgeObsolete(fingerprint, as: .revoked, at: now)
                _ = try await store.removeContent(for: fingerprint)
            default:
                break // Keep an eligible pending alert as a positive notification control.
            }
            inputs.append(Input(index: index, analysis: prepared.analysis, captureBody: body,
                captureID: captureID, payload: prepared.payload))
        }
        let expected = await store.snapshot()
        let notifications = try await store.pendingNotifications()
        let receipts = try await store.captureIdentitiesForTesting()
        try migrationRequire(expected.records.count == 3 && expected.occurrences.count == 3
            && Set(expected.occurrences.values.map(\.review)) == [.confirmedSecret, .falsePositive, .unreviewed]
            && expected.obsoleteMarkers.count == 1 && expected.analysisReceipts.count == 4
            && expected.locationReceipts.count == 4 && expected.alertDecisions.count == 2
            && Set(expected.alertDecisions.values.map(\.delivery)) == [.delivered, .pending]
            && notifications.count == 1 && receipts.pending.isEmpty && receipts.consumed.count == 4,
            "migration-seed-state-incomplete")
        return Self(inputs: inputs, expected: expected, expectedNotifications: notifications,
            expectedCaptureReceipts: receipts.consumed, contentTime: now)
    }

    func assertPreserved(in store: ProtectedStore) async throws {
        let actual = await store.snapshot()
        try migrationRequire(actual.records == expected.records && actual.occurrences == expected.occurrences,
            "migration-lost-value-identity-or-review-disposition")
        try migrationRequire(actual.obsoleteMarkers == expected.obsoleteMarkers
            && actual.obsoleteAppearances == expected.obsoleteAppearances,
            "migration-lost-obsolete-value-state")
        try migrationRequire(actual.analysisReceipts == expected.analysisReceipts
            && actual.locationReceipts == expected.locationReceipts
            && actual.strongSignalReceipts == expected.strongSignalReceipts,
            "migration-lost-analysis-location-or-alert-receipts")
        try migrationRequire(actual.alertDecisions == expected.alertDecisions
            && actual.valueLabels == expected.valueLabels
            && actual.conversationLabels == expected.conversationLabels
            && actual.nextValueLabel == expected.nextValueLabel,
            "migration-changed-alert-delivery-or-stable-labels")
        try migrationRequire(try await store.pendingNotifications() == expectedNotifications,
            "migration-restored-withdrawn-or-delivered-notification")
        try migrationRequire(try await store.captureIdentitiesForTesting().consumed == expectedCaptureReceipts,
            "migration-lost-consumed-capture-receipts")
        for input in inputs {
            let retained = try await store.payload(input.payload.binding.reference)
            if input.index == 2 {
                try migrationRequire(retained == nil, "migration-resurrected-deleted-obsolete-payload")
            } else {
                try migrationRequire(retained == input.payload, "migration-lost-encrypted-value-payload")
            }
        }
    }

    func replay(in store: ProtectedStore, profile: AgentProfileDraft,
                cryptography: BackgroundCryptography) async throws {
        guard let permit = await store.processingPermit() else {
            throw MigrationInventoryAssertionFailure.failed("migration-replay-permit-unavailable")
        }
        let otherHost: AgentInterface = profile.interface == .t3 ? .standaloneCLI : .t3
        for input in inputs {
            let replay = try await Self.prepare(index: input.index, profile: profile,
                interface: otherHost, contentTime: contentTime, cryptography: cryptography)
            try migrationRequire(replay.analysis.source.identity == input.analysis.source.identity
                && replay.analysis.revision == input.analysis.revision
                && replay.analysis.detections[0].fingerprint == input.analysis.detections[0].fingerprint,
                "migration-replay-changed-native-source-or-value-identity")
            let transition = try await store.commit(replay.analysis, payloads: [replay.payload], permit: permit)
            try migrationRequire(transition.outcome == .replay && transition.insertedOccurrenceIDs.isEmpty
                && transition.createdValueIDs.isEmpty && transition.alerts.isEmpty
                && transition.insertedObsoleteAppearanceIDs.isEmpty,
                "migration-replay-duplicated-occurrence-value-or-alert")
            try migrationRequire(try await store.payload(replay.payload.binding.reference) == nil,
                "migration-replay-retained-redundant-payload")
            guard case .alreadyProcessed(let receiptID) = try await store.enqueue(input.captureBody,
                id: input.captureID, capturedAt: contentTime, permit: permit), receiptID == input.captureID else {
                throw MigrationInventoryAssertionFailure.failed("migration-requeued-consumed-capture")
            }
        }
        try await assertPreserved(in: store)
    }

    private static func prepare(index: Int, profile: AgentProfileDraft, interface: AgentInterface,
                                contentTime: Date, cryptography: BackgroundCryptography) async throws
        -> (analysis: SourceAnalysis, payload: ProtectedPayload) {
        let value = Data("SYNTHETIC_MIGRATION_VALUE_\(index)_é🙂".utf8)
        let session = try SessionIdentity(provider: profile.provider, profileID: profile.profileID,
            sessionID: "synthetic-retained-state-session")
        let origin = try SourceOrigin(adapterID: "migration-fixture", adapterVersion: "1",
            agentVersion: profile.version, interface: interface, provenance: .live,
            canonicalization: .sharedUpstreamIdentity)
        let source = try SourceRecord(metadata: SourceRecordMetadata(
            identity: SourceIdentity(session: session, itemID: "synthetic-retained-item-\(index)"),
            contentType: .userPrompt, contentTime: contentTime, observedAt: contentTime, origin: origin),
            revision: await cryptography.revision(canonicalBytes: value),
            segments: [SourceSegment(id: "text", utf8: value)])
        let extraction = try ExactExtraction(valueUTF8: value,
            location: CanonicalLocation(segmentID: "text", range: UTF8Range(0, value.count)), in: source)
        let reference = ProtectedPayloadReference()
        let finding = try LocatedDetection(extraction: extraction, in: source,
            fingerprint: await cryptography.fingerprint(exactBytes: value),
            evidence: [DetectionEvidence(rule: RuleIdentity(id: "synthetic-migration-rule", version: "1"),
                signal: .strong, reason: .localRule, category: .token)], protectedValue: reference)
        let payload = try await cryptography.sealInventory(value,
            binding: PayloadBinding(reference: reference, ownerID: reference.id, kind: .value))
        return (try SourceAnalysis(source: source, detectorVersion: "synthetic-migration-detector-1",
            detections: [finding]), payload)
    }
}

/// A schema-one preference can predate connection proofs. Ordinary load must keep it
/// unverified while committing schema-three authorization and preserving queued work.
@MainActor
func schemaOneWithoutConnectionProofAssertions() async throws -> [String] {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("spillcheck-profile-migration-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home"), reader = root.appendingPathComponent("reader")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try Data("#!/bin/sh\nprintf 'codex-cli 0.161.0\\n'\n".utf8).write(to: reader)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: reader.path)
    let profile = AgentProfileDraft(provider: .codex, executablePath: reader.path, homePath: home.path,
        version: "0.161.0", installed: true)
    var row = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
    row.removeValue(forKey: "authorizedHosts")
    row.removeValue(forKey: "connectionProof")
    let original = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "profiles": [row]], options: [.sortedKeys])
    let crypto = try BackgroundCryptography.ephemeralForTesting(), directory = root.appendingPathComponent("store")
    var store = try await ProtectedStore.open(at: directory, cryptography: crypto)
    try await store.setProtectedPreference(original, for: .agentProfiles)
    guard let permit = await store.processingPermit() else { throw MigrationInventoryAssertionFailure.failed("migration-permit") }
    _ = try await store.enqueue(Data("SYNTHETIC_PENDING_PROFILE_MIGRATION".utf8), capturedAt: .now, permit: permit)
    let before = try await store.legacyMigrationRowsForTesting().rows["captures"]
    for expectedLoadedSchema in [1, 3] {
        let controller = AgentSetupController(store: store, helperURL: root.appendingPathComponent("helper"),
            socketURL: directory.appendingPathComponent("capture.sock"))
        try await controller.load()
        let state = await controller.snapshot(), schemas = await controller.profileSchemaVersions()
        try migrationRequire(state.profiles[.codex] == profile && state.profiles[.codex]?.connectionProof == nil
            && state.states[.codex] != .connected && state.verificationPrompts.isEmpty,
            "schema-one-migration-must-preserve-original-profile-without-invented-proof")
        try migrationRequire(schemas.loaded == expectedLoadedSchema && schemas.saved == 3,
            "schema-one-migration-must-commit-current-preference-before-restart")
        try migrationRequire(try await store.legacyMigrationRowsForTesting().rows["captures"] == before,
            "schema-one-migration-must-not-claim-or-rewrite-pending-work")
        let identities = try await store.captureIdentitiesForTesting()
        try migrationRequire(identities.pending.count == 1 && identities.consumed.isEmpty,
            "schema-one-migration-must-not-consume-pending-work")
        try await store.close()
        if expectedLoadedSchema == 1 { store = try await ProtectedStore.open(at: directory, cryptography: crypto) }
    }
    return ["schema-one-without-connection-proof-migrates-and-restarts-with-original-profile-and-pending-work"]
}
