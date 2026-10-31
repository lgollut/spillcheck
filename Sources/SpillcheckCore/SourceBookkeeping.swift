import Foundation

/// What the ledger remembers about each analyzed source: its content type, latest content time
/// and the content revisions already analyzed. Storage is private and every mutator records the
/// source it touches, so persistence can rewrite exactly the entries that changed. A failed
/// ingest works on a copy and discards its journal with the rest of its state.
struct SourceBookkeeping: Sendable {
    /// One analyzed revision of a source; the source is the key it is filed under.
    struct Stamp: Hashable, Sendable {
        let revision: ContentRevision
        let detectorVersion: String
    }

    struct Entry: Equatable, Sendable {
        var kind: ContentType
        /// Nil for sources recorded before content times were tracked.
        var time: Date?
        var stamps: Set<Stamp>
    }

    // The flat collections stay available because snapshot() and the pipeline's skip check read
    // them on every source. `stamps` indexes the same receipts per source.
    private(set) var receipts: Set<AnalysisReceipt> = []
    private(set) var kinds: [SourceIdentity: ContentType] = [:]
    private(set) var times: [SourceIdentity: Date] = [:]
    private var stamps: [SourceIdentity: Set<Stamp>] = [:]
    private var changes: Set<SourceIdentity> = []

    init() {}

    /// A restored state has an empty journal: it is what is already persisted.
    init(receipts: Set<AnalysisReceipt>, kinds: [SourceIdentity: ContentType], times: [SourceIdentity: Date]) {
        self.receipts = receipts
        self.kinds = kinds
        self.times = times
        for receipt in receipts {
            stamps[receipt.source, default: []].insert(Stamp(revision: receipt.revision, detectorVersion: receipt.detectorVersion))
        }
    }

    func entry(for source: SourceIdentity) -> Entry? {
        kinds[source].map { Entry(kind: $0, time: times[source], stamps: stamps[source] ?? []) }
    }

    /// Every source with a kind, as persistence files it.
    var entries: [SourceIdentity: Entry] {
        Dictionary(uniqueKeysWithValues: kinds.map { ($0.key, Entry(kind: $0.value, time: times[$0.key], stamps: stamps[$0.key] ?? [])) })
    }

    mutating func setKind(_ kind: ContentType, for source: SourceIdentity) {
        kinds[source] = kind
        changes.insert(source)
    }

    mutating func raiseTime(to time: Date, for source: SourceIdentity) {
        times[source] = max(times[source] ?? .distantPast, time)
        changes.insert(source)
    }

    @discardableResult
    mutating func insertReceipt(_ receipt: AnalysisReceipt) -> Bool {
        guard receipts.insert(receipt).inserted else { return false }
        stamps[receipt.source, default: []].insert(Stamp(revision: receipt.revision, detectorVersion: receipt.detectorVersion))
        changes.insert(receipt.source)
        return true
    }

    mutating func removeReceipts(of sources: Set<SourceIdentity>) {
        for source in sources {
            guard let removed = stamps.removeValue(forKey: source) else { continue }
            for stamp in removed {
                receipts.remove(AnalysisReceipt(source: source, revision: stamp.revision, detectorVersion: stamp.detectorVersion))
            }
            changes.insert(source)
        }
    }

    /// Forgets a source's kind and time. Its receipts are removed separately.
    mutating func remove(source: SourceIdentity) {
        kinds.removeValue(forKey: source)
        times.removeValue(forKey: source)
        changes.insert(source)
    }

    mutating func stampUntimed(at now: Date) {
        for source in kinds.keys where times[source] == nil {
            times[source] = now
            changes.insert(source)
        }
    }

    /// The sources touched since the last call; persistence calls this once per write attempt.
    mutating func takeChanges() -> Set<SourceIdentity> {
        defer { changes = [] }
        return changes
    }
}
