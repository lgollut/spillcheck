import Foundation
@_spi(Testing) import SpillcheckCore

private let codexLiveSecret = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
private struct CodexTimingSource: Hashable, Sendable {
    let identity: SourceIdentity
    let revision: ContentRevision
}
private struct CodexSourceObservation: Sendable {
    let metadata: SourceRecordMetadata
    let capturedAt: Date
    let readStartedAt: Date
}
private struct CodexCommitObservation: Sendable {
    let observation: CodexSourceObservation
    let completedAt: Date
    let historical: Bool
}
private actor CodexLiveEvidence {
    var observed: [String: Set<SourceIdentity>] = [:]
    var sessions: Set<String> = []
    var primarySessions: Set<String> = []
    var deliveries = 0
    private var measuring = true
    private var sourceObservations: [CodexTimingSource: CodexSourceObservation] = [:]
    private var commitObservations: [CodexTimingSource: CodexCommitObservation] = [:]
    func delivery(threadID: String?) { deliveries += 1; if let threadID { sessions.insert(threadID) } }
    func selectPrimary(_ threadID: String) { primarySessions.insert(threadID) }
    func collect(_ batch: CollectionBatch, capturedAt: Date, readStartedAt: Date) {
        let expected: [(String, ContentType)] = [("PROMPT", .userPrompt), ("INTERMEDIATE", .intermediateResponse),
            ("FINAL", .finalResponse), ("SHELL_OK", .toolOutput), ("SHELL_ERROR", .toolError),
            ("MCP_OK", .toolOutput), ("MCP_ERROR", .toolError), ("CHILD_PROMPT", .userPrompt),
            ("CHILD_FINAL", .finalResponse)]
        for source in batch.sources {
            sessions.insert(source.record.metadata.identity.session.sessionID)
            let text = source.record.segments.map { String(decoding: $0.utf8, as: UTF8.self) }.joined(separator: "\n")
            guard text.contains(codexLiveSecret) else { continue }
            let key = CodexTimingSource(identity: source.record.metadata.identity, revision: source.record.revision)
            if measuring, sourceObservations[key] == nil {
                sourceObservations[key] = CodexSourceObservation(metadata: source.record.metadata,
                    capturedAt: capturedAt, readStartedAt: readStartedAt)
            }
            for (suffix, kind) in expected where source.record.metadata.contentType == kind && text.contains("LEAKRET_M4_\(suffix)") {
                if suffix == "CHILD_FINAL" || suffix == "CHILD_PROMPT" {
                    guard !primarySessions.contains(source.record.metadata.identity.session.sessionID) else { continue }
                    if suffix == "CHILD_PROMPT", !text.trimmingCharacters(in: .whitespacesAndNewlines)
                        .hasPrefix("LEAKRET_M4_CHILD_PROMPT") { continue }
                }
                observed[suffix, default: []].insert(source.record.metadata.identity)
            }
        }
    }
    func committed(_ ids: Set<SourceIdentity>) -> [String: Int] {
        observed.mapValues { $0.intersection(ids).count }.filter { $0.value > 0 }
    }
    func summary() -> [String: Int] { observed.mapValues(\.count) }
    func selectedThreads() -> [String] { sessions.sorted() }
    func deliveryCount() -> Int { deliveries }
    func observeCommits(_ snapshot: InventorySnapshot, at completedAt: Date) {
        guard measuring else { return }
        for (key, observation) in sourceObservations where commitObservations[key] == nil {
            let receipt = AnalysisReceipt(source: key.identity, revision: key.revision,
                detectorVersion: BetterleaksSecretDetector.version)
            guard snapshot.analysisReceipts.contains(receipt),
                  let source = snapshot.occurrences.values.first(where: {
                      $0.source.identity == key.identity && $0.source.contentTime == observation.metadata.contentTime
                  })?.source else { continue }
            let historical: Bool
            if case .historical = source.origin.provenance { historical = true } else { historical = false }
            commitObservations[key] = CodexCommitObservation(observation: observation,
                completedAt: completedAt, historical: historical)
        }
    }
    func finishMeasurement(_ snapshot: InventorySnapshot, at completedAt: Date) {
        observeCommits(snapshot, at: completedAt)
        measuring = false
    }
    func latencySummaryJSON() throws -> Data {
        func statistics(_ seconds: [Double]) -> [String: Any] {
            let valid = seconds.filter { $0.isFinite && $0 >= 0 }.map { $0 * 1000 }.sorted()
            func percentile(_ fraction: Double) -> Any {
                guard !valid.isEmpty else { return NSNull() }
                return valid[max(0, Int(ceil(fraction * Double(valid.count))) - 1)]
            }
            return ["count": valid.count, "excludedNegativeOrNonfiniteCount": seconds.count - valid.count,
                "p50": percentile(0.50), "p95": percentile(0.95), "max": valid.last as Any? ?? NSNull()]
        }
        func population(historical: Bool) -> [String: Any] {
            let samples = commitObservations.values.filter { $0.historical == historical }
            return ["committedSourceRevisionCount": samples.count,
                "providerTimestampToCanonicalReadStart": statistics(samples.map {
                    $0.observation.readStartedAt.timeIntervalSince($0.observation.metadata.contentTime)
                }),
                "queueCaptureToCommitObservation": statistics(samples.map {
                    $0.completedAt.timeIntervalSince($0.observation.capturedAt)
                }),
                "canonicalReadStartToCommitObservation": statistics(samples.map {
                    $0.completedAt.timeIntervalSince($0.observation.readStartedAt)
                })]
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let report: [String: Any] = ["schemaVersion": 1, "units": "milliseconds", "percentileMethod": "nearest-rank",
            "observedSourceRevisionCount": sourceObservations.count,
            "committedSourceRevisionCount": commitObservations.count,
            "unmeasuredSourceRevisionCount": sourceObservations.count - commitObservations.count,
            "firstCanonicalReadStartedAt": sourceObservations.values.map(\.readStartedAt).min().map(formatter.string) as Any? ?? NSNull(),
            "lastCommitObservedAt": commitObservations.values.map(\.completedAt).max().map(formatter.string) as Any? ?? NSNull(),
            "live": population(historical: false), "historical": population(historical: true),
            "limits": [
                "Samples are unique public canonical source revisions carrying the disposable synthetic value, with an exact full detector receipt and a retained occurrence for that source and content time.",
                "Read start is measured immediately before awaiting CodexAdapter.normalize. Product metadata.observedAt remains the queue capturedAt timestamp and is not used as read start.",
                "Provider contentTime is completedAtMs when available, otherwise startedAtMs or a turn timestamp. It does not measure first-byte publication or when public history made that item available.",
                "A public read may include an item published after its start. Each latency leg excludes and counts negative or nonfinite wall-clock deltas; clock adjustments can affect positive durations too.",
                "Queue capture belongs to the enclosing public poll, not the source's first available byte.",
                "Commit observation follows completion of the enclosing pipeline capture. It upper-bounds the source's exact durable commit and includes remaining batch and checkpoint work.",
                "Live or historical classification comes from the retained occurrence after the production pipeline applies its start boundary. Final catch-up and replay are excluded from timing.",
                "This measures standalone CLI exact-ID public-history polling, not hook delivery, T3 latency, hosted tools, or long-running output fragment publication."
            ]]
        return try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    }
}
private struct CodexAuditedNormalizer: CaptureNormalizer {
    let adapter: CodexAdapter
    let evidence: CodexLiveEvidence
    func normalize(_ packet: CapturePacket, capturedAt: Date, cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        let readStartedAt = Date()
        let batch = try await adapter.normalize(packet, capturedAt: capturedAt, cryptography: cryptography)
        await evidence.collect(batch, capturedAt: capturedAt, readStartedAt: readStartedAt); return batch
    }
}

/// Disposable acceptance only. It cannot access production Keychain keys and is not bundled.
enum CodexAcceptance {
    static func run(_ arguments: [String]) async throws {
        func option(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: name), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        guard let directory = option("--directory"), let home = option("--codex-home"),
              let scanner = option("--scanner"), let rules = option("--rules"), let executable = option("--executable") else {
            throw CodexCollectionError.invalidConfiguration
        }
        let root = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
        let storeURL = root.appendingPathComponent("protected-store"), scannerWork = root.appendingPathComponent("scanner-work")
        let clientWork = root.appendingPathComponent("client-work")
        for path in [scannerWork, clientWork] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: storeURL, cryptography: crypto)
        let client = CodexAppServerHistoryClient(configuration: try .init(executableURL: URL(fileURLWithPath: executable),
            codexHomeURL: URL(fileURLWithPath: home), workingDirectoryURL: clientWork))
        let interface: AgentInterface = arguments.contains("--codex-observe")
            ? (AgentInterface(rawValue: option("--interface") ?? "t3") ?? .desktopCode) : .standaloneCLI
        let adapter = try CodexAdapter(profileID: "codex-live", agentVersion: "0.161.0", interface: interface,
            t3Version: interface == .t3 ? CodexAdapter.validatedT3Version : nil, history: client,
            authorityLookup: { try await store.authority(for: $0) },
            authorityRecorder: { choice in
                guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
                try await store.selectAuthority(choice, permit: permit)
            }, checkpointLookup: { try await store.checkpoint(documentID: $0) })
        let evidence = CodexLiveEvidence()
        let detector = BetterleaksSecretDetector(configuration: .init(executableURL: URL(fileURLWithPath: scanner),
            configurationURL: URL(fileURLWithPath: rules), workingDirectoryURL: scannerWork))
        let pipeline = DetectionPipeline(store: store, cryptography: crypto,
            normalizer: CodexAuditedNormalizer(adapter: adapter, evidence: evidence), detector: detector,
            detectorVersion: BetterleaksSecretDetector.version, onActivity: { activity in
                if !activity.processing {
                    let snapshot = await store.snapshot()
                    await evidence.observeCommits(snapshot, at: Date())
                }
            })
        let server = LocalCaptureServer()
        let monitor = try CodexActiveHistoryMonitor(profileID: "codex-live", sources: [], enqueue: { packet, date in
            guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
            _ = try await store.enqueue(packet.body, capturedAt: date, permit: permit)
            await evidence.delivery(threadID: nil)
        }, onGap: { gap in try? await store.recordCoverageGap(gap) })
        var setup: CodexHookSetup?
        if arguments.contains("--codex-observe") {
            guard let ids = option("--threads") else { throw CodexCollectionError.invalidConfiguration }
            for id in ids.split(separator: ",").map(String.init) {
                await evidence.selectPrimary(id)
                try await monitor.addSource(.init(threadID: id, interface: interface, authority: .publicNativeItems))
            }
            emit(["ready": true, "mode": "exact-public-threads"])
        } else {
            guard let helper = option("--helper") else { throw CodexCollectionError.invalidConfiguration }
            let socket = root.appendingPathComponent("capture.sock")
            let configuration = try CodexHookConfiguration(registrationID: UUID(), helperURL: URL(fileURLWithPath: helper),
                socketURL: socket, profileID: "codex-live", agentVersion: "0.161.0")
            let installed = try CodexHookSetup(hooksURL: URL(fileURLWithPath: home).appendingPathComponent("hooks.json"), configuration: configuration)
            _ = try await installed.install()
            let challenge = try await installed.beginVerification()
            setup = installed
            try await server.start(at: socket, accepting: { await store.processingPermit() != nil }, onCapture: { packet in
                guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
                let insertion = try await store.enqueue(packet.body, capturedAt: Date(), permit: permit)
                let hook = try? JSONDecoder().decode(CodexJSON.self, from: packet.eventJSON)
                await evidence.delivery(threadID: hook?["session_id"].string)
                if hook?["hook_event_name"].string == "UserPromptSubmit", hook?["prompt"].string == challenge.prompt {
                    if let id = hook?["session_id"].string { await evidence.selectPrimary(id) }
                    let id: UUID
                    switch insertion { case .inserted(let x), .alreadyQueued(let x), .alreadyProcessed(let x): id = x }
                    try await installed.acceptVerification(.init(packet: packet, durableQueueID: id))
                }
            }, onGap: { reason in try? await store.recordCoverageGap(reason: reason) })
            emit(["ready": true, "mode": "standalone-cli", "verificationPrompt": challenge.prompt,
                "ownedRegistrationID": configuration.registrationID.uuidString, "hooksPath": await installed.hooksURL.path])
        }
        await monitor.start()
        await pipeline.start()
        let deadline = ProcessInfo.processInfo.systemUptime + (Double(option("--duration") ?? "900") ?? 900)
        var stoppedMonitor = false, quiet = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            for id in await evidence.selectedThreads() {
                try await monitor.addSource(.init(threadID: id, interface: interface, authority: .publicNativeItems))
            }
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("provider-finished").path) {
                if !stoppedMonitor { await monitor.stop(); stoppedMonitor = true }
                if try await store.queueStatistics().count == 0 { quiet += 1; if quiet >= 8 { break } }
                else { quiet = 0 }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        await monitor.stop(); await server.stop(); await pipeline.stop()
        let beforeCatchUp = await store.snapshot()
        await evidence.finishMeasurement(beforeCatchUp, at: Date())
        let beforeCatchUpTyped = await evidence.committed(Set(beforeCatchUp.occurrences.values.map(\.source.identity)))
        // Restarting the passive client after monitor.stop is safe. No resume/start calls exist.
        func replay() async throws {
            for id in await evidence.selectedThreads() {
                guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
                let event = try JSONEncoder().encode(CodexJSON.object(["hook_event_name": .string("SpillcheckHistoryPoll"), "session_id": .string(id)]))
                let packet = try CapturePacket(metadata: .init(agent: .codex, interface: interface, profileID: "codex-live"), eventJSON: event)
                _ = try await store.enqueue(packet.body, capturedAt: Date(), permit: permit)
                for _ in 0..<256 {
                    if try await store.queueStatistics().count == 0 { break }
                    _ = try await pipeline.processNext()
                }
            }
        }
        try await replay()
        let before = await store.snapshot()
        try await replay()
        let after = await store.snapshot(), queue = try await store.queueStatistics()
        let fingerprint = try await crypto.fingerprint(exactBytes: Data(codexLiveSecret.utf8))
        let record = after.records[fingerprint]
        let occurrences = after.occurrences.values.filter { $0.valueID == record?.id }
        let committed = await evidence.committed(Set(occurrences.map(\.source.identity)))
        let setupState = try await setup?.check()
        let gaps = try await store.coverageGaps()
        let clean = try filesAreClean(storeURL) && filesAreClean(scannerWork) && filesAreClean(clientWork)
        await client.close()
        try await setup?.remove()
        try await store.close()
        let finalClean = try clean && filesAreClean(storeURL)
        let latencyBytes = try await evidence.latencySummaryJSON()
        let sourceLatency = try JSONSerialization.jsonObject(with: latencyBytes)
        emit(["finished": true, "setupState": setupState?.rawValue ?? "selected-source",
            "durableDeliveries": await evidence.deliveryCount(), "typedObserved": await evidence.summary(), "typedCommitted": committed,
            "syntheticValuePresent": record != nil, "valueCount": after.records.count, "occurrenceCount": occurrences.count,
            "occurrencesByContentType": Dictionary(grouping: occurrences, by: { $0.source.contentType.rawValue }).mapValues(\.count),
            "sessionCount": Set(occurrences.map(\.source.identity.session)).count,
            "syntheticAlertCount": after.alertDecisions.values.filter { $0.eligibility.fingerprint == fingerprint }.count,
            "queueCount": queue.count, "gapReasons": Array(Set(gaps.map(\.reason.rawValue))).sorted(),
            "sourceLatency": sourceLatency, "finalCatchUpNewOccurrences": before.occurrences.count - beforeCatchUp.occurrences.count,
            "typedCommittedBeforeCatchUp": beforeCatchUpTyped,
            "replayStable": before.occurrences.count == after.occurrences.count && before.alertDecisions.count == after.alertDecisions.count,
            "ciphertextMarkerInspectionPassed": finalClean])
    }
    private static func filesAreClean(_ directory: URL) throws -> Bool {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        for file in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            if try Data(contentsOf: file).range(of: Data(codexLiveSecret.utf8)) != nil { return false }
        }
        return true
    }
    private static func emit(_ object: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(bytes + Data([10]))
    }
}
