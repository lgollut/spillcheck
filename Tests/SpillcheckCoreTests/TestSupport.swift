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
