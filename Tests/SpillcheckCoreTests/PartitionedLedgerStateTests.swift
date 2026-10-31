import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

/// A stand-in for the rows on disk: the plaintext of the latest write of every segment.
private struct SimulatedDisk {
    var header = Data()
    var parts: [LedgerPart: Data] = [:]
    var buckets: [Int: Data] = [:]

    mutating func apply(_ plan: LedgerWritePlan) {
        header = plan.header
        parts.merge(plan.parts) { $1 }
        buckets.merge(plan.buckets) { $1 }
    }

    func reassemble(omittingBucket omitted: Int? = nil) throws -> (snapshot: InventorySnapshot, mirror: SourceLedgerMirror) {
        let decoder = JSONDecoder()
        return try LedgerAssembly.assemble(
            header: decoder.decode(LedgerHeader.self, from: header),
            core: decoder.decode(LedgerPartSegment<LedgerCore>.self, from: parts[.core] ?? Data()),
            notifications: decoder.decode(LedgerPartSegment<LedgerNotifications>.self, from: parts[.notifications] ?? Data()),
            conversations: decoder.decode(LedgerPartSegment<LedgerConversations>.self, from: parts[.conversations] ?? Data()),
            buckets: (0..<LedgerLayout.bucketCount).filter { $0 != omitted }
                .map { try decoder.decode(LedgerBucketSegment.self, from: buckets[$0] ?? Data()) })
    }
}

/// Drives the planner the way the store does: plan against the committed ledger, then adopt the result.
private struct PlannedStore {
    var ledger = InventoryLedger()
    var layout = LedgerLayoutState.unpartitioned(revision: 0)
    var disk = SimulatedDisk()
    var revision: Int64 = 0
    private(set) var firstPlan: LedgerWritePlan!

    init() throws { firstPlan = try write { _ in } }

    @discardableResult
    mutating func write(maximumBytes: Int = .max, _ change: (inout InventoryLedger) throws -> Void) throws -> LedgerWritePlan {
        var next = ledger
        try change(&next)
        let plan = try layout.plan(committed: ledger, next: &next, revision: revision + 1, maximumBytes: maximumBytes)
        revision += 1
        ledger = next
        layout = plan.layout
        disk.apply(plan)
        return plan
    }
}

@Suite("Partitioned ledger planning and assembly")
struct PartitionedLedgerStateTests {
    private let salt = Data(0..<32)

    @Test func bucketPlacementGoldenVectors() throws {
        // Independently computed: HMAC-SHA256(salt = 00 01 .. 1f, length-framed domain and identity) mod 64.
        let vectors: [(AgentProvider, String, String, String, Int)] = [
            (.codex, "profile-a", "session-1", "item-1", 28), (.codex, "profile-a", "session-1", "item-2", 3),
            (.claudeCode, "profile-b", "s", "turn-7", 63), (.codex, "p", "s", "x", 59),
            (.claudeCode, "héllo", "sess/ü", "item 9", 56), (.codex, "profile-a", "session-2", "item-1", 47),
        ]
        for (provider, profile, session, item, expected) in vectors {
            let source = try SourceIdentity(session: SessionIdentity(provider: provider, profileID: profile, sessionID: session), itemID: item)
            #expect(LedgerPlacement.bucket(of: source, salt: salt) == expected)
        }
        let source = try SourceIdentity(session: SessionIdentity(provider: .codex, profileID: "profile-a", sessionID: "session-1"), itemID: "item-1")
        #expect(LedgerPlacement.bucket(of: source, salt: Data(repeating: 7, count: 32)) != 28
            || LedgerPlacement.bucket(of: source, salt: Data(repeating: 8, count: 32)) != 28)
    }

    @Test func segmentBindingsAreDeterministicDistinctAndOwnedByTheVault() throws {
        let vault = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000AA"))
        let all = [LedgerSegmentID.header] + LedgerPart.allCases.map { .part($0) } + (0..<LedgerLayout.bucketCount).map { .bucket($0) }
        let bindings = all.map { $0.binding(vaultID: vault) }
        #expect(Set(bindings.map(\.reference)).count == 68)
        #expect(bindings.allSatisfy { $0.ownerID == vault && $0.kind == .ledgerSnapshot })
        #expect(!bindings.contains { $0.reference.id == vault })
        #expect(LedgerSegmentID.header.binding(vaultID: vault) == bindings[0])
        #expect(Set(all.map { $0.binding(vaultID: UUID()).reference }).isDisjoint(with: bindings.map(\.reference)))
        // Pinned, so a refactor cannot silently re-key every converted vault.
        #expect(bindings[0].reference.id.uuidString == "9D6E6A66-7951-5333-D7BB-96775CBB44EC")
        #expect(LedgerSegmentID.part(.notifications).binding(vaultID: vault).reference.id.uuidString == "26E2109F-363D-9ACA-7211-0D54B4BE1B78")
        #expect(LedgerSegmentID.bucket(63).binding(vaultID: vault).reference.id.uuidString == "66D2C45C-B73A-469C-65DE-21417726F932")
    }

    @Test func theFirstWriteSealsEverySegment() throws {
        let store = try PlannedStore()
        let plan = try #require(store.firstPlan)
        #expect(plan.isConversion && Set(plan.parts.keys) == Set(LedgerPart.allCases) && plan.buckets.count == 64)
        #expect(store.disk.parts.count == 3 && store.disk.buckets.count == 64)
        #expect(store.layout.isPartitioned && store.layout.sizes.total < 8 * 1024)
    }

    @Test func quietSourcesDirtyOneBucketAndNoPart() throws {
        var store = try PlannedStore()
        for index in 0..<20 {
            let plan = try store.write { _ = try $0.ingest(SourceAnalysis(source: sourceRecord(item: "quiet-\(index)"),
                detectorVersion: "1", detections: [])) }
            // The first source of a session also labels the conversation.
            #expect(Set(plan.parts.keys) == (index == 0 ? [.conversations] : []))
            #expect(plan.buckets.count == 1)
            #expect(plan.header.count < 4096)
        }
        let snapshot = try store.disk.reassemble().snapshot
        #expect(snapshot.matches(store.ledger.snapshot) && snapshot.sourceKinds.count == 20)
    }

    @Test func replayPlansNothingButTheHeader() throws {
        var store = try PlannedStore()
        let source = try sourceRecord(item: "once")
        let quiet = try SourceAnalysis(source: source, detectorVersion: "1", detections: [])
        try store.write { _ = try $0.ingest(quiet) }
        let revision = store.revision
        let plan = try store.write { ledger in
            let outcome = try ledger.ingest(quiet).outcome
            #expect(outcome == .replay)
        }
        #expect(plan.parts.isEmpty && plan.buckets.isEmpty && plan.layout.header.revision == revision + 1)
    }

    @Test func conversationLabelsAreWrittenOnlyForANewSession() throws {
        var store = try PlannedStore()
        let first = try store.write { _ = try $0.ingest(analysis(session: "one")) }
        #expect(Set(first.parts.keys) == [.core, .notifications, .conversations] && first.buckets.count == 1)
        let sameSession = try store.write { _ = try $0.ingest(analysis(session: "one", item: "second", fingerprintByte: 2)) }
        #expect(Set(sameSession.parts.keys) == [.core, .notifications] && sameSession.buckets.count == 1)
        let sameValue = try store.write { _ = try $0.ingest(analysis(session: "one", item: "third", fingerprintByte: 2)) }
        #expect(Set(sameValue.parts.keys) == [.core] && sameValue.buckets.count == 1)
        let newSession = try store.write { _ = try $0.ingest(SourceAnalysis(source: sourceRecord(session: "two", item: "quiet"),
            detectorVersion: "1", detections: [])) }
        #expect(Set(newSession.parts.keys) == [.conversations] && newSession.buckets.count == 1)
    }

    @Test func alertDeliveryRewritesOnlyTheNotificationsPart() throws {
        var store = try PlannedStore()
        try store.write { _ = try $0.ingest(analysis()) }
        let alert = try #require(store.ledger.alertDecisions.keys.first)
        let plan = try store.write { try $0.recordAlertDelivery(alert, state: .delivered) }
        #expect(Set(plan.parts.keys) == [.notifications] && plan.buckets.isEmpty)
        let review = try #require(store.ledger.occurrences.keys.first)
        let reviewed = try store.write { try $0.review(review, as: .confirmedSecret) }
        #expect(Set(reviewed.parts.keys) == [.core] && reviewed.buckets.isEmpty)
    }

    @Test func forcedPartsAreWrittenOnceEvenWhenNothingChanged() throws {
        var store = try PlannedStore()
        store.layout.forced = [.notifications]
        let plan = try store.write { _ in }
        #expect(Set(plan.parts.keys) == [.notifications] && plan.buckets.isEmpty && plan.layout.forced.isEmpty)
        #expect(try store.write { _ in }.parts.isEmpty)
    }

    @Test func plannedSegmentsReassembleToTheLedgerAfterRandomOperations() throws {
        for seed in 1...8 as ClosedRange<UInt64> {
            var random = SeededRandom(seed: seed)
            var store = try PlannedStore()
            for step in 0..<60 {
                try store.write { try randomLedgerOperation(&$0, using: &random) }
                let reread = try store.disk.reassemble()
                #expect(reread.snapshot.matches(store.ledger.snapshot), "seed \(seed) step \(step)")
                #expect(reread.mirror.matches(store.ledger.bookkeeping), "seed \(seed) step \(step)")
                #expect(store.layout.mirror.matches(store.ledger.bookkeeping))
                #expect(store.layout.header == (try JSONDecoder().decode(LedgerHeader.self, from: store.disk.header)))
            }
        }
    }

    @Test func aMissedJournalEntryRewritesEveryBucketFromTheLedger() throws {
        var store = try PlannedStore()
        for index in 0..<5 { try store.write { _ = try $0.ingest(analysis(item: "item-\(index)")) } }
        // A ledger restored from a snapshot has an empty journal, so its extra source is invisible to it.
        var changed = store.ledger
        _ = try changed.ingest(analysis(item: "unjournaled"))
        var next = try InventoryLedger(snapshot: changed.snapshot)
        let plan = try store.layout.plan(committed: store.ledger, next: &next, revision: store.revision + 1, maximumBytes: .max)
        #expect(plan.repairedMirror && plan.buckets.count == LedgerLayout.bucketCount)
        store.disk.apply(plan)
        #expect(try store.disk.reassemble().snapshot.matches(changed.snapshot))
    }

    @Test func theSumOfEverySegmentIsBoundedByTheStateLimit() throws {
        var store = try PlannedStore()
        let change: (inout InventoryLedger) throws -> Void = { _ = try $0.ingest(analysis()) }
        var scratch = store
        let total = try scratch.write(change).layout.sizes.total
        // The bound covers the clean segments too, not only the ones this write seals.
        #expect(total == scratch.disk.header.count + scratch.disk.parts.values.map(\.count).reduce(0, +)
            + scratch.disk.buckets.values.map(\.count).reduce(0, +))
        #expect(throws: StorageError.stateTooLarge) { try store.write(maximumBytes: total - 1, change) }
        #expect(store.revision == 1 && store.ledger.alertDecisions.isEmpty)
        try store.write(maximumBytes: total, change)
        #expect(store.revision == 2)
    }

    @Test func assemblyRejectsEverySegmentThatDisagreesWithTheHeader() throws {
        var store = try PlannedStore()
        for index in 0..<30 { try store.write { _ = try $0.ingest(analysis(item: "item-\(index)")) } }
        let disk = store.disk
        _ = try disk.reassemble()
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let populated = try #require((0..<64).first { disk.buckets[$0].flatMap { try? decoder.decode(LedgerBucketSegment.self, from: $0) }?.sessions.isEmpty == false })
        let other = try #require((0..<64).first { $0 != populated })

        func header(_ change: (inout LedgerHeader) -> Void) throws -> SimulatedDisk {
            var tampered = disk
            var value = try decoder.decode(LedgerHeader.self, from: disk.header)
            change(&value)
            tampered.header = try encoder.encode(value)
            return tampered
        }
        func bucket(_ index: Int, _ change: (inout LedgerBucketSegment) -> Void) throws -> SimulatedDisk {
            var tampered = disk
            var value = try decoder.decode(LedgerBucketSegment.self, from: disk.buckets[index] ?? Data())
            change(&value)
            tampered.buckets[index] = try encoder.encode(value)
            return tampered
        }
        func core(_ change: (inout LedgerPartSegment<LedgerCore>) -> Void) throws -> SimulatedDisk {
            var tampered = disk
            var value = try decoder.decode(LedgerPartSegment<LedgerCore>.self, from: disk.parts[.core] ?? Data())
            change(&value)
            tampered.parts[.core] = try encoder.encode(value)
            return tampered
        }
        var swapped = disk
        swapped.buckets[populated] = disk.buckets[other]
        swapped.buckets[other] = disk.buckets[populated]
        let moved = try decoder.decode(LedgerBucketSegment.self, from: disk.buckets[populated] ?? Data())
        var duplicated = try bucket(populated) { $0.sessions += $0.sessions }
        let cases: [(String, SimulatedDisk)] = [
            ("layout from the future", try header { $0.layout = 3 }),
            ("header revision behind a segment", try header { $0.revision = 1 }),
            ("stale core revision", try header { $0.partRevisions[0] += 1 }),
            ("stale bucket revision", try header { $0.bucketRevisions[populated] += 1 }),
            ("short salt", try header { $0.bucketSalt = Data(repeating: 1, count: 16) }),
            ("different salt", try header { $0.bucketSalt = Data(repeating: 9, count: 32) }),
            ("missing bucket revision", try header { $0.bucketRevisions.removeLast() }),
            ("core in the wrong slot", try core { $0.part = LedgerPart.conversations.rawValue }),
            ("core written at another revision", try core { $0.writtenAtRevision -= 1 }),
            ("bucket in the wrong slot", try bucket(populated) { $0.bucket = other }),
            ("entry in the wrong bucket", try bucket(other) { $0.sessions = moved.sessions }),
            ("duplicated session", duplicated),
            ("swapped buckets", swapped),
        ]
        for (name, tampered) in cases {
            #expect(throws: StorageError.corruptProtectedState, "\(name)") { try tampered.reassemble() }
        }
        #expect(throws: StorageError.corruptProtectedState, "missing bucket") { try disk.reassemble(omittingBucket: other) }
        duplicated = try bucket(populated) { segment in
            segment.sessions = segment.sessions.map { var group = $0; group.items += group.items; return group }
        }
        #expect(throws: StorageError.corruptProtectedState) { try duplicated.reassemble() }
    }

    @Test func mirrorFollowsTheJournalAcrossRandomOperations() throws {
        for seed in 1...8 as ClosedRange<UInt64> {
            var random = SeededRandom(seed: seed)
            var ledger = InventoryLedger()
            var mirror = SourceLedgerMirror(salt: salt)
            for step in 0..<80 {
                try randomLedgerOperation(&ledger, using: &random)
                for source in ledger.takeBookkeepingChanges() { mirror.set(ledger.bookkeeping.entry(for: source), for: source) }
                #expect(mirror.matches(ledger.bookkeeping) && mirror.isConsistent(with: ledger.bookkeeping), "seed \(seed) step \(step)")
            }
        }
    }
}
