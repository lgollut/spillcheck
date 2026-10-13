import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private struct DisposableCodexFixtureDetector: SecretDetector {
    func scan(_ source: SourceRecord) async throws -> DetectorOutput {
        let segment = try #require(source.segments.first)
        let extraction = try ExactExtraction(valueUTF8: segment.utf8,
            location: CanonicalLocation(segmentID: segment.id, range: UTF8Range(0, segment.utf8.count)), in: source)
        return .init(detectorVersion: "owned-history-fixture", findings: [try .init(extraction: extraction,
            evidence: [.init(rule: .init(id: "fake-token", version: "1"), signal: .strong, reason: .localRule, category: .token)])],
            unlocated: [])
    }
}

@Suite("Codex disposable exact historical admission")
struct CodexDisposableHistoryAdmissionTests {
    private let native = "00000000-0000-4000-8000-000000000123"

    private func initial(_ now: Date) async throws -> (CodexAdapter, CapturePacket, HistoricalAuditContext) {
        let adapter = try codexTestAdapter()
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let session = try SessionIdentity(provider: .codex, profileID: "test", sessionID: native)
        let packet = try await adapter.initialHistoricalCapture(audit: audit,
            source: .init(scope: adapter.collectionScope, session: session))
        return (adapter, packet, audit)
    }

    @Test func acceptsRealInitialProducerAndRunnerShapeButNeverBindsOrdinaryHooks() async throws {
        let (adapter, packet, audit) = try await initial(Date(timeIntervalSinceReferenceDate: 800_000_000))
        #expect(try CodexAdapter.historicalAuditForTesting(in: packet) == audit)
        let runner: [String: Any] = ["kind": "leakret-codex-history-v1",
            "audit": ["id": audit.id.uuidString.lowercased(), "reason": "restart", "start": 799_395_200, "end": 800_000_000],
            "threads": [native], "discovering": false, "selectedSourceOnly": true, "children": [], "visited": [], "archived": false]
        let exact = try CapturePacket(metadata: packet.metadata, eventJSON: JSONSerialization.data(withJSONObject: runner))
        #expect(try CodexAdapter.historicalAuditForTesting(in: exact) == audit)
        #expect(try CodexAdapter.historicalAuditForTesting(in: codexPacket(thread: native)) == nil)
        let other = try CapturePacket(metadata: .init(agent: .claudeCode, profileID: "test"), eventJSON: packet.eventJSON)
        #expect(try CodexAdapter.historicalAuditForTesting(in: other) == nil)
        let discovery = try await adapter.initialHistoricalCapture(audit: audit)
        #expect(throws: CodexCollectionError.invalidConfiguration) { try CodexAdapter.historicalAuditForTesting(in: discovery) }
    }

    @Test func rejectsDiscoveryContinuationsAlternateIdentityAndUnknownState() async throws {
        let (_, packet, _) = try await initial(.now)
        let object = try #require(JSONSerialization.jsonObject(with: packet.eventJSON) as? [String: Any])
        let invalid: [(String, Any)] = [
            ("threads", []), ("threads", [native, UUID().uuidString.lowercased()]),
            ("threads", ["not-a-native-uuid"]), ("threads", ["AAAAAAAA-0000-4000-8000-000000000123"]),
            ("discovering", true), ("selectedSourceOnly", false), ("archived", true),
            ("children", [native]), ("visited", [native]), ("nativeChildParents", [native: UUID().uuidString]),
            ("hasReplayCursor", true), ("partial", true), ("threadPartial", true),
            ("threadReadBeganAtStart", true), ("threadHasInWindowItems", true), ("liveBootstrapped", true),
            ("consecutiveBudgetFailures", 1), ("itemCursor", "cursor"), ("threadListCursor", "cursor"),
            ("replayCursor", "cursor"), ("transcriptPath", "/tmp/fake-only"), ("pageLimit", 1),
            ("threadUpdatedAt", 1), ("threadListedAt", 1), ("threadNativeChildParentID", native),
            ("emptyPageIsCurrent", true), ("futureState", false), ("itemCursor", NSNull())]
        for (key, value) in invalid {
            var changed = object; changed[key] = value
            let malformed = try CapturePacket(metadata: packet.metadata, eventJSON: JSONSerialization.data(withJSONObject: changed))
            #expect(throws: CodexCollectionError.invalidConfiguration) { try CodexAdapter.historicalAuditForTesting(in: malformed) }
        }
    }

    @Test func rejectsMalformedMissingAndInexactAudit() async throws {
        let (_, packet, _) = try await initial(.now)
        let object = try #require(JSONSerialization.jsonObject(with: packet.eventJSON) as? [String: Any])
        for replacement: Any in [NSNull(), ["id": "invalid"], ["id": UUID().uuidString, "reason": "resume", "start": 0, "end": 1],
            ["id": UUID().uuidString, "reason": "resume", "start": 1e100, "end": 1e100]] {
            var changed = object; changed["audit"] = replacement
            let malformed = try CapturePacket(metadata: packet.metadata, eventJSON: JSONSerialization.data(withJSONObject: changed))
            #expect(throws: CodexCollectionError.invalidConfiguration) { try CodexAdapter.historicalAuditForTesting(in: malformed) }
        }
        let malformed = try CapturePacket(metadata: packet.metadata, eventJSON: Data("{\"kind\":\"leakret-codex-history-v1\"}".utf8))
        #expect(throws: CodexCollectionError.invalidConfiguration) { try CodexAdapter.historicalAuditForTesting(in: malformed) }
    }

    @Test func boundOriginalAuditEarnsHistoricalDecisionWhileUnboundCompletionDoesNot() async throws {
        for bind in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-codex-admission-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let now = Date(), sourceTime = now.addingTimeInterval(-3600)
            let crypto = try BackgroundCryptography.ephemeralForTesting()
            let store = try await ProtectedStore.open(at: root, cryptography: crypto)
            let history = CodexTestHistory()
            try await history.configure(native, thread: codexThread(native, updatedAt: sourceTime.timeIntervalSince1970),
                pages: [.init(data: [codexItem("owned-fake-item", timestamp: sourceTime.timeIntervalSince1970 * 1000,
                    body: ["text": "fake-only-token", "phase": "final_answer"])], bytesRead: 100)])
            let adapter = try codexTestAdapter(history: history)
            let audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
            let session = try SessionIdentity(provider: .codex, profileID: "test", sessionID: native)
            let packet = try await adapter.initialHistoricalCapture(audit: audit,
                source: .init(scope: adapter.collectionScope, session: session))
            let permit = try #require(await store.processingPermit())
            let admitted = bind ? try CodexAdapter.historicalAuditForTesting(in: packet) : nil
            _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, historicalAudit: admitted)
            let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: adapter,
                detector: DisposableCodexFixtureDetector(), detectorVersion: "owned-history-fixture", liveSince: now)
            _ = try await pipeline.processNext(at: now)
            let decisions = try await store.pendingHistoricalNotifications()
            let snapshot = await store.snapshot(), progress = try await store.historicalProgress()
            #expect(snapshot.occurrences.count == 1 && snapshot.alertDecisions.isEmpty)
            if bind {
                #expect(try await store.queueStatistics().count == 0)
                #expect(progress.count == 1 && progress[0].progress.audit == audit && progress[0].completedAt != nil)
                #expect(decisions.count == 1 && decisions[0].audit == audit && decisions[0].delivery == .pending)
                #expect(snapshot.historicalNotificationDecisions.count == 1)
            } else {
                #expect(try await store.queueStatistics().count == 1)
                #expect(progress.isEmpty && decisions.isEmpty && snapshot.historicalNotificationDecisions.isEmpty)
            }
            try await store.close()
        }
    }
}
