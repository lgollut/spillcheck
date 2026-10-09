import Foundation
import Testing
@testable import SpillcheckCore

@Suite("Masked inventory workflow")
struct InventoryPresentationTests {
    @Test func reviewsAndCompoundFiltersUseTheSameOccurrence() throws {
        var ledger = InventoryLedger()
        let first = try ledger.ingest(analysis(session: "z-private-id"))
        let second = try ledger.ingest(analysis(provider: .claudeCode, session: "a-private-id", item: "other", signal: .ambiguous))
        try ledger.review(try #require(first.insertedOccurrenceIDs.first), as: .confirmedSecret)
        var view = try InventoryPresentation(snapshot: ledger.snapshot)
        #expect(view.entries().first?.reviewLabel == "Needs review")
        #expect(view.entries(matching: .init(agent: .claudeCode, review: .confirmedSecret)).isEmpty)
        #expect(view.entries(matching: .init(agent: .codex, review: .confirmedSecret)).count == 1)
        #expect(view.entries(matching: .init(agent: .claudeCode, review: .needsReview)).count == 1)
        try ledger.review(try #require(second.insertedOccurrenceIDs.first), as: .falsePositive)
        view = try InventoryPresentation(snapshot: ledger.snapshot)
        #expect(view.entries().first?.reviewLabel == "Mixed reviews")
        #expect(view.entries(matching: .init(agent: .claudeCode, review: .falsePositive)).count == 1)
        #expect(view.entries(matching: .init(agent: .codex, review: .falsePositive)).isEmpty)
    }

    @Test func obsoleteContentRemovalKeepsAnActionableMarkerAndMetadataOnlyAppearance() throws {
        var ledger = InventoryLedger()
        _ = try ledger.ingest(analysis())
        try ledger.acknowledgeObsolete(fingerprint(), as: .revoked, at: fixtureTime)
        _ = try ledger.removeContent(for: fingerprint())
        var view = try InventoryPresentation(snapshot: ledger.snapshot)
        let marker = try #require(view.entries().first)
        #expect(marker.kind == .rememberedObsoleteMarker && marker.occurrenceCount == 0)
        #expect(marker.fingerprint == (try fingerprint()))
        #expect(!marker.canRevealRetainedValue)
        #expect(view.entries(matching: .init(agent: .codex)).isEmpty)
        _ = try ledger.ingest(analysis(provider: .claudeCode, session: "new", item: "obsolete"))
        view = try InventoryPresentation(snapshot: ledger.snapshot)
        let row = try #require(view.entries().first)
        let occurrence = try #require(view.occurrences(for: row.id).first)
        #expect(row.kind == .obsoleteValue && row.agentLabels == ["Claude Code"] && row.occurrenceCount == 1)
        #expect(occurrence.metadataOnly && occurrence.protectedExcerpt == nil && occurrence.protectedMetadata == nil)
        #expect(row.reviewLabel == "Acknowledged revoked")
        try ledger.forgetObsoleteMarker(fingerprint())
        view = try InventoryPresentation(snapshot: ledger.snapshot)
        #expect(view.entries().first?.reviewLabel == "Obsolete value")
        #expect(view.entries().first?.acknowledgement == nil)
    }

    @Test func unlocatedEvidenceHasNoInventedValueOrOccurrenceReview() throws {
        var ledger = InventoryLedger()
        let source = try sourceRecord(session: "private-session", protectedMetadata: ProtectedPayloadReference())
        _ = try ledger.ingest(SourceAnalysis(source: source, detectorVersion: "1", detections: [],
            unlocated: [UnlocatedDetection(evidence: [evidence()], reason: .ambiguousRange)]))
        let view = try InventoryPresentation(snapshot: ledger.snapshot)
        let entry = try #require(view.entries().first)
        let detail = try #require(view.occurrences(for: entry.id).first)
        #expect(entry.kind == .unlocatedDetection && entry.fingerprint == nil && !entry.canRevealRetainedValue)
        #expect(detail.locationFailure == .ambiguousRange && detail.review == nil && detail.evidence.count == 1)
        #expect(detail.conversation.label.text == "Conversation 1")
        #expect(view.entries(matching: .init(review: .needsReview)).count == 1)
    }

    @Test func encryptedSnapshotLabelsAreStableAndOlderSnapshotsDecode() throws {
        var ledger = InventoryLedger()
        _ = try ledger.ingest(analysis(session: "z-session"))
        let original = try #require(ledger.conversationLabels.values.first)
        let encoded = try JSONEncoder().encode(ledger.snapshot)
        var old = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "conversationLabels"); old.removeValue(forKey: "historicalNotificationDecisions")
        ledger = try InventoryLedger(snapshot: JSONDecoder().decode(InventorySnapshot.self,
            from: JSONSerialization.data(withJSONObject: old)))
        _ = try ledger.ingest(analysis(session: "a-session", item: "new"))
        let restored = try InventoryLedger(snapshot: JSONDecoder().decode(InventorySnapshot.self, from: JSONEncoder().encode(ledger.snapshot)))
        #expect(restored.conversationLabels[try SessionIdentity(provider: .codex, profileID: "fixture-profile", sessionID: "z-session")] == original)
        #expect(Set(restored.conversationLabels.values.map(\.index)) == [1, 2])
    }

    @Test func pendingLiveAlertsWithdrawPerSessionWithoutRemovingReplayReceipts() throws {
        var ledger = InventoryLedger()
        let first = try ledger.ingest(analysis(session: "first"))
        let second = try ledger.ingest(analysis(session: "second", item: "new"))
        let firstAlert = try #require(first.alerts.first), secondAlert = try #require(second.alerts.first)
        try ledger.review(try #require(first.insertedOccurrenceIDs.first), as: .falsePositive)
        #expect(ledger.alertDecisions[firstAlert.id] == nil)
        #expect(ledger.alertDecisions[secondAlert.id]?.delivery == .pending)
        // Undoing review restores evidence without a notification for the manual action.
        try ledger.review(try #require(first.insertedOccurrenceIDs.first), as: .confirmedSecret)
        #expect(ledger.alertDecisions[firstAlert.id] == nil && ledger.alertDecisions.count == 1)
        #expect(try ledger.ingest(analysis(session: "first")).outcome == .replay)
        try ledger.acknowledgeObsolete(fingerprint(), as: .rotated, at: fixtureTime)
        #expect(ledger.alertDecisions.isEmpty && ledger.snapshot.strongSignalReceipts.isEmpty)
        _ = try InventoryLedger(snapshot: JSONDecoder().decode(InventorySnapshot.self, from: JSONEncoder().encode(ledger.snapshot)))
    }

    @Test func alertWithdrawnBeforeDeliveryLetsNextStrongOccurrenceInConversationNotify() throws {
        var ledger = InventoryLedger()
        let first = try ledger.ingest(analysis(session: "first", item: "a"))
        #expect(first.alerts.count == 1)
        try ledger.review(try #require(first.insertedOccurrenceIDs.first), as: .falsePositive)
        #expect(ledger.alertDecisions.isEmpty)
        let repeated = try ledger.ingest(analysis(session: "first", item: "b"))
        #expect(repeated.alerts.count == 1 && ledger.alertDecisions[repeated.alerts[0].id]?.delivery == .pending)
        // After delivery, repeats in the same conversation stay grouped.
        try ledger.recordAlertDelivery(repeated.alerts[0].id, state: .delivered)
        #expect(try ledger.ingest(analysis(session: "first", item: "c")).alerts.isEmpty)
    }

    @Test func historicalReceiptsRefreshPendingCountsAndNeverReissueAfterCancellation() throws {
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixtureTime)
        var ledger = InventoryLedger()
        _ = try ledger.ingest(analysis(item: "first", provenance: .historical(audit)))
        _ = try ledger.ingest(analysis(item: "second", fingerprintByte: 2, provenance: .historical(audit)))
        try ledger.settleHistoricalNotifications(auditIDs: [audit.id])
        let first = try #require(ledger.historicalNotificationDecisions[audit.id])
        #expect(first.ordinaryValueCount == 2)
        _ = try ledger.ingest(analysis(item: "third", provenance: .historical(audit)))
        #expect(ledger.historicalNotificationDecisions[audit.id]?.ordinaryOccurrenceCount == 3)
        _ = try ledger.removeContent(for: fingerprint())
        let reduced = try #require(ledger.historicalNotificationDecisions[audit.id])
        #expect(reduced.notificationIdentifier == first.notificationIdentifier && reduced.ordinaryValueCount == 1)
        try ledger.acknowledgeObsolete(fingerprint(2), as: .revoked, at: fixtureTime)
        #expect(ledger.historicalNotificationDecisions[audit.id]?.delivery == .cancelled)
        try ledger.forgetObsoleteMarker(fingerprint(2))
        try ledger.settleHistoricalNotifications(auditIDs: [audit.id])
        #expect(ledger.historicalNotificationDecisions[audit.id]?.delivery == .cancelled)
        let restored = try InventoryLedger(snapshot: JSONDecoder().decode(InventorySnapshot.self, from: JSONEncoder().encode(ledger.snapshot)))
        #expect(restored.historicalNotificationDecisions[audit.id]?.delivery == .cancelled)
    }

    @Test func obsoleteOnlyAuditNeverCreatesNotificationWork() throws {
        var ledger = InventoryLedger()
        _ = try ledger.ingest(analysis())
        try ledger.acknowledgeObsolete(fingerprint(), as: .rotated, at: fixtureTime)
        _ = try ledger.removeContent(for: fingerprint())
        let audit = try HistoricalAuditContext(reason: .resume, endingAt: fixtureTime)
        _ = try ledger.ingest(analysis(item: "obsolete-historical", provenance: .historical(audit)))
        try ledger.settleHistoricalNotifications(auditIDs: [audit.id])
        #expect(ledger.historicalNotificationDecisions.isEmpty)
        #expect(try ledger.snapshot.historicalSummaries().first?.obsoleteOccurrenceCount == 1)
    }

    @Test func valueLabelsAreStableNeverReusedAndSurviveOnlyWithAMarker() throws {
        var ledger = InventoryLedger()
        _ = try ledger.ingest(analysis(item: "a", fingerprintByte: 1))
        _ = try ledger.ingest(analysis(item: "b", fingerprintByte: 2))
        #expect(ledger.valueLabels[try fingerprint(1)]?.text == "L-1")
        #expect(ledger.valueLabels[try fingerprint(2)]?.text == "L-2")
        // Removing an unacknowledged value forgets its label; the number is not reused.
        _ = try ledger.removeContent(for: fingerprint(2))
        #expect(ledger.valueLabels[try fingerprint(2)] == nil)
        _ = try ledger.ingest(analysis(item: "c", fingerprintByte: 3))
        #expect(ledger.valueLabels[try fingerprint(3)]?.index == 3)
        // An acknowledged value keeps its label through removal and a later obsolete appearance.
        try ledger.acknowledgeObsolete(fingerprint(1), as: .rotated, at: fixtureTime)
        _ = try ledger.removeContent(for: fingerprint(1))
        _ = try ledger.ingest(analysis(session: "later", item: "d", fingerprintByte: 1))
        let view = try InventoryPresentation(snapshot: ledger.snapshot)
        #expect(view.entries().first { $0.fingerprint == (try? fingerprint(1)) }?.label?.text == "L-1")
        try ledger.forgetObsoleteMarker(fingerprint(1))
        _ = try ledger.removeContent(for: fingerprint(1))
        #expect(ledger.valueLabels[try fingerprint(1)] == nil)
        let restored = try InventoryLedger(snapshot: JSONDecoder().decode(InventorySnapshot.self, from: JSONEncoder().encode(ledger.snapshot)))
        #expect(restored.valueLabels == ledger.valueLabels && restored.snapshot.nextValueLabel == 4)
    }

    @Test func olderSnapshotsReceiveValueLabelsInFirstSeenOrder() throws {
        var ledger = InventoryLedger()
        _ = try ledger.ingest(analysis(item: "late", fingerprintByte: 1, contentTime: fixtureTime.addingTimeInterval(60)))
        _ = try ledger.ingest(analysis(item: "early", fingerprintByte: 2))
        let source = try sourceRecord(item: "unlocated")
        _ = try ledger.ingest(SourceAnalysis(source: source, detectorVersion: "1", detections: [],
            unlocated: [UnlocatedDetection(evidence: [evidence()], reason: .ambiguousRange)]))
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger.snapshot)) as? [String: Any])
        for key in ["valueLabels", "unlocatedLabels", "nextValueLabel"] { old.removeValue(forKey: key) }
        let restored = try InventoryLedger(snapshot: JSONDecoder().decode(InventorySnapshot.self,
            from: JSONSerialization.data(withJSONObject: old)))
        #expect(restored.valueLabels[try fingerprint(2)]?.index == 1)
        #expect(restored.valueLabels[try fingerprint(1)]?.index == 2)
        #expect(restored.unlocatedLabels.values.map(\.index) == [3])
    }

    @Test func alertStatesMarkTheAppearanceThatCarriedEachConversationAlert() throws {
        var ledger = InventoryLedger()
        _ = try ledger.ingest(analysis(session: "first", item: "a"))
        _ = try ledger.ingest(analysis(session: "first", item: "b", contentTime: fixtureTime.addingTimeInterval(5)))
        _ = try ledger.ingest(analysis(session: "second", item: "c", signal: .ambiguous))
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixtureTime.addingTimeInterval(60))
        _ = try ledger.ingest(analysis(session: "third", item: "d", provenance: .historical(audit)))
        let view = try InventoryPresentation(snapshot: ledger.snapshot)
        let entry = try #require(view.entries().first)
        let states = Dictionary(uniqueKeysWithValues: view.occurrences(for: entry.id).map { ($0.source.itemID, $0.alert) })
        #expect(states["a"] == .alerted(.pending))
        #expect(states["b"] == .repeatInConversation)
        #expect(states["c"] == .awaitingReview)
        #expect(states["d"] == .catchUp)
    }

    @Test func valueKindsComeFromRuleIdentitiesWithCategoryFallback() throws {
        let github = ValueKind(evidence: [try evidence(rule: "github-pat")])
        #expect(github.shortName == "GitHub token" && github.service == "GitHub" && github.monogram == "GH")
        let preferred = ValueKind(evidence: [try evidence(signal: .ambiguous, rule: "generic-api-key", category: .apiKey),
                                             try evidence(rule: "stripe-access-token", category: .apiKey)])
        #expect(preferred.shortName == "Stripe key")
        let unknown = ValueKind(evidence: [try evidence(rule: "fixture.format", category: .password)])
        #expect(unknown.shortName == "Password" && unknown.service == nil)
        #expect(unknown.servicePhrase == "the system that accepts it")
        #expect(ValueKind(evidence: [try evidence(rule: "postgres-credential-uri", category: .connectionCredential)]).monogram == "DB")
    }

    @Test func analyzedActivityCountsOnlyContentInsideTheWindow() throws {
        var ledger = InventoryLedger()
        let day: TimeInterval = 86_400
        _ = try ledger.ingest(analysis(session: "a", item: "1"))
        _ = try ledger.ingest(analysis(session: "a", item: "2", fingerprintByte: 2))
        _ = try ledger.ingest(analysis(provider: .claudeCode, session: "b", item: "3", fingerprintByte: 3,
                                       contentTime: fixtureTime.addingTimeInterval(-2 * day)))
        _ = try ledger.ingest(analysis(session: "old", item: "4", fingerprintByte: 4,
                                       contentTime: fixtureTime.addingTimeInterval(-9 * day)))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let window = AnalyzedActivity.recentWindow(endingAt: fixtureTime, calendar: calendar)
        let activity = AnalyzedActivity(snapshot: ledger.snapshot, window: window, calendar: calendar)
        #expect(activity.messageCount == 3 && activity.conversationCount == 2)
        #expect(activity.analyzedDays(provider: .codex) == [calendar.startOfDay(for: fixtureTime)])
        #expect(activity.analyzedDays(provider: .claudeCode, profileID: "fixture-profile").count == 1)
        #expect(activity.conversationCount(provider: .codex) == 1)
        #expect(activity.analyzedDays(provider: .claudeCode, profileID: "other").isEmpty)
    }

    @Test func notificationTextUsesOnlyControlledLabels() throws {
        var ledger = InventoryLedger()
        let secret = "SYNTHETIC_PRIVATE_SESSION_AND_TITLE"
        let transition = try ledger.ingest(analysis(profile: secret, session: secret, item: secret))
        let alert = try #require(transition.alerts.first)
        let message = MaskedNotification.live(alert, conversation: MaskedConversationLabel(index: 7))
        #expect(message.title == "New token detected")
        #expect(message.body == "Conversation 7 · Codex\nValue hidden. Open Spillcheck to review.")
        #expect(!message.title.contains(secret) && !message.body.contains(secret) && !message.identifier.contains(secret))
        #expect(message.target == .value(alert.valueID))
    }
}
