import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor OpenCountingCryptography: BackgroundStoreCryptography {
    nonisolated let manifest: ProtectionManifest
    private let delegate: BackgroundCryptography
    private(set) var opens = 0

    init(_ delegate: BackgroundCryptography) { self.delegate = delegate; manifest = delegate.manifest }
    func sealBackground(_ plaintext: Data, binding: PayloadBinding) async throws -> ProtectedPayload {
        try await delegate.sealBackground(plaintext, binding: binding)
    }
    func openBackground(_ payload: ProtectedPayload, binding: PayloadBinding) async throws -> Data {
        opens += 1
        return try await delegate.openBackground(payload, binding: binding)
    }
    func revision(canonicalBytes: Data) async throws -> ContentRevision {
        try await delegate.revision(canonicalBytes: canonicalBytes)
    }
}

/// The app refreshes its coverage report every second. Reopening every unchanged omission, gap
/// and work row each time kept the store busy and delayed capture processing.
@Suite("Coverage report refreshes reuse unchanged rows")
struct CoverageReportReuseTests {
    private let profile = "SYNTHETIC_PRIVATE_REUSE_PROFILE"

    @Test func refreshOpensOnlyRowsWhoseCiphertextChanged() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-report-reuse-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = OpenCountingCryptography(try BackgroundCryptography.ephemeralForTesting())
        let store = try await ProtectedStore.open(at: directory, cryptography: crypto)
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let scope = CollectionScope(provider: .codex, profileID: profile, interface: .standaloneCLI, path: .publicHistory)
        func gap(_ index: Int) throws -> CoverageGap {
            let session = try SessionIdentity(provider: .codex, profileID: profile, sessionID: "synthetic-\(index)")
            return CoverageGap(reason: .sourceUnavailable, scope: scope,
                recovery: .init(session: session, parserContract: "reuse-v1"))
        }
        for index in 0..<12 { try await store.recordCoverageGap(gap(index), at: now) }
        let permit = try #require(await store.processingPermit())
        let context = CollectionWorkContext(scope: scope, operation: .liveRead)
        for index in 0..<4 {
            let packet = try CapturePacket(metadata: .init(agent: .codex, profileID: profile),
                eventJSON: JSONEncoder().encode(["page": index]))
            _ = try await store.enqueue(packet.body, capturedAt: now, permit: permit, at: now, workContext: context)
        }

        let first = try await store.coverageReport(endingAt: now)
        #expect(first.omissions.items.count == 12 && first.gapEvents.items.count == 12 && first.work.items.count == 4)
        let opened = await crypto.opens
        let second = try await store.coverageReport(endingAt: now)
        #expect(await crypto.opens == opened)
        #expect(second.hasSameRecords(as: first))

        // A new gap adds rows of its own; only those are opened, and the report includes them.
        try await store.recordCoverageGap(gap(12), at: now)
        let third = try await store.coverageReport(endingAt: now)
        let added = (third.omissions.items.count - second.omissions.items.count)
            + (third.gapEvents.items.count - second.gapEvents.items.count)
        #expect(added > 0)
        #expect(await crypto.opens == opened + added)
        #expect(third.omissions.items.count == 13)
        try await store.close()
    }
}
