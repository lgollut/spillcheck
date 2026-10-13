import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private let webRecoveryValue = "SPILLCHECK_FAKE_WEB_RESULT_42"

private func inspectWebRecoveryFiles(_ directory: URL) throws {
    let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    for case let file as URL in files {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        #expect(try Data(contentsOf: file).range(of: Data(webRecoveryValue.utf8)) == nil)
    }
}

private actor WebRecoveryDetector: SecretDetector {
    private(set) var calls = 0
    func scan(_ source: SourceRecord) throws -> DetectorOutput {
        calls += 1
        let value = Data(webRecoveryValue.utf8)
        var findings: [DetectorFinding] = []
        for segment in source.segments {
            if let range = segment.utf8.range(of: value) {
                let location = try CanonicalLocation(segmentID: segment.id,
                    range: .init(range.lowerBound, range.upperBound))
                findings.append(try .init(extraction: .init(valueUTF8: value, location: location, in: source),
                    evidence: [evidence()]))
            }
        }
        return .init(detectorVersion: "fake-web-detector", findings: findings, unlocated: [])
    }
}

@Suite("Codex web result recovery through the encrypted pipeline")
struct CodexWebSearchRecoveryTests {
    @Test func upgradedParserRecoversOldOmissionAndRestartReplayKeepsOneOccurrence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-web-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let contentTime = now.addingTimeInterval(-60)
        let session = try SessionIdentity(provider: .codex, profileID: "test", sessionID: "web-session")
        let expectedSource = try SourceIdentity(session: session, itemID: "web-result")
        let scope = CollectionScope(provider: .codex, profileID: "test", interface: .standaloneCLI, path: .publicHistory)
        let oldGap = CoverageGap(reason: .unsupportedContent, scope: scope, operation: .liveRead,
            recovery: .init(session: session, locator: .upstreamItem, itemID: "web-result",
                contentTime: contentTime, parserContract: "codex-content-contract-v4"),
            sourceKind: .codexUnknownItem, observedAt: contentTime)
        let history = CodexTestHistory()
        try await history.configure(session.sessionID, thread: codexThread(session.sessionID), pages: [.init(data: [
            codexItem("web-result", type: "webSearch", timestamp: contentTime.timeIntervalSince1970 * 1000,
                body: ["query": "request text", "results": [["snippet": webRecoveryValue]]])
        ])])
        let packet = try codexPacket(thread: session.sessionID, interface: .standaloneCLI)
        let context = try CollectionCaptureRoute(scope: scope, readerVersion: "0.162.1")
            .context(for: packet, trigger: .activePoll)
        let detector = WebRecoveryDetector()
        var originalOccurrenceID: UUID?
        var originalReceiptCount = 0
        for isReplay in [false, true] {
            let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
            if !isReplay {
                try await store.recordCoverageGap(oldGap, at: contentTime)
                #expect(try await store.coverageOmissions().count == 1)
            }
            let adapter = try CodexAdapter(profileID: "test", agentVersion: "0.162.1", interface: .standaloneCLI,
                history: history, authorityLookup: { try await store.authority(for: $0) },
                authorityRecorder: { choice in
                    let permit = try #require(await store.processingPermit())
                    try await store.selectAuthority(choice, permit: permit)
                })
            let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
                detector: detector, detectorVersion: "fake-web-detector")
            let permit = try #require(await store.processingPermit())
            _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, workContext: context)
            #expect(try await pipeline.processNext(at: now) == .processed)
            #expect(try await store.queueStatistics().count == 0)
            #expect(try await store.coverageOmissions().isEmpty)
            #expect(try await store.coverageOmissions(includeRecovered: true).allSatisfy { $0.state == .recovered })
            let snapshot = await store.snapshot()
            let occurrence = try #require(snapshot.occurrences.values.first)
            #expect(snapshot.records.count == 1 && snapshot.occurrences.count == 1)
            #expect(occurrence.identity.source == expectedSource)
            #expect(occurrence.source.contentType == .toolOutput && occurrence.source.contentTime == contentTime)
            if isReplay {
                #expect(occurrence.id == originalOccurrenceID)
                #expect(snapshot.analysisReceipts.count == originalReceiptCount)
            } else {
                originalOccurrenceID = occurrence.id
                originalReceiptCount = snapshot.analysisReceipts.count
            }
            try await store.close()
        }
        #expect(await detector.calls == 1)
        try inspectWebRecoveryFiles(directory)
    }
}
