import Darwin
import Foundation
@_spi(Testing) import SpillcheckCore

private let claudeLiveSecret = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
private struct ClaudeTimingSource: Hashable, Sendable {
    let identity: SourceIdentity
    let revision: ContentRevision
}
private struct ClaudeSourceObservation: Sendable {
    let metadata: SourceRecordMetadata
    let capturedAt: Date
}
private struct ClaudeCommitObservation: Sendable {
    let observation: ClaudeSourceObservation
    let completedAt: Date
    let historical: Bool
}
actor ClaudeLiveEvidence {
    private struct MarkerObservation: Hashable {
        let source: ClaudeTimingSource
        let contentType: ContentType
        let contentTime: Date
        let producerVersion: String
        let role: String
        let parentPath: String
        let path: String
    }
    private var observed: [String: Set<MarkerObservation>] = [:]
    private var parentPaths: Set<String> = []
    private var childPaths: [String: String] = [:]
    private var sourcePathsByIdentity: [SourceIdentity: String] = [:]
    private var conflictingSources: Set<SourceIdentity> = []
    private var bounded = true
    private let sourceRoot: URL
    private let selectedParent: URL?
    init(sourceRoot: URL, selectedParent: URL? = nil) {
        self.sourceRoot = sourceRoot.standardizedFileURL
        self.selectedParent = selectedParent?.standardizedFileURL
    }
    private func role(_ source: CollectedSource) -> (role: String, parent: String, path: String)? {
        guard source.record.metadata.identity.session.provider == .claudeCode,
              source.record.metadata.identity.session.profileID == "claude-live",
              let raw = source.context?.transcriptPath else { return nil }
        let path = URL(fileURLWithPath: raw).standardizedFileURL
        guard path.path == raw, path.path.hasPrefix(sourceRoot.path + "/"), path.pathExtension == "jsonl" else { return nil }
        let parent: URL
        let role: String
        // Native children sit in <session>/subagents/, workflow agents two folders lower in workflows/<run>/.
        let folder = path.deletingLastPathComponent(), runs = folder.deletingLastPathComponent()
        let subagents: URL? = folder.lastPathComponent == "subagents" ? folder
            : runs.lastPathComponent == "workflows" && runs.deletingLastPathComponent().lastPathComponent == "subagents"
                ? runs.deletingLastPathComponent() : nil
        if let subagents, path.lastPathComponent.hasPrefix("agent-"), path.lastPathComponent.count > "agent-.jsonl".count {
            parent = subagents.deletingLastPathComponent().appendingPathExtension("jsonl")
            role = "child"
        } else {
            guard path.deletingPathExtension().lastPathComponent == source.record.metadata.identity.session.sessionID else { return nil }
            parent = path; role = "parent"
        }
        guard selectedParent == nil || selectedParent == parent else { return nil }
        return (role, parent.path, path.path)
    }
    var deliveries = 0
    var paths: [String:String] = [:]
    var firstObservedAt: [String: Date] = [:]
    private var producerVersions: Set<String> = []
    private var measuring = true
    private var sourceObservations: [ClaudeTimingSource: ClaudeSourceObservation] = [:]
    private var commitObservations: [ClaudeTimingSource: ClaudeCommitObservation] = [:]
    private var normalizedEvents: [String: Int] = [:]
    private var normalizerErrors: [String: Int] = [:]
    private var receiverGaps: [String: Int] = [:]
    private var captureHandlerErrors: [String: Int] = [:]
    private var pipelineFailures: [String: Int] = [:]
    private var admittedHistoricalAudits = Set<HistoricalAuditContext>()
    private var uniqueGaps: Set<CoverageGap> = []
    private static func eventLabel(_ packet: CapturePacket) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: packet.eventJSON) as? [String: Any] else { return "malformed" }
        if value["kind"] as? String == "LeakretClaudeHistory" { return "history-request" }
        let events: Set<String> = ["SessionStart", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "PostToolBatch",
            "MessageDisplay", "SubagentStart", "SubagentStop", "Stop", "SpillcheckTranscriptPoll", "LeakretTranscriptPoll"]
        guard let event = value["hook_event_name"] as? String, events.contains(event) else { return "other" }
        return event
    }
    private static func errorLabel(_ error: any Error) -> String {
        if let error = error as? StorageError {
            let name = switch error {
            case .unsafeStorageLocation: "unsafeStorageLocation"
            case .databaseUnavailable: "databaseUnavailable"
            case .manifestMissing: "manifestMissing"
            case .manifestMismatch: "manifestMismatch"
            case .corruptProtectedState: "corruptProtectedState"
            case .protectionUnavailable: "protectionUnavailable"
            case .payloadMissing: "payloadMissing"
            case .invalidPayload: "invalidPayload"
            case .monitoringPaused: "monitoringPaused"
            case .staleProcessingPermit: "staleProcessingPermit"
            case .stateChanged: "stateChanged"
            case .staleClaim: "staleClaim"
            case .captureTooLarge: "captureTooLarge"
            case .queueSaturated: "queueSaturated"
            case .expiredCapture: "expiredCapture"
            case .invalidTime: "invalidTime"
            case .stateTooLarge: "stateTooLarge"
            case .capacityExceeded(let resource): "capacityExceeded/" + resource.rawValue
            case .injectedFailure: "injectedFailure"
            }
            return "storage/" + name
        }
        if let error = error as? ClaudeCollectionError {
            let name = switch error {
            case .invalidConfiguration: "invalidConfiguration"
            case .wrongProfile: "wrongProfile"
            case .malformedCapture: "malformedCapture"
            case .unsafeTranscriptPath: "unsafeTranscriptPath"
            case .awaitingTranscript: "awaitingTranscript"
            }
            return "claude/" + name
        }
        if error is CancellationError { return "cancelled" }
        return "other"
    }
    func normalization(_ packet: CapturePacket) { normalizedEvents[Self.eventLabel(packet), default: 0] += 1 }
    func normalizationFailed(_ error: any Error) { normalizerErrors[Self.errorLabel(error), default: 0] += 1 }
    func receiverGap(_ reason: CoverageGapReason) { receiverGaps[reason.rawValue, default: 0] += 1 }
    func captureHandlerFailed(_ packet: CapturePacket, error: any Error) {
        captureHandlerErrors[Self.eventLabel(packet) + "/" + Self.errorLabel(error), default: 0] += 1
    }
    func pipelineFailure(_ failure: PipelineFailureDiagnostic) {
        let label = [failure.reason.rawValue, failure.stage.rawValue, failure.code.rawValue].joined(separator: "/")
        pipelineFailures[label, default: 0] += 1
    }
    func gapDiagnosticsJSON() throws -> Data {
        var descriptors: [String: Int] = [:]
        for gap in uniqueGaps {
            let locator: String = switch gap.recovery?.locator {
            case .transcript?: "transcript-record"
            case .transcriptByteOffset?: "transcript-position"
            case .upstreamItem?: "native-item"
            case .unavailable?: "native-session"
            case nil: "none"
            }
            let required = gap.excludedContent == true ? "excluded-media"
                : gap.isRequiredFormatFailure.map { $0 ? "confirmed-required" : "unconfirmed" } ?? "unspecified"
            let label = [gap.reason.rawValue, required, gap.contentType?.rawValue ?? "none",
                gap.recovery?.sourceDocumentID == nil ? locator : "source-document",
                gap.sourceKind?.rawValue ?? "none", gap.diagnosticCode?.rawValue ?? "none"].joined(separator: "/")
            descriptors[label, default: 0] += 1
        }
        return try JSONSerialization.data(withJSONObject: ["normalizedEventCounts": normalizedEvents, "normalizerErrorCounts": normalizerErrors,
            "receiverGapCounts": receiverGaps, "captureHandlerErrorCounts": captureHandlerErrors,
            "pipelineFailureCounts": pipelineFailures,
            "uniqueGapDescriptorCounts": descriptors, "labelsAreControlled": true], options: [.sortedKeys])
    }
    func delivery() { deliveries += 1 }
    func historicalAdmission(_ audit: HistoricalAuditContext) { admittedHistoricalAudits.insert(audit) }
    func historicalAdmissions() -> Set<HistoricalAuditContext> { admittedHistoricalAudits }
    func collect(_ batch: CollectionBatch, capturedAt: Date) {
        uniqueGaps.formUnion(batch.coverageGaps)
        let expected: [(String,ContentType)] = [("PROMPT",.userPrompt),("INTERMEDIATE",.intermediateResponse),
            ("FINAL",.finalResponse),("SHELL_OK",.toolOutput),("SHELL_ERROR",.toolError),
            ("MCP_OK",.toolOutput),("MCP_ERROR",.toolError),("CHILD_PROMPT",.userPrompt),
            ("CHILD_INTERMEDIATE",.intermediateResponse),("CHILD_FINAL",.finalResponse),
            ("CHILD_TOOL_OUTPUT",.toolOutput),("CHILD_TOOL_ERROR",.toolError)]
        for source in batch.sources {
            let metadata = source.record.metadata
            producerVersions.insert(metadata.origin.agentVersion)
            if let path = source.context?.transcriptPath { paths[path] = metadata.identity.session.sessionID }
            guard let location = role(source) else { continue }
            if let previous = sourcePathsByIdentity[metadata.identity], previous != location.path {
                conflictingSources.insert(metadata.identity)
            }
            sourcePathsByIdentity[metadata.identity] = location.path
            if location.role == "parent" { parentPaths.insert(location.path) }
            else { childPaths[location.path] = location.parent }
            let text = source.record.segments.map { String(decoding:$0.utf8,as:UTF8.self) }.joined(separator:"\n")
            guard text.contains(claudeLiveSecret) else { continue }
            let key = ClaudeTimingSource(identity: metadata.identity, revision: source.record.revision)
            if measuring, sourceObservations[key] == nil {
                sourceObservations[key] = ClaudeSourceObservation(metadata: metadata, capturedAt: capturedAt)
            }
            for (suffix,kind) in expected where metadata.contentType == kind && suffix.hasPrefix("CHILD_") == (location.role == "child") {
                guard source.record.segments.contains(where: { segment in
                    let text = String(decoding: segment.utf8, as: UTF8.self)
                    return ["LEAKRET_M3_", "LEAKRET_M3_T3_"].contains { text.contains("\($0)\(suffix) \(claudeLiveSecret)") }
                }) else { continue }
                let observation = MarkerObservation(source: key, contentType: kind, contentTime: metadata.contentTime,
                    producerVersion: metadata.origin.agentVersion, role: location.role, parentPath: location.parent, path: location.path)
                guard observed[suffix, default: []].count < 128 || observed[suffix, default: []].contains(observation) else {
                    bounded = false; continue
                }
                observed[suffix, default: []].insert(observation)
                if firstObservedAt[suffix] == nil { firstObservedAt[suffix] = metadata.observedAt }
            }
        }
    }
    private func eligible(_ observation: MarkerObservation) -> Bool {
        parentPaths.contains(observation.parentPath) && !conflictingSources.contains(observation.source.identity)
    }
    func summary() -> [String:Int] {
        observed.mapValues { Set($0.filter(eligible).map { $0.source.identity }).count }.filter { $0.value > 0 }
    }
    private func committedObservations(in snapshot: InventorySnapshot, fingerprint: ValueFingerprint) -> [String: Set<MarkerObservation>] {
        guard let valueID = snapshot.records[fingerprint]?.id else { return [:] }
        return observed.mapValues { values in
            values.filter { observation in
                eligible(observation) && snapshot.analysisReceipts.contains(AnalysisReceipt(source: observation.source.identity,
                    revision: observation.source.revision, detectorVersion: BetterleaksSecretDetector.version))
                    && snapshot.occurrences.values.contains { $0.valueID == valueID && $0.source.identity == observation.source.identity
                        && $0.source.contentType == observation.contentType && $0.source.contentTime == observation.contentTime }
            }
        }
    }
    func committedByRole(in snapshot: InventorySnapshot, fingerprint: ValueFingerprint) -> [String: [String: Int]] {
        let committed = committedObservations(in: snapshot, fingerprint: fingerprint)
        // Each complete result must come from one actual parent and one of its own child
        // files. Distinct children cannot pool missing types into one passing child.
        let pairs = childPaths.filter { parentPaths.contains($0.value) }.sorted { $0.key < $1.key }
        var result: [String: [String: Int]] = [:]
        var best = -1
        for (child, parent) in pairs {
            let candidate = Dictionary(uniqueKeysWithValues: [("parent", parent), ("child", child)].map { role, path in
                (role, committed.mapValues { Set($0.filter { $0.role == role && $0.path == path }.map { $0.source.identity }).count }
                    .filter { $0.value > 0 })
            })
            let score = candidate.values.reduce(0) { $0 + $1.count }
            if score > best { best = score; result = candidate }
        }
        return result
    }
    func committedPairCountsByProducer(in snapshot: InventorySnapshot, fingerprint: ValueFingerprint) -> [String: Int] {
        let committed = committedObservations(in: snapshot, fingerprint: fingerprint)
        let versions = Set(committed.values.flatMap { $0.map(\.producerVersion) })
        return Dictionary(uniqueKeysWithValues: versions.map { version in
            let count = childPaths.filter { parentPaths.contains($0.value) }.filter { child, parent in
                let parentMarkers = committed.filter { marker, observations in
                    !marker.hasPrefix("CHILD_") && observations.contains { $0.path == parent && $0.producerVersion == version }
                }
                let childMarkers = committed.filter { marker, observations in
                    marker.hasPrefix("CHILD_") && observations.contains { $0.path == child && $0.producerVersion == version }
                }
                return parentMarkers.count == 7 && childMarkers.count == 5
            }.count
            return (version, count)
        })
    }
    func committed(in snapshot: InventorySnapshot, fingerprint: ValueFingerprint) -> [String: Int] {
        committedObservations(in: snapshot, fingerprint: fingerprint)
            .mapValues { Set($0.map { $0.source.identity }).count }.filter { $0.value > 0 }
    }
    func nativeSourceRoles() -> [String: Int] {
        ["verifiedParentSourceCount": parentPaths.count,
         "verifiedOwnChildSourceCount": childPaths.values.filter { parentPaths.contains($0) }.count,
         "conflictingSourceIdentityCount": conflictingSources.count]
    }
    func evidenceWithinBudget() -> Bool { bounded }
    func deliveryCount() ->Int { deliveries }
    func sourcePaths() -> [String:String] { paths }
    func observationTimes() ->[String:String] {
        let formatter=ISO8601DateFormatter(); formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        return firstObservedAt.mapValues { formatter.string(from:$0) }
    }
    func observedProducerVersions() -> [String] { producerVersions.sorted() }
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
            commitObservations[key] = ClaudeCommitObservation(observation: observation,
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
                "providerTimestampToCanonicalObservation": statistics(samples.map {
                    $0.observation.metadata.observedAt.timeIntervalSince($0.observation.metadata.contentTime)
                }),
                "queueCaptureToCommitObservation": statistics(samples.map {
                    $0.completedAt.timeIntervalSince($0.observation.capturedAt)
                }),
                "canonicalObservationToCommitObservation": statistics(samples.map {
                    $0.completedAt.timeIntervalSince($0.observation.metadata.observedAt)
                })]
        }
        let report: [String: Any] = ["schemaVersion": 1, "units": "milliseconds", "percentileMethod": "nearest-rank",
            "observedSourceRevisionCount": sourceObservations.count,
            "committedSourceRevisionCount": commitObservations.count,
            "unmeasuredSourceRevisionCount": sourceObservations.count - commitObservations.count,
            "live": population(historical: false), "historical": population(historical: true),
            "limits": [
                "Samples are unique canonical source revisions carrying the disposable synthetic value and a retained detection, with an exact full detector receipt.",
                "Provider contentTime is its transcript timestamp, not a measurement of physical first output byte or agent publication; provider buffering and clock differences cannot be separated.",
                "Canonical observedAt is the adapter read-start timestamp, set before asynchronous transcript reads; a later append can produce a negative provider delta without clock skew.",
                "Each latency leg excludes and counts negative or nonfinite wall-clock deltas independently; clock adjustments can also affect positive durations.",
                "Queue capture time belongs to the enclosing durable hook or poll and can precede publication of a source row; it is not the source's first available byte.",
                "Commit observation is taken after the enclosing capture's pipeline activity completes, so it upper-bounds per-source durable commit and includes remaining batch/checkpoint work.",
                "Final catch-up and replay are excluded. An empty historical population is unmeasured. Standalone CLI results do not measure T3 latency."
            ]]
        return try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    }
}
private struct ClaudeAuditedNormalizer: CaptureNormalizer {
    let adapter:ClaudeAdapter
    let evidence:ClaudeLiveEvidence
    func normalize(_ packet:CapturePacket,capturedAt:Date,cryptography:BackgroundCryptography) async throws ->CollectionBatch {
        await evidence.normalization(packet)
        do {
            let batch = try await adapter.normalize(packet,capturedAt:capturedAt,cryptography:cryptography)
            await evidence.collect(batch, capturedAt: capturedAt); return batch
        } catch {
            await evidence.normalizationFailed(error)
            throw error
        }
    }
}

enum ClaudeAcceptance {
    /// Install/remove only one explicitly owned disposable registration using production editing.
    /// The signed app supplies the receiver; this mode does not assert its connection proof.
    static func configureHook(_ arguments: [String]) async throws {
        func option(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: name), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        guard let settings = option("--settings"), let helper = option("--helper"), let socket = option("--socket"),
              let profile = option("--profile"), let version = option("--version"),
              let registration = option("--registration-id").flatMap(UUID.init(uuidString:)) else {
            throw ClaudeCollectionError.invalidConfiguration
        }
        let configuration = try ClaudeHookConfiguration(registrationID: registration,
            helperURL: URL(fileURLWithPath: helper), socketURL: URL(fileURLWithPath: socket),
            profileID: profile, agentVersion: version)
        let setup = try ClaudeHookSetup(settingsURL: URL(fileURLWithPath: settings), configuration: configuration)
        if arguments.contains("--remove-hook") {
            try await setup.remove()
            emit(["removed": true, "setupState": "notInstalled"])
        } else {
            _ = try await setup.install()
            let challenge = try await setup.beginVerification()
            emit(["installed": true, "setupState": "installedUnverified", "verificationPrompt": challenge.prompt])
        }
    }

    static func run(_ arguments:[String]) async throws {
        func option(_ name:String) ->String? {
            guard let i = arguments.firstIndex(of:name), arguments.indices.contains(i+1) else { return nil }; return arguments[i+1]
        }
        guard let path = option("--directory"), let scanner = option("--scanner"), let rules = option("--rules"),
              let observedVersion = option("--version"),
              CollectionCompatibility.isEligible(provider: .claudeCode, interface: .standaloneCLI, version: observedVersion) else {
            throw ClaudeCollectionError.invalidConfiguration
        }
        let root = URL(fileURLWithPath:path).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath:root.path) else { throw ClaudeCollectionError.invalidConfiguration }
        let storeDirectory = root.appendingPathComponent("protected-store"), work = root.appendingPathComponent("scanner-work")
        try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at:storeDirectory,cryptography:crypto)
        let sourceRoot = URL(fileURLWithPath:option("--source-root") ?? root.path).resolvingSymlinksInPath()
        let evidence = ClaudeLiveEvidence(sourceRoot: sourceRoot,
            selectedParent: option("--source").map { URL(fileURLWithPath: $0).standardizedFileURL })
        let adapter = try ClaudeAdapter(profileID:"claude-live",agentVersion:observedVersion,allowedTranscriptRoots:[sourceRoot],
            checkpointLookup: { id in try await store.checkpoint(documentID: id) })
        let detector = BetterleaksSecretDetector(configuration:.init(executableURL:URL(fileURLWithPath:scanner),
            configurationURL:URL(fileURLWithPath:rules),workingDirectoryURL:work))
        let pipeline = DetectionPipeline(store:store,cryptography:crypto,
            normalizer:ClaudeAuditedNormalizer(adapter:adapter,evidence:evidence),detector:detector,
            detectorVersion:BetterleaksSecretDetector.version, onActivity: { activity in
                if !activity.processing {
                    let snapshot = await store.snapshot()
                    await evidence.observeCommits(snapshot, at: Date())
                }
            })
        await pipeline.observeFailuresForTesting { failure in await evidence.pipelineFailure(failure) }
        let server = LocalCaptureServer()
        var monitor:ClaudeActiveTranscriptMonitor?
        var setup:ClaudeHookSetup?
        if arguments.contains("--claude-observe") {
            guard let source = option("--source"), let session = option("--session") else { throw ClaudeCollectionError.invalidConfiguration }
            monitor = try ClaudeActiveTranscriptMonitor(profileID:"claude-live",sources:[.init(sessionID:session,transcriptURL:URL(fileURLWithPath:source),interface:.t3)], enqueue: { packet,date in
                guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
                _ = try await store.enqueue(packet.body,capturedAt:date,permit:permit)
                await evidence.delivery()
            }, onGap: { gap in try? await store.recordCoverageGap(gap) })
            await monitor?.start()
            emit(["ready":true,"mode":"selected-t3-transcript"])
        } else {
            guard let helper = option("--helper"), let settings = option("--settings") else { throw ClaudeCollectionError.invalidConfiguration }
            let socket = root.appendingPathComponent("capture.sock")
            let configuration = try ClaudeHookConfiguration(registrationID:UUID(),helperURL:URL(fileURLWithPath:helper),
                socketURL:socket,profileID:"claude-live",agentVersion:observedVersion)
            let installed = try ClaudeHookSetup(settingsURL:URL(fileURLWithPath:settings),configuration:configuration)
            _ = try await installed.install()
            let challenge = try await installed.beginVerification()
            setup = installed
            try await server.start(at:socket,accepting:{ await store.processingPermit() != nil },onCapture:{ packet in
                do {
                guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
                let audit = try ClaudeAdapter.historicalAuditForTesting(in: packet)
                let insertion = try await store.enqueue(packet.body,capturedAt:Date(),permit:permit,historicalAudit:audit)
                if let audit { await evidence.historicalAdmission(audit) }
                await evidence.delivery()
                if let hook = try? JSONSerialization.jsonObject(with:packet.eventJSON) as? [String:Any],
                   hook["hook_event_name"] as? String == "UserPromptSubmit", hook["prompt"] as? String == challenge.prompt {
                    let id:UUID
                    switch insertion { case .inserted(let value), .alreadyQueued(let value), .alreadyProcessed(let value):id=value }
                    try await installed.acceptVerification(.init(packet:packet,durableQueueID:id))
                }
                } catch {
                    await evidence.captureHandlerFailed(packet, error: error)
                    throw error
                }
            },onGap:{ reason in
                await evidence.receiverGap(reason)
                try? await store.recordCoverageGap(reason:reason)
            })
            emit(["ready":true,"mode":"standalone-cli","verificationPrompt":challenge.prompt])
            monitor = try ClaudeActiveTranscriptMonitor(profileID:"claude-live",sources:[],enqueue:{ packet,date in
                guard let permit=await store.processingPermit() else { throw StorageError.monitoringPaused }
                _ = try await store.enqueue(packet.body,capturedAt:date,permit:permit)
                await evidence.delivery()
            },onGap:{ gap in try? await store.recordCoverageGap(gap) })
            await monitor?.start()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + (Double(option("--duration") ?? "240") ?? 240)
        let finished = root.appendingPathComponent("provider-finished")
        var lastPending = -1, quiet = 0
        await pipeline.start()
        while ProcessInfo.processInfo.systemUptime < deadline {
            if arguments.contains("--claude-live") {
                for (path,session) in await evidence.sourcePaths() {
                    try await monitor?.add(source:.init(sessionID:session,transcriptURL:URL(fileURLWithPath:path),interface:.standaloneCLI))
                }
            }
            let count = try await store.queueStatistics().count
            if FileManager.default.fileExists(atPath:finished.path), count == 0 {
                quiet += 1; if quiet >= 8 { break }
            } else { quiet = 0 }
            lastPending = count
            try await Task.sleep(for:.milliseconds(250))
        }
        await monitor?.stop(); await server.stop(); await pipeline.stop()
        let beforeCatchUp = await store.snapshot()
        await evidence.finishMeasurement(beforeCatchUp, at: Date())
        let replayPaths = await evidence.sourcePaths()
        func replayPathsOnce() async throws {
            for (source,session) in replayPaths {
                guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
                let interface:AgentInterface = arguments.contains("--claude-observe") ? .t3 : .standaloneCLI
                let packet = try CapturePacket(metadata:.init(agent:.claudeCode,interface:interface,profileID:"claude-live"),eventJSON:JSONSerialization.data(withJSONObject:["hook_event_name":"SpillcheckTranscriptPoll","session_id":session,"transcript_path":source]))
                _ = try await store.enqueue(packet.body,capturedAt:Date(),permit:permit)
                _ = try await pipeline.processNext()
            }
        }
        // A final catch-up may find legitimately new rows written after a stop hook. Establish
        // the current immutable content baseline before checking replay of that same content.
        try await replayPathsOnce()
        let before=await store.snapshot()
        try await replayPathsOnce()
        let after = await store.snapshot()
        let replayStable = !replayPaths.isEmpty && before.occurrences.count == after.occurrences.count && before.alertDecisions.count == after.alertDecisions.count
        let snapshot = await store.snapshot(), queued = try await store.queueStatistics().count
        let fingerprint = try await crypto.fingerprint(exactBytes:Data(claudeLiveSecret.utf8))
        let valueID = snapshot.records[fingerprint]?.id
        let relevant = snapshot.occurrences.values.filter { $0.valueID == valueID }
        let kindCounts = Dictionary(grouping:relevant,by:{ $0.source.contentType.rawValue }).mapValues(\.count)
        let sessions = Set(relevant.map(\.source.identity.session)).count
        let coverage = try await store.coverageReport()
        guard !coverage.isTruncated else { throw StorageError.stateTooLarge }
        let activeGaps = coverage.activeGapEvents.map(\.gap) + coverage.unresolvedOmissions.map(\.gap)
        let gaps = activeGaps.filter { $0.excludedContent != true }.map(\.reason.rawValue)
        let excludedMediaCount = activeGaps.filter { $0.excludedContent == true }.count
        let historicalProgress = try await store.historicalProgress()
        let historicalAdmissions = await evidence.historicalAdmissions()
        let settledHistoricalAdmissions = historicalAdmissions.filter { admitted in
            historicalProgress.contains { $0.progress.audit == admitted && !$0.progress.hasUnreadContent }
        }.count
        let observed = await evidence.summary()
        let committed = await evidence.committed(in: snapshot, fingerprint: fingerprint)
        let committedByRole = await evidence.committedByRole(in: snapshot, fingerprint: fingerprint)
        let syntheticAlerts = snapshot.alertDecisions.values.filter { $0.eligibility.fingerprint == fingerprint }.count
        let otherCandidates:[[String:Any]] = snapshot.records.filter { $0.key != fingerprint }.map { _,record in
            let occurrences=snapshot.occurrences.values.filter { $0.valueID == record.id }
            return ["categories":record.categories.map(\.rawValue).sorted(),"occurrenceCount":occurrences.count,
                    "signals":Array(Set(occurrences.map { $0.detectorSignal.rawValue })).sorted(),
                    "rules":Array(Set(occurrences.flatMap { $0.evidence.map(\.rule.id) })).sorted(),
                    "locations":occurrences.map { occurrence in
                        ["contentType":occurrence.source.contentType.rawValue,
                         "ranges":occurrence.identity.location.components.map { ["lower":$0.range.lowerBound,"upper":$0.range.upperBound] }] as [String:Any]
                    }]
        }
        let setupState = try await setup?.check()
        let liveFilesClean = try filesAreClean(storeDirectory,marker:Data(claudeLiveSecret.utf8)) && filesAreClean(work,marker:Data(claudeLiveSecret.utf8))
        try await store.close()
        let ciphertextClean = try liveFilesClean && filesAreClean(storeDirectory,marker:Data(claudeLiveSecret.utf8))
        let latencyBytes = try await evidence.latencySummaryJSON()
        let sourceLatency = try JSONSerialization.jsonObject(with: latencyBytes)
        let gapDiagnosticBytes = try await evidence.gapDiagnosticsJSON()
        let gapDiagnostics = try JSONSerialization.jsonObject(with: gapDiagnosticBytes)
        emit(["finished":true,"setupState":setupState?.rawValue ?? "selected-source","durableDeliveries":await evidence.deliveryCount(),
              "observedExecutableVersion":observedVersion,"producerVersions":await evidence.observedProducerVersions(),
              "typedObserved":observed,"typedCommitted":committed,"typedCommittedByRole":committedByRole,
              "nativeSourceRoles":await evidence.nativeSourceRoles(),"roleEvidenceWithinBudget":await evidence.evidenceWithinBudget(),
              "committedNativeParentChildPairCountByProducer":await evidence.committedPairCountsByProducer(in: snapshot, fingerprint: fingerprint),"valueCount":snapshot.records.count,"syntheticValuePresent":valueID != nil,
              "firstObservedAt":await evidence.observationTimes(),
              "sourceLatency":sourceLatency,
              "gapDiagnostics":gapDiagnostics,
              "historicalQueueAdmissionCount":historicalAdmissions.count,
              "historicalProgressCount":historicalProgress.count,
              "historicalSettledAdmissionCount":settledHistoricalAdmissions,
              "historicalAdmissionsSettled":settledHistoricalAdmissions == historicalAdmissions.count,
              "otherCandidates":otherCandidates,
              "occurrenceCount":relevant.count,"occurrencesByContentType":kindCounts,"sessionCount":sessions,
              "alertCount":snapshot.alertDecisions.count,"syntheticAlertCount":syntheticAlerts,"queueCount":queued,"lastPending":lastPending,
              "finalCatchUpNewOccurrences":before.occurrences.count-beforeCatchUp.occurrences.count,
              "gapReasons":Array(Set(gaps)).sorted(), "excludedMediaCount": excludedMediaCount,
              "coverageReportTruncated": coverage.isTruncated,
              "replayStable":replayStable,"ciphertextMarkerInspectionPassed":ciphertextClean])
    }
    private static func filesAreClean(_ directory:URL,marker:Data) throws ->Bool {
        let files = FileManager.default.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey])?.allObjects as? [URL] ?? []
        for file in files where try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {
            if try Data(contentsOf:file).range(of:marker) != nil { return false }
        }
        return true
    }
    private static func emit(_ object:[String:Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]), let text=String(data:bytes,encoding:.utf8) else { return }
        FileHandle.standardOutput.write(Data((text+"\n").utf8))
    }
}
