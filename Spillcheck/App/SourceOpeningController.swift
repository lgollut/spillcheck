import AppKit
import Darwin
import Foundation
import SpillcheckCore

/// The app dispatches only a documented existing-conversation route after an explicit UI action.
@MainActor
final class SourceOpeningController {
    private let codexExecutableURL: URL?
    private let claudeExecutableURL: URL?
    private var operation: Task<SourceOpeningFailure?, Never>?
    private var retiringOperations: [UUID: Task<SourceOpeningFailure?, Never>] = [:]
    private var generation = UUID()

    init(codexExecutableURL: URL? = nil, claudeExecutableURL: URL? = nil) {
        self.codexExecutableURL = codexExecutableURL
        self.claudeExecutableURL = claudeExecutableURL
    }

    func open(session: SessionIdentity, capability: SourceOpeningCapability,
              hasRetainedContext: Bool) async -> SourceOpeningResult {
        cancel()
        let currentGeneration = generation
        let failure: SourceOpeningFailure?
        switch capability {
        case .unavailable: failure = .unavailable
        case .activeSessionRestriction: failure = .activeSession
        case .unverified: failure = .unverified
        case .validatedRoute: failure = nil
        }
        if let failure { return .fallback(failure, retainedContextAvailable: hasRetainedContext) }
        do {
            switch session.provider {
            case .codex:
                let url = try SourceOpeningPlan.codexURL(session: session)
                guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
                    return .fallback(.applicationMissing, retainedContextAvailable: hasRetainedContext)
                }
                return NSWorkspace.shared.open(url) ? .requested
                    : .fallback(.commandFailed, retainedContextAvailable: hasRetainedContext)
            case .claudeCode:
                guard let executable = claudeExecutableURL,
                      FileManager.default.isExecutableFile(atPath: executable.path) else {
                    return .fallback(.applicationMissing, retainedContextAvailable: hasRetainedContext)
                }
                let plan = try SourceOpeningPlan.claudeDesktop(session: session, executableURL: executable)
                let task = Task.detached { await BoundedSourceCommand.run(plan, seconds: 10) }
                operation = task
                let result = await task.value
                guard generation == currentGeneration, !Task.isCancelled else {
                    return .fallback(.cancelled, retainedContextAvailable: hasRetainedContext)
                }
                operation = nil
                return result.map { .fallback($0, retainedContextAvailable: hasRetainedContext) } ?? .requested
            }
        } catch {
            return .fallback((error as? SourceOpeningFailure) ?? .invalidReference,
                retainedContextAvailable: hasRetainedContext)
        }
    }

    /// This method prepares a separate terminal action. It does not start or resume a session.
    func terminalResumePlan(session: SessionIdentity) throws -> SourceCommandPlan {
        guard let executable = session.provider == .codex ? codexExecutableURL : claudeExecutableURL,
              executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SourceOpeningFailure.applicationMissing
        }
        return try SourceOpeningPlan.terminalResume(session: session, executableURL: executable)
    }

    func cancel() {
        generation = UUID()
        if let operation {
            operation.cancel()
            let id = UUID()
            retiringOperations[id] = operation
            Task { [weak self] in
                _ = await operation.value
                self?.retiringOperations.removeValue(forKey: id)
            }
        }
        operation = nil
    }

    func shutdown() async {
        cancel()
        let retiring = Array(retiringOperations.values)
        for task in retiring { _ = await task.value }
        retiringOperations.removeAll()
    }
}

enum BoundedSourceCommand {
    /// Claude's Desktop handoff requires terminal input. This owned PTY is never given a prompt.
    /// Output is drained and discarded, without diagnostics containing source references.
    static func run(_ plan: SourceCommandPlan, seconds: TimeInterval) async -> SourceOpeningFailure? {
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { return .commandFailed }
        let readEnd = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        // Ignore inherited injection/configuration overrides. Authentication stays in provider storage.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home,
            "TERM": "xterm-256color", "LANG": "en_US.UTF-8"]
        process.currentDirectoryURL = URL(fileURLWithPath: home, isDirectory: true)
        defer {
            if process.isRunning {
                process.terminate()
                usleep(50_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            try? terminal.close()
            try? readEnd.close()
        }
        do { try process.run() } catch { return .applicationMissing }
        try? terminal.close()
        guard fcntl(master, F_SETFL, O_NONBLOCK) != -1 else { return .commandFailed }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var buffer = [UInt8](repeating: 0, count: 4096)
        while process.isRunning {
            if Task.isCancelled { return .cancelled }
            if ProcessInfo.processInfo.systemUptime >= deadline { return .timedOut }
            // Read a bounded amount per tick even if a broken provider writes continuously.
            for _ in 0..<16 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, $0.count) }
                if count <= 0 { break }
            }
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return .cancelled }
        }
        process.waitUntilExit()
        return process.terminationReason == .exit && process.terminationStatus == 0 ? nil : .commandFailed
    }
}
