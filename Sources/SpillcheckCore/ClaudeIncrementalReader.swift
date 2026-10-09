import Darwin
import Foundation

/// Payload bytes include boundary verification reads. Unchanged, caught-up sources read zero bytes.
public struct ClaudeIncrementalRead: Sendable {
    public let batch: CollectionBatch
    public let bytesRead: Int
    public let hasForwardContent: Bool
    public let hasUnreadContent: Bool
    public let canContinueHistory: Bool
    public let oldestContentTime: Date?
    public let newestContentTime: Date?
    let toolIDs: Set<String>
    let promptIDs: Set<String>
    let hasFinalResponse: Bool
}

struct ClaudeFileSignature: Codable, Equatable, Sendable {
    let device: UInt64, inode: UInt64, birthSeconds: Int64, birthNanos: Int64
    let size: UInt64, modifiedSeconds: Int64, modifiedNanos: Int64
    init(_ value: stat) {
        device = UInt64(value.st_dev); inode = value.st_ino
        birthSeconds = Int64(value.st_birthtimespec.tv_sec); birthNanos = Int64(value.st_birthtimespec.tv_nsec)
        size = UInt64(max(0, value.st_size))
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
    }
    func sameFile(_ other: Self) -> Bool {
        device == other.device && inode == other.inode && birthSeconds == other.birthSeconds && birthNanos == other.birthNanos
    }
}

/// This versioned state is sealed inside SourceCheckpoint. It contains no source text.
struct ClaudeReadCursor: Codable, Sendable {
    var version = 1
    var signature: ClaudeFileSignature
    var forwardOffset: UInt64
    var reverseEnd: UInt64
    var drainingForward = false
    var drainingReverse = false
    var prefixLength: Int = 0
    var prefixDigest: Data = Data()
    var anchorStart: UInt64 = 0
    var anchorLength: Int = 0
    var anchorDigest: Data = Data()
    var toolIDs: [String] = []
    var promptIDs: [String] = []
    var hasFinalResponse = false
    var lastContentTime: Date?
    var auditEnd: Date?
    var maximumSeenContentTime: Date?
    var stoppedAtCutoff = false
    var waitingForAppend = false
    var historicalLimit: UInt64?
    /// Offset of the first row this audit saw dated after its end. Those rows were left to live
    /// collection; the next audit rereads from here instead of restarting cold.
    var firstRowAfterAuditEnd: UInt64?
}

extension ClaudeAdapter {
    /// Append-only JSONL is the supported mutation contract. Equal-size rewrites, replacement,
    /// shrinkage, and changed keyed boundaries restart bounded selection with a visible gap.
    /// Arbitrary edits outside both boundaries while growing a file cannot be certified as append;
    /// unread prefixes are consequently never included in a complete historical coverage claim.
    public func readIncremental(
        path: String, expectedSessionID: String? = nil, interface: AgentInterface,
        checkpoint: SourceCheckpoint? = nil, observedAt: Date = Date(),
        provenance: SourceProvenance = .live, context: RetainedSourceContext? = nil,
        maximumBytes: Int? = nil, cryptography: BackgroundCryptography
    ) async throws -> ClaudeIncrementalRead {
        try Task.checkCancellation()
        let budget = min(limits.maximumBytes, maximumBytes ?? limits.maximumBytes)
        guard budget > 0 else { throw ClaudeCollectionError.invalidConfiguration }
        let documentID = try await documentIdentity(path, cryptography: cryptography)
        let checkpointID = try await checkpointIdentity(path: path, provenance: provenance, cryptography: cryptography)
        let fd = try openTranscript(path: path)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0 else { throw ClaudeCollectionError.awaitingTranscript }
        let signature = ClaudeFileSignature(info)
        var bytesRead = 0
        var gaps: [CoverageGap] = []
        var cursor: ClaudeReadCursor?
        if checkpoint?.sourceDocumentID == checkpointID, let state = checkpoint?.adapterState {
            cursor = try? JSONDecoder().decode(ClaudeReadCursor.self, from: state)
            if cursor == nil { gaps.append(.init(reason: .sourceChanged, capabilityID: documentID)) }
        }
        if let saved = cursor, saved.version != 1 || saved.forwardOffset > saved.signature.size
            || saved.reverseEnd > saved.forwardOffset || !(0...2048).contains(saved.prefixLength)
            || !(0...2048).contains(saved.anchorLength) || UInt64(saved.prefixLength) > saved.signature.size
            || saved.anchorStart > saved.forwardOffset || UInt64(saved.anchorLength) > saved.forwardOffset - saved.anchorStart
            || saved.toolIDs.count > 2048 || saved.promptIDs.count > 2048 {
            cursor = nil; gaps.append(.init(reason: .sourceChanged, capabilityID: documentID))
        }
        let historical: Bool
        if case .historical = provenance { historical = true } else { historical = false }
        func currentAuditBound(_ date: Date?) -> Date? {
            guard let date else { return nil }
            if case .historical(let audit) = provenance, !audit.includes(contentTime: date) { return nil }
            return date
        }
        if case .historical(let audit) = provenance, var saved = cursor,
           let previousEnd = saved.auditEnd, let maximumSeen = saved.maximumSeenContentTime,
           maximumSeen > previousEnd, audit.end > previousEnd {
            if let resume = saved.firstRowAfterAuditEnd, resume <= saved.forwardOffset {
                // Rows after the previous audit's end were left to live collection. Reread only
                // those; the prefix digest still certifies the file before this offset.
                saved.forwardOffset = resume
                saved.anchorStart = 0; saved.anchorLength = 0; saved.anchorDigest = Data()
                saved.drainingForward = false; saved.waitingForAppend = false
                saved.firstRowAfterAuditEnd = nil
                cursor = saved
            } else { cursor = nil }
        }
        // Content before an audit's cutoff row is outside its window, not unread.
        func olderPrefixUnread(_ state: ClaudeReadCursor) -> Bool {
            state.reverseEnd > 0 && !(historical && state.stoppedAtCutoff)
        }
        if let saved = cursor, saved.signature == signature,
           (saved.forwardOffset == signature.size || saved.waitingForAppend),
           (!historical || saved.reverseEnd == 0 || saved.stoppedAtCutoff) {
            // Gaps stored with this checkpoint were recorded when they were found; an unchanged
            // file adds no new loss.
            return ClaudeIncrementalRead(batch: .init(sources: [], coverageGaps: gaps), bytesRead: 0,
                hasForwardContent: false, hasUnreadContent: olderPrefixUnread(saved) || saved.forwardOffset < signature.size,
                canContinueHistory: false,
                oldestContentTime: nil, newestContentTime: currentAuditBound(saved.lastContentTime),
                toolIDs: Set(saved.toolIDs), promptIDs: Set(saved.promptIDs), hasFinalResponse: saved.hasFinalResponse)
        }
        if let saved = cursor {
            if saved.prefixLength + saved.anchorLength >= budget {
                return ClaudeIncrementalRead(batch: .init(sources: [], coverageGaps: [.init(reason: .budgetExhausted)]),
                    bytesRead: 0, hasForwardContent: true, hasUnreadContent: true, canContinueHistory: true,
                    oldestContentTime: nil, newestContentTime: currentAuditBound(saved.lastContentTime),
                    toolIDs: Set(saved.toolIDs), promptIDs: Set(saved.promptIDs), hasFinalResponse: saved.hasFinalResponse)
            }
            let sameFile = saved.signature.sameFile(signature)
            let shrunk = signature.size < saved.forwardOffset
            let rewrite = saved.signature != signature && signature.size <= saved.signature.size
            var valid = sameFile && !shrunk && !rewrite
            if valid, saved.prefixLength > 0 {
                let data = try claudePread(fd, offset: 0, count: saved.prefixLength)
                bytesRead += data.count
                let digest = try await cryptography.revision(canonicalBytes: data).keyedDigest
                valid = data.count == saved.prefixLength && digest == saved.prefixDigest
            }
            if valid, saved.anchorLength > 0 {
                let data = try claudePread(fd, offset: saved.anchorStart, count: saved.anchorLength)
                bytesRead += data.count
                let digest = try await cryptography.revision(canonicalBytes: data).keyedDigest
                valid = data.count == saved.anchorLength && digest == saved.anchorDigest
            }
            if !valid { cursor = nil; gaps.append(.init(reason: .sourceChanged, capabilityID: documentID)) }
        }
        // Cold selection starts at the tail. An old conversation's recent rows are immediately
        // eligible without reading its old multi-megabyte prefix or using its mtime as a date filter.
        let cold = cursor == nil
        var state = cursor ?? ClaudeReadCursor(signature: signature, forwardOffset: 0, reverseEnd: 0)
        if case .historical(let audit) = provenance,
           state.historicalLimit == nil || state.auditEnd != audit.end {
            state.historicalLimit = signature.size
            if state.auditEnd != audit.end { state.firstRowAfterAuditEnd = nil }
        }
        let snapshotEnd = historical ? min(signature.size, state.historicalLimit ?? signature.size) : signature.size
        // Freeze this audit's file extent. A source appending continuously after the audit began
        // cannot make older eligible suffix pages wait forever or create an endless continuation.
        let reverse = historical && !cold && state.reverseEnd > 0 && !state.stoppedAtCutoff
        let availableBudget = max(0, budget - bytesRead)
        guard availableBudget > 0 else {
            return ClaudeIncrementalRead(batch: .init(sources: [], coverageGaps: gaps + [.init(reason: .budgetExhausted)]),
                bytesRead: bytesRead, hasForwardContent: true, hasUnreadContent: true, canContinueHistory: true,
                oldestContentTime: nil, newestContentTime: currentAuditBound(state.lastContentTime),
                toolIDs: Set(state.toolIDs), promptIDs: Set(state.promptIDs), hasFinalResponse: state.hasFinalResponse)
        }
        let end = reverse ? state.reverseEnd : snapshotEnd
        let payloadBudget = max(1, availableBudget - min(4096, availableBudget / 8))
        let low: UInt64
        if reverse || cold { low = end > UInt64(payloadBudget) ? end - UInt64(payloadBudget) : 0 }
        else { low = state.forwardOffset }
        let count = Int(min(UInt64(payloadBudget), end - low))
        let data = try claudePread(fd, offset: low, count: count)
        bytesRead += data.count
        var start = low, selected = data
        if (reverse || cold), low > 0 {
            if let first = selected.firstIndex(of: 10) {
                let skip = selected.distance(from: selected.startIndex, to: first) + 1
                start += UInt64(skip); selected = Data(selected.dropFirst(skip))
            } else {
                gaps.append(.init(reason: .budgetExhausted, capabilityID: documentID))
                if reverse { state.reverseEnd = low; state.drainingReverse = true }
                else { state.forwardOffset = low + UInt64(data.count); state.reverseEnd = low; state.drainingForward = true }
                selected.removeAll()
            }
        }
        if reverse, state.drainingReverse {
            if let last = selected.lastIndex(of: 10) {
                selected = Data(selected[...last]); state.drainingReverse = false
            } else { selected.removeAll() }
        }
        if !reverse, !cold, state.drainingForward {
            if let first = selected.firstIndex(of: 10) {
                let skip = selected.distance(from: selected.startIndex, to: first) + 1
                start += UInt64(skip); selected = Data(selected.dropFirst(skip)); state.drainingForward = false
            } else { state.forwardOffset = low + UInt64(data.count); selected.removeAll() }
        }
        if reverse {
            // Keep the last physical rows in a reverse page, so its unvisited earlier rows remain
            // strictly before the next reverse cursor even when the physical-row limit is small.
            var newlineCount = 0
            for index in selected.indices.reversed() where selected[index] == 10 {
                newlineCount += 1
                if newlineCount > limits.maximumRows {
                    let cut = index + 1
                    start += UInt64(cut); selected = Data(selected.dropFirst(cut)); break
                }
            }
        }
        var imported = try await importTranscript(selected, documentID: documentID, interface: interface,
            observedAt: observedAt, provenance: provenance, cryptography: cryptography,
            expectedSessionID: expectedSessionID, context: context, startingByteOffset: start)
        let consumed = imported.checkpoints.first?.byteOffset ?? 0
        state.waitingForAppend = !selected.isEmpty && selected.last != 10
            && start + UInt64(selected.count) >= signature.size && selected.count < limits.maximumRowBytes
        if reverse {
            if !selected.isEmpty { state.reverseEnd = start }
        } else if !selected.isEmpty {
            state.forwardOffset = start + consumed
            if cold { state.reverseEnd = start }
            if consumed == 0, selected.count >= limits.maximumRowBytes {
                // Drain an oversized physical row without retaining its raw fragments in a cursor.
                state.forwardOffset = start + UInt64(selected.count); state.drainingForward = true
                gaps.append(.init(reason: .budgetExhausted, capabilityID: documentID))
            }
        }
        // A reverse page may contain more physical rows than the adapter row budget. Reparse only
        // the accepted byte prefix on later pages; do not declare this source caught up.
        let session = expectedSessionID ?? imported.sources.first?.record.metadata.identity.session.sessionID
        if let session {
            let accepted = Data(selected.prefix(Int(consumed)))
            state.toolIDs = Array(Set(state.toolIDs).union(toolResultIDs(accepted, sessionID: session))).sorted().suffix(2048).map { $0 }
            state.promptIDs = Array(Set(state.promptIDs).union(promptIDs(accepted, sessionID: session))).sorted().suffix(2048).map { $0 }
        }
        state.hasFinalResponse = state.hasFinalResponse || imported.sources.contains { $0.record.metadata.contentType == .finalResponse }
        state.lastContentTime = ([state.lastContentTime].compactMap { $0 } + imported.sources.map(\.record.metadata.contentTime)).max()
        let rows = claudeCompleteRowDates(Data(selected.prefix(Int(consumed))))
        let dates = rows.map(\.date)
        state.maximumSeenContentTime = ([state.maximumSeenContentTime].compactMap { $0 } + dates).max()
        if case .historical(let audit) = provenance {
            state.auditEnd = audit.end
            if dates.contains(where: { $0 < audit.start }) { state.stoppedAtCutoff = true }
            if let after = rows.first(where: { $0.date > audit.end }) {
                let offset = start + UInt64(after.offset)
                state.firstRowAfterAuditEnd = min(state.firstRowAfterAuditEnd ?? offset, offset)
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, signature.sameFile(ClaudeFileSignature(after)),
              UInt64(max(0, after.st_size)) >= signature.size,
              after.st_size != info.st_size || ClaudeFileSignature(after) == signature else {
            throw ClaudeCollectionError.awaitingTranscript
        }
        state.signature = signature
        // Cache anchors from bytes already read when possible; verification is bounded to 4 KiB
        // total and charged to the same byte budget rather than hidden in a full-prefix hash.
        let anchorBudget = max(0, budget - bytesRead)
        if anchorBudget > 0, state.forwardOffset > 0 {
            let sharedBudget = state.prefixLength == 0 ? max(1, anchorBudget / 2) : anchorBudget
            let length = min(2048, sharedBudget, Int(state.forwardOffset))
            let anchor = try claudePread(fd, offset: state.forwardOffset - UInt64(length), count: length)
            bytesRead += anchor.count; state.anchorStart = state.forwardOffset - UInt64(length)
            state.anchorLength = anchor.count; state.anchorDigest = try await cryptography.revision(canonicalBytes: anchor).keyedDigest
        }
        if state.prefixLength == 0, budget - bytesRead > 0, signature.size > 0 {
            let prefix = try claudePread(fd, offset: 0, count: min(2048, budget - bytesRead, Int(signature.size)))
            bytesRead += prefix.count; state.prefixLength = prefix.count
            state.prefixDigest = try await cryptography.revision(canonicalBytes: prefix).keyedDigest
        }
        gaps += imported.coverageGaps
        let forward = state.forwardOffset < snapshotEnd && !state.waitingForAppend
        let outsideSnapshot = historical && signature.size > snapshotEnd
        let unread = olderPrefixUnread(state) || forward || state.drainingForward || state.drainingReverse || outsideSnapshot
        if outsideSnapshot { gaps.append(.init(reason: .incompleteMessage, capabilityID: documentID)) }
        // A tail-only live cursor reports its unread prefix once, when the cursor is created.
        if olderPrefixUnread(state), historical || cold {
            gaps.append(.init(reason: .unresolvedCorrelation, capabilityID: documentID))
        }
        if forward { gaps.append(.init(reason: .budgetExhausted, capabilityID: documentID)) }
        gaps = Array(Set(gaps))
        let encoded = try JSONEncoder().encode(state)
        let revision = try await cryptography.revision(canonicalBytes: encoded)
        let committed = SourceCheckpoint(capabilityID: documentID, sourceDocumentID: checkpointID,
            revision: revision, byteOffset: state.forwardOffset, lastContentTime: state.lastContentTime,
            gaps: gaps, adapterState: encoded)
        imported = .init(sources: imported.sources, coverageGaps: gaps, checkpoint: committed)
        return ClaudeIncrementalRead(batch: imported, bytesRead: bytesRead, hasForwardContent: forward,
            hasUnreadContent: unread, canContinueHistory: forward || (state.reverseEnd > 0 && !state.stoppedAtCutoff),
            oldestContentTime: imported.sources.map(\.record.metadata.contentTime).min(),
            newestContentTime: currentAuditBound(state.lastContentTime), toolIDs: Set(state.toolIDs), promptIDs: Set(state.promptIDs),
            hasFinalResponse: state.hasFinalResponse)
    }

    public func checkpointIdentity(path: String, provenance: SourceProvenance,
                                   cryptography: BackgroundCryptography) async throws -> UUID {
        let physical = try await documentIdentity(path, cryptography: cryptography)
        let lane: String
        if case .historical = provenance { lane = "history" } else { lane = "live" }
        let bytes = try await cryptography.revision(canonicalBytes: Data("claude-checkpoint-v2\u{0}\(profileID)\u{0}\(physical)\u{0}\(lane)".utf8)).keyedDigest
        let b = Array(bytes.prefix(16))
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }
}

/// Dated complete rows with their byte offsets in `data`.
private func claudeCompleteRowDates(_ data: Data) -> [(offset: Int, date: Date)] {
    let fraction = ISO8601DateFormatter(); fraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let seconds = ISO8601DateFormatter()
    var offset = 0
    return data.split(separator: 10, omittingEmptySubsequences: false).compactMap { line in
        let start = offset
        offset += line.count + 1
        guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let text = row["timestamp"] as? String,
              let date = fraction.date(from: text) ?? seconds.date(from: text) else { return nil }
        return (start, date)
    }
}

func claudePread(_ fd: Int32, offset: UInt64, count: Int) throws -> Data {
    guard offset <= UInt64(Int64.max), count >= 0 else { throw ClaudeCollectionError.invalidConfiguration }
    var result = Data(), buffer = [UInt8](repeating: 0, count: min(64 * 1024, max(1, count)))
    while result.count < count {
        try Task.checkCancellation()
        let requested = min(buffer.count, count - result.count)
        let read = pread(fd, &buffer, requested, off_t(offset + UInt64(result.count)))
        if read == 0 { break }
        if read < 0 { if errno == EINTR { continue }; throw ClaudeCollectionError.awaitingTranscript }
        result.append(contentsOf: buffer.prefix(read))
    }
    return result
}
