import Foundation
@_spi(Testing) import SpillcheckCore

/// Exercises only fabricated normalized records. No provider, scanner, vault or Keychain.
@main struct TypedEvidenceTests {
    static let parent = "00000000-0000-7000-8000-000000000001"
    static let child = "00000000-0000-7000-8000-000000000002"
    static let other = "00000000-0000-7000-8000-000000000003"
    static let token = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
    static let fingerprint = try! ValueFingerprint(keyedDigest: Data(repeating: 2, count: 32))
    struct Failure: Error { let check: String }
    static func require(_ condition: Bool, _ check: String) throws {
        if !condition { throw Failure(check: check) }
    }
    static func linked(_ evidence: CodexLiveEvidence, kind: String = "subAgentActivity", id: String = child) async {
        await evidence.observeNativeLinks(parent: parent, page: .init(data: [.object(["item": .object([
            "id": .string("native-spawn"), "type": .string(kind), "agentThreadId": .string(id)
        ])])]))
    }
    static func evidence(link: Bool = true, verifyChild: Bool = true) async -> CodexLiveEvidence {
        let result = CodexLiveEvidence()
        await result.selectPrimary(parent)
        await result.verifyThread(parent, result: .init(thread: .object(["id": .string(parent)])))
        if link { await linked(result) }
        if verifyChild { await result.verifyThread(child, result: .init(thread: .object(["id": .string(child)]))) }
        return result
    }
    static func source(_ session: String, _ marker: String, _ type: ContentType,
                       item: String = "item", prefix: String = "", revision: UInt8 = 1,
                       contentTime: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws -> CollectedSource {
        let identity = try SourceIdentity(session: .init(provider: .codex, profileID: "fake", sessionID: session), itemID: item)
        let origin = try SourceOrigin(adapterID: "fake-codex", adapterVersion: "1", agentVersion: "fake",
            interface: .standaloneCLI, provenance: .live, canonicalization: .exclusiveAuthority)
        let now = Date()
        let metadata = try SourceRecordMetadata(identity: identity, contentType: type,
            contentTime: contentTime, observedAt: now, origin: origin)
        return try .init(record: .init(metadata: metadata,
            revision: .init(keyedDigest: Data(repeating: revision, count: 32)),
            segments: [.init(id: "text", utf8: Data("\(prefix)LEAKRET_M4_\(marker) \(token)".utf8))]))
    }
    static func collect(_ evidence: CodexLiveEvidence, _ sources: [CollectedSource]) async {
        await evidence.collect(.init(sources: sources), capturedAt: Date(), readStartedAt: Date())
    }
    static func snapshot(_ sources: [CollectedSource]) throws -> InventorySnapshot {
        var ledger = InventoryLedger()
        for source in sources {
            let record = source.record
            let data = record.segments[0].utf8
            let range = data.range(of: Data(token.utf8))!
            let location = try CanonicalLocation(segmentID: "text", range: .init(range.lowerBound, range.upperBound))
            let extraction = try ExactExtraction(valueUTF8: Data(token.utf8), location: location, in: record)
            let detection = try LocatedDetection(extraction: extraction, in: record, fingerprint: fingerprint,
                evidence: [.init(rule: .init(id: "fixture", version: "1"), signal: .strong,
                    reason: .recognizedFormat, category: .token)], protectedValue: .init())
            _ = try ledger.ingest(.init(source: record, detectorVersion: BetterleaksSecretDetector.version,
                detections: [detection]))
        }
        return ledger.snapshot
    }
    static func main() async throws {
        let complete = await evidence()
        let childKinds: [(String, ContentType)] = [("CHILD_PROMPT", .userPrompt),
            ("CHILD_INTERMEDIATE", .intermediateResponse), ("CHILD_FINAL", .finalResponse),
            ("CHILD_TOOL_OUTPUT", .toolOutput), ("CHILD_TOOL_ERROR", .toolError)]
        let childSources = try childKinds.map { try source(child, $0.0, $0.1, item: $0.0) }
        let parentSource = try source(parent, "PROMPT", .userPrompt)
        await collect(complete, childSources + [parentSource])
        let committed = try snapshot(childSources + [parentSource])
        let roles = await complete.committedByRole(in: committed, fingerprint: fingerprint)
        try require(roles["parent"] == ["PROMPT": 1] && roles["child"]?.count == 5
            && roles["child"]?.values.allSatisfy { $0 == 1 } == true, "own-native-source-types")
        try require(await complete.committed(in: .init(), fingerprint: fingerprint).isEmpty, "observed-is-not-committed")
        await collect(complete, childSources)
        try require(await complete.committedByRole(in: committed, fingerprint: fingerprint) == roles, "replay-deduplicates")

        let revised = await evidence()
        let newRevision = try source(child, "CHILD_PROMPT", .userPrompt, revision: 2)
        await collect(revised, [newRevision])
        let old = try snapshot([source(child, "CHILD_PROMPT", .userPrompt)])
        try require(await revised.committed(in: old, fingerprint: fingerprint).isEmpty, "old-receipt-cannot-credit-new-revision")
        let current = try snapshot([newRevision])
        try require(await revised.committed(in: current, fingerprint: fingerprint) == ["CHILD_PROMPT": 1],
            "exact-revision-receipt-required")
        let noReceipt = InventorySnapshot(records: current.records, occurrences: current.occurrences)
        try require(await revised.committed(in: noReceipt, fingerprint: fingerprint).isEmpty, "occurrence-without-receipt-rejected")
        let otherTime = try snapshot([source(child, "CHILD_PROMPT", .userPrompt, revision: 2,
            contentTime: Date(timeIntervalSince1970: 1_800_000_001))])
        try require(await revised.committed(in: otherTime, fingerprint: fingerprint).isEmpty, "occurrence-content-time-must-match")

        let parentMirror = await evidence()
        await collect(parentMirror, try childKinds.map { try source(parent, $0.0, $0.1, item: $0.0) })
        try require(await parentMirror.summary().isEmpty, "parent-cannot-satisfy-child")

        let wrongKind = await evidence()
        await collect(wrongKind, [try source(child, "CHILD_PROMPT", .toolOutput)])
        try require(await wrongKind.summary().isEmpty, "tool-arguments-are-not-child-prompt")

        let unlinked = await evidence(link: false)
        await collect(unlinked, childSources)
        try require(await unlinked.summary().isEmpty, "unlinked-source-rejected")
        await linked(unlinked, kind: "userMessage")
        await collect(unlinked, childSources)
        try require(await unlinked.summary().isEmpty, "unrecognized-link-rejected")

        let unverified = await evidence(verifyChild: false)
        await unverified.verifyThread(child, result: .init(thread: .object(["id": .string(other)])))
        await collect(unverified, childSources)
        try require(await unverified.summary().isEmpty, "mismatched-native-metadata-rejected")

        let prefixed = await evidence()
        await collect(prefixed, [try source(child, "CHILD_PROMPT", .userPrompt, prefix: "Provider context\n")])
        try require(await prefixed.summary() == ["CHILD_PROMPT": 1], "legitimate-prefix-accepted")
        await collect(prefixed, [try source(child, "CHILD_PROMPT", .userPrompt, item: "second")])
        try require(await prefixed.summary() == ["CHILD_PROMPT": 2], "duplicate-native-items-counted")

        await linked(complete, id: other)
        try require(await complete.nativeSourceRoles()["nativeLinkedChildSessionCount"] == 2,
            "additional-child-remains-visible")
        print("{\"passed\":true,\"checks\":15,\"providersInvoked\":false,\"keychainAccessed\":false}")
    }
}
