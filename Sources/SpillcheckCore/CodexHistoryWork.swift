import Foundation

struct CodexHistoryRequest: Codable, Sendable {
    static let kind = "leakret-codex-history-v1"
    var kind = Self.kind
    var audit: HistoricalAuditContext?
    var threads: [String]
    var threadListCursor: String?
    var archived = false
    var discovering: Bool
    var itemCursor: String?
    var children: [String] = []
    var visited: [String] = []
    var hasReplayCursor = false
    var replayCursor: String?
    var partial = false
    /// The current thread skipped content on an earlier page. Unlike `partial`, this does not
    /// carry into the next thread, whose own complete pass can still settle its omissions.
    var threadPartial = false
    var consecutiveBudgetFailures = 0
    var pageLimit: Int?
    var liveBootstrapped = false
    /// Thread metadata time and first item listing time for the thread an audit is reading.
    var threadUpdatedAt: Double?
    var threadListedAt: Double?
    /// A poll has no upstream event behind it, so an unchanged thread is current, not pending.
    var emptyPageIsCurrent = false
    init(audit: HistoricalAuditContext?, threads: [String] = []) {
        self.audit = audit; self.threads = threads; discovering = threads.isEmpty
    }
    private enum CodingKeys: String, CodingKey {
        case kind, audit, threads, threadListCursor, archived, discovering, itemCursor, children, visited
        case hasReplayCursor, replayCursor, partial, threadPartial, consecutiveBudgetFailures, pageLimit, liveBootstrapped
        case threadUpdatedAt, threadListedAt
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        audit = try c.decodeIfPresent(HistoricalAuditContext.self, forKey: .audit)
        threads = try c.decode([String].self, forKey: .threads)
        threadListCursor = try c.decodeIfPresent(String.self, forKey: .threadListCursor)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        discovering = try c.decodeIfPresent(Bool.self, forKey: .discovering) ?? threads.isEmpty
        itemCursor = try c.decodeIfPresent(String.self, forKey: .itemCursor)
        children = try c.decodeIfPresent([String].self, forKey: .children) ?? []
        visited = try c.decodeIfPresent([String].self, forKey: .visited) ?? []
        hasReplayCursor = try c.decodeIfPresent(Bool.self, forKey: .hasReplayCursor) ?? false
        replayCursor = try c.decodeIfPresent(String.self, forKey: .replayCursor)
        partial = try c.decodeIfPresent(Bool.self, forKey: .partial) ?? false
        threadPartial = try c.decodeIfPresent(Bool.self, forKey: .threadPartial) ?? partial
        consecutiveBudgetFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveBudgetFailures) ?? 0
        pageLimit = try c.decodeIfPresent(Int.self, forKey: .pageLimit)
        liveBootstrapped = try c.decodeIfPresent(Bool.self, forKey: .liveBootstrapped) ?? false
        threadUpdatedAt = try c.decodeIfPresent(Double.self, forKey: .threadUpdatedAt)
        threadListedAt = try c.decodeIfPresent(Double.self, forKey: .threadListedAt)
    }

    mutating func finishThread() {
        threads.removeFirst(); itemCursor = nil
        hasReplayCursor = false; replayCursor = nil
        liveBootstrapped = false; pageLimit = nil
        threadUpdatedAt = nil; threadListedAt = nil; threadPartial = false
        if threads.isEmpty, !children.isEmpty { threads = children; children = [] }
    }
}
private struct CodexPublicCheckpoint: Codable {
    let kind: String
    let authorityID: String
    let pollCursor: String?
    let bootstrapped: Bool?
    let coldPageLimit: Int?
    let parserContract: String?
}

/// A completed audit read of one thread. Content after an audit's end is left to live collection,
/// so the read covers the thread only if its last update ended before that audit's end. Metadata
/// time has one-second resolution, hence the whole-second margins.
private struct CodexThreadAuditCoverage: Codable {
    static let kind = "codex-thread-audit-v1"
    let kind: String
    let authorityID: String
    let updatedAt: Double
    let listedAt: Double
    let auditEnd: Double
    let parserContract: String?
    let hasOmissions: Bool?

    var coversThread: Bool {
        parserContract == CodexAdapter.parserContract && hasOmissions == false
            && updatedAt + 1 <= auditEnd && listedAt >= updatedAt + 1
    }
}

extension CodexAdapter {
    func normalizeHistory(_ original: CodexHistoryRequest, observedAt: Date,
                          cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        guard authority == .publicNativeItems else {
            // T3's versioned reader requires explicitly selected physical sources. Public thread
            // listings cannot safely discover a wrapper transcript with a different authority.
            return .init(sources: [], coverageGaps: [.init(reason: .sourceUnavailable)],
                historicalProgress: original.audit.map { .init(audit: $0, bytesRead: 0, hasUnreadContent: true) })
        }
        guard original.threads.count <= 256, original.children.count <= 256, original.visited.count <= 4096,
              original.threads.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }),
              (0...3).contains(original.consecutiveBudgetFailures),
              original.pageLimit == nil || (1...256).contains(original.pageLimit!),
              original.itemCursor == nil || original.itemCursor!.utf8.count <= 64 * 1024,
              original.threadListCursor == nil || original.threadListCursor!.utf8.count <= 64 * 1024 else {
            throw CodexCollectionError.malformedCapture
        }
        try Task.checkCancellation()
        var request = original, bytesRead = 0
        var gaps: [CoverageGap] = []
        var sources: [CollectedSource] = []
        var checkpoints: [SourceCheckpoint] = []
        var recovered: [CoverageRecoveryReference] = []
        let started = ProcessInfo.processInfo.systemUptime
        let pageSize = min(limits.pageSize, historyBudget.maximumSources, request.pageLimit ?? 256)
        var budgetFailure = false, readingItems = false
        func remainingBudget() throws -> CodexRPCBudget {
            let duration = historyBudget.maximumDuration - (ProcessInfo.processInfo.systemUptime - started)
            let bytes = historyBudget.maximumBytes - bytesRead
            guard bytes > 0, duration > 0 else { throw CodexHistoryError.responseLimitExceeded }
            return try .init(maximumBytes: min(bytes, limits.maximumBytes), timeout: duration)
        }
        do {
        if request.threads.isEmpty, request.discovering {
            let page = try await history.listThreads(cursor: request.threadListCursor, limit: pageSize, archived: request.archived,
                budget: remainingBudget())
            bytesRead += page.bytesRead
            var reachedOld = false
            for thread in page.data {
                guard let id = thread["id"].nonemptyString, let updated = thread["updatedAt"].number, updated.isFinite else {
                    gaps.append(.init(reason: .missingTimestamp)); continue
                }
                if let audit = request.audit, updated < audit.start.timeIntervalSince1970 { reachedOld = true; continue }
                if !request.visited.contains(id) { request.threads.append(id) }
            }
            request.threadListCursor = reachedOld ? nil : page.nextCursor
            if request.threadListCursor == nil {
                if !request.archived { request.archived = true }
                else { request.discovering = false }
            }
        }
        if let threadID = request.threads.first,
           bytesRead < historyBudget.maximumBytes,
           ProcessInfo.processInfo.systemUptime - started < historyBudget.maximumDuration {
            let metadata = try await history.readThread(threadID, budget: remainingBudget())
            bytesRead += metadata.bytesRead
            guard metadata.thread["id"].string == threadID else { throw CodexCollectionError.malformedCapture }
            let checkpointLane = request.audit.map { "public-history:\($0.id):\(threadID)" } ?? "public-live:\(threadID)"
            let documentID = try await documentIdentity(checkpointLane, cryptography: cryptography)
            let coverageID = try await documentIdentity("public-history-thread:\(threadID)", cryptography: cryptography)
            if request.audit != nil, request.itemCursor == nil {
                // Unchanged since an earlier audit finished reading it: nothing new can be in this window.
                let updated = metadata.thread["updatedAt"].number
                if let updated, updated.isFinite, let previous = try await checkpointLookup(coverageID)?.adapterState,
                   let coverage = try? JSONDecoder().decode(CodexThreadAuditCoverage.self, from: previous),
                   coverage.kind == CodexThreadAuditCoverage.kind, coverage.authorityID == authority.rawValue,
                   coverage.updatedAt == updated, coverage.coversThread {
                    guard request.visited.count < 4096 else { throw CodexHistoryError.responseLimitExceeded }
                    request.visited.append(threadID)
                    request.finishThread()
                    return try finishHistory(request, sources: sources, gaps: gaps, checkpoints: checkpoints, bytesRead: bytesRead, recovered: recovered)
                }
                request.threadUpdatedAt = updated.flatMap { $0.isFinite ? $0 : nil }
                request.threadListedAt = Date().timeIntervalSince1970
            }
            if request.audit == nil, request.itemCursor == nil,
               let previous = try await checkpointLookup(documentID)?.adapterState {
                if let state = try? JSONDecoder().decode(CodexPublicCheckpoint.self, from: previous),
                   state.kind == "codex-public-checkpoint-v1", state.parserContract == Self.parserContract {
                    guard state.authorityID == authority.rawValue else { throw CodexCollectionError.authorityConflict }
                    request.itemCursor = state.pollCursor
                    request.liveBootstrapped = state.bootstrapped ?? true
                    if !request.liveBootstrapped { request.pageLimit = state.coldPageLimit }
                } else {
                    // An unreadable cursor restarts at the bounded tail; earlier unread items are a visible gap.
                    gaps.append(.init(reason: .sourceChanged, capabilityID: documentID))
                }
            }
            let coldLive = request.audit == nil && !request.liveBootstrapped
            let itemBudget = try remainingBudget()
            readingItems = true
            let rawPage = try await history.listItems(threadID: threadID, turnID: nil,
                cursor: request.itemCursor, limit: coldLive && request.pageLimit != 1 ? min(pageSize + 1, 256) : pageSize,
                direction: request.audit == nil && !coldLive ? .ascending : .descending,
                budget: itemBudget)
            bytesRead += rawPage.bytesRead
            // Pinned item cursors are exclusive of the oldest item in a descending page.
            // Request one extra boundary item, retaining only the newest configured tail.
            // Its returned opposite-direction cursor replays every retained tail item.
            let trimmedColdTail = coldLive && rawPage.nextCursor != nil && rawPage.data.count > 1 && request.pageLimit != 1
            let page = CodexHistoryPage(data: trimmedColdTail ? Array(rawPage.data.dropLast()) : rawPage.data,
                nextCursor: rawPage.nextCursor, backwardsCursor: rawPage.backwardsCursor, bytesRead: rawPage.bytesRead)
            if coldLive {
                request.liveBootstrapped = true
                if rawPage.nextCursor != nil {
                    guard let boundary = rawPage.backwardsCursor else { throw CodexHistoryError.malformedResponse }
                    if trimmedColdTail { request.itemCursor = boundary }
                    else {
                        // A single returned item has no earlier exclusive replay boundary.
                        // Revisit this bounded descending tail instead of skipping unfinished
                        // content; retain an explicit old-prefix/cursor coverage gap.
                        request.liveBootstrapped = false; request.itemCursor = nil; request.pageLimit = 1
                        gaps.append(.init(reason: .unresolvedCorrelation, capabilityID: documentID))
                    }
                    gaps.append(.init(reason: .budgetExhausted, capabilityID: documentID))
                }
            }
            if request.audit == nil, page.data.isEmpty {
                if request.emptyPageIsCurrent { return .init(sources: [], coverageGaps: Array(Set(gaps))) }
                throw CodexCollectionError.awaitingHistory
            }
            // Retain the earliest unfinished page across continuation commits. A long-running
            // tool can complete after later pages exist; revisiting only the last page loses it.
            if request.audit == nil, !request.hasReplayCursor, page.data.contains(where: { $0["completedAtMs"].number == nil }) {
                request.hasReplayCursor = true; request.replayCursor = request.itemCursor
            }
            var turnTimes: [String: DateInterval] = [:]
            if page.data.contains(where: { $0["completedAtMs"].number == nil && $0["startedAtMs"].number == nil }),
               bytesRead < historyBudget.maximumBytes,
               ProcessInfo.processInfo.systemUptime - started < historyBudget.maximumDuration {
                do {
                    let turns = try await history.listTurns(threadID: threadID, cursor: nil, limit: 256, direction: .descending,
                        budget: remainingBudget())
                    bytesRead += turns.bytesRead
                    for turn in turns.data {
                        if let id = turn["id"].nonemptyString, let start = turn["startedAt"].number,
                           let end = turn["completedAt"].number ?? turn["startedAt"].number,
                           start.isFinite, end.isFinite, end >= start {
                            turnTimes[id] = DateInterval(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
                        }
                    }
                } catch CodexHistoryError.missingMethod {
                    gaps.append(operationGap(request: request, reason: .unsupportedContent, required: true))
                } catch CodexHistoryError.rejectedParameters {
                    gaps.append(operationGap(request: request, reason: .malformedSource, required: true))
                } catch CodexHistoryError.malformedResponse {
                    gaps.append(operationGap(request: request, reason: .malformedSource, required: true))
                }

            }
            let provenance: SourceProvenance = request.audit.map(SourceProvenance.historical) ?? .live
            let batch = try await importPublicItems(page, thread: metadata.thread, observedAt: observedAt,
                provenance: provenance, turnTimes: turnTimes, cryptography: cryptography)
            request.consecutiveBudgetFailures = 0
            sources += batch.sources; gaps += batch.coverageGaps
            recovered += batch.recoveredReferences
            // Only a complete pass can resolve a session-wide operation omission. A warm live
            // cursor reads a suffix, and a final readable page cannot repair an earlier gap.
            if page.nextCursor == nil, !request.threadPartial, batch.coverageGaps.isEmpty, gaps.isEmpty,
               request.audit != nil || coldLive {
                recovered.append(.init(session: try SessionIdentity(provider: .codex, profileID: profileID, sessionID: threadID),
                    parserContract: Self.parserContract))
            }
            if !gaps.isEmpty { request.threadPartial = true }
            for entry in page.data {
                let item = entry["item"]
                let ids = [item["agentThreadId"].string].compactMap { $0 }
                    + (item["receiverThreadIds"].array ?? []).compactMap(\.string)
                for child in ids where child != threadID && !request.threads.contains(child) &&
                    !request.children.contains(child) && !request.visited.contains(child) {
                    if request.children.count < 256 { request.children.append(child) }
                    else { gaps.append(.init(reason: .budgetExhausted)) }
                }
            }
            // Audit cursors travel in the continuation; only the live lane is resumed from a checkpoint.
            if request.audit == nil {
                let state = CodexPublicCheckpoint(kind: "codex-public-checkpoint-v1",
                    authorityID: authority.rawValue, pollCursor: request.hasReplayCursor ? request.replayCursor : request.itemCursor,
                    bootstrapped: request.liveBootstrapped, coldPageLimit: request.liveBootstrapped ? nil : request.pageLimit,
                    parserContract: Self.parserContract)
                let protectedCursor = try JSONEncoder().encode(state)
                let revision = try await cryptography.revision(canonicalBytes: protectedCursor)
                checkpoints.append(.init(capabilityID: documentID, sourceDocumentID: documentID, revision: revision,
                    byteOffset: 0, lastContentTime: batch.sources.map(\.record.metadata.contentTime).max(),
                    gaps: batch.coverageGaps, adapterState: protectedCursor))
            }
            let reachedHistoricalCutoff = request.audit.map { audit in
                page.data.contains { entry in
                    guard let ms = entry["completedAtMs"].number ?? entry["startedAtMs"].number, ms.isFinite else { return false }
                    return ms / 1000 < audit.start.timeIntervalSince1970
                }
            } ?? false
            if reachedHistoricalCutoff, page.nextCursor != nil {
                request.partial = true
                // Public ordering is by item position. Earlier unfinished/edited items can have
                // recent completion dates, so stopping at the cold tail is an explicit gap.
                gaps.append(.init(reason: .budgetExhausted, capabilityID: documentID,
                    interval: request.audit.map { DateInterval(start: $0.start, end: $0.end) }))
            }
            if let next = page.nextCursor, !reachedHistoricalCutoff, !coldLive {
                guard next != request.itemCursor else { throw CodexCollectionError.malformedCapture }
                request.itemCursor = next
            } else {
                guard request.visited.count < 4096 else { throw CodexHistoryError.responseLimitExceeded }
                request.visited.append(threadID)
                if let audit = request.audit, let updated = request.threadUpdatedAt, let listed = request.threadListedAt {
                    let coverage = try JSONEncoder().encode(CodexThreadAuditCoverage(kind: CodexThreadAuditCoverage.kind,
                        authorityID: authority.rawValue, updatedAt: updated, listedAt: listed,
                        auditEnd: audit.end.timeIntervalSince1970, parserContract: Self.parserContract,
                        hasOmissions: request.threadPartial || !gaps.isEmpty))
                    checkpoints.append(.init(capabilityID: coverageID, sourceDocumentID: coverageID,
                        revision: try await cryptography.revision(canonicalBytes: coverage), byteOffset: 0,
                        lastContentTime: batch.sources.map(\.record.metadata.contentTime).max(), adapterState: coverage))
                }
                request.finishThread()
            }
        }
        } catch CodexHistoryError.missingMethod {
            request.partial = true; request.consecutiveBudgetFailures = 0
            gaps.append(operationGap(request: request, reason: .unsupportedContent, required: true))
            if request.threads.isEmpty { request.discovering = false } else { request.finishThread() }
        } catch CodexHistoryError.rejectedParameters {
            request.partial = true; request.consecutiveBudgetFailures = 0
            gaps.append(operationGap(request: request, reason: .malformedSource, required: true))
            if request.threads.isEmpty { request.discovering = false } else { request.finishThread() }
        } catch CodexHistoryError.malformedResponse {
            request.partial = true; request.consecutiveBudgetFailures = 0
            gaps.append(operationGap(request: request, reason: .malformedSource, required: true))
            if request.threads.isEmpty { request.discovering = false } else { request.finishThread() }
        } catch CodexHistoryError.responseLimitExceeded {
            budgetFailure = true
            gaps.append(.init(reason: .budgetExhausted))
        } catch CodexHistoryError.timedOut {
            budgetFailure = true
            gaps.append(.init(reason: .budgetExhausted))
        } catch let failure as CodexHistoryReadFailure where failure.reason == .responseLimitExceeded || failure.reason == .timedOut {
            budgetFailure = true
            bytesRead += failure.bytesRead
            gaps.append(.init(reason: .budgetExhausted))
        }
        if budgetFailure || checkpoints.isEmpty && !request.threads.isEmpty && bytesRead >= historyBudget.maximumBytes {
            request.consecutiveBudgetFailures += 1
            if readingItems { request.pageLimit = 1 }
            if request.consecutiveBudgetFailures >= 3 {
                request.partial = true
                request.consecutiveBudgetFailures = 0
                request.itemCursor = nil; request.hasReplayCursor = false; request.replayCursor = nil
                request.liveBootstrapped = false; request.pageLimit = nil
                if request.threads.isEmpty { request.discovering = false }
                else {
                    if request.visited.count < 4096 { request.visited.append(request.threads[0]) }
                    request.finishThread()
                }
            }
        }
        if bytesRead > historyBudget.maximumBytes || ProcessInfo.processInfo.systemUptime - started > historyBudget.maximumDuration {
            gaps.append(.init(reason: .budgetExhausted))
        }
        return try finishHistory(request, sources: sources, gaps: gaps, checkpoints: checkpoints, bytesRead: bytesRead, recovered: recovered)
    }
    private func operationGap(request: CodexHistoryRequest, reason: CoverageGapReason,
                              required: Bool) -> CoverageGap {
        let session = request.threads.first.flatMap {
            try? SessionIdentity(provider: .codex, profileID: profileID, sessionID: $0)
        }
        let operation: CollectionOperation = request.threads.isEmpty || request.audit != nil ? .historicalRead : .liveRead
        return .init(reason: reason, scope: collectionScope, operation: operation,
            recovery: session.map { .init(session: $0, parserContract: Self.parserContract) },
            isRequiredFormatFailure: required)
    }
    private func finishHistory(_ request: CodexHistoryRequest, sources: [CollectedSource], gaps: [CoverageGap],
                               checkpoints: [SourceCheckpoint], bytesRead: Int,
                               recovered: [CoverageRecoveryReference] = []) throws -> CollectionBatch {
        var request = request
        if request.audit != nil, !gaps.isEmpty { request.partial = true }
        let pendingWork = request.discovering || !request.threads.isEmpty || !request.children.isEmpty
        let continuation = pendingWork ? try packet(request) : nil
        let contentTimes = sources.map(\.record.metadata.contentTime).filter { request.audit?.includes(contentTime: $0) ?? true }
        return .init(sources: sources, coverageGaps: Array(Set(gaps)), checkpoints: checkpoints,
            continuation: continuation,
            historicalProgress: request.audit.map { .init(audit: $0, bytesRead: bytesRead,
                oldestContentTime: contentTimes.min(),
                newestContentTime: contentTimes.max(), hasUnreadContent: pendingWork || request.partial) },
            recoveredReferences: recovered)
    }
}
