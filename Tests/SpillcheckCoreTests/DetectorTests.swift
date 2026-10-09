import CryptoKit
import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private struct ScannerCorpus: Decodable {
    let cases: [ScannerCase]
}
private struct ScannerCase: Decodable {
    let id: String
    let chunks: [ScannerChunk]
    let expected: [ScannerExpected]
    var text: String { chunks.map { String(repeating: $0.text, count: $0.repeatCount) }.joined() }
}
private struct ScannerChunk: Decodable {
    let text: String
    let repeatCount: Int
    enum CodingKeys: String, CodingKey { case text, repeatCount = "repeat" }
}
private struct ScannerExpected: Decodable {
    let start: Int
    let end: Int
    let signal: String
    let decodedValue: String?
}

private struct DetectorFixture {
    let root: URL
    let work: URL
    let configuration: BetterleaksConfiguration
    init(timeout: TimeInterval = 30, maximumReportBytes: Int = 8 * 1024 * 1024) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-detector-tests-\(UUID().uuidString)")
        work = root.appendingPathComponent("worker")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        configuration = BetterleaksConfiguration(executableURL: repo.appendingPathComponent(".build/scanner/betterleaks"),
                                                configurationURL: repo.appendingPathComponent(".build/scanner/betterleaks.toml"),
                                                workingDirectoryURL: work, deadlineSeconds: timeout,
                                                maximumReportBytes: maximumReportBytes)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func syntheticReport(
    match: String, secret: String, rule: String = "generic-password", start: Int = 1,
    end: Int? = nil, confidence: String? = "low"
) throws -> Data {
    var object: [String: Any] = ["RuleID": rule, "Match": match, "Secret": secret,
                               "StartLine": 1, "EndLine": 1, "StartColumn": start,
                               "EndColumn": end ?? match.utf8.count]
    if let confidence { object["Attributes"] = ["confidence": confidence] }
    return try JSONSerialization.data(withJSONObject: [object])
}

private func mapped(_ report: Data, text: String, allowed: Set<String> = ["generic-password", "github-pat", "generic-credential-uri", "generic-api-key", "private-key"]) throws -> DetectorOutput {
    try BetterleaksSecretDetector.mapReportForTesting(report, in: sourceRecord(text: text), allowedRuleIDs: allowed)
}

private func ranges(_ output: DetectorOutput) -> [Range<Int>] {
    output.findings.map {
        let range = $0.extraction.location.components[0].range
        return range.lowerBound..<range.upperBound
    }
}

private func inspectScannerCache(at directory: URL) throws {
    let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    let marker = Data("ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS".utf8)
    for case let file as URL in files {
        if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            #expect(try Data(contentsOf: file).range(of: marker) == nil)
        }
    }
}

@Suite("Pinned local scanner and source-verified mapping")
struct DetectorTests {
    @Test func completeAnnotatedCorpusRunsThroughProductionNetworkDeniedProcess() async throws {
        let fixture = try DetectorFixture()
        defer { fixture.remove() }
        _ = try ScannerProcess.verifyArtifacts(fixture.configuration)
        try FileManager.default.createDirectory(at: fixture.work, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        for name in [".betterleaks.toml", ".gitleaks.toml"] {
            try Data("invalid auto-discovery configuration: ignore detections".utf8)
                .write(to: fixture.work.appendingPathComponent(name))
        }
        let url = try #require(Bundle.module.url(forResource: "corpus", withExtension: "json", subdirectory: "Fixtures/Scanner"))
        let corpus = try JSONDecoder().decode(ScannerCorpus.self, from: Data(contentsOf: url))
        #expect(corpus.cases.count == 47)
        let detector = BetterleaksSecretDetector(configuration: fixture.configuration)
        var expectedCount = 0
        for item in corpus.cases {
            let source = try sourceRecord(item: item.id, text: item.text)
            let result = try await detector.scan(source)
            #expect(result.scannerFailure == nil, Comment(rawValue: item.id))
            #expect(result.coverageGaps.isEmpty, Comment(rawValue: item.id))
            #expect(result.unlocated.isEmpty, Comment(rawValue: item.id))
            #expect(ranges(result) == item.expected.map { $0.start..<$0.end }, Comment(rawValue: item.id))
            expectedCount += item.expected.count
            for expected in item.expected {
                let finding = try #require(result.findings.first {
                    $0.extraction.location.components[0].range.lowerBound == expected.start
                        && $0.extraction.location.components[0].range.upperBound == expected.end
                }, Comment(rawValue: item.id))
                let value = expected.decodedValue.map { Data($0.utf8) }
                    ?? source.segments[0].utf8.subdata(in: expected.start..<expected.end)
                #expect(finding.extraction.valueUTF8 == value, Comment(rawValue: item.id))
                try finding.extraction.validate(in: source)
                if expected.signal == "strong" { #expect(finding.evidence.contains { $0.signal == .strong }) }
            }
        }
        #expect(expectedCount == 36)
        // No input/report files are produced; the scanner's compiled rule cache is allowed.
        try inspectScannerCache(at: fixture.work)
    }

    @Test func contextualEvidenceNeverFollowsASecretOnlyDuplicate() throws {
        let report = try syntheticReport(match: "password = \"tulips\"", secret: "tulips")
        let output = try mapped(report, text: "password = \"tulips\"\nThe bouquet label reads tulips.\n")
        #expect(ranges(output) == [12..<18])
        #expect(output.unlocated.isEmpty)
        let repeated = try mapped(report, text: "password = \"tulips\"\npassword = \"tulips\"\n")
        #expect(ranges(repeated) == [12..<18, 32..<38])
    }

    @Test func fabricatedContextAndValueRemainUnlocated() throws {
        let absentContext = try mapped(syntheticReport(match: "password = \"tulips\"", secret: "tulips"),
                                       text: "The bouquet label reads tulips.")
        #expect(absentContext.findings.isEmpty)
        #expect(absentContext.unlocated.first?.reason == .scannerReportMismatch)
        let invented = try mapped(syntheticReport(match: "password = \"tulips\"", secret: "invented"),
                                  text: "password = \"tulips\"")
        #expect(invented.findings.isEmpty)
        #expect(!invented.unlocated.isEmpty)
    }

    @Test func unicodeByteCoordinatesAndChunkResetRecoverIdenticalFullContexts() throws {
        let prefix = "Résumé 🔐 e\u{301} "
        let output = try mapped(syntheticReport(match: "abc123xyz", secret: "abc123xyz", rule: "github-pat", end: 9),
                                text: prefix + "abc123xyz and abc123xyz")
        let start = prefix.utf8.count
        #expect(ranges(output) == [start..<(start + 9), (start + 14)..<(start + 23)])
        #expect(output.findings.allSatisfy { $0.extraction.valueUTF8 == Data("abc123xyz".utf8) })
    }

    @Test func malformedAndUnknownRulesNeverInventARevealableValue() throws {
        for report in [try syntheticReport(match: "", secret: ""),
                       try syntheticReport(match: "abcdef", secret: "abcdef", start: 0),
                       try JSONSerialization.data(withJSONObject: [["Secret": "value"]]),
                       try syntheticReport(match: "value:value", secret: "value", rule: "unknown-rule", confidence: "high")] {
            let output = try mapped(report, text: "abcdef value:value")
            #expect(output.findings.isEmpty)
            #expect(!output.unlocated.isEmpty)
            #expect(output.unlocated.allSatisfy { $0.evidence.allSatisfy { $0.signal == .ambiguous } })
        }
        #expect(throws: DetectorFailure.invalidReport) { try mapped(Data("{bad-json}".utf8), text: "synthetic") }
        let ambiguous = try mapped(syntheticReport(match: "value:value", secret: "value", rule: "generic-api-key"), text: "value:value")
        #expect(ambiguous.findings.isEmpty)
        #expect(ambiguous.unlocated.first?.reason == .ambiguousRange)
    }

    @Test func declaredPasswordFieldsExcludeEqualKeywordsAndUsernames() throws {
        let keyword = try mapped(syntheticReport(match: "password = \"password\"", secret: "password"), text: "password = \"password\"")
        #expect(ranges(keyword) == [12..<20])
        let uri = "postgresql://rV8nQ4zF7pD2:rV8nQ4zF7pD2@db.internal/app"
        let password = try mapped(syntheticReport(match: uri, secret: "rV8nQ4zF7pD2", rule: "generic-credential-uri"), text: uri)
        #expect(ranges(password) == [26..<38])
    }

    @Test func URITransformationIsScopedCheckedAndPreservesPlus() throws {
        let uri = "https://user:a+b%40c@host"
        let output = try mapped(syntheticReport(match: uri, secret: "a+b%40c", rule: "generic-credential-uri"), text: uri)
        #expect(output.findings.first?.extraction.valueUTF8 == Data("a+b@c".utf8))
        #expect(ranges(output) == [13..<20])
        for secret in ["a%Q4", "a%FF"] {
            let uri = "https://user:\(secret)@host"
            let output = try mapped(syntheticReport(match: uri, secret: secret, rule: "generic-credential-uri"), text: uri)
            #expect(output.findings.isEmpty)
            #expect(output.unlocated.first?.reason == .invalidEncoding)
        }
        let unchanged = try mapped(syntheticReport(match: "a+b%40c", secret: "a+b%40c", rule: "generic-api-key"), text: "a+b%40c")
        #expect(unchanged.findings.first?.extraction.valueUTF8 == Data("a+b%40c".utf8))
    }

    @Test func sameRangeMergesEvidenceAndConfidenceRemainsControlled() throws {
        let one = try syntheticReport(match: "synthetic-token", secret: "synthetic-token", rule: "github-pat", confidence: "high")
        let two = try syntheticReport(match: "synthetic-token", secret: "synthetic-token", rule: "generic-api-key", confidence: "low")
        let data = try JSONSerialization.data(withJSONObject:
            (JSONSerialization.jsonObject(with: one) as! [Any]) + (JSONSerialization.jsonObject(with: two) as! [Any]))
        let merged = try mapped(data, text: "synthetic-token")
        #expect(merged.findings.count == 1)
        #expect(merged.findings[0].evidence.count == 2)
        #expect(merged.findings[0].evidence.contains { $0.signal == .strong })
        for confidence in [nil, "custom", "medium", "low"] {
            let output = try mapped(syntheticReport(match: "synthetic-token", secret: "synthetic-token", rule: "github-pat", confidence: confidence), text: "synthetic-token")
            #expect(output.findings[0].evidence.allSatisfy { $0.signal == .ambiguous })
        }
    }

    @Test func mergedURIFieldKeepsCheckedDecodedValueAndBothRules() throws {
        let uri = "https://user:a+b%40c@host"
        let one = try syntheticReport(match: uri, secret: "a+b%40c", rule: "generic-credential-uri")
        let two = try syntheticReport(match: "a+b%40c", secret: "a+b%40c", rule: "generic-api-key")
        let data = try JSONSerialization.data(withJSONObject:
            (JSONSerialization.jsonObject(with: one) as! [Any]) + (JSONSerialization.jsonObject(with: two) as! [Any]))
        let merged = try mapped(data, text: uri)
        #expect(merged.findings.count == 1)
        #expect(merged.findings[0].evidence.count == 2)
        #expect(merged.findings[0].extraction.valueUTF8 == Data("a+b@c".utf8))
        try merged.findings[0].extraction.validate(in: sourceRecord(text: uri))
    }

    @Test func AWSIdentifierIsExcludedAndOnlyMeasuredConfidentialComponentIsMapped() throws {
        let accessID = "AKIA7D4N5Q2P6R3T2V5X"
        let missing = try syntheticReport(match: accessID, secret: accessID, rule: "aws-access-token")
        let emptySets = try JSONSerialization.data(withJSONObject: [["RuleID": "aws-access-token", "ComponentSets": []]])
        let emptyComponents = try JSONSerialization.data(withJSONObject: [["RuleID": "aws-access-token", "ComponentSets": [["components": []]]]])
        for malformed in [missing, emptySets, emptyComponents] {
            let empty = try mapped(malformed, text: accessID, allowed: ["aws-access-token", "aws-secret-access-key"])
            #expect(empty.findings.isEmpty)
            #expect(empty.unlocated.first?.reason == .scannerReportMismatch)
            #expect(empty.coverageGaps.contains { $0.reason == .unsupportedContent })
        }
        let secret = "SYNTHETIC-rV8nQ4zF7pD2"
        let component: [String: Any] = ["RuleID": "aws-secret-access-key", "Match": secret, "Secret": secret,
                                      "StartLine": 1, "EndLine": 1, "StartColumn": 1, "EndColumn": secret.utf8.count]
        let report = try JSONSerialization.data(withJSONObject: [["RuleID": "aws-access-token", "Attributes": ["confidence": "high"],
            "ComponentSets": [["components": [component]], ["components": [component]]]]])
        let output = try mapped(report, text: secret, allowed: ["aws-access-token", "aws-secret-access-key"])
        #expect(output.findings.count == 1)
        #expect(output.findings[0].evidence.first?.signal == .strong)
        let unsupported = try JSONSerialization.data(withJSONObject: [["RuleID": "polymarket-api-key", "Attributes": ["confidence": "high"],
            "ComponentSets": [["components": [component]]]]])
        let partial = try mapped(unsupported, text: secret, allowed: ["polymarket-api-key", "aws-secret-access-key"])
        #expect(partial.findings.isEmpty)
        #expect(partial.unlocated.first?.reason == .ambiguousRange)
    }

    @Test func missingScannerUsesOnlyMeasuredRulesAndExplicitReducedCoverage() async throws {
        let fixture = try DetectorFixture()
        defer { fixture.remove() }
        let config = BetterleaksConfiguration(executableURL: fixture.root.appendingPathComponent("missing"),
                                              configurationURL: fixture.configuration.configurationURL, workingDirectoryURL: fixture.work)
        let detector = BetterleaksSecretDetector(configuration: config)
        let result = try await detector.scan(sourceRecord(text: "Authorization: Bearer rV8nQ4zF7pD2sL9xK3mB6cH1jE5uW0tY4aR8vN\nThe database password is `vR7!kQ2#sM9@pL4`.\n"))
        #expect(result.findings.count == 2)
        #expect(result.findings.allSatisfy { $0.evidence.allSatisfy { $0.signal == .ambiguous } })
        #expect(result.scannerFailure == .unavailable)
        #expect(result.coverageGaps.contains { $0.reason == .scannerUnavailable })
    }

    @Test func completePEMNeedsMatchingFooterAndPreservesLargeBlock() throws {
        let block = "-----BEGIN RSA PRIVATE KEY-----\n" + String(repeating: String(repeating: "M", count: 63) + "Q\n", count: 2_048) + "-----END RSA PRIVATE KEY-----"
        let source = try sourceRecord(text: "unicode 🔐\n" + block + "\n")
        let result = try NativeSecretRules.scan(source.segments[0], source: source, deadline: ProcessInfo.processInfo.systemUptime + 30)
        #expect(result.findings.count == 1)
        #expect(result.findings[0].extraction.valueUTF8 == Data(block.utf8))
        #expect(result.findings[0].evidence.first?.signal == .strong)
        let malformed = try sourceRecord(text: block.replacingOccurrences(of: "END RSA", with: "END EC"))
        let rejected = try NativeSecretRules.scan(malformed.segments[0], source: malformed, deadline: ProcessInfo.processInfo.systemUptime + 30)
        #expect(rejected.findings.isEmpty)
    }

    @Test func productionScannerMismatchedPEMStaysAmbiguousAndVisiblyUnsupported() async throws {
        let fixture = try DetectorFixture()
        defer { fixture.remove() }
        let block = "-----BEGIN RSA PRIVATE KEY-----\n" + String(repeating: "M", count: 65)
            + "\n-----END EC PRIVATE KEY-----"
        let result = try await BetterleaksSecretDetector(configuration: fixture.configuration).scan(sourceRecord(text: block))
        #expect(result.scannerFailure == nil)
        #expect(result.findings.count == 1)
        #expect(result.findings.first?.extraction.valueUTF8 == Data(block.utf8))
        #expect(result.findings.allSatisfy { $0.evidence.allSatisfy { $0.signal == .ambiguous && $0.reason != .privateKeyBlock } })
        #expect(result.coverageGaps.contains { $0.reason == .unsupportedContent })
    }

    @Test func scannerEnvironmentArgumentsAndArtifactsAreControlled() throws {
        let fixture = try DetectorFixture()
        defer { fixture.remove() }
        #expect(Set(ScannerProcess.safeEnvironment(directory: fixture.work).keys) == ["PATH", "HOME", "TMPDIR", "LC_ALL", "LANG"])
        let args = ScannerProcess.arguments(configuration: fixture.configuration, ignoreURL: fixture.work.appendingPathComponent("empty-ignore"))
        for flag in ["--validation=false", "--confidence=low", "--ignore-gitleaks-allow", "--max-decode-depth=0", "--max-archive-depth=0", "--report-path=-"] { #expect(args.contains(flag)) }
        let tampered = fixture.root.appendingPathComponent("modified-config.toml")
        try Data("disable-detection".utf8).write(to: tampered)
        let config = BetterleaksConfiguration(executableURL: fixture.configuration.executableURL, configurationURL: tampered, workingDirectoryURL: fixture.work)
        #expect(throws: DetectorFailure.invalidArtifacts) { try ScannerProcess.verifyArtifacts(config) }
    }

    @Test func sandboxActuallyDeniesListeningConnectingAndForking() throws {
        let fixture = try DetectorFixture()
        defer { fixture.remove() }
        // /usr/bin/python3 is a developer-tool launcher and itself spawns a process.
        // Invoke the actual interpreter when proving the scanner's no-descendant policy.
        let python = ProcessInfo.processInfo.environment["SPILLCHECK_TEST_PYTHON"]
            ?? "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"
        for expression in ["s.bind(('127.0.0.1',0))", "s.connect(('127.0.0.1',9))", "os.fork()"] {
            let code = "import socket,os,sys\ns=socket.socket()\ntry:\n \(expression)\nexcept OSError as e:\n sys.exit(0 if e.errno==1 else 2)\nsys.exit(3)"
            let output = try ScannerProcess.runBounded(Data(), executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                arguments: ["-p", ScannerProcess.sandboxProfile, python, "-B", "-c", code],
                directory: fixture.root, timeout: 5, maximumOutputBytes: 1)
            #expect(output.isEmpty)
        }
    }

    @Test func boundedPipesTerminateHangingInputAndExcessiveOutput() throws {
        let fixture = try DetectorFixture()
        defer { fixture.remove() }
        let started = ProcessInfo.processInfo.systemUptime
        #expect(throws: DetectorFailure.timedOut) {
            try ScannerProcess.runBounded(Data(repeating: 88, count: 8 * 1024 * 1024),
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], directory: fixture.root,
                timeout: 0.1, maximumOutputBytes: 1)
        }
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
        #expect(throws: DetectorFailure.outputLimitExceeded) {
            try ScannerProcess.runBounded(Data(), executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-B", "-c", "import sys;sys.stdout.buffer.write(b'X'*65536)"], directory: fixture.root,
                timeout: 5, maximumOutputBytes: 1_024)
        }
        #expect(throws: DetectorFailure.outputLimitExceeded) {
            try ScannerProcess.runBounded(Data(), executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-B", "-c", "import sys;sys.stderr.buffer.write(b'X'*131072)"], directory: fixture.root,
                timeout: 5, maximumOutputBytes: 1_024)
        }
    }

    @Test func canceledScannerProcessIsTerminatedPromptly() async throws {
        let fixture = try DetectorFixture()
        defer { fixture.remove() }
        let started = ProcessInfo.processInfo.systemUptime
        let worker = Task.detached {
            try ScannerProcess.runBounded(Data(repeating: 88, count: 8 * 1024 * 1024),
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], directory: fixture.root,
                timeout: 30, maximumOutputBytes: 1)
        }
        try await Task.sleep(for: .milliseconds(50))
        worker.cancel()
        await #expect(throws: DetectorFailure.cancelled) { try await worker.value }
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
    }

    @Test func excessiveReportRemainsPartialWithNativeEvidence() async throws {
        let fixture = try DetectorFixture(maximumReportBytes: 1)
        defer { fixture.remove() }
        let detector = BetterleaksSecretDetector(configuration: fixture.configuration)
        let output = try await detector.scan(sourceRecord(text: "Authorization: Bearer rV8nQ4zF7pD2sL9xK3mB6cH1jE5uW0tY4aR8vN\n"))
        #expect(output.scannerFailure == .outputLimitExceeded)
        #expect(output.findings.count == 1)
        #expect(output.coverageGaps.contains { $0.reason == .budgetExhausted })
        #expect(output.findings[0].evidence.allSatisfy { $0.signal == .ambiguous })
    }

    @Test func inputLimitAppliesToSingleAndAggregateCanonicalSegments() async throws {
        let fixture = try DetectorFixture()
        defer { fixture.remove() }
        let source = try sourceRecord(text: String(repeating: "x", count: 8 * 1024 * 1024 + 1))
        let detector = BetterleaksSecretDetector(configuration: fixture.configuration)
        await #expect(throws: DetectorFailure.inputLimitExceeded) { try await detector.scan(source) }
        let metadata = try sourceRecord(text: "fixture")
        let aggregate = try SourceRecord(metadata: metadata.metadata, revision: metadata.revision,
            segments: [SourceSegment(id: "a", utf8: Data(repeating: 88, count: 4 * 1024 * 1024 + 1)),
                       SourceSegment(id: "b", utf8: Data(repeating: 88, count: 4 * 1024 * 1024 + 1))])
        await #expect(throws: DetectorFailure.inputLimitExceeded) { try await detector.scan(aggregate) }
    }
}
