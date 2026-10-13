import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private let entryValue = "SPILLCHECK_FAKE_PAGINATED_ENTRY_42"
private let entryDetectorVersion = "entry-inspection-fixture-v1"

private actor EntryInspectionHistory: CodexHistoryReading {
    var turns: [CodexJSON]
    var items: [CodexJSON]
    let entry: CodexJSON
    var alternateTurns: [CodexJSON]?
    var alternateItems: [CodexJSON]?
    var mutationAt: Int?
    var inspectCalls = 0
    var selectedIDs: Set<String> = []
    var requests: [(Bool, String?, Int)] = []
    var budgets: [Int] = []
    var timeoutCalls: Set<Int> = []
    var cycleTurns = false
    var changedReader = false
    init(turns: [CodexJSON], items: [CodexJSON], entry: CodexJSON) { self.turns = turns; self.items = items; self.entry = entry }
    func mutate(at: Int, turns: [CodexJSON]? = nil, items: [CodexJSON]? = nil) {
        mutationAt = at; alternateTurns = turns; alternateItems = items
    }
    func configure(timeouts: Set<Int> = [], cycle: Bool = false, reader: Bool = false) {
        timeoutCalls = timeouts; cycleTurns = cycle; changedReader = reader
    }
    func readThread(_ id: String) throws -> CodexThreadRead {
        selectedIDs.insert(id)
        guard id == "parent" else { throw CodexHistoryError.unavailable }
        return .init(thread: try codexThread(producer: "0.162.1"), bytesRead: 10, readerVersion: "0.162.1")
    }
    func listThreads(cursor: String?, limit: Int, archived: Bool) throws -> CodexHistoryPage { throw CodexHistoryError.unavailable }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection) throws -> CodexHistoryPage {
        try result(threadID: threadID, items: false, cursor: cursor, limit: limit, direction: direction)
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int,
                   direction: CodexHistoryDirection) throws -> CodexHistoryPage {
        guard turnID == nil else { throw CodexHistoryError.rejectedParameters("ENTRY requires whole parent") }
        return try result(threadID: threadID, items: true, cursor: cursor, limit: limit, direction: direction)
    }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection,
                   budget: CodexRPCBudget) throws -> CodexHistoryPage {
        budgets.append(budget.maximumBytes)
        return try listTurns(threadID: threadID, cursor: cursor, limit: limit, direction: direction)
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int,
                   direction: CodexHistoryDirection, budget: CodexRPCBudget) throws -> CodexHistoryPage {
        budgets.append(budget.maximumBytes)
        return try listItems(threadID: threadID, turnID: turnID, cursor: cursor, limit: limit, direction: direction)
    }
    private func result(threadID: String, items readingItems: Bool, cursor: String?, limit: Int,
                        direction: CodexHistoryDirection) throws -> CodexHistoryPage {
        selectedIDs.insert(threadID)
        guard threadID == "parent" else { throw CodexHistoryError.unavailable }
        let offset = Int(cursor ?? "0") ?? -1
        guard offset >= 0 else { throw CodexHistoryError.malformedResponse }
        if direction == .descending {
            let rows = readingItems ? [entry] + items.filter { $0["item"]["id"].string != entry["item"]["id"].string } : turns
            return page(rows, offset: offset, limit: limit)
        }
        inspectCalls += 1; requests.append((readingItems, cursor, limit))
        if timeoutCalls.contains(inspectCalls) { throw CodexHistoryError.timedOut }
        let changed = mutationAt.map { inspectCalls >= $0 } ?? false
        let rows = readingItems ? (changed ? alternateItems ?? items : items) : (changed ? alternateTurns ?? turns : turns)
        let result = page(rows, offset: offset, limit: limit)
        return .init(data: result.data, nextCursor: cycleTurns && !readingItems ? "0" : result.nextCursor,
            bytesRead: result.bytesRead, readerVersion: changedReader ? "0.163.0" : "0.162.1")
    }
    private func page(_ rows: [CodexJSON], offset: Int, limit: Int) -> CodexHistoryPage {
        let selected = Array(rows.dropFirst(offset).prefix(limit))
        let next = offset + selected.count < rows.count ? String(offset + selected.count) : nil
        return .init(data: selected, nextCursor: next, bytesRead: 50, readerVersion: "0.162.1")
    }
    func observations() -> (Int, Set<String>, [Int]) { (inspectCalls, selectedIDs, budgets) }
}

private actor EntryDetector: SecretDetector {
    let partial: Bool
    var calls = 0
    init(partial: Bool = false) { self.partial = partial }
    func scan(_ source: SourceRecord) throws -> DetectorOutput {
        calls += 1
        var findings: [DetectorFinding] = []
        for segment in source.segments {
            if let range = segment.utf8.range(of: Data(entryValue.utf8)) {
                let location = try CanonicalLocation(segmentID: segment.id, range: .init(range.lowerBound, range.upperBound))
                findings.append(try .init(extraction: .init(valueUTF8: Data(entryValue.utf8), location: location, in: source), evidence: [evidence()]))
            }
        }
        return .init(detectorVersion: entryDetectorVersion, findings: findings, unlocated: [],
            coverageGaps: partial ? [.init(reason: .scannerUnavailable)] : [])
    }
}

@Suite("Codex paginated review input inspection", .timeLimit(.minutes(1)))
struct CodexReviewEntryInspectionTests {
    private let now = Date(timeIntervalSince1970: 1_791_434_500)
    private func turn(_ id: String, root: Any = "review") throws -> CodexJSON {
        try codexJSON(["id": id, "rootTurnId": root, "startedAt": 1_791_434_390, "completedAt": 1_791_434_400])
    }
    private func user(_ id: String = "input", turn: String = "input-turn", text: String = entryValue,
                      timestamp: Double? = 1_791_434_400_000, malformed: Bool = false) throws -> CodexJSON {
        var value: [String: Any] = ["turnId": turn, "item": ["type": "userMessage", "id": id,
            "content": malformed ? NSNull() : [["type": "text", "text": text]]] as [String: Any]]
        if let timestamp { value["completedAtMs"] = timestamp }
        return try codexJSON(value)
    }
    private func entry(_ id: String = "entry", turn: String = "review", timestamp: Double? = 1_791_434_400_000) throws -> CodexJSON {
        var value: [String: Any] = ["turnId": turn, "item": ["type": "enteredReviewMode", "id": id, "review": entryValue]]
        if let timestamp { value["completedAtMs"] = timestamp }
        return try codexJSON(value)
    }
    private func fixture(reverse: Bool = false, timestamp: Double? = 1_791_434_400_000) throws -> EntryInspectionHistory {
        let input = try user(timestamp: timestamp), presentation = try entry(timestamp: timestamp)
        return try .init(turns: reverse ? [turn("input-turn"), turn("review")] : [turn("review"), turn("input-turn")],
            items: reverse ? [presentation, input] : [input, presentation], entry: presentation)
    }
    private func adapter(_ history: EntryInspectionHistory, budget: HistoryReadBudget = .init(), pageSize: Int = 1) throws -> CodexAdapter {
        let authority = CodexTestAuthority()
        return try .init(profileID: "entry-test", agentVersion: "0.162.1", interface: .standaloneCLI,
            authority: .publicNativeItems, history: history, limits: .init(pageSize: pageSize), historyBudget: budget,
            authorityLookup: { await authority.lookup($0) }, authorityRecorder: { try await authority.record($0) })
    }
    private func packet(_ adapter: CodexAdapter, now: Date? = nil) throws -> CapturePacket {
        var request = CodexHistoryRequest(audit: try .init(reason: .restart, endingAt: now ?? self.now), threads: ["parent"])
        request.selectedSourceOnly = true
        return try adapter.packet(request)
    }
    private func batches(_ adapter: CodexAdapter, initial: CapturePacket, crypto: BackgroundCryptography) async throws -> [CollectionBatch] {
        var next: CapturePacket? = initial, output: [CollectionBatch] = []
        for _ in 0..<45 {
            guard let selected = next else { return output }
            let batch = try await adapter.normalize(selected, capturedAt: now, cryptography: crypto)
            output.append(batch)
            if !batch.pendingRecoveryDependencies.isEmpty { return output }
            next = batch.continuation
        }
        Issue.record("bounded ENTRY fixture did not finish")
        return output
    }

    @Test(arguments: [false, true])
    func bothStreamOrdersRetainActualInputIdentityAndOnlyCommitments(reverse: Bool) async throws {
        let history = try fixture(reverse: reverse), adapter = try adapter(history)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let result = try await batches(adapter, initial: packet(adapter), crypto: crypto)
        let final = try #require(result.last)
        #expect(final.pendingRecoveryDependencies.count == 1)
        #expect(final.sources.map(\.record.metadata.identity.itemID) == ["input"])
        #expect(final.sources.first?.record.metadata.identity.session.sessionID == "parent")
        #expect(final.sources.first?.record.metadata.contentType == .userPrompt)
        #expect(final.sources.first?.record.segments.map(\.id) == ["/content/0/text"])
        #expect(final.sources.first?.record.segments.first?.utf8 == Data(entryValue.utf8))
        #expect(final.pendingRecoveryDependencies.first?.provisionalGap.recovery?.itemID == "entry")
        #expect(final.continuation != nil && final.unresolvedRecoveryContinuation != nil)
        let observations = await history.observations()
        #expect(observations.0 == 12 && observations.1 == ["parent"])
        for batch in result.dropLast() {
            let continuation = try #require(batch.continuation)
            #expect(continuation.eventJSON.range(of: Data(entryValue.utf8)) == nil)
            let decoded = try JSONDecoder().decode(CodexHistoryRequest.self, from: continuation.eventJSON)
            #expect(decoded.partial == false && decoded.threadPartial == false)
        }
        let succeeded = try await adapter.normalize(#require(final.continuation), capturedAt: now, cryptography: crypto)
        let failed = try await adapter.normalize(#require(final.unresolvedRecoveryContinuation), capturedAt: now, cryptography: crypto)
        #expect(succeeded.continuation == nil && succeeded.historicalProgress?.hasUnreadContent == false)
        #expect(failed.continuation == nil && failed.historicalProgress?.hasUnreadContent == true)
    }

    @Test(arguments: ["nonmatching", "malformed", "unknown-root", "missing-turn", "duplicate-turn", "missing-root", "second-entry"])
    func fullRootGroupRejectsAmbiguityAndUnknownMembership(kind: String) async throws {
        let presentation = try entry(), input = try user()
        var turns = try [turn("review"), turn("input-turn")], items = [input, presentation]
        switch kind {
        case "nonmatching", "malformed":
            turns.append(try turn("later"))
            items.append(try user("second", turn: "later", text: "different text", malformed: kind == "malformed"))
        case "unknown-root":
            turns.append(try turn("unknown", root: NSNull())); items.append(try user("other", turn: "unknown", text: "other"))
        case "missing-turn": items.append(try user("other", turn: "absent", text: "other"))
        case "duplicate-turn": turns.append(try turn("input-turn"))
        case "missing-root": turns[1] = try codexJSON(["id": "input-turn"])
        case "second-entry": turns.append(try turn("nested")); items.append(try entry("second-entry", turn: "nested"))
        default: break
        }
        let history = EntryInspectionHistory(turns: turns, items: items, entry: presentation), adapter = try adapter(history)
        let result = try await batches(adapter, initial: packet(adapter), crypto: BackgroundCryptography.ephemeralForTesting())
        #expect(result.allSatisfy { $0.pendingRecoveryDependencies.isEmpty })
        #expect(result.last?.continuation == nil && result.last?.historicalProgress?.hasUnreadContent == true)
        #expect(result.contains { $0.coverageGaps.contains { $0.recovery?.itemID == "entry" } })
    }

    @Test func sameTextInExplicitOtherRootDoesNotBecomeTheOriginal() async throws {
        let presentation = try entry()
        let history = try EntryInspectionHistory(turns: [turn("review"), turn("input-turn"), turn("other", root: "other")],
            items: [user("other-input", turn: "other"), user(), presentation], entry: presentation)
        let adapter = try adapter(history)
        let result = try await batches(adapter, initial: packet(adapter), crypto: BackgroundCryptography.ephemeralForTesting())
        #expect(result.last?.pendingRecoveryDependencies.count == 1)
        #expect(result.last?.sources.first?.record.metadata.identity.itemID == "input")
    }

    @Test(arguments: ["root", "new-user", "final-item", "final-turn"])
    func mutationsAcrossPassesAndFinalRereadsCannotRecover(kind: String) async throws {
        let history = try fixture()
        switch kind {
        case "root": await history.mutate(at: 5, turns: try [turn("review"), turn("input-turn", root: "other")])
        case "new-user": await history.mutate(at: 5, items: try [user(), user("second", text: "different"), entry()])
        case "final-item": await history.mutate(at: 9, items: try [user(text: "changed"), entry()])
        case "final-turn": await history.mutate(at: 9, turns: try [turn("review"), turn("input-turn", root: "other")])
        default: break
        }
        let adapter = try adapter(history)
        let result = try await batches(adapter, initial: packet(adapter), crypto: BackgroundCryptography.ephemeralForTesting())
        #expect(result.allSatisfy { $0.pendingRecoveryDependencies.isEmpty })
        #expect(result.last?.historicalProgress?.hasUnreadContent == true)
    }

    @Test func cursorCyclesReaderChangesAndRetryExhaustionRemainBounded() async throws {
        for failure in ["cycle", "reader", "timeout"] {
            let history = try fixture()
            await history.configure(timeouts: failure == "timeout" ? [1, 2, 3] : [], cycle: failure == "cycle", reader: failure == "reader")
            let adapter = try adapter(history)
            let result = try await batches(adapter, initial: packet(adapter), crypto: BackgroundCryptography.ephemeralForTesting())
            #expect(result.allSatisfy { $0.pendingRecoveryDependencies.isEmpty })
            #expect(result.last?.continuation == nil && result.last?.historicalProgress?.hasUnreadContent == true)
            #expect(await history.observations().0 <= 3)
        }
    }

    @Test func fourPageFinalReadSharesAggregateByteAndSourceBudget() async throws {
        for allowed in [false, true] {
            let history = try fixture(), budget = HistoryReadBudget(maximumBytes: allowed ? 300 : 160,
                maximumDuration: 2, maximumSources: 4)
            let adapter = try adapter(history, budget: budget)
            let result = try await batches(adapter, initial: packet(adapter), crypto: BackgroundCryptography.ephemeralForTesting())
            #expect((result.last?.pendingRecoveryDependencies.count == 1) == allowed)
            if allowed {
                #expect(Array(await history.observations().2.suffix(4)) == [290, 240, 190, 140])
                #expect(result.last?.historicalProgress?.bytesRead == 210)
            } else {
                #expect(result.contains { $0.coverageGaps.contains { $0.reason == .budgetExhausted && $0.recovery?.itemID == "entry" } })
            }
        }
    }

    @Test func currentNativeTurnRowsSupplyOriginalTimestampWithoutIdentityChanges() async throws {
        let history = try fixture(timestamp: nil), adapter = try adapter(history)
        let result = try await batches(adapter, initial: packet(adapter), crypto: BackgroundCryptography.ephemeralForTesting())
        #expect(result.last?.pendingRecoveryDependencies.count == 1)
        #expect(result.last?.sources.first?.record.metadata.contentTime == Date(timeIntervalSince1970: 1_791_434_390))
        #expect(result.last?.sources.first?.record.metadata.identity.itemID == "input")
    }

    @Test func expiredReboundAndInconsistentStageCannotReuseProof() async throws {
        for invalid in ["expired", "audit", "target", "counter", "stage"] {
            let history = try fixture(), adapter = try adapter(history), crypto = try BackgroundCryptography.ephemeralForTesting()
            let initial = try await adapter.normalize(packet(adapter), capturedAt: now, cryptography: crypto)
            let started = try await adapter.normalize(#require(initial.continuation), capturedAt: now, cryptography: crypto)
            let queued = try #require(started.continuation)
            var json = try #require(JSONSerialization.jsonObject(with: queued.eventJSON) as? [String: Any])
            var work = try #require(json["reviewWork"] as? [String: Any])
            var state = try #require(work["entryInspection"] as? [String: Any])
            if invalid == "expired" { state["startedAt"] = 0 }
            if invalid == "audit" { state["audit"] = nil }
            if invalid == "target" { state["reviewTurnID"] = "wrong" }
            if invalid == "counter" {
                var pass = try #require(state["pass"] as? [String: Any])
                pass["groupUsers"] = 2; state["pass"] = pass
            }
            if invalid == "stage" { state["stage"] = "verify" }
            work["entryInspection"] = state; json["reviewWork"] = work
            let altered = try CapturePacket(metadata: queued.metadata, eventJSON: JSONSerialization.data(withJSONObject: json))
            let result = try await adapter.normalize(altered, capturedAt: now, cryptography: crypto)
            #expect(result.pendingRecoveryDependencies.isEmpty && result.historicalProgress?.hasUnreadContent == true)
            #expect(await history.observations().0 == 1)
        }
    }

    @Test func onePageHelperAlsoRejectsSecondEntryElsewhereInRootGroup() async throws {
        let presentation = try entry(), nested = try entry("nested-entry", turn: "nested"), input = try user()
        let history = try EntryInspectionHistory(turns: [turn("review"), turn("input-turn"), turn("nested")],
            items: [input, presentation, nested], entry: presentation)
        let adapter = try adapter(history, pageSize: 64), crypto = try BackgroundCryptography.ephemeralForTesting()
        let first = try await adapter.normalize(packet(adapter), capturedAt: now, cryptography: crypto)
        #expect(first.pendingRecoveryDependencies.isEmpty)
        #expect(first.coverageGaps.filter { $0.sourceKind == .codexUnknownItem }.count == 2)
    }

    @Test(arguments: [false, true])
    func encryptedEntryContinuationRestartsAndRequiresFullOriginalReceipt(partial: Bool) async throws {
        let current = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let history = try fixture(timestamp: current.addingTimeInterval(-30).timeIntervalSince1970 * 1000)
        let adapter = try adapter(history), crypto = try BackgroundCryptography.ephemeralForTesting()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-entry-inspection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let initial = try packet(adapter, now: current)
        let audit = try #require(JSONDecoder().decode(CodexHistoryRequest.self, from: initial.eventJSON).audit)
        let scope = CollectionScope(provider: .codex, profileID: "entry-test", interface: .standaloneCLI, path: .publicHistory)
        let context = try CollectionCaptureRoute(scope: scope).context(for: initial, trigger: .historyRequest, audit: audit)
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(initial.body, capturedAt: current, permit: permit, at: current, historicalAudit: audit, workContext: context)
        let unrelated = CoverageGap(reason: .sourceUnavailable, scope: scope, operation: .historicalRead,
            recovery: .init(session: try SessionIdentity(provider: .codex, profileID: "entry-test", sessionID: "parent"),
                itemID: "unrelated", parserContract: CodexAdapter.parserContract))
        try await store.recordCoverageGap(unrelated, at: current)
        let detector = EntryDetector(partial: partial)
        var pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
            detector: detector, detectorVersion: entryDetectorVersion, liveSince: current)
        #expect(try await pipeline.processNext(at: current) == .processed)
        #expect(try await pipeline.processNext(at: current.addingTimeInterval(1)) == .processed)
        #expect(await history.observations().0 == 1)
        #expect(await store.snapshot().analysisReceipts.isEmpty)
        #expect(try await store.queueStatistics().count == 1)
        try await store.close()
        try inspectEntryFiles(directory)
        store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
            detector: detector, detectorVersion: entryDetectorVersion, liveSince: current)
        for _ in 0..<30 {
            if try await store.queueStatistics().count == 0 { break }
            #expect(try await pipeline.processNext(at: current.addingTimeInterval(2)) == .processed)
        }
        #expect(try await store.queueStatistics().count == 0)
        let snapshot = await store.snapshot()
        #expect(snapshot.occurrences.count == 1)
        #expect(snapshot.occurrences.values.first?.source.identity.itemID == "input")
        #expect(snapshot.analysisReceipts.allSatisfy { partial ? $0.detectorVersion != entryDetectorVersion : $0.detectorVersion == entryDetectorVersion })
        let unresolved = try await store.coverageOmissions()
        #expect(unresolved.contains { $0.gap.recovery?.itemID == "unrelated" })
        #expect(unresolved.contains { $0.gap.recovery?.itemID == "entry" } == partial)
        #expect(try await store.historicalProgress().first?.progress.hasUnreadContent == partial)
        if !partial { #expect(await detector.calls == 1) }
        try await store.close()
    }
}

private func inspectEntryFiles(_ directory: URL) throws {
    let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        #expect(try Data(contentsOf: file).range(of: Data(entryValue.utf8)) == nil)
    }
}
