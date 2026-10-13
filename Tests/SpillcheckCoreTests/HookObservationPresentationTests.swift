import Foundation
import Testing
@testable import SpillcheckCore

private let hookPresentationTime = Date(timeIntervalSince1970: 1_800_000_000.125)
private let hookPresentationDateLabel = "January 15, 2027 at 08:00"

private func observationSource(item: String, basis: SourceTimeBasis?, at date: Date = hookPresentationTime) throws -> SourceRecord {
    let original = try sourceRecord(item: item, contentTime: date)
    let metadata = original.metadata
    return try SourceRecord(metadata: SourceRecordMetadata(identity: metadata.identity,
        contentType: metadata.contentType, contentTime: date, observedAt: date,
        locator: metadata.locator, origin: metadata.origin, timeBasis: basis),
        revision: original.revision, segments: original.segments)
}

private func firstAppearance(_ ledger: InventoryLedger) throws -> InventoryOccurrencePresentation {
    let presentation = try InventoryPresentation(snapshot: ledger.snapshot)
    let entry = try #require(presentation.entries().first)
    return try #require(presentation.occurrences(for: entry.id).first)
}

private func snapshotRoundTrip(_ ledger: InventoryLedger) throws -> InventoryLedger {
    try InventoryLedger(snapshot: JSONDecoder().decode(InventorySnapshot.self, from: JSONEncoder().encode(ledger.snapshot)))
}

private func removingTimeBasis(_ value: Any) -> Any {
    if let dictionary = value as? [String: Any] {
        return dictionary.filter { $0.key != "timeBasis" }.mapValues(removingTimeBasis)
    }
    if let array = value as? [Any] { return array.map(removingTimeBasis) }
    return value
}

@Suite("Hook observation timestamps in inventory presentation")
struct HookObservationPresentationTests {
    @Test(arguments: [nil, .firstObservation] as [SourceTimeBasis?])
    func retainedOccurrencePreservesItsDateAndLabelsOnlyObservedTime(_ basis: SourceTimeBasis?) throws {
        var ledger = InventoryLedger()
        let source = try observationSource(item: "retained", basis: basis)
        _ = try ledger.ingest(SourceAnalysis(source: source, detectorVersion: "fixture", detections: [detection(in: source)]))
        let restored = try snapshotRoundTrip(ledger)
        let appearance = try firstAppearance(restored)
        #expect(appearance.observedAt == hookPresentationTime && appearance.timeBasis == basis)
        #expect(appearance.timestampLabel(formattedDate: hookPresentationDateLabel)
            == (basis == .firstObservation ? "Observed \(hookPresentationDateLabel)" : hookPresentationDateLabel))
        #expect(!appearance.metadataOnly && appearance.review == .unreviewed)
    }

    @Test(arguments: [nil, .firstObservation] as [SourceTimeBasis?])
    func unlocatedResultPreservesItsDateAndObservationLabel(_ basis: SourceTimeBasis?) throws {
        var ledger = InventoryLedger()
        let source = try observationSource(item: "unlocated", basis: basis)
        _ = try ledger.ingest(SourceAnalysis(source: source, detectorVersion: "fixture", detections: [],
            unlocated: [UnlocatedDetection(evidence: [evidence()], reason: .ambiguousRange)]))
        let appearance = try firstAppearance(snapshotRoundTrip(ledger))
        #expect(appearance.observedAt == hookPresentationTime && appearance.timeBasis == basis)
        #expect(appearance.timestampLabel(formattedDate: hookPresentationDateLabel)
            == (basis == .firstObservation ? "Observed \(hookPresentationDateLabel)" : hookPresentationDateLabel))
        #expect(appearance.locationFailure == .ambiguousRange && appearance.alert == .unlocated)
    }

    @Test(arguments: [nil, .firstObservation] as [SourceTimeBasis?])
    func metadataOnlyObsoleteAppearanceRetainsItsTimeBasisAfterContentRemoval(_ basis: SourceTimeBasis?) throws {
        var ledger = InventoryLedger()
        _ = try ledger.ingest(analysis(item: "obsolete-before-removal"))
        try ledger.acknowledgeObsolete(fingerprint(), as: .rotated, at: fixtureTime)
        _ = try ledger.removeContent(for: fingerprint())
        let source = try observationSource(item: "obsolete-after-removal", basis: basis)
        _ = try ledger.ingest(SourceAnalysis(source: source, detectorVersion: "fixture", detections: [detection(in: source)]))
        let restored = try snapshotRoundTrip(ledger)
        let stored = try #require(restored.obsoleteAppearances.values.first)
        #expect(stored.occurredAt == hookPresentationTime && stored.timeBasis == basis)
        let appearance = try firstAppearance(restored)
        #expect(appearance.observedAt == hookPresentationTime && appearance.timeBasis == basis)
        #expect(appearance.timestampLabel(formattedDate: hookPresentationDateLabel)
            == (basis == .firstObservation ? "Observed \(hookPresentationDateLabel)" : hookPresentationDateLabel))
        #expect(appearance.metadataOnly && appearance.protectedExcerpt == nil && appearance.protectedMetadata == nil)
    }

    @Test func legacySnapshotWithoutTimeBasisPreservesAllThreeAppearanceDates() throws {
        var ledger = InventoryLedger()
        _ = try ledger.ingest(analysis(item: "obsolete-before-removal"))
        try ledger.acknowledgeObsolete(fingerprint(), as: .revoked, at: fixtureTime)
        _ = try ledger.removeContent(for: fingerprint())
        let obsolete = try observationSource(item: "obsolete", basis: .firstObservation)
        _ = try ledger.ingest(SourceAnalysis(source: obsolete, detectorVersion: "fixture", detections: [detection(in: obsolete)]))
        let retainedTime = hookPresentationTime.addingTimeInterval(12.25)
        let retained = try observationSource(item: "retained", basis: .firstObservation, at: retainedTime)
        _ = try ledger.ingest(SourceAnalysis(source: retained, detectorVersion: "fixture",
            detections: [detection(in: retained, fingerprintByte: 2)]))
        let unlocatedTime = hookPresentationTime.addingTimeInterval(24.5)
        let unlocated = try observationSource(item: "unlocated", basis: .firstObservation, at: unlocatedTime)
        _ = try ledger.ingest(SourceAnalysis(source: unlocated, detectorVersion: "fixture", detections: [],
            unlocated: [UnlocatedDetection(evidence: [evidence()], reason: .unavailableRange)]))

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger.snapshot))
        let legacy = try JSONDecoder().decode(InventorySnapshot.self,
            from: JSONSerialization.data(withJSONObject: removingTimeBasis(encoded)))
        let restored = try InventoryLedger(snapshot: legacy)
        #expect(restored.obsoleteAppearances.values.first?.timeBasis == nil)
        let presentation = try InventoryPresentation(snapshot: restored.snapshot)
        let appearances = presentation.entries().flatMap { presentation.occurrences(for: $0.id) }
        #expect(appearances.count == 3 && appearances.allSatisfy { $0.timeBasis == nil })
        #expect(Set(appearances.map(\.observedAt)) == Set([hookPresentationTime, retainedTime, unlocatedTime]))
        #expect(appearances.allSatisfy { $0.timestampLabel(formattedDate: hookPresentationDateLabel) == hookPresentationDateLabel })
    }
}
