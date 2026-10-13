import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor DesktopCollectionSpy: CaptureNormalizer {
    private(set) var packets: [CapturePacket] = []
    private(set) var hookCalls = 0
    func append(_ packet: CapturePacket) { packets.append(packet) }
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) -> CollectionBatch {
        hookCalls += 1
        return .init(sources: [])
    }
}

@Suite("T3 Codex collection uses provider session identity")
struct CodexT3SessionCollectionTests {
    @Test func desktopNativeMainPreservesCanonicalSourcesWithoutHostAcceptance() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting(), now = Date()
        let history = CodexTestHistory(), authority = CodexTestAuthority()
        let items = try [
            codexItem("prompt", type: "userMessage", body: ["content": [["type": "text", "text": "fake desktop prompt"]]]),
            codexItem("progress", body: ["text": "fake progress", "phase": "commentary"]),
            codexItem("final", body: ["text": "fake final", "phase": "final_answer"]),
            codexItem("output", type: "commandExecution", body: ["status": "completed", "exitCode": 0, "aggregatedOutput": "fake output"]),
            codexItem("error", type: "commandExecution", body: ["status": "completed", "exitCode": 3, "aggregatedOutput": "fake error"])
        ]
        await history.configure("native-main", thread: try codexThread("native-main"), pages: [.init(data: items)])
        var first: CollectionBatch?
        for interface in [AgentInterface.desktopCode, .standaloneCLI, .t3] {
            let adapter = try codexTestAdapter(authority: authority, history: history,
                interface: interface, version: "0.162.1", t3Version: nil)
            let batch = try await adapter.normalize(codexPacket(thread: "native-main", interface: interface),
                capturedAt: now, cryptography: crypto)
            #expect(batch.coverageGaps.isEmpty)
            #expect(Set(batch.sources.map(\.record.metadata.contentType)) == Set(ContentType.allCases))
            #expect(adapter.capabilities().allSatisfy { $0.validation == .unverified })
            if let first {
                #expect(batch.sources.map(\.record.metadata.identity) == first.sources.map(\.record.metadata.identity))
                #expect(batch.sources.map(\.record.revision) == first.sources.map(\.record.revision))
            } else { first = batch }
        }
        #expect(CollectionCompatibility.isEligible(provider: .claudeCode, interface: .desktopCode, version: "2.1.295"))
        #expect(CollectionCompatibility.recordedEvidence(provider: .claudeCode, interface: .desktopCode,
            producerVersion: "2.1.295") == .unverified)
        #expect(!(await history.recordedCalls()).contains { $0.hasPrefix("list:") })
    }

    @Test func desktopNativePollingAndMissingHistoryNeverEnrollHooksOrAllowTranscriptAuthority() async throws {
        let sink = DesktopCollectionSpy(), authority = CodexTestAuthority()
        let source = try CodexActiveSource(threadID: "native-main", interface: .desktopCode, authority: .publicNativeItems)
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: [source]) { packet, _ in
            await sink.append(packet)
        }
        #expect(try await monitor.pollOnce() == 1)
        let packet = try #require(await sink.packets.first)
        #expect(packet.metadata.interface == .desktopCode)
        let adapter = try codexTestAdapter(authority: authority, interface: .desktopCode)
        let route = CollectionCaptureRoute(scope: .init(provider: .codex, profileID: "test",
            interface: .desktopCode, path: .publicHistory), readerVersion: "0.162.1")
        let router = try CodexEnrolledSessionRouter(native: adapter, hooks: sink,
            nativeRoute: route, nativeAuthority: .publicNativeItems, authorityLookup: { await authority.lookup($0) })
        let context = try await router.context(for: packet, trigger: .helperDelivery,
            recordAuthority: { try await authority.record($0) })
        #expect(context.scope.path == .publicHistory)
        await #expect(throws: CodexHistoryError.unavailable) {
            try await router.normalize(packet, capturedAt: Date(), context: context,
                cryptography: BackgroundCryptography.ephemeralForTesting())
        }
        #expect(await sink.hookCalls == 0)
        let session = try SessionIdentity(provider: .codex, profileID: "test", sessionID: "native-main")
        #expect(await authority.lookup(session)?.authorityID == CodexCollectionAuthority.publicNativeItems.rawValue)
        #expect(throws: CodexCollectionError.invalidConfiguration) {
            try CodexActiveSource(threadID: "native-main", interface: .desktopCode,
                authority: .nativeRolloutTranscript, transcriptURL: URL(fileURLWithPath: "/tmp/fake-desktop.jsonl"))
        }
        #expect(throws: CodexCollectionError.invalidConfiguration) {
            try codexTestAdapter(interface: .desktopCode, selectedAuthority: .nativeRolloutTranscript)
        }
        await monitor.stop()
    }

    @Test func healthNotificationsDoNotTreatCodexConfiguredInterfaceAsObservedHost() {
        for provider in AgentProvider.allCases {
            let notification = MaskedNotification.health(.init(id: UUID(),
                scope: .init(provider: provider, profileID: "fake-notification-profile", interface: .t3, path: .publicHistory),
                contentType: .toolOutput, operation: .liveRead, reason: .sourceUnavailable,
                firstObservedAt: Date(), resolvedAt: nil, delivery: .pending))
            if provider == .codex {
                #expect(notification.body.contains("Codex · Shared profile"))
                #expect(!notification.body.contains("T3"))
            } else {
                #expect(notification.body.contains("T3"))
            }
        }
    }

    @Test func independentAppOwnedTasksNeedNoT3TaskOrThreadMapping() async throws {
        let history = CodexTestHistory(), authority = CodexTestAuthority()
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try codexTestAdapter(authority: authority, history: history,
            interface: .t3, version: "0.162.1", t3Version: "synthetic-host")
        let now = Date(timeIntervalSince1970: 1_791_434_500)
        let items = try [
            codexItem("prompt", type: "userMessage", body: [
                "content": [["type": "inputText", "text": "fake task prompt"]]]),
            codexItem("intermediate", body: ["text": "fake progress", "phase": "commentary"]),
            codexItem("final", body: ["text": "fake final", "phase": "final_answer"]),
            codexItem("output", type: "commandExecution", body: [
                "status": "completed", "exitCode": 0, "aggregatedOutput": "fake output"]),
            codexItem("error", type: "commandExecution", body: [
                "status": "completed", "exitCode": 7, "aggregatedOutput": "fake error"])
        ]
        var collected: [CollectedSource] = []
        for nativeID in ["native-task-one", "native-task-two"] {
            // The exact provider ID arrives through its normal hook. No T3 task,
            // application thread ID, project/title lookup, or text match is given.
            await history.configure(nativeID, thread: try codexThread(nativeID, producer: "0.162.1"),
                pages: [.init(data: items)])
            let packet = try codexPacket(thread: nativeID, event: "UserPromptSubmit")
            let batch = try await adapter.normalize(packet, capturedAt: now, cryptography: crypto)
            #expect(batch.coverageGaps.isEmpty)
            #expect(batch.continuation == nil)
            #expect(Set(batch.sources.map(\.record.metadata.contentType)) == Set(ContentType.allCases))
            #expect(batch.sources.allSatisfy {
                $0.record.metadata.identity.session.sessionID == nativeID &&
                $0.record.metadata.origin.interface == .t3
            })
            let replay = try await adapter.normalize(packet, capturedAt: now, cryptography: crypto)
            #expect(replay.sources.map(\.record.metadata.identity) == batch.sources.map(\.record.metadata.identity))
            #expect(replay.sources.map(\.record.revision) == batch.sources.map(\.record.revision))
            collected += batch.sources
        }
        // Identical item IDs and content in independent tasks remain independent
        // native appearances, while a replay preserves each original identity.
        #expect(collected.count == 10)
        #expect(Set(collected.map(\.record.metadata.identity)).count == 10)
        let calls = await history.recordedCalls()
        #expect(!calls.contains { $0.hasPrefix("list:") })
        #expect(Set(calls.filter { $0.hasPrefix("read:") }) == ["read:native-task-one", "read:native-task-two"])
    }

    @Test func nativeChildrenAreFollowedOnlyByProviderLinksAndKeepTheirOwnContent() async throws {
        let history = CodexTestHistory(), crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try codexTestAdapter(history: history, interface: .t3,
            version: "0.162.1", t3Version: "synthetic-host")
        let now = Date(timeIntervalSince1970: 1_791_434_500)
        await history.configure("native-task", thread: try codexThread("native-task"), pages: [.init(data: [
            try codexItem("spawn", type: "collabAgentToolCall", body: [
                "tool": "spawnAgent", "status": "completed", "senderThreadId": "native-task",
                "receiverThreadIds": ["native-grandchild"], "prompt": "parent task arguments"]),
            try codexItem("parent-final", body: ["text": "parent final", "phase": "final_answer"])
        ])])
        await history.configure("native-grandchild", thread: try codexThread("native-grandchild"), pages: [.init(data: [
            try codexItem("child-final", body: ["text": "child original final", "phase": "final_answer"])
        ])])
        let parent = try await adapter.normalize(codexPacket(thread: "native-task", event: "Stop"),
            capturedAt: now, cryptography: crypto)
        let child = try await adapter.normalize(#require(parent.continuation), capturedAt: now, cryptography: crypto)
        #expect(parent.coverageGaps.isEmpty)
        #expect(child.coverageGaps.count == 1 && child.coverageGaps.first?.diagnosticCode == .nativeChildInputUnavailable)
        #expect(parent.sources.map(\.record.metadata.identity.itemID) == ["parent-final"])
        #expect(child.sources.map(\.record.metadata.identity.itemID) == ["child-final"])
        #expect(child.sources.first?.record.metadata.identity.session.sessionID == "native-grandchild")
        #expect(child.continuation == nil)
        #expect((parent.sources + child.sources).allSatisfy { $0.record.metadata.contentType != .userPrompt })
        // A parent's spawn arguments are not promoted to a child's input merely
        // because both are visible in T3's presentation of a delegated task.
        #expect(!(parent.sources + child.sources).contains { codexText($0).contains("parent task arguments") })
        #expect(!(await history.recordedCalls()).contains { $0.hasPrefix("list:") })
    }
}
