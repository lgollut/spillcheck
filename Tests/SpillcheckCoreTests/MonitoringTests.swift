import Foundation
import Testing
@testable import SpillcheckCore

@Suite("Independent monitoring and coverage state")
struct MonitoringTests {
    @Test func pauseKeepsQueueAndCoverageButRejectsPayloadsAndOldCommits() throws {
        let partial = CoverageStatus.partial([CoverageGap(reason: .unsupportedContent)])
        let queue = QueueActivity.processing(pendingCount: 3, activeCount: 1)
        var state = MonitoringState(queueActivity: queue, coverage: partial)
        let oldPermit = try #require(state.processingPermit())
        #expect(state.acceptsPayloads)
        #expect(state.acceptsCommit(oldPermit))
        state.pause()
        #expect(state.mode == .paused)
        #expect(state.runState == .running)
        #expect(state.queueActivity == queue)
        #expect(state.coverage == partial)
        #expect(!state.acceptsPayloads)
        #expect(state.processingPermit() == nil)
        #expect(!state.acceptsCommit(oldPermit))
        state.resume()
        #expect(state.acceptsPayloads)
        #expect(!state.acceptsCommit(oldPermit))
        #expect(state.acceptsCommit(try #require(state.processingPermit())))
    }

    @Test func closingWindowDoesNotChangeMonitoringAndQuitCannotResumeIt() throws {
        var state = MonitoringState()
        let permit = try #require(state.processingPermit())
        // Window/viewing-session state belongs to the shell/vault; no core window-close mutation.
        #expect(state.acceptsPayloads)
        #expect(state.acceptsCommit(permit))
        state.stop()
        #expect(state.runState == .stopped)
        #expect(!state.acceptsPayloads)
        #expect(!state.acceptsCommit(permit))
        state.resume()
        #expect(!state.acceptsPayloads)
        #expect(state.processingPermit() == nil)
    }

    @Test func queueActivityNeverClaimsCoverageOrOverwritesPauseChoice() {
        var state = MonitoringState(mode: .paused)
        state.updateQueueActivity(.processing(pendingCount: 2, activeCount: 1))
        #expect(state.mode == .paused)
        #expect(state.coverage == .notConfigured)
        state.updateCoverage(.partial([CoverageGap(reason: .scannerUnavailable)]))
        #expect(state.queueActivity == .processing(pendingCount: 2, activeCount: 1))
        #expect(state.mode == .paused)
    }

    @Test func executablePresenceAndConnectedCapabilityDoNotClaimAnalyzedInterval() {
        let capability = AdapterCapability(
            provider: .claudeCode, interface: .standaloneCLI, agentVersion: "fixture",
            adapterVersion: "fixture", contentType: .toolOutput, path: .hook,
            validation: .validated, canObserveActiveSession: true, canReadHistoricalContent: false,
            canonicalization: .exclusiveAuthority
        )
        let detectedOnly = AdapterCoverage(capability: capability, setupVerified: false)
        #expect(!detectedOnly.isConnected)
        let connected = AdapterCoverage(capability: capability, setupVerified: true)
        #expect(connected.isConnected)
        #expect(connected.analyzedIntervals.isEmpty)
        #expect(connected.capability.contentType == .toolOutput)
        #expect(!connected.capability.canReadHistoricalContent)
    }

    @Test func queueIdentityIncludesSourceAndEncryptedPendingWorkExpires() throws {
        let first = try sourceRecord()
        let second = try sourceRecord(item: "item-2")
        let firstIdentity = IngestionIdentity(source: first.metadata.identity, revision: first.revision)
        let secondIdentity = IngestionIdentity(source: second.metadata.identity, revision: second.revision)
        #expect(firstIdentity != secondIdentity)
        let event = try QueuedEvent(
            identity: firstIdentity, encryptedPayload: ProtectedPayloadReference(),
            capturedAt: fixtureTime, expiresAt: fixtureTime.addingTimeInterval(60)
        )
        #expect(event.isEligible(at: fixtureTime))
        #expect(event.isEligible(at: fixtureTime.addingTimeInterval(59)))
        #expect(!event.isEligible(at: fixtureTime.addingTimeInterval(60)))
        #expect(throws: ContractError.invalidTime) {
            try QueuedEvent(
                identity: firstIdentity, encryptedPayload: ProtectedPayloadReference(),
                capturedAt: fixtureTime, expiresAt: fixtureTime
            )
        }
    }
}
