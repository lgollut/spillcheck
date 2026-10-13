import Foundation

private func codexValidRelationshipID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= 4096 && !id.utf8.contains(0)
}

/// `parentThreadId` is documented as subagent-only. `forkedFromId` by itself is
/// ordinary copied lineage and must never turn a main conversation into a child.
private func codexPublicNativeChildParent(_ thread: CodexJSON) -> String? {
    guard let child = thread["id"].string else { return nil }
    let parent = thread["parentThreadId"].string
    let spawn = thread["source"]["subAgent"]["thread_spawn"]["parent_thread_id"].string
    guard let selected = parent ?? spawn, codexValidRelationshipID(selected), selected != child,
          parent == nil || spawn == nil || parent == spawn else { return nil }
    return selected
}

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
    /// These facts survive a bounded continuation, but not the next thread. Older queued
    /// final pages default to an unproven full read and cannot establish source absence.
    var threadReadBeganAtStart = false
    var threadHasInWindowItems = false
    var threadNativeChildParentID: String?
    /// Exact native relationship evidence from a parent's public item, never prompt text.
    var nativeChildParents: [String: String] = [:]
    var consecutiveBudgetFailures = 0
    var pageLimit: Int?
    var liveBootstrapped = false
    /// Thread metadata time and first item listing time for the thread an audit is reading.
    var threadUpdatedAt: Double?
    var threadListedAt: Double?
    /// A poll has no upstream event behind it, so an unchanged thread is current, not pending.
    var emptyPageIsCurrent = false
    /// Explicit source retries do not discover threads or follow child links.
    var selectedSourceOnly = false
    var transcriptPath: String?
    /// Internal encrypted continuation only. Fresh public inspections never reuse checkpoint proofs.
    var reviewWork: CodexReviewWork?
    init(audit: HistoricalAuditContext?, threads: [String] = []) {
        self.audit = audit; self.threads = threads; discovering = threads.isEmpty
    }
    private enum CodingKeys: String, CodingKey {
        case kind, audit, threads, threadListCursor, archived, discovering, itemCursor, children, visited
        case hasReplayCursor, replayCursor, partial, threadPartial, consecutiveBudgetFailures, pageLimit, liveBootstrapped
        case threadUpdatedAt, threadListedAt, selectedSourceOnly, transcriptPath, reviewWork
        case threadReadBeganAtStart, threadHasInWindowItems, threadNativeChildParentID, nativeChildParents
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
        threadReadBeganAtStart = try c.decodeIfPresent(Bool.self, forKey: .threadReadBeganAtStart) ?? false
        threadHasInWindowItems = try c.decodeIfPresent(Bool.self, forKey: .threadHasInWindowItems) ?? false
        threadNativeChildParentID = try c.decodeIfPresent(String.self, forKey: .threadNativeChildParentID)
        nativeChildParents = try c.decodeIfPresent([String: String].self, forKey: .nativeChildParents) ?? [:]
        consecutiveBudgetFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveBudgetFailures) ?? 0
        pageLimit = try c.decodeIfPresent(Int.self, forKey: .pageLimit)
        liveBootstrapped = try c.decodeIfPresent(Bool.self, forKey: .liveBootstrapped) ?? false
        threadUpdatedAt = try c.decodeIfPresent(Double.self, forKey: .threadUpdatedAt)
        threadListedAt = try c.decodeIfPresent(Double.self, forKey: .threadListedAt)
        selectedSourceOnly = try c.decodeIfPresent(Bool.self, forKey: .selectedSourceOnly) ?? false
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        reviewWork = try c.decodeIfPresent(CodexReviewWork.self, forKey: .reviewWork)
    }

    mutating func finishThread() {
        threads.removeFirst(); itemCursor = nil; reviewWork = nil
        hasReplayCursor = false; replayCursor = nil
        liveBootstrapped = false; pageLimit = nil
        threadUpdatedAt = nil; threadListedAt = nil; threadPartial = false
        threadReadBeganAtStart = false; threadHasInWindowItems = false; threadNativeChildParentID = nil
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
    let nativeChildParentID: String?
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
    let nativeChildParentID: String?

    var coversThread: Bool {
        parserContract == CodexAdapter.parserContract && hasOmissions == false
            && updatedAt + 1 <= auditEnd && listedAt >= updatedAt + 1
    }
}

extension CodexAdapter {
    func normalizeHistory(_ original: CodexHistoryRequest, observedAt: Date,
                          cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        let operation: CollectionOperation = original.audit != nil || original.discovering ? .historicalRead : .liveRead
        func gap(_ reason: CoverageGapReason, capabilityID: UUID? = nil) -> CoverageGap {
            .init(reason: reason, capabilityID: capabilityID, scope: collectionScope, operation: operation,
                diagnosticCode: reason.defaultDiagnosticCode, observedAt: observedAt)
        }
        guard original.threads.count <= 256, original.children.count <= 256, original.visited.count <= 4096,
              original.nativeChildParents.count <= 256,
              original.nativeChildParents.allSatisfy({ codexValidRelationshipID($0.key) && codexValidRelationshipID($0.value) && $0.key != $0.value }),
              original.threadNativeChildParentID.map(codexValidRelationshipID) ?? true,
              original.threads.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }),
              (0...3).contains(original.consecutiveBudgetFailures),
              original.pageLimit == nil || (1...256).contains(original.pageLimit!),
              original.itemCursor == nil || original.itemCursor!.utf8.count <= 64 * 1024,
              original.threadListCursor == nil || original.threadListCursor!.utf8.count <= 64 * 1024,
              !original.selectedSourceOnly || (original.audit != nil && !original.discovering && original.threads.count == 1 && original.children.isEmpty),
              original.transcriptPath == nil || (original.selectedSourceOnly && authority == .nativeRolloutTranscript),
              original.audit == nil || (original.audit!.end.timeIntervalSince1970.isFinite
                && original.audit!.start == original.audit!.end.addingTimeInterval(-HistoricalAuditContext.lookback)) else {
            return .init(sources: [], coverageGaps: [gap(.malformedSource)])
        }
        if original.reviewWork != nil {
            return try await normalizeReviewInspection(original, observedAt: observedAt, cryptography: cryptography)
        }
        if authority == .nativeRolloutTranscript {
            guard let path = original.transcriptPath, let thread = original.threads.first,
                  let audit = original.audit else {
                return .init(sources: [], coverageGaps: [gap(.sourceUnavailable)],
                    historicalProgress: original.audit.map { .init(audit: $0, bytesRead: 0, hasUnreadContent: true) })
            }
            let selected = try SessionIdentity(provider: .codex, profileID: profileID, sessionID: thread)
            if let choice = try await authorityLookup(selected) {
                guard choice.session == selected else { throw CodexCollectionError.authorityConflict }
                if choice.authorityID == CodexHookContentAdapter.authorityID {
                    return .init(sources: [], coverageGaps: [.init(reason: .unsupportedContent,
                        scope: .init(provider: .codex, profileID: profileID, interface: interface, path: .hook),
                        operation: .historicalRead, recovery: .init(session: selected,
                            parserContract: CodexHookContentAdapter.parserContract),
                        isRequiredFormatFailure: true, sourceKind: .codexHookEvent,
                        diagnosticCode: .hookContentUnavailable, observedAt: observedAt)],
                        historicalProgress: .init(audit: audit, bytesRead: 0, hasUnreadContent: true),
                        readEvidenceEligible: false)
                }
            }
            do {
                try await selectAuthority(sessionID: thread)
                let data = try readTranscript(path: path)
                let batch = try await importTranscript(data, documentID: documentIdentity(path, cryptography: cryptography),
                    observedAt: observedAt, provenance: .historical(audit), expectedSessionID: thread,
                    context: .init(sessionIdentifier: thread, transcriptPath: path), cryptography: cryptography)
                return .init(sources: batch.sources, coverageGaps: batch.coverageGaps, checkpoints: batch.checkpoints,
                    historicalProgress: .init(audit: audit, bytesRead: data.count,
                        oldestContentTime: batch.sources.map(\.record.metadata.contentTime).min(),
                        newestContentTime: batch.sources.map(\.record.metadata.contentTime).max(),
                        hasUnreadContent: batch.coverageGaps.contains { $0.requiresAnalysis }),
                    recoveredReferences: batch.recoveredReferences)
            } catch StorageError.capacityExceeded(.sourceAuthorities) {
                return .init(sources: [], coverageGaps: [operationGap(request: original,
                    observedAt: observedAt, reason: .budgetExhausted, required: false, diagnostic: .authorityStorageLimit)],
                    historicalProgress: .init(audit: audit, bytesRead: 0, hasUnreadContent: true),
                    readEvidenceEligible: false)
            } catch CodexCollectionError.unsafeTranscriptPath {
                return .init(sources: [], coverageGaps: [gap(.sourceUnavailable)],
                    historicalProgress: .init(audit: audit, bytesRead: 0, hasUnreadContent: true))
            } catch CodexCollectionError.awaitingHistory {
                return .init(sources: [], coverageGaps: [gap(.sourceUnavailable)],
                    historicalProgress: .init(audit: audit, bytesRead: 0, hasUnreadContent: true))
            }
        }
        try Task.checkCancellation()
        var request = original, bytesRead = 0
        var readEvidenceEligible = true
        var readerVersions = Set<String>()
        var missingReaderVersion = false
        func observeReader(_ version: String?) {
            guard let version, !version.isEmpty, version.utf8.count <= 256,
                  !version.utf8.contains(0) else { missingReaderVersion = true; return }
            readerVersions.insert(version)
        }
        var observedReaderVersion: String? {
            !missingReaderVersion && readerVersions.count == 1 ? readerVersions.first : nil
        }
        var gaps: [CoverageGap] = []
        var sources: [CollectedSource] = []
        var checkpoints: [SourceCheckpoint] = []
        var recovered: [CoverageRecoveryReference] = []
        var pendingRecoveryDependencies: [CoverageRecoveryDependency] = []
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
            observeReader(page.readerVersion)
            bytesRead += page.bytesRead
            var reachedOld = false
            for thread in page.data {
                guard let id = thread["id"].nonemptyString, let updated = thread["updatedAt"].number, updated.isFinite else {
                    gaps.append(gap(.missingTimestamp)); continue
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
            let selected = try SessionIdentity(provider: .codex, profileID: profileID, sessionID: threadID)
            if let choice = try await authorityLookup(selected) {
                guard choice.session == selected else { throw CodexCollectionError.authorityConflict }
                if choice.authorityID == CodexHookContentAdapter.authorityID {
                    // A native profile audit excludes only this exact hook-owned
                    // session and continues other sources. An explicit retry cannot
                    // read its history or claim that hook coverage was recovered.
                    if request.selectedSourceOnly || request.audit == nil {
                        gaps.append(.init(reason: .unsupportedContent,
                            scope: .init(provider: .codex, profileID: profileID, interface: interface, path: .hook),
                            operation: operation, recovery: .init(session: selected,
                                parserContract: CodexHookContentAdapter.parserContract),
                            isRequiredFormatFailure: true, sourceKind: .codexHookEvent,
                            diagnosticCode: .hookContentUnavailable, observedAt: observedAt))
                    }
                    guard request.visited.count < 4096 else { throw CodexHistoryError.responseLimitExceeded }
                    request.visited.append(threadID)
                    request.finishThread()
                    return try finishHistory(request, sources: sources, gaps: gaps, checkpoints: checkpoints,
                        bytesRead: bytesRead, recovered: recovered, readEvidenceEligible: false,
                        observedReaderVersion: observedReaderVersion)
                }
            }
            let metadata = try await history.readThread(threadID, budget: remainingBudget())
            observeReader(metadata.readerVersion)
            bytesRead += metadata.bytesRead
            guard metadata.thread["id"].string == threadID else { throw CodexCollectionError.malformedCapture }
            let checkpointLane = request.audit.map { "public-history:\($0.id):\(threadID)" } ?? "public-live:\(threadID)"
            let documentID = try await documentIdentity(checkpointLane, cryptography: cryptography)
            let coverageID = try await documentIdentity("public-history-thread:\(threadID)", cryptography: cryptography)
            let previousCoverage = try await checkpointLookup(coverageID)?.adapterState.flatMap {
                try? JSONDecoder().decode(CodexThreadAuditCoverage.self, from: $0)
            }
            request.threadNativeChildParentID = codexPublicNativeChildParent(metadata.thread)
                ?? request.threadNativeChildParentID ?? request.nativeChildParents[threadID]
                ?? (previousCoverage?.parserContract == Self.parserContract ? previousCoverage?.nativeChildParentID : nil)
            if request.threadNativeChildParentID == nil, request.audit != nil {
                let liveID = try await documentIdentity("public-live:\(threadID)", cryptography: cryptography)
                if let bytes = try await checkpointLookup(liveID)?.adapterState,
                   let state = try? JSONDecoder().decode(CodexPublicCheckpoint.self, from: bytes),
                   state.parserContract == Self.parserContract, state.authorityID == authority.rawValue {
                    request.threadNativeChildParentID = state.nativeChildParentID
                }
            }
            if request.audit != nil, request.itemCursor == nil {
                // Unchanged since an earlier audit finished reading it: nothing new can be in this window.
                let updated = metadata.thread["updatedAt"].number
                if !request.selectedSourceOnly, let updated, updated.isFinite, let coverage = previousCoverage,
                   coverage.kind == CodexThreadAuditCoverage.kind, coverage.authorityID == authority.rawValue,
                   coverage.updatedAt == updated, coverage.coversThread,
                   coverage.nativeChildParentID == request.threadNativeChildParentID {
                    guard request.visited.count < 4096 else { throw CodexHistoryError.responseLimitExceeded }
                    request.visited.append(threadID)
                    request.finishThread()
                    return try finishHistory(request, sources: sources, gaps: gaps, checkpoints: checkpoints, bytesRead: bytesRead, recovered: recovered, observedReaderVersion: observedReaderVersion)
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
                    request.threadNativeChildParentID = request.threadNativeChildParentID ?? state.nativeChildParentID
                    if !request.liveBootstrapped { request.pageLimit = state.coldPageLimit }
                } else {
                    // An unreadable cursor restarts at the bounded tail; earlier unread items are a visible gap.
                    gaps.append(gap(.sourceChanged, capabilityID: documentID))
                }
            }
            let coldLive = request.audit == nil && !request.liveBootstrapped
            if request.itemCursor == nil, request.audit != nil || coldLive {
                request.threadReadBeganAtStart = true
            }
            let itemBudget = try remainingBudget()
            let readStartsAtThreadBoundary = request.itemCursor == nil
            readingItems = true
            let rawPage = try await history.listItems(threadID: threadID, turnID: nil,
                cursor: request.itemCursor, limit: coldLive && request.pageLimit != 1 ? min(pageSize + 1, 256) : pageSize,
                direction: request.audit == nil && !coldLive ? .ascending : .descending,
                budget: itemBudget)
            observeReader(rawPage.readerVersion)
            bytesRead += rawPage.bytesRead
            // Pinned item cursors are exclusive of the oldest item in a descending page.
            // Request one extra boundary item, retaining only the newest configured tail.
            // Its returned opposite-direction cursor replays every retained tail item.
            let trimmedColdTail = coldLive && rawPage.nextCursor != nil && rawPage.data.count > 1 && request.pageLimit != 1
            let page = CodexHistoryPage(data: trimmedColdTail ? Array(rawPage.data.dropLast()) : rawPage.data,
                nextCursor: rawPage.nextCursor, backwardsCursor: rawPage.backwardsCursor, bytesRead: rawPage.bytesRead, readerVersion: rawPage.readerVersion)
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
                        gaps.append(gap(.unresolvedCorrelation, capabilityID: documentID))
                    }
                    gaps.append(gap(.budgetExhausted, capabilityID: documentID))
                }
            }
            if request.audit == nil, page.data.isEmpty {
                if request.emptyPageIsCurrent { return .init(sources: [], coverageGaps: Array(Set(gaps)), observedRead: true,
                    observedReaderVersion: observedReaderVersion) }
                throw CodexCollectionError.awaitingHistory
            }
            // Retain the earliest unfinished page across continuation commits. A long-running
            // tool can complete after later pages exist; revisiting only the last page loses it.
            if request.audit == nil, !request.hasReplayCursor, page.data.contains(where: { $0["completedAtMs"].number == nil }) {
                request.hasReplayCursor = true; request.replayCursor = request.itemCursor
            }
            var turnTimes: [String: DateInterval] = [:]
            var reviewTurns: CodexHistoryPage?
            let needsReviewRoots = readStartsAtThreadBoundary && page.nextCursor == nil && !trimmedColdTail
                && page.data.contains { $0["item"]["type"].string == "enteredReviewMode" }
            if needsReviewRoots || page.data.contains(where: { $0["completedAtMs"].number == nil && $0["startedAtMs"].number == nil }),
               bytesRead < historyBudget.maximumBytes,
               ProcessInfo.processInfo.systemUptime - started < historyBudget.maximumDuration {
                do {
                    let turns = try await history.listTurns(threadID: threadID, cursor: nil, limit: 256, direction: .descending,
                        budget: remainingBudget())
                    observeReader(turns.readerVersion)
                    bytesRead += turns.bytesRead
                    reviewTurns = turns
                    for turn in turns.data {
                        if let id = turn["id"].nonemptyString, let start = turn["startedAt"].number,
                           let end = turn["completedAt"].number ?? turn["startedAt"].number,
                           start.isFinite, end.isFinite, end >= start {
                            turnTimes[id] = DateInterval(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
                        }
                    }
                } catch CodexHistoryError.missingMethod {
                    gaps.append(operationGap(request: request, observedAt: observedAt, reason: .unsupportedContent, required: true))
                } catch CodexHistoryError.rejectedParameters {
                    gaps.append(operationGap(request: request, observedAt: observedAt, reason: .malformedSource, required: true))
                } catch CodexHistoryError.malformedResponse {
                    gaps.append(operationGap(request: request, observedAt: observedAt, reason: .malformedSource, required: true))
                }

            }
            let provenance: SourceProvenance = request.audit.map(SourceProvenance.historical) ?? .live
            let batch = try await importPublicItems(page, thread: metadata.thread, observedAt: observedAt,
                provenance: provenance, turnTimes: turnTimes, cryptography: cryptography)
            request.consecutiveBudgetFailures = 0
            sources += batch.sources; gaps += batch.coverageGaps
            // Whole-thread single-response proof is the fast path. EXIT rows on
            // other pages schedule their own fresh exact-turn inspection instead.
            // ENTRY still requires the complete native causal-root membership view.
            if readStartsAtThreadBoundary,
               page.nextCursor == nil, !trimmedColdTail, !request.threadPartial {
                pendingRecoveryDependencies = reviewPresentationDependencies(page: page, batch: batch, thread: metadata.thread, turns: reviewTurns)
            }
            let immediateGaps = Set(pendingRecoveryDependencies.map(\.provisionalGap))
            let reviewTargets = try await reviewInspectionTargets(page: page, batch: batch,
                thread: metadata.thread, cryptography: cryptography).filter { !immediateGaps.contains($0.gap) }
            if !reviewTargets.isEmpty {
                request.reviewWork = .init(targets: reviewTargets, finishThreadAfterInspection: false)
            }
            let provisionalGaps = immediateGaps.union(reviewTargets.map(\.gap))
            let definiteBatchGaps = batch.coverageGaps.filter { !provisionalGaps.contains($0) }
            request.threadHasInWindowItems = request.threadHasInWindowItems || page.data.contains { entry in
                let time: Date?
                if let milliseconds = entry["completedAtMs"].number ?? entry["startedAtMs"].number,
                   milliseconds.isFinite, abs(milliseconds) < 1e15 {
                    time = Date(timeIntervalSince1970: milliseconds / 1000)
                } else if let turn = entry["turnId"].string, let interval = turnTimes[turn] {
                    time = entry["item"]["type"].string == "userMessage" ? interval.start : interval.end
                } else { time = nil }
                return time.map { request.audit?.includes(contentTime: $0) ?? true } ?? false
            }
            // A parser budget omission skipped an actual item. A transport budget failure
            // below merely queues the same page again and must not poison the whole audit.
            if definiteBatchGaps.contains(where: { $0.requiresAnalysis }) { request.partial = true }
            recovered += batch.recoveredReferences
            // Public history currently exposes no structurally attributed incoming native
            // child task. Its userMessage rows may be inherited from a fork; neither those
            // rows nor a parent's spawn arguments prove this required representation exists.
            // A complete nonempty read establishes this limitation, never a warm suffix,
            // empty source, failed page, or a tail with an unread prefix.
            if request.threadNativeChildParentID != nil, request.threadReadBeganAtStart,
               request.threadHasInWindowItems, page.nextCursor == nil,
               !request.threadPartial, !gaps.contains(where: { $0.requiresAnalysis && !provisionalGaps.contains($0) }), request.audit != nil || coldLive {
                gaps.append(.init(reason: .unsupportedContent, scope: collectionScope,
                    contentType: .userPrompt, operation: operation,
                    recovery: .init(session: selected, itemID: Self.nativeChildInputRequirementID,
                        parserContract: Self.parserContract),
                    isRequiredFormatFailure: true,
                    diagnosticCode: .nativeChildInputUnavailable, observedAt: observedAt))
                request.partial = true
            }
            // Only a complete pass can resolve a session-wide operation omission. A warm live
            // cursor reads a suffix, and a final readable page cannot repair an earlier gap.
            if page.nextCursor == nil, !request.threadPartial, batch.coverageGaps.isEmpty, gaps.isEmpty,
               request.audit != nil || coldLive {
                recovered.append(.init(session: try SessionIdentity(provider: .codex, profileID: profileID, sessionID: threadID),
                    parserContract: Self.parserContract))
            }
            if gaps.contains(where: { $0.requiresAnalysis && !provisionalGaps.contains($0) }) { request.threadPartial = true }
            for entry in page.data {
                let item = entry["item"]
                let ids = [item["agentThreadId"].string].compactMap { $0 }
                    + (item["receiverThreadIds"].array ?? []).compactMap(\.string)
                // Other collaboration calls can target a parent or peer. Only an explicit
                // creation record establishes the receiver as this thread's native child.
                let nativeRelationship = item["type"].string == "subAgentActivity" && item["kind"].string == "started"
                    || item["type"].string == "collabAgentToolCall" && item["tool"].string == "spawnAgent"
                        && item["senderThreadId"].string == threadID && item["status"].string == "completed"
                for child in ids where !request.selectedSourceOnly && nativeRelationship && child != threadID
                    && codexValidRelationshipID(child) {
                    if request.nativeChildParents[child] == nil, request.nativeChildParents.count >= 256 {
                        gaps.append(gap(.budgetExhausted)); request.partial = true
                    } else if request.nativeChildParents[child] == nil {
                        request.nativeChildParents[child] = threadID
                        // Discovery can list a child before its parent. Revisit once when the
                        // original spawn supplies proof missing from that earlier read.
                        if request.visited.contains(child), !request.threads.contains(child), !request.children.contains(child) {
                            if request.children.count < 256 { request.children.append(child) }
                            else { gaps.append(gap(.budgetExhausted)); request.partial = true }
                        }
                    }
                }
                for child in ids where !request.selectedSourceOnly && child != threadID && !request.threads.contains(child) &&
                    !request.children.contains(child) && !request.visited.contains(child) {
                    if request.children.count < 256 { request.children.append(child) }
                    else { gaps.append(gap(.budgetExhausted)); request.partial = true }
                }
            }
            // Audit cursors travel in the continuation; only the live lane is resumed from a checkpoint.
            if request.audit == nil {
                let state = CodexPublicCheckpoint(kind: "codex-public-checkpoint-v1",
                    authorityID: authority.rawValue, pollCursor: request.hasReplayCursor ? request.replayCursor : request.itemCursor,
                    bootstrapped: request.liveBootstrapped, coldPageLimit: request.liveBootstrapped ? nil : request.pageLimit,
                    parserContract: Self.parserContract, nativeChildParentID: request.threadNativeChildParentID)
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
                gaps.append(gap(.budgetExhausted, capabilityID: documentID))
            }
            if let next = page.nextCursor, !reachedHistoricalCutoff, !coldLive {
                guard next != request.itemCursor else { throw CodexCollectionError.malformedCapture }
                request.itemCursor = next
            } else {
                guard request.visited.count < 4096 else { throw CodexHistoryError.responseLimitExceeded }
                if request.reviewWork == nil { request.visited.append(threadID) }
                if pendingRecoveryDependencies.isEmpty, request.reviewWork == nil, let audit = request.audit, let updated = request.threadUpdatedAt, let listed = request.threadListedAt {
                    let coverage = try JSONEncoder().encode(CodexThreadAuditCoverage(kind: CodexThreadAuditCoverage.kind,
                        authorityID: authority.rawValue, updatedAt: updated, listedAt: listed,
                        auditEnd: audit.end.timeIntervalSince1970, parserContract: Self.parserContract,
                        hasOmissions: request.threadPartial || gaps.contains(where: { $0.requiresAnalysis }),
                        nativeChildParentID: request.threadNativeChildParentID))
                    checkpoints.append(.init(capabilityID: coverageID, sourceDocumentID: coverageID,
                        revision: try await cryptography.revision(canonicalBytes: coverage), byteOffset: 0,
                        lastContentTime: batch.sources.map(\.record.metadata.contentTime).max(), adapterState: coverage))
                }
                if request.reviewWork != nil { request.reviewWork?.finishThreadAfterInspection = true }
                else { request.finishThread() }
            }
        }
        } catch StorageError.capacityExceeded(.sourceAuthorities) {
            readEvidenceEligible = false
            request.partial = true; request.consecutiveBudgetFailures = 0
            gaps.append(operationGap(request: request, observedAt: observedAt, reason: .budgetExhausted,
                required: false, diagnostic: .authorityStorageLimit))
            if request.threads.isEmpty { request.discovering = false } else { request.finishThread() }
        } catch CodexHistoryError.missingMethod {
            request.partial = true; request.consecutiveBudgetFailures = 0
            gaps.append(operationGap(request: request, observedAt: observedAt, reason: .unsupportedContent, required: true))
            if request.threads.isEmpty { request.discovering = false } else { request.finishThread() }
        } catch CodexHistoryError.rejectedParameters {
            request.partial = true; request.consecutiveBudgetFailures = 0
            gaps.append(operationGap(request: request, observedAt: observedAt, reason: .malformedSource, required: true))
            if request.threads.isEmpty { request.discovering = false } else { request.finishThread() }
        } catch CodexHistoryError.malformedResponse {
            request.partial = true; request.consecutiveBudgetFailures = 0
            gaps.append(operationGap(request: request, observedAt: observedAt, reason: .malformedSource, required: true))
            if request.threads.isEmpty { request.discovering = false } else { request.finishThread() }
        } catch CodexHistoryError.responseLimitExceeded {
            budgetFailure = true
            gaps.append(gap(.budgetExhausted))
        } catch CodexHistoryError.timedOut {
            budgetFailure = true
            gaps.append(gap(.budgetExhausted))
        } catch let failure as CodexHistoryReadFailure where failure.reason == .responseLimitExceeded || failure.reason == .timedOut {
            budgetFailure = true
            bytesRead += failure.bytesRead
            gaps.append(gap(.budgetExhausted))
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
            gaps.append(gap(.budgetExhausted))
        }
        return try finishHistory(request, sources: sources, gaps: gaps, checkpoints: checkpoints, bytesRead: bytesRead,
            recovered: recovered, readEvidenceEligible: readEvidenceEligible, observedReaderVersion: observedReaderVersion,
            pendingRecoveryDependencies: pendingRecoveryDependencies)
    }
    private func operationGap(request: CodexHistoryRequest, observedAt: Date, reason: CoverageGapReason,
                              required: Bool, diagnostic: CoverageDiagnosticCode? = nil) -> CoverageGap {
        let session = request.threads.first.flatMap {
            try? SessionIdentity(provider: .codex, profileID: profileID, sessionID: $0)
        }
        let operation: CollectionOperation = request.threads.isEmpty || request.audit != nil ? .historicalRead : .liveRead
        return .init(reason: reason, scope: collectionScope, operation: operation,
            recovery: session.map { .init(session: $0, parserContract: Self.parserContract) },
            isRequiredFormatFailure: required, diagnosticCode: diagnostic ?? reason.defaultDiagnosticCode, observedAt: observedAt)
    }
    private func finishHistory(_ request: CodexHistoryRequest, sources: [CollectedSource], gaps: [CoverageGap],
                               checkpoints: [SourceCheckpoint], bytesRead: Int,
                               recovered: [CoverageRecoveryReference] = [], readEvidenceEligible: Bool = true,
                               observedReaderVersion: String? = nil,
                               pendingRecoveryDependencies: [CoverageRecoveryDependency] = []) throws -> CollectionBatch {
        var request = request
        let provisionalGaps = Set(pendingRecoveryDependencies.map(\.provisionalGap))
            .union(request.reviewWork?.targets.map(\.gap) ?? [])
        if request.audit != nil, gaps.contains(where: {
            $0.reason != .budgetExhausted && $0.requiresAnalysis && !provisionalGaps.contains($0)
        }) { request.partial = true }
        let pendingWork = request.reviewWork != nil || request.discovering || !request.threads.isEmpty || !request.children.isEmpty
        let continuation = pendingWork ? try packet(request) : nil
        var failureRequest = request
        failureRequest.partial = true
        // finishThread may already have selected another thread. Failure belongs
        // to the dependency's original session, not that next thread's read.
        if let thread = request.threads.first, pendingRecoveryDependencies.contains(where: {
            $0.provisionalGap.recovery?.session?.sessionID == thread
        }) { failureRequest.threadPartial = true }
        let failedDependencyContinuation = pendingWork && !pendingRecoveryDependencies.isEmpty ? try packet(failureRequest) : nil
        let contentTimes = sources.map(\.record.metadata.contentTime).filter { request.audit?.includes(contentTime: $0) ?? true }
        return .init(sources: sources, coverageGaps: Array(Set(gaps)), checkpoints: checkpoints,
            continuation: continuation, unresolvedRecoveryContinuation: failedDependencyContinuation,
            historicalProgress: request.audit.map { .init(audit: $0, bytesRead: bytesRead,
                oldestContentTime: contentTimes.min(),
                newestContentTime: contentTimes.max(), hasUnreadContent: pendingWork || request.partial) },
            recoveredReferences: recovered, pendingRecoveryDependencies: pendingRecoveryDependencies,
            readEvidenceEligible: readEvidenceEligible, observedReaderVersion: observedReaderVersion)
    }
}
