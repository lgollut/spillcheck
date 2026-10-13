import CryptoKit
import Foundation
@_spi(Testing) import SpillcheckCore

enum NativeAssertionFailure: Error { case failed(String) }
private actor NativeAssertionHistory: CodexHistoryReading {
    let thread: CodexThreadRead
    let page: CodexHistoryPage
    init(thread: CodexThreadRead, page: CodexHistoryPage) { self.thread = thread; self.page = page }
    func readThread(_ id: String) -> CodexThreadRead { thread }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int,
                   direction: CodexHistoryDirection) -> CodexHistoryPage { page }
    func listThreads(cursor: String?, limit: Int, archived: Bool) throws -> CodexHistoryPage { throw CodexHistoryError.unsafeMethod }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection) throws -> CodexHistoryPage {
        throw CodexHistoryError.unsafeMethod
    }
}
private actor NativeAssertionAuthority {
    var choices: [SessionIdentity: CollectionAuthorityChoice] = [:]
    func lookup(_ session: SessionIdentity) -> CollectionAuthorityChoice? { choices[session] }
    func record(_ choice: CollectionAuthorityChoice) throws {
        if let previous = choices[choice.session], previous.authorityID != choice.authorityID { throw CodexCollectionError.authorityConflict }
        choices[choice.session] = choice
    }
}


@MainActor
func nativeContentAcceptanceAssertions() async throws -> [String] {
    func check(_ value: Bool, _ label: String) throws {
        guard value else { throw NativeAssertionFailure.failed(label) }
    }
    var checks: [String] = []
    for kind: NativeContentAcceptance.FixtureKind in [.mcp, .hookPrompt, .plan, .localImage] {
    let crypto = try BackgroundCryptography.ephemeralForTesting()
    let threadID = UUID().uuidString.lowercased(), turnID = UUID().uuidString.lowercased()
    let text = kind == .plan ? "# Harmless plan é🙂\r\n1. Read nothing.\n2. Finish.\n"
        : NativeContentAcceptance.expectedText(kind).values.sorted().joined(separator: "\n")
    let segments: [NativeContentAcceptance.Segment] = kind == .plan
        ? [.init(pointer: "/text", textSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
                 textBytes: text.utf8.count)]
        : NativeContentAcceptance.expectedSegments(kind)
    let descriptor = NativeContentAcceptance.Descriptor(schemaVersion: 1, fixtureKind: kind,
        threadID: threadID, turnID: turnID, itemID: turnID + "-fixture", producerVersion: "0.162.1",
        hookRunID: kind == .hookPrompt ? "owned-hook-run" : "", segments: segments,
        imageSHA256: kind == .localImage ? NativeContentAcceptance.imageSHA256 : nil)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let descriptorData = try encoder.encode(descriptor)
    try check(NativeContentAcceptance.Descriptor.decode(descriptorData) == descriptor, "native-exact-private-descriptor")
    for invalid in [descriptorData + Data([10]), Data("{}".utf8),
        Data(String(decoding: descriptorData, as: UTF8.self).replacingOccurrences(of: "0.162.1", with: "0.162.2").utf8),
        Data(String(decoding: descriptorData, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1").utf8)] {
        do { _ = try NativeContentAcceptance.Descriptor.decode(invalid); throw NativeAssertionFailure.failed("native-descriptor-accepted-invalid") }
        catch is NativeAssertionFailure { throw NativeAssertionFailure.failed("native-descriptor-accepted-invalid") }
        catch { }
    }
    if kind == .localImage {
        let invalid = Data(String(decoding: descriptorData, as: UTF8.self).replacingOccurrences(
            of: NativeContentAcceptance.imageSHA256, with: String(repeating: "0", count: 64)).utf8)
        do { _ = try NativeContentAcceptance.Descriptor.decode(invalid); throw NativeAssertionFailure.failed("native-media-invalid-image-hash") }
        catch NativeContentAcceptance.Failure.unsafeConfiguration { }
    }
    if kind == .plan {
        let original = try JSONSerialization.jsonObject(with: descriptorData) as! [String: Any]
        var invalidDescriptors: [[String: Any]] = []
        for (field, value) in [("turnID", "non-uuid-turn"), ("itemID", "item with spaces"),
                               ("itemID", "é"), ("hookRunID", "unexpected-run")] {
            var invalid = original; invalid[field] = value; invalidDescriptors.append(invalid)
        }
        for segment in [
            NativeContentAcceptance.Segment(pointer: "/other", textSHA256: segments[0].textSHA256, textBytes: text.utf8.count),
            .init(pointer: "/text", textSHA256: String(repeating: "g", count: 64), textBytes: text.utf8.count),
            .init(pointer: "/text", textSHA256: segments[0].textSHA256, textBytes: 0),
            .init(pointer: "/text", textSHA256: segments[0].textSHA256, textBytes: 16_385)
        ] {
            var invalid = original
            invalid["segments"] = try JSONSerialization.jsonObject(with: encoder.encode([segment]))
            invalidDescriptors.append(invalid)
        }
        for count in [0, 2] {
            var invalid = original
            invalid["segments"] = try JSONSerialization.jsonObject(with: encoder.encode(Array(repeating: segments[0], count: count)))
            invalidDescriptors.append(invalid)
        }
        for invalid in invalidDescriptors {
            let data = try JSONSerialization.data(withJSONObject: invalid, options: [.sortedKeys, .withoutEscapingSlashes])
            do { _ = try NativeContentAcceptance.Descriptor.decode(data); throw NativeAssertionFailure.failed("native-plan-invalid-descriptor") }
            catch NativeContentAcceptance.Failure.unsafeConfiguration { }
        }
    }
    let boundary = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("spillcheck-native-witness-\(UUID())")
    try FileManager.default.createDirectory(at: boundary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: boundary) }
    let home = boundary.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    for (name, data) in [("token", Data(repeating: 52, count: 32)), ("native-content-descriptor.json", descriptorData)] {
        let file = boundary.appendingPathComponent(name); try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    let recovery = try DisposableRecoveryConfiguration(arguments: ["--acceptance-recovery-root", boundary.path,
        "--store-directory", boundary.appendingPathComponent("store").path,
        "--acceptance-report", boundary.appendingPathComponent("report").path,
        "--acceptance-finish-file", boundary.appendingPathComponent("finish").path,
        "--acceptance-recovery-token", boundary.appendingPathComponent("token").path,
        "--acceptance-recovery-native-content", "--acceptance-native-content-descriptor", boundary.appendingPathComponent("native-content-descriptor.json").path])
    func configuration(_ home: URL, hosts: Set<AgentInterface> = [.standaloneCLI]) -> CodexCollectionConfiguration {
        .init(profileID: descriptor.profileID, readerVersion: "0.162.1", t3Version: nil, interface: .standaloneCLI,
            authority: .publicNativeItems, home: home, executable: URL(fileURLWithPath: "/usr/bin/true"),
            transcriptRoots: [], activeSources: [], authorizedHosts: hosts)
    }
    let selected = try NativeContentAcceptance.selected(configuration: configuration(home), recovery: recovery)
    try check(selected.session.sessionID == threadID && selected.descriptor == descriptor, "native-private-home-native-descriptor")
    for config in [configuration(boundary), configuration(home, hosts: [.standaloneCLI, .t3]),
        configuration(URL(fileURLWithPath: home.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")))] {
        do { _ = try NativeContentAcceptance.selected(configuration: config, recovery: recovery); throw NativeAssertionFailure.failed("native-unsafe-home") }
        catch NativeContentAcceptance.Failure.unsafeConfiguration { }
    }
    if kind == .localImage {
        try FileManager.default.createDirectory(atPath: selected.producerWorkPath, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    let session = selected.session, now = Date()
    let metadata = try CaptureMetadata(agent: .codex, interface: .standaloneCLI, profileID: session.profileID)
    let audit = try HistoricalAuditContext(reason: .resume, endingAt: now.addingTimeInterval(1))
    func entry(type: String? = nil, item: String? = nil, turn: String? = nil, body: String? = nil, mediaType: String = "localImage", imagePath: String? = nil) -> CodexJSON {
        let native: [String: CodexJSON]
        if kind == .mcp {
            var result = try! NativeContentAcceptance.expectedMCPResult()
            if let body, case .object(var fields) = result { fields["structuredContent"] = .string(body); result = .object(fields) }
            native = ["type": .string(type ?? "mcpToolCall"), "id": .string(item ?? descriptor.itemID),
                "server": .string("spillcheck_opaque_fixture"), "tool": .string("opaque_business_result"),
                "arguments": .object([:]), "status": .string("completed"), "error": .null, "result": result]
        } else if kind == .hookPrompt {
            native = ["type": .string(type ?? "hookPrompt"), "id": .string(item ?? descriptor.itemID),
                "fragments": .array([.object(["text": .string(body ?? NativeContentAcceptance.hookText),
                    "hookRunId": .string(descriptor.hookRunID)])])]
        } else if kind == .localImage {
            native = ["type": .string(type ?? "userMessage"), "id": .string(item ?? descriptor.itemID), "content": .array([
                .object(["type": .string("text"), "text": .string(body ?? NativeContentAcceptance.mediaText), "text_elements": .array([])]),
                .object(["type": .string(mediaType), "path": .string(imagePath ?? selected.producerWorkPath + "/fixture.png"), "detail": .null])])]
        } else {
            native = ["type": .string(type ?? "plan"), "id": .string(item ?? descriptor.itemID),
                "text": .string(body ?? text), "phase": .string("commentary")]
        }
        return .object(["turnId": .string(turn ?? turnID), "completedAtMs": .number(now.timeIntervalSince1970 * 1000), "item": .object(native)])
    }
    let page = CodexHistoryPage(data: [entry()], bytesRead: 512, readerVersion: "0.162.1")
    let nativeThread = CodexThreadRead(thread: .object(["id": .string(threadID), "cliVersion": .string("0.162.1"),
        "cwd": .string(selected.producerWorkPath), "ephemeral": .bool(false)]), bytesRead: 128, readerVersion: "0.162.1")
    let fakeClient = NativeAssertionHistory(thread: nativeThread, page: page)
    let wrapper = NativeContentAcceptanceHistory(client: fakeClient, evidence: selected)
    let returnedThread = try await wrapper.readThread(threadID)
    let returned = try await wrapper.listItems(threadID: threadID, turnID: nil, cursor: nil, limit: 64, direction: .ascending)
    try check(returned.data == page.data && returned.bytesRead == page.bytesRead && returned.readerVersion == page.readerVersion,
        "native-wrapper-passes-original-response")
    let authority = NativeAssertionAuthority()
    let adapter = try CodexAdapter(profileID: session.profileID, agentVersion: "0.162.1", history: wrapper,
        authorityLookup: { await authority.lookup($0) }, authorityRecorder: { try await authority.record($0) })
    let parsed = try await adapter.importPublicItems(returned, thread: returnedThread.thread, observedAt: now,
        provenance: .historical(audit), cryptography: crypto)
    guard parsed.sources.count == 1, let source = parsed.sources.first?.record else { throw NativeAssertionFailure.failed("native-parser-fixture") }
    func batch(_ source: SourceRecord, gaps: [CoverageGap]? = nil) -> CollectionBatch {
        .init(sources: [.init(record: source)], coverageGaps: gaps ?? parsed.coverageGaps, historicalProgress: .init(audit: audit, bytesRead: 640, hasUnreadContent: false),
            observedReaderVersion: "0.162.1")
    }
    func witness() -> NativeContentAcceptance { .init(session: session, descriptor: descriptor, producerWorkPath: selected.producerWorkPath) }
    var store = try await ProtectedStore.open(at: boundary.appendingPathComponent("protected"), cryptography: crypto)
    try await selected.captureInitial(await store.snapshot(), cryptography: crypto)
    await selected.observe(batch(source), metadata: metadata, path: .publicHistory, cryptography: crypto)
    let pending = try await selected.report(snapshot: await store.snapshot(), payloadRows: 0, cryptography: crypto)
    try check(pending.initialStoreEmpty && pending.nativeTargetVerified && pending.observedTargetSourceCount == 1
        && pending.committedTargetSourceCount == 0 && pending.targetReceiptDigests.isEmpty,
        "native-native-and-normalized-observation-is-not-scan")
    guard let permit = await store.processingPermit() else { throw NativeAssertionFailure.failed("native-permit") }
    let analysis = try SourceAnalysis(source: source, detectorVersion: BetterleaksSecretDetector.version, detections: [])
    _ = try await store.commit(analysis, payloads: [], permit: permit)
    for gap in parsed.coverageGaps { try await store.recordCoverageGap(gap) }
    func storedGaps(_ store: ProtectedStore) async throws -> [CoverageGap] {
        try await store.coverageGapEvents(limit: 129).items.map(\.gap)
    }
    let committed = try await selected.report(snapshot: await store.snapshot(), payloadRows: 0, gaps: storedGaps(store), cryptography: crypto)
    try check(committed.allObservedTargetSourcesCommitted && committed.cleanInventory && committed.targetSegmentCount == descriptor.segments.count
        && committed.targetTextBytes == descriptor.textBytes && committed.targetReceiptDigests == committed.receiptDigests,
        "native-binds-native-original-bytes-to-full-receipt")
    let publicJSON = String(decoding: try JSONEncoder().encode(committed), as: UTF8.self)
    try check(!publicJSON.contains(threadID) && !publicJSON.contains(turnID) && !publicJSON.contains(text)
        && !publicJSON.contains(descriptor.segments[0].textSHA256), "native-report-only-keyed-identities-and-counts")
    try await store.close()
    store = try await ProtectedStore.open(at: boundary.appendingPathComponent("protected"), cryptography: crypto)
    let cold = witness()
    try await cold.captureInitial(await store.snapshot(), cryptography: crypto)
    let beforeRead = try await cold.report(snapshot: await store.snapshot(), payloadRows: 0, gaps: storedGaps(store), cryptography: crypto)
    try check(!beforeRead.initialStoreEmpty && !beforeRead.nativeTargetVerified && beforeRead.observedTargetSourceCount == 0
        && beforeRead.targetReceiptDigests.isEmpty && beforeRead.initialReceiptDigests == committed.receiptDigests
        && beforeRead.initialSourceKindDigests == committed.sourceKindDigests
        && beforeRead.initialSourceTimeDigests == committed.sourceTimeDigests
        && beforeRead.initialConversationLabelDigests == committed.conversationLabelDigests,
        "native-cold-full-state-not-new-read")
    let coldWrapper = NativeContentAcceptanceHistory(client: fakeClient, evidence: cold)
    let coldPage = try await coldWrapper.listItems(threadID: threadID, turnID: nil, cursor: nil, limit: 64, direction: .ascending)
    let reread = try await adapter.importPublicItems(coldPage, thread: nativeThread.thread, observedAt: now,
        provenance: .historical(audit), cryptography: crypto)
    await cold.observe(batch(reread.sources[0].record), metadata: metadata, path: .publicHistory, cryptography: crypto)
    guard let replayPermit = await store.processingPermit() else { throw NativeAssertionFailure.failed("native-replay-permit") }
    let transition = try await store.commit(analysis, payloads: [], permit: replayPermit)
    for gap in reread.coverageGaps { try await store.recordCoverageGap(gap) }
    let replay = try await cold.report(snapshot: await store.snapshot(), payloadRows: 0, gaps: storedGaps(store), cryptography: crypto)
    try check(transition.outcome == .replay && replay.allObservedTargetSourcesCommitted
        && replay.targetResultDigests == committed.targetResultDigests && replay.receiptDigests == committed.receiptDigests
        && replay.sourceKindDigests == committed.sourceKindDigests && replay.sourceTimeDigests == committed.sourceTimeDigests
        && replay.conversationLabelDigests == committed.conversationLabelDigests, "native-native-reread-keeps-durable-state")
    if kind == .localImage {
        guard parsed.coverageGaps.count == 1, let gap = parsed.coverageGaps.first else { throw NativeAssertionFailure.failed("media-exact-gap-required") }
        try check(selected.acceptsGap(gap) && committed.expectedExcludedGapCount == 1
            && committed.excludedGapEventCount == 1 && committed.onlyExpectedExcludedMedia == true,
            "native-media-exact-persisted-exclusion")
        try check(beforeRead.expectedExcludedGapDigests == committed.expectedExcludedGapDigests
            && replay.expectedExcludedGapDigests == committed.expectedExcludedGapDigests
            && replay.expectedExcludedGapCount == 1 && replay.excludedGapEventCount == 2,
            "native-media-cold-and-replayed-persisted-exclusion-identity")
        let missing = try await cold.report(snapshot: await store.snapshot(), payloadRows: 0, cryptography: crypto)
        try check(!missing.allObservedTargetSourcesCommitted, "native-media-exclusion-cannot-be-silently-dropped")
        try check(!publicJSON.contains(selected.producerWorkPath) && !publicJSON.contains(NativeContentAcceptance.imageSHA256), "native-media-report-no-path-or-image-hash")
        for invalid in [entry(mediaType: "localAudio"), entry(imagePath: "/other.png")] {
            do { try witness().verifyItems(.init(data: [invalid], readerVersion: "0.162.1")); throw NativeAssertionFailure.failed("media-wrong-attachment-accepted") }
            catch is NativeContentAcceptance.Failure { }
        }
        for gaps in [[], [CoverageGap(reason: .unsupportedContent, excludedContent: true)], [gap, gap], [gap, CoverageGap(reason: .sourceUnavailable)]] {
            let invalid = witness(); try await invalid.captureInitial(InventorySnapshot(), cryptography: crypto); try invalid.verifyItems(page)
            await invalid.observe(batch(source, gaps: gaps), metadata: metadata, path: .publicHistory, cryptography: crypto)
            try check(invalid.failure != nil, "native-media-missing-duplicate-or-unrelated-exclusion-rejected")
        }
        for file in [home.appendingPathComponent("auth.json"), URL(fileURLWithPath: selected.producerWorkPath + "/fixture.png")] {
            try Data("fake-only".utf8).write(to: file)
            do { try witness().verifyItems(page); throw NativeAssertionFailure.failed("media-existing-auth-or-image-accepted") }
            catch NativeContentAcceptance.Failure.unsafeState { }
            try FileManager.default.removeItem(at: file)
        }
        let turn: CodexJSON = .object(["id": .string(turnID), "status": .string("completed"), "error": .null,
            "startedAt": .number(now.timeIntervalSince1970 - 1), "completedAt": .number(now.timeIntervalSince1970 + 1)])
        try selected.verifyTurns(.init(data: [turn], readerVersion: "0.162.1"))
        do { try witness().verifyTurns(.init(data: [], readerVersion: "0.162.1")); throw NativeAssertionFailure.failed("media-incomplete-turn-accepted") }
        catch NativeContentAcceptance.Failure.foreignSource { }
        checks.append("local-image:exact-exclusion-persists-without-auth-image-or-duplicate-source")
    }
    try await store.close()
    for invalid in [entry(type: "agentMessage"), entry(item: "different-native-item"), entry(turn: UUID().uuidString.lowercased()),
        entry(body: text + "changed")] {
        let other = witness()
        do {
            try other.verifyItems(.init(data: [invalid], readerVersion: "0.162.1"))
            throw NativeAssertionFailure.failed("native-accepted-echo-or-mismatched-native-source")
        } catch is NativeContentAcceptance.Failure { }
    }
    let unobserved = witness()
    try await unobserved.captureInitial(InventorySnapshot(), cryptography: crypto)
    await unobserved.observe(batch(source), metadata: metadata, path: .publicHistory, cryptography: crypto)
    try check(unobserved.failure == .invalidNativeContent, "native-normalized-echo-without-native-proof-rejected")
    for version in [BetterleaksSecretDetector.version + "+partial", BetterleaksSecretDetector.version + "+reduced", "wrong-detector"] {
        let invalidReceipt = AnalysisReceipt(source: source.metadata.identity, revision: source.revision, detectorVersion: version)
        do {
            try await witness().captureInitial(InventorySnapshot(analysisReceipts: [invalidReceipt],
                sourceKinds: [source.metadata.identity: descriptor.contentType], sourceTimes: [source.metadata.identity: now]), cryptography: crypto)
            throw NativeAssertionFailure.failed("native-degraded-receipt-accepted")
        } catch NativeContentAcceptance.Failure.receiptMismatch { }
    }
    let wrongRevision = try await crypto.revision(canonicalBytes: Data("wrong revision".utf8))
    let unmatched = try await selected.report(snapshot: InventorySnapshot(analysisReceipts: [
        .init(source: source.metadata.identity, revision: wrongRevision, detectorVersion: BetterleaksSecretDetector.version)],
        sourceKinds: [source.metadata.identity: descriptor.contentType], sourceTimes: [source.metadata.identity: now]),
        payloadRows: 0, cryptography: crypto)
    try check(!unmatched.allObservedTargetSourcesCommitted && unmatched.targetReceiptDigests.isEmpty, "native-wrong-revision-does-not-commit")
    let corrupt = try SourceRecord(metadata: source.metadata, revision: wrongRevision, segments: source.segments)
    let invalidNormalized = witness()
    try await invalidNormalized.captureInitial(InventorySnapshot(), cryptography: crypto)
    try invalidNormalized.verifyItems(page)
    await invalidNormalized.observe(batch(corrupt), metadata: metadata, path: .publicHistory, cryptography: crypto)
    try check(invalidNormalized.failure == .invalidNativeContent, "native-corrupt-normalized-revision-rejected")
    let shortSegments: [SourceSegment]
    if kind == .mcp { shortSegments = Array(source.segments.dropLast()) }
    else { shortSegments = [try SourceSegment(id: source.segments[0].id, utf8: Data("changed fixture".utf8))] }
    let shortened = try SourceRecord(metadata: source.metadata,
        revision: try await crypto.revision(canonicalBytes: WebResultAcceptance.canonicalSegments(shortSegments)),
        segments: shortSegments)
    let incomplete = witness()
    try await incomplete.captureInitial(InventorySnapshot(), cryptography: crypto)
    try incomplete.verifyItems(page)
    await incomplete.observe(batch(shortened), metadata: metadata, path: .publicHistory, cryptography: crypto)
    try check(incomplete.failure == .invalidNativeContent, "native-incomplete-segment-projection-rejected")
    if kind == .hookPrompt {
        let multipleTurns = witness()
        let unrelated: CodexJSON = .object(["turnId": .string("rollout-1"), "item": .object(["type": .string("userMessage"), "id": .string("ordinary-input"), "content": .array([])])])
        try multipleTurns.verifyItems(.init(data: [unrelated, entry()], readerVersion: "0.162.1"))
        try multipleTurns.verifyTurns(.init(data: [.object(["id": .string("rollout-1"), "startedAt": .null, "completedAt": .null])], readerVersion: "0.162.1"))
        try check(multipleTurns.nativeReadCount == 1 && multipleTurns.failure == nil, "native-hook-preserves-target-with-unrelated-null-turn")
    }
    if kind == .plan {
        let paged = witness()
        try paged.verifyItems(.init(data: [], nextCursor: "later", readerVersion: "0.162.1"))
        try check(paged.nativeReadCount == 0, "native-plan-nontarget-page-is-not-proof")
        try paged.verifyItems(page)
        try check(paged.nativeReadCount == 1 && paged.failure == nil, "native-plan-proof-survives-pagination")
    }
    let foreign = witness()
    do { try foreign.checkSelection(UUID().uuidString.lowercased()); throw NativeAssertionFailure.failed("native-foreign-selection") }
    catch NativeContentAcceptance.Failure.foreignSource { }
    checks += ["native-native-kind-source-and-byte-proof-before-full-receipt",
        "native-private-canonical-descriptor-and-owned-home",
        "native-rejects-assistant-echo-wrong-turn-item-hash-and-revision",
        "native-cold-full-ledger-is-not-new-observation",
        "native-reread-preserves-full-receipts-kinds-times-labels",
        "native-rejects-partial-reduced-unmatched-and-foreign-evidence"].map { kind.rawValue + ":" + $0 }
    }
    return checks
}
