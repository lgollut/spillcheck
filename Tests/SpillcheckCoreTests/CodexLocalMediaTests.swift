import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private func localMediaMessage(_ blocks: [Any], id: String = "original-input", timestamp: Double? = 1_791_434_400_000) throws -> CodexJSON {
    try codexItem(id, type: "userMessage", timestamp: timestamp, body: ["content": blocks])
}
private func localMediaExclusion(_ batch: CollectionBatch) -> CoverageGap? {
    batch.coverageGaps.first { $0.diagnosticCode == .excludedBinaryContent }
}

@Suite("Codex public native local media exclusions")
struct CodexLocalMediaTests {
    @Test func mixedTextAndLocalAttachmentsPreserveOnlyOriginalReadableBytes() async throws {
        let before = "before é🙂\r\n", after = "after\n exact bytes"
        let entries = [try localMediaMessage([
            ["type": "text", "text": before],
            ["type": "localImage", "path": "/path/that/must/not/be/opened/FAKE_IMAGE_42", "detail": "original"],
            ["type": "text", "text": after],
            ["type": "localAudio", "path": "relative/FAKE_AUDIO_42"]])]
        let crypto = try BackgroundCryptography.ephemeralForTesting(), adapter = try codexTestAdapter()
        let first = try await adapter.importPublicItems(.init(data: entries), thread: codexThread(), observedAt: Date(), cryptography: crypto)
        let replay = try await adapter.importPublicItems(.init(data: entries), thread: codexThread(), observedAt: Date(), cryptography: crypto)
        let source = try #require(first.sources.first?.record), gap = try #require(localMediaExclusion(first))
        #expect(first.sources.count == 1 && first.coverageGaps.count == 1 && first.recoveredReferences.isEmpty)
        #expect(source.metadata.identity.itemID == "original-input" && source.metadata.identity.session.sessionID == "parent")
        #expect(source.metadata.contentType == .userPrompt && source.metadata.locator == .upstreamItem)
        #expect(source.segments.map(\.id) == ["/content/0/text", "/content/2/text"])
        #expect(source.segments.map(\.utf8) == [Data(before.utf8), Data(after.utf8)])
        #expect(source.revision == replay.sources.first?.record.revision)
        #expect(source.metadata.identity == replay.sources.first?.record.metadata.identity)
        #expect(gap.reason == .unsupportedContent && gap.contentType == .userPrompt && gap.sourceKind == .codexUserMessage)
        #expect(gap.excludedContent == true && gap.isRequiredFormatFailure == false && !gap.requiresAnalysis)
        #expect(gap.recovery?.constraint == .recognizedLocalMedia && gap.recovery?.locator == .upstreamItem)
        #expect(gap.recovery?.itemID == source.metadata.identity.itemID && gap.recovery?.contentTime == source.metadata.contentTime)
    }

    @Test func attachmentOnlyItemsRemainExcludedWithoutSourcesOrSuccessfulRecovery() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        for blocks: [Any] in [
            [["type": "localImage", "path": "/does-not-exist/image"]],
            [["type": "localAudio", "path": "does-not-exist/audio"]],
            [["type": "localImage", "path": "one"], ["type": "localAudio", "path": "two"]]] {
            let batch = try await adapter.importPublicItems(.init(data: [localMediaMessage(blocks)]), thread: codexThread(),
                observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty && batch.coverageGaps.count == 1)
            #expect(localMediaExclusion(batch)?.recovery?.constraint == .recognizedLocalMedia)
            #expect(localMediaExclusion(batch)?.excludedContent == true)
        }
    }

    @Test func validDetailAndAttachmentMetadataChangesDoNotChangeTextRevision() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        var revision: ContentRevision?
        for detail: String? in [nil, "auto", "low", "high", "original"] {
            var image: [String: Any] = ["type": "localImage", "path": "metadata-only-\(detail ?? "none")"]
            if let detail { image["detail"] = detail }
            let batch = try await adapter.importPublicItems(.init(data: [localMediaMessage([
                image, ["type": "text", "text": "original unchanged text"]])]), thread: codexThread(),
                observedAt: Date(), cryptography: crypto)
            let source = try #require(batch.sources.first?.record)
            if let revision { #expect(source.revision == revision) } else { revision = source.revision }
            #expect(source.segments.map(\.id) == ["/content/1/text"])
            #expect(localMediaExclusion(batch)?.recovery?.constraint == .recognizedLocalMedia)
            #expect(batch.recoveredReferences.isEmpty)
        }
    }

    @Test func invalidPathsDetailsAndFutureFieldsRetainRequiredWarnings() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        var invalid: [[String: Any]] = []
        for type in ["localImage", "localAudio"] {
            invalid.append(["type": type])
            for path: Any in [NSNull(), "", "bad\u{0}path", String(repeating: "é", count: 2049), 42, false, [], ["path": "nested"]] {
                invalid.append(["type": type, "path": path])
            }
            invalid.append(["type": type, "path": "valid", "futureText": "must not silently ignore"])
        }
        for detail: Any in [1, false, "future-detail", [], ["text": "future"]] {
            invalid.append(["type": "localImage", "path": "valid", "detail": detail])
        }
        invalid.append(["type": "localAudio", "path": "valid", "detail": "auto"])
        for block in invalid {
            let batch = try await adapter.importPublicItems(.init(data: [localMediaMessage([
                ["type": "text", "text": "readable sibling"], block])]), thread: codexThread(), observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.count == 1 && codexText(batch.sources[0]) == "readable sibling")
            #expect(batch.coverageGaps.contains { $0.isRequiredFormatFailure == true })
            #expect(batch.coverageGaps.allSatisfy { $0.recovery?.constraint == nil })
            #expect(batch.recoveredReferences.isEmpty)
        }
        let largest = try await adapter.importPublicItems(.init(data: [localMediaMessage([
            ["type": "localAudio", "path": String(repeating: "x", count: 4096)]])]), thread: codexThread(),
            observedAt: Date(), cryptography: crypto)
        #expect(largest.coverageGaps.count == 1 && localMediaExclusion(largest)?.recovery?.constraint == .recognizedLocalMedia)
    }

    @Test func otherUnknownMalformedAndEncryptedSiblingsVetoExclusionProof() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        for sibling: Any in [["type": "futureText", "text": "unrecognized"], ["type": "text"],
            ["type": "text", "text": 42], ["type": "encrypted_content", "encrypted_content": "fake-encrypted"],
            ["type": "encrypted_content"], ["type": "localAudio", "path": ""], NSNull(), 3] {
            let batch = try await adapter.importPublicItems(.init(data: [localMediaMessage([
                ["type": "localImage", "path": "valid"], ["type": "text", "text": "retained"], sibling])]),
                thread: codexThread(), observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.count == 1 && codexText(batch.sources[0]) == "retained")
            #expect(localMediaExclusion(batch)?.excludedContent == true)
            #expect(batch.coverageGaps.contains { $0.isRequiredFormatFailure == true })
            #expect(batch.coverageGaps.allSatisfy { $0.recovery?.constraint == nil })
            #expect(batch.recoveredReferences.isEmpty)
        }
    }

    @Test func publicNullDetailAndFullyKnownSiblingShapesPermitOnlyExclusionProof() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let original = "é exact text"
        let validSiblings: [[String: Any]] = [
            ["type": "text", "text": original, "text_elements": []],
            ["type": "text", "text": original, "text_elements": [
                ["byteRange": ["start": 0, "end": 2], "placeholder": NSNull()],
                ["byteRange": ["start": 3, "end": 8], "placeholder": "inline"]]],
            ["type": "image", "url": "https://invalid.example/fixture", "detail": NSNull()],
            ["type": "image", "fileId": "fixture-file", "detail": "original"],
            ["type": "audio", "url": "https://invalid.example/audio"]]
        for sibling in validSiblings {
            let batch = try await adapter.importPublicItems(.init(data: [localMediaMessage([
                ["type": "localImage", "path": "unopened", "detail": NSNull()], sibling])]),
                thread: codexThread(), observedAt: Date(), cryptography: crypto)
            #expect(batch.coverageGaps.count == 1 && batch.recoveredReferences.isEmpty)
            #expect(localMediaExclusion(batch)?.recovery?.constraint == .recognizedLocalMedia)
            if sibling["type"] as? String == "text" {
                #expect(batch.sources.count == 1 && codexText(batch.sources[0]) == original)
                #expect(batch.sources[0].record.segments.map(\.id) == ["/content/1/text"])
            } else { #expect(batch.sources.isEmpty) }
        }
    }

    @Test func uncertainLegacySiblingShapesWithholdProofWithoutNewParsingFailures() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        var uncertain: [[String: Any]] = [
            ["type": "text", "text": "legacy text", "extraText": "future field"],
            ["type": "image"], ["type": "image", "url": 42],
            ["type": "image", "url": "", "detail": "auto"],
            ["type": "image", "url": "url", "fileId": "file"],
            ["type": "image", "fileId": "file", "detail": "future"],
            ["type": "image", "url": "url", "detail": 42],
            ["type": "image", "url": "url", "extraText": "future field"],
            ["type": "audio"], ["type": "audio", "url": NSNull()],
            ["type": "audio", "url": "url", "extraText": "future field"],
            ["type": "tool_reference", "name": "legacy metadata"]]
        let invalidElements: [Any] = [NSNull(), "not an array",
            [["byteRange": ["start": 0, "end": 1]]],
            [["byteRange": ["start": 0, "end": 1], "placeholder": 42]],
            [["byteRange": ["start": 0, "end": 1], "placeholder": NSNull(), "extraText": "future"]],
            [["byteRange": ["start": 0, "end": 1, "extra": 2], "placeholder": NSNull()]],
            [["byteRange": ["start": -1, "end": 1], "placeholder": NSNull()]],
            [["byteRange": ["start": 0.5, "end": 1], "placeholder": NSNull()]],
            [["byteRange": ["start": 3, "end": 2], "placeholder": NSNull()]],
            [["byteRange": ["start": 0, "end": 100], "placeholder": NSNull()]]]
        for elements in invalidElements {
            uncertain.append(["type": "text", "text": "legacy text", "text_elements": elements])
        }
        for sibling in uncertain {
            let batch = try await adapter.importPublicItems(.init(data: [localMediaMessage([
                ["type": "localImage", "path": "unopened"], sibling])]),
                thread: codexThread(), observedAt: Date(), cryptography: crypto)
            #expect(batch.coverageGaps.count == 1 && batch.recoveredReferences.isEmpty)
            #expect(localMediaExclusion(batch)?.excludedContent == true)
            #expect(localMediaExclusion(batch)?.recovery?.constraint == nil)
            #expect(batch.coverageGaps.allSatisfy { $0.isRequiredFormatFailure != true })
            if sibling["type"] as? String == "text" {
                #expect(batch.sources.count == 1 && codexText(batch.sources[0]) == "legacy text")
                #expect(batch.sources[0].record.segments.map(\.id) == ["/content/1/text"])
            } else { #expect(batch.sources.isEmpty) }
        }
    }

    @Test func opaqueMCPBusinessObjectsKeepLocalMediaNamedStringsAsText() async throws {
        let adapter = try codexTestAdapter(), crypto = try BackgroundCryptography.ephemeralForTesting()
        for type in ["localImage", "localAudio"] {
            let item = try codexItem("native-tool", type: "mcpToolCall", body: ["status": "completed", "error": NSNull(),
                "result": ["content": [], "structuredContent": ["type": type, "path": "ordinary business path",
                    "detail": "future business detail", "text": "original tool result"]]])
            let batch = try await adapter.importPublicItems(.init(data: [item]), thread: codexThread(), observedAt: Date(), cryptography: crypto)
            let source = try #require(batch.sources.first?.record)
            #expect(batch.coverageGaps.isEmpty && batch.sources.count == 1)
            #expect(Dictionary(uniqueKeysWithValues: source.segments.map { ($0.id, String(decoding: $0.utf8, as: UTF8.self)) }) == [
                "/result/structuredContent/type": type, "/result/structuredContent/path": "ordinary business path",
                "/result/structuredContent/detail": "future business detail", "/result/structuredContent/text": "original tool result"])
            #expect(batch.recoveredReferences.count == 1 && batch.recoveredReferences.first?.constraint == nil)
        }
    }

    @Test func rawTranscriptAuthorityDoesNotAcquireUnverifiedLocalMediaSemantics() async throws {
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "parent", "cli_version": "0.162.1"]],
            ["type": "response_item", "timestamp": "2026-10-11T10:00:00Z", "payload": ["type": "message",
                "id": "original-input", "role": "user", "content": [["type": "text", "text": "raw original"],
                    ["type": "localImage", "path": "not opened"]]]]]
        var bytes = Data()
        for row in rows { bytes.append(try JSONSerialization.data(withJSONObject: row)); bytes.append(10) }
        let batch = try await codexTestAdapter(selectedAuthority: .nativeRolloutTranscript).importTranscript(bytes,
            documentID: UUID(), observedAt: Date(), expectedSessionID: "parent", cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(batch.sources.count == 1 && codexText(batch.sources[0]) == "raw original")
        #expect(batch.coverageGaps.contains { $0.reason == .unsupportedContent })
        #expect(localMediaExclusion(batch) == nil && batch.recoveredReferences.isEmpty)
        #expect(batch.coverageGaps.allSatisfy { $0.recovery?.constraint == nil })
    }

    @Test func rowTimeIdentityAndAuditLimitsNeverYieldExclusionProof() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting(), adapter = try codexTestAdapter()
        let attachment: [String: Any] = ["type": "localImage", "path": "not opened"]
        for row in [try localMediaMessage([attachment], id: ""), try localMediaMessage([attachment], timestamp: nil)] {
            let batch = try await adapter.importPublicItems(.init(data: [row]), thread: codexThread(), observedAt: Date(), cryptography: crypto)
            #expect(batch.sources.isEmpty && batch.recoveredReferences.isEmpty && localMediaExclusion(batch) == nil)
            #expect(batch.coverageGaps.allSatisfy { $0.recovery?.constraint == nil })
        }
        let limited = try codexTestAdapter(limits: .init(maximumRowBytes: 1024))
        let oversized = try await limited.importPublicItems(.init(data: [localMediaMessage([
            attachment, ["type": "text", "text": String(repeating: "x", count: 2048)]])]), thread: codexThread(),
            observedAt: Date(), cryptography: crypto)
        #expect(oversized.coverageGaps.first?.reason == .budgetExhausted)
        #expect(oversized.sources.isEmpty && oversized.recoveredReferences.isEmpty && localMediaExclusion(oversized) == nil)
        let now = Date(timeIntervalSince1970: 1_791_434_500), audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let expired = try await adapter.importPublicItems(.init(data: [localMediaMessage([attachment],
            timestamp: audit.start.addingTimeInterval(-1).timeIntervalSince1970 * 1000)]), thread: codexThread(), observedAt: now,
            provenance: .historical(audit), cryptography: crypto)
        #expect(expired.sources.isEmpty && expired.coverageGaps.isEmpty && expired.recoveredReferences.isEmpty)
    }
}
