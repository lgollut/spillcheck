import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private struct ClaudeLiveReadBudgetDetector: SecretDetector {
    func scan(_ source: SourceRecord) async throws -> DetectorOutput {
        .init(detectorVersion: "claude-live-budget-fixture", findings: [], unlocated: [])
    }
}

@Suite("Claude live read budgets")
struct ClaudeLiveReadBudgetTests {
    @Test(arguments: ["SpillcheckTranscriptPoll", "SubagentStop"])
    func denseLiveReadsCommitAndContinueAcrossParentAndChild(event: String) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spillcheck-claude-live-budget-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let main = sources.appendingPathComponent("parent.jsonl")
        let child = sources.appendingPathComponent("parent/subagents/agent-child.jsonl")
        let files = event == "SubagentStop" ? [main, child] : [main]
        // The pipeline commits sources against the wall clock, so its queue claim must be current too.
        let now = Date()
        for (index, file) in files.enumerated() {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let session = index == 0 ? "parent" : "child"
            let control = try JSONSerialization.data(withJSONObject: ["type": "mode", "mode": "normal", "sessionId": session]) + Data([10])
            let response = try JSONSerialization.data(withJSONObject: ["type": "assistant", "uuid": "final",
                "sessionId": session, "version": "2.1.296", "timestamp": "2026-10-13T11:00:00Z",
                "message": ["role": "assistant", "content": "required response", "stop_reason": "end_turn"]]) + Data([10])
            // A native identity row at the front also enables the poll's availability recovery.
            // The remaining controls exercise both single-file and combined parent/child budgets.
            let controls = files.count == 1 ? 4095 : 2050
            try (response + Data(Array(repeating: control, count: controls).joined())).write(to: file)
        }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: root.appendingPathComponent("store"), cryptography: crypto)
        let adapter = try ClaudeAdapter(profileID: "live-budget", agentVersion: "2.1.296", allowedTranscriptRoots: [sources],
            checkpointLookup: { try await store.checkpoint(documentID: $0) })
        var hook = ["hook_event_name": event, "session_id": "parent", "transcript_path": main.path]
        if event == "SubagentStop" { hook["agent_transcript_path"] = child.path }
        let packet = try CapturePacket(metadata: .init(agent: .claudeCode, interface: .standaloneCLI, profileID: "live-budget"),
            eventJSON: JSONSerialization.data(withJSONObject: hook))
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now)
        let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
            detector: ClaudeLiveReadBudgetDetector(), detectorVersion: "claude-live-budget-fixture", liveSince: now)
        let first = try await pipeline.processNext(at: now)
        #expect(first == .processed)
        guard first == .processed else { try await store.close(); return }
        for file in files {
            let key = try await adapter.checkpointIdentity(path: file.path, provenance: .live, cryptography: crypto)
            let checkpoint = try #require(try await store.checkpoint(documentID: key))
            let byteCount = try Data(contentsOf: file).count
            #expect(checkpoint.byteOffset > 0)
            #expect(checkpoint.byteOffset < UInt64(byteCount))
        }
        for _ in 0..<4 {
            if try await store.queueStatistics().count == 0 { break }
            #expect(try await pipeline.processNext(at: now) == .processed)
        }
        #expect(try await store.queueStatistics().count == 0)
        for file in files {
            let key = try await adapter.checkpointIdentity(path: file.path, provenance: .live, cryptography: crypto)
            let byteCount = try Data(contentsOf: file).count
            #expect(try await store.checkpoint(documentID: key)?.byteOffset == UInt64(byteCount))
        }
        try await store.close()
    }
}
