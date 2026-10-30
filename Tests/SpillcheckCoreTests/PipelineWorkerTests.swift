import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private struct EmptyBatchNormalizer: CaptureNormalizer {
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        CollectionBatch(sources: [], checkpoints: [])
    }
}

private struct UnusedWorkerDetector: SecretDetector {
    func scan(_ source: SourceRecord) async throws -> DetectorOutput {
        .init(detectorVersion: "worker-fixture", findings: [], unlocated: [])
    }
}

@Suite("Running detection worker")
struct PipelineWorkerTests {
    @Test func queuedCapturesAreProcessedBackToBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-worker-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let permit = try #require(await store.processingPermit())
        let packet = try CapturePacket(metadata: .init(agent: .claudeCode, profileID: "worker-fixture"),
            eventJSON: Data("{}".utf8))
        let now = Date()
        for _ in 0..<40 { _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now) }
        let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: EmptyBatchNormalizer(),
            detector: UnusedWorkerDetector(), detectorVersion: "worker-fixture")
        let started = ContinuousClock.now
        await pipeline.start()
        while try await store.queueStatistics().count > 0, ContinuousClock.now - started < .seconds(20) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let elapsed = ContinuousClock.now - started
        await pipeline.stop()
        #expect(try await store.queueStatistics().count == 0)
        // The worker used to pause 250 ms after every capture, so these forty took at least 10 s.
        #expect(elapsed < .seconds(5), "draining took \(elapsed)")
        try await store.close()
    }
}
