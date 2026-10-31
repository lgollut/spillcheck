import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

/// Characterization of what persistence promises regardless of layout: whatever a mutation leaves in
/// memory is exactly what a fresh process reads back, and the outbox tables mirror the ledger.
@Suite("Close and reopen equivalence")
struct ReopenEquivalenceTests {
    @Test func everyMutationKindSurvivesCloseReopen() async throws {
        let vault = try LedgerVault()
        defer { vault.remove() }
        try await vault.open()
        try await runRichLedgerScript(on: vault, now: Date(), compactingAt: Date().addingTimeInterval(10 * 24 * 60 * 60)) { step in
            let snapshot = await vault.store.snapshot()
            let revision = await vault.store.stateRevision()
            #expect(try outboxRows(in: vault.directory) == expectedOutbox(for: snapshot), "outbox before reopen: \(step)")
            try await vault.close()
            try await vault.open()
            expectSnapshotsEqual(await vault.store.snapshot(), snapshot, step)
            #expect(await vault.store.stateRevision() == revision, "revision: \(step)")
            #expect(try outboxRows(in: vault.directory) == expectedOutbox(for: snapshot), "outbox after reopen: \(step)")
        }
        try await vault.close()
    }
}
