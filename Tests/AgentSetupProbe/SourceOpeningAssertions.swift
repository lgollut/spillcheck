import Foundation
import SpillcheckCore

enum SourceOpeningAssertionFailure: Error { case failed(String) }

@MainActor
func sourceOpeningAssertions() async throws -> [String] {
    func require(_ condition: Bool, _ name: String) throws {
        guard condition else { throw SourceOpeningAssertionFailure.failed(name) }
    }
    func reject(_ name: String, _ action: () throws -> Void) throws {
        do { try action() }
        catch { return }
        throw SourceOpeningAssertionFailure.failed(name)
    }
    let defaultHome = URL(fileURLWithPath: "/synthetic-default-home", isDirectory: true)
    let executable = "/usr/bin/true" // Only executable metadata is checked; this is never launched.
    var profile = AgentProfileDraft(provider: .codex, profileID: "first-profile",
        executablePath: executable, homePath: "/synthetic-selected-home")
    let first = SourceOpeningConfiguration(profiles: [.codex: profile], homeURL: defaultHome)
    let originalSession = try SessionIdentity(provider: .codex, profileID: profile.profileID,
        sessionID: UUID().uuidString)
    let controller = SourceOpeningController(configuration: first)
    let firstPlan = try controller.terminalResumePlan(session: originalSession)
    try require(firstPlan.arguments[3] == "/synthetic-selected-home",
        "codex-resume-used-ambient-home")
    let opening = await controller.open(session: originalSession, capability: .unverified, hasRetainedContext: true)
    try require(opening == .fallback(.unverified, retainedContextAvailable: true),
        "codex-profile-bound-resume-promoted-unverified-desktop-opening")
    profile.homePath = "/synthetic-moved-home"
    profile.profileID = "moved-home-profile"
    let moved = SourceOpeningConfiguration(profiles: [.codex: profile], homeURL: defaultHome)
    let movedSession = try SessionIdentity(provider: .codex, profileID: profile.profileID,
        sessionID: UUID().uuidString)
    let movedController = SourceOpeningController(configuration: moved)
    let movedPlan = try movedController.terminalResumePlan(session: movedSession)
    try require(moved != first && movedPlan.arguments[3] == "/synthetic-moved-home",
        "codex-resume-refresh-ignored-profile-home-change")
    try reject("old-codex-finding-resumed-in-moved-home") {
        _ = try movedController.terminalResumePlan(session: originalSession)
    }
    profile.profileID = "replacement-profile"
    let replacement = SourceOpeningConfiguration(profiles: [.codex: profile], homeURL: defaultHome)
    try require(replacement != moved, "codex-resume-refresh-ignored-profile-identity-change")
    try reject("old-codex-finding-resumed-in-replacement-profile") {
        _ = try SourceOpeningController(configuration: replacement).terminalResumePlan(session: originalSession)
    }
    let unconfigured = SourceOpeningConfiguration(profiles: [:], homeURL: defaultHome)
    try require(unconfigured.codexProfile == nil
        && unconfigured.claudeExecutableURL?.path == "/synthetic-default-home/.local/bin/claude",
        "codex-resume-invented-default-profile-or-changed-claude-fallback")
    try reject("unconfigured-codex-finding-resumed-in-default-home") {
        _ = try SourceOpeningController(configuration: unconfigured).terminalResumePlan(session: originalSession)
    }
    let claude = AgentProfileDraft(provider: .claudeCode, profileID: "claude-profile",
        executablePath: executable, homePath: "/synthetic-claude-home")
    let claudeSession = try SessionIdentity(provider: .claudeCode, profileID: claude.profileID,
        sessionID: UUID().uuidString)
    let mixed = SourceOpeningConfiguration(profiles: [.codex: profile, .claudeCode: claude], homeURL: defaultHome)
    let claudePlan = try SourceOpeningController(configuration: mixed).terminalResumePlan(session: claudeSession)
    try require(claudePlan.executableURL.path == executable
        && claudePlan.arguments == ["--resume", claudeSession.sessionID.lowercased()],
        "codex-profile-bound-resume-altered-claude-command")
    return ["codex-resume-binds-current-profile-home-and-rejects-unmatched-or-missing-profile-without-claude-change"]
}
