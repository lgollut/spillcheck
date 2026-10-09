import Darwin
import Foundation
@_spi(Testing) import SpillcheckCore

private let githubValue = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
private let googleValue = "AIzaSy8vR4qN7dP2mL9xF3kT6sB1cH5jE0uW4zY"
private let queueMarker = "SPILLCHECK_RESOURCE_QUEUE_SYNTHETIC_1D1D5880"
private let historySession = "resource-history-synthetic-session"
private enum ProbeFailure: Error { case configuration, networkNotBlocked, fixture, pipeline, assertion, files }

private struct Corpus: Decodable {
    let synthetic: Bool
    let cases: [Fixture]
}
private struct Fixture: Decodable, Sendable {
    struct Chunk: Decodable, Sendable { let text: String; let `repeat`: Int }
    struct Expected: Decodable, Sendable { let start: Int; let end: Int }
    let id: String
    let chunks: [Chunk]
    let expected: [Expected]
    var text: String { chunks.map { String(repeating: $0.text, count: $0.repeat) }.joined() }
}
private struct SyntheticCapture: Codable, Sendable {
    let item: String
    let session: String
    let text: String
    let contentType: ContentType
    let contentTime: Date
}

private struct SyntheticNormalizer: CaptureNormalizer {
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        guard let capture = try? JSONDecoder().decode(SyntheticCapture.self, from: packet.eventJSON) else {
            return .init(sources: [], coverageGaps: [.init(reason: .malformedSource)])
        }
        let identity = try SourceIdentity(session: .init(provider: .claudeCode,
            profileID: "synthetic-resources", sessionID: capture.session), itemID: capture.item)
        let origin = try SourceOrigin(adapterID: "synthetic-resource-fixture", adapterVersion: "1",
            agentVersion: "fixture", interface: .standaloneCLI, provenance: .live,
            canonicalization: .exclusiveAuthority)
        let bytes = Data(capture.text.utf8)
        let revision = try await cryptography.revision(canonicalBytes: bytes)
        let record = try SourceRecord(metadata: .init(identity: identity, contentType: capture.contentType,
            contentTime: capture.contentTime, observedAt: capturedAt, origin: origin),
            revision: revision,
            segments: [.init(id: "text", utf8: bytes)])
        return .init(sources: [.init(record: record,
            context: .init(sessionIdentifier: capture.session, title: "Synthetic resource fixture"))])
    }
}

private actor HistoryMetrics {
    private var values: [HistoricalReadProgress] = []
    func add(_ progress: HistoricalReadProgress?) { if let progress { values.append(progress) } }
    func drain() -> [HistoricalReadProgress] { defer { values.removeAll() }; return values }
}
private struct MeasuredHistoryNormalizer: CaptureNormalizer {
    let adapter: ClaudeAdapter
    let metrics: HistoryMetrics
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        let batch = try await adapter.normalize(packet, capturedAt: capturedAt, cryptography: cryptography)
        await metrics.add(batch.historicalProgress)
        return batch
    }
}

/// This mode checks local workflow under inherited network denial. Its two known synthetic
/// values are fixture results, not a secret-detection algorithm or production scanner claim.
private struct AnnotatedSyntheticDetector: SecretDetector {
    static let version = "annotated-synthetic-offline-workflow-1"
    func scan(_ source: SourceRecord) async throws -> DetectorOutput {
        let evidence = DetectionEvidence(rule: try .init(id: "annotated-synthetic-fixture", version: "1"),
            signal: .strong, reason: .recognizedFormat, category: .token)
        var findings: [DetectorFinding] = []
        for segment in source.segments {
            for known in [githubValue, googleValue] {
                let value = Data(known.utf8)
                var cursor = 0
                while cursor < segment.utf8.count,
                      let range = segment.utf8.range(of: value, in: cursor..<segment.utf8.count) {
                    let location = try CanonicalLocation(segmentID: segment.id,
                        range: .init(range.lowerBound, range.upperBound))
                    findings.append(try .init(extraction: .init(valueUTF8: value, location: location, in: source),
                        evidence: [evidence]))
                    cursor = range.upperBound
                }
            }
        }
        return .init(detectorVersion: Self.version, findings: findings, unlocated: [])
    }
}

/// Synthetic resource/offline acceptance only. This product is never bundled and creates no
/// Keychain item. Every operation uses disposable storage and ephemeral testing cryptography.
@main
private struct ResourceAcceptance {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let result: [String: Any]
            if arguments.contains("--network-denial-workflow") { result = try await offlineWorkflow(arguments) }
            else if arguments.contains("--history-period-only") { result = try await historyPeriodOnly(arguments) }
            else { result = try await run(arguments) }
            emit(result)
        } catch {
            let label: String
            if let controlled = error as? ProbeFailure { label = String(describing: controlled) }
            else if let controlled = error as? StorageError { label = "storage.\(controlled)" }
            else if let controlled = error as? ContractError { label = "contract.\(controlled)" }
            else if let controlled = error as? CaptureTransportError { label = "transport.\(controlled)" }
            else if let controlled = error as? DetectorFailure { label = "detector.\(controlled)" }
            else if let controlled = error as? ClaudeCollectionError { label = "collection.\(controlled)" }
            else { label = "unclassifiedAcceptanceFailure" }
            emit(["passed": false, "failure": label,
                  "ephemeralTestingKeysOnly": true, "productionKeychainItemsCreated": 0])
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) async throws -> [String: Any] {
        func option(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: name), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        guard let path = option("--directory"), let scanner = option("--scanner"),
              let rules = option("--rules"), let corpusPath = option("--corpus"),
              let samples = Int(option("--samples") ?? "40"), (16...160).contains(samples),
              let historyMiB = Int(option("--history-mib") ?? "128"), (101...256).contains(historyMiB) else {
            throw ProbeFailure.configuration
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        let storeURL = root.appendingPathComponent("protected-store", isDirectory: true)
        let scannerWork = root.appendingPathComponent("scanner-work", isDirectory: true)
        let historyRoot = root.appendingPathComponent("synthetic-history", isDirectory: true)
        for directory in [scannerWork, historyRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: corpusPath)))
        let names = ["github-error", "unicode-prefix", "repeated-same-line", "repeated-lines",
                     "pem-multiline", "past-4k", "negative-prose"]
        guard corpus.synthetic else { throw ProbeFailure.fixture }
        var fixtures = try names.map { name -> Fixture in
            guard let fixture = corpus.cases.first(where: { $0.id == name }) else { throw ProbeFailure.fixture }
            return fixture
        }
        let repeated = (0..<24).map { "retry \($0): \(githubValue)\n" }.joined()
        fixtures.append(try fixture(id: "repeated-output-24", text: repeated, value: githubValue))
        let large = String(repeating: "ordinary output\n", count: 65_536) + githubValue + "\n"
        fixtures.append(try fixture(id: "one-mib-output", text: large, value: githubValue))
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: storeURL, cryptography: crypto)
        let detector = BetterleaksSecretDetector(configuration: .init(executableURL: URL(fileURLWithPath: scanner),
            configurationURL: URL(fileURLWithPath: rules), workingDirectoryURL: scannerWork))
        let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: SyntheticNormalizer(),
            detector: detector, detectorVersion: BetterleaksSecretDetector.version,
            liveSince: Date().addingTimeInterval(-1))
        var memoryMarks = [memoryMark("fixture-and-store-ready")]
        guard let permit = await store.processingPermit() else { throw ProbeFailure.pipeline }
        let scope = try LiveCaptureScope(startedAt: Date().addingTimeInterval(-1))
        var latencies: [Double] = [], caseLatencies: [String: [Double]] = [:]
        var expectedOccurrences = 0, totalInputBytes = 0, peakStoreBytes = try directoryBytes(storeURL)
        var peakQueueBytes = 0
        var plaintextNeedles = [Data(githubValue.utf8), Data(googleValue.utf8), Data(queueMarker.utf8),
            Data("Synthetic resource fixture".utf8), Data(historySession.utf8)]
        if let key = fixtures.first(where: { $0.id == "pem-multiline" }) {
            plaintextNeedles.append(Data(key.text.utf8))
            plaintextNeedles.append(Data("-----BEGIN RSA PRIVATE KEY-----".utf8))
        }
        for index in 0..<samples {
            let fixture = fixtures[index % fixtures.count]
            let capture = SyntheticCapture(item: "sample-\(index)", session: "resource-pipeline-synthetic-session",
                text: fixture.text, contentType: ContentType.allCases[index % ContentType.allCases.count],
                contentTime: Date())
            let packet = try CapturePacket(metadata: .init(agent: .claudeCode, interface: .standaloneCLI,
                profileID: "synthetic-resources"), eventJSON: JSONEncoder().encode(capture))
            let began = ProcessInfo.processInfo.systemUptime
            _ = try await store.enqueue(packet.body, capturedAt: Date(), permit: permit, scope: scope)
            let queue = try await store.queueStatistics()
            peakQueueBytes = max(peakQueueBytes, queue.encryptedBytes)
            guard try await pipeline.processNext() == .processed,
                  try await store.queueStatistics().count == 0 else { throw ProbeFailure.pipeline }
            let milliseconds = (ProcessInfo.processInfo.systemUptime - began) * 1000
            latencies.append(milliseconds); caseLatencies[fixture.id, default: []].append(milliseconds)
            totalInputBytes += fixture.text.utf8.count
            let snapshot = await store.snapshot()
            let occurrences = snapshot.occurrences.values.filter { $0.source.identity.itemID == capture.item }
            let actualRanges = occurrences.flatMap { $0.identity.location.components.map { [$0.range.lowerBound, $0.range.upperBound] } }
                .sorted { $0[0] < $1[0] }
            let expectedRanges = fixture.expected.map { [$0.start, $0.end] }.sorted { $0[0] < $1[0] }
            guard actualRanges == expectedRanges else { throw ProbeFailure.assertion }
            expectedOccurrences += fixture.expected.count
            guard snapshot.occurrences.count == expectedOccurrences else { throw ProbeFailure.assertion }
            // A new delivery ID for the same canonical item is a replay, not a second appearance.
            _ = try await store.enqueue(packet.body, capturedAt: Date(), permit: permit, scope: scope)
            guard try await pipeline.processNext() == .processed,
                  await store.snapshot().occurrences.count == expectedOccurrences else { throw ProbeFailure.assertion }
            peakStoreBytes = max(peakStoreBytes, try directoryBytes(storeURL))
        }
        let beforeMalformed = await store.snapshot()
        let malformedPacket = try CapturePacket(metadata: .init(agent: .claudeCode, interface: .standaloneCLI,
            profileID: "synthetic-resources"), eventJSON: Data("{not-json".utf8))
        _ = try await store.enqueue(malformedPacket.body, capturedAt: Date(), permit: permit, scope: scope)
        guard try await pipeline.processNext() == .processed,
              await store.snapshot().occurrences.count == beforeMalformed.occurrences.count,
              try await store.coverageGaps().contains(where: { $0.reason == .malformedSource }) else {
            throw ProbeFailure.assertion
        }
        guard let reviewed = beforeMalformed.occurrences.values.first else { throw ProbeFailure.assertion }
        try await store.review(reviewed.id, as: .falsePositive)
        guard await store.snapshot().occurrences[reviewed.id]?.review == .falsePositive else { throw ProbeFailure.assertion }
        try await store.review(reviewed.id, as: .confirmedSecret)
        guard await store.snapshot().occurrences[reviewed.id]?.review == .confirmedSecret else { throw ProbeFailure.assertion }
        let liveNotifications = try await store.pendingNotifications()
        guard !liveNotifications.isEmpty,
              liveNotifications.allSatisfy({ notification in
                  !plaintextNeedles.contains(where: { notification.body.data(using: .utf8)?.range(of: $0) != nil })
              }) else { throw ProbeFailure.assertion }
        await pipeline.stop()
        memoryMarks.append(memoryMark("processing-and-replay-complete"))

        let history = try await measureHistory(root: historyRoot, sizeMiB: historyMiB, store: store,
            cryptography: crypto, detector: detector)
        memoryMarks.append(memoryMark("history-cold-warm-append-complete"))
        peakStoreBytes = max(peakStoreBytes, try directoryBytes(storeURL))
        let stateBeforeQueue = await store.snapshot()
        let queue = try await measureQueue(store: store, directory: storeURL, needles: plaintextNeedles)
        memoryMarks.append(memoryMark("saturation-inspection-and-expiry-complete"))
        peakStoreBytes = max(peakStoreBytes, queue.peakDiskBytes)
        guard await store.snapshot().occurrences.count == stateBeforeQueue.occurrences.count else {
            throw ProbeFailure.assertion
        }
        let gapReasons = Array(Set(try await store.coverageGaps().map { $0.reason.rawValue })).sorted()
        guard !gapReasons.contains(CoverageGapReason.scannerUnavailable.rawValue),
              try filesAreClean(storeURL, needles: plaintextNeedles),
              try filesAreClean(scannerWork, needles: plaintextNeedles) else { throw ProbeFailure.files }
        memoryMarks.append(memoryMark("final-ciphertext-inspection-complete"))
        let storeBytesBeforeClose = try directoryBytes(storeURL)
        let finalSnapshot = await store.snapshot()
        try await store.close()
        guard try filesAreClean(storeURL, needles: plaintextNeedles) else { throw ProbeFailure.files }
        memoryMarks.append(memoryMark("store-closed-and-inspected"))
        return [
            "passed": percentile(latencies, 0.95) < 120_000,
            "scope": "Synthetic local queue-to-detector-to-encrypted-inventory pipeline; no running agents or GUI",
            "ephemeralTestingKeysOnly": true, "productionKeychainItemsCreated": 0,
            "acceptanceParentNetworkIsolated": false,
            "productionScannerNetworkAndForkDenyProfile": true,
            "networkScope": "Production scanner subprocesses use deny network* and deny process-fork; this measurement parent is not sandboxed because macOS rejects nesting sandbox-exec.",
            "detectorVersion": BetterleaksSecretDetector.version,
            "latency": ["sampleCount": samples, "inputBytes": totalInputBytes,
                "p50Milliseconds": percentile(latencies, 0.50), "p95Milliseconds": percentile(latencies, 0.95),
                "maximumMilliseconds": latencies.max() ?? 0, "targetP95Milliseconds": 120_000,
                "includes": "Durable queue encryption/insert, normalization, actual scanner process, value/context encryption, inventory commit",
                "excludes": "Provider observation delay, helper process startup, IPC transport, worker idle polling, UI and OS notification display",
                "cases": caseLatencies.keys.sorted().map { name in
                    ["case": name, "sampleCount": caseLatencies[name]!.count,
                     "p50Milliseconds": percentile(caseLatencies[name]!, 0.50),
                     "p95Milliseconds": percentile(caseLatencies[name]!, 0.95)] as [String: Any]
                }],
            "upstreamObservationDelay": ["measured": false,
                "reason": "Synthetic content is directly observable; actual provider delay is reported separately"],
            "hookDeliveryBudget": ["measuredHere": false,
                "reason": "The separate real helper/IPC acceptance measures helper startup and acknowledgement"],
            "checks": ["allFiveContentTypes": true, "canonicalReplayStable": true,
                "malformedJSONVisibleGap": true, "unicodeExactRanges": true, "multilineKeyExactRange": true,
                "repeatedAppearancesPreserved": true, "reviewReversible": true,
                "controlledMaskedNotificationsPreparedOffline": true,
                "ciphertextMarkerInspectionPassed": true, "queueExpiryPreservedInventory": true],
            "inventory": ["valueCount": finalSnapshot.records.count,
                "occurrenceCount": finalSnapshot.occurrences.count,
                "liveMaskedNotificationsPrepared": liveNotifications.count],
            "storage": ["peakProtectedStoreLogicalBytes": peakStoreBytes,
                "protectedStoreLogicalBytesBeforeClose": storeBytesBeforeClose,
                "protectedStoreLogicalBytesAfterClose": try directoryBytes(storeURL),
                "peakSequentialPipelineEncryptedQueueBytes": peakQueueBytes,
                "scannerWorkingDirectoryBytes": try directoryBytes(scannerWork),
                "notes": "Logical on-disk sizes include SQLite journals. Queue payload budget does not cap total metadata or physical database size."],
            "history": history,
            "queue": queue.report,
            "memory": ["processPeakRSSBytes": peakRSS(RUSAGE_SELF),
                "scannerChildrenPeakRSSBytes": peakRSS(RUSAGE_CHILDREN),
                "phaseMemory": memoryMarks,
                "scope": "This synthetic Swift acceptance executable, not the signed GUI app",
                "notes": "Current resident bytes use mach_task_basic_info. Darwin getrusage high-water marks accumulate across phases and are separate process/child maxima, not simultaneous total RSS; parent wrapper samples the owned process tree."],
            "gapReasons": gapReasons,
        ]
    }

    private static func offlineWorkflow(_ arguments: [String]) async throws -> [String: Any] {
        guard let index = arguments.firstIndex(of: "--directory"), arguments.indices.contains(index + 1),
              networkBlocked() else { throw ProbeFailure.networkNotBlocked }
        let root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true).resolvingSymlinksInPath()
        let historyRoot = root.appendingPathComponent("synthetic-history", isDirectory: true)
        let storeURL = root.appendingPathComponent("protected-store", isDirectory: true)
        try FileManager.default.createDirectory(at: historyRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = historyRoot.appendingPathComponent("synthetic-offline.jsonl")
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var rows = Data()
        for (index, type) in ContentType.allCases.enumerated() {
            rows.append(try historyRow(id: "network-row-\(index)", date: now,
                text: "Résumé 🔐 秘密 \(githubValue)", contentType: type))
        }
        rows.append(Data("{malformed-json\n".utf8))
        guard FileManager.default.createFile(atPath: path.path, contents: rows, attributes: [.posixPermissions: 0o600]) else {
            throw ProbeFailure.files
        }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: storeURL, cryptography: crypto)
        let adapter = try ClaudeAdapter(profileID: "synthetic-offline", agentVersion: ClaudeAdapter.validatedAgentVersion,
            allowedTranscriptRoots: [historyRoot], checkpointLookup: { try await store.checkpoint(documentID: $0) })
        let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
            detector: AnnotatedSyntheticDetector(), detectorVersion: AnnotatedSyntheticDetector.version,
            liveSince: now.addingTimeInterval(-1))
        let scope = try LiveCaptureScope(startedAt: now.addingTimeInterval(-1))
        let event = try JSONSerialization.data(withJSONObject: ["hook_event_name": "SpillcheckTranscriptPoll",
            "session_id": historySession, "transcript_path": path.path])
        let packet = try CapturePacket(metadata: .init(agent: .claudeCode, interface: .standaloneCLI,
            profileID: adapter.profileID), eventJSON: event)
        func capture() async throws {
            guard let permit = await store.processingPermit() else { throw ProbeFailure.pipeline }
            _ = try await store.enqueue(packet.body, capturedAt: Date(), permit: permit, scope: scope)
            guard try await pipeline.processNext() == .processed,
                  try await store.queueStatistics().count == 0 else { throw ProbeFailure.pipeline }
        }
        func append(_ id: String, _ text: String) throws {
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: historyRow(id: id, date: Date(), text: text))
            try handle.synchronize()
        }
        try await capture()
        let first = await store.snapshot()
        guard first.records.count == 1, first.occurrences.count == 5,
              Set(first.occurrences.values.map { $0.source.contentType }) == Set(ContentType.allCases),
              first.alertDecisions.count == 1,
              try await store.coverageGaps().contains(where: { $0.reason == .malformedSource }) else { throw ProbeFailure.assertion }
        let notifications = try await store.pendingNotifications()
        guard notifications.count == 1, let occurrence = first.occurrences.values.first else { throw ProbeFailure.assertion }
        for review in [OccurrenceReview.falsePositive, .confirmedSecret, .unreviewed] {
            try await store.review(occurrence.id, as: review)
            guard await store.snapshot().occurrences[occurrence.id]?.review == review else { throw ProbeFailure.assertion }
        }
        try await capture()
        guard await store.snapshot().occurrences.count == 5,
              await store.snapshot().alertDecisions.count == 1 else { throw ProbeFailure.assertion }
        guard let permit = await store.processingPermit() else { throw ProbeFailure.pipeline }
        await store.setMonitoring(enabled: false)
        var rejectedWhilePaused = false
        do { _ = try await store.enqueue(packet.body, capturedAt: Date(), permit: permit) }
        catch StorageError.monitoringPaused { rejectedWhilePaused = true }
        guard rejectedWhilePaused, try await pipeline.processNext() == .idle,
              try await store.queueStatistics().count == 0 else { throw ProbeFailure.assertion }
        await store.setMonitoring(enabled: true)
        let fingerprint = try await crypto.fingerprint(exactBytes: Data(githubValue.utf8))
        try await store.acknowledgeObsolete(fingerprint, as: .revoked, at: Date())
        _ = try await store.removeContent(for: fingerprint)
        let removed = await store.snapshot()
        guard removed.records[fingerprint]?.protectedValue == nil, removed.occurrences.isEmpty,
              removed.obsoleteMarkers[fingerprint] != nil else { throw ProbeFailure.assertion }
        try await capture()
        guard await store.snapshot().occurrences.isEmpty else { throw ProbeFailure.assertion }
        try append("network-obsolete-new", githubValue)
        try await capture()
        guard await store.snapshot().obsoleteAppearances.count == 1,
              await store.snapshot().records[fingerprint]?.protectedValue == nil,
              try await store.pendingNotifications().isEmpty else { throw ProbeFailure.assertion }
        try await store.forgetObsoleteMarker(fingerprint)
        try append("network-forgotten-new", githubValue)
        try await capture()
        let forgotten = await store.snapshot()
        guard forgotten.obsoleteMarkers[fingerprint] == nil, forgotten.occurrences.count == 1,
              forgotten.records[fingerprint]?.protectedValue != nil else { throw ProbeFailure.assertion }
        try append("network-replacement-new", googleValue)
        try await capture()
        let final = await store.snapshot()
        let replacementFingerprint = try await crypto.fingerprint(exactBytes: Data(googleValue.utf8))
        guard final.records[replacementFingerprint]?.protectedValue != nil, final.occurrences.count == 2 else {
            throw ProbeFailure.assertion
        }
        let needles = [Data(githubValue.utf8), Data(googleValue.utf8), Data(historySession.utf8), Data(path.path.utf8)]
        guard try filesAreClean(storeURL, needles: needles) else { throw ProbeFailure.files }
        try FileManager.default.removeItem(at: path)
        guard await store.snapshot().records.values.filter({ $0.protectedValue != nil }).count == 2 else {
            throw ProbeFailure.assertion
        }
        await pipeline.stop()
        try await store.close()
        guard networkBlocked(), try filesAreClean(storeURL, needles: needles) else { throw ProbeFailure.files }
        return ["passed": true, "ephemeralTestingKeysOnly": true, "productionKeychainItemsCreated": 0,
            "acceptanceParentNetworkIsolated": true, "networkDenyConfirmedBeforeAndAfterWorkflow": true,
            "detector": AnnotatedSyntheticDetector.version,
            "scannerInvocations": 0,
            "scope": "Actual Claude transcript normalizer, encrypted queue, encrypted inventory, review, alert decisions and lifecycle under deny network*. Detector results are explicitly annotated synthetic fixtures.",
            "checks": ["actualClaudeNormalizerAllFiveContentTypes": true, "malformedJSONVisibleGap": true,
                "durableEncryptedCaptureAndInventory": true, "canonicalReplayStable": true,
                "reviewReversible": true, "maskedNotificationDecision": true,
                "pauseRejectedWithoutQueuedPayload": true, "resumeProcessedNewCapture": true,
                "acknowledgedDeletionPreservedMarker": true, "replayDidNotResurrectDeletedContent": true,
                "newObsoleteAppearanceMetadataOnlyAndSilent": true, "forgottenMarkerNewAppearanceDetected": true,
                "differentReplacementEvaluated": true, "retainedValueSurvivedSourceDeletion": true,
                "ciphertextMarkerInspectionPassed": true, "shutdownQueueEmpty": true],
            "limits": "No production scanner, running provider, LocalAuthentication prompt, OS notification display, or GUI ran in this mode. Actual scanner measurement is a separate production-isolation component proof."]
    }

    private static func fixture(id: String, text: String, value: String) throws -> Fixture {
        let bytes = Data(text.utf8), exact = Data(value.utf8)
        var expected: [[String: Int]] = [], cursor = 0
        while cursor < bytes.count, let range = bytes.range(of: exact, in: cursor..<bytes.count) {
            expected.append(["start": range.lowerBound, "end": range.upperBound]); cursor = range.upperBound
        }
        return try JSONDecoder().decode(Fixture.self, from: JSONSerialization.data(withJSONObject:
            ["id": id, "chunks": [["text": text, "repeat": 1]], "expected": expected]))
    }

    private static func historyPeriodOnly(_ arguments: [String]) async throws -> [String: Any] {
        func option(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: name), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        guard let path = option("--directory"), let scanner = option("--scanner"),
              let rules = option("--rules"), let sizeMiB = Int(option("--history-mib") ?? "128"),
              (101...256).contains(sizeMiB) else { throw ProbeFailure.configuration }
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        let storeURL = root.appendingPathComponent("protected-store", isDirectory: true)
        let scannerWork = root.appendingPathComponent("scanner-work", isDirectory: true)
        let historyRoot = root.appendingPathComponent("synthetic-history", isDirectory: true)
        for directory in [scannerWork, historyRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: storeURL, cryptography: crypto)
        let detector = BetterleaksSecretDetector(configuration: .init(executableURL: URL(fileURLWithPath: scanner),
            configurationURL: URL(fileURLWithPath: rules), workingDirectoryURL: scannerWork))
        let history = try await measureHistory(root: historyRoot, sizeMiB: sizeMiB, store: store,
            cryptography: crypto, detector: detector)
        let queueCount = try await store.queueStatistics().count
        let gaps = Array(Set(try await store.coverageGaps().map { $0.reason.rawValue })).sorted()
        let needles = [Data(githubValue.utf8), Data(googleValue.utf8), Data(historySession.utf8)]
        guard queueCount == 0, !gaps.contains(CoverageGapReason.scannerUnavailable.rawValue),
              try filesAreClean(storeURL, needles: needles),
              try filesAreClean(scannerWork, needles: needles) else { throw ProbeFailure.files }
        try await store.close()
        guard try filesAreClean(storeURL, needles: needles) else { throw ProbeFailure.files }
        return ["passed": true, "scope": "Fresh isolated synthetic large-history period measurement only; not a rerun of the original resource measurements",
            "ephemeralTestingKeysOnly": true, "productionKeychainItemsCreated": 0,
            "acceptanceParentNetworkIsolated": false, "productionScannerNetworkAndForkDenyProfile": true,
            "detectorVersion": BetterleaksSecretDetector.version, "history": history,
            "queueCount": queueCount, "gapReasons": gaps, "ciphertextMarkerInspectionPassed": true]
    }

    private static func measureHistory(root: URL, sizeMiB: Int, store: ProtectedStore,
        cryptography: BackgroundCryptography, detector: BetterleaksSecretDetector) async throws -> [String: Any] {
        let path = root.appendingPathComponent("synthetic-large-history.jsonl")
        guard FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ProbeFailure.files
        }
        let handle = try FileHandle(forWritingTo: path)
        let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let old = base.addingTimeInterval(-30 * 24 * 3600)
        let oldRow = try historyRow(id: "old-repeated-row", date: old,
            text: String(repeating: "ordinary archived output ", count: 1400) + googleValue)
        let target = sizeMiB * 1024 * 1024
        var sourceBytes = 0
        while sourceBytes < target { try handle.write(contentsOf: oldRow); sourceBytes += oldRow.count }
        let cutoff = base.addingTimeInterval(-HistoricalAuditContext.lookback)
        // These two rows make inclusive/exclusive cutoff behavior observable in the inventory.
        try handle.write(contentsOf: historyRow(id: "outside-cutoff", date: cutoff.addingTimeInterval(-1), text: googleValue))
        try handle.write(contentsOf: historyRow(id: "on-cutoff", date: cutoff, text: githubValue))
        for index in 0..<8 {
            try handle.write(contentsOf: historyRow(id: "recent-\(index)", date: base.addingTimeInterval(-10),
                text: "Résumé 🔐 秘密 \(githubValue)", contentType: ContentType.allCases[index % ContentType.allCases.count]))
        }
        try handle.synchronize(); try handle.close()
        sourceBytes = try directoryBytes(root)
        let adapter = try ClaudeAdapter(profileID: "synthetic-resource-history", agentVersion: ClaudeAdapter.validatedAgentVersion,
            allowedTranscriptRoots: [root], checkpointLookup: { try await store.checkpoint(documentID: $0) })
        let metrics = HistoryMetrics()
        let pipeline = DetectionPipeline(store: store, cryptography: cryptography,
            normalizer: MeasuredHistoryNormalizer(adapter: adapter, metrics: metrics), detector: detector,
            detectorVersion: BetterleaksSecretDetector.version)
        guard let permit = await store.processingPermit() else { throw ProbeFailure.pipeline }
        func pass(_ audit: HistoricalAuditContext) async throws -> (Double, [HistoricalReadProgress], Int) {
            let packet = try await adapter.initialHistoricalCapture(audit: audit)
            let begin = ProcessInfo.processInfo.systemUptime
            _ = try await store.enqueue(packet.body, capturedAt: Date(), permit: permit, historicalAudit: audit)
            var passes = 0
            while try await store.queueStatistics().count > 0 {
                guard passes < 20, try await pipeline.processNext() == .processed else { throw ProbeFailure.pipeline }
                passes += 1
            }
            return ((ProcessInfo.processInfo.systemUptime - begin) * 1000, await metrics.drain(), passes)
        }
        let coldAudit = try HistoricalAuditContext(reason: .firstLaunch, endingAt: base)
        let cold = try await pass(coldAudit)
        let coldSnapshot = await store.snapshot()
        let historical = coldSnapshot.occurrences.values.filter { $0.source.identity.session.profileID == adapter.profileID }
        let oldFingerprint = try await cryptography.fingerprint(exactBytes: Data(googleValue.utf8))
        guard historical.count == 9, historical.contains(where: { $0.source.contentTime == cutoff }),
              historical.allSatisfy({ coldAudit.includes(contentTime: $0.source.contentTime) }),
              coldSnapshot.records[oldFingerprint] == nil,
              cold.1.reduce(0, { $0 + $1.bytesRead }) <= 100 * 1024 * 1024,
              cold.1.contains(where: { $0.hasUnreadContent }) else { throw ProbeFailure.assertion }
        let warmAudit = try HistoricalAuditContext(reason: .restart, endingAt: base.addingTimeInterval(1))
        let warm = try await pass(warmAudit)
        guard warm.1.reduce(0, { $0 + $1.bytesRead }) == 0,
              await store.snapshot().occurrences.count == coldSnapshot.occurrences.count else { throw ProbeFailure.assertion }
        let appendTime = Date().addingTimeInterval(-1)
        let append = try historyRow(id: "append-unicode", date: appendTime,
            text: "Résumé 🔐 é 秘密 \(githubValue)")
            + historyRow(id: "append-replacement", date: appendTime, text: googleValue)
        let appendHandle = try FileHandle(forWritingTo: path)
        try appendHandle.seekToEnd(); try appendHandle.write(contentsOf: append)
        try appendHandle.synchronize(); try appendHandle.close()
        let changedAudit = try HistoricalAuditContext(reason: .resume, endingAt: Date())
        let changed = try await pass(changedAudit)
        let changedBytes = changed.1.reduce(0, { $0 + $1.bytesRead })
        let final = await store.snapshot()
        guard final.occurrences.count == coldSnapshot.occurrences.count + 2,
              final.records[oldFingerprint] != nil, changedBytes <= append.count + 8192,
              changed.1.contains(where: { $0.hasUnreadContent }) else { throw ProbeFailure.assertion }
        let appended = final.occurrences.values.filter {
            $0.source.identity.session.profileID == adapter.profileID && coldSnapshot.occurrences[$0.id] == nil
        }
        let coldOldest = cold.1.compactMap(\.oldestContentTime).min()
        let coldNewest = cold.1.compactMap(\.newestContentTime).max()
        let appendOldest = changed.1.compactMap(\.oldestContentTime).min()
        let appendNewest = changed.1.compactMap(\.newestContentTime).max()
        guard coldOldest == cutoff, coldNewest == base.addingTimeInterval(-10),
              warm.1.compactMap(\.oldestContentTime).isEmpty,
              appended.count == 2, appendOldest == appended.map(\.source.contentTime).min(),
              appendNewest == appended.map(\.source.contentTime).max(),
              appended.allSatisfy({ changedAudit.includes(contentTime: $0.source.contentTime) }) else {
            throw ProbeFailure.assertion
        }
        await pipeline.stop()
        return ["provider": "Claude Code versioned synthetic transcript", "agentVersion": ClaudeAdapter.validatedAgentVersion,
            "sourceLogicalBytesBeforeAppend": sourceBytes, "appendLogicalBytes": append.count,
            "periodReporting": ["measuredDuringThisRun": true, "completeWindowCoverage": false,
                "fixtureBaseTime": timestamp(base), "oldRepeatedPrefixTime": timestamp(old),
                "outsideCutoffTime": timestamp(cutoff.addingTimeInterval(-1)),
                "onCutoffTime": timestamp(cutoff), "recentRowsTime": timestamp(base.addingTimeInterval(-10)),
                "notes": "Audit endpoints select an inclusive seven-day content-time window. Adapter bounds describe emitted sources and the newest checkpoint watermark, not all timestamps in unread bytes. Retained bounds describe only new detections in that pass. Warm reuse reads zero payload bytes; an old prefix remains unread and visibly partial."],
            "cold": ["queueToInventoryMilliseconds": cold.0,
                "sourceBytesReadIncludingBoundaryVerification": cold.1.reduce(0, { $0 + $1.bytesRead }),
                "boundedPasses": cold.2, "retainedOccurrences": historical.count,
                "period": historyPeriod(audit: coldAudit, progress: cold.1, retainedTimes: historical.map(\.source.contentTime))],
            "warm": ["queueToInventoryMilliseconds": warm.0,
                "sourceBytesReadIncludingBoundaryVerification": warm.1.reduce(0, { $0 + $1.bytesRead }),
                "boundedPasses": warm.2, "newOccurrences": 0,
                "period": historyPeriod(audit: warmAudit, progress: warm.1, retainedTimes: [])],
            "append": ["queueToInventoryMilliseconds": changed.0,
                "sourceBytesReadIncludingBoundaryVerification": changedBytes,
                "boundedPasses": changed.2, "newOccurrences": 2,
                "period": historyPeriod(audit: changedAudit, progress: changed.1, retainedTimes: appended.map(\.source.contentTime))],
            "sevenDayContentTimeCutoffPassed": true, "unchangedHistoryNotReprocessed": true,
            "differentReplacementValueEvaluated": true, "unreadPrefixVisibleAsPartialCoverage": true,
            "notes": "Old monotonic prefix is deliberately unread. A visible unresolved-correlation gap and partial progress remain; this is not an exhaustive historical audit or a Codex benchmark."]
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func historyPeriod(audit: HistoricalAuditContext, progress: [HistoricalReadProgress],
        retainedTimes: [Date]) -> [String: Any] {
        func bound(_ date: Date?) -> Any { date.map(timestamp) as Any? ?? NSNull() }
        return ["auditReason": audit.reason.rawValue, "auditStartInclusive": timestamp(audit.start),
            "auditEndInclusive": timestamp(audit.end), "lookbackSeconds": HistoricalAuditContext.lookback,
            "progressRecordCount": progress.count,
            "adapterOldestEmittedContentTime": bound(progress.compactMap(\.oldestContentTime).min()),
            "adapterNewestContentCheckpointTime": bound(progress.compactMap(\.newestContentTime).max()),
            "newRetainedOldestContentTime": bound(retainedTimes.min()),
            "newRetainedNewestContentTime": bound(retainedTimes.max()),
            "hasUnreadContent": progress.contains(where: \.hasUnreadContent)]
    }

    private static func historyRow(id: String, date: Date, text: String,
        contentType: ContentType = .userPrompt) throws -> Data {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let blocks: [[String: Any]]
        if contentType == .toolOutput || contentType == .toolError {
            blocks = [["type": "tool_result", "tool_use_id": id, "content": text, "is_error": contentType == .toolError]]
        } else { blocks = [["type": "text", "text": text]] }
        return try JSONSerialization.data(withJSONObject: ["type": contentType == .intermediateResponse || contentType == .finalResponse
            ? "assistant" : "user", "version": ClaudeAdapter.validatedAgentVersion, "sessionId": historySession,
            "uuid": id, "timestamp": formatter.string(from: date),
            "message": ["content": blocks, "stop_reason": contentType == .finalResponse ? "end_turn" : "tool_use"]],
            options: [.sortedKeys]) + Data([10])
    }

    private struct QueueMeasurement {
        let peakDiskBytes: Int
        let report: [String: Any]
    }
    private static func measureQueue(store: ProtectedStore, directory: URL, needles: [Data]) async throws -> QueueMeasurement {
        guard let permit = await store.processingPermit() else { throw ProbeFailure.pipeline }
        let now = Date()
        let eventBytes = 7 * 1024 * 1024
        var event = Data(queueMarker.utf8)
        event.append(Data(repeating: 65, count: eventBytes - event.count))
        let began = ProcessInfo.processInfo.systemUptime
        var memoryMarks = [memoryMark("before-queue-saturation")]
        var accepted = 0, saturated = false
        for _ in 0..<32 {
            do { _ = try await store.enqueue(event, capturedAt: now, permit: permit, at: now); accepted += 1 }
            catch StorageError.queueSaturated { saturated = true; break }
        }
        let full = try await store.queueStatistics()
        guard saturated, accepted > 0, full.count == accepted, full.encryptedBytes <= 100 * 1024 * 1024,
              try await store.coverageGaps().contains(where: { $0.reason == .queueSaturated }) else { throw ProbeFailure.assertion }
        let disk = try directoryBytes(directory)
        memoryMarks.append(memoryMark("queue-saturated-before-inspection"))
        guard try filesAreClean(directory, needles: needles) else { throw ProbeFailure.files }
        memoryMarks.append(memoryMark("saturated-queue-inspection-complete"))
        var oversizeRejected = false
        do { _ = try await store.enqueue(Data(repeating: 65, count: 8 * 1024 * 1024 + 1),
                capturedAt: now, permit: permit, at: now) }
        catch StorageError.captureTooLarge { oversizeRejected = true }
        guard oversizeRejected, try await store.queueStatistics() == full else { throw ProbeFailure.assertion }
        memoryMarks.append(memoryMark("oversize-rejected"))
        await store.setMonitoring(enabled: false)
        let expired = try await store.maintainQueue(at: now.addingTimeInterval(24 * 3600 + 1))
        let empty = try await store.queueStatistics()
        guard expired == accepted, empty.count == 0, empty.encryptedBytes == 0,
              try await store.coverageGaps().contains(where: { $0.reason == .queueExpired }) else { throw ProbeFailure.assertion }
        memoryMarks.append(memoryMark("expired-queue-empty"))
        return .init(peakDiskBytes: disk, report: ["configuredEncryptedPayloadBudgetBytes": 100 * 1024 * 1024,
            "configuredSingleEventBudgetBytes": 8 * 1024 * 1024, "configuredAgeBudgetSeconds": 24 * 3600,
            "singleSyntheticPayloadBytes": eventBytes, "acceptedBeforeSaturation": accepted,
            "peakEncryptedQueuedBytes": full.encryptedBytes, "saturationRejectedWithVisibleGap": true,
            "oversizeRejectedWithoutChangingQueue": true, "expiredWhilePausedCount": expired,
            "expiryVisibleGap": true, "finalQueuedBytes": empty.encryptedBytes,
            "phaseMemory": memoryMarks,
            "elapsedMilliseconds": (ProcessInfo.processInfo.systemUptime - began) * 1000])
    }

    private static func networkBlocked() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return errno == EPERM || errno == EACCES }
        defer { close(fd) }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(9).bigEndian
        destination.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let outcome = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return outcome < 0 && (errno == EPERM || errno == EACCES)
    }

    private static func filesAreClean(_ directory: URL, needles: [Data]) throws -> Bool {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw ProbeFailure.files
        }
        let overlap = max(0, (needles.map(\.count).max() ?? 1) - 1)
        for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var tail = Data()
            while let block = try handle.read(upToCount: 64 * 1024), !block.isEmpty {
                let combined = tail + block
                if needles.contains(where: { combined.range(of: $0) != nil }) { return false }
                tail = Data(combined.suffix(overlap))
            }
        }
        return true
    }

    private static func directoryBytes(_ directory: URL) throws -> Int {
        guard let files = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { throw ProbeFailure.files }
        var bytes = 0
        for case let file as URL in files {
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if info.isRegularFile == true { bytes += info.fileSize ?? 0 }
        }
        return bytes
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double {
        let ordered = values.sorted()
        guard !ordered.isEmpty else { return 0 }
        return ordered[min(ordered.count - 1, max(0, Int(ceil(Double(ordered.count) * percentile)) - 1))]
    }

    private static func peakRSS(_ who: Int32) -> Int64 {
        var usage = rusage()
        guard getrusage(who, &usage) == 0 else { return 0 }
        return Int64(usage.ru_maxrss)
    }

    private static func memoryMark(_ phase: String) -> [String: Any] {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return ["phase": phase, "currentResidentBytes": result == KERN_SUCCESS ? Int64(info.resident_size) : 0,
                "currentResidentMeasurementSucceeded": result == KERN_SUCCESS,
                "cumulativePeakRSSBytes": peakRSS(RUSAGE_SELF)]
    }

    private static func emit(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }
}
