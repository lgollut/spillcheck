import Foundation

extension CodexAdapter {
    /// Called only after a fresh, complete whole-thread read. This does
    /// not itself establish those read conditions or settle an omission. The
    /// pipeline must still commit the exact original's current full receipt.
    func reviewPresentationDependencies(page: CodexHistoryPage, batch: CollectionBatch,
                                        thread: CodexJSON, turns: CodexHistoryPage? = nil) -> [CoverageRecoveryDependency] {
        guard authority == .publicNativeItems, page.nextCursor == nil, page.data.count <= 256,
              let itemBytes = reviewPresentationEncodedBytes(page.data) else { return [] }
        var itemIDs = Set<String>()
        for entry in page.data {
            guard reviewPresentationIdentifier(entry["turnId"]) != nil,
                  reviewPresentationIdentifier(entry["item"]["type"]) != nil,
                  let id = reviewPresentationIdentifier(entry["item"]["id"]), itemIDs.insert(id).inserted else { return [] }
        }

        // Data keys compare decoded UTF-8 bytes. Swift String equality would also
        // match canonically equivalent Unicode with different source bytes.
        var originals: [String: [Data: [CodexJSON]]] = [:]
        for entry in page.data {
            let item = entry["item"]
            guard item["type"].string == "agentMessage", item.object?["phase"] == .null,
                  let turn = reviewPresentationIdentifier(entry["turnId"]),
                  let text = item["text"].string, !text.isEmpty else { continue }
            originals[turn, default: [:]][Data(text.utf8), default: []].append(entry)
        }

        var dependencies: [CoverageRecoveryDependency] = []
        for entry in page.data {
            let item = entry["item"]
            guard item["type"].string == "exitedReviewMode",
                  let turn = reviewPresentationIdentifier(entry["turnId"]),
                  let review = item["review"].string, !review.isEmpty else { continue }
            let bytes = Data(review.utf8)
            guard let matching = originals[turn]?[bytes], matching.count == 1,
                  let original = matching.first,
                  let dependency = reviewExitPresentationDependency(presentation: entry, original: original,
                      batch: batch, thread: thread) else { continue }
            dependencies.append(dependency)
        }
        dependencies += reviewEntryPresentationDependencies(page: page, turns: turns, itemBytes: itemBytes,
            batch: batch, thread: thread)
        return dependencies
    }

    /// The caller must independently prove fresh, complete exact-turn uniqueness
    /// before selecting these two rows. This matcher grants no sibling-read authority.
    func reviewExitPresentationDependency(presentation: CodexJSON, original: CodexJSON,
                                         batch: CollectionBatch, thread: CodexJSON) -> CoverageRecoveryDependency? {
        guard reviewPresentationEncodedBytes([presentation, original]) != nil,
              presentation["item"]["type"].string == "exitedReviewMode",
              let turn = reviewPresentationIdentifier(presentation["turnId"]),
              reviewPresentationIdentifier(original["turnId"]) == turn,
              original["item"]["type"].string == "agentMessage", original["item"].object?["phase"] == .null,
              let review = presentation["item"]["review"].string, !review.isEmpty,
              let text = original["item"]["text"].string, Data(text.utf8) == Data(review.utf8) else { return nil }
        return reviewPresentationDependency(presentation: presentation, original: original, bytes: Data(review.utf8),
            contentType: .intermediateResponse, pointer: "/text", batch: batch, thread: thread)
    }

    /// The caller proves complete fresh parent-thread/root-group uniqueness. These
    /// are actual final-read native rows, not reconstructed IDs or inferred roots.
    func reviewEntryPresentationDependency(presentation: CodexJSON, original: CodexJSON,
                                          reviewTurn: CodexJSON, originalTurn: CodexJSON,
                                          batch: CollectionBatch, thread: CodexJSON) -> CoverageRecoveryDependency? {
        guard reviewPresentationEncodedBytes([presentation, original, reviewTurn, originalTurn]) != nil,
              presentation["item"]["type"].string == "enteredReviewMode",
              let reviewID = reviewPresentationIdentifier(presentation["turnId"]),
              reviewPresentationIdentifier(reviewTurn["id"]) == reviewID,
              reviewPresentationIdentifier(reviewTurn["rootTurnId"]) == reviewID,
              original["item"]["type"].string == "userMessage",
              let originalID = reviewPresentationIdentifier(original["turnId"]),
              reviewPresentationIdentifier(originalTurn["id"]) == originalID,
              reviewPresentationIdentifier(originalTurn["rootTurnId"]) == reviewID,
              let content = original["item"]["content"].array, content.count == 1,
              content[0]["type"].string == "text", let text = content[0]["text"].string,
              let review = presentation["item"]["review"].string, !review.isEmpty,
              Data(text.utf8) == Data(review.utf8) else { return nil }
        return reviewPresentationDependency(presentation: presentation, original: original, bytes: Data(review.utf8),
            contentType: .userPrompt, pointer: "/content/0/text", batch: batch, thread: thread)
    }

    private func reviewEntryPresentationDependencies(page: CodexHistoryPage, turns: CodexHistoryPage?, itemBytes: Int,
                                                    batch: CollectionBatch, thread: CodexJSON) -> [CoverageRecoveryDependency] {
        guard let turns, turns.nextCursor == nil, !turns.data.isEmpty, turns.data.count <= 256,
              let reader = page.readerVersion, !reader.isEmpty, turns.readerVersion == reader,
              let turnBytes = reviewPresentationEncodedBytes(turns.data),
              turnBytes <= limits.maximumBytes - itemBytes else { return [] }
        var turnRows: [String: CodexJSON] = [:]
        for row in turns.data {
            guard let id = reviewPresentationIdentifier(row["id"]), turnRows[id] == nil,
                  row["rootTurnId"] == .null || reviewPresentationIdentifier(row["rootTurnId"]) != nil else { return [] }
            turnRows[id] = row
        }
        // Every original user item needs known native root membership. Unknown
        // membership could conceal a second input in the presentation's group.
        var usersByRoot: [String: [CodexJSON]] = [:]
        for entry in page.data where entry["item"]["type"].string == "userMessage" {
            guard let turn = reviewPresentationIdentifier(entry["turnId"]), let row = turnRows[turn],
                  let root = reviewPresentationIdentifier(row["rootTurnId"]) else { return [] }
            usersByRoot[root, default: []].append(entry)
        }
        let entries = page.data.filter { $0["item"]["type"].string == "enteredReviewMode" }
        var entriesByRoot: [String: [CodexJSON]] = [:]
        for entry in entries {
            guard let turn = reviewPresentationIdentifier(entry["turnId"]), let row = turnRows[turn],
                  let root = reviewPresentationIdentifier(row["rootTurnId"]) else { return [] }
            entriesByRoot[root, default: []].append(entry)
        }
        var result: [CoverageRecoveryDependency] = []
        for entry in entries {
            guard let turn = reviewPresentationIdentifier(entry["turnId"]),
                  let row = turnRows[turn], reviewPresentationIdentifier(row["rootTurnId"]) == turn,
                  entriesByRoot[turn]?.count == 1,
                  let users = usersByRoot[turn], users.count == 1, let original = users.first,
                  let content = original["item"]["content"].array, content.count == 1,
                  content[0]["type"].string == "text", let text = content[0]["text"].string,
                  let review = entry["item"]["review"].string, !review.isEmpty,
                  Data(text.utf8) == Data(review.utf8),
                  let dependency = reviewPresentationDependency(presentation: entry, original: original,
                      bytes: Data(review.utf8), contentType: .userPrompt, pointer: "/content/0/text",
                      batch: batch, thread: thread) else { continue }
            result.append(dependency)
        }
        return result
    }

    private func reviewPresentationDependency(presentation: CodexJSON, original: CodexJSON, bytes: Data,
                                             contentType: ContentType, pointer: String, batch: CollectionBatch,
                                             thread: CodexJSON) -> CoverageRecoveryDependency? {
        guard authority == .publicNativeItems, let threadID = reviewPresentationIdentifier(thread["id"]),
              let session = try? SessionIdentity(provider: .codex, profileID: profileID, sessionID: threadID),
              let originalID = reviewPresentationIdentifier(original["item"]["id"]),
              let presentationID = reviewPresentationIdentifier(presentation["item"]["id"]),
              originalID != presentationID else { return nil }
        let normalized = batch.sources.filter {
            $0.record.metadata.identity.session == session && $0.record.metadata.identity.itemID == originalID
        }
        guard normalized.count == 1, let source = normalized.first else { return nil }
        let record = source.record, metadata = record.metadata
        guard metadata.contentType == contentType, metadata.locator == .upstreamItem,
              metadata.timeBasis == nil, metadata.origin.adapterID == "codex",
              metadata.origin.adapterVersion == Self.adapterVersion,
              metadata.origin.agentVersion == recordedProducerVersion(thread["cliVersion"]),
              metadata.origin.interface == interface, metadata.origin.canonicalization == .exclusiveAuthority,
              record.segments.count == 1, record.segments[0].id == pointer, record.segments[0].utf8 == bytes,
              !batch.coverageGaps.contains(where: { $0.recovery?.session == session && $0.recovery?.itemID == originalID }),
              batch.recoveredReferences.contains(where: {
                  $0.session == session && $0.locator == .upstreamItem && $0.itemID == originalID
                      && $0.contentTime == metadata.contentTime && $0.parserContract == Self.parserContract
                      && $0.sourceDocumentID == nil && $0.sourceURL == nil
              }),
              !batch.sources.contains(where: { $0.record.metadata.identity.session == session
                  && $0.record.metadata.identity.itemID == presentationID }),
              !batch.recoveredReferences.contains(where: { $0.session == session && $0.itemID == presentationID }) else { return nil }
        let gaps = batch.coverageGaps.filter { $0.recovery?.session == session && $0.recovery?.itemID == presentationID }
        guard gaps.count == 1, let gap = gaps.first, let recovery = gap.recovery,
              gap.reason == .unsupportedContent, gap.diagnosticCode == .unknownRecordKind,
              gap.sourceKind == .codexUnknownItem, gap.contentType == nil,
              gap.isRequiredFormatFailure == false, gap.excludedContent == nil,
              gap.scope == collectionScope, gap.operation == metadata.origin.provenance.collectionOperation,
              gap.observedAt == metadata.observedAt, gap.capabilityID == nil, gap.interval == nil,
              recovery.locator == .upstreamItem, recovery.contentTime != nil,
              recovery.parserContract == Self.parserContract,
              recovery.sourceDocumentID == nil, recovery.sourceURL == nil else { return nil }
        return .init(provisionalGap: gap, originalMetadata: metadata, originalRevision: record.revision)
    }

    private func reviewPresentationEncodedBytes(_ rows: [CodexJSON]) -> Int? {
        var total = 0
        for row in rows {
            guard let encoded = try? JSONEncoder().encode(row), encoded.count <= limits.maximumRowBytes,
                  encoded.count <= limits.maximumBytes - total else { return nil }
            total += encoded.count
        }
        return total
    }
}

private func reviewPresentationIdentifier(_ value: CodexJSON) -> String? {
    guard let text = value.string, !text.isEmpty, text.utf8.count <= 4096, !text.utf8.contains(0) else { return nil }
    return text
}
