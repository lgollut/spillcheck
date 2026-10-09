import Foundation
import Testing
@testable import SpillcheckCore

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
    var reject = false
    func accept(_ packet:CapturePacket) throws { if reject { throw ClaudeCollectionError.awaitingTranscript }; packets.append(packet) }
    func setReject(_ value:Bool) { reject = value }
    func count() ->Int { packets.count }
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
}
