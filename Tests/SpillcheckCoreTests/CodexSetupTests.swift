import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

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
    @Test func verificationPromptIsOneUseBoundedAndSafeAsAShellArgument() {
        let first = SetupVerificationPrompt.make(), second = SetupVerificationPrompt.make()
        #expect(first != second)
        #expect(first.contains(SetupVerificationPrompt.marker))
        #expect(first.contains("Do not read files, run commands, or use tools."))
        // The app shows this prompt inside a single-quoted command, and the hook must receive it unchanged.
        #expect(!first.contains(where: { "'\"`$\\\n".contains($0) }))
    }

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
        #expect(hooks["PostToolUse"] != nil && hooks["Interrupt"] != nil)
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
        let upgraded = try codexConfiguration(version: "4.0.0")
        let installed = try config.editing(nil, action: .install)
        #expect(upgraded.isInstalled(in: installed))
        #expect(try upgraded.editing(installed, action: .install) == installed)
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

private actor MonitorBox {
    var monitor: CodexActiveHistoryMonitor?
    func set(_ value: CodexActiveHistoryMonitor) { monitor = value }
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
        try await monitor.addSource(.init(threadID: "parent", interface: .standaloneCLI, authority: .publicNativeItems))
        await #expect(throws: CodexCollectionError.authorityConflict) {
            try await monitor.addSource(.init(threadID: "parent", interface: .t3, authority: .nativeRolloutTranscript,
                transcriptURL: URL(fileURLWithPath: "/tmp/selected.jsonl")))
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

    /// Polls every second from `start`, reports each as the detection worker would, and returns
    /// (second, thread) for each poll made.
    private func pollEachSecond(_ monitor: CodexActiveHistoryMonitor, _ sink: CodexMonitorSink, from start: Date,
                                seconds: ClosedRange<Int>, outcome: (String, Date) async -> Void) async throws -> [String] {
        var polls: [String] = []
        for second in seconds {
            let now = start.addingTimeInterval(Double(second))
            let before = await sink.packets.count
            _ = try await monitor.pollOnce(at: now)
            for packet in await sink.packets.dropFirst(before) {
                let event = try #require(JSONSerialization.jsonObject(with: packet.eventJSON) as? [String: String])
                let thread = try #require(event["session_id"])
                polls.append("\(second):\(thread)")
                await outcome(thread, now)
            }
        }
        return polls
    }

    @Test func threadWhosePollsKeepFailingIsPolledExponentiallyLessOften() async throws {
        let sink = CodexMonitorSink()
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: []) { packet, _ in try await sink.accept(packet) }
        let start = Date(timeIntervalSince1970: 1_791_434_400)
        try await monitor.addSource(.init(threadID: "deleted", interface: .t3, authority: .publicNativeItems), at: start)
        let polls = try await pollEachSecond(monitor, sink, from: start, seconds: 0...3_000) { thread, now in
            await monitor.recordPollFailure(thread: thread, polledAt: now, at: now)
        }
        // The delay doubles with each failure on top of the cadence for how long the thread has been idle.
        #expect(polls == ["0:deleted", "2:deleted", "6:deleted", "14:deleted", "30:deleted", "62:deleted", "126:deleted", "766:deleted"])
        await monitor.stop()
    }

    @Test func attemptsToRetryOnePollCountAsOneFailure() async throws {
        let sink = CodexMonitorSink()
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: []) { packet, _ in try await sink.accept(packet) }
        let start = Date(timeIntervalSince1970: 1_791_434_400)
        try await monitor.addSource(.init(threadID: "thread", interface: .t3, authority: .publicNativeItems), at: start)
        var polledAt: [Date] = []
        // The pipeline attempts a failed poll four times, reporting each, the last after newer polls were made.
        let polls = try await pollEachSecond(monitor, sink, from: start, seconds: 0...100) { thread, now in
            polledAt.append(now)
            for _ in 0..<4 { await monitor.recordPollFailure(thread: thread, polledAt: now, at: now) }
            if let older = polledAt.dropLast().last { await monitor.recordPollFailure(thread: thread, polledAt: older, at: now) }
        }
        #expect(polls == ["0:thread", "2:thread", "6:thread", "14:thread", "30:thread", "62:thread"])
        // Once the outage ends the next poll succeeds and the normal cadence returns.
        await monitor.recordPollSuccess(thread: "thread", at: start.addingTimeInterval(62))
        #expect(try await monitor.pollOnce(at: start.addingTimeInterval(63)) == 1)
        await monitor.stop()
    }

    @Test func failureBackoffIsCappedAtAnHour() {
        #expect(CodexActiveHistoryMonitor.publicPollDelay(idle: 0, failures: 0) == 1)
        #expect(CodexActiveHistoryMonitor.publicPollDelay(idle: 0, failures: 3) == 8)
        #expect(CodexActiveHistoryMonitor.publicPollDelay(idle: 300, failures: 2) == 20)
        #expect(CodexActiveHistoryMonitor.publicPollDelay(idle: 700, failures: 6) == 1_920)
        #expect(CodexActiveHistoryMonitor.publicPollDelay(idle: 700, failures: 7) == 3_600)
        #expect(CodexActiveHistoryMonitor.publicPollDelay(idle: 0, failures: 5_000) == 3_600)
        #expect(CodexActiveHistoryMonitor.publicPollDelay(idle: 3_600, failures: 3) == nil)
    }

    @Test func aSuccessfulPollRestoresTheNormalDelay() async throws {
        let sink = CodexMonitorSink()
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: []) { packet, _ in try await sink.accept(packet) }
        let start = Date(timeIntervalSince1970: 1_791_434_400)
        try await monitor.addSource(.init(threadID: "thread", interface: .t3, authority: .publicNativeItems), at: start)
        for second in [0.0, 2, 6] {
            #expect(try await monitor.pollOnce(at: start.addingTimeInterval(second)) == 1)
            await monitor.recordPollFailure(thread: "thread", polledAt: start.addingTimeInterval(second), at: start.addingTimeInterval(second))
        }
        #expect(try await monitor.pollOnce(at: start.addingTimeInterval(10)) == 0)
        #expect(try await monitor.pollOnce(at: start.addingTimeInterval(14)) == 1)
        await monitor.recordPollSuccess(thread: "thread", at: start.addingTimeInterval(14))
        #expect(try await monitor.pollOnce(at: start.addingTimeInterval(14.5)) == 0)
        #expect(try await monitor.pollOnce(at: start.addingTimeInterval(15)) == 1)
        // Failures count from zero again.
        await monitor.recordPollFailure(thread: "thread", polledAt: start.addingTimeInterval(15), at: start.addingTimeInterval(15))
        #expect(try await monitor.pollOnce(at: start.addingTimeInterval(16)) == 0)
        #expect(try await monitor.pollOnce(at: start.addingTimeInterval(17)) == 1)
        await monitor.stop()
    }

    @Test func aFailureReportedWhileTheNextPollIsBeingQueuedStillBacksOff() async throws {
        let start = Date(timeIntervalSince1970: 1_791_434_400)
        let sink = CodexMonitorSink(), box = MonitorBox()
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: []) { packet, date in
            // The detection worker can fail the poll before enqueue returns to the monitor.
            await box.monitor?.recordPollFailure(thread: "thread", polledAt: date, at: date)
            try await sink.accept(packet)
        }
        await box.set(monitor)
        try await monitor.addSource(.init(threadID: "thread", interface: .t3, authority: .publicNativeItems), at: start)
        #expect(try await monitor.pollOnce(at: start) == 1)
        #expect(try await monitor.pollOnce(at: start.addingTimeInterval(1)) == 0)
        #expect(try await monitor.pollOnce(at: start.addingTimeInterval(2)) == 1)
        await monitor.stop()
    }

    @Test func aPollBeingQueuedDoesNotPullBackAFailureReportedLater() async throws {
        let start = Date(timeIntervalSince1970: 1_791_434_400)
        let sink = CodexMonitorSink(), box = MonitorBox()
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: []) { packet, date in
            // The failure arrives at a later time than the poll started.
            await box.monitor?.recordPollFailure(thread: "thread", polledAt: date, at: date.addingTimeInterval(3))
            try await sink.accept(packet)
        }
        await box.set(monitor)
        try await monitor.addSource(.init(threadID: "thread", interface: .t3, authority: .publicNativeItems), at: start)
        #expect(try await monitor.pollOnce(at: start) == 1)
        #expect(try await monitor.pollOnce(at: start.addingTimeInterval(4)) == 0)
        #expect(try await monitor.pollOnce(at: start.addingTimeInterval(5)) == 1)
        await monitor.stop()
    }

    @Test func hookActivityRestoresTheNormalDelay() async throws {
        let sink = CodexMonitorSink()
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: []) { packet, _ in try await sink.accept(packet) }
        let start = Date(timeIntervalSince1970: 1_791_434_400)
        let source = try CodexActiveSource(threadID: "thread", interface: .t3, authority: .publicNativeItems)
        try await monitor.addSource(source, at: start)
        for second in [0.0, 2, 6] {
            #expect(try await monitor.pollOnce(at: start.addingTimeInterval(second)) == 1)
            await monitor.recordPollFailure(thread: "thread", polledAt: start.addingTimeInterval(second), at: start.addingTimeInterval(second))
        }
        // A hook proves the thread exists.
        try await monitor.addSource(source, at: start.addingTimeInterval(10))
        #expect(try await monitor.pollOnce(at: start.addingTimeInterval(10)) == 1)
        #expect(try await monitor.pollOnce(at: start.addingTimeInterval(11)) == 1)
        await monitor.stop()
    }

    @Test func aFailingThreadDoesNotSlowOtherThreads() async throws {
        let sink = CodexMonitorSink()
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: []) { packet, _ in try await sink.accept(packet) }
        let start = Date(timeIntervalSince1970: 1_791_434_400)
        for thread in ["deleted", "healthy"] {
            try await monitor.addSource(.init(threadID: thread, interface: .t3, authority: .publicNativeItems), at: start)
        }
        let polls = try await pollEachSecond(monitor, sink, from: start, seconds: 0...30) { thread, now in
            if thread == "deleted" { await monitor.recordPollFailure(thread: thread, polledAt: now, at: now) }
            else { await monitor.recordPollSuccess(thread: thread, at: now) }
        }
        #expect(polls.filter { $0.hasSuffix(":healthy") }.count == 31)
        #expect(polls.filter { $0.hasSuffix(":deleted") } == ["0:deleted", "2:deleted", "6:deleted", "14:deleted", "30:deleted"])
        await monitor.stop()
    }

    @Test func rereadItemsLetAnIdleThreadSlowDownAndNewItemsSpeedItUp() async throws {
        let history = CodexTestHistory(), checkpoints = CodexCheckpoints(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let start = Date(timeIntervalSince1970: 1_791_434_400)
        await history.configure("parent", thread: try codexThread(updatedAt: 1_791_434_000),
            pages: [.init(data: [try codexItem("answer", timestamp: start.timeIntervalSince1970 * 1000)])])
        let adapter = try codexTestAdapter(history: history, checkpoints: { await checkpoints.get($0) })
        let sink = CodexMonitorSink()
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: []) { packet, _ in try await sink.accept(packet) }
        try await monitor.addSource(.init(threadID: "parent", interface: .t3, authority: .publicNativeItems), at: start)
        // Each poll is read and observed as the pipeline would. A poll rereads the thread's tail.
        func run(_ seconds: ClosedRange<Int>) async throws -> (polls: Int, rereads: Int) {
            var polls = 0, rereads = 0
            for second in seconds {
                let now = start.addingTimeInterval(Double(second))
                guard try await monitor.pollOnce(at: now) == 1 else { continue }
                polls += 1
                let batch = try await adapter.normalize(#require(await sink.packets.last), capturedAt: now, cryptography: crypto)
                await checkpoints.save(batch.checkpoints)
                if batch.sources.contains(where: { $0.record.metadata.identity.itemID == "answer" }) { rereads += 1 }
                await monitor.observe(batch, authority: .publicNativeItems, at: now)
            }
            return (polls, rereads)
        }
        let idle = try await run(0...399)
        #expect(idle.rereads == idle.polls)
        // Every second for two minutes after the last item, then every five seconds.
        #expect(idle.polls == 120 + 56)
        await history.configure("parent", thread: try codexThread(updatedAt: 1_791_434_000),
            pages: [.init(data: [try codexItem("answer", timestamp: start.timeIntervalSince1970 * 1000),
                                 try codexItem("later", timestamp: (start.timeIntervalSince1970 + 400) * 1000)])])
        #expect(try await run(400...409).polls == 10)
        await monitor.stop()
    }

    @Test func itemsFromAnEarlierRunDoNotRestartPolling() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let now = Date(timeIntervalSince1970: 1_791_434_400)
        await history.configure("parent", thread: try codexThread(updatedAt: 1_791_434_000),
            pages: [.init(data: [try codexItem("answer", timestamp: (now.timeIntervalSince1970 - 7_200) * 1000)])])
        let adapter = try codexTestAdapter(history: history)
        let batch = try await adapter.normalize(codexPacket(thread: "parent"), capturedAt: now, cryptography: crypto)
        #expect(!batch.sources.isEmpty)
        let sink = CodexMonitorSink()
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: []) { packet, _ in try await sink.accept(packet) }
        // A poll queued before a restart is processed later. Its items are two hours old.
        await monitor.observe(batch, authority: .publicNativeItems, at: now)
        #expect(try await monitor.pollOnce(at: now) == 0)
        #expect(try await monitor.pollOnce(at: now.addingTimeInterval(30)) == 0)
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
