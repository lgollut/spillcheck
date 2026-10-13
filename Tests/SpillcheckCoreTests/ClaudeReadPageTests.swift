import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

@Suite("Claude bounded decoded pages")
struct ClaudeReadPageTests {
    @Test func decodedRowsPreserveOffsetsCorrelationAndCommittedTimestampBounds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-page-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("session.jsonl")
        let prefix = Data("\n{invalid}\n{\"type\":\"ai-title\",\"sessionId\":\"session\",\"timestamp\":\"invalid\"}\n".utf8)
        let prompt = try row("prompt", date: "2026-10-13T11:00:00.125Z", content: "first prompt")
        let tool = try row("result", date: "2026-10-13T11:01:00Z", content: [
            ["type": "tool_result", "tool_use_id": "tool", "content": "tool output"]])
        let missingDate = try row("missing-date", date: nil, content: "unusable prompt")
        let unfinished = try row("future", date: "2026-10-13T12:00:00Z", content: "later prompt").dropLast()
        let committed = prefix + prompt + tool + missingDate
        try (committed + unfinished).write(to: path)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "page-test", agentVersion: "2.1.296", allowedTranscriptRoots: [root])
        let first = try await adapter.readIncremental(path: path.path, interface: .t3, cryptography: crypto)
        #expect(first.batch.sources.map(\.record.metadata.identity.itemID) == ["prompt:prompt:block:0", "tool:tool"])
        #expect(first.promptIDs == ["prompt"])
        #expect(first.toolIDs == ["tool"])
        #expect(Set(first.batch.coverageGaps.map(\.reason)) == [.malformedSource, .missingTimestamp, .incompleteMessage])
        let checkpoint = try #require(first.batch.checkpoints.first)
        #expect(checkpoint.byteOffset == committed.count)
        let cursor = try JSONDecoder().decode(ClaudeReadCursor.self, from: #require(checkpoint.adapterState))
        #expect(cursor.maximumSeenContentTime == ISO8601DateFormatter().date(from: "2026-10-13T11:01:00Z"))
        #expect(first.batch.sources.map(\.record.metadata.locator) == [
            .transcriptByteOffset(documentID: checkpoint.capabilityID, byteOffset: UInt64(prefix.count)),
            .transcriptByteOffset(documentID: checkpoint.capabilityID, byteOffset: UInt64(prefix.count + prompt.count)),
        ])
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([10])); try handle.close()
        let resumed = try await adapter.readIncremental(path: path.path, interface: .t3,
            checkpoint: checkpoint, cryptography: crypto)
        #expect(resumed.batch.sources.map(\.record.metadata.identity.itemID) == ["prompt:future:block:0"])
        #expect(resumed.promptIDs == ["prompt", "future"])
        #expect(resumed.toolIDs == ["tool"])
        #expect(resumed.batch.coverageGaps.isEmpty)
    }

    private func row(_ id: String, date: String?, content: Any) throws -> Data {
        var value: [String: Any] = ["type": "user", "sessionId": "session", "uuid": id, "promptId": id,
            "message": ["role": "user", "content": content]]
        if let date { value["timestamp"] = date }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data([10])
    }
}
