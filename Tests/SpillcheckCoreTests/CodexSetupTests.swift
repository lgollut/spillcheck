import Foundation
import Testing
@testable import SpillcheckCore

func codexSetupDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-codex-setup-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return directory
}
private func codexConfiguration(version: String = "0.161.0") throws -> CodexHookConfiguration {
    try .init(registrationID: UUID(uuidString: "909ee8d0-77cb-4f58-91bb-0a36e996c89f")!,
        helperURL: URL(fileURLWithPath: "/usr/bin/true"), socketURL: URL(fileURLWithPath: "/tmp/space ' $ socket"),
        profileID: "test ' $", agentVersion: version)
}
@Suite("Codex owned hook setup")
struct CodexSetupTests {
    @Test func installRepairAndRemovePreserveUnrelatedHooksAndSettingsExactly() throws {
        let config = try codexConfiguration()
        let root: [String: Any] = ["unrelated": ["retained": 42],
            "hooks": ["Stop": [["matcher": "unrelated", "hooks": [["type": "command", "command": "existing", "timeout": 17],
                ["type": "command", "command": "other-owned", "statusMessage": "Spillcheck hook unrelated-uuid"]]]]]]
        let original = try JSONSerialization.data(withJSONObject: root)
        let installed = try config.editing(original, action: .install)
        #expect(config.isInstalled(in: installed))
        #expect(try config.editing(installed, action: .install) == installed)
        let removed = try JSONSerialization.jsonObject(with: config.editing(installed, action: .remove)) as! NSDictionary
        #expect(removed == root as NSDictionary)
        let parsed = try JSONSerialization.jsonObject(with: installed) as! [String: Any]
        let hooks = parsed["hooks"] as! [String: [[String: Any]]]
        for event in CodexHookConfiguration.events {
            let owned = hooks[event]!.flatMap { $0["hooks"] as! [[String: Any]] }.filter { $0["statusMessage"] as? String == config.ownershipMarker }
            #expect(owned.count == 1 && owned[0]["command"] as? String == config.command)
            #expect(owned[0]["timeout"] as? Int == 2)
        }
        #expect(config.command.contains("'\"'\"'"))
        #expect(!config.command.contains("dangerously-bypass"))
    }
    @Test func atomicOwnedInstallRequiresCorrectProviderOneUseDurableChallengeAndDetectsChange() async throws {
        let directory = try codexSetupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let hooks = directory.appendingPathComponent("hooks.json")
        let original = Data("{\"unrelated\":42}".utf8); try original.write(to: hooks)
        let config = try codexConfiguration(), setup = try CodexHookSetup(hooksURL: hooks, configuration: config)
        #expect(try await setup.install() == .installedUnverified)
        let challenge = try await setup.beginVerification()
        let event = try JSONSerialization.data(withJSONObject: ["hook_event_name": "UserPromptSubmit",
            "prompt": challenge.prompt, "session_id": "synthetic"])
        let foreign = try CapturePacket(metadata: .init(agent: .claudeCode, profileID: config.profileID), eventJSON: event)
        await #expect(throws: CodexSetupError.verificationFailed) {
            try await setup.acceptVerification(.init(packet: foreign, durableQueueID: UUID()))
        }
        let packet = try CapturePacket(metadata: .init(agent: .codex, profileID: config.profileID), eventJSON: event)
        try await setup.acceptVerification(.init(packet: packet, durableQueueID: UUID()))
        #expect(try await setup.check() == .connected)
        await #expect(throws: CodexSetupError.verificationFailed) {
            try await setup.acceptVerification(.init(packet: packet, durableQueueID: UUID()))
        }
        try original.write(to: hooks)
        #expect(try await setup.check() == .needsRepair)
        #expect(try await setup.repair() == .installedUnverified)
        try await setup.remove()
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: hooks)) as! NSDictionary == ["unrelated": 42] as NSDictionary)
        #expect((try FileManager.default.attributesOfItem(atPath: hooks.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["hooks.json"])
    }
    @Test func malformedOversizedUnsupportedAndSymlinkSettingsAreNeverReplaced() async throws {
        let config = try codexConfiguration()
        for input in ["[]", "{broken", "{\"hooks\":false}", "{\"hooks\":{\"Stop\":\"wrong\"}}"] {
            #expect(throws: CodexSetupError.malformedHooks) { try config.editing(Data(input.utf8), action: .install) }
        }
        #expect(throws: CodexSetupError.unsupportedVersion) { try codexConfiguration(version: "0.162.0").editing(nil, action: .install) }
        let large = try JSONSerialization.data(withJSONObject: ["padding": String(repeating: "a", count: 1024*1024 - 20)])
        #expect(throws: CodexSetupError.malformedHooks) { try config.editing(large, action: .install) }
        let directory = try codexSetupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("untouched.json"), hooks = directory.appendingPathComponent("hooks.json")
        let original = Data("{\"retained\":true}".utf8); try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: hooks, withDestinationURL: target)
        let setup = try CodexHookSetup(hooksURL: hooks, configuration: config)
        await #expect(throws: CodexSetupError.unsafeHooksPath) { try await setup.install() }
        #expect(try Data(contentsOf: target) == original)
    }
}

private actor CodexMonitorSink {
    var packets: [CapturePacket] = []
    var reject = false
    func accept(_ packet: CapturePacket) throws { if reject { throw CodexCollectionError.awaitingHistory }; packets.append(packet) }
    func rejecting(_ value: Bool) { reject = value }
    func count() -> Int { packets.count }
}
@Suite("Codex exact selected active sources")
struct CodexMonitorTests {
    @Test func warmTranscriptPollReadsNoPayloadAndRetryWaitsForDurableAdmission() async throws {
        let directory = try codexSetupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("synthetic.jsonl"); try Data("{}\n".utf8).write(to: path)
        let sink = CodexMonitorSink()
        let source = try CodexActiveSource(threadID: "child", interface: .t3, authority: .t3VersionedTranscript, transcriptURL: path)
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: [source]) { packet, _ in try await sink.accept(packet) }
        #expect(try await monitor.pollOnce() == 1)
        #expect(try await monitor.pollOnce() == 0)
        try Data("{}\n{}\n".utf8).write(to: path)
        await sink.rejecting(true)
        await #expect(throws: CodexCollectionError.awaitingHistory) { try await monitor.pollOnce() }
        await sink.rejecting(false)
        #expect(try await monitor.pollOnce() == 1)
        #expect(try await monitor.pollOnce() == 0)
        #expect(await sink.count() == 2)
    }
    @Test func publicPollingUsesOnlyAdmittedExactSourcesAndKeepsSameSecondUpdatesObservable() async throws {
        let sink = CodexMonitorSink()
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: [
            .init(threadID: "parent", interface: .t3, authority: .publicNativeItems)]) { packet, _ in try await sink.accept(packet) }
        let now = Date()
        #expect(try await monitor.pollOnce(at: now) == 1)
        #expect(try await monitor.pollOnce(at: now.addingTimeInterval(1)) == 1)
        try await monitor.addSource(.init(threadID: "parent", interface: .t3, authority: .publicNativeItems))
        await #expect(throws: CodexCollectionError.authorityConflict) {
            try await monitor.addSource(.init(threadID: "parent", interface: .standaloneCLI, authority: .publicNativeItems))
        }
        #expect(await sink.count() == 2)
        await monitor.stop()
    }

    @Test func publicPollingBacksOffWhileIdleAndResumesOnActivity() async throws {
        let sink = CodexMonitorSink()
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: []) { packet, _ in try await sink.accept(packet) }
        let start = Date()
        let source = try CodexActiveSource(threadID: "parent", interface: .t3, authority: .publicNativeItems)
        try await monitor.addSource(source, at: start)
        #expect(try await monitor.pollOnce(at: start) == 1)
        #expect(try await monitor.pollOnce(at: start.addingTimeInterval(0.5)) == 0)
        #expect(try await monitor.pollOnce(at: start.addingTimeInterval(1)) == 1)
        #expect(try await monitor.pollOnce(at: start.addingTimeInterval(300)) == 1)
        #expect(try await monitor.pollOnce(at: start.addingTimeInterval(302)) == 0)
        #expect(try await monitor.pollOnce(at: start.addingTimeInterval(3_700)) == 0)
        try await monitor.addSource(source, at: start.addingTimeInterval(3_700))
        #expect(try await monitor.pollOnce(at: start.addingTimeInterval(3_700)) == 1)
        #expect(await sink.count() == 4)
        await monitor.stop()
    }

    @Test func fullSourceListReplacesTheLeastRecentlyActiveThread() async throws {
        let sink = CodexMonitorSink()
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: []) { packet, _ in try await sink.accept(packet) }
        let start = Date()
        for index in 0..<256 {
            try await monitor.addSource(.init(threadID: "thread-\(index)", interface: .t3, authority: .publicNativeItems),
                                        at: start.addingTimeInterval(Double(index)))
        }
        let later = start.addingTimeInterval(4_000)
        try await monitor.addSource(.init(threadID: "newest", interface: .t3, authority: .publicNativeItems), at: later)
        #expect(try await monitor.pollOnce(at: later) == 1)
        let polled = try #require(await sink.packets.last)
        let event = try #require(JSONSerialization.jsonObject(with: polled.eventJSON) as? [String: String])
        #expect(event["session_id"] == "newest")
        await monitor.stop()
    }
}
