import Foundation

/// Raw source details are transient until protected with the inventory revelation key.
public struct RetainedSourceContext: Codable, Sendable, Equatable {
    public let sessionIdentifier: String
    public let title: String?
    public let projectPath: String?
    public let transcriptPath: String?
    public let openingCapability: SourceOpeningCapability

    public init(sessionIdentifier: String, title: String? = nil, projectPath: String? = nil,
                transcriptPath: String? = nil, openingCapability: SourceOpeningCapability = .unverified) {
        self.sessionIdentifier = sessionIdentifier
        self.title = title
        self.projectPath = projectPath
        self.transcriptPath = transcriptPath
        self.openingCapability = openingCapability
    }
}

public struct CollectedSource: Sendable {
    public let record: SourceRecord
    public let context: RetainedSourceContext?

    public init(record: SourceRecord, context: RetainedSourceContext? = nil) {
        self.record = record
        self.context = context
    }
}

/// A freshly inspected presentation duplicates this exact original. The normalizer must
/// return the fully parsed original in the same batch; the pipeline separately requires
/// its current full analysis receipt before settling the presentation's provisional gap.
/// This carries no original text and never grants permission to read another source.
public struct CoverageRecoveryDependency: Sendable {
    public let provisionalGap: CoverageGap
    public let originalMetadata: SourceRecordMetadata
    public let originalRevision: ContentRevision

    public init(provisionalGap: CoverageGap, originalMetadata: SourceRecordMetadata,
                originalRevision: ContentRevision) {
        self.provisionalGap = provisionalGap
        self.originalMetadata = originalMetadata
        self.originalRevision = originalRevision
    }
}

public struct CollectionBatch: Sendable {
    /// A capture must fit both pipeline validation and its atomic coverage settlement.
    static let maximumRecoveryEntries = 4096

    public let sources: [CollectedSource]
    public let coverageGaps: [CoverageGap]
    /// Source progress becomes durable only after every returned record is handled.
    public let checkpoints: [SourceCheckpoint]
    /// Cursor-only continuation replaces this capture atomically after all returned sources commit.
    /// With pending recovery dependencies this is the success branch and requires an explicit
    /// unresolvedRecoveryContinuation that preserves the caller's incomplete-read state.
    public let continuation: CapturePacket?
    /// Selected if any pending recovery lacks a full receipt for its freshly returned original.
    /// Both branches must retain this capture's metadata. Nil for ordinary or terminal batches.
    public let unresolvedRecoveryContinuation: CapturePacket?
    public let historicalProgress: HistoricalReadProgress?
    /// Only complete successful reparses of the referenced item/record belong here.
    public let recoveredReferences: [CoverageRecoveryReference]
    /// Conditional presentation recoveries. These are not ordinary successful reparses.
    public let pendingRecoveryDependencies: [CoverageRecoveryDependency]
    /// The reader completed a bounded read of the selected source, including a valid empty
    /// result. A default empty batch or a stat-only check conveys no such evidence.
    public let observedRead: Bool
    /// A single measured reader version across the successful RPCs in this batch.
    /// Missing or mixed response evidence remains unknown.
    public let observedReaderVersion: String?
    /// Authority-only skips advance an audit cursor without proving a source read.
    public let readEvidenceEligible: Bool

    public init(sources: [CollectedSource], coverageGaps: [CoverageGap] = [], checkpoints: [SourceCheckpoint] = [],
                continuation: CapturePacket? = nil, unresolvedRecoveryContinuation: CapturePacket? = nil,
                historicalProgress: HistoricalReadProgress? = nil,
                recoveredReferences: [CoverageRecoveryReference] = [],
                pendingRecoveryDependencies: [CoverageRecoveryDependency] = [], observedRead: Bool = false,
                readEvidenceEligible: Bool = true, observedReaderVersion: String? = nil) {
        self.sources = sources
        self.coverageGaps = coverageGaps
        self.checkpoints = checkpoints
        self.continuation = continuation
        self.unresolvedRecoveryContinuation = unresolvedRecoveryContinuation
        self.historicalProgress = historicalProgress
        self.recoveredReferences = recoveredReferences
        self.pendingRecoveryDependencies = pendingRecoveryDependencies
        self.observedRead = observedRead
        self.observedReaderVersion = observedReaderVersion
        self.readEvidenceEligible = readEvidenceEligible
    }

    public init(sources: [CollectedSource], coverageGaps: [CoverageGap] = [], checkpoint: SourceCheckpoint?,
                continuation: CapturePacket? = nil, unresolvedRecoveryContinuation: CapturePacket? = nil,
                historicalProgress: HistoricalReadProgress? = nil,
                recoveredReferences: [CoverageRecoveryReference] = [],
                pendingRecoveryDependencies: [CoverageRecoveryDependency] = [], observedRead: Bool = false,
                readEvidenceEligible: Bool = true, observedReaderVersion: String? = nil) {
        self.init(sources: sources, coverageGaps: coverageGaps, checkpoints: checkpoint.map { [$0] } ?? [],
                  continuation: continuation, unresolvedRecoveryContinuation: unresolvedRecoveryContinuation,
                  historicalProgress: historicalProgress,
                  recoveredReferences: recoveredReferences, pendingRecoveryDependencies: pendingRecoveryDependencies,
                  observedRead: observedRead,
                  readEvidenceEligible: readEvidenceEligible, observedReaderVersion: observedReaderVersion)
    }
}

public protocol CaptureNormalizer: Sendable {
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) async throws -> CollectionBatch
    func normalize(_ packet: CapturePacket, capturedAt: Date, context: CollectionWorkContext?,
                   cryptography: BackgroundCryptography) async throws -> CollectionBatch
}

extension CaptureNormalizer {
    public func normalize(_ packet: CapturePacket, capturedAt: Date, context: CollectionWorkContext?,
                          cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        try await normalize(packet, capturedAt: capturedAt, cryptography: cryptography)
    }
}

public typealias SourceCheckpointLookup = @Sendable (UUID) async throws -> SourceCheckpoint?
