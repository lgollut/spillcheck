import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private let reviewPresentationText = "Review of fake input: é🙂\r\nNo findings."
private let reviewPresentationObserved = Date(timeIntervalSince1970: 1_791_434_500)

private func reviewPresentationEntry(_ id: String = "exit", kind: String = "exitedReviewMode",
                                     text: Any = reviewPresentationText, turn: String = "turn",
                                     timestamp: Double? = 1_791_434_400_000) throws -> CodexJSON {
    var entry = try #require(codexItem(id, type: kind, timestamp: timestamp, body: ["review": text]).object)
    entry["turnId"] = .string(turn)
    return .object(entry)
}

private func reviewPresentationOriginal(_ id: String = "original", text: String = reviewPresentationText,
                                       phase: Any? = NSNull(), turn: String = "turn") throws -> CodexJSON {
    var body: [String: Any] = ["text": text]
    if let phase { body["phase"] = phase }
    var entry = try #require(codexItem(id, body: body).object)
    entry["turnId"] = .string(turn)
    return .object(entry)
}

private func reviewPresentationUser(_ id: String = "input", text: String = reviewPresentationText,
                                    turn: String = "input-turn", content: Any? = nil) throws -> CodexJSON {
    var entry = try #require(codexItem(id, type: "userMessage",
        body: ["content": content ?? [["type": "text", "text": text]]]).object)
    entry["turnId"] = .string(turn)
    return .object(entry)
}

private func reviewPresentationTurn(_ id: String, root: Any = "turn") throws -> CodexJSON {
    try codexJSON(["id": id, "rootTurnId": root, "status": "inProgress",
        "startedAt": 1_791_434_399, "completedAt": NSNull()])
}

private func reviewPresentationRootTurns() throws -> CodexHistoryPage {
    .init(data: try [reviewPresentationTurn("turn"), reviewPresentationTurn("input-turn")], readerVersion: "0.162.1")
}

private func reviewPresentationSource(_ source: CollectedSource, session: SessionIdentity? = nil,
                                     contentType: ContentType? = nil, origin: SourceOrigin? = nil,
                                     segments: [SourceSegment]? = nil, locator: SourceLocator? = nil,
                                     timeBasis: SourceTimeBasis? = nil) throws -> CollectedSource {
    let old = source.record.metadata
    let metadata = try SourceRecordMetadata(identity: .init(session: session ?? old.identity.session,
        itemID: old.identity.itemID), contentType: contentType ?? old.contentType,
        contentTime: old.contentTime, observedAt: old.observedAt, locator: locator ?? old.locator,
        origin: origin ?? old.origin, timeBasis: timeBasis)
    return try .init(record: .init(metadata: metadata, revision: source.record.revision,
        segments: segments ?? source.record.segments), context: source.context)
}

@Suite("Codex review presentation dependencies")
struct CodexReviewPresentationTests {
    @Test func entryDependsOnOriginalInputInExplicitNativeReviewRootWithoutRebindingIt() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1"), thread = try codexThread(producer: "0.162.1")
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let input = try reviewPresentationUser(), enter = try reviewPresentationEntry("enter", kind: "enteredReviewMode")
        let page = CodexHistoryPage(data: [input, enter], readerVersion: "0.162.1")
        let turns = try reviewPresentationRootTurns()
        let batch = try await adapter.importPublicItems(page, thread: thread, observedAt: reviewPresentationObserved, cryptography: crypto)
        let dependencies = adapter.reviewPresentationDependencies(page: page, batch: batch, thread: thread, turns: turns)
        let dependency = try #require(dependencies.first)
        #expect(dependencies.count == 1 && batch.sources.count == 1 && batch.coverageGaps.count == 1)
        #expect(input["turnId"].string == "input-turn" && enter["turnId"].string == "turn")
        #expect(dependency.originalMetadata == batch.sources[0].record.metadata)
        #expect(dependency.originalMetadata.identity.itemID == "input" && dependency.originalMetadata.contentType == .userPrompt)
        #expect(dependency.originalMetadata.timeBasis == nil)
        #expect(dependency.originalRevision == batch.sources[0].record.revision)
        #expect(dependency.provisionalGap == batch.coverageGaps[0])
        #expect(batch.sources[0].record.segments[0].id == "/content/0/text")
        #expect(batch.recoveredReferences.map(\.itemID) == ["input"] && batch.pendingRecoveryDependencies.isEmpty)
        let reordered = CodexHistoryPage(data: [enter, input], readerVersion: "0.162.1")
        let replay = try await adapter.importPublicItems(reordered, thread: thread, observedAt: reviewPresentationObserved, cryptography: crypto)
        let repeated = try #require(adapter.reviewPresentationDependencies(page: reordered, batch: replay, thread: thread,
            turns: .init(data: Array(turns.data.reversed()), readerVersion: "0.162.1")).first)
        #expect(repeated.originalMetadata == dependency.originalMetadata && repeated.originalRevision == dependency.originalRevision)
        #expect(repeated.provisionalGap == dependency.provisionalGap)
    }

    @Test func entryRequiresCompleteUniqueMeasuredTurnRoots() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1"), thread = try codexThread()
        let page = CodexHistoryPage(data: try [reviewPresentationUser(), reviewPresentationEntry("enter", kind: "enteredReviewMode")], readerVersion: "0.162.1")
        let turns = try reviewPresentationRootTurns()
        let batch = try await adapter.importPublicItems(page, thread: thread, observedAt: reviewPresentationObserved,
            cryptography: BackgroundCryptography.ephemeralForTesting())
        let variants: [CodexHistoryPage?] = try [nil, .init(data: []),
            .init(data: turns.data, nextCursor: "more", readerVersion: "0.162.1"),
            .init(data: turns.data), .init(data: turns.data, readerVersion: "0.161.0"),
            .init(data: [turns.data[0]], readerVersion: "0.162.1"),
            .init(data: [turns.data[1]], readerVersion: "0.162.1"),
            .init(data: turns.data + [turns.data[1]], readerVersion: "0.162.1"),
            .init(data: turns.data + [reviewPresentationTurn("")], readerVersion: "0.162.1"),
            .init(data: turns.data + [reviewPresentationTurn("bad\0turn")], readerVersion: "0.162.1"),
            .init(data: Array(repeating: turns.data[0], count: 257), readerVersion: "0.162.1")]
        for candidate in variants {
            #expect(adapter.reviewPresentationDependencies(page: page, batch: batch, thread: thread, turns: candidate).isEmpty)
        }
        let invalidRoots: [Any] = ["input-turn", "unrelated-review", "", NSNull(), true, ["id": "turn"]]
        for invalidRoot in invalidRoots {
            let wrongInput = CodexHistoryPage(data: try [reviewPresentationTurn("turn"),
                reviewPresentationTurn("input-turn", root: invalidRoot)], readerVersion: "0.162.1")
            let wrongParent = CodexHistoryPage(data: try [reviewPresentationTurn("turn", root: invalidRoot),
                reviewPresentationTurn("input-turn")], readerVersion: "0.162.1")
            #expect(adapter.reviewPresentationDependencies(page: page, batch: batch, thread: thread, turns: wrongInput).isEmpty)
            #expect(adapter.reviewPresentationDependencies(page: page, batch: batch, thread: thread, turns: wrongParent).isEmpty)
        }
        #expect(adapter.reviewPresentationDependencies(page: .init(data: page.data), batch: batch, thread: thread, turns: turns).isEmpty)
        #expect(adapter.reviewPresentationDependencies(page: .init(data: page.data, nextCursor: "more", readerVersion: "0.162.1"),
            batch: batch, thread: thread, turns: turns).isEmpty)
    }

    @Test func entryRejectsAnySecondRootGroupUserEvenWhenOnlyOneTextMatches() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1"), thread = try codexThread()
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let input = try reviewPresentationUser(), enter = try reviewPresentationEntry("enter", kind: "enteredReviewMode")
        let turns = CodexHistoryPage(data: try reviewPresentationRootTurns().data + [reviewPresentationTurn("sibling-turn")], readerVersion: "0.162.1")
        let variants = try [[input, reviewPresentationUser("second", turn: "sibling-turn"), enter],
            [input, reviewPresentationUser("second", text: "different input", turn: "sibling-turn"), enter],
            [input, reviewPresentationUser("second", text: "different input", turn: "turn"), enter],
            [input, input, enter], [input, enter, reviewPresentationEntry("enter2", kind: "enteredReviewMode")],
            [input, reviewPresentationUser("unknown", turn: "unlisted"), enter]]
        for entries in variants {
            let page = CodexHistoryPage(data: entries, readerVersion: "0.162.1")
            let batch = try await adapter.importPublicItems(page, thread: thread, observedAt: reviewPresentationObserved, cryptography: crypto)
            #expect(adapter.reviewPresentationDependencies(page: page, batch: batch, thread: thread, turns: turns).isEmpty)
        }
        let unrelated = try reviewPresentationUser("other", text: "unrelated", turn: "other-turn")
        let page = CodexHistoryPage(data: [input, unrelated, enter], readerVersion: "0.162.1")
        let batch = try await adapter.importPublicItems(page, thread: thread, observedAt: reviewPresentationObserved, cryptography: crypto)
        let separate = CodexHistoryPage(data: turns.data + [try reviewPresentationTurn("other-turn", root: "other-turn")], readerVersion: "0.162.1")
        #expect(adapter.reviewPresentationDependencies(page: page, batch: batch, thread: thread, turns: separate).count == 1)
    }

    @Test func entryRequiresWholeSingleTextBlockWithExactDecodedBytes() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1"), thread = try codexThread(), turns = try reviewPresentationRootTurns()
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let variants: [Any] = [NSNull(), [], [["type": "image", "text": reviewPresentationText]],
            [["type": "text"]], [["type": "text", "text": reviewPresentationText], ["type": "text", "text": "extra"]],
            [["type": "text", "text": reviewPresentationText], ["type": "image", "image_url": "fake"]]]
        for content in variants {
            let page = CodexHistoryPage(data: try [reviewPresentationUser(content: content),
                reviewPresentationEntry("enter", kind: "enteredReviewMode")], readerVersion: "0.162.1")
            let batch = try await adapter.importPublicItems(page, thread: thread, observedAt: reviewPresentationObserved, cryptography: crypto)
            #expect(adapter.reviewPresentationDependencies(page: page, batch: batch, thread: thread, turns: turns).isEmpty)
        }
        let composed = "caf\u{e9}", decomposed = "cafe\u{301}"
        #expect(composed == decomposed && Data(composed.utf8) != Data(decomposed.utf8))
        let page = CodexHistoryPage(data: try [reviewPresentationUser(text: composed),
            reviewPresentationEntry("enter", kind: "enteredReviewMode", text: decomposed)], readerVersion: "0.162.1")
        let batch = try await adapter.importPublicItems(page, thread: thread, observedAt: reviewPresentationObserved, cryptography: crypto)
        #expect(adapter.reviewPresentationDependencies(page: page, batch: batch, thread: thread, turns: turns).isEmpty)
        let invalidReviews: [Any] = [NSNull(), true, "", ["type": "text", "text": reviewPresentationText]]
        for review in invalidReviews {
            let invalidPage = CodexHistoryPage(data: try [reviewPresentationUser(),
                reviewPresentationEntry("enter", kind: "enteredReviewMode", text: review)], readerVersion: "0.162.1")
            let invalidBatch = try await adapter.importPublicItems(invalidPage, thread: thread,
                observedAt: reviewPresentationObserved, cryptography: crypto)
            #expect(adapter.reviewPresentationDependencies(page: invalidPage, batch: invalidBatch, thread: thread, turns: turns).isEmpty)
        }
    }

    @Test func entryCannotUseChangedOrPartialNormalizedInput() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1"), thread = try codexThread(), turns = try reviewPresentationRootTurns()
        let page = CodexHistoryPage(data: try [reviewPresentationUser(), reviewPresentationEntry("enter", kind: "enteredReviewMode")], readerVersion: "0.162.1")
        let batch = try await adapter.importPublicItems(page, thread: thread, observedAt: reviewPresentationObserved,
            cryptography: BackgroundCryptography.ephemeralForTesting())
        let source = try #require(batch.sources.first)
        let variants = try [reviewPresentationSource(source, contentType: .intermediateResponse),
            reviewPresentationSource(source, timeBasis: .firstObservation),
            reviewPresentationSource(source, segments: [.init(id: "/text", utf8: Data(reviewPresentationText.utf8))])]
        for changed in variants {
            #expect(adapter.reviewPresentationDependencies(page: page,
                batch: .init(sources: [changed], coverageGaps: batch.coverageGaps, recoveredReferences: batch.recoveredReferences),
                thread: thread, turns: turns).isEmpty)
        }
        let partial = CoverageGap(reason: .unsupportedContent, recovery: batch.recoveredReferences.first,
            isRequiredFormatFailure: false, diagnosticCode: .excludedBinaryContent, excludedContent: true)
        #expect(adapter.reviewPresentationDependencies(page: page,
            batch: .init(sources: batch.sources, coverageGaps: batch.coverageGaps + [partial], recoveredReferences: batch.recoveredReferences),
            thread: thread, turns: turns).isEmpty)
        #expect(adapter.reviewPresentationDependencies(page: page,
            batch: .init(sources: batch.sources, coverageGaps: batch.coverageGaps), thread: thread, turns: turns).isEmpty)
    }

    @Test func entryAndExitDependOnSeparateOriginalsAndInvalidRootsNeverDisableExit() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1"), thread = try codexThread(), turns = try reviewPresentationRootTurns()
        let page = CodexHistoryPage(data: try [reviewPresentationUser(), reviewPresentationOriginal(),
            reviewPresentationEntry("enter", kind: "enteredReviewMode"), reviewPresentationEntry()], readerVersion: "0.162.1")
        let batch = try await adapter.importPublicItems(page, thread: thread, observedAt: reviewPresentationObserved,
            cryptography: BackgroundCryptography.ephemeralForTesting())
        let dependencies = adapter.reviewPresentationDependencies(page: page, batch: batch, thread: thread, turns: turns)
        #expect(Set(dependencies.map { $0.originalMetadata.identity.itemID }) == ["original", "input"])
        #expect(Set(dependencies.compactMap { $0.provisionalGap.recovery?.itemID }) == ["exit", "enter"])
        #expect(adapter.reviewPresentationDependencies(page: page, batch: batch, thread: thread,
            turns: .init(data: turns.data, nextCursor: "more", readerVersion: "0.162.1")).map { $0.originalMetadata.identity.itemID } == ["original"])
        let direct = try #require(adapter.reviewExitPresentationDependency(presentation: page.data[3], original: page.data[1], batch: batch, thread: thread))
        #expect(direct.originalRevision == batch.sources.first(where: { $0.record.metadata.identity.itemID == "original" })?.record.revision)
    }

    @Test func exitDependsOnExactOriginalWithoutCreatingPresentationSourceOrRecovery() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1"), crypto = try BackgroundCryptography.ephemeralForTesting()
        let thread = try codexThread(producer: "0.162.1")
        let entries = try [reviewPresentationOriginal(), reviewPresentationEntry(), reviewPresentationEntry("enter", kind: "enteredReviewMode")]
        let page = CodexHistoryPage(data: entries)
        let batch = try await adapter.importPublicItems(page, thread: thread, observedAt: reviewPresentationObserved, cryptography: crypto)
        let dependencies = adapter.reviewPresentationDependencies(page: page, batch: batch, thread: thread)
        let dependency = try #require(dependencies.first)
        #expect(dependencies.count == 1 && batch.sources.count == 1 && batch.coverageGaps.count == 2)
        #expect(dependency.provisionalGap == batch.coverageGaps.first(where: { $0.recovery?.itemID == "exit" }))
        #expect(dependency.originalMetadata == batch.sources[0].record.metadata)
        #expect(dependency.originalRevision == batch.sources[0].record.revision)
        #expect(batch.recoveredReferences.map(\.itemID) == ["original"])
        #expect(batch.pendingRecoveryDependencies.isEmpty)
        let reordered = CodexHistoryPage(data: Array(entries.reversed()))
        let replay = try await adapter.importPublicItems(reordered, thread: thread, observedAt: reviewPresentationObserved, cryptography: crypto)
        let repeated = try #require(adapter.reviewPresentationDependencies(page: reordered, batch: replay, thread: thread).first)
        #expect(repeated.originalMetadata == dependency.originalMetadata)
        #expect(repeated.originalRevision == dependency.originalRevision)
        #expect(repeated.provisionalGap == dependency.provisionalGap)
    }

    @Test func canonicallyEquivalentUnicodeDoesNotCountAsIdenticalSourceBytes() async throws {
        let composed = "caf\u{e9}", decomposed = "cafe\u{301}"
        #expect(composed == decomposed && Data(composed.utf8) != Data(decomposed.utf8))
        let adapter = try codexTestAdapter(version: "0.162.1"), thread = try codexThread()
        let page = CodexHistoryPage(data: try [reviewPresentationOriginal(text: composed), reviewPresentationEntry(text: decomposed)])
        let batch = try await adapter.importPublicItems(page, thread: thread, observedAt: reviewPresentationObserved,
            cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(adapter.reviewPresentationDependencies(page: page, batch: batch, thread: thread).isEmpty)
        #expect(batch.coverageGaps.count == 1)
    }

    @Test func onlySameTurnExplicitNullPhaseAssistantCanSatisfyExit() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1"), thread = try codexThread()
        let variants = try [reviewPresentationOriginal(phase: nil), reviewPresentationOriginal(phase: "final_answer"),
            reviewPresentationOriginal(phase: "commentary"), reviewPresentationOriginal(phase: "partial_answer"),
            reviewPresentationOriginal(turn: "other-turn"),
            codexItem("original", type: "userMessage", body: ["content": [["type": "text", "text": reviewPresentationText]]])]
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        for original in variants {
            let page = CodexHistoryPage(data: [original, try reviewPresentationEntry()])
            let batch = try await adapter.importPublicItems(page, thread: thread, observedAt: reviewPresentationObserved, cryptography: crypto)
            #expect(adapter.reviewPresentationDependencies(page: page, batch: batch, thread: thread).isEmpty)
        }
    }

    @Test func duplicatePageIDsAndMultipleOriginalCandidatesStayUnresolved() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1"), thread = try codexThread()
        let original = try reviewPresentationOriginal(), exit = try reviewPresentationEntry()
        let variants = try [[original, original, exit], [original, exit, exit],
            [original, reviewPresentationOriginal("second"), exit],
            [original, exit, codexItem("unrelated", type: "reasoning"), codexItem("unrelated", type: "reasoning")]]
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        for entries in variants {
            let page = CodexHistoryPage(data: entries)
            let batch = try await adapter.importPublicItems(page, thread: thread, observedAt: reviewPresentationObserved, cryptography: crypto)
            #expect(adapter.reviewPresentationDependencies(page: page, batch: batch, thread: thread).isEmpty)
        }
    }

    @Test func malformedSiblingEnvelopeCannotHideAnAmbiguousOriginal() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1"), thread = try codexThread()
        let original = try reviewPresentationOriginal(), exit = try reviewPresentationEntry()
        let sibling = try #require(reviewPresentationOriginal("second").object)
        let malformed: [CodexJSON] = [.null, .string(""), .string(String(repeating: "t", count: 4097)), .string("t\0urn")]
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        for invalid in malformed {
            var invalidTurn = sibling
            invalidTurn["turnId"] = invalid
            var invalidType = sibling
            var item = try #require(invalidType["item"]?.object)
            item["type"] = invalid
            invalidType["item"] = .object(item)
            for entry in [CodexJSON.object(invalidTurn), .object(invalidType)] {
                let page = CodexHistoryPage(data: [original, exit, entry])
                let batch = try await adapter.importPublicItems(page, thread: thread,
                    observedAt: reviewPresentationObserved, cryptography: crypto)
                #expect(adapter.reviewPresentationDependencies(page: page, batch: batch, thread: thread).isEmpty)
                #expect(batch.coverageGaps.contains(where: { $0.recovery?.itemID == "exit" }))
            }
        }
    }

    @Test func malformedEmptyMediaAndOversizedPresentationsNeverRecover() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1", limits: .init(maximumRowBytes: 1024)), thread = try codexThread()
        let variants = try [reviewPresentationEntry(text: NSNull()), reviewPresentationEntry(text: true),
            reviewPresentationEntry(text: ["type": "image", "text": reviewPresentationText]),
            reviewPresentationEntry(text: ""), reviewPresentationEntry(""), reviewPresentationEntry(turn: ""),
            reviewPresentationEntry(text: String(repeating: "x", count: 1025)),
            reviewPresentationEntry(timestamp: nil),
            codexItem("exit", type: "exitedReviewMode", body: [:])]
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        for exit in variants {
            let page = CodexHistoryPage(data: [try reviewPresentationOriginal(), exit])
            let batch = try await adapter.importPublicItems(page, thread: thread, observedAt: reviewPresentationObserved, cryptography: crypto)
            #expect(adapter.reviewPresentationDependencies(page: page, batch: batch, thread: thread).isEmpty)
        }
    }

    @Test func continuationAndOversizedPageNeverEstablishCompleteSiblingEvidence() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1"), thread = try codexThread()
        let rows = try [reviewPresentationOriginal(), reviewPresentationEntry()]
        let batch = try await adapter.importPublicItems(.init(data: rows), thread: thread,
            observedAt: reviewPresentationObserved, cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(adapter.reviewPresentationDependencies(page: .init(data: rows, nextCursor: "more"), batch: batch, thread: thread).isEmpty)
        #expect(adapter.reviewPresentationDependencies(page: .init(data: Array(repeating: rows[0], count: 257)), batch: batch, thread: thread).isEmpty)
    }

    @Test func missingDuplicatePartialOrChangedNormalizedOriginalCannotAuthorizeRecovery() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1"), thread = try codexThread()
        let page = CodexHistoryPage(data: try [reviewPresentationOriginal(), reviewPresentationEntry()])
        let batch = try await adapter.importPublicItems(page, thread: thread, observedAt: reviewPresentationObserved,
            cryptography: BackgroundCryptography.ephemeralForTesting())
        let source = try #require(batch.sources.first), old = source.record.metadata
        let wrongSession = try SessionIdentity(provider: .codex, profileID: "other-profile", sessionID: old.identity.session.sessionID)
        let changed: [CollectedSource] = try [
            reviewPresentationSource(source, session: wrongSession),
            reviewPresentationSource(source, contentType: .finalResponse),
            reviewPresentationSource(source, locator: .unavailable),
            reviewPresentationSource(source, timeBasis: .firstObservation),
            reviewPresentationSource(source, segments: [.init(id: "/text", utf8: Data("different".utf8))]),
            reviewPresentationSource(source, segments: [.init(id: "/wrong", utf8: Data(reviewPresentationText.utf8))]),
            reviewPresentationSource(source, segments: [.init(id: "/text", utf8: Data(reviewPresentationText.utf8)),
                .init(id: "/extra", utf8: Data("extra".utf8))]),
            reviewPresentationSource(source, origin: .init(adapterID: "other", adapterVersion: old.origin.adapterVersion,
                agentVersion: old.origin.agentVersion, interface: old.origin.interface, provenance: old.origin.provenance,
                canonicalization: old.origin.canonicalization))]
        for sources in [[] as [CollectedSource], [source, source]] + changed.map({ [$0] }) {
            let altered = CollectionBatch(sources: sources, coverageGaps: batch.coverageGaps, recoveredReferences: batch.recoveredReferences)
            #expect(adapter.reviewPresentationDependencies(page: page, batch: altered, thread: thread).isEmpty)
        }
        let partial = CoverageGap(reason: .unsupportedContent, recovery: batch.recoveredReferences.first,
            isRequiredFormatFailure: false, diagnosticCode: .excludedBinaryContent, excludedContent: true)
        let altered = CollectionBatch(sources: batch.sources, coverageGaps: batch.coverageGaps + [partial], recoveredReferences: batch.recoveredReferences)
        #expect(adapter.reviewPresentationDependencies(page: page, batch: altered, thread: thread).isEmpty)
        #expect(adapter.reviewPresentationDependencies(page: page,
            batch: .init(sources: batch.sources, coverageGaps: batch.coverageGaps), thread: thread).isEmpty)
    }

    @Test func exactCurrentProvisionalGapIsRequiredAndNeverBecomesOrdinaryReparse() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1"), thread = try codexThread()
        let page = CodexHistoryPage(data: try [reviewPresentationOriginal(), reviewPresentationEntry()])
        let batch = try await adapter.importPublicItems(page, thread: thread, observedAt: reviewPresentationObserved,
            cryptography: BackgroundCryptography.ephemeralForTesting())
        let gap = try #require(batch.coverageGaps.first), recovery = try #require(gap.recovery)
        let variants: [CoverageGap] = [
            .init(reason: .malformedSource, scope: gap.scope, operation: gap.operation, recovery: recovery, observedAt: gap.observedAt),
            .init(reason: gap.reason, scope: gap.scope, operation: gap.operation, recovery: recovery,
                isRequiredFormatFailure: false, sourceKind: gap.sourceKind, diagnosticCode: .unknownBlockKind, observedAt: gap.observedAt),
            .init(reason: gap.reason, scope: gap.scope, operation: gap.operation, recovery: recovery,
                isRequiredFormatFailure: true, sourceKind: gap.sourceKind, diagnosticCode: gap.diagnosticCode, observedAt: gap.observedAt),
            .init(reason: gap.reason, scope: gap.scope, operation: gap.operation, recovery: recovery,
                isRequiredFormatFailure: false, sourceKind: gap.sourceKind, diagnosticCode: gap.diagnosticCode,
                observedAt: reviewPresentationObserved.addingTimeInterval(-1)),
            .init(reason: gap.reason, scope: gap.scope, operation: gap.operation,
                recovery: .init(session: recovery.session, locator: recovery.locator, itemID: recovery.itemID,
                    contentTime: recovery.contentTime, parserContract: "old-parser"),
                isRequiredFormatFailure: false, sourceKind: gap.sourceKind, diagnosticCode: gap.diagnosticCode, observedAt: gap.observedAt)]
        for gaps in [[] as [CoverageGap], [gap, gap]] + variants.map({ [$0] }) {
            #expect(adapter.reviewPresentationDependencies(page: page,
                batch: .init(sources: batch.sources, coverageGaps: gaps, recoveredReferences: batch.recoveredReferences), thread: thread).isEmpty)
        }
        #expect(adapter.reviewPresentationDependencies(page: page,
            batch: .init(sources: batch.sources, coverageGaps: batch.coverageGaps,
                recoveredReferences: batch.recoveredReferences + [recovery]), thread: thread).isEmpty)
    }

    @Test func historicalOriginalProvenanceAndItsExactRevisionAreRetained() async throws {
        let adapter = try codexTestAdapter(version: "0.162.1"), thread = try codexThread()
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: reviewPresentationObserved)
        let page = CodexHistoryPage(data: try [reviewPresentationOriginal(), reviewPresentationEntry()])
        let batch = try await adapter.importPublicItems(page, thread: thread, observedAt: reviewPresentationObserved,
            provenance: .historical(audit), cryptography: BackgroundCryptography.ephemeralForTesting())
        let dependency = try #require(adapter.reviewPresentationDependencies(page: page, batch: batch, thread: thread).first)
        #expect(dependency.originalMetadata.origin.provenance == .historical(audit))
        #expect(dependency.provisionalGap.operation == .historicalRead)
        #expect(dependency.originalRevision == batch.sources[0].record.revision)
        #expect(dependency.originalMetadata == batch.sources[0].record.metadata)
    }
}
