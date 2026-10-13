import Foundation
@_spi(Testing) import SpillcheckCore

// CollectionConfiguration's unrelated setup default; the actual role/evidence code is compiled unchanged.
struct AgentProfileDraft { static let supportedHosts: Set<AgentInterface> = [.standaloneCLI, .t3] }
private enum Failure: Error { case failed(String) }
private func check(_ condition: Bool, _ stage: String) throws { if !condition { throw Failure.failed(stage) } }

@main struct CodexRoleEvidenceProbe {
    static let parent = "11111111-1111-4111-8111-111111111111"
    static let child = "22222222-2222-4222-8222-222222222222"
    static let unrelated = "33333333-3333-4333-8333-333333333333"
    static let now = Date(timeIntervalSince1970: 1_792_000_000)
    static let roles = CodexAcceptanceRoles(parent: parent, child: child, profileID: "owned-fixture", interface: .standaloneCLI)

    static func source(marker: String, session: String? = nil, kind: ContentType? = nil,
                       profile: String = "owned-fixture", revision: UInt8 = 1, suffix: String = "") throws -> SourceRecord {
        let session = try SessionIdentity(provider: .codex, profileID: profile,
            sessionID: session ?? (marker.hasPrefix("CHILD_") ? child : parent))
        let origin = try SourceOrigin(adapterID: "codex", adapterVersion: "fixture", agentVersion: "0.162.1",
            interface: .standaloneCLI, provenance: .live, canonicalization: .sharedUpstreamIdentity)
        let metadata = try SourceRecordMetadata(identity: SourceIdentity(session: session, itemID: marker + suffix),
            contentType: kind ?? CodexAcceptanceRoleEvidence.expected[marker]!, contentTime: now, observedAt: now,
            origin: origin)
        let bytes = Data("LEAKRET_M4_\(marker) \(CodexAcceptanceRoleEvidence.token)".utf8)
        return try SourceRecord(metadata: metadata, revision: ContentRevision(keyedDigest: Data(repeating: revision, count: 32)),
            segments: [SourceSegment(id: "text", utf8: bytes)])
    }

    static func commit(_ record: SourceRecord, store: ProtectedStore, crypto: BackgroundCryptography) async throws {
        let bytes = Data(CodexAcceptanceRoleEvidence.token.utf8)
        let range = record.segments[0].utf8.range(of: bytes)!
        let location = try CanonicalLocation(components: [.init(segmentID: "text", range: .init(range.lowerBound, range.upperBound))])
        let extraction = try ExactExtraction(valueUTF8: bytes, location: location, in: record)
        let reference = ProtectedPayloadReference()
        let payload = try await crypto.sealInventory(bytes, binding: .init(reference: reference, ownerID: reference.id, kind: .value))
        let detection = try LocatedDetection(extraction: extraction, in: record,
            fingerprint: await crypto.fingerprint(exactBytes: bytes),
            evidence: [.init(rule: .init(id: "fixture", version: "1"), signal: .strong, reason: .recognizedFormat, category: .token)],
            protectedValue: reference)
        guard let permit = await store.processingPermit() else { throw Failure.failed("no-permit") }
        _ = try await store.commit(SourceAnalysis(source: record, detectorVersion: BetterleaksSecretDetector.version,
            detections: [detection]), payloads: [payload], permit: permit, at: now)
    }

    static func verify(_ evidence: CodexAcceptanceRoleEvidence, link: Bool = true, childMetadata: Bool = true) async {
        await evidence.verifyThread(parent, result: .init(thread: .object(["id": .string(parent)])))
        if childMetadata { await evidence.verifyThread(child, result: .init(thread: .object(["id": .string(child)]))) }
        if link { await evidence.observeLinks(parent: parent, page: .init(data: [
            .object(["item": .object(["type": .string("collabAgentToolCall"), "receiverThreadIds": .array([.string(child)])])])])) }
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-codex-role-probe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: root, cryptography: crypto)
        let records = try CodexAcceptanceRoleEvidence.expected.keys.sorted().map { try source(marker: $0) }
        let batch = CollectionBatch(sources: records.map { CollectedSource(record: $0) })
        let evidence = CodexAcceptanceRoleEvidence(roles: roles)
        await verify(evidence)
        await evidence.collect(batch)
        var summary = await evidence.summary(snapshot: store.snapshot(), syntheticValueID: nil)
        try check(!summary.complete && summary.markers.values.allSatisfy(\.isEmpty), "uncommitted-not-counted")
        for record in records { try await commit(record, store: store, crypto: crypto) }
        let snapshot = await store.snapshot()
        let value = snapshot.records.values.first!.id
        summary = await evidence.summary(snapshot: snapshot, syntheticValueID: value)
        try check(summary.complete, "twelve-typed-durable-markers")
        try check(!(await evidence.summary(snapshot: snapshot, syntheticValueID: UUID())).complete, "different-value-not-counted")
        await evidence.collect(batch)
        try check(await evidence.summary(snapshot: snapshot, syntheticValueID: value).complete, "replay-stable")
        let noReceipt = InventorySnapshot(records: snapshot.records, occurrences: snapshot.occurrences)
        try check(!(await evidence.summary(snapshot: noReceipt, syntheticValueID: value)).complete, "receipt-required")
        let noOccurrence = InventorySnapshot(records: snapshot.records, analysisReceipts: snapshot.analysisReceipts)
        try check(!(await evidence.summary(snapshot: noOccurrence, syntheticValueID: value)).complete, "occurrence-required")
        try await store.close()
        let reopened = try await ProtectedStore.open(at: root, cryptography: crypto)
        try check(await evidence.summary(snapshot: reopened.snapshot(), syntheticValueID: value).complete, "durable-after-reopen")
        try await reopened.close()

        for (label, link, metadata) in [("no-native-link", false, true), ("unverified-child", true, false)] {
            let other = CodexAcceptanceRoleEvidence(roles: roles)
            await verify(other, link: link, childMetadata: metadata); await other.collect(batch)
            try check(!(await other.summary(snapshot: snapshot, syntheticValueID: value)).complete, label)
        }
        let inconsistent = CodexAcceptanceRoleEvidence(roles: roles)
        await verify(inconsistent); await inconsistent.collect(batch)
        await inconsistent.verifyThread(child, result: .init(thread: .object(["id": .string(unrelated)])))
        try check(!(await inconsistent.summary(snapshot: snapshot, syntheticValueID: value)).complete, "conflicting-native-metadata")
        let falseLink = CodexAcceptanceRoleEvidence(roles: roles)
        await verify(falseLink, link: false)
        await falseLink.observeLinks(parent: parent, page: .init(data: [
            .object(["item": .object(["type": .string("userMessage"), "receiverThreadIds": .array([.string(child)])])])]))
        await falseLink.collect(batch)
        try check(!(await falseLink.summary(snapshot: snapshot, syntheticValueID: value)).complete, "arbitrary-reference-not-native-link")
        let wrongRevision = CodexAcceptanceRoleEvidence(roles: roles)
        await verify(wrongRevision)
        await wrongRevision.collect(.init(sources: try records.map { .init(record: try source(marker: $0.metadata.identity.itemID, revision: 2)) }))
        try check(!(await wrongRevision.summary(snapshot: snapshot, syntheticValueID: value)).complete, "stale-receipt-not-counted")
        let mirrored = CodexAcceptanceRoleEvidence(roles: roles)
        await verify(mirrored)
        await mirrored.collect(.init(sources: try CodexAcceptanceRoleEvidence.expected.keys.map { .init(record: try source(marker: $0, session: parent)) }))
        let mirrorSummary = await mirrored.summary(snapshot: snapshot, syntheticValueID: value)
        try check(!mirrorSummary.complete && mirrorSummary.markers["child"]!.isEmpty, "parent-mirror-not-child")
        for mutation in ["wrong-profile", "unrelated-session", "wrong-type"] {
            let other = CodexAcceptanceRoleEvidence(roles: roles)
            await verify(other)
            await other.collect(.init(sources: try CodexAcceptanceRoleEvidence.expected.keys.map { marker in
                .init(record: try source(marker: marker, session: mutation == "unrelated-session" ? unrelated : nil,
                    kind: mutation == "wrong-type" ? .toolOutput : nil,
                    profile: mutation == "wrong-profile" ? "foreign" : "owned-fixture"))
            }))
            try check(!(await other.summary(snapshot: snapshot, syntheticValueID: value)).complete, mutation)
        }
        let overflow = CodexAcceptanceRoleEvidence(roles: roles)
        await verify(overflow)
        await overflow.collect(.init(sources: try (0...128).map { .init(record: try source(marker: "CHILD_FINAL", suffix: String($0))) }))
        try check(!(await overflow.summary(snapshot: snapshot, syntheticValueID: value)).bounded, "observation-budget")

        let args = ["--codex-profile", "owned-fixture", "--codex-version", "0.162.1", "--codex-home", "/fake/home",
            "--codex-executable", "/fake/codex", "--codex-active-thread", parent, "--codex-active-thread", child,
            "--acceptance-codex-parent", parent, "--acceptance-codex-child", child,
            "--acceptance-no-profile-catchup", "--acceptance-cleanup-new-vault"]
        let configuration = try CodexCollectionConfiguration.fromArguments(args)
        try check(try CodexAcceptanceRoles.fromArguments(args, configuration: configuration, explicitStore: true, reportRequested: true) != nil, "exact-config")
        for (label, changedArgs, explicit, report) in [
            ("store-required", args, false, true), ("report-required", args, true, false),
            ("both-roles-required", Array(args.dropLast(4)), true, true),
            ("duplicate-role", args + ["--acceptance-codex-child", child], true, true),
            ("history-enumeration-forbidden", args.filter { $0 != "--acceptance-no-profile-catchup" }, true, true)] {
            do {
                _ = try CodexAcceptanceRoles.fromArguments(changedArgs, configuration: configuration, explicitStore: explicit, reportRequested: report)
                throw Failure.failed(label)
            } catch is CodexCollectionError {}
        }
        print("{\"passed\":true,\"providerLaunched\":false,\"appLaunched\":false}")
    }
}
