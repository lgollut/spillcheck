import Foundation

public protocol SecretDetector: Sendable {
    func scan(_ source: SourceRecord) async throws -> DetectorOutput
}

/// Transient plaintext proof. The pipeline fingerprints and protects it before committing.
public struct DetectorFinding: Sendable {
    public let extraction: ExactExtraction
    public let evidence: Set<DetectionEvidence>

    public init(extraction: ExactExtraction, evidence: Set<DetectionEvidence>) throws {
        guard !evidence.isEmpty else { throw ContractError.missingEvidence }
        self.extraction = extraction
        self.evidence = evidence
    }
}

public enum DetectorFailure: Error, Equatable, Sendable {
    case unavailable, invalidArtifacts, networkIsolationUnavailable
    case executionFailed(code: Int32), timedOut, outputLimitExceeded, invalidReport
    case inputLimitExceeded, invalidSource, busy, cancelled
}

public struct DetectorOutput: Sendable {
    public let detectorVersion: String
    public let findings: [DetectorFinding]
    public let unlocated: [UnlocatedDetection]
    public let coverageGaps: [CoverageGap]
    public let scannerFailure: DetectorFailure?

    public init(detectorVersion: String, findings: [DetectorFinding], unlocated: [UnlocatedDetection],
                coverageGaps: [CoverageGap] = [], scannerFailure: DetectorFailure? = nil) {
        self.detectorVersion = detectorVersion
        self.findings = findings
        self.unlocated = unlocated
        self.coverageGaps = coverageGaps
        self.scannerFailure = scannerFailure
    }
}

public struct BetterleaksConfiguration: Sendable {
    public static let pinnedVersion = "1.9.0"
    public static let pinnedExecutableSHA256 = "70d2103c2915aababa0e1eea121bd3db0ff0da86bee40ddc6f5982181acaf6d0"
    public static let pinnedConfigurationSHA256 = "a8f553eb634ac3c5c1ca3f0dc95e2b8abdea7d14b622604c5af07f30ce7926ef"
    public let executableURL: URL
    public let configurationURL: URL
    public let workingDirectoryURL: URL
    /// May be the hash of the same verified pinned artifact after app-controlled code signing.
    public let expectedExecutableSHA256: String
    public let deadlineSeconds: TimeInterval
    public let maximumReportBytes: Int

    public init(
        executableURL: URL, configurationURL: URL, workingDirectoryURL: URL,
        expectedExecutableSHA256: String = Self.pinnedExecutableSHA256,
        deadlineSeconds: TimeInterval = 30, maximumReportBytes: Int = 8 * 1024 * 1024
    ) {
        self.executableURL = executableURL
        self.configurationURL = configurationURL
        self.workingDirectoryURL = workingDirectoryURL
        self.expectedExecutableSHA256 = expectedExecutableSHA256
        self.deadlineSeconds = min(30, max(0.05, deadlineSeconds.isFinite ? deadlineSeconds : 30))
        self.maximumReportBytes = min(8 * 1024 * 1024, max(1, maximumReportBytes))
    }
}

/// One invocation at a time. The blocking pipe pump runs outside the app's main actor.
public actor BetterleaksSecretDetector: SecretDetector {
    public static let version = "betterleaks-1.9.0+stdlib-1+leakret-native-1+mapping-1"
    public static let maximumInputBytes = 8 * 1024 * 1024
    private let configuration: BetterleaksConfiguration
    private var scanning = false

    public init(configuration: BetterleaksConfiguration) { self.configuration = configuration }

    public func scan(_ source: SourceRecord) async throws -> DetectorOutput {
        guard !scanning else { throw DetectorFailure.busy }
        guard !Task.isCancelled else { throw DetectorFailure.cancelled }
        var total = 0
        for segment in source.segments {
            guard segment.utf8.count <= Self.maximumInputBytes - total,
                  String(data: segment.utf8, encoding: .utf8) != nil else {
                throw segment.utf8.count > Self.maximumInputBytes - total
                    ? DetectorFailure.inputLimitExceeded : DetectorFailure.invalidSource
            }
            total += segment.utf8.count
        }
        scanning = true
        defer { scanning = false }
        let config = configuration
        let worker = Task.detached(priority: .utility) {
            try ScannerWorker.scan(source, configuration: config)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    /// Mapping contracts use synthetic reports without weakening the production artifact checks.
    @_spi(Testing) public static func mapReportForTesting(
        _ report: Data, in source: SourceRecord, allowedRuleIDs: Set<String>
    ) throws -> DetectorOutput {
        try ScannerMapper.map(report, source: source, segment: source.segments[0], allowedRuleIDs: allowedRuleIDs)
    }
}

enum ScannerWorker {
    static func scan(_ source: SourceRecord, configuration: BetterleaksConfiguration) throws -> DetectorOutput {
        var findings: [DetectorFinding] = []
        var unlocated: [UnlocatedDetection] = []
        var gaps: Set<CoverageGap> = []
        var failure: DetectorFailure?
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + configuration.deadlineSeconds
        for segment in source.segments {
            guard !Task.isCancelled else { throw DetectorFailure.cancelled }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                failure = failure ?? .timedOut
                gaps.insert(CoverageGap(reason: .budgetExhausted))
                break
            }
            let native = try NativeSecretRules.scan(segment, source: source, deadline: deadline)
            findings.append(contentsOf: native.findings)
            gaps.formUnion(native.coverageGaps)
            do {
                let rules = try ScannerProcess.verifyArtifacts(configuration)
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw DetectorFailure.timedOut }
                let report = try ScannerProcess.run(segment.utf8, configuration: configuration, timeout: remaining)
                let mapped = try ScannerMapper.map(report, source: source, segment: segment,
                                                   allowedRuleIDs: rules, deadline: deadline)
                findings.append(contentsOf: mapped.findings)
                unlocated.append(contentsOf: mapped.unlocated)
                gaps.formUnion(mapped.coverageGaps)
            } catch let error as DetectorFailure {
                if error == .cancelled { throw error }
                failure = failure ?? error
                gaps.insert(CoverageGap(reason: [.timedOut, .outputLimitExceeded].contains(error) ? .budgetExhausted : .scannerUnavailable))
            } catch {
                failure = failure ?? .invalidReport
                gaps.insert(CoverageGap(reason: .scannerUnavailable))
            }
            if findings.count > ScannerMapper.maximumFindings || unlocated.count > ScannerMapper.maximumFindings {
                findings = Array(findings.prefix(ScannerMapper.maximumFindings))
                unlocated = Array(unlocated.prefix(ScannerMapper.maximumFindings))
                failure = failure ?? .outputLimitExceeded
                gaps.insert(CoverageGap(reason: .budgetExhausted))
                break
            }
        }
        let merged = try ScannerMapper.merge(findings)
        return DetectorOutput(detectorVersion: BetterleaksSecretDetector.version, findings: merged,
                              unlocated: Array(Set(unlocated)), coverageGaps: Array(gaps), scannerFailure: failure)
    }
}
