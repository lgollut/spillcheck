import Foundation
import Testing
@testable import SpillcheckCore

@Suite("Viewing selection and source-opening boundaries")
struct InventoryViewingWorkflowTests {
    @Test func selectionBindsExactRetainedFieldsAndDeletionRejectsPriorRequest() throws {
        var ledger = InventoryLedger()
        let metadata = ProtectedPayloadReference()
        let source = try sourceRecord(protectedMetadata: metadata)
        let inserted = try ledger.ingest(SourceAnalysis(source: source, detectorVersion: "1",
            detections: [detection(in: source)]))
        let valueID = try #require(inserted.createdValueIDs.first)
        let occurrenceID = try #require(inserted.insertedOccurrenceIDs.first)
        let value = try InventoryRevealSelection.retainedValue(in: ledger.snapshot, valueID: valueID)
        let context = try InventoryRevealSelection.occurrence(in: ledger.snapshot, occurrenceID: occurrenceID)
        #expect(value.isCurrent(in: ledger.snapshot))
        #expect(context.isCurrent(in: ledger.snapshot))
        #expect(context.fields.count == 2)
        #expect(context.fields.contains(.sourceMetadata(occurrenceID: occurrenceID, reference: metadata)))
        for field in value.fields + context.fields {
            #expect(field.binding.reference == field.reference)
            #expect(field.binding.ownerID == field.reference.id)
            #expect(!field.binding.kind.isBackgroundAccessible)
        }
        _ = try ledger.removeContent(for: fingerprint())
        #expect(!value.isCurrent(in: ledger.snapshot))
        #expect(!context.isCurrent(in: ledger.snapshot))
        #expect(throws: ContractError.unknownValue) {
            try InventoryRevealSelection.retainedValue(in: ledger.snapshot, valueID: valueID)
        }
    }

    @Test func selectionSwitchMaskAndNewRequestRejectLateCompletion() throws {
        var ledger = InventoryLedger()
        let inserted = try ledger.ingest(analysis())
        let valueID = try #require(inserted.createdValueIDs.first)
        let selection = try InventoryRevealSelection.retainedValue(in: ledger.snapshot, valueID: valueID)
        var guardState = InventoryRevealGuard()
        #expect(throws: ViewingAuthorizationError.invalidated) { try guardState.begin(selection) }
        guardState.select(valueID: valueID)
        let first = try guardState.begin(selection)
        #expect(guardState.accepts(first))
        let second = try guardState.begin(selection)
        #expect(!guardState.accepts(first))
        #expect(guardState.accepts(second))
        guardState.invalidate()
        #expect(!guardState.accepts(second))
        let third = try guardState.begin(selection)
        guardState.select(valueID: UUID())
        #expect(!guardState.accepts(third))
        guardState.select(valueID: valueID)
        #expect(!guardState.accepts(third))
    }

    @Test func obsoleteMetadataOnlyAppearancesHaveNoRevealRequest() throws {
        var ledger = InventoryLedger()
        let first = try ledger.ingest(analysis())
        let valueID = try #require(first.createdValueIDs.first)
        try ledger.acknowledgeObsolete(fingerprint(), as: .revoked, at: fixtureTime)
        _ = try ledger.removeContent(for: fingerprint())
        let appeared = try ledger.ingest(analysis(item: "new-metadata-only"))
        #expect(appeared.insertedOccurrenceIDs.isEmpty)
        #expect(appeared.insertedObsoleteAppearanceIDs.count == 1)
        #expect(throws: ContractError.unknownValue) {
            try InventoryRevealSelection.retainedValue(in: ledger.snapshot, valueID: valueID)
        }
        let appearanceID = try #require(appeared.insertedObsoleteAppearanceIDs.first)
        #expect(throws: ContractError.unknownOccurrence) {
            try InventoryRevealSelection.occurrence(in: ledger.snapshot, occurrenceID: appearanceID)
        }
    }

    @Test func occurrenceWithValueRevealsValueAndContextTogether() throws {
        var ledger = InventoryLedger()
        let metadata = ProtectedPayloadReference()
        let source = try sourceRecord(protectedMetadata: metadata)
        let inserted = try ledger.ingest(SourceAnalysis(source: source, detectorVersion: "1", detections: [detection(in: source)]))
        let occurrenceID = try #require(inserted.insertedOccurrenceIDs.first)
        let selection = try InventoryRevealSelection.occurrenceWithValue(in: ledger.snapshot, occurrenceID: occurrenceID)
        #expect(selection.valueID == inserted.createdValueIDs.first)
        #expect(selection.fields.count == 3 && selection.isCurrent(in: ledger.snapshot))
        #expect(selection.fields.contains { if case .value = $0 { true } else { false } })
        _ = try ledger.removeContent(for: fingerprint())
        #expect(throws: ContractError.unknownOccurrence) {
            try InventoryRevealSelection.occurrenceWithValue(in: ledger.snapshot, occurrenceID: occurrenceID)
        }
    }

    @Test func unlocatedSourceCanRevealOnlyItsRetainedMetadata() throws {
        var ledger = InventoryLedger()
        let metadata = ProtectedPayloadReference()
        let source = try sourceRecord(protectedMetadata: metadata)
        let inserted = try ledger.ingest(SourceAnalysis(source: source, detectorVersion: "1", detections: [],
            unlocated: [UnlocatedDetection(evidence: [evidence()], reason: .unavailableRange)]))
        let resultID = try #require(inserted.insertedUnlocatedIDs.first)
        let selection = try InventoryRevealSelection.unlocatedSource(in: ledger.snapshot, resultID: resultID)
        #expect(selection.fields == [.unlocatedSourceMetadata(resultID: resultID, reference: metadata)])
        #expect(selection.fields[0].binding.kind == .sourceMetadata)
        #expect(selection.isCurrent(in: ledger.snapshot))
        #expect(!selection.isCurrent(in: InventorySnapshot()))
        #expect(throws: ContractError.unknownValue) {
            try InventoryRevealSelection.retainedValue(in: ledger.snapshot, valueID: resultID)
        }
    }

    @Test func sourceRoutesUseNativeUUIDAndDistinctArgumentArrays() throws {
        let identifier = UUID()
        let codex = try SessionIdentity(provider: .codex, profileID: "test", sessionID: identifier.uuidString)
        let claude = try SessionIdentity(provider: .claudeCode, profileID: "test", sessionID: identifier.uuidString)
        #expect(try SourceOpeningPlan.codexURL(session: codex).absoluteString
            == "codex://threads/\(identifier.uuidString.lowercased())")
        let executable = URL(fileURLWithPath: "/synthetic/CLI with ' quote/claude")
        let desktop = try SourceOpeningPlan.claudeDesktop(session: claude, executableURL: executable)
        #expect(desktop.arguments == ["--desktop", "--resume", identifier.uuidString.lowercased()])
        #expect(try SourceOpeningPlan.terminalResume(session: claude, executableURL: executable).arguments
            == ["--resume", identifier.uuidString.lowercased()])
        #expect(try SourceOpeningPlan.terminalResume(session: codex, executableURL: executable).arguments
            == ["resume", identifier.uuidString.lowercased()])
        #expect(desktop.displayCommand.contains("'\\''"))
        #expect(throws: SourceOpeningFailure.invalidReference) { try SourceOpeningPlan.codexURL(session: claude) }
    }

    @Test func arbitrarySourceTextCannotBecomeURLPathOrCommandArguments() throws {
        for identifier in ["new", "../../../settings", "--dangerously-skip-permissions", "$(touch /tmp/NO)",
                           "abc\n--resume", "47cca6f4-1966-43e9-b33a-2b45f2a990a0?prompt=send"] {
            let session = try SessionIdentity(provider: .codex, profileID: "test", sessionID: identifier)
            #expect(throws: SourceOpeningFailure.invalidReference) { try SourceOpeningPlan.codexURL(session: session) }
            #expect(throws: SourceOpeningFailure.invalidReference) {
                try SourceOpeningPlan.terminalResume(session: session,
                    executableURL: URL(fileURLWithPath: "/synthetic/codex"))
            }
        }
    }
}
