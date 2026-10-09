import Foundation
@_spi(Testing) import SpillcheckCore

private let syntheticValue = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
private enum ProbeError: Error { case controlled(String) }
private struct NativeSelection: Codable, Sendable {
    let role: String
    let nativeThreadID: String
    let nativeIdentitySource: String
    let storeCandidate: String
    let storeCandidateSource: String
    let workingDirectory: String
    let registeredAtUnix: Double
}
private struct Poll: Codable, Sendable {
    let threadID: String
    let audit: HistoricalAuditContext?
    let nonce: UUID
}
private actor Evidence {
    var versions: Set<String> = []
    var markers: [String: Set<SourceIdentity>] = [:]
    var liveMarkers: [String: Set<SourceIdentity>] = [:]
    var liveRevisions: Set<SourceIdentity> = []
    var normalizedContentCounts: [String: [String: Int]] = [:]
    var publicItemMarkers: [String: Set<String>] = [:]
    func collectPublicItems(_ page: CodexHistoryPage, role: String) {
        for item in page.data {
            guard let data = try? JSONEncoder().encode(item) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            guard text.contains(syntheticValue) else { continue }
            for suffix in ["PROMPT", "INTERMEDIATE", "FINAL", "TOOL_OUTPUT", "TOOL_ERROR"] {
                let marker = role.uppercased() + "_" + suffix
                if text.contains("SPILLCHECK_GUI_" + marker) { publicItemMarkers[role, default: []].insert(marker) }
            }
        }
    }
    func collect(_ batch: CollectionBatch, role: String, live: Bool) {
        let expected: [(String, ContentType)] = [("PROMPT", .userPrompt), ("INTERMEDIATE", .intermediateResponse),
            ("FINAL", .finalResponse), ("TOOL_OUTPUT", .toolOutput), ("TOOL_ERROR", .toolError)]
        for source in batch.sources {
            normalizedContentCounts[role, default: [:]][source.record.metadata.contentType.rawValue, default: 0] += 1
            versions.insert(source.record.metadata.origin.agentVersion)
            let text = source.record.segments.map { String(decoding: $0.utf8, as: UTF8.self) }.joined(separator: "\n")
            guard text.contains(syntheticValue) else { continue }
            if live { liveRevisions.insert(source.record.metadata.identity) }
            for (suffix, kind) in expected where source.record.metadata.contentType == kind {
                let marker = role.uppercased() + "_" + suffix
                if text.contains("SPILLCHECK_GUI_" + marker) {
                    markers[marker, default: []].insert(source.record.metadata.identity)
                    if live { liveMarkers[marker, default: []].insert(source.record.metadata.identity) }
                }
            }
        }
    }
    func counts(ids: Set<SourceIdentity>, live: Bool = false) -> [String: Int] {
        (live ? liveMarkers : markers).mapValues { $0.intersection(ids).count }
    }
    func producerVersions() -> [String] { versions.sorted() }
    func observedNativeMarkers() -> [String: [String]] { publicItemMarkers.mapValues { $0.sorted() } }
    func normalizedTypes() -> [String: [String: Int]] { normalizedContentCounts }
}
private actor SelectedHistory: CaptureNormalizer {
    let client: CodexAppServerHistoryClient
    let adapter: CodexAdapter
    let evidence: Evidence
    let project: URL
    let authorizedHome: URL
    var selections: [String: NativeSelection] = [:]
    var referencedNativeChildren: Set<String> = []
    init(client: CodexAppServerHistoryClient, adapter: CodexAdapter, evidence: Evidence,
         project: URL, authorizedHome: URL) {
        self.client = client; self.adapter = adapter; self.evidence = evidence
        self.project = project; self.authorizedHome = authorizedHome
    }
    func admit(_ selection: NativeSelection) async throws -> Bool {
        guard ["parent", "child"].contains(selection.role),
              selection.nativeIdentitySource == "own-runtime-CODEX_THREAD_ID",
              !selection.nativeThreadID.isEmpty, selection.nativeThreadID.utf8.count <= 4096,
              !selection.nativeThreadID.utf8.contains(0),
              URL(fileURLWithPath: selection.workingDirectory).resolvingSymlinksInPath() == project,
              URL(fileURLWithPath: selection.storeCandidate).resolvingSymlinksInPath() == authorizedHome,
              !selections.values.contains(where: { $0.role != selection.role && $0.nativeThreadID == selection.nativeThreadID }) else {
            throw ProbeError.controlled("runtime-selection-or-store-authorization-mismatch")
        }
        if let existing = selections.values.first(where: { $0.role == selection.role }) {
            guard existing.nativeThreadID == selection.nativeThreadID else { throw ProbeError.controlled("native-identity-changed") }
            return true
        }
        // The child must be linked by an original native item in the selected parent.
        // A second task with a matching title/marker/project cannot stand in for a child.
        if selection.role == "child", !referencedNativeChildren.contains(selection.nativeThreadID) { return false }
        let read = try await client.readThread(selection.nativeThreadID)
        try verify(read.thread, id: selection.nativeThreadID)
        selections[selection.nativeThreadID] = selection
        return true
    }
    func childRelationshipVerified() -> Bool {
        guard let child = selections.values.first(where: { $0.role == "child" }) else { return false }
        return referencedNativeChildren.contains(child.nativeThreadID)
    }
    private func verify(_ thread: CodexJSON, id: String) throws {
        guard thread["id"].string == id, let cwd = thread["cwd"].string,
              URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == project,
              let sourcePath = thread["path"].string, sourcePath.hasPrefix("/") else {
            throw ProbeError.controlled("exact-native-source-or-owned-project-unverified")
        }
        let source = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().path
        guard source.hasPrefix(authorizedHome.path + "/") else {
            throw ProbeError.controlled("original-native-source-outside-authorized-store")
        }
    }
    func normalize(_ packet: CapturePacket, capturedAt: Date, cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        let poll = try JSONDecoder().decode(Poll.self, from: packet.eventJSON)
        guard let selection = selections[poll.threadID] else { throw ProbeError.controlled("unselected-native-source") }
        let read = try await client.readThread(poll.threadID)
        try verify(read.thread, id: poll.threadID)
        var cursor: String?, seen: Set<String> = [], bytes = read.bytesRead
        var sources: [CollectedSource] = [], gaps: [CoverageGap] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        for pageNumber in 0..<16 {
            guard bytes < 8 * 1024 * 1024, ProcessInfo.processInfo.systemUptime < deadline else {
                throw ProbeError.controlled("selected-source-read-budget-exhausted")
            }
            let budget = try CodexRPCBudget(maximumBytes: 8 * 1024 * 1024 - bytes,
                timeout: min(10, deadline - ProcessInfo.processInfo.systemUptime))
            let page = try await client.listItems(threadID: poll.threadID, turnID: nil, cursor: cursor, limit: 64,
                direction: .ascending, budget: budget)
            await evidence.collectPublicItems(page, role: selection.role)
            bytes += page.bytesRead
            if selection.role == "parent" {
                for entry in page.data {
                    let item = entry["item"]
                    guard ["collabAgentToolCall", "subAgentActivity"].contains(item["type"].string ?? "") else { continue }
                    let ids = [item["agentThreadId"].string].compactMap { $0 }
                        + (item["receiverThreadIds"].array ?? []).compactMap(\.string)
                    for id in ids where id != poll.threadID && !id.isEmpty && id.utf8.count <= 4096 && !id.utf8.contains(0) {
                        guard referencedNativeChildren.count < 256 || referencedNativeChildren.contains(id) else {
                            throw ProbeError.controlled("native-child-reference-budget-exhausted")
                        }
                        referencedNativeChildren.insert(id)
                    }
                }
            }
            let provenance: SourceProvenance = poll.audit.map { .historical($0) } ?? .live
            let batch = try await adapter.importPublicItems(page, thread: read.thread, observedAt: capturedAt,
                provenance: provenance, cryptography: cryptography)
            await evidence.collect(batch, role: selection.role, live: poll.audit == nil)
            sources += batch.sources; gaps += batch.coverageGaps
            guard let next = page.nextCursor else { return .init(sources: sources, coverageGaps: gaps) }
            guard seen.insert(next).inserted, pageNumber < 15 else { throw ProbeError.controlled("selected-source-pagination-incomplete") }
            cursor = next
        }
        throw ProbeError.controlled("selected-source-pagination-incomplete")
    }
}

@main
private enum CodexGUIProbe {
    static func main() async {
        do { try await run() }
        catch {
            let reason: String
            if case ProbeError.controlled(let stage) = error { reason = stage }
            else if let failure = error as? CodexHistoryReadFailure { reason = readFailure(failure.reason) }
            else if let failure = error as? CodexHistoryError { reason = readFailure(failure) }
            else { reason = "controlled-probe-failure" }
            emit(["finished": true, "passed": false, "reason": reason, "productionGUICollectionEnabled": false])
            exit(1)
        }
    }
    private static func readFailure(_ error: CodexHistoryError) -> String {
        switch error {
        case .missingMethod(let method):
            return ["thread/read", "thread/items/list"].contains(method)
                ? "required-passive-method-missing:" + method : "required-passive-method-missing"
        case .rejectedParameters(let method):
            return ["thread/read", "thread/items/list"].contains(method)
                ? "required-passive-parameters-rejected:" + method : "required-passive-parameters-rejected"
        case .unrecognizedExecutable: return "unrecognized-passive-reader-executable"
        case .malformedResponse: return "malformed-passive-native-source-response"
        case .responseLimitExceeded: return "passive-native-source-response-budget-exhausted"
        case .timedOut: return "passive-native-source-read-timed-out"
        default: return "passive-provider-read-unavailable"
        }
    }
    static func run() async throws {
        let args = CommandLine.arguments
        func option(_ name: String) throws -> String {
            guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { throw ProbeError.controlled("missing-option") }
            return args[index + 1]
        }
        let project = URL(fileURLWithPath: try option("--project")).resolvingSymlinksInPath()
        let home = URL(fileURLWithPath: try option("--authorized-home")).resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: try option("--private-directory")).resolvingSymlinksInPath()
        let hostVersion = try option("--host-version")
        let hostVersionEvidence = (try? option("--host-version-evidence")) ?? "operatorAbout"
        let catchupOnly = args.contains("--catchup-only")
        let duration = min(900, max(10, Double(try option("--duration")) ?? 600))
        guard home.path != "/", project != home, hostVersion != "unknown", !hostVersion.isEmpty,
              ["officialBundleMetadata", "operatorAbout"].contains(hostVersionEvidence) else { throw ProbeError.controlled("unverified-host-or-store") }
        let observerStartedAt = Date()
        let selectedSourceAudit = try HistoricalAuditContext(id: UUID(), reason: .restart, endingAt: observerStartedAt)
        let clientWork = temporary.appendingPathComponent("reader-work"), scannerWork = temporary.appendingPathComponent("scanner-work")
        for path in [clientWork, scannerWork] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let client = CodexAppServerHistoryClient(configuration: try .init(executableURL: URL(fileURLWithPath: option("--executable")),
            codexHomeURL: home, workingDirectoryURL: clientWork, requestTimeout: 10))
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let storeURL = temporary.appendingPathComponent("encrypted-store")
        let store = try await ProtectedStore.open(at: storeURL, cryptography: crypto)
        let adapter = try CodexAdapter(profileID: "codex-gui-phase0-format-probe", agentVersion: "unknown",
            interface: .standaloneCLI, history: client, authorityLookup: { try await store.authority(for: $0) },
            authorityRecorder: { choice in
                guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
                try await store.selectAuthority(choice, permit: permit)
            })
        let evidence = Evidence()
        let normalizer = SelectedHistory(client: client, adapter: adapter, evidence: evidence, project: project, authorizedHome: home)
        let detector = BetterleaksSecretDetector(configuration: .init(executableURL: URL(fileURLWithPath: try option("--scanner")),
            configurationURL: URL(fileURLWithPath: try option("--rules")), workingDirectoryURL: scannerWork))
        let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: normalizer, detector: detector,
            detectorVersion: BetterleaksSecretDetector.version, liveSince: observerStartedAt)
        var admitted: [String: NativeSelection] = [:]
        func enqueue(_ selection: NativeSelection, audit: HistoricalAuditContext? = nil) async throws {
            let event = try JSONEncoder().encode(Poll(threadID: selection.nativeThreadID, audit: audit, nonce: UUID()))
            let packet = try CapturePacket(metadata: .init(agent: .codex, interface: .standaloneCLI,
                profileID: "codex-gui-phase0-format-probe"), eventJSON: event)
            guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
            _ = try await store.enqueue(packet.body, capturedAt: Date(), permit: permit, historicalAudit: audit)
            for _ in 0..<32 {
                if try await store.queueStatistics().count == 0 { break }
                _ = try await pipeline.processNext()
            }
        }
        emit(["ready": true, "mode": catchupOnly ? "selected-existing-GUI-sources-catchup-only" : "waiting-for-own-GUI-runtime-identities", "sourceHost": "official-codex-GUI",
            "productionGUICollectionEnabled": false, "parserEligibilityContext": "standalone-cli-format-probe-only"])
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        var completePasses = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            for role in ["parent", "child"] {
                if FileManager.default.fileExists(atPath: project.appendingPathComponent(role + "-unavailable.json").path) {
                    throw ProbeError.controlled(role + "-native-runtime-identity-unavailable")
                }
                let identityFile = project.appendingPathComponent(role + "-identity.json")
                if FileManager.default.fileExists(atPath: identityFile.path) {
                    let data = try Data(contentsOf: identityFile)
                    guard data.count <= 8192 else { throw ProbeError.controlled("runtime-identity-manifest-limit") }
                    let selection = try JSONDecoder().decode(NativeSelection.self, from: data)
                    guard selection.role == role,
                          catchupOnly || selection.registeredAtUnix >= observerStartedAt.timeIntervalSince1970 else {
                        throw ProbeError.controlled("fixture-started-before-observer")
                    }
                    if try await normalizer.admit(selection) {
                        admitted[role] = selection
                        if !catchupOnly {
                            try Data().write(to: project.appendingPathComponent(role + "-collector-ready"), options: .atomic)
                        }
                        try await enqueue(selection, audit: catchupOnly ? selectedSourceAudit : nil)
                    }
                }
            }
            let snapshot = await store.snapshot()
            let selectedIDs = Set(snapshot.occurrences.values.filter {
                if catchupOnly { return true }
                if case .live = $0.source.origin.provenance { return true }; return false
            }.map(\.source.identity))
            let counts = await evidence.counts(ids: selectedIDs, live: !catchupOnly)
            if admitted.count == 2 && counts.count == 10 && counts.values.allSatisfy({ $0 == 1 }) { completePasses += 1 }
            else { completePasses = 0 }
            if completePasses >= 5 { break }
            try await Task.sleep(for: .seconds(1))
        }
        let beforeCatchup = await store.snapshot()
        let beforeIDs = Set(beforeCatchup.occurrences.values.filter {
            if case .live = $0.source.origin.provenance { return true }; return false
        }.map(\.source.identity))
        let liveCounts = await evidence.counts(ids: beforeIDs, live: true)
        emit(["progress": true, "nativeSessionCount": admitted.count,
            "nativeParentChildRelationshipVerified": await normalizer.childRelationshipVerified(),
            "selectedNativePublicItemMarkers": await evidence.observedNativeMarkers(),
            "normalizedContentObservationsIncludingReplay": await evidence.normalizedTypes(),
            "typedCommittedDuringObservation": liveCounts,
            "catchupOnly": catchupOnly, "productionGUICollectionEnabled": false])
        await client.close()
        let restartShutdownCompleted = await client.lastShutdownCompletedWithinDeadline
        let audit = try HistoricalAuditContext(id: UUID(), reason: .restart, endingAt: Date())
        for selection in admitted.values { try await enqueue(selection, audit: audit) }
        let afterCatchup = await store.snapshot()
        for selection in admitted.values { try await enqueue(selection, audit: audit) }
        let afterReplay = await store.snapshot()
        let queue = try await store.queueStatistics()
        let gaps = try await store.coverageGaps()
        let fingerprint = try await crypto.fingerprint(exactBytes: Data(syntheticValue.utf8))
        let valueID = afterReplay.records[fingerprint]?.id
        let occurrences = afterReplay.occurrences.values.filter { $0.valueID == valueID }
        let typed = await evidence.counts(ids: Set(occurrences.map(\.source.identity)))
        let replayStable = afterCatchup.occurrences.count == afterReplay.occurrences.count
            && afterCatchup.alertDecisions.count == afterReplay.alertDecisions.count
        let cipherClean = try clean(storeURL) && clean(scannerWork) && clean(clientWork)
        await client.close()
        let finalShutdownCompleted = await client.lastShutdownCompletedWithinDeadline
        let readerVersion = await client.observedReaderVersion
        try await store.close()
        let producerVersions = await evidence.producerVersions()
        let relationshipVerified = await normalizer.childRelationshipVerified()
        let catchupPassed = admitted.count == 2 && relationshipVerified && typed.count == 10 && typed.values.allSatisfy({ $0 == 1 }) && replayStable
            && queue.count == 0 && cipherClean && gaps.filter({ $0.reason != .incompleteMessage }).isEmpty
            && !producerVersions.isEmpty && !producerVersions.contains("unknown")
            && restartShutdownCompleted == true && finalShutdownCompleted == true
        let passed = !catchupOnly && catchupPassed && liveCounts.count == 10 && liveCounts.values.allSatisfy({ $0 == 1 })
        emit(["finished": true, "passed": passed, "sourceHost": "official-codex-GUI", "hostVersion": hostVersion,
            "catchupOnly": catchupOnly, "selectedSourceCatchupPassed": catchupPassed,
            "hostVersionEvidence": hostVersionEvidence,
            "actualReaderVersion": readerVersion as Any? ?? NSNull(), "observedProducerVersions": producerVersions,
            "nativeSessionCount": admitted.count, "exactNativeIdentityAndAuthorizedOriginalStoreVerified": admitted.count == 2,
            "nativeParentChildRelationshipVerified": relationshipVerified,
            "typedCommitted": typed, "typedCommittedDuringObservation": liveCounts,
            "selectedNativePublicItemMarkers": await evidence.observedNativeMarkers(),
            "normalizedContentObservationsIncludingReplay": await evidence.normalizedTypes(),
            "occurrenceCount": occurrences.count, "nativeLocationsUnique": Set(occurrences.map(\.identity)).count == occurrences.count,
            "readerRestartShutdownCompletedWithinDeadline": restartShutdownCompleted as Any? ?? NSNull(),
            "readerFinalShutdownCompletedWithinDeadline": finalShutdownCompleted as Any? ?? NSNull(),
            "liveBoundaryBeforeRuntimeRegistration": !catchupOnly, "catchupWindowDays": 7, "catchupScope": "exact-selected-original-sources-only",
            "catchupNewOccurrences": afterCatchup.occurrences.count - beforeCatchup.occurrences.count,
            "replayStable": replayStable, "queueCount": queue.count, "ciphertextMarkerInspectionPassed": cipherClean,
            "gapReasons": Array(Set(gaps.map(\.reason.rawValue))).sorted(), "productionGUICollectionEnabled": false,
            "parserEligibilityContext": "standalone-cli-format-probe-only", "signedAppAcceptance": false,
            "hookDeliveryMeasured": false, "sourceOpeningMeasured": false,
            "limitations": ["Format probe uses the existing provider parser in its enabled CLI eligibility context; it does not enable or accept production Desktop normalization.",
                "The GUI host/version and store authorization are explicit operator evidence; native identity comes only from the created task's own runtime and is checked against its exact original source.",
                "Live boundary and exact-ID polling do not measure first-byte publication or hook delivery.",
                catchupOnly ? "This retry began after the genuine GUI fixture completed; all analyzed sources have historical provenance and no live gate is established." : "The live observer began before the genuine GUI fixture registered its native identities.",
                "Catch-up covers only the two selected disposable original sources in a seven-day time window, not discovery of unrelated history."]])
        if !(catchupOnly ? catchupPassed : passed) { exit(1) }
    }
    private static func clean(_ root: URL) throws -> Bool {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        for file in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            if try Data(contentsOf: file).range(of: Data(syntheticValue.utf8)) != nil { return false }
        }
        return true
    }
    private static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
