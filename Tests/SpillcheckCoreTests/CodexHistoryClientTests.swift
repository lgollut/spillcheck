import Darwin
import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

@Suite("Codex passive process bounds", .serialized)
struct CodexHistoryClientTests {
    private func fixture(_ mode: String, timeout: TimeInterval = 5, maximumBytes: Int = 1024, configuredVersion: String = "0.161.0") throws -> (CodexAppServerHistoryClient, URL) {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("spillcheck-codex-process-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let resources = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        let executable = directory.appendingPathComponent("passive-fixture")
        compiler.arguments = [resources.appendingPathComponent("Codex/passive_fixture.c").path, "-o", executable.path]
        compiler.standardOutput = FileHandle.nullDevice; compiler.standardError = FileHandle.nullDevice
        try compiler.run(); compiler.waitUntilExit()
        #expect(compiler.terminationStatus == 0)
        let signer = Process(); signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", executable.path]
        signer.standardOutput = FileHandle.nullDevice; signer.standardError = FileHandle.nullDevice
        try signer.run(); signer.waitUntilExit()
        #expect(signer.terminationStatus == 0)
        let work = directory.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(mode.utf8).write(to: work.appendingPathComponent("mode"))
        let home = directory.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return (CodexAppServerHistoryClient(configuration: try .init(executableURL: executable, codexHomeURL: home,
            workingDirectoryURL: work, agentVersion: configuredVersion, requestTimeout: timeout, maximumResponseBytes: maximumBytes)), directory)
    }
    private func exited(_ directory: URL) throws -> Bool {
        let text = try String(contentsOf: directory.appendingPathComponent("work/server.pid"), encoding: .utf8)
        let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        return kill(pid, 0) == -1 && errno == ESRCH
    }
    @Test func actualChildDeniesNetworkAndForkSanitizesEnvironmentAndReapsOnClose() async throws {
        let (client, directory) = try fixture("normal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await client.readThread("synthetic")
        #expect(result.thread["networkDenied"].bool == true && result.thread["forkDenied"].bool == true)
        #expect(result.thread["environmentSanitized"].bool == true)
        await client.close()
        #expect(try exited(directory))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("work").path).sorted() == ["empty-ignore", "mode", "server.pid"])
    }
    @Test func closedStreamsAndStubbornOwnedReaderCloseWithinDeadlineAndRemainIdempotent() async throws {
        let (client, directory) = try fixture("closed-streams")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await client.readThread("synthetic")
        #expect(!(try exited(directory)))
        let start = ProcessInfo.processInfo.systemUptime
        await client.close()
        #expect(ProcessInfo.processInfo.systemUptime - start < 0.5)
        #expect(await client.lastShutdownCompletedWithinDeadline == true)
        #expect(try exited(directory))
        let repeatedStart = ProcessInfo.processInfo.systemUptime
        await client.close()
        #expect(ProcessInfo.processInfo.systemUptime - repeatedStart < 0.1)
        #expect(await client.lastShutdownCompletedWithinDeadline == true)
    }
    @Test func unsafeServerRequestsMalformedReportsAndRemoteErrorsAreControlledAndReaped() async throws {
        for (mode, expected) in [("unsafe", CodexHistoryError.unsafeMethod), ("malformed", .malformedResponse), ("remote", .remoteFailure(code: -32001))] {
            let (client, directory) = try fixture(mode)
            defer { try? FileManager.default.removeItem(at: directory) }
            await #expect(throws: expected) { try await client.readThread("synthetic") }
            #expect(try exited(directory))
            await client.close()
        }
    }
    @Test func actualReaderVersionIsObservedAndOperationsAreAssessedSeparately() async throws {
        let (client, directory) = try fixture("new-version", configuredVersion: "0.1.0")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await client.readThread("synthetic")
        let scope = CollectionScope(provider: .codex, profileID: "synthetic", interface: .standaloneCLI, path: .publicHistory)
        #expect(await client.observedReaderVersion == "4.0.0")
        #expect(await client.assessment(scope: scope).usableOperations.isEmpty)
        _ = try await client.listItems(threadID: "synthetic", cursor: nil)
        #expect(await client.assessment(scope: scope).usableOperations == [.liveRead])
        _ = try await client.listThreads(cursor: nil)
        #expect(await client.assessment(scope: scope).usableOperations == [.liveRead, .historicalRead])
        #expect(await client.assessment(scope: scope).acceptanceEvidence == .unverified)
        await client.close()
    }
    @Test func requiredMethodFailureRevokesPriorUsabilityUntilFreshSuccess() async throws {
        let (client, directory) = try fixture("normal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = CollectionScope(provider: .codex, profileID: "synthetic", interface: .standaloneCLI, path: .publicHistory)
        _ = try await client.readThread("synthetic")
        _ = try await client.listItems(threadID: "synthetic", cursor: nil)
        _ = try await client.listThreads(cursor: nil)
        #expect(await client.assessment(scope: scope).usableOperations == [.liveRead, .historicalRead])
        let mode = directory.appendingPathComponent("work/mode")
        try Data("missing-method".utf8).write(to: mode)
        await #expect(throws: CodexHistoryError.missingMethod("thread/items/list")) {
            try await client.listItems(threadID: "synthetic", cursor: nil)
        }
        #expect(await client.assessment(scope: scope).usableOperations.isEmpty)
        #expect(await client.assessment(scope: scope).failures == [.init(reason: .missingMethod, operation: .liveRead)])
        #expect(try exited(directory))
        try Data("normal".utf8).write(to: mode)
        _ = try await client.listItems(threadID: "synthetic", cursor: nil)
        #expect(await client.assessment(scope: scope).usableOperations == [.liveRead, .historicalRead])
        #expect(await client.assessment(scope: scope).failures.isEmpty)
        await client.close()
    }
    @Test func missingTurnTimestampFallbackIsPartialForBothOperationsUntilRestored() async throws {
        let (client, directory) = try fixture("normal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = CollectionScope(provider: .codex, profileID: "synthetic", interface: .standaloneCLI, path: .publicHistory)
        _ = try await client.readThread("synthetic")
        _ = try await client.listItems(threadID: "synthetic", cursor: nil)
        _ = try await client.listThreads(cursor: nil)
        let mode = directory.appendingPathComponent("work/mode")
        try Data("missing-method".utf8).write(to: mode)
        await #expect(throws: CodexHistoryError.missingMethod("thread/turns/list")) {
            try await client.listTurns(threadID: "synthetic", cursor: nil)
        }
        let partial = await client.assessment(scope: scope)
        #expect(partial.usableOperations == [.liveRead, .historicalRead] && partial.status == .partial)
        #expect(Set(partial.failures.compactMap(\.operation)) == [.liveRead, .historicalRead])
        try Data("normal".utf8).write(to: mode)
        _ = try await client.listTurns(threadID: "synthetic", cursor: nil)
        #expect(await client.assessment(scope: scope).status == .compatible)
        await client.close()
    }
    @Test func replacingReaderReapsOnlyItsOwnedProcessAndReassessesActualVersion() async throws {
        let (client, directory) = try fixture("normal")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await client.readThread("synthetic")
        let pidText = try String(contentsOf: directory.appendingPathComponent("work/server.pid"), encoding: .utf8)
        let oldPID = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        let executable = directory.appendingPathComponent("passive-fixture")
        let replacement = directory.appendingPathComponent("replacement")
        try FileManager.default.copyItem(at: executable, to: replacement)
        try Data("new-version".utf8).write(to: directory.appendingPathComponent("work/mode"))
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.moveItem(at: replacement, to: executable)
        #expect(await client.refreshExecutableIfChanged())
        #expect(kill(oldPID, 0) == -1 && errno == ESRCH)
        #expect(await client.observedReaderVersion == nil)
        _ = try await client.readThread("synthetic")
        #expect(await client.observedReaderVersion == "4.0.0")
        #expect(!(await client.refreshExecutableIfChanged()))
        await client.close()
        #expect(try exited(directory))
    }
    @Test func retargetedSelectedSymlinkRecreatesReaderWithoutFreezingOldExecutable() async throws {
        let (unused, directory) = try fixture("normal")
        await unused.close()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldExecutable = directory.appendingPathComponent("passive-fixture")
        let newExecutable = directory.appendingPathComponent("new-fixture")
        try FileManager.default.copyItem(at: oldExecutable, to: newExecutable)
        let selected = directory.appendingPathComponent("selected-reader")
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: oldExecutable)
        let configuration = try CodexHistoryClientConfiguration(executableURL: selected,
            codexHomeURL: directory.appendingPathComponent("home"), workingDirectoryURL: directory.appendingPathComponent("work"), requestTimeout: 5)
        #expect(configuration.executableURL == selected)
        let client = CodexAppServerHistoryClient(configuration: configuration)
        _ = try await client.readThread("synthetic")
        let pidText = try String(contentsOf: directory.appendingPathComponent("work/server.pid"), encoding: .utf8)
        let oldPID = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        try Data("new-version".utf8).write(to: directory.appendingPathComponent("work/mode"))
        try FileManager.default.removeItem(at: selected)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: newExecutable)
        _ = try await client.readThread("synthetic")
        #expect(await client.observedReaderVersion == "4.0.0")
        #expect(kill(oldPID, 0) == -1 && errno == ESRCH)
        await client.close()
    }
    @Test func missingMethodsRejectedParametersAndUnrecognizedExecutablesHaveDistinctFailures() async throws {
        for (mode, expected) in [("missing-method", CodexHistoryError.missingMethod("thread/read")),
                                  ("rejected-parameters", .rejectedParameters("thread/read")),
                                  ("invalid-version", .unrecognizedExecutable)] {
            let (client, directory) = try fixture(mode)
            defer { try? FileManager.default.removeItem(at: directory) }
            await #expect(throws: expected) { try await client.readThread("synthetic") }
            if mode != "invalid-version" { #expect(try exited(directory)) }
            await client.close()
        }
    }
    @Test func byteBudgetTerminatesOversizedResponseWithoutPersistingPayload() async throws {
        let (client, directory) = try fixture("flood", maximumBytes: 512)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await client.readThread("synthetic")
            Issue.record("Oversized response unexpectedly succeeded")
        } catch let failure as CodexHistoryReadFailure {
            #expect(failure.reason == .responseLimitExceeded && failure.bytesRead == 512)
        }
        #expect(try exited(directory))
    }
    @Test func remainingRequestDeadlineAndCancellationTerminateOwnedProcess() async throws {
        let (client, directory) = try fixture("timeout", timeout: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Establish the process before measuring a short request deadline, isolating cold
        // version/startup scheduling. Cold total deadline is covered by the shared actor counter.
        let mode = directory.appendingPathComponent("work/mode")
        try Data("normal".utf8).write(to: mode)
        _ = try await client.readThread("synthetic")
        try Data("timeout".utf8).write(to: mode)
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await client.readThread("synthetic", budget: .init(maximumBytes: 1024, timeout: 0.3))
            Issue.record("Stalled response unexpectedly succeeded")
        } catch let failure as CodexHistoryReadFailure {
            #expect(failure.reason == .timedOut && failure.bytesRead > 0)
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
        #expect(try exited(directory))
        let task = Task { try await client.readThread("synthetic") }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CodexHistoryError.cancelled) { try await task.value }
        #expect(try exited(directory))
        await client.close()
    }
}
