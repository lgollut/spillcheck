import Foundation
import Testing
@testable import SpillcheckCore

private func verifySignedScannerHasNoPlaintextFiles(at directory: URL, marker: Data) throws {
    let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    for case let file as URL in files {
        if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            #expect(try Data(contentsOf: file).range(of: marker) == nil)
        }
    }
}

@Suite("Signed application scanner integration")
struct SignedScannerBundleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPILLCHECK_SIGNED_SCANNER_APP"] != nil))
    func signedExecutableUsesTheSealedPostSigningHashAndPinnedRules() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SPILLCHECK_SIGNED_SCANNER_APP"])
        let app = URL(fileURLWithPath: path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", app.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let entitlements = Process()
        let entitlementOutput = Pipe()
        entitlements.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        entitlements.arguments = ["-d", "--entitlements", ":-", app.appendingPathComponent("Contents/Helpers/betterleaks").path]
        entitlements.standardOutput = entitlementOutput
        try entitlements.run()
        let entitlementBytes = entitlementOutput.fileHandleForReading.readDataToEndOfFile()
        entitlements.waitUntilExit()
        #expect(entitlements.terminationStatus == 0)
        if !entitlementBytes.isEmpty {
            let flags = try #require(try PropertyListSerialization.propertyList(from: entitlementBytes,
                options: [], format: nil) as? [String: Bool])
            #expect(flags.isEmpty)
        }
        let resources = app.appendingPathComponent("Contents/Resources/Scanner")
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf:
            resources.appendingPathComponent("dependencies.json"))) as? [String: Any])
        let hash = try #require(manifest["bundledExecutableSHA256"] as? String)
        #expect(manifest["regexEngine"] as? String == "stdlib")
        #expect(hash != BetterleaksConfiguration.pinnedExecutableSHA256)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-signed-scanner-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = app.appendingPathComponent("Contents/Helpers/betterleaks")
        let rules = resources.appendingPathComponent("betterleaks.toml")
        let token = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
        let source = try sourceRecord(text: token)
        let detector = BetterleaksSecretDetector(configuration: BetterleaksConfiguration(
            executableURL: binary, configurationURL: rules, workingDirectoryURL: directory,
            expectedExecutableSHA256: hash))
        let result = try await detector.scan(source)
        #expect(result.scannerFailure == nil)
        #expect(result.coverageGaps.isEmpty)
        #expect(result.findings.count == 1)
        #expect(result.findings.first?.extraction.valueUTF8 == Data(token.utf8))
        // The original download hash must reject the modified signed bytes.
        let wrongHashDetector = BetterleaksSecretDetector(configuration: BetterleaksConfiguration(
            executableURL: binary, configurationURL: rules, workingDirectoryURL: directory))
        #expect(try await wrongHashDetector.scan(source).scannerFailure == .invalidArtifacts)
        try verifySignedScannerHasNoPlaintextFiles(at: directory, marker: Data(token.utf8))
    }
}
