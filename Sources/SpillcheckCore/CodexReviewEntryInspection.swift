import Foundation

/// Only keyed row/identity commitments and native coordinates survive a capture.
/// Turn membership is observed, never inferred from matching input text.
struct CodexReviewEntryMembership: Codable, Sendable {
    var selected: Set<ContentRevision> = []
    var other: Set<ContentRevision> = []
    var unknown: Set<ContentRevision> = []
    var count: Int { selected.count + other.count + unknown.count }
    func contains(_ id: ContentRevision) -> Bool { selected.contains(id) || other.contains(id) || unknown.contains(id) }
    var disjoint: Bool { selected.isDisjoint(with: other) && selected.isDisjoint(with: unknown) && other.isDisjoint(with: unknown) }
}

struct CodexReviewEntryRows: Codable, Sendable {
    var chain: ContentRevision?
    var count = 0
    var pageCount = 0
    var bytesRead = 0
    var seenItems: Set<ContentRevision> = []
    var seenCursors: Set<ContentRevision> = []
}

struct CodexReviewEntryItem: Codable, Equatable, Sendable {
    let turnID: String
    let coordinate: CodexReviewCoordinate
}

struct CodexReviewEntryPass: Codable, Sendable {
    var turns = CodexReviewEntryRows()
    var items = CodexReviewEntryRows()
    var membership = CodexReviewEntryMembership()
    var reviewTurn: CodexReviewCoordinate?
    var originalTurn: CodexReviewCoordinate?
    var original: CodexReviewEntryItem?
    var presentation: CodexReviewEntryItem?
    var groupUsers = 0
    var groupEntries = 0
}

struct CodexReviewEntrySummary: Codable, Equatable, Sendable {
    let turnChain: ContentRevision?
    let turnCount: Int
    let turnPages: Int
    let itemChain: ContentRevision?
    let itemCount: Int
    let itemPages: Int
    let reviewTurn: CodexReviewCoordinate?
    let original: CodexReviewEntryItem?
    let presentation: CodexReviewEntryItem?
    let groupUsers: Int
    let groupEntries: Int
    init(_ pass: CodexReviewEntryPass) {
        turnChain = pass.turns.chain; turnCount = pass.turns.count; turnPages = pass.turns.pageCount
        itemChain = pass.items.chain; itemCount = pass.items.count; itemPages = pass.items.pageCount
        reviewTurn = pass.reviewTurn; original = pass.original; presentation = pass.presentation
        groupUsers = pass.groupUsers; groupEntries = pass.groupEntries
    }
}

struct CodexReviewEntryInspectionState: Codable, Sendable {
    enum Stage: String, Codable, Sendable { case firstTurns, firstItems, secondTurns, secondItems, verify }
    let generation: UUID
    let startedAt: Date
    let parserContract: String
    let authorityID: String
    let profileID: String
    let threadID: String
    let reviewTurnID: String
    let targetItemID: String
    let targetRevision: ContentRevision
    let audit: HistoricalAuditContext?
    let pageSize: Int
    var readerVersion: String?
    var stage = Stage.firstTurns
    var cursor: String?
    var pass = CodexReviewEntryPass()
    var firstPass: CodexReviewEntrySummary?
    var transportFailures = 0

    init(profileID: String, threadID: String, target: CodexReviewTarget, audit: HistoricalAuditContext?, pageSize: Int) {
        generation = UUID(); startedAt = Date(); parserContract = CodexAdapter.parserContract
        authorityID = CodexCollectionAuthority.publicNativeItems.rawValue
        self.profileID = profileID; self.threadID = threadID; self.audit = audit; self.pageSize = pageSize
        reviewTurnID = target.turnID; targetItemID = target.itemID; targetRevision = target.rowRevision
    }
}

private enum CodexReviewEntryFailure: Error { case unresolved }

extension CodexAdapter {
    func normalizeReviewEntryInspection(_ original: CodexHistoryRequest, work admittedWork: CodexReviewWork,
                                       target: CodexReviewTarget, threadID: String, observedAt: Date,
                                       cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        var work = admittedWork, request = original
        // Final verification can need two item and two turn pages in one capture.
        let pageSize = min(limits.pageSize, max(1, historyBudget.maximumSources / 4))
        var state = work.entryInspection ?? .init(profileID: profileID, threadID: threadID, target: target,
            audit: original.audit, pageSize: pageSize)
        guard validEntryState(state, target: target, threadID: threadID, audit: original.audit) else {
            return try finishReviewInspection(original, observedAt: observedAt, failure: .sourceChanged)
        }
        let initialState = state
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + historyBudget.maximumDuration
        var bytesRead = 0, rowsRead = 0
        func budget() throws -> CodexRPCBudget {
            let bytes = historyBudget.maximumBytes - bytesRead
            let duration = deadline - ProcessInfo.processInfo.systemUptime
            guard bytes > 0, duration > 0 else { throw CodexHistoryError.responseLimitExceeded }
            return try .init(maximumBytes: min(bytes, limits.maximumBytes), timeout: duration)
        }
        func observe(_ version: String?) throws {
            guard let version, !version.isEmpty, version.utf8.count <= 256, !version.utf8.contains(0),
                  state.readerVersion == nil || state.readerVersion == version else { throw CodexReviewInspectionFailure.changed }
            state.readerVersion = version
        }
        func readPage(items: Bool, cursor: String?) async throws -> CodexHistoryPage {
            let page: CodexHistoryPage
            if items {
                page = try await history.listItems(threadID: threadID, turnID: nil, cursor: cursor,
                    limit: state.pageSize, direction: .ascending, budget: budget())
            } else {
                page = try await history.listTurns(threadID: threadID, cursor: cursor,
                    limit: state.pageSize, direction: .ascending, budget: budget())
            }
            try observe(page.readerVersion)
            bytesRead += page.bytesRead; rowsRead += page.data.count
            guard page.bytesRead >= 0, page.data.count <= state.pageSize,
                  rowsRead <= historyBudget.maximumSources, bytesRead <= historyBudget.maximumBytes,
                  ProcessInfo.processInfo.systemUptime <= deadline,
                  page.nextCursor.map(validReviewCursor) ?? true else { throw CodexReviewInspectionFailure.budget }
            return page
        }
        do {
            try Task.checkCancellation()
            try await selectAuthority(sessionID: threadID)
            let metadata = try await history.readThread(threadID, budget: budget())
            try observe(metadata.readerVersion); bytesRead += metadata.bytesRead
            guard metadata.bytesRead >= 0, bytesRead <= historyBudget.maximumBytes,
                  ProcessInfo.processInfo.systemUptime <= deadline,
                  metadata.thread["id"].string == threadID,
                  recordedProducerVersion(metadata.thread["cliVersion"]) == target.producerVersion else {
                throw CodexReviewInspectionFailure.changed
            }
            if state.stage == .verify {
                guard let originalItem = state.pass.original, let presentation = state.pass.presentation,
                      let reviewTurn = state.pass.reviewTurn, let originalTurn = state.pass.originalTurn else {
                    throw CodexReviewInspectionFailure.malformed
                }
                let originalPage = try await readPage(items: true, cursor: originalItem.coordinate.pageCursor)
                let presentationPage = originalItem.coordinate.pageCursor == presentation.coordinate.pageCursor
                    ? originalPage : try await readPage(items: true, cursor: presentation.coordinate.pageCursor)
                let reviewPage = try await readPage(items: false, cursor: reviewTurn.pageCursor)
                let inputTurnPage = reviewTurn.pageCursor == originalTurn.pageCursor
                    ? reviewPage : try await readPage(items: false, cursor: originalTurn.pageCursor)
                for (page, coordinate) in [(originalPage, originalItem.coordinate), (presentationPage, presentation.coordinate),
                                           (reviewPage, reviewTurn), (inputTurnPage, originalTurn)] {
                    guard try await reviewPageCommitment(page, cryptography: cryptography) == coordinate.pageRevision else {
                        throw CodexReviewInspectionFailure.changed
                    }
                }
                let input = try requiredReviewRow(originalPage, id: originalItem.coordinate.itemID)
                let entry = try requiredReviewRow(presentationPage, id: presentation.coordinate.itemID)
                let nativeReviewTurn = try entryTurnRow(reviewPage, coordinate: reviewTurn)
                let nativeInputTurn = try entryTurnRow(inputTurnPage, coordinate: originalTurn)
                guard try await reviewRowMatches(input, coordinate: originalItem.coordinate, turnID: originalItem.turnID,
                          cryptography: cryptography),
                      try await reviewRowMatches(entry, coordinate: presentation.coordinate, turnID: target.turnID,
                          cryptography: cryptography),
                      try await reviewCommitment("row", bytes: reviewCanonical(nativeReviewTurn), cryptography: cryptography) == reviewTurn.rowRevision,
                      try await reviewCommitment("row", bytes: reviewCanonical(nativeInputTurn), cryptography: cryptography) == originalTurn.rowRevision else {
                    throw CodexReviewInspectionFailure.changed
                }
                var times: [String: DateInterval] = [:]
                for turn in [nativeReviewTurn, nativeInputTurn] {
                    if let id = reviewIdentifier(turn["id"]), let start = turn["startedAt"].number,
                       let end = turn["completedAt"].number ?? turn["startedAt"].number,
                       start.isFinite, end.isFinite, end >= start {
                        times[id] = .init(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
                    }
                }
                return try await finishReviewProof(original, originalRow: input, presentationRow: entry,
                    thread: metadata.thread, observedAt: observedAt, bytesRead: bytesRead,
                    readerVersion: state.readerVersion, turnTimes: times, deadline: deadline,
                    entryTurns: (nativeReviewTurn, nativeInputTurn), cryptography: cryptography)
            }
            let items = state.stage == .firstItems || state.stage == .secondItems
            let cursor = state.cursor
            let page = try await readPage(items: items, cursor: cursor)
            if items {
                try await absorbEntryItems(page, cursor: cursor, target: target, state: &state, cryptography: cryptography)
            } else {
                try await absorbEntryTurns(page, cursor: cursor, target: target, state: &state, cryptography: cryptography)
            }
            guard ProcessInfo.processInfo.systemUptime <= deadline else { throw CodexHistoryError.timedOut }
            state.transportFailures = 0
            if let next = page.nextCursor {
                let digest = try await reviewCommitment(items ? "entry-item-cursor" : "entry-turn-cursor",
                    bytes: Data(next.utf8), cryptography: cryptography)
                let inserted = items ? state.pass.items.seenCursors.insert(digest).inserted : state.pass.turns.seenCursors.insert(digest).inserted
                guard next != cursor, inserted else { throw CodexReviewInspectionFailure.changed }
                state.cursor = next
            } else {
                state.cursor = nil
                switch state.stage {
                case .firstTurns:
                    guard state.pass.reviewTurn != nil else { throw CodexReviewEntryFailure.unresolved }
                    state.stage = .firstItems
                case .secondTurns:
                    guard state.pass.reviewTurn != nil, state.pass.originalTurn != nil else { throw CodexReviewEntryFailure.unresolved }
                    state.stage = .secondItems
                case .firstItems:
                    guard completeEntryPass(state.pass) else { throw CodexReviewEntryFailure.unresolved }
                    state.firstPass = .init(state.pass); state.pass = .init(); state.stage = .secondTurns
                case .secondItems:
                    guard completeEntryPass(state.pass), state.firstPass == CodexReviewEntrySummary(state.pass) else {
                        throw CodexReviewInspectionFailure.changed
                    }
                    state.stage = .verify
                case .verify: throw CodexReviewInspectionFailure.malformed
                }
            }
            work.entryInspection = state; request.reviewWork = work
            guard try JSONEncoder().encode(work).count <= CodexReviewWork.maximumEncodedBytes else {
                throw CodexReviewInspectionFailure.budget
            }
            return try reviewProgressBatch(request, bytesRead: bytesRead, readerVersion: state.readerVersion)
        } catch is CancellationError { throw CancellationError() }
        catch let failure as CodexHistoryReadFailure where failure.reason == .responseLimitExceeded || failure.reason == .timedOut {
            bytesRead += failure.bytesRead
            return try retryEntryInspection(original, work: admittedWork, state: initialState, observedAt: observedAt,
                bytesRead: bytesRead, readerVersion: state.readerVersion)
        } catch CodexHistoryError.responseLimitExceeded, CodexHistoryError.timedOut {
            return try retryEntryInspection(original, work: admittedWork, state: initialState, observedAt: observedAt,
                bytesRead: bytesRead, readerVersion: state.readerVersion)
        } catch CodexReviewInspectionFailure.budget {
            return try finishReviewInspection(original, observedAt: observedAt, failure: .budgetExhausted, bytesRead: bytesRead)
        } catch CodexReviewInspectionFailure.changed {
            return try finishReviewInspection(original, observedAt: observedAt, failure: .sourceChanged, bytesRead: bytesRead)
        } catch CodexReviewEntryFailure.unresolved {
            return try finishReviewInspection(original, observedAt: observedAt, failure: .unresolvedCorrelation, bytesRead: bytesRead)
        } catch {
            return try finishReviewInspection(original, observedAt: observedAt, failure: .malformedSource, bytesRead: bytesRead)
        }
    }

    private func absorbEntryTurns(_ page: CodexHistoryPage, cursor: String?, target: CodexReviewTarget,
                                  state: inout CodexReviewEntryInspectionState,
                                  cryptography: BackgroundCryptography) async throws {
        try admitEntryPage(page, items: false, pass: &state.pass)
        let pageRevision = try await reviewPageCommitment(page, cryptography: cryptography)
        for row in page.data {
            try Task.checkCancellation()
            guard let id = reviewIdentifier(row["id"]), let rootValue = row.object?["rootTurnId"],
                  rootValue == .null || reviewIdentifier(rootValue) != nil else { throw CodexReviewInspectionFailure.malformed }
            let identity = try await reviewCommitment("entry-turn-id", bytes: Data(id.utf8), cryptography: cryptography)
            guard !state.pass.membership.contains(identity) else { throw CodexReviewInspectionFailure.changed }
            let selected = rootValue.string.map { Data($0.utf8) == Data(target.turnID.utf8) } ?? false
            if selected { state.pass.membership.selected.insert(identity) }
            else if rootValue == .null { state.pass.membership.unknown.insert(identity) }
            else { state.pass.membership.other.insert(identity) }
            let revision = try await entryAccumulate(row, rows: &state.pass.turns, cryptography: cryptography)
            let coordinate = CodexReviewCoordinate(itemID: id, rowRevision: revision, pageCursor: cursor, pageRevision: pageRevision)
            if id == target.turnID {
                guard selected, state.pass.reviewTurn == nil else { throw CodexReviewEntryFailure.unresolved }
                state.pass.reviewTurn = coordinate
            }
            if id == state.firstPass?.original?.turnID {
                guard selected, state.pass.originalTurn == nil else { throw CodexReviewEntryFailure.unresolved }
                state.pass.originalTurn = coordinate
            }
        }
    }

    private func absorbEntryItems(_ page: CodexHistoryPage, cursor: String?, target: CodexReviewTarget,
                                  state: inout CodexReviewEntryInspectionState,
                                  cryptography: BackgroundCryptography) async throws {
        try admitEntryPage(page, items: true, pass: &state.pass)
        let pageRevision = try await reviewPageCommitment(page, cryptography: cryptography)
        for row in page.data {
            try Task.checkCancellation()
            let item = row["item"]
            guard let id = reviewIdentifier(item["id"]), let turn = reviewIdentifier(row["turnId"]),
                  let type = reviewIdentifier(item["type"]) else { throw CodexReviewInspectionFailure.malformed }
            let identity = try await reviewCommitment("entry-item-id", bytes: Data(id.utf8), cryptography: cryptography)
            guard state.pass.items.seenItems.insert(identity).inserted else { throw CodexReviewInspectionFailure.changed }
            let revision = try await entryAccumulate(row, rows: &state.pass.items, cryptography: cryptography)
            if id == target.itemID, revision != target.rowRevision { throw CodexReviewInspectionFailure.changed }
            guard type == "userMessage" || type == "enteredReviewMode" else { continue }
            let turnKey = try await reviewCommitment("entry-turn-id", bytes: Data(turn.utf8), cryptography: cryptography)
            guard state.pass.membership.contains(turnKey), !state.pass.membership.unknown.contains(turnKey) else {
                throw CodexReviewEntryFailure.unresolved
            }
            guard state.pass.membership.selected.contains(turnKey) else { continue }
            let coordinate = CodexReviewEntryItem(turnID: turn,
                coordinate: .init(itemID: id, rowRevision: revision, pageCursor: cursor, pageRevision: pageRevision))
            if type == "userMessage" {
                // Count before checking payload or equality: an unreadable or nonmatching
                // second user still makes the causal group ambiguous.
                state.pass.groupUsers += 1
                guard state.pass.groupUsers == 1 else { throw CodexReviewEntryFailure.unresolved }
                guard let content = item["content"].array, content.count == 1,
                      content[0]["type"].string == "text", let text = content[0]["text"].string,
                      try await reviewCommitment("text", bytes: Data(text.utf8), cryptography: cryptography) == target.textRevision else {
                    throw CodexReviewEntryFailure.unresolved
                }
                state.pass.original = coordinate
            } else {
                state.pass.groupEntries += 1
                guard state.pass.groupEntries == 1, id == target.itemID, turn == target.turnID,
                      revision == target.rowRevision else { throw CodexReviewEntryFailure.unresolved }
                state.pass.presentation = coordinate
            }
        }
    }

    private func admitEntryPage(_ page: CodexHistoryPage, items: Bool, pass: inout CodexReviewEntryPass) throws {
        if items { pass.items.pageCount += 1; pass.items.bytesRead += page.bytesRead }
        else { pass.turns.pageCount += 1; pass.turns.bytesRead += page.bytesRead }
        guard pass.turns.pageCount + pass.items.pageCount <= CodexReviewInspectionState.maximumPages,
              pass.turns.bytesRead + pass.items.bytesRead <= CodexReviewInspectionState.maximumBytes,
              !page.data.isEmpty || page.nextCursor == nil else { throw CodexReviewInspectionFailure.budget }
    }

    private func entryAccumulate(_ row: CodexJSON, rows: inout CodexReviewEntryRows,
                                 cryptography: BackgroundCryptography) async throws -> ContentRevision {
        let bytes = try reviewCanonical(row)
        guard bytes.count <= limits.maximumRowBytes,
              rows.count < min(limits.maximumRows, CodexReviewInspectionState.maximumItems) else { throw CodexReviewInspectionFailure.budget }
        let revision = try await reviewCommitment("row", bytes: bytes, cryptography: cryptography)
        var chain = rows.chain?.keyedDigest ?? Data(repeating: 0, count: 32)
        chain.append(revision.keyedDigest)
        rows.chain = try await reviewCommitment("entry-chain", bytes: chain, cryptography: cryptography)
        rows.count += 1
        return revision
    }

    private func retryEntryInspection(_ original: CodexHistoryRequest, work: CodexReviewWork,
                                     state: CodexReviewEntryInspectionState, observedAt: Date,
                                     bytesRead: Int, readerVersion: String?) throws -> CollectionBatch {
        var work = work, state = state, request = original
        state.transportFailures += 1
        if state.transportFailures >= 3 {
            return try finishReviewInspection(original, observedAt: observedAt, failure: .budgetExhausted, bytesRead: bytesRead)
        }
        work.entryInspection = state; request.reviewWork = work
        return try reviewProgressBatch(request, bytesRead: bytesRead, readerVersion: readerVersion)
    }

    private func validEntryState(_ state: CodexReviewEntryInspectionState, target: CodexReviewTarget,
                                 threadID: String, audit: HistoricalAuditContext?) -> Bool {
        let age = Date().timeIntervalSince(state.startedAt)
        guard age.isFinite, age >= 0, age <= CodexReviewInspectionState.maximumLifetime,
              state.parserContract == Self.parserContract, state.authorityID == authority.rawValue,
              state.profileID == profileID, state.threadID == threadID, state.audit == audit,
              state.targetItemID == target.itemID, state.reviewTurnID == target.turnID, state.targetRevision == target.rowRevision,
              state.pageSize > 0, state.pageSize <= min(limits.pageSize, max(1, historyBudget.maximumSources / 4)),
              state.cursor.map(validReviewCursor) ?? true, (0...2).contains(state.transportFailures),
              validEntryPass(state.pass) else { return false }
        if let first = state.firstPass { guard validEntrySummary(first) else { return false } }
        switch state.stage {
        case .firstTurns:
            return state.firstPass == nil && state.pass.items.count == 0
        case .firstItems:
            return state.firstPass == nil && state.pass.reviewTurn != nil
        case .secondTurns:
            return state.firstPass != nil && state.pass.items.count == 0
        case .secondItems:
            return state.firstPass != nil && state.pass.reviewTurn != nil && state.pass.originalTurn != nil
        case .verify:
            return state.cursor == nil && state.pass.originalTurn != nil && state.firstPass == CodexReviewEntrySummary(state.pass)
        }
    }
}

private func completeEntryPass(_ pass: CodexReviewEntryPass) -> Bool {
    pass.turns.count > 0 && pass.items.count > 0 && pass.reviewTurn != nil
        && pass.groupUsers == 1 && pass.groupEntries == 1 && pass.original != nil && pass.presentation != nil
        && pass.original?.coordinate.itemID != pass.presentation?.coordinate.itemID
}
private func entryTurnRow(_ page: CodexHistoryPage, coordinate: CodexReviewCoordinate) throws -> CodexJSON {
    let matching = page.data.filter { $0["id"].string == coordinate.itemID }
    guard matching.count == 1, let row = matching.first else { throw CodexReviewInspectionFailure.changed }
    return row
}
private func validEntryCoordinate(_ coordinate: CodexReviewCoordinate?) -> Bool {
    guard let coordinate else { return true }
    return reviewIdentifier(.string(coordinate.itemID)) != nil && (coordinate.pageCursor.map(validReviewCursor) ?? true)
}
private func validEntryPass(_ pass: CodexReviewEntryPass) -> Bool {
    for rows in [pass.turns, pass.items] {
        guard (0...CodexReviewInspectionState.maximumItems).contains(rows.count),
              (0...CodexReviewInspectionState.maximumPages).contains(rows.pageCount),
              (0...CodexReviewInspectionState.maximumBytes).contains(rows.bytesRead),
              rows.seenCursors.count <= rows.pageCount, (rows.chain == nil) == (rows.count == 0) else { return false }
    }
    return pass.turns.pageCount + pass.items.pageCount <= CodexReviewInspectionState.maximumPages
        && pass.turns.bytesRead + pass.items.bytesRead <= CodexReviewInspectionState.maximumBytes
        && pass.turns.seenItems.isEmpty && pass.items.seenItems.count == pass.items.count
        && pass.membership.disjoint && pass.membership.count == pass.turns.count
        && (0...1).contains(pass.groupUsers) && (0...1).contains(pass.groupEntries)
        && (pass.original == nil) == (pass.groupUsers == 0) && (pass.presentation == nil) == (pass.groupEntries == 0)
        && validEntryCoordinate(pass.reviewTurn) && validEntryCoordinate(pass.originalTurn)
        && validEntryCoordinate(pass.original?.coordinate) && validEntryCoordinate(pass.presentation?.coordinate)
        && (pass.original.map { reviewIdentifier(.string($0.turnID)) != nil } ?? true)
        && (pass.presentation.map { reviewIdentifier(.string($0.turnID)) != nil } ?? true)
}
private func validEntrySummary(_ summary: CodexReviewEntrySummary) -> Bool {
    summary.turnCount > 0 && summary.turnCount <= CodexReviewInspectionState.maximumItems
        && summary.itemCount > 0 && summary.itemCount <= CodexReviewInspectionState.maximumItems
        && summary.turnPages > 0 && summary.itemPages > 0
        && summary.turnPages + summary.itemPages <= CodexReviewInspectionState.maximumPages
        && summary.turnChain != nil && summary.itemChain != nil
        && summary.groupUsers == 1 && summary.groupEntries == 1
        && summary.reviewTurn != nil && summary.original != nil && summary.presentation != nil
        && validEntryCoordinate(summary.reviewTurn) && validEntryCoordinate(summary.original?.coordinate)
        && validEntryCoordinate(summary.presentation?.coordinate)
}
