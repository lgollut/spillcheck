import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private func claudeSetupDirectory() throws -> URL {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-claude-setup-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    return path
}
private func configuration(version: String = "2.1.293") throws -> ClaudeHookConfiguration {
    try .init(registrationID:UUID(uuidString:"909ee8d0-77cb-4f58-91bb-0a36e996c89f")!,
        helperURL:URL(fileURLWithPath:"/usr/bin/true"),socketURL:URL(fileURLWithPath:"/tmp/space ' dollar $ backtick ` socket"),
        profileID:"test ' $ `",agentVersion:version)
}
@Suite("Claude owned setup")
struct ClaudeSetupTests {
    @Test func preservesUnrelatedSettingsHandlersAndMatchersAcrossIdempotentInstallRemoveRepair() throws {
        let config = try configuration()
        let root:[String:Any] = ["permissions":["allow":["Bash(echo *)"]],"env":["EXAMPLE":"unrelated"],
            "hooks":["PostToolBatch":[["hooks":[["type":"command","command":"unrelated","timeout":17,"async":true]]]],
                     "PostToolUse":[["matcher":"Bash","hooks":[["type":"command","command":"another"],["type":"http","url":"https://example.invalid/hook"]]]]]]
        let original = try JSONSerialization.data(withJSONObject:root)
        let installed = try config.editing(original,action:.install)
        #expect(config.isInstalled(in:installed))
        #expect(try config.editing(installed,action:.install) == installed)
        let removed = try config.editing(installed,action:.remove)
        #expect((try JSONSerialization.jsonObject(with:removed) as! NSDictionary) == (try JSONSerialization.jsonObject(with:original) as! NSDictionary))
        #expect(try config.editing(removed,action:.install) == installed)
        let parsed = try JSONSerialization.jsonObject(with:installed) as! [String:Any]
        let hooks = parsed["hooks"] as! [String:[[String:Any]]]
        for event in ClaudeHookConfiguration.events {
            let owned = hooks[event]!.flatMap { $0["hooks"] as! [[String:Any]] }.filter { $0["statusMessage"] as? String == config.ownershipMarker }
            #expect(owned.count == 1)
            #expect(owned[0]["command"] as? String == "/usr/bin/true")
            #expect(owned[0]["args"] as? [String] == config.arguments)
        }
    }

    @Test func malformedOrUnsupportedSettingsFailWithoutOverwriting() throws {
        let config = try configuration()
        for input in ["{broken", "[]", "{\"hooks\":false}", "{\"hooks\":{\"Stop\":\"wrong\"}}"] {
            #expect(throws:ClaudeSetupError.malformedSettings) { try config.editing(Data(input.utf8),action:.install) }
        }
        #expect(try configuration(version:"2.1.295").editing(nil,action:.install) == config.editing(nil,action:.install))
        #expect(throws:ClaudeSetupError.unsupportedVersion) { try configuration(version:"").editing(nil,action:.install) }
    }

    @Test func atomicFileInstallNeedsOneUseDurableSyntheticVerificationThenDetectsTampering() async throws {
        let directory = try claudeSetupDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
        let settings = directory.appendingPathComponent("settings.json")
        try Data("{\"unrelated\":42}".utf8).write(to:settings)
        let config = try configuration(), setup = try ClaudeHookSetup(settingsURL:settings,configuration:config)
        #expect(try await setup.install() == .installedUnverified)
        #expect(try await setup.check() == .installedUnverified)
        let challenge = try await setup.beginVerification()
        let wrong = try CapturePacket(metadata:.init(agent:.claudeCode,profileID:config.profileID),eventJSON:Data("{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"wrong\",\"session_id\":\"s\"}".utf8))
        await #expect(throws:ClaudeSetupError.verificationFailed) { try await setup.acceptVerification(.init(packet:wrong,durableQueueID:UUID())) }
        let hook:[String:String] = ["hook_event_name":"UserPromptSubmit","prompt":challenge.prompt,"session_id":"synthetic-session"]
        let packet = try CapturePacket(metadata:.init(agent:.claudeCode,profileID:config.profileID),eventJSON:JSONSerialization.data(withJSONObject:hook))
        try await setup.acceptVerification(.init(packet:packet,durableQueueID:UUID()))
        #expect(try await setup.check() == .connected)
        await #expect(throws:ClaudeSetupError.verificationFailed) { try await setup.acceptVerification(.init(packet:packet,durableQueueID:UUID())) }
        try Data("{\"unrelated\":42}".utf8).write(to:settings)
        #expect(try await setup.check() == .needsRepair)
        #expect(try await setup.repair() == .installedUnverified)
        try await setup.remove()
        #expect((try JSONSerialization.jsonObject(with:Data(contentsOf:settings)) as! NSDictionary) == ["unrelated":42] as NSDictionary)
        #expect((try FileManager.default.attributesOfItem(atPath:settings.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath:directory.path) == ["settings.json"])
    }

    @Test func symlinkSettingsAreRejectedWithoutChangingTarget() async throws {
        let directory = try claudeSetupDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
        let target = directory.appendingPathComponent("untouched.json"), settings = directory.appendingPathComponent("settings.json")
        let original = Data("{\"unrelated\":true}".utf8); try original.write(to:target)
        try FileManager.default.createSymbolicLink(at:settings,withDestinationURL:target)
        let setup = try ClaudeHookSetup(settingsURL:settings,configuration:configuration())
        await #expect(throws:ClaudeSetupError.unsafeSettingsPath) { try await setup.install() }
        #expect(try Data(contentsOf:target) == original)
    }
}

private actor ClaudeMonitorSink {
    var packets:[CapturePacket] = []
    var gaps: [CoverageGap] = []
    var reject = false
    func accept(_ packet:CapturePacket) throws { if reject { throw ClaudeCollectionError.awaitingTranscript }; packets.append(packet) }
    func setReject(_ value:Bool) { reject = value }
    func count() ->Int { packets.count }
    func recorded() -> [CapturePacket] { packets }
    func recordGap(_ gap: CoverageGap) { gaps.append(gap) }
    func observedGaps() -> [CoverageGap] { gaps }
}
private actor ClaudeCancelledMonitorSink {
    var began=false, cancelled=false, gaps=0
    var waiting:CheckedContinuation<Void,Never>?
    var beganWaiters:[CheckedContinuation<Void,Never>]=[]
    func accept() async throws {
        began=true
        for waiter in beganWaiters { waiter.resume() }; beganWaiters=[]
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiting=$0 }
        } onCancel: { Task { await self.cancel() } }
        try Task.checkCancellation()
    }
    func waitUntilBegan() async { if !began { await withCheckedContinuation { beganWaiters.append($0) } } }
    func cancel() { cancelled=true; waiting?.resume(); waiting=nil }
    func gap() { gaps += 1 }
    func status() ->(Bool,Int) { (cancelled,gaps) }
}
@Suite("Claude selected active sources")
struct ClaudeMonitorTests {
    @Test func unavailableParentDoesNotBlockReadableSelectedChild() async throws {
        let directory = try claudeSetupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("parent.jsonl")
        let children = directory.appendingPathComponent("parent/subagents")
        try FileManager.default.createDirectory(at: children, withIntermediateDirectories: true)
        let child = children.appendingPathComponent("agent-child.jsonl")
        let content = try JSONSerialization.data(withJSONObject: ["type": "user", "uuid": "child-prompt",
            "sessionId": "native-child", "version": "2.1.293", "timestamp": "2026-10-07T20:00:00Z",
            "message": ["role": "user", "content": "FAKE_CHILD_PROMPT"]]) + Data([10])
        try content.write(to: child)
        let sink = ClaudeMonitorSink()
        let monitor = try ClaudeActiveTranscriptMonitor(profileID: "test", sources: [.init(sessionID: "parent", transcriptURL: parent)],
            enqueue: { packet, _ in try await sink.accept(packet) }, onGap: { await sink.recordGap($0) })
        #expect(try await monitor.pollOnce() == 1)
        let gaps = await sink.observedGaps()
        #expect(gaps.count == 1 && gaps.first?.reason == .sourceUnavailable)
        #expect(gaps.first?.recovery?.sourceURL == parent)
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory])
        let packet = try #require(await sink.recorded().first)
        let batch = try await adapter.normalize(packet, capturedAt: Date(), cryptography: .ephemeralForTesting())
        #expect(batch.coverageGaps.isEmpty)
        #expect(batch.sources.map(\.record.metadata.identity.itemID) == ["prompt:child-prompt:block:0"])
        #expect(batch.sources.first?.record.metadata.identity.session.sessionID == "native-child")
        #expect(batch.sources.first?.context?.transcriptPath == claudeConfiguredURL(child).path)
    }

    @Test(arguments: ["parent", "distinct-child"])
    func selectedChildPollingUsesPersistedNativeIdentity(childSession: String) async throws {
        let directory = try claudeSetupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("parent.jsonl")
        let children = directory.appendingPathComponent("parent/subagents")
        try FileManager.default.createDirectory(at: children, withIntermediateDirectories: true)
        let child = children.appendingPathComponent("agent-child.jsonl")
        func row(_ id: String, session: String, role: String = "user", content: Any, stop: String? = nil) throws -> Data {
            var message: [String: Any] = ["role": role, "content": content]
            if let stop { message["stop_reason"] = stop }
            return try JSONSerialization.data(withJSONObject: ["type": role, "uuid": id, "sessionId": session,
                "version": "2.1.293", "timestamp": "2026-10-07T20:00:00Z", "message": message], options: [.sortedKeys]) + Data([10])
        }
        try row("parent-prompt", session: "parent", content: "FAKE_PARENT_PROMPT").write(to: parent)
        var content = try row("child-prompt", session: childSession, content: "FAKE_CHILD_PROMPT")
        content += try row("child-intermediate", session: childSession, role: "assistant", content: "FAKE_CHILD_INTERMEDIATE")
        content += try row("child-shell", session: childSession, content: [
                ["type": "tool_result", "tool_use_id": "child-shell-ok", "content": "FAKE_CHILD_SHELL_OK"],
                ["type": "tool_result", "tool_use_id": "child-shell-error", "content": "FAKE_CHILD_SHELL_ERROR", "is_error": true]])
        content += try row("child-mcp", session: childSession, content: [
                ["type": "tool_result", "tool_use_id": "child-mcp-ok", "content": ["result": "FAKE_CHILD_MCP_OK"]],
                ["type": "tool_result", "tool_use_id": "child-mcp-error", "content": ["error": "FAKE_CHILD_MCP_ERROR"], "is_error": true]])
        content += try row("child-final", session: childSession, role: "assistant", content: "FAKE_CHILD_FINAL", stop: "end_turn")
        try content.write(to: child)
        let sink = ClaudeMonitorSink()
        let monitor = try ClaudeActiveTranscriptMonitor(profileID: "test", sources: [.init(sessionID: "parent", transcriptURL: parent)]) {
            packet, _ in try await sink.accept(packet)
        }
        #expect(try await monitor.pollOnce() == 2)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.293", allowedTranscriptRoots: [directory])
        var collected: [CollectedSource] = [], gaps: [CoverageGap] = []
        for packet in await sink.recorded() {
            let batch = try await adapter.normalize(packet, capturedAt: Date(), cryptography: crypto)
            collected += batch.sources.filter { $0.context?.transcriptPath == claudeConfiguredURL(child).path }
            gaps += batch.coverageGaps
        }
        #expect(gaps.isEmpty)
        #expect(collected.count == 7)
        #expect(Set(collected.map(\.record.metadata.contentType)) == Set(ContentType.allCases))
        #expect(collected.allSatisfy { $0.record.metadata.identity.session.sessionID == childSession })
        let canonical = try await adapter.importTranscript(content, documentID: UUID(), interface: .t3,
            observedAt: Date(), cryptography: crypto)
        #expect(collected.map(\.record.metadata.identity) == canonical.sources.map(\.record.metadata.identity))
        #expect(collected.map(\.record.revision) == canonical.sources.map(\.record.revision))
    }

    @Test func warmPollDoesNotEnqueueAndChangesWaitForDurableAdmission() async throws {
        let directory = try claudeSetupDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
        let file = directory.appendingPathComponent("source.jsonl"); try Data("{}\n".utf8).write(to:file)
        let sink = ClaudeMonitorSink()
        let monitor = try ClaudeActiveTranscriptMonitor(profileID:"test",sources:[.init(sessionID:"s",transcriptURL:file)]) { packet,_ in try await sink.accept(packet) }
        #expect(try await monitor.pollOnce() == 1)
        #expect(try await monitor.pollOnce() == 0)
        try Data("{}\n{}\n".utf8).write(to:file)
        await sink.setReject(true)
        await #expect(throws:ClaudeCollectionError.awaitingTranscript) { try await monitor.pollOnce() }
        await sink.setReject(false)
        #expect(try await monitor.pollOnce() == 1)
        #expect(try await monitor.pollOnce() == 0)
        #expect(await sink.count() == 2)
    }

    @Test func selectedConversationDiscoversOwnNativeChildrenAndIgnoresOtherSessions() async throws {
        let directory=try claudeSetupDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
        let parent=directory.appendingPathComponent("parent.jsonl"); try Data("{}\n".utf8).write(to:parent)
        let children=directory.appendingPathComponent("parent/subagents")
        try FileManager.default.createDirectory(at:children,withIntermediateDirectories:true)
        try Data("{}\n".utf8).write(to:children.appendingPathComponent("agent-child.jsonl"))
        let other=directory.appendingPathComponent("unselected/subagents")
        try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
        try Data("{}\n".utf8).write(to:other.appendingPathComponent("agent-other.jsonl"))
        let sink=ClaudeMonitorSink()
        let monitor=try ClaudeActiveTranscriptMonitor(profileID:"test",sources:[.init(sessionID:"parent",transcriptURL:parent)]) { packet,_ in try await sink.accept(packet) }
        #expect(try await monitor.pollOnce() == 2)
        #expect(try await monitor.pollOnce() == 0)
        #expect(await sink.count() == 2)
    }

    @Test func stopAwaitsCancelledPollingTaskAndDoesNotReportIntentionalCancellationAsLoss() async throws {
        let directory=try claudeSetupDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
        let file=directory.appendingPathComponent("source.jsonl"); try Data("{}\n".utf8).write(to:file)
        let sink=ClaudeCancelledMonitorSink()
        let monitor=try ClaudeActiveTranscriptMonitor(profileID:"test",sources:[.init(sessionID:"s",transcriptURL:file)],
            enqueue:{ _,_ in try await sink.accept() },onGap:{ _ in await sink.gap() })
        await monitor.start()
        await sink.waitUntilBegan()
        await monitor.stop()
        let status=await sink.status()
        #expect(status.0)
        #expect(status.1 == 0)
    }

    @Test func unchangedTranscriptIsCheckedLessOftenUntilItIsSelectedAgain() async throws {
        let directory = try claudeSetupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        // Each check of a missing transcript reports one availability gap, so gaps count checks.
        let source = try ClaudeActiveSource(sessionID: "idle", transcriptURL: directory.appendingPathComponent("missing.jsonl"))
        let sink = ClaudeMonitorSink()
        let monitor = try ClaudeActiveTranscriptMonitor(profileID: "test", sources: [],
            enqueue: { packet, _ in try await sink.accept(packet) }, onGap: { await sink.recordGap($0) })
        let start = Date()
        await monitor.add(source: source, at: start)
        for tick in 0..<(4 * 7185) { _ = try await monitor.pollOnce(at: start.addingTimeInterval(Double(tick) / 4)) }
        let checks = await sink.observedGaps().count
        // Every pass for two minutes, every 2 s until ten minutes, every 10 s until an hour, then
        // every 30 s: the last check was at 7,170 s and the next is due at 7,200 s.
        #expect(checks == 4 * 120 + 480 / 2 + 3000 / 10 + 3600 / 30)
        let later = start.addingTimeInterval(7185)
        _ = try await monitor.pollOnce(at: later)
        #expect(await sink.observedGaps().count == checks)
        // Selecting the source again, as a hook for its session does, checks it on the next pass.
        await monitor.add(source: source, at: later)
        _ = try await monitor.pollOnce(at: later)
        #expect(await sink.observedGaps().count == checks + 1)
    }

    @Test func changedTranscriptIsCheckedOnEveryPassAgain() async throws {
        let directory = try claudeSetupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.jsonl"); try Data("{}\n".utf8).write(to: file)
        let sink = ClaudeMonitorSink()
        let start = Date()
        let monitor = try ClaudeActiveTranscriptMonitor(profileID: "test", sources: [],
            enqueue: { packet, _ in try await sink.accept(packet) })
        await monitor.add(source: try .init(sessionID: "s", transcriptURL: file), at: start)
        #expect(try await monitor.pollOnce(at: start) == 1)
        // After an idle hour the transcript is checked every 30 s, so a change waits for that check.
        var time = start
        for tick in 1...(4 * 3600) { time = start.addingTimeInterval(Double(tick) / 4); _ = try await monitor.pollOnce(at: time) }
        try Data("{}\n{}\n".utf8).write(to: file)
        var found = 0, waited = 0.0
        while found == 0, waited < 31 { waited += 0.25; found = try await monitor.pollOnce(at: time.addingTimeInterval(waited)) }
        #expect(found == 1)
        // Once it changed, the next change is read on the very next pass.
        try Data("{}\n{}\n{}\n".utf8).write(to: file)
        #expect(try await monitor.pollOnce(at: time.addingTimeInterval(waited + 0.25)) == 1)
        #expect(await sink.count() == 3)
    }

    @Test func failedSourceIsReportedWithoutSkippingLaterSourcesInThePass() async throws {
        let directory = try claudeSetupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.jsonl"), second = directory.appendingPathComponent("second.jsonl")
        try Data("{}\n".utf8).write(to: first); try Data("{}\n".utf8).write(to: second)
        let sink = ClaudeMonitorSink()
        let monitor = try ClaudeActiveTranscriptMonitor(profileID: "test", sources: [
            .init(sessionID: "first", transcriptURL: first), .init(sessionID: "second", transcriptURL: second)],
            enqueue: { packet, _ in
                let event = try #require(JSONSerialization.jsonObject(with: packet.eventJSON) as? [String: String])
                if event["session_id"] == "first" { throw ClaudeCollectionError.awaitingTranscript }
                try await sink.accept(packet)
            }, onGap: { await sink.recordGap($0) })
        await #expect(throws: ClaudeCollectionError.awaitingTranscript) { try await monitor.pollOnce() }
        #expect(await sink.count() == 1)
        let gaps = await sink.observedGaps()
        #expect(gaps.count == 1 && gaps.first?.reason == .deliveryUncertain && gaps.first?.recovery?.sourceURL == first)
    }

    @Test func failedChildDeliveryLeavesADurableWarningWithoutAGuessedIdentity() async throws {
        let directory = try claudeSetupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("parent.jsonl")
        let children = directory.appendingPathComponent("parent/subagents")
        try FileManager.default.createDirectory(at: children, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: parent)
        try Data("{}\n".utf8).write(to: children.appendingPathComponent("agent-child.jsonl"))
        let store = try await ProtectedStore.open(at: directory.appendingPathComponent("store"),
            cryptography: BackgroundCryptography.ephemeralForTesting())
        let monitor = try ClaudeActiveTranscriptMonitor(profileID: "test",
            sources: [.init(sessionID: "parent", transcriptURL: parent)],
            enqueue: { packet, _ in
                let event = try #require(JSONSerialization.jsonObject(with: packet.eventJSON) as? [String: String])
                if event["agent_transcript_path"] != nil { throw ClaudeCollectionError.awaitingTranscript }
            }, onGap: { gap in try? await store.recordCoverageGap(gap) }) // Mirrors the app's handler.
        await #expect(throws: ClaudeCollectionError.awaitingTranscript) { try await monitor.pollOnce() }
        let gaps = try await store.coverageGaps()
        #expect(gaps.count == 1 && gaps.first?.reason == .deliveryUncertain)
        #expect(gaps.first?.scope?.path == .versionedTranscript && gaps.first?.operation == .liveRead)
        #expect(try await store.coverageOmissions().isEmpty)
        try await store.close()
    }
}
