import Foundation
@_spi(Testing) import SpillcheckCore

private struct WebWitnessUnusedHistory: CodexHistoryReading {
    func readThread(_ threadID: String) async throws -> CodexThreadRead { throw CodexHistoryError.unsafeMethod }
    func listThreads(cursor: String?, limit: Int, archived: Bool) async throws -> CodexHistoryPage { throw CodexHistoryError.unsafeMethod }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection) async throws -> CodexHistoryPage {
        throw CodexHistoryError.unsafeMethod
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int,
                   direction: CodexHistoryDirection) async throws -> CodexHistoryPage { throw CodexHistoryError.unsafeMethod }
}

private enum WebWitnessAssertionFailure: Error { case failed(String) }

private actor WebWitnessAuthority {
    private var choices: [SessionIdentity: CollectionAuthorityChoice] = [:]
    func lookup(_ session: SessionIdentity) -> CollectionAuthorityChoice? { choices[session] }
    func record(_ choice: CollectionAuthorityChoice) throws {
        if let old = choices[choice.session], old.authorityID != choice.authorityID {
            throw CodexCollectionError.authorityConflict
        }
        choices[choice.session] = choice
    }
}

@MainActor
func webResultAcceptanceAssertions() async throws -> [String] {
    func check(_ value: Bool, _ name: String) throws {
        guard value else { throw WebWitnessAssertionFailure.failed(name) }
    }
    let boundaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("spillcheck-web-boundary-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: boundaryRoot, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: boundaryRoot) }
    let boundaryHome = boundaryRoot.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: boundaryHome, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    let boundaryToken = boundaryRoot.appendingPathComponent("token")
    try Data(repeating: 57, count: 32).write(to: boundaryToken)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: boundaryToken.path)
    let boundarySource = UUID().uuidString.lowercased()
    let recovery = try DisposableRecoveryConfiguration(arguments: [
        "--acceptance-recovery-root", boundaryRoot.path,
        "--store-directory", boundaryRoot.appendingPathComponent("store").path,
        "--acceptance-report", boundaryRoot.appendingPathComponent("report").path,
        "--acceptance-finish-file", boundaryRoot.appendingPathComponent("finish").path,
        "--acceptance-recovery-token", boundaryToken.path,
        "--acceptance-recovery-web-results", "--acceptance-web-source", boundarySource])
    func boundaryConfiguration(home: URL, hosts: Set<AgentInterface> = [.standaloneCLI]) -> CodexCollectionConfiguration {
        .init(profileID: "owned-web-boundary", readerVersion: "0.162.1", t3Version: nil,
            interface: .standaloneCLI, authority: .publicNativeItems, home: home,
            executable: URL(fileURLWithPath: "/usr/bin/true"), transcriptRoots: [], activeSources: [], authorizedHosts: hosts)
    }
    let selected = try WebResultAcceptance.selectedSession(configuration: boundaryConfiguration(home: boundaryHome), recovery: recovery)
    try check(selected == SessionIdentity(provider: .codex, profileID: "owned-web-boundary", sessionID: boundarySource),
        "web-witness-accepts-posix-canonical-private-tmp-home")
    let homeLink = boundaryRoot.appendingPathComponent("home-link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: homeLink, withDestinationURL: boundaryHome)
    let nestedHome = boundaryHome.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nestedHome, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    let aliasHome = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent(boundaryRoot.lastPathComponent, isDirectory: true).appendingPathComponent("home", isDirectory: true)
    for invalid in [boundaryConfiguration(home: aliasHome), boundaryConfiguration(home: homeLink),
                    boundaryConfiguration(home: nestedHome), boundaryConfiguration(home: boundaryRoot.deletingLastPathComponent()),
                    boundaryConfiguration(home: boundaryHome, hosts: [.standaloneCLI, .t3])] {
        do {
            _ = try WebResultAcceptance.selectedSession(configuration: invalid, recovery: recovery)
            throw WebWitnessAssertionFailure.failed("web-witness-accepted-aliased-linked-outside-or-wrong-host-home")
        } catch WebResultAcceptance.Failure.unsafeConfiguration { }
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: boundaryHome.path)
    do {
        _ = try WebResultAcceptance.selectedSession(configuration: boundaryConfiguration(home: boundaryHome), recovery: recovery)
        throw WebWitnessAssertionFailure.failed("web-witness-accepted-public-home")
    } catch WebResultAcceptance.Failure.unsafeConfiguration { }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: boundaryHome.path)
    let crypto = try BackgroundCryptography.ephemeralForTesting()
    let session = try SessionIdentity(provider: .codex, profileID: "owned-web-test", sessionID: UUID().uuidString.lowercased())
    let metadata = try CaptureMetadata(agent: .codex, interface: .standaloneCLI, profileID: session.profileID)
    let now = Date()
    let audit = try HistoricalAuditContext(reason: .resume, endingAt: now.addingTimeInterval(1))
    let authority = WebWitnessAuthority()
    let adapter = try CodexAdapter(profileID: session.profileID, agentVersion: "0.162.1",
        history: WebWitnessUnusedHistory(), authorityLookup: { await authority.lookup($0) },
        authorityRecorder: { try await authority.record($0) })
    let item: CodexJSON = .object(["type": .string("webSearch"), "id": .string("native-web-item"),
        "query": .string("REQUEST_METADATA_MUST_NOT_COUNT"), "results": .array([
            .object(["text": .string("public result é🙂"), "url": .string("https://example.invalid/docs")])])])
    let page = CodexHistoryPage(data: [.object(["turnId": .string("owned-turn"),
        "completedAtMs": .number(now.timeIntervalSince1970 * 1000), "item": item])])
    let parsed = try await adapter.importPublicItems(page, thread: .object([
        "id": .string(session.sessionID), "cliVersion": .string("0.162.1")]), observedAt: now,
        provenance: .historical(audit), cryptography: crypto)
    guard parsed.sources.count == 1, let source = parsed.sources.first?.record else {
        throw WebWitnessAssertionFailure.failed("native-parser-fixture")
    }
    func batch(_ record: SourceRecord) -> CollectionBatch {
        .init(sources: [.init(record: record)], historicalProgress: .init(audit: audit, bytesRead: 250, hasUnreadContent: false),
              observedReaderVersion: "0.162.1")
    }
    func modified(_ segments: [SourceSegment], identity: SourceIdentity? = nil,
                  revision: ContentRevision? = nil, type: ContentType = .toolOutput) async throws -> SourceRecord {
        let selectedRevision: ContentRevision
        if let revision { selectedRevision = revision }
        else { selectedRevision = try await crypto.revision(canonicalBytes: WebResultAcceptance.canonicalSegments(segments)) }
        return try .init(metadata: .init(identity: identity ?? source.metadata.identity, contentType: type,
            contentTime: source.metadata.contentTime, observedAt: now, origin: source.metadata.origin),
            revision: selectedRevision, segments: segments)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-web-witness-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    var store = try await ProtectedStore.open(at: root, cryptography: crypto)
    let witness = WebResultAcceptance(session: session)
    try await witness.captureInitial(await store.snapshot(), cryptography: crypto)
    let empty = try await witness.report(snapshot: await store.snapshot(), payloadRows: 0, cryptography: crypto)
    try check(empty.initialStoreEmpty && empty.receiptCount == 0 && empty.webReceiptDigests.isEmpty,
              "web-witness-empty-before-observation")
    await witness.observe(batch(source), metadata: metadata, path: .publicHistory, cryptography: crypto)
    let observed = try await witness.report(snapshot: await store.snapshot(), payloadRows: 0, cryptography: crypto)
    try check(observed.observedWebSourceCount == 1 && observed.committedWebSourceCount == 0
        && observed.webReceiptDigests.isEmpty && !observed.allObservedWebSourcesCommitted,
        "web-witness-observation-alone-cannot-prove-scan")
    guard let permit = await store.processingPermit() else { throw WebWitnessAssertionFailure.failed("permit") }
    let analysis = try SourceAnalysis(source: source, detectorVersion: BetterleaksSecretDetector.version, detections: [])
    _ = try await store.commit(analysis, payloads: [], permit: permit)
    let committed = try await witness.report(snapshot: await store.snapshot(), payloadRows: 0, cryptography: crypto)
    try check(committed.allObservedWebSourcesCommitted && committed.committedWebSourceCount == 1
        && committed.resultSegmentCount == 2 && committed.resultTextBytes > 0 && committed.cleanInventory
        && committed.webReceiptDigests == committed.receiptDigests,
        "web-witness-binds-production-result-only-bytes-to-full-receipt")
    let encoded = try JSONEncoder().encode(committed)
    let publicReport = String(decoding: encoded, as: UTF8.self)
    try check(!publicReport.contains(session.sessionID) && !publicReport.contains("native-web-item")
        && !publicReport.contains("example.invalid") && !publicReport.contains("public result")
        && !publicReport.contains("REQUEST_METADATA"), "web-witness-report-contains-no-identities-or-text")
    try await store.close()
    store = try await ProtectedStore.open(at: root, cryptography: crypto)
    let restarted = WebResultAcceptance(session: session)
    try await restarted.captureInitial(await store.snapshot(), cryptography: crypto)
    let cold = try await restarted.report(snapshot: await store.snapshot(), payloadRows: 0, cryptography: crypto)
    try check(!cold.initialStoreEmpty && cold.observedWebSourceCount == 0
        && cold.initialReceiptDigests == committed.receiptDigests && cold.receiptDigests == committed.receiptDigests
        && cold.sourceTimeDigests == committed.sourceTimeDigests && cold.sourceKindDigests == committed.sourceKindDigests,
        "web-witness-cold-state-proves-persistence-without-new-read")
    await restarted.observe(batch(source), metadata: metadata, path: .publicHistory, cryptography: crypto)
    guard let replayPermit = await store.processingPermit() else { throw WebWitnessAssertionFailure.failed("replay-permit") }
    let transition = try await store.commit(analysis, payloads: [], permit: replayPermit)
    let replayed = try await restarted.report(snapshot: await store.snapshot(), payloadRows: 0, cryptography: crypto)
    try check(transition.outcome == .replay && replayed.allObservedWebSourcesCommitted
        && replayed.receiptDigests == committed.receiptDigests && replayed.webResultDigests == committed.webResultDigests
        && replayed.webSourceDigests == committed.webSourceDigests && replayed.webReceiptDigests == committed.webReceiptDigests,
        "web-witness-replay-keeps-full-source-and-receipt-commitments")
    let payloadLeak = try await restarted.report(snapshot: await store.snapshot(), payloadRows: 1, cryptography: crypto)
    try check(!payloadLeak.cleanInventory, "web-witness-rejects-unexpected-payload")
    try await store.close()

    for version in [BetterleaksSecretDetector.version + "+partial", BetterleaksSecretDetector.version + "+reduced", "wrong-detector"] {
        let receipt = AnalysisReceipt(source: source.metadata.identity, revision: source.revision, detectorVersion: version)
        let snapshot = InventorySnapshot(analysisReceipts: [receipt], sourceKinds: [source.metadata.identity: .toolOutput],
            sourceTimes: [source.metadata.identity: now])
        let invalid = WebResultAcceptance(session: session)
        do {
            try await invalid.captureInitial(snapshot, cryptography: crypto)
            throw WebWitnessAssertionFailure.failed("web-witness-accepted-degraded-receipt")
        } catch WebResultAcceptance.Failure.receiptMismatch { }
    }
    let otherSession = try SessionIdentity(provider: .codex, profileID: session.profileID, sessionID: UUID().uuidString.lowercased())
    let foreignID = try SourceIdentity(session: otherSession, itemID: "native-web-item")
    let foreignReceipt = AnalysisReceipt(source: foreignID, revision: source.revision, detectorVersion: BetterleaksSecretDetector.version)
    do {
        let invalid = WebResultAcceptance(session: session)
        try await invalid.captureInitial(InventorySnapshot(analysisReceipts: [foreignReceipt],
            sourceKinds: [foreignID: .toolOutput], sourceTimes: [foreignID: now]), cryptography: crypto)
        throw WebWitnessAssertionFailure.failed("web-witness-accepted-foreign-receipt")
    } catch WebResultAcceptance.Failure.foreignSource { }
    let differentRevision = try await crypto.revision(canonicalBytes: Data("different original revision".utf8))
    let wrongRevision = AnalysisReceipt(source: source.metadata.identity, revision: differentRevision,
        detectorVersion: BetterleaksSecretDetector.version)
    let unmatched = try await witness.report(snapshot: InventorySnapshot(analysisReceipts: [wrongRevision],
        sourceKinds: [source.metadata.identity: .toolOutput], sourceTimes: [source.metadata.identity: now]),
        payloadRows: 0, cryptography: crypto)
    try check(!unmatched.allObservedWebSourcesCommitted && unmatched.webReceiptDigests.isEmpty,
        "web-witness-same-item-wrong-revision-cannot-pass")
    let receipt = AnalysisReceipt(source: source.metadata.identity, revision: source.revision,
        detectorVersion: BetterleaksSecretDetector.version)
    let wrongKind = try await witness.report(snapshot: InventorySnapshot(analysisReceipts: [receipt],
        sourceKinds: [source.metadata.identity: .userPrompt], sourceTimes: [source.metadata.identity: now]),
        payloadRows: 0, cryptography: crypto)
    try check(!wrongKind.allObservedWebSourcesCommitted, "web-witness-wrong-stored-kind-cannot-pass")
    let changedSegments = [try SourceSegment(id: "/results/0/text", utf8: Data("changed returned content".utf8))]
    let invalidRecords = try await [
        modified(source.segments, identity: foreignID),
        modified(changedSegments, revision: source.revision),
        modified(source.segments + [SourceSegment(id: "/query", utf8: Data("query".utf8))]),
        modified([SourceSegment(id: "/results/0/text", utf8: Data())]),
        modified(source.segments, type: .finalResponse)]
    for invalidRecord in invalidRecords {
        let invalid = WebResultAcceptance(session: session)
        try await invalid.captureInitial(InventorySnapshot(), cryptography: crypto)
        await invalid.observe(batch(invalidRecord), metadata: metadata, path: .publicHistory, cryptography: crypto)
        try check(invalid.failure != nil, "web-witness-rejects-foreign-corrupt-empty-or-mixed-source")
    }
    let changed = WebResultAcceptance(session: session)
    try await changed.captureInitial(InventorySnapshot(), cryptography: crypto)
    await changed.observe(batch(source), metadata: metadata, path: .publicHistory, cryptography: crypto)
    let newRevision = try await modified(changedSegments)
    await changed.observe(batch(newRevision), metadata: metadata, path: .publicHistory, cryptography: crypto)
    try check(changed.failure == .changedSource, "web-witness-rejects-conflicting-native-revision")
    for incomplete in [CollectionBatch(sources: []), CollectionBatch(sources: [], observedRead: true,
        observedReaderVersion: "0.162.1"), CollectionBatch(sources: [.init(record: source)], readEvidenceEligible: false,
        observedReaderVersion: "0.162.1"), CollectionBatch(sources: [.init(record: source)], coverageGaps: [
            .init(reason: .unsupportedContent, isRequiredFormatFailure: true)], observedReaderVersion: "0.162.1")] {
        let invalid = WebResultAcceptance(session: session)
        try await invalid.captureInitial(InventorySnapshot(), cryptography: crypto)
        await invalid.observe(incomplete, metadata: metadata, path: .publicHistory, cryptography: crypto)
        let state = try await invalid.report(snapshot: InventorySnapshot(), payloadRows: 0, cryptography: crypto)
        try check(!state.allObservedWebSourcesCommitted, "web-witness-empty-ineligible-missing-source-cannot-pass")
    }
    return ["web-result-witness-posix-canonical-private-home-without-alias-or-symlink-expansion",
        "web-result-witness-production-parser-bytes-and-exact-full-receipt",
        "web-result-witness-observation-alone-is-not-a-scan",
        "web-result-witness-encrypted-receipts-survive-cold-replay",
        "web-result-witness-rejects-foreign-corrupt-empty-mixed-or-changed-source",
        "web-result-witness-rejects-partial-reduced-and-wrong-detector",
        "web-result-witness-reports-only-keyed-commitments-and-bounded-counts"]
}
