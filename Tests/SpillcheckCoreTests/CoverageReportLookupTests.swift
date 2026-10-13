import Foundation
import Testing
@testable import SpillcheckCore

/// Deterministic, so a failing seed can be replayed.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

@Suite("Coverage report lookups match the nested scans they replace")
struct CoverageReportLookupTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let profile = "SYNTHETIC_LOOKUP_PROFILE"

    /// The ownership scan before indexing, kept verbatim as the reference.
    private func referenceIndependentEvents(_ report: CoverageReport) -> [StoredCoverageGapEvent] {
        report.gapEvents.items.filter { event in
            !report.omissions.items.contains { omission in
                if event.gap.requiresAnalysis && !omission.gap.requiresAnalysis { return false }
                if let reference = event.gap.recovery, let other = omission.gap.recovery {
                    return event.gap.scope == omission.gap.scope && event.gap.reason == omission.gap.reason
                        && event.gap.contentType == omission.gap.contentType && event.gap.operation == omission.gap.operation
                        && reference.identifiesSameLocation(as: other)
                }
                return event.gap.recovery == nil && omission.gap.recovery == nil && event.gap == omission.gap
                    && abs(event.observedAt.timeIntervalSince(omission.firstObservedAt)) < 0.001
            }
        }
    }

    /// The backlog settlement scan before indexing, kept verbatim as the reference.
    private func referenceRecoveredBacklog(_ event: StoredCoverageGapEvent, in report: CoverageReport) -> Bool {
        guard event.isIntermediateBacklog, event.gap.reason == .budgetExhausted,
              event.gap.recovery == nil, let audit = event.audit else { return false }
        if let workID = event.workID {
            guard !report.work.isTruncated, report.work.items.contains(where: { $0.id == workID }),
                  !report.work.items.contains(where: { $0.context.audit == audit && $0.state != .recovered && $0.state != .completed }) else { return false }
        }
        return report.history.items.contains {
            $0.progress.audit.id == audit.auditID && $0.provider == audit.provider && $0.profileID == audit.profileID
                && !$0.progress.hasUnreadContent && $0.continuationQueued == false
                && $0.completedAt.map { $0 >= event.observedAt } == true
        }
    }

    /// Small value pools make exact matches, near misses and duplicate identities common.
    private func fixture(size: Int, using random: inout SeededGenerator) throws -> CoverageReport {
        func pick<T>(_ values: [T]) -> T { values.randomElement(using: &random)! }
        let scopes = [
            CollectionScope(provider: .codex, profileID: profile, interface: .standaloneCLI, path: .publicHistory),
            CollectionScope(provider: .codex, profileID: profile, interface: .t3, path: .publicHistory),
            CollectionScope(provider: .claudeCode, profileID: profile, interface: .standaloneCLI, path: .versionedTranscript),
        ]
        let sessions: [SessionIdentity?] = [nil,
            try SessionIdentity(provider: .codex, profileID: profile, sessionID: "synthetic-session-a"),
            try SessionIdentity(provider: .codex, profileID: profile, sessionID: "synthetic-session-b")]
        let documents: [UUID?] = [nil, UUID(), UUID()]
        let urls: [URL?] = [nil, URL(fileURLWithPath: "/synthetic/a.jsonl"), URL(fileURLWithPath: "/synthetic/b.jsonl")]
        let locators: [SourceLocator] = [.upstreamItem, .unavailable,
            .transcript(documentID: documents[1]!, recordIndex: 1), .transcript(documentID: documents[1]!, recordIndex: 2)]
        let gaps = (0..<24).map { _ -> CoverageGap in
            let recovery = random.next() % 3 == 0 ? nil : CoverageRecoveryReference(session: pick(sessions),
                locator: pick(locators), itemID: pick([nil, "item-a", "item-b"]), contentTime: now,
                parserContract: "synthetic-v1", sourceDocumentID: pick(documents), sourceURL: pick(urls))
            return CoverageGap(reason: pick([.malformedSource, .unsupportedContent, .budgetExhausted]),
                scope: pick([nil] + scopes), contentType: pick([nil, .userPrompt, .toolOutput]),
                operation: pick([nil, .liveRead, .historicalRead]), recovery: recovery,
                excludedContent: pick([nil, nil, true]))
        }
        /// Changes fields that location matching may ignore, depending on the locator.
        func variant() -> CoverageGap {
            let gap = pick(gaps)
            guard random.next() % 2 == 0 else { return gap }
            let recovery = gap.recovery.map {
                CoverageRecoveryReference(session: pick(sessions), locator: $0.locator, itemID: $0.itemID,
                    contentTime: pick([nil, now]), parserContract: pick(["synthetic-v1", "synthetic-v2"]),
                    sourceDocumentID: $0.sourceDocumentID, sourceURL: pick(urls))
            }
            return CoverageGap(reason: gap.reason, scope: gap.scope, contentType: gap.contentType,
                operation: gap.operation, recovery: recovery, isRequiredFormatFailure: pick([nil, true]),
                excludedContent: pick([nil, true]))
        }
        let backlog = CoverageGap(reason: .budgetExhausted, scope: scopes[0], operation: .historicalRead)
        let audits = try (0..<4).map { _ in
            CoverageAuditIdentity(auditID: try HistoricalAuditContext(reason: .resume, endingAt: now).id,
                                  provider: .codex, profileID: profile)
        }
        // 1 ms is the boundary for matching an unlocated omission to its event.
        let times = [now, now.addingTimeInterval(0.0005), now.addingTimeInterval(0.002), now.addingTimeInterval(5)]
        let omissionIDs = (0..<size / 2).map { _ in UUID() }
        let workIDs = (0..<size / 2).map { _ in UUID() }

        let omissions = omissionIDs.map { id in
            CoverageOmission(id: id, gap: variant(), firstObservedAt: pick(times),
                             state: pick([.retryable, .blocked, .recovered, .unrecoverable]), resolvedAt: nil)
        }
        let events = (0..<size).map { _ -> StoredCoverageGapEvent in
            random.next() % 3 == 0
                ? StoredCoverageGapEvent(gap: backlog, observedAt: pick(times), audit: pick(audits),
                                         isIntermediateBacklog: true, workID: pick([nil, UUID(), pick(workIDs)]))
                : StoredCoverageGapEvent(gap: variant(), observedAt: pick(times), audit: pick([nil] + audits))
        }
        let work = (0..<size).map { _ in
            let audit = pick([nil] + audits)
            // The first audit's work is always settled, so linked backlog events can recover.
            let states: [CollectionWorkState] = audit == audits[0] ? [.completed, .recovered]
                : [.queued, .processing, .stalled, .terminal, .completed, .recovered]
            return StoredCollectionWork(id: pick(workIDs),
                context: CollectionWorkContext(scope: pick(scopes), operation: .historicalRead, audit: audit,
                    retry: CoverageSourceRetryDescriptor(scope: pick(scopes), session: pick(sessions),
                        sourceDocumentID: pick(documents), sourceURL: pick(urls))),
                state: pick(states), admittedAt: pick(times), omissionID: pick([nil] + omissionIDs))
        }
        let history = try (0..<size / 4).map { _ in
            let audit = pick(audits)
            let context = try HistoricalAuditContext(id: audit.auditID, reason: .resume, endingAt: now)
            return StoredHistoricalProgress(provider: pick([.codex, .codex, .claudeCode]),
                profileID: pick([profile, profile, "other"]),
                progress: HistoricalReadProgress(audit: context, bytesRead: 0, hasUnreadContent: random.next() % 4 == 0),
                completedAt: pick([nil] + times), continuationQueued: pick([nil, false, false, true]))
        }
        let reads = (0..<size / 4).map { _ in
            SuccessfulCollectionRead(scope: pick(scopes), operation: pick([.liveRead, .historicalRead]), succeededAt: pick(times))
        }
        return CoverageReport(window: .init(start: now.addingTimeInterval(-60), end: now),
            gapEvents: .init(items: events, totalCount: size), omissions: .init(items: omissions, totalCount: omissions.count),
            history: .init(items: history, totalCount: history.count),
            queue: .init(count: 0, encryptedBytes: 0, claimedCount: 0, historicalCount: 0), oldestPendingCaptureAt: nil,
            work: .init(items: work, totalCount: work.count + (random.next() % 4 == 0 ? 1 : 0)),
            successfulReads: .init(items: reads, totalCount: reads.count))
    }

    @Test(arguments: 0..<40 as Range<UInt64>)
    func indexedJoinsMatchNestedScans(seed: UInt64) throws {
        var random = SeededGenerator(state: seed)
        let report = try fixture(size: 120, using: &random)

        let independent = report.independentlyReportedEvents
        #expect(independent.map(\.id) == referenceIndependentEvents(report).map(\.id))
        #expect(report.activeGapEvents.map(\.id)
            == referenceIndependentEvents(report).filter { !referenceRecoveredBacklog($0, in: report) }.map(\.id))
        for event in report.gapEvents.items {
            #expect(report.hasRecoveredBacklog(event) == referenceRecoveredBacklog(event, in: report))
        }
        for id in Set(report.work.items.map(\.id)) {
            #expect(report.work(id: id) == report.work.items.first { $0.id == id })
        }
        for id in report.omissions.items.map(\.id) {
            #expect(report.work(omissionID: id) == report.work.items.first { $0.omissionID == id })
        }
        for audit in Set(report.gapEvents.items.compactMap(\.audit)) {
            #expect(report.work(audit: audit) == report.work.items.filter { $0.context.audit == audit })
        }
        for source in report.work.items.compactMap(\.context.retry) {
            #expect(report.hasPendingWork(for: source) == report.work.items.contains {
                ($0.state == .queued || $0.state == .processing) && $0.context.retry?.identifiesSameSource(as: source) == true
            })
        }
        for read in report.successfulReads.items {
            #expect(report.latestSuccessfulRead(scope: read.scope, operation: read.operation)
                == report.successfulReads.items.filter { $0.scope == read.scope && $0.operation == read.operation }
                    .map(\.succeededAt).max())
        }
    }

    @Test func fixturesExerciseMatchesAndSettlement() throws {
        // Guards the differential test above against fixtures that never match anything.
        var owned = 0, recovered = 0, linkedRecovered = 0, pending = 0
        for seed in 0..<40 as Range<UInt64> {
            var random = SeededGenerator(state: seed)
            let report = try fixture(size: 120, using: &random)
            owned += report.gapEvents.items.count - report.independentlyReportedEvents.count
            let settled = report.gapEvents.items.filter(report.hasRecoveredBacklog)
            recovered += settled.count
            linkedRecovered += settled.filter { $0.workID != nil }.count
            pending += report.work.items.compactMap(\.context.retry).filter(report.hasPendingWork).count
        }
        #expect(owned > 100)
        #expect(recovered > 40)
        #expect(linkedRecovered > 10)
        #expect(pending > 100)
    }

    /// The report limit allows 1,000 rows per collection, and refresh joins them every second.
    /// Nested scans took about 4 s in Debug for 2,000 rows; the bound leaves a wide margin.
    @Test func joinsStayLinearAtTheReportLimit() throws {
        let size = 2000
        let scope = CollectionScope(provider: .codex, profileID: profile, interface: .t3, path: .publicHistory)
        let session = try SessionIdentity(provider: .codex, profileID: profile, sessionID: "synthetic-session")
        func gap(_ index: Int) -> CoverageGap {
            CoverageGap(reason: .malformedSource, scope: scope, contentType: .toolOutput, operation: .historicalRead,
                recovery: CoverageRecoveryReference(session: session, locator: .upstreamItem,
                    itemID: "synthetic-item-\(index)", contentTime: now, parserContract: "synthetic-v1"))
        }
        let report = CoverageReport(window: .init(start: now.addingTimeInterval(-60), end: now),
            gapEvents: .init(items: (0..<size).map { StoredCoverageGapEvent(gap: gap($0), observedAt: now) }, totalCount: size),
            omissions: .init(items: (0..<size).map {
                CoverageOmission(id: UUID(), gap: gap($0 + size), firstObservedAt: now, state: .blocked, resolvedAt: nil)
            }, totalCount: size),
            history: .init(items: [], totalCount: 0),
            queue: .init(count: 0, encryptedBytes: 0, claimedCount: 0, historicalCount: 0), oldestPendingCaptureAt: nil)
        let clock = ContinuousClock()
        var active = 0
        let elapsed = clock.measure { active = report.activeGapEvents.count }
        #expect(active == size)
        #expect(elapsed < .milliseconds(500))
    }
}
