import Foundation
import Testing
@testable import SpillcheckCore

@Suite("Observed collection compatibility")
struct CollectionCompatibilityTests {
    private let scope = CollectionScope(provider: .claudeCode, profileID: "existing-profile",
        interface: .standaloneCLI, path: .versionedTranscript)

    @Test func unfamiliarReleasePermitsAssessmentWithoutClaimingAcceptance() {
        for version in ["2.1.295", "2.9.0", "3.0.0", "3.0.0-beta.1"] {
            #expect(CollectionCompatibility.isEligible(provider: .claudeCode, interface: .standaloneCLI, version: version))
            #expect(CollectionCompatibility.recordedEvidence(provider: .claudeCode, interface: .standaloneCLI,
                producerVersion: version) == .unverified)
        }
        #expect(!CollectionCompatibility.isEligible(provider: .claudeCode, interface: .standaloneCLI, version: ""))
        #expect(!CollectionCompatibility.isEligible(provider: .claudeCode, interface: .desktopCode, version: "2.1.293"))
    }

    @Test func connectionCompatibilityAndAcceptanceAreIndependent() {
        let assessment = CollectionAssessment(scope: scope, observedExecutableVersion: "3.0.0",
            format: .claudeTranscript, usableOperations: [.liveRead],
            failures: [.init(reason: .missingMethod, operation: .historicalRead)])
        #expect(assessment.status == .partial)
        #expect(assessment.canPerform(.liveRead))
        #expect(!assessment.canPerform(.historicalRead))
        #expect(assessment.acceptanceEvidence == .unverified)
        let capability = AdapterCapability(provider: .claudeCode, interface: .standaloneCLI,
            agentVersion: "3.0.0", adapterVersion: "fixture", contentType: .toolOutput,
            path: .versionedTranscript, validation: .unverified, canObserveActiveSession: true,
            canReadHistoricalContent: false, canonicalization: .exclusiveAuthority)
        let coverage = AdapterCoverage(capability: capability, setupVerified: true, assessment: assessment)
        #expect(coverage.isConnected)
        #expect(coverage.analyzedIntervals.isEmpty)
        #expect(!AdapterCoverage(capability: capability, setupVerified: false, assessment: assessment).isConnected)
    }

    @Test func requiredToolFailurePreservesPromptAndResponseOperations() {
        let assessment = CollectionAssessment(scope: scope, format: .claudeTranscript,
            usableOperations: [.liveRead, .historicalRead], unavailableContent: [.toolOutput, .toolError],
            failures: [.init(reason: .changedContentFormat, contentType: .toolOutput)])
        #expect(assessment.status == .partial)
        #expect(assessment.canPerform(.liveRead))
        #expect(!assessment.unavailableContent.contains(.userPrompt))
        #expect(CollectionAssessment(scope: scope).status == .unverified)
        #expect(CollectionAssessment(scope: scope,
            failures: [.init(reason: .malformedReply, operation: .liveRead)]).status == .incompatible)
        #expect(CollectionAssessment(scope: scope,
            failures: [.init(reason: .transientFailure, operation: .liveRead)]).status == .unverified)
        #expect(CollectionAssessment(scope: scope, failures: [.init(reason: .transientFailure, operation: .liveRead),
            .init(reason: .missingMethod, operation: .historicalRead)]).status == .incompatible)
    }

    @Test func registrationProofSurvivesReleaseChangeButNotConfigurationChange() throws {
        let registration = UUID()
        func binding(socket: String = "/private/owned/capture.sock") -> HookRegistrationBinding {
            .init(provider: .claudeCode, profileID: "existing-profile", registrationID: registration,
                interface: .standaloneCLI, configurationPath: "/private/owned/settings.json",
                helperPath: "/Applications/Spillcheck.app/Contents/Helpers/spillcheck-hook", socketPath: socket)
        }
        let proof = ConnectionVerificationProof(binding: binding(), durableQueueID: UUID(), verifiedAt: fixtureTime)
        let decoded = try JSONDecoder().decode(ConnectionVerificationProof.self, from: JSONEncoder().encode(proof))
        #expect(decoded.applies(to: binding()))
        #expect(!decoded.applies(to: binding(socket: "/private/other/capture.sock")))
    }

    @Test func oldCoverageStillDecodesWithoutAnAssessment() throws {
        let capability = AdapterCapability(provider: .codex, interface: .t3, agentVersion: "0.160.1",
            adapterVersion: "1", contentType: .finalResponse, path: .publicHistory,
            validation: .validated, canObserveActiveSession: true, canReadHistoricalContent: true,
            canonicalization: .sharedUpstreamIdentity)
        let old = AdapterCoverage(capability: capability, setupVerified: true)
        let encoded = try JSONEncoder().encode(old)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "assessment")
        let decoded = try JSONDecoder().decode(AdapterCoverage.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.assessment == nil)
        #expect(decoded.isConnected)
    }
}
