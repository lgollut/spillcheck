import Foundation
import SpillcheckCore

let fixtureTime = Date(timeIntervalSince1970: 1_800_000_000)

func fingerprint(_ byte: UInt8 = 1) throws -> ValueFingerprint {
    try ValueFingerprint(keyedDigest: Data(repeating: byte, count: 32))
}

func evidence(
    signal: SignalStrength = .strong, rule: String = "fixture.format",
    version: String = "1", category: SecretCategory = .token
) throws -> DetectionEvidence {
    DetectionEvidence(
        rule: try RuleIdentity(id: rule, version: version), signal: signal,
        reason: .recognizedFormat, category: category
    )
}

func sourceRecord(
    provider: AgentProvider = .codex, profile: String = "fixture-profile",
    session: String = "session-1", item: String = "item-1",
    contentType: ContentType = .toolOutput, text: String = "SYNTHETIC_VALUE_A",
    revision: UInt8 = 1, interface: AgentInterface = .standaloneCLI,
    provenance: SourceProvenance = .live, contentTime: Date = fixtureTime,
    protectedMetadata: ProtectedPayloadReference? = nil
) throws -> SourceRecord {
    let sessionID = try SessionIdentity(provider: provider, profileID: profile, sessionID: session)
    let identity = try SourceIdentity(session: sessionID, itemID: item)
    let origin = try SourceOrigin(
        adapterID: "fixture.reader", adapterVersion: "1", agentVersion: "fixture-1",
        interface: interface, provenance: provenance, canonicalization: .sharedUpstreamIdentity
    )
    return try SourceRecord(
        metadata: SourceRecordMetadata(
            identity: identity, contentType: contentType, contentTime: contentTime,
            observedAt: fixtureTime, protectedMetadata: protectedMetadata, origin: origin
        ),
        revision: ContentRevision(keyedDigest: Data(repeating: revision, count: 32)),
        segments: [SourceSegment(id: "text", utf8: Data(text.utf8))]
    )
}

func detection(
    in source: SourceRecord, range: UTF8Range? = nil, value: String? = nil,
    fingerprintByte: UInt8 = 1, signal: SignalStrength = .strong,
    rule: String = "fixture.format", ruleVersion: String = "1",
    category: SecretCategory = .token, excerpt: ProtectedPayloadReference? = ProtectedPayloadReference()
) throws -> LocatedDetection {
    let bytes = source.segments[0].utf8
    let location = try CanonicalLocation(segmentID: "text", range: range ?? UTF8Range(0, bytes.count))
    let rawValue = try value.map { Data($0.utf8) } ?? location.extract(from: source)
    let extraction = try ExactExtraction(valueUTF8: rawValue, location: location, in: source)
    return try LocatedDetection(
        extraction: extraction, in: source, fingerprint: fingerprint(fingerprintByte),
        evidence: [evidence(signal: signal, rule: rule, version: ruleVersion, category: category)],
        protectedValue: ProtectedPayloadReference(), protectedExcerpt: excerpt
    )
}

func analysis(
    provider: AgentProvider = .codex, profile: String = "fixture-profile",
    session: String = "session-1", item: String = "item-1", fingerprintByte: UInt8 = 1,
    signal: SignalStrength = .strong, revision: UInt8 = 1,
    interface: AgentInterface = .standaloneCLI, provenance: SourceProvenance = .live,
    contentTime: Date = fixtureTime, detectorVersion: String = "1",
    rule: String = "fixture.format", ruleVersion: String = "1"
) throws -> SourceAnalysis {
    let source = try sourceRecord(
        provider: provider, profile: profile, session: session, item: item,
        revision: revision, interface: interface, provenance: provenance, contentTime: contentTime
    )
    return try SourceAnalysis(
        source: source, detectorVersion: detectorVersion,
        detections: [detection(
            in: source, fingerprintByte: fingerprintByte, signal: signal, rule: rule, ruleVersion: ruleVersion
        )]
    )
}

/// Deterministic SplitMix64, so a failing script replays exactly.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// One random ledger operation drawn from a small pool of sessions, items and revisions, so that
/// replays, kind conflicts, removals and pruning all occur within a few dozen steps.
func randomLedgerOperation(_ ledger: inout InventoryLedger, using random: inout SeededRandom) throws {
    let session = "session-\(Int.random(in: 0..<3, using: &random))"
    let index = Int.random(in: 0..<10, using: &random)
    let item = "item-\(index)"
    let kind = ContentType.allCases[index % ContentType.allCases.count]
    let age = [0.0, 2, 20].randomElement(using: &random)! * 24 * 60 * 60
    let time = fixtureTime.addingTimeInterval(-age)
    let revision = UInt8(Int.random(in: 1...3, using: &random))
    switch Int.random(in: 0..<10, using: &random) {
    case 0..<3:
        let source = try sourceRecord(session: session, item: item, contentType: kind, revision: revision, contentTime: time)
        _ = try ledger.ingest(SourceAnalysis(source: source, detectorVersion: "1", detections: []))
    case 3..<5:
        // One value per item: a second value at the same location would reject the batch.
        let byte = UInt8(1 + index % 4)
        let source = try sourceRecord(session: session, item: item, contentType: kind, revision: revision, contentTime: time)
        _ = try ledger.ingest(SourceAnalysis(source: source, detectorVersion: "1",
            detections: [detection(in: source, fingerprintByte: byte)]))
    case 5:
        // A new revision of a known source whose content type differs is rejected whole.
        let known = try sourceRecord(session: session, item: item, contentType: kind, revision: revision, contentTime: time)
        _ = try ledger.ingest(SourceAnalysis(source: known, detectorVersion: "1", detections: []))
        let other = ContentType.allCases[(index + 1) % ContentType.allCases.count]
        let source = try sourceRecord(session: session, item: item, contentType: other, revision: 9, contentTime: time)
        _ = try? ledger.ingest(SourceAnalysis(source: source, detectorVersion: "1", detections: []))
    case 6:
        let audit = try HistoricalAuditContext(reason: .restart, endingAt: fixtureTime.addingTimeInterval(-60 * 24 * 60 * 60))
        let source = try sourceRecord(session: session, item: item, contentType: kind, revision: revision,
            provenance: .historical(audit), contentTime: time)
        _ = try ledger.ingest(SourceAnalysis(source: source, detectorVersion: "1", detections: []))
    case 7:
        _ = try? ledger.removeContent(for: fingerprint(UInt8(Int.random(in: 1...4, using: &random))))
    case 8:
        let days = Double(Int.random(in: 1...15, using: &random))
        ledger.pruneProcessedSources(before: fixtureTime.addingTimeInterval(-days * 24 * 60 * 60), stampingUntimedAt: fixtureTime)
    default:
        if let id = ledger.occurrences.keys.sorted(by: { $0.uuidString < $1.uuidString }).first {
            try ledger.review(id, as: .falsePositive)
        }
    }
}
