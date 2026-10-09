import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

@Suite("Multi-record durable capture completion")
struct CaptureCompletionTests {
    @Test func liveAdmissionScopeSurvivesASeparateStoreLifetime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-scope-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let now = Date()
        let scope = try LiveCaptureScope(startedAt: now.addingTimeInterval(-60), catchupReason: .resume)
        let body = Data("synthetic queue bytes".utf8)
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(body, capturedAt: now, permit: permit, at: now, scope: scope)
        try await store.close()
        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let nextPermit = try #require(await reopened.processingPermit())
        let capture = try #require(try await reopened.nextPending(at: now, permit: nextPermit))
        let work = try await reopened.openCapturedWork(capture)
        #expect(work.scope == scope)
        #expect(work.body == body)
        #expect(try await reopened.openCapture(capture) == body)
        try await reopened.close()
    }
    @Test func sourceCommitsRemainReplayableUntilFinalCheckpointAndCaptureCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-completion-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(Data("synthetic multi-record capture".utf8), capturedAt: .now, permit: permit)
        let capture = try #require(try await store.nextPending(at: .now, permit: permit))
        let first = try sourceRecord(item: "batch-first")
        let firstAnalysis = try SourceAnalysis(source: first, detectorVersion: "fixture", detections: [])
        _ = try await store.commit(firstAnalysis, payloads: [], permit: permit)
        #expect(try await store.queueStatistics().count == 1)
        let documentID = UUID()
        #expect(try await store.checkpoint(documentID: documentID) == nil)
        // Retrying a partially processed batch sees the durable source receipt.
        #expect(try await store.commit(firstAnalysis, payloads: [], permit: permit).outcome == .replay)
        let last = try sourceRecord(item: "batch-last")
        _ = try await store.commit(SourceAnalysis(source: last, detectorVersion: "fixture", detections: []), payloads: [], permit: permit)
        let checkpoint = SourceCheckpoint(capabilityID: UUID(), sourceDocumentID: documentID,
            revision: last.revision, byteOffset: 500)
        try await store.completeCapture(capture, checkpoints: [checkpoint], permit: permit)
        #expect(try await store.queueStatistics().count == 0)
        #expect(try await store.checkpoint(documentID: documentID)?.byteOffset == 500)
        #expect(await store.snapshot().analysisReceipts.count == 2)
        try await store.close()
    }

    @Test func failedFinalTransactionLeavesQueueAndCheckpointUnadvanced() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-completion-rollback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto, failureInjector: { point in
            if point == .beforeProcessingCommit { throw StorageError.injectedFailure }
        })
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(Data("synthetic pending capture".utf8), capturedAt: .now, permit: permit)
        let capture = try #require(try await store.nextPending(at: .now, permit: permit))
        let documentID = UUID()
        let checkpoint = SourceCheckpoint(capabilityID: UUID(), sourceDocumentID: documentID,
            revision: try ContentRevision(keyedDigest: Data(repeating: 3, count: 32)), byteOffset: 500)
        await #expect(throws: StorageError.injectedFailure) {
            try await store.completeCapture(capture, checkpoints: [checkpoint], permit: permit)
        }
        #expect(try await store.queueStatistics().count == 1)
        #expect(try await store.checkpoint(documentID: documentID) == nil)
        await store.setMonitoring(enabled: false)
        await #expect(throws: StorageError.monitoringPaused) {
            try await store.completeCapture(capture, checkpoints: [checkpoint], permit: permit)
        }
        try await store.close()
    }
}
