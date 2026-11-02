import Foundation
import Testing
@testable import SpillcheckCore

@Suite("Decisions about exact values")
struct ValueDecisionTests {
    @Test func dismissedValueStaysQuietInEveryLaterConversation() throws {
        var ledger = InventoryLedger()
        #expect(try ledger.ingest(analysis()).alerts.count == 1)
        try ledger.decide(fingerprint(), as: .testOrDevelopment, at: fixtureTime)
        // The alert that hadn't been delivered yet is withdrawn.
        #expect(ledger.alertDecisions.isEmpty)
        let later = try ledger.ingest(analysis(session: "session-2", item: "item-2"))
        #expect(later.alerts.isEmpty)
        #expect(later.insertedOccurrenceIDs.count == 1)
        let summary = try #require(ledger.summary(for: fingerprint()))
        #expect(summary.decision?.decision == .testOrDevelopment)
        #expect(summary.appearancesSinceDecision == 1)
        // The decision belongs to the value; appearances aren't reviewed one by one.
        #expect(ledger.occurrences.values.allSatisfy { $0.review == .unreviewed })
    }

    @Test func valueThatNeedsRotationStillAlertsInANewConversation() throws {
        var ledger = InventoryLedger()
        _ = try ledger.ingest(analysis())
        try ledger.decide(fingerprint(), as: .needsRotation, at: fixtureTime)
        #expect(ledger.alertDecisions.count == 1)
        #expect(try ledger.ingest(analysis(item: "item-2")).alerts.isEmpty)
        #expect(try ledger.ingest(analysis(session: "session-2")).alerts.count == 1)
        #expect(ledger.summary(for: try fingerprint())?.appearancesSinceDecision == 2)
    }

    @Test func clearingTheDecisionReturnsTheValueToReview() throws {
        var ledger = InventoryLedger()
        _ = try ledger.ingest(analysis(signal: .ambiguous))
        try ledger.decide(fingerprint(), as: .notSecret, at: fixtureTime)
        #expect(try ledger.ingest(analysis(session: "session-2")).alerts.isEmpty)
        try ledger.decide(fingerprint(), as: nil, at: fixtureTime)
        #expect(ledger.valueDecisions.isEmpty)
        #expect(ledger.valueLabels[try fingerprint()] != nil)
        #expect(try ledger.ingest(analysis(session: "session-3")).alerts.count == 1)
        #expect(throws: ContractError.unknownValue) { try ledger.decide(fingerprint(9), as: .notSecret, at: fixtureTime) }
    }

    @Test func rotationReplacesTheDecisionAndMustBeForgottenBeforeDecidingAgain() throws {
        var ledger = InventoryLedger()
        _ = try ledger.ingest(analysis())
        try ledger.decide(fingerprint(), as: .needsRotation, at: fixtureTime)
        try ledger.acknowledgeObsolete(fingerprint(), as: .rotated, at: fixtureTime)
        #expect(ledger.valueDecisions.isEmpty)
        #expect(throws: ContractError.invalidState) { try ledger.decide(fingerprint(), as: .notSecret, at: fixtureTime) }
        try ledger.forgetObsoleteMarker(fingerprint())
        try ledger.decide(fingerprint(), as: .notSecret, at: fixtureTime)
        #expect(ledger.valueDecisions[try fingerprint()]?.decision == .notSecret)
    }

    @Test func removalKeepsTheDecisionAndLaterAppearancesStayQuiet() throws {
        var ledger = InventoryLedger()
        _ = try ledger.ingest(analysis())
        _ = try ledger.ingest(analysis(item: "item-2"))
        try ledger.decide(fingerprint(), as: .acceptedRisk, at: fixtureTime)
        #expect(ledger.valueDecisions[try fingerprint()]?.appearancesAtDecision == 2)
        let removal = try ledger.removeContent(for: fingerprint())
        #expect(removal.retainedDecision?.decision == .acceptedRisk)
        #expect(removal.retainedDecision?.appearancesAtDecision == 0)
        #expect(ledger.records.isEmpty)
        let label = try #require(ledger.valueLabels[try fingerprint()])
        let remembered = try #require(InventoryPresentation(snapshot: ledger.snapshot).entries().first)
        #expect(remembered.id == .rememberedDecision(try fingerprint()))
        #expect(remembered.kind == .rememberedDecision)
        #expect(remembered.decision == .acceptedRisk)
        #expect(remembered.label == label)
        let later = try ledger.ingest(analysis(session: "session-2", item: "item-3"))
        #expect(later.alerts.isEmpty)
        #expect(later.insertedOccurrenceIDs.count == 1)
        let summary = try #require(ledger.summary(for: fingerprint()))
        #expect(summary.decision?.decision == .acceptedRisk)
        #expect(summary.appearancesSinceDecision == 1)
        #expect(ledger.valueLabels[try fingerprint()] == label)
        // Forgetting a decision whose content is gone removes the entry with its label.
        _ = try ledger.removeContent(for: fingerprint())
        try ledger.decide(fingerprint(), as: nil, at: fixtureTime)
        #expect(ledger.valueLabels.isEmpty)
        #expect(try InventoryPresentation(snapshot: ledger.snapshot).entries().isEmpty)
    }

    @Test func catchUpSummaryLeavesDismissedValuesOut() throws {
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixtureTime)
        var ledger = InventoryLedger()
        _ = try ledger.ingest(analysis(item: "old-1", provenance: .historical(audit)))
        _ = try ledger.ingest(analysis(item: "other", fingerprintByte: 2, provenance: .historical(audit)))
        #expect(try ledger.snapshot.historicalSummaries().first?.ordinaryValueCount == 2)
        try ledger.decide(fingerprint(), as: .notSecret, at: fixtureTime)
        let summary = try #require(ledger.snapshot.historicalSummaries().first)
        #expect(summary.ordinaryValueCount == 1)
        #expect(summary.ordinaryOccurrenceCount == 1)
        try ledger.decide(fingerprint(2), as: .needsRotation, at: fixtureTime)
        #expect(try ledger.snapshot.historicalSummaries().first?.ordinaryValueCount == 1)
        let quiet = try ledger.ingest(analysis(item: "old-2", provenance: .historical(audit)))
        #expect(quiet.historicalContribution?.ordinaryOccurrenceIDs.isEmpty == true)
    }

    @Test func olderVaultsDeriveDecisionsFromPerAppearanceReviews() throws {
        var ledger = InventoryLedger()
        // Confirmed once: needs rotation.
        let confirmed = try ledger.ingest(analysis(item: "a-1", fingerprintByte: 1))
        _ = try ledger.ingest(analysis(item: "a-2", fingerprintByte: 1))
        try ledger.review(#require(confirmed.insertedOccurrenceIDs.first), as: .confirmedSecret)
        // Every appearance a false positive: not a secret.
        let dismissed = try ledger.ingest(analysis(item: "b-1", fingerprintByte: 2))
        try ledger.review(#require(dismissed.insertedOccurrenceIDs.first), as: .falsePositive)
        // A false positive beside an unreviewed appearance: still undecided.
        let mixed = try ledger.ingest(analysis(item: "c-1", fingerprintByte: 3))
        _ = try ledger.ingest(analysis(item: "c-2", fingerprintByte: 3))
        try ledger.review(#require(mixed.insertedOccurrenceIDs.first), as: .falsePositive)
        // Acknowledged rotated: keeps its acknowledgement.
        let rotated = try ledger.ingest(analysis(item: "d-1", fingerprintByte: 4))
        try ledger.review(#require(rotated.insertedOccurrenceIDs.first), as: .confirmedSecret)
        try ledger.acknowledgeObsolete(fingerprint(4), as: .rotated, at: fixtureTime)

        let restored = try JSONDecoder().decode(InventorySnapshot.self, from: encodedWithoutDecisions(ledger.snapshot))
        #expect(restored.valueDecisions[try fingerprint(1)]?.decision == .needsRotation)
        #expect(restored.valueDecisions[try fingerprint(1)]?.appearancesAtDecision == 2)
        #expect(restored.valueDecisions[try fingerprint(2)]?.decision == .notSecret)
        #expect(restored.valueDecisions[try fingerprint(3)] == nil)
        #expect(restored.valueDecisions[try fingerprint(4)] == nil)
        #expect(restored.unlocatedDecisions.isEmpty)
        // Once written, stored decisions are read as they are, without deriving them again.
        var reopened = try InventoryLedger(snapshot: restored)
        try reopened.decide(fingerprint(1), as: nil, at: fixtureTime)
        let again = try JSONDecoder().decode(InventorySnapshot.self, from: JSONEncoder().encode(reopened.snapshot))
        #expect(again.valueDecisions[try fingerprint(1)] == nil)
        #expect(again.valueDecisions[try fingerprint(2)]?.decision == .notSecret)
    }

    /// The partitioned ledger stores the decisions in its core part. A core written by a build
    /// without decisions has neither key, so its reviews become decisions as a version-1 ledger's do.
    @Test func partitionedCoreWrittenBeforeDecisionsDerivesThemFromReviews() throws {
        var ledger = InventoryLedger()
        let confirmed = try ledger.ingest(analysis(item: "a-1", fingerprintByte: 1))
        try ledger.review(#require(confirmed.insertedOccurrenceIDs.first), as: .confirmedSecret)
        let dismissed = try ledger.ingest(analysis(item: "b-1", fingerprintByte: 2))
        try ledger.review(#require(dismissed.insertedOccurrenceIDs.first), as: .falsePositive)

        let older = try JSONDecoder().decode(LedgerCore.self, from: encodedWithoutDecisions(LedgerCore(ledger.snapshot)))
        #expect(older.valueDecisions[try fingerprint(1)]?.decision == .needsRotation)
        #expect(older.valueDecisions[try fingerprint(2)]?.decision == .notSecret)
        #expect(older.unlocatedDecisions.isEmpty)
        // A core that holds the keys is read as it is, without deriving decisions again.
        let current = try JSONDecoder().decode(LedgerCore.self, from: JSONEncoder().encode(LedgerCore(ledger.snapshot)))
        #expect(current.valueDecisions.isEmpty)
        #expect(current == LedgerCore(ledger.snapshot))
        // And it carries decisions back into the snapshot it assembles.
        try ledger.decide(fingerprint(2), as: .testOrDevelopment, at: fixtureTime)
        let decided = try JSONDecoder().decode(LedgerCore.self, from: JSONEncoder().encode(LedgerCore(ledger.snapshot)))
        let assembled = InventorySnapshot(core: decided, notifications: LedgerNotifications(ledger.snapshot),
            conversations: LedgerConversations(ledger.snapshot), sources: SourceLedgerMirror(salt: Data(count: 32)))
        #expect(assembled.valueDecisions == ledger.snapshot.valueDecisions)
    }

    @Test func inverseChangesUndoDecisionsAndAcknowledgements() throws {
        var ledger = InventoryLedger()
        let first = try fingerprint(1), second = try fingerprint(2)
        _ = try ledger.ingest(analysis(item: "a", fingerprintByte: 1))
        _ = try ledger.ingest(analysis(item: "b", fingerprintByte: 2))
        try ledger.decide(second, as: .needsRotation, at: fixtureTime)
        let before = ledger.snapshot
        let changes: [InventoryDecisionChange] = [.decide(first, .notSecret), .acknowledge(second, .rotated)]
        for change in changes { try ledger.apply(change, at: fixtureTime) }
        #expect(ledger.valueDecisions[first]?.decision == .notSecret)
        #expect(ledger.obsoleteMarkers[second] != nil && ledger.valueDecisions[second] == nil)

        let undo = InventoryDecisionChange.inverse(of: changes, in: before)
        #expect(undo == [.forgetMarker(second), .decide(second, .needsRotation), .decide(first, nil)])
        for change in undo { try ledger.apply(change, at: fixtureTime) }
        #expect(ledger.valueDecisions[first] == nil)
        #expect(ledger.obsoleteMarkers[second] == nil)
        #expect(ledger.valueDecisions[second]?.decision == .needsRotation)
    }

    @Test func unlocatedDecisionCoversThatResultOnly() throws {
        var ledger = InventoryLedger()
        let source = try sourceRecord(item: "unlocated")
        let transition = try ledger.ingest(SourceAnalysis(source: source, detectorVersion: "1", detections: [],
            unlocated: [UnlocatedDetection(evidence: [evidence()], reason: .ambiguousRange)]))
        let resultID = try #require(transition.insertedUnlocatedIDs.first)
        try ledger.decide(unlocated: resultID, as: .notSecret, at: fixtureTime)
        #expect(throws: ContractError.unknownOccurrence) { try ledger.decide(unlocated: UUID(), as: .notSecret, at: fixtureTime) }
        let restored = try InventoryLedger(snapshot: JSONDecoder().decode(
            InventorySnapshot.self, from: JSONEncoder().encode(ledger.snapshot)))
        #expect(restored.unlocatedDecisions[resultID]?.decision == .notSecret)
        let entry = try #require(InventoryPresentation(snapshot: restored.snapshot).entry(.unlocated(resultID)))
        #expect(entry.decision == .notSecret)
        #expect(entry.reviewLabel == "Not a secret")
        #expect(!entry.reviewStates.contains(.needsReview))
        var cleared = restored
        try cleared.decide(unlocated: resultID, as: nil, at: fixtureTime)
        #expect(cleared.unlocatedDecisions.isEmpty)
    }

    @Test func presentationNamesTheDecisionAndKeepsAnAlertAlreadySent() throws {
        var ledger = InventoryLedger()
        let alert = try #require(try ledger.ingest(analysis()).alerts.first)
        try ledger.recordAlertDelivery(alert.id, state: .delivered)
        _ = try ledger.ingest(analysis(item: "item-2", signal: .ambiguous))
        try ledger.decide(fingerprint(), as: .testOrDevelopment, at: fixtureTime)
        let presentation = try InventoryPresentation(snapshot: ledger.snapshot)
        let entry = try #require(presentation.entries().first)
        #expect(entry.decision == .testOrDevelopment)
        #expect(entry.decidedAt == fixtureTime)
        #expect(entry.reviewLabel == "Test or dev only")
        #expect(entry.appearancesSinceDecision == 0)
        let states = presentation.occurrences(for: entry.id).map(\.alert)
        #expect(states.contains(.alerted(.delivered)))
        #expect(states.contains(.dismissed))
        #expect(presentation.entries(matching: InventoryFilter(review: .needsReview)).isEmpty)
    }

    @Test func snapshotRejectsADecisionFiledUnderAnotherValue() throws {
        var ledger = InventoryLedger()
        _ = try ledger.ingest(analysis())
        try ledger.decide(fingerprint(), as: .notSecret, at: fixtureTime)
        let snapshot = ledger.snapshot
        let misfiled = try InventorySnapshot(
            records: snapshot.records, occurrences: snapshot.occurrences, alertDecisions: snapshot.alertDecisions,
            analysisReceipts: snapshot.analysisReceipts, locationReceipts: snapshot.locationReceipts,
            strongSignalReceipts: snapshot.strongSignalReceipts, sourceKinds: snapshot.sourceKinds,
            sourceTimes: snapshot.sourceTimes, valueLabels: snapshot.valueLabels, nextValueLabel: snapshot.nextValueLabel,
            valueDecisions: [fingerprint(2): #require(snapshot.valueDecisions[fingerprint()])]
        )
        #expect(throws: ContractError.invalidSnapshot) { try InventoryLedger(snapshot: misfiled) }
    }

    /// A vault written before decisions existed: the same snapshot without the decision keys.
    private func encodedWithoutDecisions<Value: Encodable>(_ value: Value) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object.removeValue(forKey: "valueDecisions")
        object.removeValue(forKey: "unlocatedDecisions")
        return try JSONSerialization.data(withJSONObject: object)
    }
}
