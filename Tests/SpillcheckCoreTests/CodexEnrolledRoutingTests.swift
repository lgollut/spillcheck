import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor EnrolledRouteSpy: CaptureNormalizer {
    private(set) var calls = 0
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) -> CollectionBatch {
        calls += 1
        return .init(sources: [], observedRead: true)
    }
}

private actor EnrolledPacketSpy {
    private(set) var packets: [CapturePacket] = []
    private(set) var gaps: [CoverageGap] = []
    func append(_ packet: CapturePacket) { packets.append(packet) }
    func gap(_ gap: CoverageGap) { gaps.append(gap) }
}

private actor EnrolledCapacityGate {
    var blocked = true
    func setBlocked(_ value: Bool) { blocked = value }
}

private struct EnrolledRouteDetector: SecretDetector {
    func scan(_ source: SourceRecord) -> DetectorOutput {
        .init(detectorVersion: "enrolled-routing-test", findings: [], unlocated: [])
    }
}

private func enrolledSession(_ id: String) throws -> SessionIdentity {
    try .init(provider: .codex, profileID: "test", sessionID: id)
}

private func enrolledChoice(_ id: String, authority: String = CodexHookContentAdapter.authorityID) throws -> CollectionAuthorityChoice {
    try .init(session: enrolledSession(id), adapterVersion: "1", authorityID: authority)
}

private func enrolledPacket(_ id: String = "side", event: String = "UserPromptSubmit") throws -> CapturePacket {
    try .init(metadata: .init(agent: .codex, interface: .t3, profileID: "test"),
        eventJSON: JSONSerialization.data(withJSONObject: ["hook_event_name": event, "session_id": id,
            "turn_id": "turn", "prompt": "fake route test text"]))
}

private var enrolledNativeRoute: CollectionCaptureRoute {
    .init(scope: .init(provider: .codex, profileID: "test", interface: .t3, path: .publicHistory),
        readerVersion: "0.162.1", hostVersion: "synthetic-host")
}

private func enrolledRouter(native: EnrolledRouteSpy = .init(), hooks: EnrolledRouteSpy = .init(),
                            lookup: @escaping SourceAuthorityLookup) throws -> CodexEnrolledSessionRouter {
    try .init(native: native, hooks: hooks, nativeRoute: enrolledNativeRoute,
        nativeAuthority: .publicNativeItems, authorityLookup: lookup)
}

@Suite("Codex exact enrolled-session admission and routing")
struct CodexEnrolledRoutingTests {
    @Test func knownHooksAndUnknownNativeSessionsKeepDistinctDurableEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-enrolled-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let permit = try #require(await store.processingPermit()), now = Date()
        try await store.selectAuthority(enrolledChoice("side"), permit: permit)
        let native = EnrolledRouteSpy(), hooks = EnrolledRouteSpy()
        let router = try enrolledRouter(native: native, hooks: hooks, lookup: { try await store.authority(for: $0) })
        for id in ["side", "main"] {
            let packet = try enrolledPacket(id)
            let context = try await router.context(for: packet, trigger: .helperDelivery,
                recordAuthority: { try await store.selectAuthority($0, permit: permit) })
            #expect(context.scope.path == (id == "side" ? .hook : .publicHistory))
            #expect((context.retry == nil) == (id == "side"))
            _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, workContext: context)
        }
        #expect(try await store.authority(for: enrolledSession("main"))?.authorityID == CodexCollectionAuthority.publicNativeItems.rawValue)
        let collection = try CollectionRouter(routes: [.init(provider: .codex, profileID: "test", interface: .t3, normalizer: router)])
        let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: collection,
            detector: EnrolledRouteDetector(), detectorVersion: "enrolled-routing-test")
        #expect(try await pipeline.processNext(at: now) == .processed)
        #expect(try await pipeline.processNext(at: now) == .processed)
        #expect(await hooks.calls == 1)
        #expect(await native.calls == 1)
        let report = try await store.coverageReport(endingAt: now)
        #expect(Set(report.successfulReads.items.map(\.scope.path)) == [.hook, .publicHistory])
        #expect(report.successfulReads.totalCount == 2)
        try await store.close()
    }

    @Test func sessionStartFreezesNativeAndLaterEnrollmentCannotSwitchIt() async throws {
        let authorities = CodexTestAuthority(), native = EnrolledRouteSpy(), hooks = EnrolledRouteSpy()
        let router = try enrolledRouter(native: native, hooks: hooks, lookup: { await authorities.lookup($0) })
        let packet = try enrolledPacket("fresh", event: "SessionStart")
        let context = try await router.context(for: packet, trigger: .helperDelivery,
            recordAuthority: { try await authorities.record($0) })
        #expect(context.scope.path == .publicHistory)
        await #expect(throws: CodexCollectionError.authorityConflict) {
            try await authorities.record(enrolledChoice("fresh"))
        }
        _ = try await router.normalize(packet, capturedAt: Date(), context: context,
            cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(await native.calls == 1)
        #expect(await hooks.calls == 0)
    }

    @Test func oldNativeQueueContextCannotTurnIntoHookEvidenceAfterEnrollment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-enrolled-old-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let permit = try #require(await store.processingPermit()), now = Date(), packet = try enrolledPacket()
        _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now,
            workContext: enrolledNativeRoute.context(for: packet, trigger: .helperDelivery))
        try await store.selectAuthority(enrolledChoice("side"), permit: permit)
        let native = EnrolledRouteSpy(), hooks = EnrolledRouteSpy()
        let router = try enrolledRouter(native: native, hooks: hooks, lookup: { try await store.authority(for: $0) })
        let pipeline = DetectionPipeline(store: store, cryptography: crypto,
            normalizer: try CollectionRouter(routes: [.init(provider: .codex, profileID: "test", interface: .t3, normalizer: router)]),
            detector: EnrolledRouteDetector(), detectorVersion: "enrolled-routing-test")
        #expect(try await pipeline.processNext(at: now) == .retryScheduled)
        #expect(await native.calls == 0)
        #expect(await hooks.calls == 0)
        #expect(try await store.coverageReport(endingAt: now).successfulReads.totalCount == 0)
        await #expect(throws: CodexCollectionError.authorityConflict) {
            try await router.normalize(packet, capturedAt: now, cryptography: crypto)
        }
        try await store.close()
    }

    @Test func concurrentSelectorUsesOnlyTheCommittedAllowedWinner() async throws {
        let authorities = CodexTestAuthority()
        let router = try enrolledRouter(lookup: { await authorities.lookup($0) })
        let context = try await router.context(for: enrolledPacket(), trigger: .helperDelivery,
            recordAuthority: { _ in
                try await authorities.record(enrolledChoice("side"))
                throw StorageError.invalidPayload
            })
        #expect(context.scope.path == .hook && context.retry == nil)
        let other = CodexTestAuthority()
        let invalid = try enrolledRouter(lookup: { await other.lookup($0) })
        await #expect(throws: CodexCollectionError.authorityConflict) {
            try await invalid.context(for: enrolledPacket(), trigger: .helperDelivery, recordAuthority: { _ in
                try await other.record(enrolledChoice("side", authority: "unknown-future-authority"))
                throw StorageError.invalidPayload
            })
        }
    }

    @Test func pauseRejectsTheAdmissionPermitBeforeAuthorityOrQueueMutation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-enrolled-pause-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
        let permit = try #require(await store.processingPermit())
        let router = try enrolledRouter(lookup: { try await store.authority(for: $0) })
        await store.setMonitoring(enabled: false)
        await #expect(throws: StorageError.monitoringPaused) {
            try await router.context(for: enrolledPacket(), trigger: .helperDelivery,
                recordAuthority: { try await store.selectAuthority($0, permit: permit) })
        }
        #expect(try await store.authority(for: enrolledSession("side")) == nil)
        #expect(try await store.queueStatistics().count == 0)
        try await store.close()
    }

    @Test func malformedAndUnrecognizedPacketsCannotSelectAuthority() async throws {
        let authorities = CodexTestAuthority()
        let router = try enrolledRouter(lookup: { await authorities.lookup($0) })
        for packet in [try enrolledPacket("bad\0id"), try enrolledPacket("side", event: "invented-event")] {
            let context = try await router.context(for: packet, trigger: .helperDelivery,
                recordAuthority: { _ in Issue.record("Unexpected authority mutation") })
            #expect(context.scope.path == .publicHistory)
        }
        #expect(try await authorities.lookup(enrolledSession("side")) == nil)
    }

    @Test func authorityCapacityFailureBeforeAdmissionDoesNotQueueOrChangeRouting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-enrolled-capacity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting(),
            limits: .init(maxSourceAuthorities: 1))
        let permit = try #require(await store.processingPermit())
        try await store.selectAuthority(enrolledChoice("already-enrolled"), permit: permit)
        let router = try enrolledRouter(lookup: { try await store.authority(for: $0) })
        await #expect(throws: StorageError.capacityExceeded(.sourceAuthorities)) {
            try await router.context(for: enrolledPacket(), trigger: .helperDelivery,
                recordAuthority: { try await store.selectAuthority($0, permit: permit) })
        }
        #expect(try await store.queueStatistics().count == 0)
        #expect(try await store.authority(for: enrolledSession("side")) == nil)
        #expect(try await store.capacitySnapshot().sourceAuthorities.count == 1)
        try await store.close()
    }

    @Test(arguments: [false, true])
    func pollingCapacityFailureIsSpecificAndDoesNotBlockUnrelatedSessions(transcript: Bool) async throws {
        let captured = EnrolledPacketSpy(), gate = EnrolledCapacityGate()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-capacity-poll-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        if transcript { try Data("fake".utf8).write(to: path) }
        let now = Date()
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: [
            .init(threadID: "full", interface: .t3, authority: transcript ? .nativeRolloutTranscript : .publicNativeItems,
                transcriptURL: transcript ? path : nil),
            .init(threadID: "existing", interface: .t3, authority: .publicNativeItems)],
            enqueue: { packet, _ in
                let event = try JSONDecoder().decode(CodexJSON.self, from: packet.eventJSON)
                if event["session_id"].string == "full", await gate.blocked {
                    throw StorageError.capacityExceeded(.sourceAuthorities)
                }
                await captured.append(packet)
            }, onGap: { await captured.gap($0) })
        #expect(try await monitor.pollOnce(at: now.addingTimeInterval(1)) == 1)
        let gaps = await captured.gaps
        #expect(gaps.count == 1 && gaps.first?.diagnosticCode == .authorityStorageLimit)
        #expect(gaps.first?.reason == .budgetExhausted && gaps.first?.operation == .liveRead)
        #expect(gaps.first?.recovery?.session?.sessionID == "full")
        #expect(await captured.packets.count == 1)
        #expect(try await monitor.pollOnce(at: now.addingTimeInterval(3)) == 1)
        #expect(await captured.gaps.count == 1)
        await gate.setBlocked(false)
        #expect(try await monitor.pollOnce(at: now.addingTimeInterval(5)) == 2)
        await gate.setBlocked(true)
        if transcript { try Data("fake changed".utf8).write(to: path) }
        #expect(try await monitor.pollOnce(at: now.addingTimeInterval(7)) == 1)
        #expect(await captured.gaps.count == 2)
    }

    @Test func nativeHistoryCapacityGapRemainsDistinctAndContinuesTheNextSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-history-capacity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let authorities = CodexTestAuthority(), history = CodexTestHistory()
        try await authorities.record(enrolledChoice("existing", authority: CodexCollectionAuthority.publicNativeItems.rawValue))
        for id in ["new", "existing"] {
            try await history.configure(id, thread: codexThread(id), pages: [.init(data: [codexItem()])])
        }
        let adapter = try CodexAdapter(profileID: "test", agentVersion: "0.162.1", interface: .t3,
            history: history, authorityLookup: { await authorities.lookup($0) },
            authorityRecorder: { _ in throw StorageError.capacityExceeded(.sourceAuthorities) })
        let crypto = try BackgroundCryptography.ephemeralForTesting(), now = Date()
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let first = try await adapter.normalize(adapter.packet(.init(audit: audit, threads: ["new", "existing"])),
            capturedAt: now, cryptography: crypto)
        #expect(first.sources.isEmpty)
        #expect(first.coverageGaps.first?.diagnosticCode == .authorityStorageLimit)
        #expect(first.coverageGaps.first?.reason == .budgetExhausted)
        #expect(!first.readEvidenceEligible)
        #expect(first.historicalProgress?.hasUnreadContent == true)
        let next = try await adapter.normalize(#require(first.continuation), capturedAt: now, cryptography: crypto)
        #expect(next.sources.first?.record.metadata.identity.session.sessionID == "existing")
        #expect(next.historicalProgress?.hasUnreadContent == true)
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let permit = try #require(await store.processingPermit())
        let packet = try adapter.packet(.init(audit: audit, threads: ["new", "existing"]))
        _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, historicalAudit: audit,
            workContext: enrolledNativeRoute.context(for: packet, trigger: .historyRequest, audit: audit))
        let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
            detector: EnrolledRouteDetector(), detectorVersion: "enrolled-routing-test")
        #expect(try await pipeline.processNext(at: now) == .processed)
        #expect(try await store.queueStatistics().count == 1)
        #expect(try await store.coverageReport(endingAt: now).successfulReads.totalCount == 0)
        #expect(try await pipeline.processNext(at: now) == .processed)
        #expect(try await store.queueStatistics().count == 0)
        #expect(try await store.coverageReport(endingAt: now).successfulReads.totalCount == 1)
        try await store.close()
    }

    @Test func monitorSkipsOnlyHookOwnedSessionsAndQuietlyDropsAStaleHookPoll() async throws {
        let authorities = CodexTestAuthority(), captured = EnrolledPacketSpy()
        try await authorities.record(enrolledChoice("side"))
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: [
            .init(threadID: "side", interface: .t3, authority: .publicNativeItems),
            .init(threadID: "main", interface: .t3, authority: .publicNativeItems)],
            enqueue: { packet, _ in await captured.append(packet) },
            authorityLookup: { await authorities.lookup($0) }, onGap: { await captured.gap($0) })
        #expect(try await monitor.pollOnce(at: Date().addingTimeInterval(1)) == 1)
        let packets = await captured.packets
        #expect(packets.count == 1)
        #expect(try JSONDecoder().decode(CodexJSON.self, from: #require(packets.first).eventJSON)["session_id"].string == "main")
        let stale = try CodexActiveHistoryMonitor(profileID: "test", sources: [
            .init(threadID: "side", interface: .t3, authority: .publicNativeItems)],
            enqueue: { _, _ in throw CodexEnrolledRoutingError.hookOwnedPoll }, onGap: { await captured.gap($0) })
        #expect(try await stale.pollOnce(at: Date().addingTimeInterval(1)) == 0)
        #expect(await captured.gaps.isEmpty)
    }

    @Test(arguments: [false, true])
    func failingSourceIsReportedAndDoesNotStarveLaterSources(inLookup: Bool) async throws {
        let captured = EnrolledPacketSpy(), now = Date()
        let monitor = try CodexActiveHistoryMonitor(profileID: "test", sources: [
            .init(threadID: "broken", interface: .t3, authority: .publicNativeItems),
            .init(threadID: "later", interface: .t3, authority: .publicNativeItems)],
            enqueue: { packet, _ in
                if !inLookup, try JSONDecoder().decode(CodexJSON.self, from: packet.eventJSON)["session_id"].string == "broken" {
                    throw StorageError.databaseUnavailable
                }
                await captured.append(packet)
            },
            authorityLookup: { session in
                if inLookup, session.sessionID == "broken" { throw StorageError.databaseUnavailable }
                return nil
            }, onGap: { await captured.gap($0) })
        for step in [1.0, 3.0] {
            await #expect(throws: StorageError.databaseUnavailable) { try await monitor.pollOnce(at: now.addingTimeInterval(step)) }
        }
        let gaps = await captured.gaps
        #expect(gaps.count == 2 && gaps.allSatisfy {
            $0.reason == .deliveryUncertain && $0.recovery?.session?.sessionID == "broken" })
        let polled = try await captured.packets.map {
            try JSONDecoder().decode(CodexJSON.self, from: $0.eventJSON)["session_id"].string }
        #expect(polled == ["later", "later"])
    }

    @Test func nativeAuditSkipsExactHookOwnerAndContinuesUnrelatedNativeSources() async throws {
        let authorities = CodexTestAuthority(), history = CodexTestHistory()
        try await authorities.record(enrolledChoice("side"))
        try await history.configure("main", thread: codexThread("main"), pages: [.init(data: [codexItem()])])
        let adapter = try codexTestAdapter(authority: authorities, history: history)
        let now = Date(timeIntervalSince1970: 1_791_434_500), crypto = try BackgroundCryptography.ephemeralForTesting()
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let first = try await adapter.normalize(adapter.packet(.init(audit: audit, threads: ["side", "main"])),
            capturedAt: now, cryptography: crypto)
        #expect(first.sources.isEmpty && first.coverageGaps.isEmpty)
        #expect(await history.recordedCalls().isEmpty)
        let next = try await adapter.normalize(#require(first.continuation), capturedAt: now, cryptography: crypto)
        #expect(next.sources.count == 1 && next.sources.first?.record.metadata.identity.session.sessionID == "main")
        #expect(next.historicalProgress?.hasUnreadContent == false && next.continuation == nil)
        #expect(!(await history.recordedCalls()).contains("read:side"))
        var selected = CodexHistoryRequest(audit: audit, threads: ["side"])
        selected.selectedSourceOnly = true
        let blocked = try await adapter.normalize(adapter.packet(selected), capturedAt: now, cryptography: crypto)
        #expect(blocked.sources.isEmpty && blocked.coverageGaps.contains { $0.scope?.path == .hook && $0.requiresAnalysis })
        #expect(blocked.historicalProgress?.hasUnreadContent == true && blocked.recoveredReferences.isEmpty)
        #expect(!(await history.recordedCalls()).contains("read:side"))
    }

    @Test(arguments: [false, true])
    func aSkipOnlyAuditSettlesItsCursorWithoutCreatingNativeReadEvidence(discovering: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-enrolled-skip-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let permit = try #require(await store.processingPermit()), now = Date()
        try await store.selectAuthority(enrolledChoice("side"), permit: permit)
        let history = CodexTestHistory()
        try await history.configureListings([.init(data: [
            codexThread("side", updatedAt: now.timeIntervalSince1970),
            codexThread("main", updatedAt: now.timeIntervalSince1970)], bytesRead: 128)], archived: false)
        try await history.configure("main", thread: codexThread("main", updatedAt: now.timeIntervalSince1970),
            pages: [.init(data: [codexItem(timestamp: now.addingTimeInterval(-1).timeIntervalSince1970 * 1000)], bytesRead: 128)])
        let adapter = try CodexAdapter(profileID: "test", agentVersion: "0.162.1", interface: .t3,
            history: history, authorityLookup: { try await store.authority(for: $0) },
            authorityRecorder: { try await store.selectAuthority($0, permit: permit) })
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let packet = try adapter.packet(.init(audit: audit, threads: discovering ? [] : ["side"]))
        _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, historicalAudit: audit,
            workContext: enrolledNativeRoute.context(for: packet, trigger: .historyRequest, audit: audit))
        let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
            detector: EnrolledRouteDetector(), detectorVersion: "enrolled-routing-test")
        #expect(try await pipeline.processNext(at: now) == .processed)
        #expect(try await store.queueStatistics().count == (discovering ? 1 : 0))
        #expect(try await store.coverageReport(endingAt: now).successfulReads.totalCount == 0)
        #expect(await history.recordedCalls() == (discovering ? ["list:false"] : []))
        if discovering {
            #expect(try await pipeline.processNext(at: now) == .processed)
            let read = try #require(try await store.coverageReport(endingAt: now).successfulReads.items.first)
            #expect(read.scope.path == .publicHistory && read.operation == .historicalRead)
            #expect(!(await history.recordedCalls()).contains("read:side"))
            #expect((await history.recordedCalls()).contains("read:main"))
        }
        try await store.close()
    }

    @Test func rolloutRetryRejectsHookOwnershipBeforeOpeningItsSelectedPath() async throws {
        let authorities = CodexTestAuthority()
        try await authorities.record(enrolledChoice("side"))
        let adapter = try codexTestAdapter(authority: authorities, selectedAuthority: .nativeRolloutTranscript,
            roots: [FileManager.default.temporaryDirectory])
        let now = Date(), audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        var request = CodexHistoryRequest(audit: audit, threads: ["side"])
        request.selectedSourceOnly = true
        request.transcriptPath = "/outside-authorized-root/nonexistent.jsonl"
        let result = try await adapter.normalize(adapter.packet(request), capturedAt: now,
            cryptography: BackgroundCryptography.ephemeralForTesting())
        #expect(result.sources.isEmpty && result.readEvidenceEligible == false)
        #expect(result.coverageGaps.count == 1)
        #expect(result.coverageGaps.first?.diagnosticCode == .hookContentUnavailable)
        #expect(result.coverageGaps.first?.reason == .unsupportedContent)
        #expect(result.historicalProgress?.bytesRead == 0 && result.historicalProgress?.hasUnreadContent == true)
    }

    @Test func authorityCountLimitIsAtomicAndExistingChoicesReplayBeyondALoweredCap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-authority-count-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto,
            limits: .init(maxSourceAuthorities: 2))
        let permit = try #require(await store.processingPermit())
        let results = await withTaskGroup(of: (String, Bool).self) { tasks in
            for index in 0..<12 {
                tasks.addTask {
                    let session = "bounded-\(index)"
                    do {
                        try await store.selectAuthority(enrolledChoice(session), permit: permit)
                        return (session, true)
                    } catch {
                        #expect((error as? StorageError) == .capacityExceeded(.sourceAuthorities))
                        return (session, false)
                    }
                }
            }
            var results: [(String, Bool)] = []
            for await result in tasks { results.append(result) }
            return results
        }
        let admitted = results.filter(\.1).map(\.0)
        #expect(admitted.count == 2)
        try await store.close()
        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto,
            limits: .init(maxSourceAuthorities: 1))
        let nextPermit = try #require(await reopened.processingPermit())
        for session in admitted {
            #expect(try await reopened.authority(for: enrolledSession(session))?.authorityID == CodexHookContentAdapter.authorityID)
            try await reopened.selectAuthority(enrolledChoice(session), permit: nextPermit)
        }
        await #expect(throws: StorageError.capacityExceeded(.sourceAuthorities)) {
            try await reopened.selectAuthority(enrolledChoice("new-after-lowered-limit"), permit: nextPermit)
        }
        await #expect(throws: StorageError.invalidPayload) {
            try await reopened.selectAuthority(enrolledChoice(#require(admitted.first),
                authority: CodexCollectionAuthority.publicNativeItems.rawValue), permit: nextPermit)
        }
        try await reopened.close()
    }

    @Test func authorityByteLimitRollsBackOnlyTheNewChoiceAndKeepsExistingReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-authority-bytes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting(),
            limits: .init(maxProtectedStateBytes: 8 * 1024))
        let permit = try #require(await store.processingPermit())
        let first = String(repeating: "a", count: 3000), second = String(repeating: "b", count: 3000)
        try await store.selectAuthority(enrolledChoice(first), permit: permit)
        await #expect(throws: StorageError.capacityExceeded(.sourceAuthorities)) {
            try await store.selectAuthority(enrolledChoice(second), permit: permit)
        }
        #expect(try await store.authority(for: enrolledSession(second)) == nil)
        try await store.selectAuthority(enrolledChoice(first), permit: permit)
        try await store.close()
    }
}
