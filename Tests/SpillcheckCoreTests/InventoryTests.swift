import Foundation
import Testing
@testable import SpillcheckCore

@Suite("Inventory, occurrence, replay and alert semantics")
struct InventoryTests {
    @Test func alertMatrixGroupsExactValuesAndCanonicalSessions() throws {
        var ledger = InventoryLedger()
        let first = try ledger.ingest(analysis())
        #expect(first.alerts.count == 1)
        #expect(first.createdValueIDs.count == 1)
        let replay = try ledger.ingest(analysis(interface: .t3))
        #expect(replay.outcome == .replay)
        #expect(replay.insertedOccurrenceIDs.isEmpty)
        #expect(replay.alerts.isEmpty)
        let repeated = try ledger.ingest(analysis(item: "item-2"))
        #expect(repeated.insertedOccurrenceIDs.count == 1)
        #expect(repeated.alerts.isEmpty)
        let newSession = try ledger.ingest(analysis(session: "session-2"))
        #expect(newSession.alerts.count == 1)
        #expect(newSession.createdValueIDs.isEmpty)
        let otherProvider = try ledger.ingest(analysis(provider: .claudeCode))
        #expect(otherProvider.alerts.count == 1)
        #expect(ledger.records.count == 1)
        #expect(ledger.occurrences.count == 4)
        #expect(ledger.alertDecisions.count == 3)
    }

    @Test func ambiguousThenStrongGetsFirstEligibleAlert() throws {
        var ledger = InventoryLedger()
        let ambiguous = try ledger.ingest(analysis(signal: .ambiguous))
        #expect(ambiguous.alerts.isEmpty)
        let initial = try #require(ledger.summary(for: fingerprint()))
        #expect(initial.detectorSignal == .ambiguous)
        #expect(initial.reviewCounts.needsReview == 1)
        let strong = try ledger.ingest(analysis(item: "item-2"))
        #expect(strong.alerts.count == 1)
        #expect(try ledger.ingest(analysis(item: "item-3")).alerts.isEmpty)
        let summary = try #require(ledger.summary(for: fingerprint()))
        #expect(summary.detectorSignal == .strong)
        #expect(summary.reviewCounts.needsReview == 1)
    }

    @Test func rangesStaySeparateAndMultipleRulesMergeAtOneLocation() throws {
        let source = try sourceRecord(text: "abc abc")
        let first = try detection(in: source, range: UTF8Range(0, 3), rule: "rule-1")
        let additionalRule = try detection(in: source, range: UTF8Range(0, 3), rule: "rule-2")
        let second = try detection(in: source, range: UTF8Range(4, 7))
        var ledger = InventoryLedger()
        let transition = try ledger.ingest(SourceAnalysis(
            source: source, detectorVersion: "1", detections: [first, additionalRule, second]
        ))
        #expect(transition.insertedOccurrenceIDs.count == 2)
        #expect(transition.addedEvidenceCount == 3)
        #expect(transition.alerts.count == 1)
        #expect(ledger.occurrences.values.map { $0.evidence.count }.sorted() == [1, 2])
        #expect(ledger.records.count == 1)
    }

    @Test func hookHistoryReconcileInBothOrdersWithoutFuzzyTextDeduplication() throws {
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixtureTime)
        let live = try analysis()
        let history = try analysis(interface: .t3, provenance: .historical(audit))
        for ordered in [[live, history], [history, live]] {
            var ledger = InventoryLedger()
            let first = try ledger.ingest(ordered[0])
            let second = try ledger.ingest(ordered[1])
            #expect(first.insertedOccurrenceIDs.count == 1)
            #expect(second.insertedOccurrenceIDs.isEmpty)
            #expect(second.alerts.isEmpty)
            #expect(ledger.occurrences.count == 1)
            #expect(try ledger.ingest(analysis(item: "another-identical-output")).insertedOccurrenceIDs.count == 1)
            #expect(ledger.occurrences.count == 2)
        }
    }

    @Test func richerContentAndRuleReevaluationKeepReviewAndAddNewEvidence() throws {
        var ledger = InventoryLedger()
        let first = try ledger.ingest(analysis(signal: .ambiguous))
        let id = try #require(first.insertedOccurrenceIDs.first)
        try ledger.review(id, as: .confirmedSecret)
        let improved = try ledger.ingest(analysis(revision: 2, detectorVersion: "2", rule: "strong-rule"))
        #expect(improved.insertedOccurrenceIDs.isEmpty)
        #expect(improved.addedEvidenceCount == 1)
        #expect(improved.alerts.count == 1)
        #expect(ledger.occurrences[id]?.review == .confirmedSecret)
        #expect(ledger.occurrences[id]?.evidence.count == 2)
        #expect(ledger.occurrences[id]?.detectorSignal == .strong)
    }

    @Test func reviewIsReversibleOccurrenceScopedAndDoesNotAlterDetectorConfidence() throws {
        var ledger = InventoryLedger()
        let first = try ledger.ingest(analysis(signal: .ambiguous))
        let second = try ledger.ingest(analysis(item: "item-2", signal: .ambiguous))
        let firstID = try #require(first.insertedOccurrenceIDs.first)
        let secondID = try #require(second.insertedOccurrenceIDs.first)
        try ledger.review(firstID, as: .confirmedSecret)
        var summary = try #require(ledger.summary(for: fingerprint()))
        #expect(summary.detectorSignal == .ambiguous)
        #expect(summary.reviewCounts.confirmed == 1)
        #expect(summary.reviewCounts.needsReview == 1)
        try ledger.review(secondID, as: .falsePositive)
        summary = try #require(ledger.summary(for: fingerprint()))
        #expect(summary.reviewCounts.falsePositive == 1)
        #expect(summary.reviewCounts.needsReview == 0)
        #expect(ledger.occurrences[secondID]?.detectorSignal == .ambiguous)
        try ledger.review(firstID, as: .falsePositive)
        #expect(try ledger.summary(for: fingerprint())?.detectorSignal == nil)
        try ledger.review(firstID, as: .unreviewed)
        #expect(try ledger.summary(for: fingerprint())?.reviewCounts.needsReview == 1)
        #expect(ledger.occurrences[secondID]?.review == .falsePositive)
        #expect(ledger.alertDecisions.isEmpty)
        #expect(try ledger.ingest(analysis()).alerts.isEmpty)
        #expect(try ledger.ingest(analysis(item: "new-strong")).alerts.count == 1)
    }

    @Test func falsePositiveEvidenceIsExcludedFromEffectiveSignal() throws {
        var ledger = InventoryLedger()
        let strong = try ledger.ingest(analysis())
        _ = try ledger.ingest(analysis(item: "ambiguous", signal: .ambiguous))
        let strongID = try #require(strong.insertedOccurrenceIDs.first)
        try ledger.review(strongID, as: .falsePositive)
        #expect(try ledger.summary(for: fingerprint())?.detectorSignal == .ambiguous)
        try ledger.review(strongID, as: .unreviewed)
        #expect(try ledger.summary(for: fingerprint())?.detectorSignal == .strong)
        // The withdrawn alert never reached the user; undoing review issues none, the next occurrence does.
        #expect(ledger.alertDecisions.isEmpty)
        #expect(try ledger.ingest(analysis(item: "another-strong")).alerts.count == 1)
    }

    @Test func contentRemovalPreservesReceiptsButNewSourceRemainsDetectable() throws {
        var ledger = InventoryLedger()
        let input = try analysis()
        let first = try ledger.ingest(input)
        let removal = try ledger.removeContent(for: fingerprint())
        #expect(removal.payloadReferences.count == 2)
        #expect(removal.occurrenceIDs == first.insertedOccurrenceIDs)
        #expect(removal.notificationIdentifiers == Set(first.alerts.map(\.notificationIdentifier)))
        #expect(removal.retainedObsoleteMarker == nil)
        #expect(ledger.records.isEmpty)
        #expect(ledger.occurrences.isEmpty)
        #expect(ledger.alertDecisions.isEmpty)
        #expect(ledger.processedLocations.count == 1)
        let replay = try ledger.ingest(input)
        #expect(replay.outcome == .replay)
        #expect(ledger.records.isEmpty)
        let later = try ledger.ingest(analysis(item: "genuinely-new"))
        #expect(later.insertedOccurrenceIDs.count == 1)
        #expect(later.alerts.count == 1)
        #expect(ledger.obsoleteMarkers.isEmpty)
    }

    @Test func richerSameSourceAfterDeletionSuppressesOldRangeAndAcceptsAppendedRange() throws {
        let original = try sourceRecord(text: "abc")
        let oldAnalysis = try SourceAnalysis(source: original, detectorVersion: "1", detections: [detection(in: original)])
        var ledger = InventoryLedger()
        _ = try ledger.ingest(oldAnalysis)
        _ = try ledger.removeContent(for: fingerprint())
        let richer = try sourceRecord(text: "abc abc", revision: 2)
        let newAnalysis = try SourceAnalysis(source: richer, detectorVersion: "1", detections: [
            detection(in: richer, range: UTF8Range(0, 3)),
            detection(in: richer, range: UTF8Range(4, 7)),
        ])
        let transition = try ledger.ingest(newAnalysis)
        #expect(transition.insertedOccurrenceIDs.count == 1)
        #expect(transition.alerts.count == 1)
        #expect(ledger.processedLocations.count == 2)
        #expect(ledger.occurrences.values.first?.identity.location.components.first?.range.lowerBound == 4)
        #expect(try ledger.ingest(newAnalysis).outcome == .replay)
    }

    @Test func obsoleteAcknowledgementRetainsContextUntilExplicitRemoval() throws {
        var ledger = InventoryLedger()
        let first = try ledger.ingest(analysis(signal: .ambiguous))
        let id = try #require(first.insertedOccurrenceIDs.first)
        try ledger.review(id, as: .confirmedSecret)
        try ledger.acknowledgeObsolete(fingerprint(), as: .rotated, at: fixtureTime)
        let reappearance = try ledger.ingest(analysis(item: "new-obsolete"))
        #expect(reappearance.alerts.isEmpty)
        #expect(reappearance.insertedOccurrenceIDs.count == 1)
        #expect(reappearance.insertedObsoleteAppearanceIDs.isEmpty)
        let summary = try #require(ledger.summary(for: fingerprint()))
        #expect(summary.canRevealRetainedValue)
        #expect(summary.obsoleteMarker?.acknowledgement == .rotated)
        #expect(summary.reviewCounts.confirmed == 1)
        #expect(summary.detectorSignal == .strong)
        #expect(summary.obsoleteAppearanceCount == 1)
        #expect(summary.occurrenceCount == 2)
        try ledger.forgetObsoleteMarker(fingerprint())
        #expect(try ledger.summary(for: fingerprint())?.obsoleteAppearanceCount == 1)
    }

    @Test func obsoleteRemovalReplayNewAppearanceReplacementAndForgetting() throws {
        var ledger = InventoryLedger()
        let original = try analysis()
        _ = try ledger.ingest(original)
        try ledger.acknowledgeObsolete(fingerprint(), as: .revoked, at: fixtureTime)
        let deletion = try ledger.removeContent(for: fingerprint())
        #expect(deletion.retainedObsoleteMarker?.acknowledgement == .revoked)
        #expect(try ledger.ingest(original).outcome == .replay)
        #expect(ledger.records.isEmpty)
        let obsolete = try ledger.ingest(analysis(item: "obsolete-new"))
        #expect(obsolete.alerts.isEmpty)
        #expect(obsolete.insertedOccurrenceIDs.isEmpty)
        #expect(obsolete.insertedObsoleteAppearanceIDs.count == 1)
        #expect(obsolete.discardedPayloadReferences.count == 2)
        let summary = try #require(ledger.summary(for: fingerprint()))
        #expect(!summary.canRevealRetainedValue)
        #expect(summary.record.categories.isEmpty)
        #expect(summary.reviewCounts.total == 0)
        #expect(summary.obsoleteAppearanceCount == 1)
        #expect(ledger.occurrences.isEmpty)
        let replacement = try ledger.ingest(analysis(item: "replacement", fingerprintByte: 2))
        #expect(replacement.alerts.count == 1)
        try ledger.forgetObsoleteMarker(fingerprint())
        #expect(ledger.obsoleteMarkers.isEmpty)
        #expect(try ledger.ingest(original).outcome == .replay)
        #expect(try ledger.ingest(analysis(item: "obsolete-new")).outcome == .replay)
        let later = try ledger.ingest(analysis(item: "after-forget"))
        #expect(later.alerts.count == 1)
        #expect(later.insertedOccurrenceIDs.count == 1)
        #expect(try ledger.summary(for: fingerprint())?.canRevealRetainedValue == true)
        #expect(ledger.obsoleteAppearances.values.first?.label == "Obsolete value")
    }

    @Test func retainedObsoleteReanalysisAfterForgetStaysSilentButNewItemAlerts() throws {
        var ledger = InventoryLedger()
        _ = try ledger.ingest(analysis())
        try ledger.acknowledgeObsolete(fingerprint(), as: .rotated, at: fixtureTime)
        let obsolete = try ledger.ingest(analysis(session: "session-B", item: "obsolete-item"))
        let obsoleteID = try #require(obsolete.insertedOccurrenceIDs.first)
        #expect(ledger.occurrences[obsoleteID]?.classification == .obsolete)
        try ledger.forgetObsoleteMarker(fingerprint())
        let reevaluated = try ledger.ingest(analysis(
            session: "session-B", item: "obsolete-item", detectorVersion: "2", ruleVersion: "2"
        ))
        #expect(reevaluated.alerts.isEmpty)
        #expect(reevaluated.insertedOccurrenceIDs.isEmpty)
        #expect(ledger.occurrences[obsoleteID]?.classification == .obsolete)
        #expect(try ledger.ingest(analysis(session: "session-B", item: "genuinely-new-item")).alerts.count == 1)
    }

    @Test func historicalAuditGivesOneMaskedSummaryAndNoIndividualAlerts() throws {
        let audit = try HistoricalAuditContext(reason: .resume, endingAt: fixtureTime)
        var ledger = InventoryLedger()
        var summary = HistoricalAuditSummary(audit: audit)
        let first = try ledger.ingest(analysis(provenance: .historical(audit)))
        let second = try ledger.ingest(analysis(item: "item-2", fingerprintByte: 2, signal: .ambiguous, provenance: .historical(audit)))
        #expect(first.alerts.isEmpty)
        #expect(second.alerts.isEmpty)
        try summary.include(#require(first.historicalContribution))
        try summary.include(#require(second.historicalContribution))
        try summary.include(#require(first.historicalContribution))
        #expect(summary.ordinaryOccurrenceCount == 2)
        #expect(summary.ordinaryValueCount == 2)
        #expect(summary.shouldNotify)
        #expect(summary.notificationIdentifier.hasPrefix("leakret-audit-"))
        #expect(try ledger.ingest(analysis(item: "new-live-same-session")).alerts.isEmpty)
        #expect(try ledger.ingest(analysis(session: "new-session")).alerts.count == 1)
        #expect(ledger.occurrences.values.contains { $0.source.origin.provenance == .historical(audit) })
    }

    @Test func obsoleteOnlyAuditIsVisibleAndSilentWithNoFreshPayloads() throws {
        var ledger = InventoryLedger()
        _ = try ledger.ingest(analysis())
        try ledger.acknowledgeObsolete(fingerprint(), as: .rotated, at: fixtureTime)
        _ = try ledger.removeContent(for: fingerprint())
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixtureTime)
        let observed = try ledger.ingest(analysis(item: "historical-obsolete", provenance: .historical(audit)))
        var summary = HistoricalAuditSummary(audit: audit)
        try summary.include(#require(observed.historicalContribution))
        #expect(summary.ordinaryOccurrenceCount == 0)
        #expect(summary.obsoleteOccurrenceCount == 1)
        #expect(!summary.shouldNotify)
        #expect(observed.alerts.isEmpty)
        #expect(observed.discardedPayloadReferences.count == 2)
        #expect(ledger.records.values.allSatisfy { $0.protectedValue == nil })
    }

    @Test func firstStrongHistoricalReevaluationContributesToSummary() throws {
        var ledger = InventoryLedger()
        let initial = try ledger.ingest(analysis(signal: .ambiguous))
        let id = try #require(initial.insertedOccurrenceIDs.first)
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixtureTime)
        let improved = try ledger.ingest(analysis(
            revision: 2, provenance: .historical(audit), detectorVersion: "2", rule: "strong-rule"
        ))
        #expect(improved.insertedOccurrenceIDs.isEmpty)
        #expect(improved.alerts.isEmpty)
        var summary = HistoricalAuditSummary(audit: audit)
        try summary.include(#require(improved.historicalContribution))
        #expect(summary.ordinaryOccurrenceIDs == [id])
        #expect(summary.shouldNotify)
        #expect(try ledger.ingest(analysis(item: "later-live")).alerts.isEmpty)
    }

    @Test func conflictingValueAtSameCanonicalLocationRejectsEntireBatch() throws {
        var ledger = InventoryLedger()
        _ = try ledger.ingest(analysis())
        let source = try sourceRecord(text: "SYNTHETIC_VALUE_A appended", revision: 2)
        let initialEnd = Data("SYNTHETIC_VALUE_A".utf8).count
        let new = try detection(in: source, range: UTF8Range(initialEnd + 1, source.segments[0].utf8.count), fingerprintByte: 3)
        let conflict = try detection(in: source, range: UTF8Range(0, initialEnd), fingerprintByte: 2)
        let candidate = try SourceAnalysis(source: source, detectorVersion: "1", detections: [new, conflict])
        #expect(throws: ContractError.conflictingValueAtLocation) { try ledger.ingest(candidate) }
        #expect(ledger.records.count == 1)
        #expect(ledger.occurrences.count == 1)
        #expect(ledger.alertDecisions.count == 1)
        #expect(ledger.analyzedRevisionCount == 1)
    }

    @Test func unlocatedFindingsNeverInventRevealableValues() throws {
        let source = try sourceRecord()
        let unlocated = try UnlocatedDetection(evidence: [evidence()], reason: .scannerReportMismatch)
        let result = try SourceAnalysis(source: source, detectorVersion: "1", detections: [], unlocated: [unlocated])
        var ledger = InventoryLedger()
        #expect(try ledger.ingest(result).insertedUnlocatedIDs.count == 1)
        #expect(ledger.records.isEmpty)
        #expect(ledger.occurrences.isEmpty)
        #expect(ledger.alertDecisions.isEmpty)
        #expect(try ledger.ingest(result).outcome == .replay)
        #expect(ledger.unlocatedResults.count == 1)
    }

    @Test func notificationPermissionFailureDoesNotRemoveInventoryOrCreateRetryIdentifier() throws {
        var ledger = InventoryLedger()
        let transition = try ledger.ingest(analysis())
        let alert = try #require(transition.alerts.first)
        try ledger.recordAlertDelivery(alert.id, state: .permissionDenied)
        #expect(ledger.records.count == 1)
        #expect(ledger.alertDecisions[alert.id]?.notificationIdentifier == alert.notificationIdentifier)
        #expect(ledger.alertDecisions[alert.id]?.delivery == .permissionDenied)
        #expect(try ledger.ingest(analysis()).alerts.isEmpty)
        #expect(ledger.alertDecisions.count == 1)
    }

    @Test func serializedInventoryMetadataContainsNoExactFixtureValue() throws {
        var ledger = InventoryLedger()
        _ = try ledger.ingest(analysis())
        let record = try #require(ledger.records.values.first)
        let occurrence = try #require(ledger.occurrences.values.first)
        let encoder = JSONEncoder()
        let bytes = try encoder.encode(record) + encoder.encode(occurrence)
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(!text.contains("SYNTHETIC_VALUE_A"))
        #expect(record.maskedLabels == ["Token ••••"])
        #expect(record.protectedValue != nil)
    }

    @Test func versionedSnapshotPreservesDeletionMarkerReceiptsAndFutureEligibility() throws {
        var ledger = InventoryLedger()
        let original = try analysis()
        _ = try ledger.ingest(original)
        try ledger.acknowledgeObsolete(fingerprint(), as: .revoked, at: fixtureTime)
        _ = try ledger.removeContent(for: fingerprint())
        let snapshotBytes = try JSONEncoder().encode(ledger.snapshot)
        #expect(!String(decoding: snapshotBytes, as: UTF8.self).contains("SYNTHETIC_VALUE_A"))
        let snapshot = try JSONDecoder().decode(InventorySnapshot.self, from: snapshotBytes)
        var restarted = try InventoryLedger(snapshot: snapshot)
        #expect(restarted.records.isEmpty)
        #expect(restarted.obsoleteMarkers.count == 1)
        #expect(restarted.processedLocations.count == 1)
        #expect(try restarted.ingest(original).outcome == .replay)
        let obsolete = try restarted.ingest(analysis(item: "new-after-restart"))
        #expect(obsolete.insertedObsoleteAppearanceIDs.count == 1)
        #expect(obsolete.alerts.isEmpty)
        let again = try JSONDecoder().decode(InventorySnapshot.self, from: JSONEncoder().encode(restarted.snapshot))
        restarted = try InventoryLedger(snapshot: again)
        try restarted.forgetObsoleteMarker(fingerprint())
        #expect(try restarted.ingest(analysis(item: "new-after-restart")).outcome == .replay)
        #expect(try restarted.ingest(analysis(item: "later-normal")).alerts.count == 1)
        #expect(try InventoryLedger(snapshot: restarted.snapshot).records.count == 1)
    }

    @Test func snapshotRejectsUnsupportedVersionAndOrphanedReceipt() throws {
        #expect(throws: ContractError.unsupportedSnapshotVersion) {
            try InventoryLedger(snapshot: InventorySnapshot(schemaVersion: 2))
        }
        let source = try sourceRecord()
        let location = try CanonicalLocation(segmentID: "text", range: UTF8Range(0, 3))
        let identity = OccurrenceIdentity(source: source.metadata.identity, location: location)
        #expect(throws: ContractError.invalidSnapshot) {
            try InventoryLedger(snapshot: InventorySnapshot(locationReceipts: [identity: .occurrence(UUID())]))
        }
    }

    @Test func compactionDropsStaleUnreferencedSourcesAndKeepsInventoryValid() throws {
        var ledger = InventoryLedger()
        let old = fixtureTime.addingTimeInterval(-30 * 24 * 60 * 60)
        let kept = try ledger.ingest(analysis(item: "kept", contentTime: old))
        let emptySource = try sourceRecord(item: "empty", contentTime: old)
        _ = try ledger.ingest(SourceAnalysis(source: emptySource, detectorVersion: "1", detections: []))
        _ = try ledger.ingest(analysis(item: "deleted", fingerprintByte: 2, contentTime: old))
        _ = try ledger.removeContent(for: fingerprint(2))
        _ = try ledger.ingest(analysis(item: "recent", fingerprintByte: 3))
        #expect(ledger.analyzedRevisionCount == 4)
        #expect(ledger.needsProcessedSourceCompaction(before: fixtureTime.addingTimeInterval(-60)))

        let removed = ledger.pruneProcessedSources(before: fixtureTime.addingTimeInterval(-60), stampingUntimedAt: fixtureTime)
        #expect(removed > 0 && ledger.analyzedRevisionCount == 1)
        #expect(!ledger.needsProcessedSourceCompaction(before: fixtureTime.addingTimeInterval(-60)))
        let snapshot = ledger.snapshot
        let keptID = try #require(kept.insertedOccurrenceIDs.first)
        let keptSource = try #require(ledger.occurrences[keptID]).identity.source
        #expect(snapshot.sourceKinds[keptSource] != nil && snapshot.sourceKinds.count == 2)
        #expect(!snapshot.locationReceipts.values.contains(.removed))
        let restored = try InventoryLedger(snapshot: JSONDecoder().decode(InventorySnapshot.self, from: JSONEncoder().encode(snapshot)))
        #expect(restored.occurrences.count == 2 && restored.analyzedRevisionCount == 1)
    }

    @Test func sourcesRecordedBeforeContentTimesAreStampedThenPrunedLater() throws {
        var ledger = InventoryLedger()
        _ = try ledger.ingest(SourceAnalysis(source: try sourceRecord(item: "legacy"), detectorVersion: "1", detections: []))
        let encoded = try JSONEncoder().encode(ledger.snapshot)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "sourceTimes")
        ledger = try InventoryLedger(snapshot: JSONDecoder().decode(InventorySnapshot.self,
            from: JSONSerialization.data(withJSONObject: legacy)))
        let stampedAt = fixtureTime.addingTimeInterval(365 * 24 * 60 * 60)
        #expect(ledger.needsProcessedSourceCompaction(before: fixtureTime))
        #expect(ledger.pruneProcessedSources(before: fixtureTime, stampingUntimedAt: stampedAt) == 0)
        #expect(ledger.analyzedRevisionCount == 1 && ledger.snapshot.sourceTimes.count == 1)
        #expect(ledger.pruneProcessedSources(before: stampedAt.addingTimeInterval(1), stampingUntimedAt: stampedAt) > 0)
        #expect(ledger.analyzedRevisionCount == 0 && ledger.snapshot.sourceKinds.isEmpty)
    }
}
