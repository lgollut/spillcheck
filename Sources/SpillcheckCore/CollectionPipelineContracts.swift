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

public struct CollectionBatch: Sendable {
    public let sources: [CollectedSource]
    public let coverageGaps: [CoverageGap]
    /// Source progress becomes durable only after every returned record is handled.
    public let checkpoints: [SourceCheckpoint]
    /// Cursor-only continuation replaces this capture atomically after all returned sources commit.
    public let continuation: CapturePacket?
    public let historicalProgress: HistoricalReadProgress?

    public init(sources: [CollectedSource], coverageGaps: [CoverageGap] = [], checkpoints: [SourceCheckpoint] = [],
                continuation: CapturePacket? = nil, historicalProgress: HistoricalReadProgress? = nil) {
        self.sources = sources
        self.coverageGaps = coverageGaps
        self.checkpoints = checkpoints
        self.continuation = continuation
        self.historicalProgress = historicalProgress
    }

    public init(sources: [CollectedSource], coverageGaps: [CoverageGap] = [], checkpoint: SourceCheckpoint?,
                continuation: CapturePacket? = nil, historicalProgress: HistoricalReadProgress? = nil) {
        self.init(sources: sources, coverageGaps: coverageGaps, checkpoints: checkpoint.map { [$0] } ?? [],
                  continuation: continuation, historicalProgress: historicalProgress)
    }
}

public protocol CaptureNormalizer: Sendable {
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) async throws -> CollectionBatch
}

public typealias SourceCheckpointLookup = @Sendable (UUID) async throws -> SourceCheckpoint?
