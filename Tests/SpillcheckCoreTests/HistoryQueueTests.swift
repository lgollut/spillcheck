import Foundation
import GRDB
import Testing
@_spi(Testing) @testable import SpillcheckCore

private let historyQueueMarker = "SPILLCHECK_HISTORY_QUEUE_SYNTHETIC_MARKER_42"

private func historyQueueDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("spillcheck-history-queue-\(UUID())").resolvingSymlinksInPath()
}

private func historyQueuePacket(page: Int, profile: String = "history-profile", padding: Int = 0) throws -> CapturePacket {
    try CapturePacket(metadata: CaptureMetadata(agent: .codex, profileID: profile),
        eventJSON: JSONSerialization.data(withJSONObject: [
            "cursor": "\(historyQueueMarker):page=\(page)", "padding": String(repeating: "x", count: padding)
        ], options: [.sortedKeys]))
}

private func historyQueueTime() -> Date {
    Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
}

private func historyQueueCheckpoint(
    crypto: BackgroundCryptography, documentID: UUID = UUID(), offset: UInt64 = 500
) async throws -> SourceCheckpoint {
    let cursor = Data("\(historyQueueMarker):adapter-cursor=\(offset)".utf8)
    let revision = try await crypto.revision(canonicalBytes: cursor)
    return SourceCheckpoint(capabilityID: documentID, sourceDocumentID: documentID,
        revision: revision, byteOffset: offset, adapterState: cursor)
}

private func historyQueueFilesAreProtected(_ directory: URL) throws {
    // A plaintext JSON checkpoint would base64-encode its Data cursor. Check that
    // representation as well as the literal marker in captured events and profiles.
    let patterns = [Data(historyQueueMarker.utf8)] + [500, 800].map {
        Data(Data("\(historyQueueMarker):adapter-cursor=\($0)".utf8).base64EncodedString().utf8)
    }
    let files = try #require(FileManager.default.enumerator(at: directory,
        includingPropertiesForKeys: [.isRegularFileKey]))
    for case let file as URL in files {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        let bytes = try Data(contentsOf: file)
        for pattern in patterns { #expect(bytes.range(of: pattern) == nil) }
    }
}

private func historyQueueAuthorityIDs(_ directory: URL) throws -> [String] {
    var configuration = Configuration()
    configuration.readonly = true
    let database = try DatabaseQueue(path: directory.appendingPathComponent(ProtectedStore.databaseFilename).path,
        configuration: configuration)
    defer { try? database.close() }
    return try database.read { try String.fetchAll($0, sql: "SELECT id FROM collection_authorities ORDER BY id") }
}

/// Holds a real background-encryption boundary so tests observe pause/concurrent completion
/// after preparation starts, without depending on task scheduling delays.
private actor HistoryQueueBlockingCryptography: BackgroundStoreCryptography {
    nonisolated let manifest: ProtectionManifest
    private let delegate: BackgroundCryptography
    private var kind: ProtectedPayloadKind?
    private var gate: CheckedContinuation<Void, Never>?
    private var blocked = false

    init(_ delegate: BackgroundCryptography) { self.delegate = delegate; manifest = delegate.manifest }
    func blockNext(_ kind: ProtectedPayloadKind) { self.kind = kind; blocked = false }
    func isBlocked() -> Bool { blocked }
    func release() { gate?.resume(); gate = nil }

    func sealBackground(_ plaintext: Data, binding: PayloadBinding) async throws -> ProtectedPayload {
        if kind == binding.kind {
            kind = nil
            await withCheckedContinuation { gate = $0; blocked = true }
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

private func historyQueueWaitForBoundary(_ crypto: HistoryQueueBlockingCryptography) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await crypto.isBlocked()), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(await crypto.isBlocked())
}

@Suite("Durable historical continuation and queue fairness")
struct HistoryQueueTests {
    @Test func continuationCheckpointAndProgressRollbackTogetherBeforeCommit() async throws {
        let directory = historyQueueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto, failureInjector: { point in
            if point == .beforeProcessingCommit { throw StorageError.injectedFailure }
        })
        let now = historyQueueTime(), audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let packet = try historyQueuePacket(page: 0), continuation = try historyQueuePacket(page: 1)
        let permit = try #require(await store.processingPermit())
        let id = UUID()
        _ = try await store.enqueue(packet.body, id: id, capturedAt: now, permit: permit, at: now, historicalAudit: audit)
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        let checkpoint = try await historyQueueCheckpoint(crypto: crypto)
        let progress = HistoricalReadProgress(audit: audit, bytesRead: 321,
            oldestContentTime: now.addingTimeInterval(-60), newestContentTime: now, hasUnreadContent: true)
        let before = try await store.queueStatistics()
        await #expect(throws: StorageError.injectedFailure) {
            try await store.completeCapture(capture, checkpoints: [checkpoint], continuation: continuation,
                historicalProgress: progress, permit: permit, at: now)
        }
        #expect(try await store.queueStatistics() == before)
        #expect(try await store.checkpoint(documentID: checkpoint.sourceDocumentID) == nil)
        #expect(try await store.historicalProgress().isEmpty)
        #expect(try await store.openCapturedWork(capture).body == packet.body)
        try historyQueueFilesAreProtected(directory)
        try await store.close()

        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let recoveredPermit = try #require(await reopened.processingPermit())
        let later = now.addingTimeInterval(181)
        let recovered = try #require(try await reopened.nextPending(at: later, permit: recoveredPermit))
        #expect(recovered.id == id)
        #expect(try await reopened.openCapturedWork(recovered).historicalAudit == audit)
        try await reopened.completeCapture(recovered, checkpoints: [checkpoint], continuation: continuation,
            historicalProgress: progress, permit: recoveredPermit, at: later)
        #expect(try await reopened.checkpoint(documentID: checkpoint.sourceDocumentID) == checkpoint)
        #expect(try await reopened.historicalProgress().first?.progress == progress)
        #expect(try await reopened.queueStatistics().count == 1)
        #expect(try await reopened.enqueue(packet.body, id: id, capturedAt: now,
            permit: recoveredPermit, at: later, historicalAudit: audit) == .alreadyProcessed(id))
        try await reopened.close()
    }

    @Test func restartPreservesAuditWindowContinuationCursorAndProtectedCumulativeProgress() async throws {
        let directory = historyQueueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let now = historyQueueTime(), audit = try HistoricalAuditContext(reason: .resume, endingAt: now)
        let scope = try LiveCaptureScope(startedAt: now, catchupReason: .resume, catchupAuditID: audit.id)
        let packet = try historyQueuePacket(page: 0, profile: historyQueueMarker)
        let next = try historyQueuePacket(page: 1, profile: historyQueueMarker)
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now,
            scope: scope, historicalAudit: audit)
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        let checkpoint = try await historyQueueCheckpoint(crypto: crypto)
        let progress = HistoricalReadProgress(audit: audit, bytesRead: 321,
            oldestContentTime: audit.start.addingTimeInterval(10), newestContentTime: now.addingTimeInterval(-10),
            hasUnreadContent: true)
        try await store.completeCapture(capture, checkpoints: [checkpoint], continuation: next,
            historicalProgress: progress, permit: permit, at: now)
        try historyQueueFilesAreProtected(directory)
        try await store.close()

        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let nextPermit = try #require(await reopened.processingPermit())
        let later = now.addingTimeInterval(60)
        let continued = try #require(try await reopened.nextPending(at: later, permit: nextPermit))
        let work = try await reopened.openCapturedWork(continued)
        #expect(work.body == next.body)
        #expect(work.historicalAudit == audit)
        #expect(work.scope == scope)
        #expect(continued.id != capture.id)
        #expect(continued.expiresAt == capture.expiresAt)
        #expect(try await reopened.checkpoint(documentID: checkpoint.sourceDocumentID) == checkpoint)
        let stored = try #require(try await reopened.historicalProgress().first)
        #expect(stored.provider == .codex)
        #expect(stored.profileID == historyQueueMarker)
        #expect(stored.progress == progress)
        let finalCheckpoint = try await historyQueueCheckpoint(crypto: crypto,
            documentID: checkpoint.sourceDocumentID, offset: 800)
        let final = HistoricalReadProgress(audit: audit, bytesRead: 123,
            oldestContentTime: now.addingTimeInterval(-30), newestContentTime: now, hasUnreadContent: false)
        try await reopened.completeCapture(continued, checkpoints: [finalCheckpoint], historicalProgress: final,
            permit: nextPermit, at: later)
        let accumulated = try #require(try await reopened.historicalProgress().first?.progress)
        #expect(accumulated.audit == audit)
        #expect(accumulated.bytesRead == 444)
        #expect(accumulated.oldestContentTime == progress.oldestContentTime)
        #expect(accumulated.newestContentTime == now)
        #expect(!accumulated.hasUnreadContent)
        #expect(try await reopened.queueStatistics().count == 0)
        #expect(try await reopened.checkpoint(documentID: checkpoint.sourceDocumentID) == finalCheckpoint)
        try historyQueueFilesAreProtected(directory)
        try await reopened.close()
        try historyQueueFilesAreProtected(directory)
    }

    @Test func theSameClaimCannotCommitASecondContinuationOrDoubleCountProgress() async throws {
        let directory = historyQueueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let blocking = HistoryQueueBlockingCryptography(crypto)
        let store = try await ProtectedStore.open(at: directory, cryptography: blocking)
        let now = historyQueueTime(), audit = try HistoricalAuditContext(reason: .firstLaunch, endingAt: now)
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(historyQueuePacket(page: 0).body, capturedAt: now,
            permit: permit, at: now, historicalAudit: audit)
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        let checkpoint = try await historyQueueCheckpoint(crypto: crypto)
        let continuation = try historyQueuePacket(page: 1)
        let progress = HistoricalReadProgress(audit: audit, bytesRead: 100, hasUnreadContent: true)
        await blocking.blockNext(.sourceCheckpoint)
        let first = Task {
            try await store.completeCapture(capture, checkpoints: [checkpoint], continuation: continuation,
                historicalProgress: progress, permit: permit, at: now)
        }
        try await historyQueueWaitForBoundary(blocking)
        let winner = Task {
            try await store.completeCapture(capture, checkpoints: [checkpoint], continuation: continuation,
                historicalProgress: progress, permit: permit, at: now)
        }
        let winnerResult = await winner.result
        await blocking.release()
        try winnerResult.get()
        await #expect(throws: StorageError.staleClaim) { try await first.value }
        #expect(try await store.queueStatistics().count == 1)
        #expect(try await store.historicalProgress().first?.progress.bytesRead == 100)
        #expect(try await store.checkpoint(documentID: checkpoint.sourceDocumentID) == checkpoint)
        try await store.close()
    }

    @Test func continuationReplacesTheCurrentQueueBytesInsteadOfRequiringDoubleCapacity() async throws {
        let directory = historyQueueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let initial = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let now = historyQueueTime(), audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let initialPermit = try #require(await initial.processingPermit())
        _ = try await initial.enqueue(historyQueuePacket(page: 0).body, capturedAt: now,
            permit: initialPermit, at: now, historicalAudit: audit)
        let originalBytes = try await initial.queueStatistics().encryptedBytes
        // Ciphertext JSON escaping can vary slightly between fresh nonces. Leave headroom
        // for one frame while still proving that both frames cannot fit simultaneously.
        let capacity = originalBytes + originalBytes / 2
        try await initial.close()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto,
            limits: StoreLimits(maxQueueBytes: capacity))
        let permit = try #require(await store.processingPermit())
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        try await store.completeCapture(capture, continuation: historyQueuePacket(page: 1), permit: permit, at: now)
        #expect(try await store.queueStatistics().count == 1)
        let bytes = try await store.queueStatistics().encryptedBytes
        #expect(bytes <= capacity)
        #expect(originalBytes + bytes > capacity)
        try await store.close()
    }

    @Test func anOversizedReplacementRollsBackCheckpointProgressAndQueueConsumption() async throws {
        let directory = historyQueueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto,
            limits: StoreLimits(maxEventBytes: 16 * 1024, maxQueueBytes: 4096))
        let now = historyQueueTime(), audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(historyQueuePacket(page: 0).body, capturedAt: now,
            permit: permit, at: now, historicalAudit: audit)
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        _ = try await store.enqueue(historyQueuePacket(page: 2).body, capturedAt: now, permit: permit, at: now)
        let before = try await store.queueStatistics()
        #expect(before.count == 2)
        let checkpoint = try await historyQueueCheckpoint(crypto: crypto)
        await #expect(throws: StorageError.queueSaturated) {
            try await store.completeCapture(capture, checkpoints: [checkpoint],
                continuation: historyQueuePacket(page: 1, padding: 9000),
                historicalProgress: HistoricalReadProgress(audit: audit, bytesRead: 100, hasUnreadContent: true),
                permit: permit, at: now)
        }
        #expect(try await store.queueStatistics() == before)
        #expect(try await store.checkpoint(documentID: checkpoint.sourceDocumentID) == nil)
        #expect(try await store.historicalProgress().isEmpty)
        try await store.close()
    }

    @Test func pauseRejectsAnAlreadyPreparingContinuationBeforeAnyDurableProgress() async throws {
        let directory = historyQueueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let blocking = HistoryQueueBlockingCryptography(crypto)
        let store = try await ProtectedStore.open(at: directory, cryptography: blocking)
        let now = historyQueueTime(), audit = try HistoricalAuditContext(reason: .resume, endingAt: now)
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(historyQueuePacket(page: 0).body, capturedAt: now,
            permit: permit, at: now, historicalAudit: audit)
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        let checkpoint = try await historyQueueCheckpoint(crypto: crypto)
        let before = try await store.queueStatistics()
        let continuation = try historyQueuePacket(page: 1)
        await blocking.blockNext(.queueEvent)
        let completion = Task {
            try await store.completeCapture(capture, checkpoints: [checkpoint], continuation: continuation,
                historicalProgress: HistoricalReadProgress(audit: audit, bytesRead: 100, hasUnreadContent: true),
                permit: permit, at: now)
        }
        try await historyQueueWaitForBoundary(blocking)
        await store.setMonitoring(enabled: false)
        await blocking.release()
        await #expect(throws: StorageError.monitoringPaused) { try await completion.value }
        #expect(try await store.queueStatistics() == before)
        #expect(try await store.checkpoint(documentID: checkpoint.sourceDocumentID) == nil)
        #expect(try await store.historicalProgress().isEmpty)
        await store.setMonitoring(enabled: true)
        let resumedPermit = try #require(await store.processingPermit())
        await #expect(throws: StorageError.staleProcessingPermit) {
            try await store.completeCapture(capture, continuation: continuation, permit: permit, at: now)
        }
        try await store.completeCapture(capture, checkpoints: [checkpoint], continuation: continuation,
            historicalProgress: HistoricalReadProgress(audit: audit, bytesRead: 100, hasUnreadContent: true),
            permit: resumedPermit, at: now)
        #expect(try await store.queueStatistics().count == 1)
        try await store.close()
    }

    @Test func liveWorkWinsFourClaimsThenHistoryAdvancesWithoutStarvingLiveWork() async throws {
        let directory = historyQueueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let now = historyQueueTime(), audit = try HistoricalAuditContext(reason: .firstLaunch, endingAt: now)
        let permit = try #require(await store.processingPermit())
        let historyID = UUID()
        _ = try await store.enqueue(historyQueuePacket(page: 0).body, id: historyID,
            capturedAt: now.addingTimeInterval(-30), permit: permit, at: now, historicalAudit: audit)
        var liveIDs = Set<UUID>()
        for page in 1...6 {
            let id = UUID(); liveIDs.insert(id)
            _ = try await store.enqueue(historyQueuePacket(page: page).body, id: id,
                capturedAt: now.addingTimeInterval(-10), permit: permit, at: now)
        }
        for _ in 0..<4 {
            let capture = try #require(try await store.nextPending(at: now, permit: permit))
            #expect(liveIDs.remove(capture.id) != nil)
            #expect(try await store.openCapturedWork(capture).historicalAudit == nil)
            try await store.completeCapture(capture, permit: permit, at: now)
        }
        let historical = try #require(try await store.nextPending(at: now, permit: permit))
        #expect(historical.id == historyID)
        #expect(try await store.openCapturedWork(historical).historicalAudit == audit)
        try await store.completeCapture(historical, permit: permit, at: now)
        let nextLive = try #require(try await store.nextPending(at: now, permit: permit))
        #expect(liveIDs.remove(nextLive.id) != nil)
        try await store.completeCapture(nextLive, permit: permit, at: now)
        #expect(try await store.queueStatistics().count == 1)
        try await store.close()
    }

    @Test func continuationCannotShiftAuditIdentityWindowReasonOrProfile() async throws {
        let directory = historyQueueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let now = historyQueueTime(), audit = try HistoricalAuditContext(reason: .restart, endingAt: now)
        let permit = try #require(await store.processingPermit())
        _ = try await store.enqueue(historyQueuePacket(page: 0).body, capturedAt: now,
            permit: permit, at: now, historicalAudit: audit)
        let capture = try #require(try await store.nextPending(at: now, permit: permit))
        let continuation = try historyQueuePacket(page: 1)
        let shiftedAudits = [
            try HistoricalAuditContext(reason: audit.reason, endingAt: audit.end),
            try HistoricalAuditContext(id: audit.id, reason: audit.reason, endingAt: now.addingTimeInterval(60)),
            try HistoricalAuditContext(id: audit.id, reason: .resume, endingAt: audit.end)
        ]
        for shifted in shiftedAudits {
            await #expect(throws: StorageError.invalidPayload) {
                try await store.completeCapture(capture, continuation: continuation,
                    historicalProgress: HistoricalReadProgress(audit: shifted, bytesRead: 10, hasUnreadContent: true),
                    permit: permit, at: now)
            }
        }
        await #expect(throws: StorageError.invalidPayload) {
            try await store.completeCapture(capture, continuation: historyQueuePacket(page: 1, profile: "another-profile"),
                permit: permit, at: now)
        }
        #expect(try await store.queueStatistics().count == 1)
        #expect(try await store.historicalProgress().isEmpty)
        try await store.completeCapture(capture, continuation: continuation,
            historicalProgress: HistoricalReadProgress(audit: audit, bytesRead: 10, hasUnreadContent: true),
            permit: permit, at: now)
        let next = try #require(try await store.nextPending(at: now.addingTimeInterval(60), permit: permit))
        #expect(try await store.openCapturedWork(next).historicalAudit == audit)
        try await store.close()
    }

    @Test func authorityIsFixedAcrossRestartAndItsOpaqueKeyDependsOnProfileAndIdentityKey() async throws {
        let directory = historyQueueDirectory(), otherDirectory = historyQueueDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: otherDirectory)
        }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let permit = try #require(await store.processingPermit())
        let session = try SessionIdentity(provider: .codex, profileID: "\(historyQueueMarker):A", sessionID: historyQueueMarker)
        let otherProfile = try SessionIdentity(provider: .codex, profileID: "\(historyQueueMarker):B", sessionID: historyQueueMarker)
        let choice = try CollectionAuthorityChoice(session: session, adapterVersion: "fixture-1", authorityID: "public-native-items")
        let otherChoice = try CollectionAuthorityChoice(session: otherProfile, adapterVersion: "fixture-1", authorityID: "provider-transcript")
        try await store.selectAuthority(choice, permit: permit)
        try await store.selectAuthority(otherChoice, permit: permit)
        #expect(try await store.authority(for: session) == choice)
        #expect(try await store.authority(for: otherProfile) == otherChoice)
        try historyQueueFilesAreProtected(directory)
        try await store.close()
        let ids = try historyQueueAuthorityIDs(directory)
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        #expect(ids.allSatisfy { UUID(uuidString: $0) != nil })

        let reopened = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let reopenedPermit = try #require(await reopened.processingPermit())
        #expect(try await reopened.authority(for: session) == choice)
        try await reopened.selectAuthority(choice, permit: reopenedPermit)
        let conflict = try CollectionAuthorityChoice(session: session, adapterVersion: "fixture-2", authorityID: "provider-transcript")
        await #expect(throws: StorageError.invalidPayload) {
            try await reopened.selectAuthority(conflict, permit: reopenedPermit)
        }
        #expect(try await reopened.authority(for: session) == choice)
        try await reopened.close()
        #expect(try historyQueueAuthorityIDs(directory) == ids)
        try historyQueueFilesAreProtected(directory)

        let otherKey = try BackgroundCryptography.ephemeralForTesting()
        let independent = try await ProtectedStore.open(at: otherDirectory, cryptography: otherKey)
        let independentPermit = try #require(await independent.processingPermit())
        try await independent.selectAuthority(choice, permit: independentPermit)
        try await independent.close()
        let independentlyKeyed = try historyQueueAuthorityIDs(otherDirectory)
        #expect(independentlyKeyed.count == 1)
        #expect(Set(independentlyKeyed).isDisjoint(with: Set(ids)))
        try historyQueueFilesAreProtected(otherDirectory)
    }
}
