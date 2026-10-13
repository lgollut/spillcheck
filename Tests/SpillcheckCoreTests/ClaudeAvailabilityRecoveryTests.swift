import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor ClaudeAvailabilityReadGate: BackgroundStoreCryptography {
    nonisolated let manifest: ProtectionManifest
    private let delegate: BackgroundCryptography
    private var armed = false
    private var gate: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ delegate: BackgroundCryptography) { self.delegate = delegate; manifest = delegate.manifest }
    func arm() { armed = true }
    func blocked() async {
        if gate != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { gate?.resume(); gate = nil }
    func sealBackground(_ plaintext: Data, binding: PayloadBinding) async throws -> ProtectedPayload {
        try await delegate.sealBackground(plaintext, binding: binding)
    }
    func openBackground(_ payload: ProtectedPayload, binding: PayloadBinding) async throws -> Data {
        let plaintext = try await delegate.openBackground(payload, binding: binding)
        if armed, let omission = try? JSONDecoder().decode(CoverageOmission.self, from: plaintext),
           omission.gap.reason == .sourceUnavailable {
            armed = false
            await withCheckedContinuation { continuation in
                gate = continuation; waiters.forEach { $0.resume() }; waiters.removeAll()
            }
        }
        return plaintext
    }
    func revision(canonicalBytes: Data) async throws -> ContentRevision {
        try await delegate.revision(canonicalBytes: canonicalBytes)
    }
}

@Suite("Constrained Claude source availability", .timeLimit(.minutes(1)))
struct ClaudeAvailabilityRecoveryTests {
    private let now = Date(timeIntervalSince1970: 1_791_750_000)
    private let source = URL(fileURLWithPath: "/owned-fake/parent.jsonl")
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-claude-availability-\(UUID())")
    }
    private func scope(_ interface: AgentInterface = .t3, profile: String = "availability-fixture",
                       path: CollectionPath = .versionedTranscript) -> CollectionScope {
        .init(provider: .claudeCode, profileID: profile, interface: interface, path: path)
    }
    private func reference(proof: Bool = false, session: String? = "parent", url: URL? = nil,
                           observed: Date? = nil) throws -> CoverageRecoveryReference {
        .init(session: try session.map { try SessionIdentity(provider: .claudeCode,
                profileID: "availability-fixture", sessionID: $0) },
            parserContract: ClaudeAdapter.parserContractVersion, sourceURL: url ?? source,
            constraint: proof ? .claudeSourceAvailability : nil,
            availabilityObservedAt: proof ? observed ?? now : nil)
    }
    private func warning(_ reference: CoverageRecoveryReference, scope: CollectionScope? = nil,
                         reason: CoverageGapReason = .sourceUnavailable,
                         operation: CollectionOperation = .liveRead, observed: Date? = nil,
                         contentType: ContentType? = nil) -> CoverageGap {
        .init(reason: reason, scope: scope ?? self.scope(), contentType: contentType, operation: operation,
            recovery: reference, diagnosticCode: reason.defaultDiagnosticCode, observedAt: observed ?? now)
    }
    private func capture(_ store: ProtectedStore, reference: CoverageRecoveryReference,
                         scope: CollectionScope? = nil, authorized: Bool = true,
                         operation: CollectionOperation = .liveRead) async throws -> (PendingCapture, StoreProcessingPermit) {
        let permit = try #require(await store.processingPermit()), selected = scope ?? self.scope()
        let context = authorized ? CollectionWorkContext(scope: selected, operation: operation,
            retry: .init(scope: selected, session: reference.session, sourceURL: reference.sourceURL),
            trigger: .activePoll) : nil
        let packet = try CapturePacket(metadata: .init(agent: .claudeCode, interface: selected.interface,
            profileID: selected.profileID), eventJSON: Data("{}".utf8))
        _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, workContext: context)
        return (try #require(try await store.nextPending(at: now, permit: permit)), permit)
    }
    private func complete(_ store: ProtectedStore, proof: CoverageRecoveryReference,
                          scope: CollectionScope? = nil, authorized: Bool = true,
                          operation: CollectionOperation = .liveRead) async throws {
        let (capture, permit) = try await capture(store, reference: proof, scope: scope,
            authorized: authorized, operation: operation)
        try await store.completeCapture(capture, recoveredReferences: [proof], permit: permit, at: now)
    }

    @Test func clearsOnlyExactAvailabilityAndPreservesOtherReasonsScopesAndSibling() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
        let old = try reference()
        let gaps = [warning(old), warning(old, reason: .deliveryUncertain), warning(old, reason: .sourceChanged),
            warning(old, reason: .scannerUnavailable), warning(old, scope: scope(.standaloneCLI)),
            warning(old, operation: .historicalRead),
            warning(old, reason: .malformedSource, contentType: .userPrompt),
            warning(try reference(session: "sibling", url: URL(fileURLWithPath: "/owned-fake/sibling.jsonl")))]
        for gap in gaps { try await store.recordCoverageGap(gap, at: now) }
        let before = try await store.coverageOmissions(), target = try #require(before.first { $0.gap == gaps[0] })
        try await complete(store, proof: reference(proof: true))
        let after = try await store.coverageOmissions()
        #expect(Set(after.map(\.id)) == Set(before.map(\.id)).subtracting([target.id]))
        #expect(after.allSatisfy { before.contains($0) })
        #expect(try await store.coverageGaps().count == gaps.count)
        try await complete(store, proof: reference(proof: true))
        #expect(try await store.coverageOmissions() == after)
        #expect(await store.snapshot().analysisReceipts.isEmpty)
        #expect(await store.snapshot().alertDecisions.isEmpty)
        try await store.close()
    }

    @Test func missingRouteWrongInterfaceWrongSessionAndNewerObservationRemainUnresolved() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
        try await store.recordCoverageGap(warning(reference()), at: now)
        try await complete(store, proof: reference(proof: true), authorized: false)
        try await complete(store, proof: reference(proof: true), scope: scope(.standaloneCLI))
        try await complete(store, proof: reference(proof: true, session: "wrong"))
        try await complete(store, proof: reference(proof: true), operation: .hookDelivery)
        try await complete(store, proof: reference(proof: true, observed: now.addingTimeInterval(-1)))
        try await complete(store, proof: reference(proof: true, observed: now.addingTimeInterval(1)))
        #expect(try await store.coverageOmissions().count == 1)
        try await complete(store, proof: reference(proof: true))
        #expect(try await store.coverageOmissions().isEmpty)
        try await store.close()
    }

    @Test func childURLOnlyWarningNeedsTheConstrainedProofAndExactSelection() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
        let child = URL(fileURLWithPath: "/owned-fake/parent/subagents/agent-child.jsonl")
        let old = try reference(session: nil, url: child)
        try await store.recordCoverageGap(warning(old), at: now)
        await #expect(throws: StorageError.invalidPayload) {
            try await store.recordCoverageGap(warning(old, reason: .deliveryUncertain), at: now)
        }
        await #expect(throws: StorageError.invalidPayload) {
            try await store.recordCoverageGap(warning(reference(proof: true, session: nil, url: child),
                reason: .scannerUnavailable), at: now)
        }
        let (capture, permit) = try await capture(store, reference: old)
        await #expect(throws: StorageError.invalidPayload) {
            try await store.completeCapture(capture, recoveredReferences: [old], permit: permit, at: now)
        }
        #expect(try await store.coverageOmissions().count == 1)
        try await store.completeCapture(capture, recoveredReferences: [reference(proof: true, session: nil, url: child)],
            permit: permit, at: now)
        #expect(try await store.coverageOmissions().isEmpty)
        try await store.close()
    }

    @Test func failedCommitPreservesOmissionAndCapture() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting(),
            failureInjector: { if $0 == .beforeProcessingCommit { throw StorageError.injectedFailure } })
        try await store.recordCoverageGap(warning(reference()), at: now)
        await #expect(throws: StorageError.injectedFailure) { try await complete(store, proof: reference(proof: true)) }
        #expect(try await store.coverageOmissions().count == 1)
        #expect(try await store.queueStatistics().count == 1)
        try await store.close()
    }

    @Test func availabilityProofDoesNotRenewExpiredOmissionAge() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
        let expired = now.addingTimeInterval(-HistoricalAuditContext.lookback - 1)
        try await store.recordCoverageGap(warning(reference(), observed: expired), at: expired)
        let before = try await store.coverageOmissions(includeRecovered: true)
        try await complete(store, proof: reference(proof: true))
        #expect(try await store.coverageOmissions(includeRecovered: true) == before)
        #expect(before.count == 1 && before.first?.firstObservedAt == expired)
        try await store.close()
    }

    @Test func newerMissingObservationDuringCryptoYieldRejectsStaleSettlement() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = ClaudeAvailabilityReadGate(try .ephemeralForTesting())
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let old = try reference()
        try await store.recordCoverageGap(warning(old), at: now)
        let (capture, permit) = try await capture(store, reference: old)
        await crypto.arm()
        let pending = Task {
            try await store.completeCapture(capture, recoveredReferences: [reference(proof: true)], permit: permit, at: now)
        }
        await crypto.blocked()
        try await store.recordCoverageGap(warning(old, observed: now.addingTimeInterval(1)), at: now)
        await crypto.release()
        await #expect(throws: StorageError.stateChanged) { try await pending.value }
        #expect(try await store.queueStatistics().count == 1)
        let refreshed = try #require(try await store.coverageOmissions().first)
        #expect(refreshed.firstObservedAt == now)
        #expect(refreshed.gap.observedAt == now.addingTimeInterval(1))
        // A delayed older absence cannot move the observation boundary backwards.
        try await store.recordCoverageGap(warning(old, observed: now), at: now)
        #expect(try await store.coverageOmissions().first?.gap.observedAt == now.addingTimeInterval(1))
        // The newer observation is already present at lookup on the next attempt.
        try await store.completeCapture(capture, recoveredReferences: [reference(proof: true)], permit: permit, at: now)
        #expect(try await store.coverageOmissions().count == 1)
        try await store.close()
    }

    @Test func overfullCandidateLocationRemainsUnresolvedWithoutBlockingQueueProgress() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
        let old = try reference()
        try await store.recordCoverageGap(warning(old), at: now)
        var inserted = 1
        outer: for operation in [CollectionOperation.liveRead, .historicalRead] {
            for interface in [AgentInterface.t3, .standaloneCLI, .desktopCode] {
                for reason in CoverageGapReason.allCases {
                    for type in ContentType.allCases {
                        try await store.recordCoverageGap(warning(old, scope: scope(interface), reason: reason,
                            operation: operation, contentType: type), at: now)
                        inserted += 1
                        if inserted == 257 { break outer }
                    }
                }
            }
        }
        #expect(inserted == 257)
        try await complete(store, proof: reference(proof: true))
        #expect(try await store.coverageOmissions().count == 257)
        #expect(try await store.queueStatistics().count == 0)
        try await store.close()
    }
}
