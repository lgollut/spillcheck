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
        let profile = try CodexResumeProfile(profileID: "test",
            homeURL: URL(fileURLWithPath: "/synthetic/codex-home"), executableURL: executable)
        #expect(try SourceOpeningPlan.terminalResume(session: codex, codexProfile: profile).arguments
            == ["-c", "export CODEX_HOME=\"$1\"; shift; exec \"$@\"", "spillcheck-resume",
                "/synthetic/codex-home", executable.path, "resume", identifier.uuidString.lowercased()])
        #expect(throws: SourceOpeningFailure.invalidReference) {
            try SourceOpeningPlan.terminalResume(session: codex, executableURL: executable)
        }
        let otherProfile = try CodexResumeProfile(profileID: "other",
            homeURL: profile.homeURL, executableURL: executable)
        #expect(throws: SourceOpeningFailure.invalidReference) {
            try SourceOpeningPlan.terminalResume(session: codex, codexProfile: otherProfile)
        }
        #expect(desktop.displayCommand.contains("'\\''"))
        #expect(throws: SourceOpeningFailure.invalidReference) { try SourceOpeningPlan.codexURL(session: claude) }
    }

    @Test func codexResumeUsesExactCanonicalHomeAndQuotesAllShellArguments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-resume-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let home = root.appendingPathComponent("home 'quote' $(exit 41); exit 42", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("chosen-home", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home)
        let executable = root.appendingPathComponent("fake= 'codex' $(exit 43)")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$CODEX_HOME\" \"$@\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let profile = try CodexResumeProfile(profileID: "owned-fake-profile", homeURL: alias, executableURL: executable)
        let reader = try CodexHistoryClientConfiguration(executableURL: executable, codexHomeURL: alias,
            workingDirectoryURL: root)
        #expect(profile.homeURL == reader.codexHomeURL)
        let session = try SessionIdentity(provider: .codex, profileID: profile.profileID, sessionID: UUID().uuidString)
        let plan = try SourceOpeningPlan.terminalResume(session: session, codexProfile: profile)
        for copiedCommand in [false, true] {
            let process = Process(), output = Pipe()
            process.executableURL = copiedCommand ? URL(fileURLWithPath: "/bin/sh") : plan.executableURL
            process.arguments = copiedCommand ? ["-c", plan.displayCommand] : plan.arguments
            process.environment = ["PATH": "/usr/bin:/bin", "CODEX_HOME": "/wrong-ambient-home"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(text == "\(profile.homeURL.path)\nresume\n\(session.sessionID.lowercased())\n")
        }
    }

    @Test func arbitrarySourceTextCannotBecomeURLPathOrCommandArguments() throws {
        let profile = try CodexResumeProfile(profileID: "test",
            homeURL: URL(fileURLWithPath: "/synthetic/codex-home"),
            executableURL: URL(fileURLWithPath: "/synthetic/codex"))
        for identifier in ["new", "../../../settings", "--dangerously-skip-permissions", "$(touch /tmp/NO)",
                           "abc\n--resume", "47cca6f4-1966-43e9-b33a-2b45f2a990a0?prompt=send"] {
            let session = try SessionIdentity(provider: .codex, profileID: "test", sessionID: identifier)
            #expect(throws: SourceOpeningFailure.invalidReference) { try SourceOpeningPlan.codexURL(session: session) }
            #expect(throws: SourceOpeningFailure.invalidReference) {
                try SourceOpeningPlan.terminalResume(session: session,
                    codexProfile: profile)
            }
        }
    }
}
