import Foundation

/// The one-use setup prompt states its purpose and asks the agent to stop, so the agent doesn't
/// search the workspace for an unexplained marker. It contains no credential, quote, or shell
/// metacharacter, so it can be passed as a single-quoted command argument unchanged.
public enum SetupVerificationPrompt {
    public static let marker = "SPILLCHECK_SETUP_SYNTHETIC_"

    public static func make(id: UUID = UUID()) -> String {
        "Spillcheck connection test \(marker)\(id.uuidString). Reply only with the word Connected. "
            + "Do not read files, run commands, or use tools."
    }
}
