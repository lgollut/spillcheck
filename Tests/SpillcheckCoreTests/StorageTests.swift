import Darwin
import Foundation
import GRDB
import Testing
@_spi(Testing) @testable import SpillcheckCore

private let storageMarker = "SPILLCHECK_STORAGE_SYNTHETIC_PLAINTEXT_42"

private struct AcceptanceReport: Decodable {
    let queueCount: Int
    let valueCount: Int
    let occurrenceCount: Int
    let sourceReceiptCount: Int
    let alertCount: Int
    let notificationIdentifiers: [String]
    let markerCount: Int
    let metadataOnlyCount: Int
    let checkpointOffset: UInt64?
    let replay: Bool?
    let queueInsertion: String?
}

private func runAcceptance(
    directory: URL, operation: String, failpoint: StorageFailpoint? = nil,
    advance: Double = 0, wrongKey: Bool = false
) throws -> (status: Int32, report: AcceptanceReport?) {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [root.appendingPathComponent(".build/out/Products/Debug/spillcheck-storage-acceptance"),
                      root.appendingPathComponent(".build/debug/spillcheck-storage-acceptance")]
    let binary = try #require(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) })
    let process = Process()
    process.executableURL = binary
    process.arguments = ["--directory", directory.path, "--operation", operation, "--advance", String(advance)]
    if let failpoint { process.arguments! += ["--failpoint", failpoint.rawValue] }
    if wrongKey { process.arguments!.append("--wrong-key") }
    let output = Pipe()
    let diagnostics = Pipe()
    process.standardOutput = output
    process.standardError = diagnostics
    try process.run()
    let sentinel = directory.appendingPathComponent("failpoint-reached")
    let deadline = Date().addingTimeInterval(15)
    var killedAtFailpoint = false
    while process.isRunning, Date() < deadline {
        if failpoint != nil, FileManager.default.fileExists(atPath: sentinel.path) {
            #expect(kill(process.processIdentifier, SIGKILL) == 0)
            killedAtFailpoint = true
            break
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning, !killedAtFailpoint { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    _ = diagnostics.fileHandleForReading.readDataToEndOfFile()
    if failpoint != nil {
        #expect(killedAtFailpoint)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
        try? FileManager.default.removeItem(at: sentinel)
    }
    let report = try? JSONDecoder().decode(AcceptanceReport.self, from: bytes)
    return (process.terminationStatus, report)
}

private func temporaryStoreDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-storage-test-\(UUID())", isDirectory: true)
}

private func sealedInventoryPayloads(
    for analysis: SourceAnalysis, using crypto: BackgroundCryptography
) async throws -> [ProtectedPayload] {
    var payloads: [ProtectedPayload] = []
    var references: Set<ProtectedPayloadReference> = []
    for finding in analysis.detections {
        if references.insert(finding.protectedValue).inserted {
            payloads.append(try await crypto.sealInventory(
                Data("SYNTHETIC_VALUE_A".utf8), binding: PayloadBinding(
                    reference: finding.protectedValue, ownerID: finding.protectedValue.id, kind: .value
                )
            ))
        }
        if let excerpt = finding.protectedExcerpt, references.insert(excerpt).inserted {
            payloads.append(try await crypto.sealInventory(
                Data("excerpt=\(storageMarker)".utf8),
                binding: PayloadBinding(reference: excerpt, ownerID: excerpt.id, kind: .excerpt)
            ))
        }
    }
    if let metadata = analysis.source.protectedMetadata, references.insert(metadata).inserted {
        payloads.append(try await crypto.sealInventory(
            Data("path=/synthetic/\(storageMarker);title=\(storageMarker)".utf8),
            binding: PayloadBinding(reference: metadata, ownerID: metadata.id, kind: .sourceMetadata)
        ))
    }
    return payloads
}

private actor BlockingStoreCryptography: BackgroundStoreCryptography {
    nonisolated let manifest: ProtectionManifest
    let delegate: BackgroundCryptography
    var nextBlockedKind: ProtectedPayloadKind?
    var blocked = false
    var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    var releaseContinuation: CheckedContinuation<Void, Never>?

    init(_ delegate: BackgroundCryptography) { self.delegate = delegate; manifest = delegate.manifest }
    func blockNext(_ kind: ProtectedPayloadKind) { nextBlockedKind = kind; blocked = false }
    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
    func sealBackground(_ plaintext: Data, binding: PayloadBinding) async throws -> ProtectedPayload {
        if nextBlockedKind == binding.kind {
            nextBlockedKind = nil
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                blocked = true
                for waiter in blockedWaiters { waiter.resume() }
                blockedWaiters.removeAll()
            }
        }
        return try await delegate.sealBackground(plaintext, binding: binding)
    }
    func openBackground(_ payload: ProtectedPayload, binding: PayloadBinding) async throws -> Data {
        try await delegate.openBackground(payload, binding: binding)
    }
    func revision(canonicalBytes: Data) async throws -> ContentRevision {
        try await delegate.revision(canonicalBytes: canonicalBytes)
    }
}

@Suite("Protected SQLite durability and transactional semantics")
struct StorageTests {
    @Test(arguments: [StorageFailpoint.beforeEnqueueCommit, .afterEnqueueCommit,
                      .beforeProcessingCommit, .afterProcessingCommit])
    func abruptChildSIGKILLBeforeAndAfterDurableTransactions(_ failpoint: StorageFailpoint) throws {
        let directory = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let processing = failpoint == .beforeProcessingCommit || failpoint == .afterProcessingCommit
        if processing {
            #expect(try runAcceptance(directory: directory, operation: "enqueue").status == 0)
        }
        _ = try runAcceptance(directory: directory, operation: processing ? "process" : "enqueue", failpoint: failpoint)
        let recovered = try runAcceptance(directory: directory, operation: "inspect")
        #expect(recovered.status == 0)
        let state = try #require(recovered.report)
        switch failpoint {
        case .beforeEnqueueCommit:
            #expect(state.queueCount == 0)
            #expect(state.valueCount == 0)
            #expect(state.sourceReceiptCount == 0)
            #expect(state.checkpointOffset == nil)
        case .afterEnqueueCommit:
            #expect(state.queueCount == 1)
            let duplicate = try #require(runAcceptance(directory: directory, operation: "enqueue").report)
            #expect(duplicate.queueCount == 1)
            #expect(duplicate.queueInsertion == "alreadyQueued")
            let processed = try #require(runAcceptance(directory: directory, operation: "process").report)
            #expect(processed.queueCount == 0)
            #expect(processed.occurrenceCount == 1)
            #expect(processed.alertCount == 1)
        case .beforeProcessingCommit:
            #expect(state.queueCount == 1)
            #expect(state.valueCount == 0)
            #expect(state.occurrenceCount == 0)
            #expect(state.sourceReceiptCount == 0)
            #expect(state.alertCount == 0)
            #expect(state.checkpointOffset == nil)
            let processed = try #require(runAcceptance(directory: directory, operation: "process", advance: 181).report)
            #expect(processed.queueCount == 0)
            #expect(processed.occurrenceCount == 1)
            #expect(processed.alertCount == 1)
            #expect(processed.checkpointOffset == 100)
        case .afterProcessingCommit:
            #expect(state.queueCount == 0)
            #expect(state.valueCount == 1)
            #expect(state.occurrenceCount == 1)
            #expect(state.sourceReceiptCount == 1)
            #expect(state.alertCount == 1)
            #expect(state.checkpointOffset == 100)
            let replay = try #require(runAcceptance(directory: directory, operation: "process").report)
            #expect(replay.replay == true)
            #expect(replay.occurrenceCount == 1)
            #expect(replay.notificationIdentifiers == state.notificationIdentifiers)
        }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            #expect(try Data(contentsOf: file).range(of: Data("SPILLCHECK_STORAGE_CRASH_SYNTHETIC_SECRET".utf8)) == nil)
        }
    }

    @Test func separateProcessDeletionMarkerAppendReplacementAndForget() throws {
        let directory = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try runAcceptance(directory: directory, operation: "process").status == 0)
        let removed = try #require(runAcceptance(directory: directory, operation: "ack-delete").report)
        #expect(removed.valueCount == 0)
        #expect(removed.occurrenceCount == 0)
        #expect(removed.alertCount == 0)
        #expect(removed.markerCount == 1)
        #expect(removed.sourceReceiptCount == 1)
        #expect(try runAcceptance(directory: directory, operation: "inspect", wrongKey: true).status == 1)
        let replay = try #require(runAcceptance(directory: directory, operation: "process").report)
        #expect(replay.replay == true)
        #expect(replay.valueCount == 0)
        let appended = try #require(runAcceptance(directory: directory, operation: "append").report)
        #expect(appended.metadataOnlyCount == 1)
        #expect(appended.occurrenceCount == 0)
        #expect(appended.sourceReceiptCount == 2)
        #expect(appended.alertCount == 0)
        let replacement = try #require(runAcceptance(directory: directory, operation: "replacement").report)
        #expect(replacement.valueCount == 2)
        #expect(replacement.occurrenceCount == 1)
        #expect(replacement.alertCount == 1)
        #expect(try runAcceptance(directory: directory, operation: "forget").status == 0)
        let oldReplay = try #require(runAcceptance(directory: directory, operation: "append").report)
        #expect(oldReplay.replay == true)
        #expect(oldReplay.markerCount == 0)
        #expect(oldReplay.alertCount == 1)
        let genuinelyNew = try #require(runAcceptance(directory: directory, operation: "new-item").report)
        #expect(genuinelyNew.occurrenceCount == 2)
        #expect(genuinelyNew.alertCount == 2)
        #expect(genuinelyNew.metadataOnlyCount == 1)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: file)
            #expect(bytes.range(of: Data("SPILLCHECK_STORAGE_CRASH_SYNTHETIC_SECRET".utf8)) == nil)
            #expect(bytes.range(of: Data("SPILLCHECK_STORAGE_CRASH_SYNTHETIC_REPLACEMENT".utf8)) == nil)
        }
    }

    @Test func durableEncryptedQueueIdempotencyPermissionsAndConfiguredPragmas() async throws {
        let directory = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let permit = try #require(await store.processingPermit())
        let id = UUID()
        let now = Date()
        #expect(try await store.enqueue(Data(storageMarker.utf8), id: id, capturedAt: now, permit: permit, at: now) == .inserted(id))
        #expect(try await store.enqueue(Data(storageMarker.utf8), id: id, capturedAt: now, permit: permit, at: now) == .alreadyQueued(id))
        #expect(try await store.queueStatistics().count == 1)
        let claim = try #require(try await store.nextPending(at: now, permit: permit))
        #expect(try await store.openCapture(claim) == Data(storageMarker.utf8))
        #expect(try await store.queueStatistics().claimedCount == 1)
        var directoryInfo = stat()
        #expect(lstat(directory.path, &directoryInfo) == 0)
        #expect(directoryInfo.st_mode & 0o777 == 0o700)
        for filename in [ProtectedStore.databaseFilename, ProtectedStore.databaseFilename + "-wal", ProtectedStore.databaseFilename + "-shm"] {
            let file = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: file.path) {
                var info = stat()
                #expect(lstat(file.path, &info) == 0)
                #expect(info.st_mode & 0o777 == 0o600)
                #expect(try Data(contentsOf: file).range(of: Data(storageMarker.utf8)) == nil)
            }
        }
        var configuration = Configuration()
        configuration.readonly = true
        let db = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path, configuration: configuration)
        #expect(try await db.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") } == "wal")
        // synchronous is connection-specific; the write path config is also inspected in source.
        try db.close()
        try await store.close()
        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        #expect(try await reopened.queueStatistics().count == 1)
        let reopenedPermit = try #require(await reopened.processingPermit())
        let recovered = try #require(try await reopened.nextPending(at: now.addingTimeInterval(181), permit: reopenedPermit))
        #expect(recovered.id == id)
        #expect(try await reopened.openCapture(recovered) == Data(storageMarker.utf8))
        try await reopened.close()
    }

    @Test func commitAtomicallyRetainsPayloadsSnapshotReceiptsOutboxCheckpointAndConsumesQueue() async throws {
        let directory = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let permit = try #require(await store.processingPermit())
        let now = Date()
        let captureID = UUID()
        _ = try await store.enqueue(Data(storageMarker.utf8), id: captureID, capturedAt: now, permit: permit, at: now)
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        let input = try analysis()
        let payloads = try await sealedInventoryPayloads(for: input, using: crypto)
        let document = UUID()
        let checkpoint = SourceCheckpoint(capabilityID: UUID(), sourceDocumentID: document, revision: input.revision, byteOffset: 100)
        let transition = try await store.commit(input, payloads: payloads, checkpoint: checkpoint, consuming: capture, permit: permit)
        #expect(transition.alerts.count == 1)
        #expect(try await store.queueStatistics().count == 0)
        #expect(try await store.checkpoint(documentID: document)?.byteOffset == 100)
        #expect(try await store.payload(input.detections[0].protectedValue) != nil)
        let outboxID = try #require(transition.alerts.first?.notificationIdentifier)
        try await store.close()
        let restarted = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let snapshot = await restarted.snapshot()
        #expect(snapshot.occurrences.count == 1)
        #expect(snapshot.alertDecisions.values.first?.notificationIdentifier == outboxID)
        let nextPermit = try #require(await restarted.processingPermit())
        #expect(try await restarted.enqueue(Data(storageMarker.utf8), id: captureID, capturedAt: now, permit: nextPermit) == .alreadyProcessed(captureID))
        #expect(try await restarted.commit(input, payloads: payloads, permit: nextPermit).outcome == .replay)
        #expect(await restarted.snapshot().occurrences.count == 1)
        try await restarted.close()
    }

    @Test func failedProcessingTransactionDoesNotAdvanceAnything() async throws {
        let directory = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto, failureInjector: {
            if $0 == .beforeProcessingCommit { throw StorageError.injectedFailure }
        })
        let permit = try #require(await store.processingPermit())
        let now = Date()
        _ = try await store.enqueue(Data(storageMarker.utf8), capturedAt: now, permit: permit, at: now)
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        let input = try analysis()
        let checkpoint = SourceCheckpoint(capabilityID: UUID(), sourceDocumentID: UUID(), revision: input.revision, byteOffset: 200)
        let payloads = try await sealedInventoryPayloads(for: input, using: crypto)
        await #expect(throws: StorageError.injectedFailure) {
            try await store.commit(input, payloads: payloads, checkpoint: checkpoint, consuming: capture, permit: permit)
        }
        #expect(await store.snapshot().records.isEmpty)
        #expect(await store.snapshot().locationReceipts.isEmpty)
        #expect(await store.snapshot().alertDecisions.isEmpty)
        #expect(try await store.checkpoint(documentID: checkpoint.sourceDocumentID) == nil)
        #expect(try await store.payload(input.detections[0].protectedValue) == nil)
        #expect(try await store.queueStatistics().count == 1)
        try await store.close()
        let restarted = try await ProtectedStore.open(at: directory, cryptography: crypto)
        #expect(await restarted.snapshot().records.isEmpty)
        #expect(try await restarted.queueStatistics().count == 1)
        try await restarted.close()
    }

    @Test func missingPayloadRejectsTransactionAndCheckpoint() async throws {
        let directory = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let input = try analysis()
        let checkpoint = SourceCheckpoint(capabilityID: UUID(), sourceDocumentID: UUID(), revision: input.revision, byteOffset: 300)
        let permit = try #require(await store.processingPermit())
        await #expect(throws: StorageError.payloadMissing) {
            try await store.commit(input, payloads: [], checkpoint: checkpoint, permit: permit)
        }
        #expect(await store.snapshot().records.isEmpty)
        #expect(try await store.checkpoint(documentID: checkpoint.sourceDocumentID) == nil)
        try await store.close()
    }

    @Test func markerOnlyRestartDeletionReplayRicherAppendAndForget() async throws {
        let directory = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let input = try analysis()
        var permit = try #require(await store.processingPermit())
        _ = try await store.commit(input, payloads: sealedInventoryPayloads(for: input, using: crypto), permit: permit)
        try await store.acknowledgeObsolete(fingerprint(), as: .revoked, at: fixtureTime)
        let removal = try await store.removeContent(for: fingerprint())
        #expect(removal.payloadReferences.count == 2)
        #expect(try await store.payload(input.detections[0].protectedValue) == nil)
        try await store.close()
        let probe = try ProtectedStore.probe(at: directory)
        #expect(probe.state == .protectedDataPresent)
        #expect(probe.manifest == crypto.manifest)
        let restarted = try await ProtectedStore.open(at: directory, cryptography: crypto)
        permit = try #require(await restarted.processingPermit())
        #expect(await restarted.snapshot().records.isEmpty)
        #expect(await restarted.snapshot().obsoleteMarkers.count == 1)
        #expect(try await restarted.commit(input, payloads: [], permit: permit).outcome == .replay)
        let source = try sourceRecord(text: "SYNTHETIC_VALUE_A SYNTHETIC_VALUE_A", revision: 2)
        let end = Data("SYNTHETIC_VALUE_A".utf8).count
        let richer = try SourceAnalysis(source: source, detectorVersion: "1", detections: [
            detection(in: source, range: UTF8Range(0, end)),
            detection(in: source, range: UTF8Range(end + 1, source.segments[0].utf8.count)),
        ])
        let observed = try await restarted.commit(richer, payloads: sealedInventoryPayloads(for: richer, using: crypto), permit: permit)
        #expect(observed.insertedObsoleteAppearanceIDs.count == 1)
        #expect(observed.alerts.isEmpty)
        #expect(await restarted.snapshot().records.values.first?.protectedValue == nil)
        #expect(try await restarted.payload(richer.detections[1].protectedValue) == nil)
        try await restarted.forgetObsoleteMarker(fingerprint())
        let new = try analysis(item: "new-after-forget")
        #expect(try await restarted.commit(new, payloads: sealedInventoryPayloads(for: new, using: crypto), permit: permit).alerts.count == 1)
        try await restarted.close()
    }

    @Test func missingOrDifferentKeysNeverCreateAnEmptyStoreOverProtectedData() async throws {
        let directory = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let input = try analysis()
        let permit = try #require(await store.processingPermit())
        _ = try await store.commit(input, payloads: sealedInventoryPayloads(for: input, using: crypto), permit: permit)
        try await store.acknowledgeObsolete(fingerprint(), as: .rotated, at: fixtureTime)
        _ = try await store.removeContent(for: fingerprint())
        try await store.close()
        let differentManifest = try BackgroundCryptography.ephemeralForTesting()
        await #expect(throws: StorageError.manifestMismatch) {
            try await ProtectedStore.open(at: directory, cryptography: differentManifest)
        }
        let wrongKeysSameManifest = try BackgroundCryptography.ephemeralForTesting(manifest: crypto.manifest)
        await #expect(throws: StorageError.protectionUnavailable) {
            try await ProtectedStore.open(at: directory, cryptography: wrongKeysSameManifest)
        }
        let recovered = try await ProtectedStore.open(at: directory, cryptography: crypto)
        #expect(await recovered.snapshot().obsoleteMarkers.count == 1)
        #expect(await recovered.snapshot().locationReceipts.count == 1)
        try await recovered.close()
    }

    @Test func queueBoundsExpiryAndBoundedRetryCreateVisibleGaps() async throws {
        let directory = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let limits = StoreLimits(maxEventBytes: 64, maxQueueBytes: 500, maxQueueAge: 10, maxRetryCount: 1)
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto, limits: limits)
        let permit = try #require(await store.processingPermit())
        let now = Date()
        await #expect(throws: StorageError.captureTooLarge) {
            try await store.enqueue(Data(repeating: 1, count: 65), capturedAt: now, permit: permit, at: now)
        }
        _ = try await store.enqueue(Data(storageMarker.utf8), capturedAt: now, permit: permit, at: now)
        await #expect(throws: StorageError.queueSaturated) {
            try await store.enqueue(Data(storageMarker.utf8), capturedAt: now, permit: permit, at: now)
        }
        let first = try #require(try await store.nextPending(at: now, permit: permit))
        try await store.retry(first, reason: .scannerUnavailable, at: now, permit: permit)
        let second = try #require(try await store.nextPending(at: now.addingTimeInterval(3), permit: permit))
        #expect(second.retryCount == 1)
        try await store.retry(second, reason: .scannerUnavailable, at: now.addingTimeInterval(3), permit: permit)
        #expect(try await store.queueStatistics().count == 0)
        #expect(try await store.coverageGaps().contains { $0.reason == .scannerUnavailable })
        _ = try await store.enqueue(Data(storageMarker.utf8), capturedAt: now, permit: permit, at: now)
        #expect(try await store.nextPending(at: now.addingTimeInterval(11), permit: permit) == nil)
        #expect(try await store.coverageGaps().contains { $0.reason == .queueExpired })
        #expect(try await store.queueStatistics().count == 0)
        try await store.close()
    }

    @Test func pauseDuringEncryptionRejectsLateDurableInsertion() async throws {
        let directory = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let blocking = BlockingStoreCryptography(crypto)
        let store = try await ProtectedStore.open(at: directory, cryptography: blocking)
        let permit = try #require(await store.processingPermit())
        await blocking.blockNext(.queueEvent)
        let enqueue = Task { try await store.enqueue(Data(storageMarker.utf8), capturedAt: Date(), permit: permit) }
        await blocking.waitUntilBlocked()
        await store.setMonitoring(enabled: false)
        await blocking.release()
        await #expect(throws: StorageError.monitoringPaused) { try await enqueue.value }
        #expect(try await store.queueStatistics().count == 0)
        await store.setMonitoring(enabled: true)
        await #expect(throws: StorageError.staleProcessingPermit) {
            try await store.enqueue(Data(storageMarker.utf8), capturedAt: Date(), permit: permit)
        }
        try await store.close()
    }

    @Test func queueAgeMaintenanceWorksWhileIdlePausedAndStopsAfterClose() async throws {
        let directory = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto, limits: StoreLimits(maxQueueAge: 10))
        let permit = try #require(await store.processingPermit())
        let now = Date()
        _ = try await store.enqueue(Data(storageMarker.utf8), capturedAt: now, permit: permit, at: now)
        await store.setMonitoring(enabled: false)
        #expect(await store.processingPermit() == nil)
        #expect(try await store.maintainQueue(at: now.addingTimeInterval(9)) == 0)
        #expect(try await store.maintainQueue(at: now.addingTimeInterval(11)) == 1)
        #expect(try await store.queueStatistics().count == 0)
        #expect(try await store.coverageGaps().contains { $0.reason == .queueExpired })
        #expect(await store.snapshot().records.isEmpty)
        #expect(await store.snapshot().alertDecisions.isEmpty)
        try await store.close()
        await #expect(throws: StorageError.databaseUnavailable) { try await store.maintainQueue(at: Date()) }
    }

    @Test func existingManifestWithMissingMarkerOnlyLedgerIsExplicitCorruption() async throws {
        let directory = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let input = try analysis()
        let permit = try #require(await store.processingPermit())
        _ = try await store.commit(input, payloads: sealedInventoryPayloads(for: input, using: crypto), permit: permit)
        try await store.acknowledgeObsolete(fingerprint(), as: .revoked, at: fixtureTime)
        _ = try await store.removeContent(for: fingerprint())
        try await store.close()
        let db = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path)
        try await db.write { try $0.execute(sql: "DELETE FROM store_state") }
        try db.close()
        #expect(try ProtectedStore.probe(at: directory).state == .protectedDataPresent)
        await #expect(throws: StorageError.corruptProtectedState) {
            try await ProtectedStore.open(at: directory, cryptography: crypto)
        }
        let inspection = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path)
        #expect(try await inspection.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM store_state") } == 0)
        #expect(try await inspection.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM protection_manifest") } == 1)
        try inspection.close()
    }

    @Test func concurrentAcknowledgementAndRemovalAreAppliedAtCommitNotScanTime() async throws {
        let directory = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let blocking = BlockingStoreCryptography(crypto)
        let store = try await ProtectedStore.open(at: directory, cryptography: blocking)
        let input = try analysis()
        var permit = try #require(await store.processingPermit())
        _ = try await store.commit(input, payloads: sealedInventoryPayloads(for: input, using: crypto), permit: permit)
        let next = try analysis(session: "new-conversation", item: "new-item")
        let payloads = try await sealedInventoryPayloads(for: next, using: crypto)
        await blocking.blockNext(.ledgerSnapshot)
        let capturedPermit = permit
        let work = Task { try await store.commit(next, payloads: payloads, permit: capturedPermit) }
        await blocking.waitUntilBlocked()
        try await store.acknowledgeObsolete(fingerprint(), as: .revoked, at: fixtureTime)
        _ = try await store.removeContent(for: fingerprint())
        await blocking.release()
        await #expect(throws: StorageError.staleProcessingPermit) { try await work.value }
        permit = try #require(await store.processingPermit())
        let transition = try await store.commit(next, payloads: payloads, permit: permit)
        #expect(transition.alerts.isEmpty)
        #expect(transition.insertedObsoleteAppearanceIDs.count == 1)
        #expect(await store.snapshot().records.values.first?.protectedValue == nil)
        #expect(try await store.payload(next.detections[0].protectedValue) == nil)
        try await store.close()
    }

    @Test func contentRemovalPurgesAssociatedRetriesAndRejectsOldPermits() async throws {
        let directory = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let input = try analysis()
        let permit = try #require(await store.processingPermit())
        _ = try await store.commit(input, payloads: sealedInventoryPayloads(for: input, using: crypto), permit: permit)
        let now = Date()
        let id = UUID()
        _ = try await store.enqueue(Data("SYNTHETIC_VALUE_A and new=SYNTHETIC_VALUE_B".utf8), id: id, capturedAt: now, permit: permit, at: now)
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        try await store.associateDetectedValues(capture, fingerprints: [fingerprint()], permit: permit)
        _ = try await store.removeContent(for: fingerprint())
        #expect(try await store.queueStatistics().count == 0)
        #expect(try await store.coverageGaps().contains { $0.reason == .captureRejected })
        let nextPermit = try #require(await store.processingPermit())
        #expect(try await store.enqueue(Data(storageMarker.utf8), id: id, capturedAt: now, permit: nextPermit) == .alreadyProcessed(id))
        await #expect(throws: StorageError.staleProcessingPermit) {
            try await store.commit(input, payloads: [], permit: permit)
        }
        #expect(try await store.commit(input, payloads: [], permit: nextPermit).outcome == .replay)
        try await store.close()
    }

    @Test func encryptedMetadataCheckpointsAndAllPrivateFilesExcludeSyntheticPlaintext() async throws {
        let directory = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let source = try sourceRecord(session: storageMarker, item: storageMarker, protectedMetadata: ProtectedPayloadReference())
        let input = try SourceAnalysis(source: source, detectorVersion: "1", detections: [detection(in: source)])
        let checkpoint = SourceCheckpoint(capabilityID: UUID(), sourceDocumentID: UUID(), revision: source.revision, byteOffset: 1024)
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(Data(storageMarker.utf8), capturedAt: Date(), permit: permit)
        _ = try await store.commit(input, payloads: sealedInventoryPayloads(for: input, using: crypto), checkpoint: checkpoint, permit: permit)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                #expect(try Data(contentsOf: file).range(of: Data(storageMarker.utf8)) == nil)
            }
        }
        try await store.close()
    }

    @Test func bookkeepingIsBoundedWithoutTouchingCurrentReceiptsOrInventory() async throws {
        let directory = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let now = Date()
        let permit = try #require(await store.processingPermit())
        let old = now.addingTimeInterval(-ProtectedStore.coverageGapRetention - 60)
        try await store.recordCoverageGap(reason: .sourceChanged, at: old)
        try await store.recordCoverageGap(reason: .queueSaturated, at: now.addingTimeInterval(-2 * 24 * 60 * 60))
        try await store.recordCoverageGap(reason: .budgetExhausted, at: now)
        #expect(try await store.coverageGaps(since: now.addingTimeInterval(-60)).map(\.reason) == [.budgetExhausted])

        let id = UUID()
        _ = try await store.enqueue(Data(storageMarker.utf8), id: id, capturedAt: now, permit: permit, at: now)
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        let input = try analysis(contentTime: now.addingTimeInterval(-30 * 24 * 60 * 60))
        _ = try await store.commit(input, payloads: sealedInventoryPayloads(for: input, using: crypto), consuming: capture, permit: permit)
        #expect(try await store.enqueue(Data(storageMarker.utf8), id: id, capturedAt: now, permit: permit, at: now) == .alreadyProcessed(id))
        #expect(try await store.compactProcessedSources(at: now))
        let compacted = await store.snapshot()
        #expect(compacted.analysisReceipts.isEmpty && compacted.occurrences.count == 1)
        let repeated = try await store.compactProcessedSources(at: now)
        #expect(!repeated)

        let later = now.addingTimeInterval(ProtectedStore.captureReceiptRetention + 60)
        _ = try await store.maintainQueue(at: later)
        #expect(Set(try await store.coverageGaps().map(\.reason)) == [.queueSaturated, .budgetExhausted])
        let laterPermit = try #require(await store.processingPermit())
        #expect(try await store.enqueue(Data(storageMarker.utf8), id: id, capturedAt: later, permit: laterPermit, at: later) == .inserted(id))
        try await store.close()
        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        #expect(await reopened.snapshot().occurrences.count == 1)
        try await reopened.close()
    }
}
