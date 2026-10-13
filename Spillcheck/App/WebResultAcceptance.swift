#if DEBUG
import Darwin
import Foundation
@_spi(Testing) import SpillcheckCore

/// A bounded witness over the normal native parser and encrypted analysis ledger.
/// It never supplies a detector result or exports source identities or content.
@MainActor
final class WebResultAcceptance {
    static let maximumSources = 128
    static let maximumSegments = 1024
    static let maximumBytes = 1024 * 1024
    enum Failure: String, Error { case unsafeConfiguration, unsafeState, foreignSource, invalidWebSource,
        changedSource, incompleteRead, receiptMismatch, reportUnavailable }
    struct Observation: Equatable {
        let receipt: AnalysisReceipt
        let sourceDigest: String
        let resultDigest: String
        let segmentCount: Int
        let textBytes: Int
        let pointerBytes: Int
        let producerVersion: String
    }
    struct Report: Encodable {
        let measured = true
        let truncated = false
        let nativeKindEvidence = "pinned-codex-results-root"
        let parserContract = CodexAdapter.parserContract
        let detectorVersion = BetterleaksSecretDetector.version
        let initialStoreEmpty: Bool
        let initialReceiptDigests: [String]
        let initialSourceKindDigests: [String]
        let receiptDigests: [String]
        let sourceKindDigests: [String]
        let sourceTimeDigests: [String]
        let receiptCount: Int
        let sourceCount: Int
        let sessionCount: Int
        let observedWebSourceCount: Int
        let committedWebSourceCount: Int
        let webSourceDigests: [String]
        let webResultDigests: [String]
        let webReceiptDigests: [String]
        let resultSegmentCount: Int
        let resultTextBytes: Int
        let resultPointerBytes: Int
        let allObservedWebSourcesCommitted: Bool
        let cleanInventory: Bool
        let payloadRowCount: Int
        let batchCount: Int
        let readerVersions: [String]
        let producerVersions: [String]
    }
    private struct Pair<K: Encodable, V: Encodable>: Encodable { let key: K; let value: V }
    let session: SessionIdentity
    private(set) var failure: Failure?
    private var initialized = false
    private var initialStoreEmpty = false
    private var initialReceiptDigests: [String] = []
    private var initialSourceKindDigests: [String] = []
    private var observations: [SourceIdentity: Observation] = [:]
    private var batchCount = 0
    private var readerVersions: Set<String> = []

    init(session: SessionIdentity) { self.session = session }

    static func selectedSession(configuration: CodexCollectionConfiguration,
                                recovery: DisposableRecoveryConfiguration) throws -> SessionIdentity {
        guard recovery.webResultsEnabled, let source = recovery.webSourceID,
              configuration.interface == .standaloneCLI, configuration.authority == .publicNativeItems,
              configuration.authorizedHosts == [.standaloneCLI], configuration.activeSources.isEmpty,
              configuration.home.deletingLastPathComponent().path == recovery.root.path else {
            throw Failure.unsafeConfiguration
        }
        // Use the same POSIX canonical spelling required by the recovery root.
        // Foundation aliases existing /private/tmp paths to /tmp on this host.
        guard let canonicalHome = realpath(configuration.home.path, nil) else { throw Failure.unsafeConfiguration }
        defer { free(canonicalHome) }
        guard String(cString: canonicalHome) == configuration.home.path else { throw Failure.unsafeConfiguration }
        var info = stat()
        guard lstat(configuration.home.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Failure.unsafeConfiguration }
        return try SessionIdentity(provider: .codex, profileID: configuration.profileID, sessionID: source)
    }

    func captureInitial(_ snapshot: InventorySnapshot, cryptography: BackgroundCryptography) async throws {
        guard !initialized else { throw Failure.unsafeState }
        try validate(snapshot)
        initialStoreEmpty = snapshot.analysisReceipts.isEmpty && snapshot.sourceKinds.isEmpty
            && snapshot.sourceTimes.isEmpty && snapshot.conversationLabels.isEmpty && snapshot.nextValueLabel == 1
            && Self.hasNoFindings(snapshot)
        initialReceiptDigests = try await digests("receipt", Array(snapshot.analysisReceipts), cryptography)
        initialSourceKindDigests = try await digests("source-kind",
            snapshot.sourceKinds.map { Pair(key: $0.key, value: $0.value) }, cryptography)
        initialized = true
    }

    func reject(_ reason: Failure) { if failure == nil { failure = reason } }

    /// Mirrors the pinned v6 canonical revision framing without normalizing text.
    static func canonicalSegments(_ segments: [SourceSegment]) -> Data {
        var bytes = Data("codex-segments-v1".utf8)
        for segment in segments {
            for value in [Data(segment.id.utf8), segment.utf8] {
                var count = UInt64(value.count).bigEndian
                withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
                bytes.append(value)
            }
        }
        return bytes
    }

    /// /results/ is exclusive to native webSearch in this pinned Codex parser.
    /// The public-history path, origin, locator and exact session are checked too;
    /// query/action fields and assistant echoes cannot supply these coordinates.
    static func isWebSource(_ source: SourceRecord, session: SessionIdentity) throws -> Bool {
        guard source.metadata.identity.session == session else { throw Failure.foreignSource }
        guard source.metadata.origin.adapterID == "codex",
              source.metadata.origin.adapterVersion == CodexAdapter.adapterVersion,
              source.metadata.origin.interface == .standaloneCLI,
              source.metadata.origin.canonicalization == .exclusiveAuthority,
              source.metadata.locator == .upstreamItem else { throw Failure.invalidWebSource }
        let resultPointers = source.segments.filter { $0.id.hasPrefix("/results/") }
        guard !resultPointers.isEmpty else { return false }
        guard source.metadata.contentType == .toolOutput, resultPointers.count == source.segments.count,
              source.segments.count <= maximumSegments,
              source.segments.allSatisfy({ !$0.utf8.isEmpty }),
              source.segments.reduce(0, { $0 + $1.utf8.count }) <= maximumBytes,
              source.segments.reduce(0, { $0 + $1.id.utf8.count }) <= maximumBytes else {
            throw Failure.invalidWebSource
        }
        return true
    }

    func observe(_ batch: CollectionBatch, metadata: CaptureMetadata, path: CollectionPath,
                 cryptography: BackgroundCryptography) async {
        guard failure == nil else { return }
        do {
            guard initialized, metadata.agent == .codex, metadata.profileID == session.profileID,
                  metadata.interface == .standaloneCLI, path == .publicHistory else { throw Failure.foreignSource }
            guard batchCount < Self.maximumSources, batch.sources.count <= Self.maximumSources,
                  InventoryStateAcceptance.hasReadEvidence(batch),
                  !batch.coverageGaps.contains(where: { $0.requiresAnalysis && ($0.reason != .budgetExhausted || batch.continuation == nil) }),
                  let reader = batch.observedReaderVersion, !reader.isEmpty, reader.utf8.count <= 256 else {
                throw Failure.incompleteRead
            }
            batchCount += 1
            readerVersions.insert(reader)
            guard readerVersions.count <= 2 else { throw Failure.incompleteRead }
            for collected in batch.sources {
                let source = collected.record
                guard try Self.isWebSource(source, session: session) else { continue }
                guard source.metadata.origin.agentVersion.utf8.count <= 256 else { throw Failure.invalidWebSource }
                let canonical = Self.canonicalSegments(source.segments)
                guard try await cryptography.revision(canonicalBytes: canonical) == source.revision else {
                    throw Failure.invalidWebSource
                }
                let receipt = AnalysisReceipt(source: source.metadata.identity, revision: source.revision,
                    detectorVersion: BetterleaksSecretDetector.version)
                let sourceDigest = try await digest("source", source.metadata.identity, cryptography)
                // Length frames retain pointer/text boundaries and original UTF-8 bytes.
                var bytes = Data("web-result-state-v1/result\n".utf8)
                bytes.append(Data(sourceDigest.utf8)); bytes.append(0)
                bytes.append(source.revision.keyedDigest); bytes.append(canonical)
                let resultDigest = try await cryptography.revision(canonicalBytes: bytes).keyedDigest.base64EncodedString()
                let observed = Observation(receipt: receipt, sourceDigest: sourceDigest, resultDigest: resultDigest,
                    segmentCount: source.segments.count, textBytes: source.segments.reduce(0) { $0 + $1.utf8.count },
                    pointerBytes: source.segments.reduce(0) { $0 + $1.id.utf8.count },
                    producerVersion: source.metadata.origin.agentVersion)
                if let previous = observations[source.metadata.identity], previous != observed { throw Failure.changedSource }
                guard observations.count < Self.maximumSources || observations[source.metadata.identity] != nil else {
                    throw Failure.invalidWebSource
                }
                observations[source.metadata.identity] = observed
                guard observations.values.reduce(0, { $0 + $1.textBytes + $1.pointerBytes }) <= 2 * Self.maximumBytes,
                      observations.values.reduce(0, { $0 + $1.segmentCount }) <= Self.maximumSegments else {
                    throw Failure.invalidWebSource
                }
            }
        } catch { reject((error as? Failure) ?? .reportUnavailable) }
    }

    static func hasNoFindings(_ snapshot: InventorySnapshot) -> Bool {
        snapshot.records.isEmpty && snapshot.occurrences.isEmpty && snapshot.obsoleteMarkers.isEmpty
            && snapshot.obsoleteAppearances.isEmpty && snapshot.alertDecisions.isEmpty
            && snapshot.historicalNotificationDecisions.isEmpty && snapshot.unlocatedResults.isEmpty
            && snapshot.locationReceipts.isEmpty && snapshot.strongSignalReceipts.isEmpty
            && snapshot.unlocatedReceipts.isEmpty && snapshot.valueLabels.isEmpty && snapshot.unlocatedLabels.isEmpty
    }

    private func validate(_ snapshot: InventorySnapshot) throws {
        guard snapshot.analysisReceipts.count <= Self.maximumSources, snapshot.sourceKinds.count <= Self.maximumSources,
              snapshot.sourceTimes.count <= Self.maximumSources, snapshot.conversationLabels.count <= 1 else {
            throw Failure.reportUnavailable
        }
        guard snapshot.analysisReceipts.allSatisfy({ $0.source.session == session }),
              snapshot.sourceKinds.keys.allSatisfy({ $0.session == session }),
              snapshot.sourceTimes.keys.allSatisfy({ $0.session == session }),
              snapshot.conversationLabels.keys.allSatisfy({ $0 == session }) else { throw Failure.foreignSource }
        guard snapshot.analysisReceipts.allSatisfy({ $0.detectorVersion == BetterleaksSecretDetector.version }),
              Set(snapshot.analysisReceipts.map(\.source)) == Set(snapshot.sourceKinds.keys),
              Set(snapshot.sourceKinds.keys) == Set(snapshot.sourceTimes.keys) else { throw Failure.receiptMismatch }
    }

    func report(snapshot: InventorySnapshot, payloadRows: Int,
                cryptography: BackgroundCryptography) async throws -> Report {
        guard initialized else { throw Failure.unsafeState }
        try validate(snapshot)
        let observed = Array(observations.values)
        let committed = observed.filter { snapshot.analysisReceipts.contains($0.receipt)
            && snapshot.sourceKinds[$0.receipt.source] == .toolOutput }
        return try await Report(initialStoreEmpty: initialStoreEmpty, initialReceiptDigests: initialReceiptDigests,
            initialSourceKindDigests: initialSourceKindDigests,
            receiptDigests: digests("receipt", Array(snapshot.analysisReceipts), cryptography),
            sourceKindDigests: digests("source-kind", snapshot.sourceKinds.map { Pair(key: $0.key, value: $0.value) }, cryptography),
            sourceTimeDigests: digests("source-time", snapshot.sourceTimes.map { Pair(key: $0.key, value: $0.value) }, cryptography),
            receiptCount: snapshot.analysisReceipts.count, sourceCount: snapshot.sourceKinds.count,
            sessionCount: Set(snapshot.sourceKinds.keys.map(\.session)).count,
            observedWebSourceCount: observed.count, committedWebSourceCount: committed.count,
            webSourceDigests: observed.map(\.sourceDigest).sorted(), webResultDigests: observed.map(\.resultDigest).sorted(),
            webReceiptDigests: digests("receipt", committed.map(\.receipt), cryptography),
            resultSegmentCount: observed.reduce(0) { $0 + $1.segmentCount },
            resultTextBytes: observed.reduce(0) { $0 + $1.textBytes }, resultPointerBytes: observed.reduce(0) { $0 + $1.pointerBytes },
            allObservedWebSourcesCommitted: failure == nil && !observed.isEmpty && committed.count == observed.count,
            cleanInventory: failure == nil && Self.hasNoFindings(snapshot) && payloadRows == 0,
            payloadRowCount: payloadRows, batchCount: batchCount, readerVersions: readerVersions.sorted(),
            producerVersions: Set(observed.map(\.producerVersion)).sorted())
    }

    private func digest<T: Encodable>(_ domain: String, _ value: T, _ crypto: BackgroundCryptography) async throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(value)
        guard encoded.count <= 64 * 1024 else { throw Failure.reportUnavailable }
        var bytes = Data(("web-result-state-v1/" + domain + "\n").utf8); bytes.append(encoded)
        return try await crypto.revision(canonicalBytes: bytes).keyedDigest.base64EncodedString()
    }

    private func digests<T: Encodable>(_ domain: String, _ values: [T], _ crypto: BackgroundCryptography) async throws -> [String] {
        guard values.count <= Self.maximumSources else { throw Failure.reportUnavailable }
        var result: [String] = []
        for value in values { result.append(try await digest(domain, value, crypto)) }
        return result.sorted()
    }
}
#endif
