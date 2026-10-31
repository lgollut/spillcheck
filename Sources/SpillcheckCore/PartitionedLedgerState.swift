import CryptoKit
import Foundation

// Layout 2 of the sealed ledger splits the inventory snapshot into segments that are sealed and
// stored separately, so a commit rewrites only what it changed:
//   header         revision, bucket salt and the revision each other segment was last written at
//   core           values, occurrences, receipts and labels: everything that holds findings
//   notifications  alert decisions, strong-signal receipts and historical notification decisions
//   conversations  conversation labels
//   64 buckets     per-source bookkeeping (kind, time, analyzed revisions), placed by a salted HMAC
// This file is pure: no SQLite and no cryptography. ProtectedStore seals and stores what it plans.

enum LedgerLayout {
    static let version = 2
    static let bucketCount = 64
    static let saltLength = 32
}

enum LedgerPart: Int, CaseIterable, Sendable {
    case core = 1, notifications, conversations
}

/// Every segment has its own deterministic binding: the owner is the vault and the reference is
/// derived from the segment's slot, so a stored row cannot be swapped for another one. The header
/// differs from the version-1 ledger binding, which makes older builds fail to open a converted vault.
enum LedgerSegmentID: Hashable, Sendable {
    case header
    case part(LedgerPart)
    case bucket(Int)

    func binding(vaultID: UUID) -> PayloadBinding {
        let slot: (String, Int)
        switch self {
        case .header: slot = ("ledger-header-v2", 0)
        case .part(let part): slot = ("ledger-part-v2", part.rawValue)
        case .bucket(let index): slot = ("ledger-bucket-v2", index)
        }
        let digest = Array(SHA256.hash(data: framedFields(["spillcheck-ledger-segment", String(LedgerLayout.version),
            vaultID.uuidString, slot.0, String(slot.1)])).prefix(16))
        let id = digest.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        return PayloadBinding(reference: ProtectedPayloadReference(id: id), ownerID: vaultID, kind: .ledgerSnapshot)
    }
}

// MARK: Segments

struct LedgerHeader: Codable, Equatable, Sendable {
    var layout: Int
    /// Equals the store_state revision column; a mismatch means the rows come from different writes.
    var revision: Int64
    var bucketCount: Int
    var bucketSalt: Data
    /// The revision each segment was last written at, in part order and bucket order.
    var partRevisions: [Int64]
    var bucketRevisions: [Int64]

    func validate() throws {
        guard layout == LedgerLayout.version, bucketCount == LedgerLayout.bucketCount,
              bucketSalt.count == LedgerLayout.saltLength, revision >= 0,
              partRevisions.count == LedgerPart.allCases.count, bucketRevisions.count == bucketCount,
              (partRevisions + bucketRevisions).allSatisfy({ $0 >= 0 && $0 <= revision }) else {
            throw StorageError.corruptProtectedState
        }
    }
}

struct LedgerCore: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var records: [ValueFingerprint: InventoryRecord]
    var occurrences: [UUID: Occurrence]
    var obsoleteAppearances: [UUID: ObsoleteAppearance]
    var obsoleteMarkers: [ValueFingerprint: ObsoleteValueMarker]
    var unlocatedResults: [UUID: UnlocatedResult]
    var locationReceipts: [OccurrenceIdentity: LocationReceipt]
    var unlocatedReceipts: Set<UnlocatedIdentity>
    var valueLabels: [ValueFingerprint: MaskedValueLabel]
    var unlocatedLabels: [UUID: MaskedValueLabel]
    var nextValueLabel: Int

    init(_ snapshot: InventorySnapshot) {
        schemaVersion = snapshot.schemaVersion
        records = snapshot.records
        occurrences = snapshot.occurrences
        obsoleteAppearances = snapshot.obsoleteAppearances
        obsoleteMarkers = snapshot.obsoleteMarkers
        unlocatedResults = snapshot.unlocatedResults
        locationReceipts = snapshot.locationReceipts
        unlocatedReceipts = snapshot.unlocatedReceipts
        valueLabels = snapshot.valueLabels
        unlocatedLabels = snapshot.unlocatedLabels
        nextValueLabel = snapshot.nextValueLabel
    }
}

struct LedgerNotifications: Codable, Equatable, Sendable {
    var alertDecisions: [UUID: AlertDecision]
    var strongSignalReceipts: [AlertEligibilityKey: StrongSignalReceipt]
    var historicalNotificationDecisions: [UUID: HistoricalNotificationDecision]

    init(_ snapshot: InventorySnapshot) {
        alertDecisions = snapshot.alertDecisions
        strongSignalReceipts = snapshot.strongSignalReceipts
        historicalNotificationDecisions = snapshot.historicalNotificationDecisions
    }
}

struct LedgerConversations: Codable, Equatable, Sendable {
    var conversationLabels: [SessionIdentity: MaskedConversationLabel]

    init(_ snapshot: InventorySnapshot) { conversationLabels = snapshot.conversationLabels }
}

/// A part with the slot and revision it was written for. Both are checked against the header.
struct LedgerPartSegment<Body: Codable & Sendable>: Codable, Sendable {
    var part: Int
    var writtenAtRevision: Int64
    var body: Body
}

/// Sessions group the items they own, so a session identity is encoded once per bucket.
struct LedgerBucketSegment: Codable, Equatable, Sendable {
    struct Receipt: Codable, Equatable, Sendable {
        var revision: ContentRevision
        var detectorVersion: String
    }
    struct Item: Codable, Equatable, Sendable {
        var itemID: String
        var kind: ContentType
        var time: Date?
        var receipts: [Receipt]
    }
    struct Session: Codable, Equatable, Sendable {
        var session: SessionIdentity
        var items: [Item]
    }
    var bucket: Int
    var writtenAtRevision: Int64
    var sessions: [Session]
}

// MARK: Placement

enum LedgerPlacement {
    /// HMAC-SHA256 under the vault's bucket salt over the length-framed identity. The salt keeps
    /// the bucket of a known identity unpredictable to anyone who can only see which rows change.
    static func bucket(of source: SourceIdentity, salt: Data, count: Int = LedgerLayout.bucketCount) -> Int {
        let message = framedFields(["spillcheck-ledger-bucket", source.session.provider.rawValue,
            source.session.profileID, source.session.sessionID, source.itemID])
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: salt))
        return Int(mac.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % UInt64(count))
    }

    static func freshSalt() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}

// MARK: Mirror

/// The bookkeeping exactly as the buckets hold it. A commit updates only the entries the ledger's
/// journal names, and the buckets they fall into are the only ones sealed again.
struct SourceLedgerMirror: Sendable {
    typealias Entry = SourceBookkeeping.Entry

    let salt: Data
    private(set) var buckets: [[SourceIdentity: Entry]]
    private(set) var sourceCount = 0
    private(set) var timeCount = 0
    private(set) var receiptCount = 0

    init(salt: Data, entries: [SourceIdentity: Entry] = [:]) {
        self.salt = salt
        buckets = Array(repeating: [:], count: LedgerLayout.bucketCount)
        for (source, entry) in entries { set(entry, for: source) }
    }

    /// Placement and uniqueness are checked while reading, so a misplaced or repeated entry is corruption.
    init(salt: Data, segments: [LedgerBucketSegment]) throws {
        self.init(salt: salt)
        for segment in segments {
            for group in segment.sessions {
                for item in group.items {
                    guard let source = try? SourceIdentity(session: group.session, itemID: item.itemID),
                          bucket(of: source) == segment.bucket, buckets[segment.bucket][source] == nil else {
                        throw StorageError.corruptProtectedState
                    }
                    let stamps = Set(item.receipts.map { SourceBookkeeping.Stamp(revision: $0.revision, detectorVersion: $0.detectorVersion) })
                    guard stamps.count == item.receipts.count else { throw StorageError.corruptProtectedState }
                    set(Entry(kind: item.kind, time: item.time, stamps: stamps), for: source)
                }
            }
        }
    }

    func bucket(of source: SourceIdentity) -> Int { LedgerPlacement.bucket(of: source, salt: salt) }

    /// Files `entry` for `source`, or removes it for nil. Returns the bucket whose content changed.
    @discardableResult
    mutating func set(_ entry: Entry?, for source: SourceIdentity) -> Int? {
        let index = bucket(of: source)
        let old = buckets[index][source]
        guard old != entry else { return nil }
        if let old {
            sourceCount -= 1
            timeCount -= old.time == nil ? 0 : 1
            receiptCount -= old.stamps.count
        }
        if let entry {
            sourceCount += 1
            timeCount += entry.time == nil ? 0 : 1
            receiptCount += entry.stamps.count
        }
        buckets[index][source] = entry
        return index
    }

    var entries: [SourceIdentity: Entry] {
        buckets.reduce(into: [:]) { $0.merge($1) { first, _ in first } }
    }

    /// Cheap check that no change was missed: counts of the three collections must agree.
    func isConsistent(with bookkeeping: SourceBookkeeping) -> Bool {
        sourceCount == bookkeeping.kinds.count && timeCount == bookkeeping.times.count
            && receiptCount == bookkeeping.receipts.count
    }

    /// Full comparison, linear in the number of sources.
    func matches(_ bookkeeping: SourceBookkeeping) -> Bool { entries == bookkeeping.entries }

    func segment(_ index: Int, writtenAtRevision revision: Int64) -> LedgerBucketSegment {
        let sources = Dictionary(grouping: buckets[index].keys, by: \.session)
        let sessions = sources.keys.sorted {
            ($0.provider.rawValue, $0.profileID, $0.sessionID) < ($1.provider.rawValue, $1.profileID, $1.sessionID)
        }.map { session in
            LedgerBucketSegment.Session(session: session, items: sources[session, default: []]
                .sorted { $0.itemID < $1.itemID }.compactMap { source in
                    buckets[index][source].map { entry in
                        LedgerBucketSegment.Item(itemID: source.itemID, kind: entry.kind, time: entry.time,
                            receipts: entry.stamps.sorted { first, second in
                                first.revision == second.revision ? first.detectorVersion < second.detectorVersion
                                    : first.revision.keyedDigest.lexicographicallyPrecedes(second.revision.keyedDigest)
                            }.map { .init(revision: $0.revision, detectorVersion: $0.detectorVersion) })
                    }
                })
        }
        return LedgerBucketSegment(bucket: index, writtenAtRevision: revision, sessions: sessions)
    }
}

// MARK: Layout state and planning

/// What the store remembers about the rows on disk: enough to decide, for the next write, which
/// segments changed and how large the whole ledger is, without reading or sealing the rest.
struct LedgerLayoutState: Sendable {
    struct Sizes: Equatable, Sendable {
        var header = 0
        var parts = Array(repeating: 0, count: LedgerPart.allCases.count)
        var buckets = Array(repeating: 0, count: LedgerLayout.bucketCount)
        var total: Int { header + parts.reduce(0, +) + buckets.reduce(0, +) }
    }

    /// False for a version-1 vault, which converts atomically on its first write.
    var isPartitioned: Bool
    var header: LedgerHeader
    var mirror: SourceLedgerMirror
    var sizes: Sizes
    /// Parts the next write must include although the ledger equals its committed copy: whatever
    /// opening normalized, and the notifications, so the outbox is resynchronized.
    var forced: Set<LedgerPart>
    /// Set when the mirror is found to disagree with the ledger: the next write rebuilds and rewrites every bucket.
    var rewriteAllBuckets = false

    /// A vault with no partitioned rows yet. The first write seals every segment.
    static func unpartitioned(revision: Int64) -> Self {
        let salt = LedgerPlacement.freshSalt()
        return Self(isPartitioned: false,
            header: LedgerHeader(layout: LedgerLayout.version, revision: revision, bucketCount: LedgerLayout.bucketCount,
                bucketSalt: salt, partRevisions: Array(repeating: 0, count: LedgerPart.allCases.count),
                bucketRevisions: Array(repeating: 0, count: LedgerLayout.bucketCount)),
            mirror: SourceLedgerMirror(salt: salt), sizes: Sizes(), forced: Set(LedgerPart.allCases))
    }
}

/// Plaintext of the segments one write must seal, and the layout state once it commits.
struct LedgerWritePlan: Sendable {
    let isConversion: Bool
    let header: Data
    let parts: [LedgerPart: Data]
    let buckets: [Int: Data]
    let layout: LedgerLayoutState
    /// The journal missed a source; every bucket was rewritten from the ledger instead.
    let repairedMirror: Bool

    var coreChanged: Bool { parts[.core] != nil }
    var notificationsChanged: Bool { parts[.notifications] != nil }
}

extension LedgerLayoutState {
    /// Plans the write that takes `committed` to `next` at `revision`. Takes the journal from `next`.
    /// A part is rewritten when it differs from the committed one, which is exact and costs nothing
    /// for shared storage; a bucket when the entry of a journaled source changed. Every segment is
    /// rewritten for a conversion. Throws `stateTooLarge` if the segments exceed `maximumBytes`.
    func plan(committed: InventoryLedger, next: inout InventoryLedger, revision: Int64, maximumBytes: Int) throws -> LedgerWritePlan {
        let touched = next.takeBookkeepingChanges()
        let conversion = !isPartitioned
        var mirror = self.mirror
        var dirtyBuckets: Set<Int> = []
        var repaired = false
        if conversion || rewriteAllBuckets {
            mirror = SourceLedgerMirror(salt: header.bucketSalt, entries: next.bookkeeping.entries)
            dirtyBuckets = Set(0..<LedgerLayout.bucketCount)
        } else {
            for source in touched {
                if let bucket = mirror.set(next.bookkeeping.entry(for: source), for: source) { dirtyBuckets.insert(bucket) }
            }
            if !mirror.isConsistent(with: next.bookkeeping) {
                mirror = SourceLedgerMirror(salt: header.bucketSalt, entries: next.bookkeeping.entries)
                dirtyBuckets = Set(0..<LedgerLayout.bucketCount)
                repaired = true
            }
        }

        let before = committed.snapshot, after = next.snapshot
        var dirtyParts = conversion ? Set(LedgerPart.allCases) : forced
        if LedgerCore(before) != LedgerCore(after) { dirtyParts.insert(.core) }
        if LedgerNotifications(before) != LedgerNotifications(after) { dirtyParts.insert(.notifications) }
        if LedgerConversations(before) != LedgerConversations(after) { dirtyParts.insert(.conversations) }

        var header = self.header
        var sizes = self.sizes
        let encoder = JSONEncoder()
        var parts: [LedgerPart: Data] = [:]
        for part in dirtyParts {
            let encoded: Data
            switch part {
            case .core:
                encoded = try encoder.encode(LedgerPartSegment(part: part.rawValue, writtenAtRevision: revision, body: LedgerCore(after)))
            case .notifications:
                encoded = try encoder.encode(LedgerPartSegment(part: part.rawValue, writtenAtRevision: revision, body: LedgerNotifications(after)))
            case .conversations:
                encoded = try encoder.encode(LedgerPartSegment(part: part.rawValue, writtenAtRevision: revision, body: LedgerConversations(after)))
            }
            parts[part] = encoded
            header.partRevisions[part.rawValue - 1] = revision
            sizes.parts[part.rawValue - 1] = encoded.count
        }
        var buckets: [Int: Data] = [:]
        for bucket in dirtyBuckets {
            let encoded = try encoder.encode(mirror.segment(bucket, writtenAtRevision: revision))
            buckets[bucket] = encoded
            header.bucketRevisions[bucket] = revision
            sizes.buckets[bucket] = encoded.count
        }
        header.revision = revision
        let encodedHeader = try encoder.encode(header)
        sizes.header = encodedHeader.count
        guard sizes.total <= maximumBytes else { throw StorageError.stateTooLarge }
        return LedgerWritePlan(isConversion: conversion, header: encodedHeader, parts: parts, buckets: buckets,
            layout: Self(isPartitioned: true, header: header, mirror: mirror, sizes: sizes, forced: []),
            repairedMirror: repaired)
    }
}

// MARK: Assembly

enum LedgerAssembly {
    /// Rebuilds the snapshot and the mirror from decoded segments. Anything that does not fit the
    /// header (a stale or misplaced segment, a missing bucket, a repeated source) is corruption.
    static func assemble(
        header: LedgerHeader, core: LedgerPartSegment<LedgerCore>,
        notifications: LedgerPartSegment<LedgerNotifications>, conversations: LedgerPartSegment<LedgerConversations>,
        buckets: [LedgerBucketSegment]
    ) throws -> (snapshot: InventorySnapshot, mirror: SourceLedgerMirror) {
        try header.validate()
        for (part, written) in [(LedgerPart.core, (core.part, core.writtenAtRevision)),
                                (.notifications, (notifications.part, notifications.writtenAtRevision)),
                                (.conversations, (conversations.part, conversations.writtenAtRevision))] {
            guard written.0 == part.rawValue, written.1 == header.partRevisions[part.rawValue - 1] else {
                throw StorageError.corruptProtectedState
            }
        }
        guard buckets.count == header.bucketCount else { throw StorageError.corruptProtectedState }
        for (index, bucket) in buckets.enumerated() {
            guard bucket.bucket == index, bucket.writtenAtRevision == header.bucketRevisions[index] else {
                throw StorageError.corruptProtectedState
            }
        }
        let mirror = try SourceLedgerMirror(salt: header.bucketSalt, segments: buckets)
        return (InventorySnapshot(core: core.body, notifications: notifications.body,
                                  conversations: conversations.body, sources: mirror), mirror)
    }
}

extension InventorySnapshot {
    init(core: LedgerCore, notifications: LedgerNotifications, conversations: LedgerConversations, sources: SourceLedgerMirror) {
        var receipts: Set<AnalysisReceipt> = []
        var kinds: [SourceIdentity: ContentType] = [:]
        var times: [SourceIdentity: Date] = [:]
        for (source, entry) in sources.entries {
            kinds[source] = entry.kind
            times[source] = entry.time
            for stamp in entry.stamps {
                receipts.insert(AnalysisReceipt(source: source, revision: stamp.revision, detectorVersion: stamp.detectorVersion))
            }
        }
        self.init(schemaVersion: core.schemaVersion, records: core.records, occurrences: core.occurrences,
            obsoleteAppearances: core.obsoleteAppearances, obsoleteMarkers: core.obsoleteMarkers,
            alertDecisions: notifications.alertDecisions, unlocatedResults: core.unlocatedResults,
            analysisReceipts: receipts, locationReceipts: core.locationReceipts,
            strongSignalReceipts: notifications.strongSignalReceipts, unlocatedReceipts: core.unlocatedReceipts,
            sourceKinds: kinds, sourceTimes: times, conversationLabels: conversations.conversationLabels,
            historicalNotificationDecisions: notifications.historicalNotificationDecisions,
            valueLabels: core.valueLabels, unlocatedLabels: core.unlocatedLabels, nextValueLabel: core.nextValueLabel)
    }

    /// Field-by-field equality, used to prove that what was written reads back as the ledger.
    func matches(_ other: InventorySnapshot) -> Bool {
        LedgerCore(self) == LedgerCore(other) && LedgerNotifications(self) == LedgerNotifications(other)
            && LedgerConversations(self) == LedgerConversations(other) && analysisReceipts == other.analysisReceipts
            && sourceKinds == other.sourceKinds && sourceTimes == other.sourceTimes
    }
}
