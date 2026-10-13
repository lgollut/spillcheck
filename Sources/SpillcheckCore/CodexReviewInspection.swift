import Foundation

/// Pending review inspection contains coordinates and keyed commitments only. Source
/// bytes are reread at settlement, never carried in a continuation or checkpoint.
enum CodexReviewTargetKind: String, Codable, Sendable {
    case exit = "exitedReviewMode"
    case entry = "enteredReviewMode"
}

struct CodexReviewTarget: Codable, Sendable {
    let turnID: String
    let itemID: String
    let producerVersion: String
    let rowRevision: ContentRevision
    let textRevision: ContentRevision
    let gap: CoverageGap
    var kind: CodexReviewTargetKind?
    var selectedKind: CodexReviewTargetKind { kind ?? .exit }
}

struct CodexReviewWork: Codable, Sendable {
    static let maximumEncodedBytes = 512 * 1024
    var targets: [CodexReviewTarget]
    var inspection: CodexReviewInspectionState?
    var entryInspection: CodexReviewEntryInspectionState?
    var finishThreadAfterInspection: Bool
}

struct CodexReviewCoordinate: Codable, Equatable, Sendable {
    let itemID: String
    let rowRevision: ContentRevision
    let pageCursor: String?
    let pageRevision: ContentRevision
}

struct CodexReviewPass: Codable, Equatable, Sendable {
    var rowChain: ContentRevision?
    var itemCount = 0
    var pageCount = 0
    var bytesRead = 0
    var original: CodexReviewCoordinate?
    var presentation: CodexReviewCoordinate?
    var matchingOriginalCount = 0
    var seenItems: Set<ContentRevision> = []
    var seenCursors: Set<ContentRevision> = []
}

struct CodexReviewPassSummary: Codable, Equatable, Sendable {
    let rowChain: ContentRevision?
    let itemCount: Int
    let original: CodexReviewCoordinate?
    let presentation: CodexReviewCoordinate?
    let matchingOriginalCount: Int
    init(_ pass: CodexReviewPass) {
        rowChain = pass.rowChain; itemCount = pass.itemCount
        original = pass.original; presentation = pass.presentation
        matchingOriginalCount = pass.matchingOriginalCount
    }
}

struct CodexReviewInspectionState: Codable, Sendable {
    static let maximumItems = 4096
    static let maximumPages = 128
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumLifetime: TimeInterval = 15 * 60
    enum Phase: String, Codable, Sendable { case first, second, verify }
    let generation: UUID
    let startedAt: Date
    let parserContract: String
    let authorityID: String
    let profileID: String
    let threadID: String
    let targetItemID: String
    let turnID: String
    let targetRevision: ContentRevision
    let audit: HistoricalAuditContext?
    var readerVersion: String?
    var phase = Phase.first
    var cursor: String?
    var pageSize: Int
    var pass = CodexReviewPass()
    var firstPass: CodexReviewPassSummary?
    var transportFailures = 0

    init(profileID: String, threadID: String, target: CodexReviewTarget, audit: HistoricalAuditContext?, pageSize: Int) {
        generation = UUID(); startedAt = Date(); parserContract = CodexAdapter.parserContract
        authorityID = CodexCollectionAuthority.publicNativeItems.rawValue
        self.profileID = profileID; self.threadID = threadID; self.pageSize = pageSize
        targetItemID = target.itemID; turnID = target.turnID; targetRevision = target.rowRevision; self.audit = audit
    }
}

enum CodexReviewInspectionFailure: Error { case changed, malformed, budget }

extension CodexAdapter {
    /// Admit only native presentation rows with the exact known presentation gap.
    /// Original content remains provisional until its fresh bounded inspection succeeds.
    func reviewInspectionTargets(page: CodexHistoryPage, batch: CollectionBatch, thread: CodexJSON,
                                 cryptography: BackgroundCryptography) async throws -> [CodexReviewTarget] {
        guard authority == .publicNativeItems, let threadID = thread["id"].string else { return [] }
        var targets: [CodexReviewTarget] = [], encodedBytes = 0
        let session = try SessionIdentity(provider: .codex, profileID: profileID, sessionID: threadID)
        for entry in page.data {
            let item = entry["item"]
            guard let kind = item["type"].string.flatMap(CodexReviewTargetKind.init(rawValue:)),
                  let turn = reviewIdentifier(entry["turnId"]),
                  let id = reviewIdentifier(item["id"]), let text = item["review"].string, !text.isEmpty,
                  try reviewCanonical(entry).count <= limits.maximumRowBytes else { continue }
            let matching = batch.coverageGaps.filter { $0.recovery?.session == session && $0.recovery?.itemID == id }
            guard matching.count == 1, let gap = matching.first, gap.reason == .unsupportedContent,
                  gap.diagnosticCode == .unknownRecordKind, gap.sourceKind == .codexUnknownItem,
                  gap.isRequiredFormatFailure == false, gap.excludedContent == nil, gap.contentType == nil,
                  gap.scope == collectionScope, gap.recovery?.locator == .upstreamItem,
                  gap.recovery?.contentTime != nil, gap.recovery?.parserContract == Self.parserContract,
                  gap.recovery?.sourceDocumentID == nil, gap.recovery?.sourceURL == nil else { continue }
            let target = CodexReviewTarget(turnID: turn, itemID: id,
                producerVersion: recordedProducerVersion(thread["cliVersion"]),
                rowRevision: try await reviewCommitment("row", bytes: reviewCanonical(entry), cryptography: cryptography),
                textRevision: try await reviewCommitment("text", bytes: Data(text.utf8), cryptography: cryptography), gap: gap,
                kind: kind)
            let size = try JSONEncoder().encode(target).count
            // Reserve the rest of the 512 KiB state budget for seen-item/cursor digests.
            guard targets.count < 256, size <= 64 * 1024 - encodedBytes else { continue }
            targets.append(target); encodedBytes += size
        }
        return targets
    }

    func normalizeReviewInspection(_ original: CodexHistoryRequest, observedAt: Date,
                                   cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        guard var work = original.reviewWork, let target = work.targets.first,
              let threadID = original.threads.first, authority == .publicNativeItems,
              !work.targets.isEmpty, work.targets.count <= 256,
              try JSONEncoder().encode(work).count <= CodexReviewWork.maximumEncodedBytes,
              work.targets.allSatisfy({ reviewTargetValid($0, threadID: threadID) }) else {
            var rejected = original
            rejected.reviewWork = nil; rejected.partial = true; rejected.threadPartial = true
            if !rejected.threads.isEmpty { rejected.finishThread() }
            return try reviewProgressBatch(rejected, bytesRead: 0, gaps: [.init(reason: .malformedSource,
                scope: collectionScope, operation: original.audit == nil ? .liveRead : .historicalRead,
                observedAt: observedAt)])
        }
        if target.selectedKind == .entry {
            guard work.inspection == nil else {
                return try finishReviewInspection(original, observedAt: observedAt, failure: .malformedSource)
            }
            return try await normalizeReviewEntryInspection(original, work: work, target: target,
                threadID: threadID, observedAt: observedAt, cryptography: cryptography)
        }
        guard work.entryInspection == nil else {
            return try finishReviewInspection(original, observedAt: observedAt, failure: .malformedSource)
        }
        var request = original
        let effectivePageSize = min(limits.pageSize, max(1, historyBudget.maximumSources / 3))
        var state = work.inspection ?? .init(profileID: profileID, threadID: threadID, target: target, audit: original.audit, pageSize: effectivePageSize)
        guard reviewStateValid(state, threadID: threadID, target: target, audit: original.audit) else {
            return try finishReviewInspection(original, observedAt: observedAt, failure: .sourceChanged)
        }
        let initialState = state
        var bytesRead = 0, itemCount = 0
        let started = ProcessInfo.processInfo.systemUptime
        func budget() throws -> CodexRPCBudget {
            let bytes = historyBudget.maximumBytes - bytesRead
            let duration = historyBudget.maximumDuration - (ProcessInfo.processInfo.systemUptime - started)
            guard bytes > 0, duration > 0 else { throw CodexHistoryError.responseLimitExceeded }
            return try .init(maximumBytes: min(bytes, limits.maximumBytes), timeout: duration)
        }
        func observe(_ version: String?) throws {
            guard let version, !version.isEmpty, version.utf8.count <= 256, !version.utf8.contains(0),
                  state.readerVersion == nil || state.readerVersion == version else {
                throw CodexReviewInspectionFailure.changed
            }
            state.readerVersion = version
        }
        func readPage(_ cursor: String?) async throws -> CodexHistoryPage {
            let page = try await history.listItems(threadID: threadID, turnID: target.turnID, cursor: cursor,
                limit: state.pageSize, direction: .ascending, budget: budget())
            try observe(page.readerVersion)
            bytesRead += page.bytesRead; itemCount += page.data.count
            guard page.bytesRead >= 0, page.data.count <= state.pageSize, itemCount <= historyBudget.maximumSources,
                  bytesRead <= historyBudget.maximumBytes,
                  ProcessInfo.processInfo.systemUptime - started <= historyBudget.maximumDuration,
                  page.nextCursor.map({ validReviewCursor($0) }) ?? true else {
                throw CodexReviewInspectionFailure.budget
            }
            return page
        }
        func turnTimes(for rows: [CodexJSON]) async throws -> [String: DateInterval] {
            guard rows.contains(where: { $0["completedAtMs"].number == nil && $0["startedAtMs"].number == nil }) else { return [:] }
            let remaining = historyBudget.maximumSources - itemCount
            guard remaining > 0 else { throw CodexReviewInspectionFailure.budget }
            let turns = try await history.listTurns(threadID: threadID, cursor: nil, limit: min(256, remaining),
                direction: .descending, budget: budget())
            try observe(turns.readerVersion); bytesRead += turns.bytesRead; itemCount += turns.data.count
            guard turns.bytesRead >= 0, turns.data.count <= min(256, remaining), bytesRead <= historyBudget.maximumBytes,
                  ProcessInfo.processInfo.systemUptime - started <= historyBudget.maximumDuration else {
                throw CodexReviewInspectionFailure.budget
            }
            let matching = turns.data.filter { $0["id"].string == target.turnID }
            guard matching.count == 1, let turn = matching.first,
                  let start = turn["startedAt"].number, let end = turn["completedAt"].number,
                  start.isFinite, end.isFinite, end >= start else { return [:] }
            return [target.turnID: .init(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))]
        }
        do {
            try Task.checkCancellation()
            try await selectAuthority(sessionID: threadID)
            let metadata = try await history.readThread(threadID, budget: budget())
            try observe(metadata.readerVersion); bytesRead += metadata.bytesRead
            guard metadata.bytesRead >= 0, bytesRead <= historyBudget.maximumBytes,
                  ProcessInfo.processInfo.systemUptime - started <= historyBudget.maximumDuration,
                  metadata.thread["id"].string == threadID,
                  recordedProducerVersion(metadata.thread["cliVersion"]) == target.producerVersion else {
                throw CodexReviewInspectionFailure.changed
            }
            if state.phase == .verify {
                guard let verified = state.firstPass, let originalCoordinate = verified.original,
                      let presentationCoordinate = verified.presentation else { throw CodexReviewInspectionFailure.malformed }
                let first = try await readPage(originalCoordinate.pageCursor)
                let second = originalCoordinate.pageCursor == presentationCoordinate.pageCursor
                    ? first : try await readPage(presentationCoordinate.pageCursor)
                guard try await reviewPageCommitment(first, cryptography: cryptography) == originalCoordinate.pageRevision,
                      try await reviewPageCommitment(second, cryptography: cryptography) == presentationCoordinate.pageRevision else {
                    throw CodexReviewInspectionFailure.changed
                }
                let originalRows = first.data.filter { $0["item"]["id"].string == originalCoordinate.itemID }
                let presentationRows = second.data.filter { $0["item"]["id"].string == presentationCoordinate.itemID }
                guard originalRows.count == 1, presentationRows.count == 1,
                      let originalRow = originalRows.first, let presentationRow = presentationRows.first,
                      try await reviewRowMatches(originalRow, coordinate: originalCoordinate, turnID: target.turnID,
                          cryptography: cryptography),
                      try await reviewRowMatches(presentationRow, coordinate: presentationCoordinate, turnID: target.turnID,
                          cryptography: cryptography) else { throw CodexReviewInspectionFailure.changed }
                let times = try await turnTimes(for: [originalRow, presentationRow])
                return try await finishReviewProof(request, originalRow: originalRow,
                    presentationRow: presentationRow, thread: metadata.thread, observedAt: observedAt,
                    bytesRead: bytesRead, readerVersion: state.readerVersion, turnTimes: times,
                    deadline: started + historyBudget.maximumDuration, cryptography: cryptography)
            }
            let currentCursor = state.cursor
            let page = try await readPage(currentCursor)
            try await absorbReviewPage(page, cursor: currentCursor, target: target, state: &state,
                cryptography: cryptography)
            guard ProcessInfo.processInfo.systemUptime - started <= historyBudget.maximumDuration else {
                throw CodexHistoryError.timedOut
            }
            state.transportFailures = 0
            if let next = page.nextCursor {
                let digest = try await reviewCommitment("cursor", bytes: Data(next.utf8), cryptography: cryptography)
                guard next != currentCursor, state.pass.seenCursors.insert(digest).inserted else {
                    throw CodexReviewInspectionFailure.changed
                }
                state.cursor = next
            } else {
                guard state.pass.matchingOriginalCount == 1, let originalCoordinate = state.pass.original,
                      let presentationCoordinate = state.pass.presentation,
                      originalCoordinate.itemID != presentationCoordinate.itemID else {
                    throw CodexReviewInspectionFailure.changed
                }
                if state.phase == .first, state.pass.pageCount == 1 {
                    let originalRow = try requiredReviewRow(page, id: originalCoordinate.itemID)
                    let presentationRow = try requiredReviewRow(page, id: presentationCoordinate.itemID)
                    let times = try await turnTimes(for: [originalRow, presentationRow])
                    return try await finishReviewProof(request, originalRow: originalRow,
                        presentationRow: presentationRow, thread: metadata.thread, observedAt: observedAt,
                        bytesRead: bytesRead, readerVersion: state.readerVersion, turnTimes: times,
                    deadline: started + historyBudget.maximumDuration, cryptography: cryptography)
                }
                if state.phase == .first {
                    state.firstPass = .init(state.pass); state.pass = .init(); state.cursor = nil; state.phase = .second
                } else {
                    guard let firstPass = state.firstPass, firstPass == CodexReviewPassSummary(state.pass) else {
                        throw CodexReviewInspectionFailure.changed
                    }
                    state.phase = .verify; state.cursor = nil
                }
            }
            work.inspection = state; request.reviewWork = work
            guard try JSONEncoder().encode(work).count <= CodexReviewWork.maximumEncodedBytes else {
                throw CodexReviewInspectionFailure.budget
            }
            return try reviewProgressBatch(request, bytesRead: bytesRead, readerVersion: state.readerVersion)
        } catch is CancellationError { throw CancellationError() }
        catch let failure as CodexHistoryReadFailure where failure.reason == .responseLimitExceeded || failure.reason == .timedOut {
            bytesRead += failure.bytesRead
            return try reviewTransportRetry(request, work: work, state: initialState, observedAt: observedAt,
                bytesRead: bytesRead, readerVersion: state.readerVersion)
        } catch CodexHistoryError.responseLimitExceeded, CodexHistoryError.timedOut {
            return try reviewTransportRetry(request, work: work, state: initialState, observedAt: observedAt,
                bytesRead: bytesRead, readerVersion: state.readerVersion)
        } catch CodexReviewInspectionFailure.budget {
            return try finishReviewInspection(request, observedAt: observedAt, failure: .budgetExhausted, bytesRead: bytesRead)
        } catch CodexReviewInspectionFailure.changed {
            return try finishReviewInspection(request, observedAt: observedAt, failure: .sourceChanged, bytesRead: bytesRead)
        } catch {
            return try finishReviewInspection(request, observedAt: observedAt, failure: .malformedSource, bytesRead: bytesRead)
        }
    }

    private func absorbReviewPage(_ page: CodexHistoryPage, cursor: String?, target: CodexReviewTarget,
                                 state: inout CodexReviewInspectionState,
                                 cryptography: BackgroundCryptography) async throws {
        state.pass.pageCount += 1; state.pass.bytesRead += page.bytesRead
        guard state.pass.pageCount <= CodexReviewInspectionState.maximumPages,
              state.pass.bytesRead <= CodexReviewInspectionState.maximumBytes,
              !page.data.isEmpty || page.nextCursor == nil else { throw CodexReviewInspectionFailure.budget }
        let pageRevision = try await reviewPageCommitment(page, cryptography: cryptography)
        for row in page.data {
            try Task.checkCancellation()
            guard row["turnId"].string == target.turnID, let id = reviewIdentifier(row["item"]["id"]),
                  reviewIdentifier(row["item"]["type"]) != nil else { throw CodexReviewInspectionFailure.malformed }
            let bytes = try reviewCanonical(row)
            guard bytes.count <= limits.maximumRowBytes,
                  state.pass.itemCount < min(limits.maximumRows, CodexReviewInspectionState.maximumItems) else {
                throw CodexReviewInspectionFailure.budget
            }
            let identity = try await reviewCommitment("item", bytes: Data(id.utf8), cryptography: cryptography)
            guard state.pass.seenItems.insert(identity).inserted else { throw CodexReviewInspectionFailure.changed }
            let revision = try await reviewCommitment("row", bytes: bytes, cryptography: cryptography)
            var chain = state.pass.rowChain?.keyedDigest ?? Data(repeating: 0, count: 32)
            chain.append(revision.keyedDigest)
            state.pass.rowChain = try await reviewCommitment("chain", bytes: chain, cryptography: cryptography)
            state.pass.itemCount += 1
            let item = row["item"]
            if id == target.itemID {
                guard revision == target.rowRevision, item["type"].string == "exitedReviewMode",
                      state.pass.presentation == nil else { throw CodexReviewInspectionFailure.changed }
                state.pass.presentation = .init(itemID: id, rowRevision: revision, pageCursor: cursor, pageRevision: pageRevision)
            }
            if item["type"].string == "agentMessage", item.object?["phase"] == .null,
               let text = item["text"].string, !text.isEmpty,
               try await reviewCommitment("text", bytes: Data(text.utf8), cryptography: cryptography) == target.textRevision {
                state.pass.matchingOriginalCount += 1
                guard state.pass.matchingOriginalCount == 1 else { throw CodexReviewInspectionFailure.changed }
                state.pass.original = .init(itemID: id, rowRevision: revision, pageCursor: cursor, pageRevision: pageRevision)
            }
        }
    }

    func finishReviewProof(_ request: CodexHistoryRequest,
                                  originalRow: CodexJSON, presentationRow: CodexJSON, thread: CodexJSON,
                                  observedAt: Date, bytesRead: Int, readerVersion: String?, turnTimes: [String: DateInterval],
                                  deadline: TimeInterval, entryTurns: (review: CodexJSON, original: CodexJSON)? = nil,
                                  cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        let provenance = request.audit.map(SourceProvenance.historical) ?? .live
        let pair = CodexHistoryPage(data: [originalRow, presentationRow], readerVersion: readerVersion)
        let batch = try await importPublicItems(pair, thread: thread, observedAt: observedAt,
            provenance: provenance, turnTimes: turnTimes, cryptography: cryptography)
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime <= deadline else { throw CodexHistoryError.timedOut }
        let pending: CoverageRecoveryDependency?
        if let entryTurns {
            pending = reviewEntryPresentationDependency(presentation: presentationRow, original: originalRow,
                reviewTurn: entryTurns.review, originalTurn: entryTurns.original, batch: batch, thread: thread)
        } else {
            pending = reviewExitPresentationDependency(presentation: presentationRow, original: originalRow,
                batch: batch, thread: thread)
        }
        guard let dependency = pending else {
            return try finishReviewInspection(request, observedAt: observedAt, failure: .unresolvedCorrelation,
                bytesRead: bytesRead, sources: batch.sources, gaps: batch.coverageGaps)
        }
        let success = advancingReviewWork(request, failed: false)
        let failure = advancingReviewWork(request, failed: true)
        let successPacket = try reviewHasWork(success) ? packet(success) : nil
        let failurePacket = try reviewHasWork(failure) ? packet(failure) : nil
        return .init(sources: batch.sources, coverageGaps: batch.coverageGaps,
            continuation: successPacket, unresolvedRecoveryContinuation: successPacket == nil ? nil : failurePacket,
            historicalProgress: request.audit.map {
                .init(audit: $0, bytesRead: bytesRead, oldestContentTime: batch.sources.map(\.record.metadata.contentTime).min(),
                    newestContentTime: batch.sources.map(\.record.metadata.contentTime).max(),
                    hasUnreadContent: reviewHasWork(success) || success.partial)
            }, recoveredReferences: batch.recoveredReferences, pendingRecoveryDependencies: [dependency],
            observedRead: true, observedReaderVersion: readerVersion)
    }

    private func advancingReviewWork(_ original: CodexHistoryRequest, failed: Bool) -> CodexHistoryRequest {
        var request = original
        guard var work = request.reviewWork, !work.targets.isEmpty else {
            request.reviewWork = nil; request.partial = true; request.threadPartial = true
            // Invalid control work cannot create a self-repeating continuation.
            if !request.threads.isEmpty { request.finishThread() }
            return request
        }
        work.targets.removeFirst(); work.inspection = nil; work.entryInspection = nil
        if failed { request.partial = true; request.threadPartial = true }
        if work.targets.isEmpty {
            request.reviewWork = nil
            if work.finishThreadAfterInspection {
                if let thread = request.threads.first, request.visited.count < 4096 { request.visited.append(thread) }
                if !request.threads.isEmpty { request.finishThread() }
            }
        } else { request.reviewWork = work }
        return request
    }

    func finishReviewInspection(_ original: CodexHistoryRequest, observedAt: Date,
                                       failure: CoverageGapReason, bytesRead: Int = 0,
                                       sources: [CollectedSource] = [], gaps: [CoverageGap] = []) throws -> CollectionBatch {
        let target = original.reviewWork?.targets.first
        var allGaps = gaps
        if let target {
            allGaps.append(target.gap)
            allGaps.append(.init(reason: failure, scope: collectionScope,
                operation: original.audit == nil ? .liveRead : .historicalRead, recovery: target.gap.recovery,
                diagnosticCode: failure.defaultDiagnosticCode, observedAt: observedAt))
        } else {
            allGaps.append(.init(reason: failure, scope: collectionScope,
                operation: original.audit == nil ? .liveRead : .historicalRead, observedAt: observedAt))
        }
        let next = advancingReviewWork(original, failed: true)
        return try reviewProgressBatch(next, bytesRead: bytesRead, sources: sources, gaps: allGaps)
    }

    private func reviewTransportRetry(_ original: CodexHistoryRequest, work: CodexReviewWork,
                                      state: CodexReviewInspectionState, observedAt: Date,
                                      bytesRead: Int, readerVersion: String?) throws -> CollectionBatch {
        var request = original, work = work, state = state
        state.transportFailures += 1
        if state.transportFailures >= 3 {
            return try finishReviewInspection(request, observedAt: observedAt, failure: .budgetExhausted, bytesRead: bytesRead)
        }
        work.inspection = state; request.reviewWork = work
        // The unchanged inspection is retried. No parsed row or successful proof is persisted.
        return try reviewProgressBatch(request, bytesRead: bytesRead, readerVersion: readerVersion)
    }

    func reviewProgressBatch(_ request: CodexHistoryRequest, bytesRead: Int,
                                     sources: [CollectedSource] = [], gaps: [CoverageGap] = [],
                                     readerVersion: String? = nil) throws -> CollectionBatch {
        let pending = reviewHasWork(request)
        return .init(sources: sources, coverageGaps: gaps, continuation: pending ? try packet(request) : nil,
            historicalProgress: request.audit.map { .init(audit: $0, bytesRead: bytesRead,
                hasUnreadContent: pending || request.partial) }, observedRead: bytesRead > 0,
            observedReaderVersion: readerVersion)
    }

    private func reviewTargetValid(_ target: CodexReviewTarget, threadID: String) -> Bool {
        reviewIdentifier(.string(target.turnID)) != nil && reviewIdentifier(.string(target.itemID)) != nil
            && target.producerVersion.utf8.count <= 256
            && target.gap.recovery?.session?.sessionID == threadID
            && target.gap.recovery?.session?.profileID == profileID
            && target.gap.recovery?.session?.provider == .codex
            && target.gap.recovery?.itemID == target.itemID
            && target.gap.recovery?.locator == .upstreamItem
            && target.gap.recovery?.parserContract == Self.parserContract
            && target.gap.scope == collectionScope && target.gap.reason == .unsupportedContent
    }

    private func reviewStateValid(_ state: CodexReviewInspectionState, threadID: String,
                                  target: CodexReviewTarget, audit: HistoricalAuditContext?) -> Bool {
        let age = Date().timeIntervalSince(state.startedAt)
        guard age.isFinite, age >= 0, age <= CodexReviewInspectionState.maximumLifetime,
              state.parserContract == Self.parserContract, state.authorityID == authority.rawValue,
              state.profileID == profileID, state.threadID == threadID, state.audit == audit,
              state.targetItemID == target.itemID, state.turnID == target.turnID, state.targetRevision == target.rowRevision,
              state.pageSize > 0, state.pageSize <= min(limits.pageSize, max(1, historyBudget.maximumSources / 3)),
              state.cursor.map(validReviewCursor) ?? true, (0...2).contains(state.transportFailures) else { return false }
        let pass = state.pass
        guard (0...CodexReviewInspectionState.maximumItems).contains(pass.itemCount),
              (0...CodexReviewInspectionState.maximumPages).contains(pass.pageCount),
              (0...CodexReviewInspectionState.maximumBytes).contains(pass.bytesRead),
              pass.seenItems.count == pass.itemCount, pass.seenCursors.count <= pass.pageCount,
              validReviewSummary(.init(pass)),
              (pass.itemCount == 0) == (pass.rowChain == nil) else { return false }
        if let first = state.firstPass {
            guard validReviewSummary(first), first.itemCount > 0, first.rowChain != nil,
                  first.original != nil, first.presentation != nil, first.matchingOriginalCount == 1 else { return false }
        }
        switch state.phase {
        case .first: return state.firstPass == nil
        case .second: return state.firstPass != nil
        case .verify: return state.firstPass == CodexReviewPassSummary(pass) && state.cursor == nil
        }
    }

}

func reviewHasWork(_ request: CodexHistoryRequest) -> Bool {
    request.reviewWork != nil || request.discovering || !request.threads.isEmpty || !request.children.isEmpty
}
func validReviewCursor(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 64 * 1024 && !value.utf8.contains(0) }
func reviewIdentifier(_ value: CodexJSON) -> String? {
    guard let text = value.string, !text.isEmpty, text.utf8.count <= 4096, !text.utf8.contains(0) else { return nil }
    return text
}
func reviewCanonical(_ value: CodexJSON) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}
func reviewCommitment(_ domain: String, bytes: Data,
                              cryptography: BackgroundCryptography) async throws -> ContentRevision {
    var input = Data("codex-review-inspection-v1/\(domain)\n".utf8); input.append(bytes)
    return try await cryptography.revision(canonicalBytes: input)
}
func reviewRowMatches(_ row: CodexJSON, coordinate: CodexReviewCoordinate, turnID: String,
                              cryptography: BackgroundCryptography) async throws -> Bool {
    guard row["turnId"].string == turnID, row["item"]["id"].string == coordinate.itemID else { return false }
    return try await reviewCommitment("row", bytes: reviewCanonical(row), cryptography: cryptography) == coordinate.rowRevision
}
func requiredReviewRow(_ page: CodexHistoryPage, id: String) throws -> CodexJSON {
    let rows = page.data.filter { $0["item"]["id"].string == id }
    guard rows.count == 1, let row = rows.first else { throw CodexReviewInspectionFailure.changed }
    return row
}

private func validReviewSummary(_ pass: CodexReviewPassSummary) -> Bool {
    (0...CodexReviewInspectionState.maximumItems).contains(pass.itemCount)
        && (0...1).contains(pass.matchingOriginalCount)
        && (pass.original == nil) == (pass.matchingOriginalCount == 0)
        && (pass.original?.pageCursor.map(validReviewCursor) ?? true)
        && (pass.presentation?.pageCursor.map(validReviewCursor) ?? true)
}
func reviewPageCommitment(_ page: CodexHistoryPage,
                                  cryptography: BackgroundCryptography) async throws -> ContentRevision {
    let shape = CodexJSON.object(["data": .array(page.data), "nextCursor": page.nextCursor.map(CodexJSON.string) ?? .null])
    return try await reviewCommitment("page", bytes: reviewCanonical(shape), cryptography: cryptography)
}
