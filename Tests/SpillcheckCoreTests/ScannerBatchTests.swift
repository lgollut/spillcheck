import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private func corpusCases() throws -> [ScannerCase] {
    let url = try #require(Bundle.module.url(forResource: "corpus", withExtension: "json", subdirectory: "Fixtures/Scanner"))
    return try JSONDecoder().decode(ScannerCorpus.self, from: Data(contentsOf: url)).cases
}

private func corpusText(_ id: String) throws -> String {
    try #require(try corpusCases().first { $0.id == id }).text
}

private func fieldsSource(_ fields: [(String, String)]) throws -> SourceRecord {
    let metadata = try sourceRecord(text: "fixture")
    return try SourceRecord(metadata: metadata.metadata, revision: metadata.revision,
                            segments: fields.map { try SourceSegment(id: $0.0, utf8: Data($0.1.utf8)) })
}

/// A structured tool result: one string field per segment.
private func toolResultFields(_ count: Int) -> [(String, String)] {
    (0..<count).map { ("/result/items/\($0)/status", "item \($0) is ready in eu-west-1, updated 2026-10-30T12:00:00Z") }
}

private struct Seen: Hashable {
    let location: CanonicalLocation
    let value: Data
    let evidence: Set<DetectionEvidence>
}

private func seen(_ output: DetectorOutput) -> Set<Seen> {
    Set(output.findings.map { Seen(location: $0.extraction.location, value: $0.extraction.valueUTF8, evidence: $0.evidence) })
}

/// What the scanner reports for each field scanned as its own source.
private func scannedAlone(_ fields: [(String, String)], with detector: BetterleaksSecretDetector)
    async throws -> (seen: Set<Seen>, gaps: Set<CoverageGap>, unlocated: Set<UnlocatedDetection>) {
    var result = (seen: Set<Seen>(), gaps: Set<CoverageGap>(), unlocated: Set<UnlocatedDetection>())
    for field in fields {
        let output = try await detector.scan(fieldsSource([field]))
        #expect(output.scannerFailure == nil, Comment(rawValue: field.0))
        result.seen.formUnion(seen(output))
        result.gaps.formUnion(output.coverageGaps)
        result.unlocated.formUnion(output.unlocated)
    }
    return result
}

@Suite("Scanning sources with many fields")
struct ScannerBatchTests {
    @Test func aToolResultWithHundredsOfFieldsIsScannedWithinTheDeadline() async throws {
        // A launch took 140 to 200 ms, so 300 of them one after another outlast the 30 s deadline.
        let fixture = try DetectorFixture()
        defer { fixture.remove() }
        var fields = toolResultFields(300)
        fields[0].1 = try corpusText("github-error")
        fields[100].1 = try corpusText("uri-postgres")
        fields[299].1 = try corpusText("pem-multiline")
        let detector = BetterleaksSecretDetector(configuration: fixture.configuration)
        let output = try await detector.scan(fieldsSource(fields))
        #expect(output.scannerFailure == nil)
        #expect(output.coverageGaps.isEmpty)
        let alone = try await scannedAlone([fields[0], fields[1], fields[100], fields[299]], with: detector)
        #expect(alone.seen.count == 3)
        #expect(seen(output) == alone.seen)
    }

    @Test(arguments: [false, true])
    func aSourceReportsExactlyWhatItsFieldsReportAlone(reversed: Bool) async throws {
        let fixture = try DetectorFixture()
        defer { fixture.remove() }
        let cases = try corpusCases().filter { $0.text.utf8.count < 200_000 }
        var fields = cases.map { ("/\($0.id)", $0.text) }
        // A key block split across two fields is not one finding.
        let pem = try corpusText("pem-multiline").split(separator: "\n", omittingEmptySubsequences: false)
        fields += [("/pem-head", pem[..<(pem.count / 2)].joined(separator: "\n") + "\n"),
                   ("/pem-tail", pem[(pem.count / 2)...].joined(separator: "\n"))]
        // The same value in two fields is reported in both.
        fields.append(("/github-error-again", try corpusText("github-error")))
        if reversed { fields.reverse() }
        let detector = BetterleaksSecretDetector(configuration: fixture.configuration)
        let together = try await detector.scan(fieldsSource(fields))
        let alone = try await scannedAlone(fields, with: detector)
        #expect(together.scannerFailure == nil)
        #expect(alone.seen.count == cases.reduce(1) { $0 + $1.expected.count })
        #expect(seen(together) == alone.seen)
        #expect(Set(together.coverageGaps) == alone.gaps)
        #expect(Set(together.unlocated) == alone.unlocated)
    }

    @Test func aLaunchReturnsSoonAfterItsProcessExits() throws {
        let fixture = try DetectorFixture()
        defer { fixture.remove() }
        var fastest = TimeInterval.infinity
        for _ in 0..<20 {
            let started = ProcessInfo.processInfo.systemUptime
            _ = try ScannerProcess.runBounded(Data(), executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                                              directory: fixture.root, timeout: 5, maximumOutputBytes: 1)
            fastest = min(fastest, ProcessInfo.processInfo.systemUptime - started)
        }
        // Each launch used to wait out a 25 ms poll and a ~70 ms run-loop pass after its process had exited.
        #expect(fastest < 0.06)
    }

    @Test func cancelingAScanOfManyFieldsStopsItPromptly() async throws {
        let fixture = try DetectorFixture()
        defer { fixture.remove() }
        let detector = BetterleaksSecretDetector(configuration: fixture.configuration)
        let source = try fieldsSource(toolResultFields(400))
        let scan = Task { try await detector.scan(source) }
        try await Task.sleep(for: .milliseconds(300))
        let canceled = ProcessInfo.processInfo.systemUptime
        scan.cancel()
        await #expect(throws: DetectorFailure.cancelled) { try await scan.value }
        #expect(ProcessInfo.processInfo.systemUptime - canceled < 2)
    }

    @Test func aDeadlineCutShortReportsTheTimeoutAndKeepsWhatWasScanned() async throws {
        let fixture = try DetectorFixture(timeout: 0.5)
        defer { fixture.remove() }
        var fields = toolResultFields(300)
        fields[0].1 = "Authorization: Bearer rV8nQ4zF7pD2sL9xK3mB6cH1jE5uW0tY4aR8vN\n"
        let output = try await BetterleaksSecretDetector(configuration: fixture.configuration).scan(fieldsSource(fields))
        #expect(output.scannerFailure == .timedOut)
        #expect(output.coverageGaps.contains(CoverageGap(reason: .budgetExhausted)))
        #expect(output.findings.contains { $0.extraction.location.components[0].segmentID == "/result/items/0/status" })
    }

    @Test func aMissingScannerStillGetsLocalRulesOnEveryField() async throws {
        let fixture = try DetectorFixture()
        defer { fixture.remove() }
        let config = BetterleaksConfiguration(executableURL: fixture.root.appendingPathComponent("missing"),
                                              configurationURL: fixture.configuration.configurationURL,
                                              workingDirectoryURL: fixture.work)
        var fields = toolResultFields(40)
        fields[3].1 = "Authorization: Bearer rV8nQ4zF7pD2sL9xK3mB6cH1jE5uW0tY4aR8vN\n"
        fields[37].1 = "The database password is `vR7!kQ2#sM9@pL4`.\n"
        let output = try await BetterleaksSecretDetector(configuration: config).scan(fieldsSource(fields))
        #expect(output.scannerFailure == .unavailable)
        #expect(output.coverageGaps == [CoverageGap(reason: .scannerUnavailable)])
        #expect(output.findings.map { $0.extraction.location.components[0].segmentID }.sorted()
                == ["/result/items/3/status", "/result/items/37/status"])
    }
}
