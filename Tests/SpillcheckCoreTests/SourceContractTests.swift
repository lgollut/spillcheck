import Foundation
import Testing
@testable import SpillcheckCore

struct ExtractionFixture: Decodable {
    let name: String
    let text: String
    let value: String
    let expectedOccurrences: Int
}

@Suite("Normalized source and exact extraction")
struct SourceContractTests {
    @Test func annotatedUnicodeWhitespaceAndMultilineFixtures() throws {
        let url = try #require(Bundle.module.url(forResource: "extraction", withExtension: "json", subdirectory: "Fixtures"))
        let fixtures = try JSONDecoder().decode([ExtractionFixture].self, from: Data(contentsOf: url))
        for fixture in fixtures {
            let source = try sourceRecord(text: fixture.text)
            let bytes = Data(fixture.text.utf8)
            let value = Data(fixture.value.utf8)
            var cursor = 0
            var count = 0
            while cursor < bytes.count, let range = bytes.range(of: value, in: cursor..<bytes.count) {
                let location = try CanonicalLocation(segmentID: "text", range: UTF8Range(range.lowerBound, range.upperBound))
                let extraction = try ExactExtraction(valueUTF8: value, location: location, in: source)
                #expect(extraction.valueUTF8 == value, Comment(rawValue: fixture.name))
                cursor = range.upperBound
                count += 1
            }
            #expect(count == fixture.expectedOccurrences, Comment(rawValue: fixture.name))
        }
    }

    @Test func componentRangesPreserveOneExactValue() throws {
        let source = try sourceRecord(text: "abc-XYZ")
        let location = try CanonicalLocation(components: [
            ComponentRange(segmentID: "text", range: UTF8Range(0, 3)),
            ComponentRange(segmentID: "text", range: UTF8Range(4, 7)),
        ])
        let extraction = try ExactExtraction(valueUTF8: Data("abcXYZ".utf8), location: location, in: source)
        #expect(extraction.location.components.count == 2)
        #expect(extraction.valueUTF8 == Data("abcXYZ".utf8))
    }

    @Test func extractionRejectsGuessedTrimmedOrSplitUnicodeValues() throws {
        let source = try sourceRecord(text: " Päss ")
        let location = try CanonicalLocation(segmentID: "text", range: UTF8Range(0, source.segments[0].utf8.count))
        #expect(throws: ContractError.valueDoesNotMatchSource) {
            try ExactExtraction(valueUTF8: Data("Päss".utf8), location: location, in: source)
        }
        let split = try CanonicalLocation(segmentID: "text", range: UTF8Range(3, 4))
        #expect(throws: ContractError.invalidUTF8) { try split.extract(from: source) }
        let outOfBounds = try CanonicalLocation(segmentID: "text", range: UTF8Range(0, 100))
        #expect(throws: ContractError.invalidRange) { try outOfBounds.extract(from: source) }
    }

    @Test func invalidOrOverlappingRangesAndInvalidDecodedRangesFailClosed() throws {
        #expect(throws: ContractError.invalidRange) { try UTF8Range(-1, 1) }
        #expect(throws: ContractError.invalidRange) { try UTF8Range(2, 2) }
        #expect(throws: ContractError.invalidRange) {
            try CanonicalLocation(components: [
                ComponentRange(segmentID: "text", range: UTF8Range(0, 4)),
                ComponentRange(segmentID: "text", range: UTF8Range(3, 6)),
            ])
        }
        #expect(throws: ContractError.invalidRange) {
            try JSONDecoder().decode(UTF8Range.self, from: Data("{\"lowerBound\":-1,\"upperBound\":1}".utf8))
        }
        #expect(throws: ContractError.invalidFingerprint) { try fingerprintFromShortDigest() }
    }

    private func fingerprintFromShortDigest() throws -> ValueFingerprint {
        try ValueFingerprint(keyedDigest: Data(repeating: 1, count: 8))
    }

    @Test func sourceIdentityExcludesPresentationAndProvenance() throws {
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixtureTime)
        let hook = try sourceRecord()
        let history = try sourceRecord(interface: .t3, provenance: .historical(audit))
        #expect(hook.metadata.identity == history.metadata.identity)
        #expect(hook.metadata.origin != history.metadata.origin)
        let distinctProfile = try sourceRecord(profile: "another-installation")
        #expect(hook.metadata.identity != distinctProfile.metadata.identity)
    }

    @Test func preparedFindingsCannotBeAttachedToAnotherItemOrRevision() throws {
        let first = try sourceRecord()
        let finding = try detection(in: first)
        let otherItem = try sourceRecord(item: "item-2")
        #expect(throws: ContractError.conflictingSourceMetadata) {
            try SourceAnalysis(source: otherItem, detectorVersion: "1", detections: [finding])
        }
        let richer = try sourceRecord(revision: 2)
        #expect(throws: ContractError.conflictingSourceMetadata) {
            try SourceAnalysis(source: richer, detectorVersion: "1", detections: [finding])
        }
    }

    @Test func historicalWindowUsesContentTimeAndHasSevenDayBoundary() throws {
        let audit = try HistoricalAuditContext(reason: .firstLaunch, endingAt: fixtureTime)
        #expect(audit.end.timeIntervalSince(audit.start) == 604_800)
        #expect(audit.includes(contentTime: audit.start))
        #expect(audit.includes(contentTime: fixtureTime))
        #expect(!audit.includes(contentTime: audit.start.addingTimeInterval(-1)))
        #expect(!audit.includes(contentTime: fixtureTime.addingTimeInterval(1)))
        var ledger = InventoryLedger()
        let old = try analysis(provenance: .historical(audit), contentTime: audit.start.addingTimeInterval(-1))
        #expect(try ledger.ingest(old).outcome == .outsideHistoricalWindow)
        #expect(ledger.records.isEmpty)
        let recentInOldConversation = try analysis(session: "old-conversation", provenance: .historical(audit))
        #expect(try ledger.ingest(recentInOldConversation).insertedOccurrenceIDs.count == 1)
    }

    @Test func everyRequiredContentKindUsesSameDomainContract() throws {
        var ledger = InventoryLedger()
        for kind in ContentType.allCases {
            let source = try sourceRecord(item: kind.rawValue, contentType: kind)
            let prepared = try SourceAnalysis(source: source, detectorVersion: "1", detections: [detection(in: source)])
            #expect(try ledger.ingest(prepared).insertedOccurrenceIDs.count == 1)
        }
        #expect(ledger.occurrences.count == 5)
        #expect(ledger.records.count == 1)
        #expect(ledger.alertDecisions.count == 1)
    }
}
