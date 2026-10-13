import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor ClaudeDesktopPackets {
    private var packets: [CapturePacket] = []
    func append(_ packet: CapturePacket) { packets.append(packet) }
    func values() -> [CapturePacket] { packets }
}
private func claudeDesktopDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-claude-desktop-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
private func claudeDesktopRow(_ id: String, session: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["type": "user", "uuid": id, "sessionId": session,
        "version": "2.1.295", "timestamp": "2026-10-09T12:00:00Z",
        "message": ["role": "user", "content": "FAKE_DESKTOP_\(id)"]]) + Data([10])
}

@Suite("Explicit Claude Desktop transcript route")
struct ClaudeDesktopRouteTests {
    @Test func desktopEligibilityDoesNotConferAcceptance() throws {
        for version in ["2.1.295", "3.0.0"] {
            #expect(CollectionCompatibility.isEligible(provider: .claudeCode, interface: .desktopCode, version: version))
            #expect(CollectionCompatibility.recordedEvidence(provider: .claudeCode, interface: .desktopCode,
                producerVersion: version, hostVersion: "2.31226.1") == .unverified)
            let adapter = try ClaudeAdapter(profileID: "selected", agentVersion: version, allowedTranscriptRoots: [])
            let capabilities = adapter.capabilities(interface: .desktopCode)
            #expect(capabilities.count == ContentType.allCases.count)
            #expect(capabilities.allSatisfy { $0.path == .versionedTranscript && $0.validation == .unverified
                && $0.canObserveActiveSession && $0.canReadHistoricalContent })
        }
        #expect(!CollectionCompatibility.isEligible(provider: .claudeCode, interface: .desktopCode, version: ""))
    }

    @Test func desktopPollingRequiresSelectedSourceAndReadsOnlyItsNativeChild() async throws {
        let root = try claudeDesktopDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent.jsonl")
        let childDirectory = root.appendingPathComponent("parent/subagents")
        try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
        let child = childDirectory.appendingPathComponent("agent-worker.jsonl")
        try claudeDesktopRow("parent-row", session: "parent").write(to: parent)
        try claudeDesktopRow("child-row", session: "own-child").write(to: child)
        try claudeDesktopRow("unselected-row", session: "unselected").write(to: root.appendingPathComponent("unselected.jsonl"))
        let sink = ClaudeDesktopPackets()
        let monitor = try ClaudeActiveTranscriptMonitor(profileID: "selected", sources: [], enqueue: { packet, _ in await sink.append(packet) })
        #expect(try await monitor.pollOnce() == 0)
        #expect(await sink.values().isEmpty)
        try await monitor.add(source: .init(sessionID: "parent", transcriptURL: parent, interface: .desktopCode))
        #expect(try await monitor.pollOnce() == 2)
        #expect(try await monitor.pollOnce() == 0)
        let packets = await sink.values()
        #expect(packets.allSatisfy { $0.metadata.interface == .desktopCode })
        let adapter = try ClaudeAdapter(profileID: "selected", agentVersion: "2.1.295", allowedTranscriptRoots: [root])
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        var identities = Set<String>(), sessions = Set<String>()
        for packet in packets {
            let batch = try await adapter.normalize(packet, capturedAt: Date(), cryptography: crypto)
            #expect(batch.coverageGaps.isEmpty)
            #expect(batch.sources.allSatisfy { $0.record.metadata.origin.interface == .desktopCode })
            identities.formUnion(batch.sources.map(\.record.metadata.identity.itemID))
            sessions.formUnion(batch.sources.map(\.record.metadata.identity.session.sessionID))
        }
        #expect(identities == ["prompt:parent-row:block:0", "prompt:child-row:block:0"])
        #expect(sessions == ["parent", "own-child"])
        #expect(throws: ClaudeCollectionError.invalidConfiguration) {
            try ClaudeActiveSource(sessionID: "", transcriptURL: parent, interface: .desktopCode)
        }
    }

    @Test func exactDesktopHistoryReadsSelectedChildWithoutParentOrSibling() async throws {
        let root = try claudeDesktopDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let childDirectory = root.appendingPathComponent("parent/subagents")
        try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
        let child = childDirectory.appendingPathComponent("agent-worker.jsonl")
        try claudeDesktopRow("child-row", session: "own-child").write(to: child)
        try claudeDesktopRow("sibling-row", session: "sibling").write(to: childDirectory.appendingPathComponent("agent-sibling.jsonl"))
        let adapter = try ClaudeAdapter(profileID: "selected", agentVersion: "2.1.295", allowedTranscriptRoots: [root])
        let scope = CollectionScope(provider: .claudeCode, profileID: "selected", interface: .desktopCode, path: .versionedTranscript)
        let now = Date(timeIntervalSince1970: 1_791_676_800)
        let audit = try HistoricalAuditContext(reason: .resume, endingAt: now)
        let packet = try await adapter.initialHistoricalCapture(audit: audit, source: .init(scope: scope, sourceURL: child))
        #expect(packet.metadata.interface == .desktopCode)
        let batch = try await adapter.normalize(packet, capturedAt: now, cryptography: .ephemeralForTesting())
        #expect(batch.sources.map(\.record.metadata.identity.itemID) == ["prompt:child-row:block:0"])
        #expect(batch.sources.map(\.record.metadata.identity.session.sessionID) == ["own-child"])
        #expect(batch.coverageGaps.isEmpty && batch.continuation == nil && batch.historicalProgress?.hasUnreadContent == false)
        let foreign = root.deletingLastPathComponent().appendingPathComponent("unselected.jsonl")
        await #expect(throws: ClaudeCollectionError.unsafeTranscriptPath) {
            try await adapter.initialHistoricalCapture(audit: audit, source: .init(scope: scope, sourceURL: foreign))
        }
    }
}
