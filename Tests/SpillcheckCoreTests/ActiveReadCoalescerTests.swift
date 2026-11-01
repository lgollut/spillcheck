import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

@Suite("Queueing one waiting read per active source")
struct ActiveReadCoalescerTests {
    private struct Fixture {
        let directory: URL
        let store: ProtectedStore
        let permit: StoreProcessingPermit
        let reads: ActiveReadCoalescer

        init() async throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-coalesce-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let store = try await ProtectedStore.open(at: directory.appendingPathComponent("store"),
                cryptography: try BackgroundCryptography.ephemeralForTesting())
            self.store = store
            permit = try #require(await store.processingPermit())
            reads = ActiveReadCoalescer { id in try await store.isAwaitingFirstAttempt(id) }
        }

        /// The production path: a monitor's poll, then the store's queue.
        func enqueue(_ packet: CapturePacket) async throws {
            let store = store, permit = permit
            try await reads.enqueue(packet) { packet in
                switch try await store.enqueue(packet.body, capturedAt: Date(), permit: permit) {
                case .inserted(let id), .alreadyQueued(let id), .alreadyProcessed(let id): id
                }
            }
        }

        func queued() async throws -> Int { try await store.queueStatistics().count }
    }

    private func poll(_ session: String, interface: AgentInterface = .standaloneCLI) throws -> CapturePacket {
        try CapturePacket(metadata: .init(agent: .claudeCode, interface: interface, profileID: "test"),
            eventJSON: JSONSerialization.data(withJSONObject: ["hook_event_name": "SpillcheckTranscriptPoll",
                "session_id": session, "transcript_path": "/tmp/\(session).jsonl"], options: [.sortedKeys]))
    }

    @Test func aTranscriptChangingWhileItsReadWaitsQueuesThatReadOnce() async throws {
        // The installed app queued a read for every change to an active transcript, every 250 ms,
        // even while an earlier read of it still waited. Each later read found nothing new.
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let transcript = fixture.directory.appendingPathComponent("session.jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        let monitor = try ClaudeActiveTranscriptMonitor(profileID: "test",
            sources: [.init(sessionID: "session", transcriptURL: transcript, interface: .standaloneCLI)],
            enqueue: { packet, _ in try await fixture.enqueue(packet) })
        let handle = try FileHandle(forWritingTo: transcript)
        defer { try? handle.close() }
        for row in 0..<3 {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"row\":\(row)}\n".utf8))
            #expect(try await monitor.pollOnce() == 1)
        }
        #expect(try await fixture.queued() == 1)
    }

    @Test func aClaimedOrRetryingReadNoLongerStandsInForANewOne() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.enqueue(poll("a"))
        try await fixture.enqueue(poll("a"))
        // Another source, or the same session through another interface, is a different read.
        try await fixture.enqueue(poll("b"))
        try await fixture.enqueue(poll("a", interface: .t3))
        #expect(try await fixture.queued() == 3)

        // A running read may already be past the change, so the change is queued again.
        let running = try #require(try await fixture.store.nextPending(at: Date(), permit: fixture.permit))
        try await fixture.enqueue(poll("a"))
        #expect(try await fixture.queued() == 4)
        try await fixture.enqueue(poll("a"))
        #expect(try await fixture.queued() == 4)

        // So may one waiting to retry; the read queued behind it still absorbs later changes.
        try await fixture.store.retry(running, reason: .scannerUnavailable, at: Date(), permit: fixture.permit)
        try await fixture.enqueue(poll("a"))
        #expect(try await fixture.queued() == 4)
        #expect(try await fixture.store.isAwaitingFirstAttempt(running.id) == false)
    }
}
