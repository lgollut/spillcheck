import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private func transcriptDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-claude-identity-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
}

private func transcriptRow(_ id: String, text: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["type": "user", "uuid": id, "sessionId": "session",
        "timestamp": "2026-10-07T20:00:00Z", "version": "2.1.293", "message": ["role": "user", "content": text]],
        options: [.sortedKeys]) + Data([10])
}

private func append(_ data: Data, to url: URL) throws {
    let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
    try file.seekToEnd(); try file.write(contentsOf: data)
}

/// The checkpoint as a new boot sees it. macOS numbers a volume when it mounts it, so the same
/// file can report another `st_dev` after a restart while its inode and birth time stay the same.
private func afterRestart(_ checkpoint: SourceCheckpoint, crypto: BackgroundCryptography) async throws -> SourceCheckpoint {
    let saved = try #require(checkpoint.adapterState)
    var cursor = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
    var signature = try #require(cursor["signature"] as? [String: Any])
    let device = try #require(signature["device"] as? NSNumber).uint64Value
    signature["device"] = NSNumber(value: device + 1)
    cursor["signature"] = signature
    let state = try JSONSerialization.data(withJSONObject: cursor, options: [.sortedKeys])
    return SourceCheckpoint(capabilityID: checkpoint.capabilityID, sourceDocumentID: checkpoint.sourceDocumentID,
        revision: try await crypto.revision(canonicalBytes: state), byteOffset: checkpoint.byteOffset,
        lastContentTime: checkpoint.lastContentTime, gaps: checkpoint.gaps, adapterState: state)
}

@Suite("Claude read positions across a restart")
struct ClaudeFileIdentityTests {
    @Test(arguments: [false, true])
    func anUnchangedTranscriptStaysReadAfterARestart(historical: Bool) async throws {
        let directory = try transcriptDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("conversation.jsonl")
        try transcriptRow("first", text: "read before the restart").write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory])
        let audit = try HistoricalAuditContext(reason: .resume,
            endingAt: ISO8601DateFormatter().date(from: "2026-10-08T00:00:00Z")!)
        let provenance: SourceProvenance = historical ? .historical(audit) : .live
        let before = try await adapter.readIncremental(path: file.path, interface: .t3, provenance: provenance,
            cryptography: crypto)
        #expect(before.batch.sources.count == 1)
        let saved = try await afterRestart(#require(before.batch.checkpoints.first), crypto: crypto)
        let after = try await adapter.readIncremental(path: file.path, interface: .t3, checkpoint: saved,
            provenance: provenance, cryptography: crypto)
        #expect(!after.batch.coverageGaps.contains { $0.reason == .sourceChanged })
        #expect(after.bytesRead == 0 && after.batch.sources.isEmpty)
    }

    @Test func aTranscriptThatGrewAcrossARestartContinuesWhereItStopped() async throws {
        let directory = try transcriptDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("conversation.jsonl")
        try transcriptRow("first", text: "read before the restart").write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory])
        let before = try await adapter.readIncremental(path: file.path, interface: .t3, cryptography: crypto)
        let saved = try await afterRestart(#require(before.batch.checkpoints.first), crypto: crypto)
        try append(transcriptRow("second", text: "written after the restart"), to: file)
        let after = try await adapter.readIncremental(path: file.path, interface: .t3, checkpoint: saved, cryptography: crypto)
        #expect(!after.batch.coverageGaps.contains { $0.reason == .sourceChanged })
        #expect(after.batch.sources.map(\.record.metadata.identity.itemID) == ["prompt:second:block:0"])
    }

    /// Ignoring the device number must not hide a file that was really replaced.
    @Test func aReplacedTranscriptIsStillReportedAfterARestart() async throws {
        let directory = try transcriptDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("conversation.jsonl")
        try transcriptRow("first", text: "read before the restart").write(to: file)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory])
        let before = try await adapter.readIncremental(path: file.path, interface: .t3, cryptography: crypto)
        let saved = try await afterRestart(#require(before.batch.checkpoints.first), crypto: crypto)
        try transcriptRow("replacement", text: "a different file at the same path").write(to: file, options: .atomic)
        let after = try await adapter.readIncremental(path: file.path, interface: .t3, checkpoint: saved, cryptography: crypto)
        #expect(after.batch.coverageGaps.contains { $0.reason == .sourceChanged })
        #expect(after.batch.sources.map(\.record.metadata.identity.itemID) == ["prompt:replacement:block:0"])
    }
}
