import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor MetadataReadGate: BackgroundStoreCryptography {
    nonisolated let manifest: ProtectionManifest
    let delegate: BackgroundCryptography
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
           omission.gap.sourceKind == .codexUnknownItem, omission.gap.isRequiredFormatFailure == false {
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

@Suite("Constrained native metadata warning recovery", .timeLimit(.minutes(1)))
struct MetadataWarningRecoveryTests {
    private let now = Date(timeIntervalSince1970: 1_791_750_000)
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-metadata-recovery-\(UUID())")
    }
    private func scope(_ interface: AgentInterface = .standaloneCLI, path: CollectionPath = .publicHistory,
                       profile: String = "metadata-profile") -> CollectionScope {
        .init(provider: .codex, profileID: profile, interface: interface, path: path)
    }
    private func reference(_ item: String = "sleep", time: Date? = nil, constrained: Bool = false,
                           session: String = "native-session") throws -> CoverageRecoveryReference {
        .init(session: try .init(provider: .codex, profileID: "metadata-profile", sessionID: session),
            locator: .upstreamItem, itemID: item, contentTime: time ?? now, parserContract: "metadata-fixture-v1",
            constraint: constrained ? .unclassifiedMetadata : nil)
    }
    private func warning(_ reference: CoverageRecoveryReference, scope: CollectionScope? = nil,
                         operation: CollectionOperation = .liveRead, required: Bool? = false,
                         kind: CoverageSourceKind = .codexUnknownItem, diagnostic: CoverageDiagnosticCode = .unknownRecordKind,
                         excluded: Bool? = nil, contentType: ContentType? = nil,
                         reason: CoverageGapReason = .unsupportedContent) -> CoverageGap {
        .init(reason: reason, scope: scope ?? self.scope(), contentType: contentType, operation: operation,
            recovery: reference, isRequiredFormatFailure: required, sourceKind: kind,
            diagnosticCode: diagnostic, excludedContent: excluded)
    }
    private func capture(_ store: ProtectedStore, scope: CollectionScope? = nil,
                         authorized: Bool = true, operation: CollectionOperation = .liveRead) async throws -> (PendingCapture, StoreProcessingPermit) {
        let permit = try #require(await store.processingPermit())
        let selected = scope ?? self.scope()
        let work = authorized ? CollectionWorkContext(scope: selected, operation: operation) : nil
        let packet = try CapturePacket(metadata: .init(agent: .codex, interface: selected.interface, profileID: selected.profileID),
            eventJSON: JSONSerialization.data(withJSONObject: ["hook_event_name": "SpillcheckHistoryPoll", "session_id": "native-session"]))
        _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, workContext: work)
        return (try #require(try await store.nextPending(at: now, permit: permit)), permit)
    }
    private func complete(_ store: ProtectedStore, refs: [CoverageRecoveryReference], gaps: [CoverageGap] = [],
                          scope: CollectionScope? = nil, authorized: Bool = true) async throws {
        let (capture, permit) = try await capture(store, scope: scope, authorized: authorized)
        try await store.completeCapture(capture, coverageGaps: gaps, recoveredReferences: refs, permit: permit, at: now)
    }

    @Test func optionalConstraintDecodesLegacyAndDoesNotChangeLocationIdentity() throws {
        let ordinary = try reference(), constrained = try reference(constrained: true)
        let bytes = try JSONEncoder().encode(ordinary)
        let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(json["constraint"] == nil)
        #expect(try JSONDecoder().decode(CoverageRecoveryReference.self, from: bytes).constraint == nil)
        #expect(ordinary.identifiesSameLocation(as: constrained))
        #expect(constrained.identifiesSameLocation(as: ordinary))
        #expect(try JSONDecoder().decode(CoverageRecoveryReference.self,
            from: JSONEncoder().encode(constrained)).constraint == .unclassifiedMetadata)
    }

    @Test func constrainedRecoveryClearsOnlyAuthenticatedWarningAndSurvivesRestart() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let old = try reference()
        let gaps = [warning(old), warning(old, required: true, kind: .codexFunctionCallOutput, contentType: .toolOutput),
            warning(old, required: true, kind: .codexFunctionCallOutput, diagnostic: .unavailableSource,
                contentType: .toolOutput, reason: .scannerUnavailable),
            warning(old, required: true, kind: .codexFunctionCallOutput, diagnostic: .malformedRecord,
                contentType: .toolOutput, reason: .malformedSource),
            warning(old, scope: scope(.t3)), warning(try reference("other"))]
        for gap in gaps { try await store.recordCoverageGap(gap, at: now) }
        let before = try await store.coverageOmissions()
        let target = try #require(before.first { $0.gap == gaps[0] })
        try await complete(store, refs: [reference(constrained: true)])
        let after = try await store.coverageOmissions()
        #expect(Set(after.map(\.id)) == Set(before.map(\.id)).subtracting([target.id]))
        #expect(after.allSatisfy { prior in before.contains { $0 == prior } })
        #expect(await store.snapshot().analysisReceipts.isEmpty)
        try await store.close()
        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        #expect(try await reopened.coverageOmissions() == after)
        // Ordinary text recovery still has its existing full-location semantics.
        try await complete(reopened, refs: [old])
        #expect(try await reopened.coverageOmissions().map(\.gap.recovery?.itemID) == ["other"])
        try await reopened.close()
    }

    @Test func constrainedRecoveryRequiresCurrentRouteAndExactContentTime() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
        try await store.recordCoverageGap(warning(reference()), at: now)
        for (route, authorized) in [(scope(), false), (scope(path: .hook), true),
                                   (scope(profile: "another-profile"), true), (scope(.t3), true)] {
            try await complete(store, refs: [reference(constrained: true)], scope: route, authorized: authorized)
            #expect(try await store.coverageOmissions().count == 1)
        }
        try await complete(store, refs: [reference(time: now.addingTimeInterval(-1), constrained: true)])
        try await complete(store, refs: [reference(constrained: true, session: "another-session")])
        let (hookCapture, hookPermit) = try await capture(store, operation: .hookDelivery)
        try await store.completeCapture(hookCapture, recoveredReferences: [reference(constrained: true)], permit: hookPermit, at: now)
        #expect(try await store.coverageOmissions().count == 1)
        try await complete(store, refs: [reference(constrained: true)])
        #expect(try await store.coverageOmissions().isEmpty)
        try await store.close()
    }

    @Test func sameBatchGapVetoAndExactOptionalSignatureRemainRequired() async throws {
        for variant in 0..<9 {
            let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
            let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
            let old = try reference()
            let gap: CoverageGap
            switch variant {
            case 0: gap = warning(old, required: nil)
            case 1: gap = warning(old, required: true)
            case 2: gap = warning(old, kind: .codexFunctionCallOutput)
            case 3: gap = warning(old, diagnostic: .missingPayload)
            case 4: gap = warning(old, excluded: false)
            case 6: gap = warning(old, operation: .hookDelivery)
            case 7: gap = warning(try reference(constrained: true))
            case 8: gap = warning(.init(session: old.session, locator: old.locator, itemID: old.itemID,
                contentTime: old.contentTime, parserContract: old.parserContract, sourceURL: URL(fileURLWithPath: "/tmp/not-native")))
            default: gap = warning(old)
            }
            try await store.recordCoverageGap(gap, at: now)
            let sameBatch = variant == 5 ? [warning(old, required: true, contentType: .toolOutput)] : []
            try await complete(store, refs: [reference(constrained: true)], gaps: sameBatch)
            #expect(try await store.coverageOmissions().contains { $0.gap == gap })
            try await store.close()
        }
    }

    @Test func sameKeyKnownMeaningUpgradesUnknownAndCannotDowngrade() async throws {
        for excluded in [false, true] {
            let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
            let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
            let old = try reference(time: now.addingTimeInterval(-3600))
            try await store.recordCoverageGap(warning(old), at: now.addingTimeInterval(-3600))
            let before = try #require(try await store.coverageOmissions().first)
            let known = warning(old, required: !excluded, kind: .codexFunctionCallOutput,
                diagnostic: excluded ? .excludedBinaryContent : .missingPayload, excluded: excluded ? true : nil)
            try await store.recordCoverageGap(known, at: now)
            try await store.recordCoverageGap(warning(old), at: now)
            try await complete(store, refs: [reference(time: now.addingTimeInterval(-3600), constrained: true)])
            let after = try #require(try await store.coverageOmissions().first)
            #expect(after.id == before.id && after.firstObservedAt == before.firstObservedAt)
            #expect(after.gap.sourceKind == .codexFunctionCallOutput && after.gap.diagnosticCode == known.diagnosticCode)
            #expect(after.gap.excludedContent == known.excludedContent && after.gap.isRequiredFormatFailure == known.isRequiredFormatFailure)
            #expect(after.state == .blocked)
            try await store.close()
        }
    }

    @Test func oldAndFutureWarningsCannotBeRecovered() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
        let old = now.addingTimeInterval(-HistoricalAuditContext.lookback - 1), future = now.addingTimeInterval(1)
        for (item, time) in [("old", old), ("future", future)] {
            try await store.recordCoverageGap(warning(reference(item, time: time)), at: now)
            try await complete(store, refs: [reference(item, time: time, constrained: true)])
        }
        let all = try await store.coverageOmissions(limit: 20, since: old.addingTimeInterval(-1))
        #expect(all.count == 2 && all.allSatisfy(\.isUnresolved))
        try await store.close()
    }

    @Test func malformedConstrainedReferencesAreRejectedWithoutConsumingCapture() async throws {
        let session = try reference().session
        let variants: [CoverageRecoveryReference] = [
            .init(session: session, locator: .unavailable, itemID: "sleep", contentTime: now, parserContract: "v", constraint: .unclassifiedMetadata),
            .init(session: session, locator: .transcript(documentID: UUID(), recordIndex: 0), itemID: "sleep", contentTime: now, parserContract: "v", constraint: .unclassifiedMetadata),
            .init(session: session, locator: .upstreamItem, itemID: nil, contentTime: now, parserContract: "v", constraint: .unclassifiedMetadata),
            .init(session: session, locator: .upstreamItem, itemID: "sleep\n", contentTime: now, parserContract: "v", constraint: .unclassifiedMetadata),
            .init(session: session, locator: .upstreamItem, itemID: "sleep", parserContract: "v", constraint: .unclassifiedMetadata),
            .init(session: session, locator: .upstreamItem, itemID: "sleep", contentTime: now, parserContract: "v", sourceURL: URL(fileURLWithPath: "/tmp/other"), constraint: .unclassifiedMetadata),
            .init(session: try .init(provider: .claudeCode, profileID: "metadata-profile", sessionID: "native-session"),
                locator: .upstreamItem, itemID: "sleep", contentTime: now, parserContract: "v", constraint: .unclassifiedMetadata)
        ]
        for reference in variants {
            let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
            let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
            let (capture, permit) = try await capture(store)
            await #expect(throws: StorageError.invalidPayload) {
                try await store.completeCapture(capture, recoveredReferences: [reference], permit: permit, at: now)
            }
            #expect(try await store.queueStatistics().count == 1)
            try await store.close()
        }
    }

    @Test func cryptoYieldUpgradeOrNewSiblingRejectsStaleRecoveryAtomically() async throws {
        for insertSibling in [false, true] {
            let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
            let crypto = MetadataReadGate(try BackgroundCryptography.ephemeralForTesting())
            let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
            let old = try reference()
            try await store.recordCoverageGap(warning(old), at: now)
            let (capture, permit) = try await capture(store)
            let checkpoint = SourceCheckpoint(capabilityID: UUID(), sourceDocumentID: UUID(),
                revision: try ContentRevision(keyedDigest: Data(repeating: 2, count: 32)), byteOffset: 7)
            await crypto.arm()
            let pending = Task {
                try await store.completeCapture(capture, checkpoints: [checkpoint],
                    recoveredReferences: [reference(constrained: true)], permit: permit, at: now)
            }
            await crypto.blocked()
            let newGap = insertSibling ? warning(old, operation: .historicalRead)
                : warning(old, required: true, kind: .codexFunctionCallOutput, diagnostic: .missingPayload)
            try await store.recordCoverageGap(newGap, at: now)
            await crypto.release()
            await #expect(throws: StorageError.stateChanged) { try await pending.value }
            #expect(try await store.queueStatistics().count == 1)
            #expect(try await store.checkpoint(documentID: checkpoint.sourceDocumentID) == nil)
            let gaps = try await store.coverageOmissions()
            #expect(gaps.count == (insertSibling ? 2 : 1) && gaps.allSatisfy(\.isUnresolved))
            if !insertSibling { #expect(gaps.first?.gap.isRequiredFormatFailure == true) }
            try await store.close()
        }
    }

    @Test func candidateBudgetKeepsExcessWarningWithoutBlockingProgressOrExactRetry() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
        var references: [CoverageRecoveryReference] = []
        for index in 0..<257 {
            try await store.recordCoverageGap(warning(reference("item-\(index)")), at: now)
            references.append(try reference("item-\(index)", constrained: true))
        }
        let (capture, permit) = try await capture(store)
        let checkpoint = SourceCheckpoint(capabilityID: UUID(), sourceDocumentID: UUID(),
            revision: try ContentRevision(keyedDigest: Data(repeating: 3, count: 32)), byteOffset: 19)
        try await store.completeCapture(capture, checkpoints: [checkpoint], recoveredReferences: references, permit: permit, at: now)
        let remaining = try await store.coverageOmissions()
        #expect(remaining.count == 1 && remaining.first?.gap.recovery?.itemID == "item-256")
        #expect(try await store.queueStatistics().count == 0)
        #expect(try await store.checkpoint(documentID: checkpoint.sourceDocumentID) == checkpoint)
        try await complete(store, refs: [references[256]])
        #expect(try await store.coverageOmissions().isEmpty)
        try await store.close()
    }

    @Test func overflowingLocationExhaustsMetadataLookupsButNotOrdinaryRecovery() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ProtectedStore.open(at: directory, cryptography: BackgroundCryptography.ephemeralForTesting())
        var references: [CoverageRecoveryReference] = []
        for index in 0..<255 {
            try await store.recordCoverageGap(warning(reference("bounded-\(index)")), at: now)
            references.append(try reference("bounded-\(index)", constrained: true))
        }
        let overflowing = try reference("overflow")
        try await store.recordCoverageGap(warning(overflowing), at: now)
        try await store.recordCoverageGap(warning(overflowing, operation: .historicalRead), at: now)
        try await store.recordCoverageGap(warning(reference("later-metadata")), at: now)
        try await store.recordCoverageGap(warning(reference("ordinary"), required: true, contentType: .toolOutput), at: now)
        references += [try reference("overflow", constrained: true),
            try reference("later-metadata", constrained: true), try reference("ordinary")]
        let (capture, permit) = try await capture(store)
        let checkpoint = SourceCheckpoint(capabilityID: UUID(), sourceDocumentID: UUID(),
            revision: try ContentRevision(keyedDigest: Data(repeating: 4, count: 32)), byteOffset: 23)
        try await store.completeCapture(capture, checkpoints: [checkpoint], recoveredReferences: references, permit: permit, at: now)
        let remaining = try await store.coverageOmissions()
        #expect(remaining.count == 3)
        #expect(remaining.filter { $0.gap.recovery?.itemID == "overflow" }.count == 2)
        #expect(remaining.filter { $0.gap.recovery?.itemID == "later-metadata" }.count == 1)
        #expect(try await store.queueStatistics().count == 0)
        #expect(try await store.checkpoint(documentID: checkpoint.sourceDocumentID) == checkpoint)
        #expect(await store.snapshot().analysisReceipts.isEmpty)
        try await store.close()
    }
}
