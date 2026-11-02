import Foundation
import os

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
        let cancellation = ScannerCancellation()
        let worker = Task.detached(priority: .utility) {
            try ScannerWorker.scan(source, configuration: config, cancellation: cancellation)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            cancellation.cancel()
            worker.cancel()
        }
    }

    /// Mapping contracts use synthetic reports without weakening the production artifact checks.
    @_spi(Testing) public static func mapReportForTesting(
        _ report: Data, in source: SourceRecord, allowedRuleIDs: Set<String>
    ) throws -> DetectorOutput {
        try ScannerMapper.map(report, source: source, segment: source.segments[0], allowedRuleIDs: allowedRuleIDs)
    }
}

/// Cancellation that scanner launches on dispatch threads can see, where `Task.isCancelled` is always false.
final class ScannerCancellation: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { state.withLock { $0 } || Task.isCancelled }
    func cancel() { state.withLock { $0 = true } }
}

enum ScannerWorker {
    /// A tool result with hundreds of string fields outlasted the deadline one launch at a time.
    /// Most of a launch is process and sandbox start-up rather than CPU, so a few run at once. Each
    /// segment still gets its own launch, so a match can't depend on a neighbouring segment.
    static let concurrentLaunches = 4

    static func scan(
        _ source: SourceRecord, configuration: BetterleaksConfiguration, cancellation: ScannerCancellation
    ) throws -> DetectorOutput {
        var findings: [DetectorFinding] = []
        var unlocated: [UnlocatedDetection] = []
        var gaps: Set<CoverageGap> = []
        var failure: DetectorFailure?
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + configuration.deadlineSeconds
        var native: [DetectorOutput] = []
        for segment in source.segments {
            guard !cancellation.isCancelled else { throw DetectorFailure.cancelled }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            native.append(try NativeSecretRules.scan(segment, source: source, deadline: deadline))
        }
        let scanned = try launch(Array(source.segments.prefix(native.count)), source: source,
                                 configuration: configuration, deadline: deadline, cancellation: cancellation)
        var truncated = false
        for (native, mapped) in zip(native, scanned) {
            findings.append(contentsOf: native.findings)
            gaps.formUnion(native.coverageGaps)
            findings.append(contentsOf: mapped.findings)
            unlocated.append(contentsOf: mapped.unlocated)
            gaps.formUnion(mapped.coverageGaps)
            failure = failure ?? mapped.scannerFailure
            if findings.count > ScannerMapper.maximumFindings || unlocated.count > ScannerMapper.maximumFindings {
                findings = Array(findings.prefix(ScannerMapper.maximumFindings))
                unlocated = Array(unlocated.prefix(ScannerMapper.maximumFindings))
                failure = failure ?? .outputLimitExceeded
                gaps.insert(CoverageGap(reason: .budgetExhausted))
                truncated = true
                break
            }
        }
        if !truncated, native.count < source.segments.count {
            failure = failure ?? .timedOut
            gaps.insert(CoverageGap(reason: .budgetExhausted))
        }
        let merged = try ScannerMapper.merge(findings)
        return DetectorOutput(detectorVersion: BetterleaksSecretDetector.version, findings: merged,
                              unlocated: Array(Set(unlocated)), coverageGaps: Array(gaps), scannerFailure: failure)
    }

    /// One launch per segment, a few at a time, returned in segment order.
    private static func launch(
        _ segments: [SourceSegment], source: SourceRecord, configuration: BetterleaksConfiguration,
        deadline: TimeInterval, cancellation: ScannerCancellation
    ) throws -> [DetectorOutput] {
        guard !segments.isEmpty else { return [] }
        // Checked once per source: hashing the 23 MB scanner before every launch cost more than the launch.
        let rules: Result<Set<String>, DetectorFailure>
        do { rules = .success(try ScannerProcess.verifyArtifacts(configuration)) }
        catch let error as DetectorFailure { rules = .failure(error) }
        catch { rules = .failure(.invalidReport) }
        let results = OSAllocatedUnfairLock(initialState: [Result<DetectorOutput, any Error>?](repeating: nil, count: segments.count))
        let next = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: min(concurrentLaunches, segments.count)) { _ in
            while !cancellation.isCancelled, let index = next.withLock({ (value: inout Int) -> Int? in
                guard value < segments.count else { return nil }
                defer { value += 1 }
                return value
            }) {
                let result = Result {
                    try scan(segments[index], rules: rules, source: source, configuration: configuration,
                             deadline: deadline, cancellation: cancellation)
                }
                results.withLock { $0[index] = result }
            }
        }
        guard !cancellation.isCancelled else { throw DetectorFailure.cancelled }
        return try results.withLock { $0 }.map { try $0!.get() }
    }

    private static func scan(
        _ segment: SourceSegment, rules: Result<Set<String>, DetectorFailure>, source: SourceRecord,
        configuration: BetterleaksConfiguration, deadline: TimeInterval, cancellation: ScannerCancellation
    ) throws -> DetectorOutput {
        let failure: DetectorFailure
        do {
            let rules = try rules.get()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw DetectorFailure.timedOut }
            let report = try ScannerProcess.run(segment.utf8, configuration: configuration, timeout: remaining,
                                                isCancelled: { cancellation.isCancelled })
            guard !cancellation.isCancelled else { throw DetectorFailure.cancelled }
            return try ScannerMapper.map(report, source: source, segment: segment, allowedRuleIDs: rules, deadline: deadline)
        } catch let error as DetectorFailure {
            if error == .cancelled { throw error }
            failure = error
        } catch { failure = .invalidReport }
        return DetectorOutput(detectorVersion: BetterleaksSecretDetector.version, findings: [], unlocated: [],
                              coverageGaps: [CoverageGap(reason: [.timedOut, .outputLimitExceeded].contains(failure)
                                  ? .budgetExhausted : .scannerUnavailable)],
                              scannerFailure: failure)
    }
}
