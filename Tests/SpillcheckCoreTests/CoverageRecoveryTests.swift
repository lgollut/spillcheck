import Foundation
import GRDB
import Testing
@_spi(Testing) @testable import SpillcheckCore

@Suite("Durable scoped omissions and health incidents")
struct CoverageRecoveryTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-recovery-\(UUID())")
    }

    private func scope(interface: AgentInterface = .standaloneCLI) -> CollectionScope {
        CollectionScope(provider: .codex, profileID: "private-native-profile", interface: interface, path: .publicHistory)
    }

    private func reference(item: String, at time: Date, contract: String = "contract-before") throws -> CoverageRecoveryReference {
        .init(session: try SessionIdentity(provider: .codex, profileID: "private-native-profile", sessionID: "private-native-session"),
              locator: .upstreamItem, itemID: item, contentTime: time, parserContract: contract)
    }

    private func gap(_ reference: CoverageRecoveryReference, interface: AgentInterface = .standaloneCLI,
                     required: Bool = true) -> CoverageGap {
        .init(reason: .malformedSource, scope: scope(interface: interface), contentType: .toolOutput,
              recovery: reference, isRequiredFormatFailure: required)
    }

    private func complete(_ store: ProtectedStore, gaps: [CoverageGap] = [],
                          recovered: [CoverageRecoveryReference] = [], at time: Date) async throws {
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(Data("synthetic controlled capture".utf8), capturedAt: time, permit: permit, at: time)
        let capture = try #require(try await store.nextPending(at: time, permit: permit))
        try await store.completeCapture(capture, coverageGaps: gaps, recoveredReferences: recovered, permit: permit, at: time)
    }

    @Test func legacyGapRecordsDecodeWithoutPromotingFailureOrRecovery() throws {
        let decoded = try JSONDecoder().decode(CoverageGap.self, from: Data(#"{"reason":"unsupportedVersion"}"#.utf8))
        #expect(decoded.scope == nil)
        #expect(decoded.recovery == nil)
        #expect(decoded.isRequiredFormatFailure == nil)
        #expect(decoded.operation == nil)
    }

    @Test func failedCompletionKeepsCheckpointQueueAndOmissionsUnchanged() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto, failureInjector: {
            if $0 == .beforeProcessingCommit { throw StorageError.injectedFailure }
        })
        let now = Date(), documentID = UUID()
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(Data("synthetic controlled capture".utf8), capturedAt: now, permit: permit, at: now)
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        let checkpoint = SourceCheckpoint(capabilityID: UUID(), sourceDocumentID: documentID,
            revision: try ContentRevision(keyedDigest: Data(repeating: 1, count: 32)), byteOffset: 100)
        let omission = gap(try reference(item: "private-native-item", at: now))
        await #expect(throws: StorageError.injectedFailure) {
            try await store.completeCapture(capture, checkpoints: [checkpoint], coverageGaps: [omission], permit: permit, at: now)
        }
        #expect(try await store.queueStatistics().count == 1)
        #expect(try await store.checkpoint(documentID: documentID) == nil)
        #expect(try await store.coverageOmissions().isEmpty)
        #expect(try await store.coverageGaps().isEmpty)
        #expect(try await store.healthIncidents().isEmpty)
        try await store.close()
    }

    @Test func recoveryAndIncidentReceiptsSurviveRestartAndPreserveOtherOmissions() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date()
        let first = try reference(item: "private-item-one", at: now)
        let second = try reference(item: "private-item-two", at: now)
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        try await complete(store, gaps: [gap(first), gap(second), gap(first)], at: now)
        #expect(try await store.coverageOmissions().count == 2)
        let firstOmissionID = try #require(try await store.coverageOmissions().first(where: { $0.gap.recovery == first })?.id)
        #expect(await store.snapshot().analysisReceipts.isEmpty)
        let notification = try #require(try await store.pendingNotifications().first)
        #expect(notification.title == "Collection needs attention")
        #expect(!notification.body.contains("private-native"))
        #expect(!notification.body.contains("private-item"))
        let incidentID = try #require(try await store.healthIncidents().first?.id)
        try await store.recordNotificationDelivery(identifier: notification.identifier, state: .delivered)
        try await store.close()

        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        #expect(try await reopened.pendingNotifications().isEmpty)
        #expect(try await reopened.healthIncidents().first?.id == incidentID)
        #expect(try await reopened.notificationCanRemain(notification))
        // A source commit at another native location cannot resolve the omission.
        let permit = try #require(await reopened.processingPermit())
        let unrelated = try sourceRecord(item: "readable-sibling")
        _ = try await reopened.commit(SourceAnalysis(source: unrelated, detectorVersion: "fixture", detections: []), payloads: [], permit: permit)
        #expect(try await reopened.coverageOmissions().count == 2)
        try await complete(reopened, recovered: [first], at: now)
        #expect(try await reopened.coverageOmissions().count == 1)
        #expect(try await reopened.healthIncidents().count == 1)
        try await complete(reopened, recovered: [second], at: now)
        #expect(try await reopened.coverageOmissions().isEmpty)
        #expect(try await reopened.healthIncidents().isEmpty)
        #expect(try await reopened.coverageOmissions(includeRecovered: true).allSatisfy { $0.state == .recovered })
        #expect(!(try await reopened.notificationCanRemain(notification)))
        #expect(try await reopened.pendingNotifications().isEmpty)
        // A demonstrated re-failure of the same item reopens its omission without extending
        // original source age, and receives a new incident without changing old delivery history.
        let later = now.addingTimeInterval(24 * 60 * 60)
        let failedAgain = try reference(item: "private-item-one", at: later, contract: "contract-after")
        try await complete(reopened, gaps: [gap(failedAgain)], at: later)
        let reopenedOmission = try #require(try await reopened.coverageOmissions().first)
        #expect(reopenedOmission.id == firstOmissionID)
        #expect(reopenedOmission.state == .blocked)
        #expect(reopenedOmission.resolvedAt == nil)
        // SQLite stores Unix-epoch Double values; converting back to Date can round by less
        // than a microsecond. This bound still rejects any renewal to the 24-hour-later failure.
        let preservedContentTime = try #require(reopenedOmission.gap.recovery?.contentTime)
        #expect(abs(reopenedOmission.firstObservedAt.timeIntervalSince(now)) < 0.000001)
        #expect(abs(preservedContentTime.timeIntervalSince(now)) < 0.000001)
        #expect(reopenedOmission.gap.recovery?.parserContract == "contract-after")
        #expect(try await reopened.healthIncidents().first?.id != incidentID)
        #expect(try await reopened.healthIncident(id: incidentID)?.delivery == .delivered)
        #expect(try await reopened.healthIncident(id: incidentID)?.resolvedAt != nil)
        #expect(try await reopened.pendingNotifications().count == 1)
        try await reopened.close()
    }

    @Test func unfamiliarVersionsAndIntentionallyUnsupportedContentDoNotNotify() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let now = Date()
        try await complete(store, gaps: [
            .init(reason: .unsupportedVersion, scope: scope(), contentType: .toolOutput, isRequiredFormatFailure: true),
            .init(reason: .unsupportedContent, scope: scope(), contentType: .toolOutput,
                  recovery: try reference(item: "unsupported-image", at: now), isRequiredFormatFailure: false)
        ], at: now)
        #expect(try await store.healthIncidents().isEmpty)
        #expect(try await store.pendingNotifications().isEmpty)
        #expect(try await store.coverageOmissions().count == 1)
        try await store.close()
    }

    @Test func recentGapAgingCannotPretendAnOmissionRecovered() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let now = Date(), earlier = now.addingTimeInterval(-2 * 24 * 60 * 60)
        let reference = try reference(item: "private-old-omission", at: earlier)
        try await store.recordCoverageGap(gap(reference), at: earlier)
        #expect(try await store.coverageGaps(since: now.addingTimeInterval(-24 * 60 * 60)).isEmpty)
        #expect(try await store.coverageOmissions(since: now.addingTimeInterval(-HistoricalAuditContext.lookback)).count == 1)
        #expect(try await store.recoverableOmissions(parserContract: "contract-before", at: now).isEmpty)
        #expect(try await store.recoverableOmissions(parserContract: "contract-after", at: now).count == 1)
        let later = now.addingTimeInterval(6 * 24 * 60 * 60)
        #expect(try await store.expireCoverageRecovery(at: later) == 1)
        #expect(try await store.coverageOmissions().first?.state == .unrecoverable)
        #expect(try await store.coverageOmissions().first?.isUnresolved == true)
        #expect(try await store.recoverableOmissions(parserContract: "contract-after", at: later).isEmpty)
        // The loss stays visible, but an incident that can no longer recover cannot stay open
        // forever and silently absorb a later failure with the same identity.
        #expect(try await store.healthIncidents().isEmpty)
        let settled = try #require(try await store.healthIncidents(includeResolved: true).first)
        #expect(settled.resolvedAt != nil)
        try await store.recordCoverageGap(gap(try self.reference(item: "private-new-omission", at: later)), at: later)
        let recurrence = try #require(try await store.healthIncidents().first)
        #expect(recurrence.id != settled.id && recurrence.delivery == .pending)
        #expect(try await store.coverageOmissions().filter(\.isUnresolved).count == 2)
        try await store.close()
    }

    @Test func assessedOperationSettlesDespiteUnrecoverableLinkedLoss() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let earlier = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        let operationFailure = CoverageGap(reason: .malformedSource, scope: scope(), operation: .liveRead,
            isRequiredFormatFailure: true)
        let itemFailure = CoverageGap(reason: .malformedSource, scope: scope(), operation: .liveRead,
            recovery: try reference(item: "private-lost-item", at: earlier), isRequiredFormatFailure: true)
        try await complete(store, gaps: [operationFailure, itemFailure], at: earlier)
        let later = earlier.addingTimeInterval(8 * 24 * 60 * 60)
        #expect(try await store.expireCoverageRecovery(at: later) == 1)
        // Expiry alone cannot settle an operation failure; a fresh successful assessment must.
        #expect(try await store.healthIncidents().count == 1)
        #expect(try await store.resolveHealthIncidents(scope: scope(), operation: .liveRead, at: later) == 1)
        #expect(try await store.healthIncidents().isEmpty)
        try await store.close()
    }

    @Test func requiredFailureLinksAnOpenOmissionFirstRecordedAsOptional() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let now = Date(), position = try reference(item: "private-shared-position", at: now)
        try await complete(store, gaps: [gap(position, required: false), gap(position)], at: now)
        #expect(try await store.coverageOmissions().count == 1)
        #expect(try await store.healthIncidents().count == 1)
        try await complete(store, recovered: [position], at: now)
        #expect(try await store.healthIncidents().isEmpty)
        try await store.close()
    }

    @Test func partialRowCannotResolveItsUnreadBlockAndUnknownSessionCanRecover() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let now = Date(), documentID = UUID()
        let unknown = CoverageRecoveryReference(locator: .transcriptByteOffset(documentID: documentID, byteOffset: 200),
            contentTime: now, parserContract: "before")
        let known = CoverageRecoveryReference(session: try SessionIdentity(provider: .codex,
            profileID: "private-native-profile", sessionID: "private-session"), locator: unknown.locator,
            contentTime: now, parserContract: "after")
        try await complete(store, gaps: [gap(unknown)], at: now)
        try await complete(store, gaps: [gap(known)], recovered: [known], at: now)
        #expect(try await store.coverageOmissions().count == 1)
        try await complete(store, recovered: [known], at: now)
        #expect(try await store.coverageOmissions().isEmpty)
        #expect(try await store.healthIncidents().isEmpty)
        try await store.close()
    }

    @Test func expiredAndExhaustedCapturesRetainOnlyEncryptedScopedLossMetadata() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto,
            limits: .init(maxQueueAge: 1, maxRetryCount: 0))
        let now = Date()
        let profile = "SPILLCHECK_SYNTHETIC_QUEUE_LOSS_PROFILE"
        let rawMarker = "SPILLCHECK_SYNTHETIC_QUEUE_LOSS_RAW_CONTENT"
        let packet = try CapturePacket(metadata: .init(agent: .claudeCode, interface: .t3, profileID: profile),
            eventJSON: JSONEncoder().encode(rawMarker))
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now)
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        try await store.retry(capture, reason: .sourceUnavailable, at: now, permit: permit)
        _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now)
        await store.setMonitoring(enabled: false)
        #expect(try await store.maintainQueue(at: now.addingTimeInterval(2)) == 1)
        #expect(try await store.queueStatistics().count == 0)
        let omissions = try await store.coverageOmissions()
        #expect(omissions.count == 2)
        #expect(omissions.allSatisfy { $0.state == .unrecoverable && $0.gap.recovery == nil })
        #expect(omissions.allSatisfy {
            $0.gap.scope == CollectionScope(provider: .claudeCode, profileID: profile, interface: .t3, path: .hook)
        })
        #expect(Set(omissions.map { $0.gap.reason }) == [.sourceUnavailable, .queueExpired])
        for filename in [ProtectedStore.databaseFilename, ProtectedStore.databaseFilename + "-wal"] {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(filename))
            #expect(bytes.range(of: Data(profile.utf8)) == nil)
            #expect(bytes.range(of: Data(rawMarker.utf8)) == nil)
        }
        try await store.close()
        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        #expect(try await reopened.coverageOmissions().count == 2)
        #expect(try await reopened.healthIncidents().isEmpty)
        try await reopened.close()
    }

    @Test func operationIncidentsDeduplicateAcrossRestartAndResolveOnlyTheProvenScope() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(), selectedScope = scope(interface: .t3)
        let live = CoverageGap(reason: .unsupportedContent, scope: selectedScope,
            operation: .liveRead, isRequiredFormatFailure: true)
        let history = CoverageGap(reason: .unsupportedContent, scope: selectedScope,
            operation: .historicalRead, isRequiredFormatFailure: true)
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        try await complete(store, gaps: [live, history, live], at: now)
        let incidents = try await store.healthIncidents()
        #expect(incidents.count == 2)
        #expect(Set(incidents.compactMap(\.operation)) == [.liveRead, .historicalRead])
        #expect(incidents.allSatisfy { $0.contentType == nil })
        let liveID = try #require(incidents.first(where: { $0.operation == .liveRead })?.id)
        let messages = try await store.pendingNotifications()
        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0.body.contains("T3") && !$0.body.contains("private-native") })
        #expect(messages.contains { $0.body.contains("Live collection") })
        #expect(messages.contains { $0.body.contains("History catch-up") })
        for message in messages { try await store.recordNotificationDelivery(identifier: message.identifier, state: .delivered) }
        try await store.close()

        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        try await complete(reopened, gaps: [live, history], at: now)
        #expect(try await reopened.healthIncidents().count == 2)
        #expect(try await reopened.pendingNotifications().isEmpty)
        // Without a native reference, a readable sibling and capture completion cannot resolve
        // a failed operation. A successful exact route/operation assessment must do it explicitly.
        let readable = try reference(item: "readable-sibling", at: now)
        try await complete(reopened, recovered: [readable], at: now)
        #expect(try await reopened.healthIncidents().count == 2)
        #expect(try await reopened.resolveHealthIncidents(scope: scope(), operation: .liveRead, at: now) == 0)
        try await complete(reopened, gaps: [gap(try reference(item: "content-omission", at: now), interface: .t3)], at: now)
        let nativeLive = try reference(item: "omitted-native-live", at: now)
        let nativeHook = try reference(item: "omitted-native-hook", at: now)
        try await complete(reopened, gaps: [
            .init(reason: .unsupportedContent, scope: selectedScope, operation: .liveRead,
                recovery: nativeLive, isRequiredFormatFailure: true),
            .init(reason: .unsupportedContent, scope: selectedScope, operation: .hookDelivery,
                recovery: nativeHook, isRequiredFormatFailure: true)
        ], at: now)
        // Global operation success cannot settle a known native omission, including an incident
        // that also has a route-level failure requiring a fresh assessment.
        #expect(try await reopened.resolveHealthIncidents(scope: selectedScope, operation: .liveRead, at: now) == 0)
        #expect(try await reopened.resolveHealthIncidents(scope: selectedScope, operation: .hookDelivery, at: now) == 0)
        try await complete(reopened, recovered: [nativeLive], at: now)
        #expect(try await reopened.healthIncident(id: liveID)?.resolvedAt == nil)
        #expect(try await reopened.resolveHealthIncidents(scope: selectedScope, operation: .liveRead, at: now) == 1)
        let remaining = try await reopened.healthIncidents()
        #expect(remaining.count == 3)
        #expect(remaining.contains { $0.operation == .historicalRead })
        #expect(remaining.contains { $0.operation == .hookDelivery })
        #expect(remaining.contains { $0.contentType == .toolOutput && $0.operation == nil })
        try await reopened.close()

        let again = try await ProtectedStore.open(at: directory, cryptography: crypto)
        #expect(try await again.healthIncident(id: liveID)?.resolvedAt != nil)
        try await complete(again, gaps: [live], at: now)
        let newLive = try #require(try await again.healthIncidents().first(where: { $0.operation == .liveRead }))
        #expect(newLive.id != liveID)
        #expect(newLive.delivery == .pending)
        try await again.close()
    }

    @Test func legacyContentIncidentCiphertextAndKeyRetainDeliveredSuppression() async throws {
        struct LegacyKey: Codable {
            let scope: CollectionScope
            let contentType: ContentType
            let reason: CoverageGapReason
        }
        struct LegacyIncident: Codable {
            let id: UUID
            let scope: CollectionScope
            let contentType: ContentType
            let reason: CoverageGapReason
            let firstObservedAt: Date
            let resolvedAt: Date?
            let delivery: AlertDeliveryState
        }
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        try await store.close()
        let now = Date(), id = UUID(), scope = scope()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let keyBytes = Data("collection-health-scope-v1".utf8)
            + (try encoder.encode(LegacyKey(scope: scope, contentType: .toolOutput, reason: .malformedSource)))
        let digest = Array(try await crypto.revision(canonicalBytes: keyBytes).keyedDigest.prefix(16))
        let keyID = UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
        let legacy = LegacyIncident(id: id, scope: scope, contentType: .toolOutput, reason: .malformedSource,
            firstObservedAt: now, resolvedAt: nil, delivery: .delivered)
        let sealed = try await crypto.sealBackground(encoder.encode(legacy),
            binding: PayloadBinding(reference: .init(id: id), ownerID: id, kind: .sourceCheckpoint))
        let database = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path)
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO collection_health_incidents (id, key_id, created_at, delivery, requires_assessment, encoded)
                VALUES (?, ?, ?, ?, 1, ?)
                """, arguments: [id.uuidString, keyID.uuidString, now.timeIntervalSince1970,
                    AlertDeliveryState.delivered.rawValue, try sealed.encoded()])
        }
        try database.close()
        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        try await reopened.recordCoverageGap(.init(reason: .malformedSource, scope: scope,
            contentType: .toolOutput, isRequiredFormatFailure: true), at: now)
        let incidents = try await reopened.healthIncidents()
        #expect(incidents.count == 1)
        #expect(incidents.first?.id == id)
        #expect(incidents.first?.contentType == .toolOutput)
        #expect(incidents.first?.operation == nil)
        #expect(incidents.first?.delivery == .delivered)
        #expect(try await reopened.pendingNotifications().isEmpty)
        try await reopened.close()
    }
}
