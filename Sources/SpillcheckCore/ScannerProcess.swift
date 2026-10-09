import CryptoKit
import Darwin
import Foundation

extension Process {
    /// Kills the process if it's still running and waits up to `timeout` for its exit to be observed.
    /// `waitUntilExit()` spins the calling thread's run loop, and on a concurrency thread it was seen
    /// waiting forever for a child that had already exited, which stalled the detection pipeline.
    /// Polling `isRunning` against a deadline can't stall.
    public func forceStop(timeout: TimeInterval = 2) {
        guard isRunning else { return }
        kill(processIdentifier, SIGKILL)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while isRunning, ProcessInfo.processInfo.systemUptime < deadline { usleep(5_000) }
    }
}

enum ScannerProcess {
    // No service validation, outbound traffic, listeners or descendant processes.
    static let sandboxProfile = "(version 1)(allow default)(deny network*)(deny process-fork)"
    static let maximumDiagnosticBytes = 64 * 1024

    static func verifyArtifacts(_ configuration: BetterleaksConfiguration) throws -> Set<String> {
        guard regularFile(configuration.executableURL), regularFile(configuration.configurationURL),
              FileManager.default.isExecutableFile(atPath: configuration.executableURL.path) else {
            throw DetectorFailure.unavailable
        }
        guard try sha256(configuration.executableURL) == configuration.expectedExecutableSHA256,
              try sha256(configuration.configurationURL) == BetterleaksConfiguration.pinnedConfigurationSHA256 else {
            throw DetectorFailure.invalidArtifacts
        }
        let data = try Data(contentsOf: configuration.configurationURL)
        guard let text = String(data: data, encoding: .utf8) else { throw DetectorFailure.invalidArtifacts }
        let pattern = try NSRegularExpression(pattern: #"(?m)^id = "([A-Za-z0-9_.-]+)"$"#)
        let ids = Set(pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        })
        guard !ids.isEmpty else { throw DetectorFailure.invalidArtifacts }
        return ids
    }

    private static func regularFile(_ url: URL) -> Bool {
        var info = stat()
        return url.isFileURL && lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    private static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func safeEnvironment(directory: URL) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": directory.path, "TMPDIR": directory.path,
         "LC_ALL": "C", "LANG": "C"]
    }

    static func arguments(configuration: BetterleaksConfiguration, ignoreURL: URL) -> [String] {
        ["-p", sandboxProfile, configuration.executableURL.path, "stdin",
         "--regex-engine=stdlib",
         "--config", configuration.configurationURL.path,
         "--report-format=json", "--report-path=-", "--log-level=fatal", "--no-banner", "--no-color",
         "--exit-code=0", "--ignore-gitleaks-allow", "--max-decode-depth=0", "--max-archive-depth=0",
         "--gitleaks-ignore-path", ignoreURL.path, "--timeout=30", "--validation=false", "--confidence=low"]
    }

    static func prepareWorkingDirectory(_ directory: URL) throws -> URL {
        guard directory.isFileURL else { throw DetectorFailure.invalidArtifacts }
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw DetectorFailure.unavailable }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw DetectorFailure.invalidArtifacts }
        let ignoreURL = directory.appendingPathComponent("empty-ignore")
        let descriptor = open(ignoreURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if descriptor >= 0 { close(descriptor) }
        else if errno != EEXIST { throw DetectorFailure.unavailable }
        guard lstat(ignoreURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size == 0, info.st_mode & 0o077 == 0 else {
            throw DetectorFailure.invalidArtifacts
        }
        return ignoreURL
    }

    static func run(_ input: Data, configuration: BetterleaksConfiguration, timeout: TimeInterval) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw DetectorFailure.networkIsolationUnavailable
        }
        let ignore = try prepareWorkingDirectory(configuration.workingDirectoryURL)
        return try runBounded(input, executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                              arguments: arguments(configuration: configuration, ignoreURL: ignore),
                              directory: configuration.workingDirectoryURL, timeout: timeout,
                              maximumOutputBytes: configuration.maximumReportBytes)
    }

    /// Only controlled arguments reach Process. Input/report remain anonymous pipe bytes.
    static func runBounded(
        _ input: Data, executable: URL, arguments: [String], directory: URL,
        timeout: TimeInterval, maximumOutputBytes: Int
    ) throws -> Data {
        let process = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = safeEnvironment(directory: directory)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let writer = stdin.fileHandleForWriting
        let reader = stdout.fileHandleForReading
        let diagnostics = stderr.fileHandleForReading
        let deadline = ProcessInfo.processInfo.systemUptime + min(30, timeout)
        defer {
            for file in [stdin.fileHandleForReading, writer, reader, stdout.fileHandleForWriting,
                         diagnostics, stderr.fileHandleForWriting] { try? file.close() }
            process.forceStop()
        }
        do { try process.run() } catch { throw DetectorFailure.unavailable }
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let inputFD = writer.fileDescriptor, outputFD = reader.fileDescriptor, errorFD = diagnostics.fileDescriptor
        guard fcntl(inputFD, F_SETNOSIGPIPE, 1) == 0 else { throw DetectorFailure.unavailable }
        for descriptor in [inputFD, outputFD, errorFD] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw DetectorFailure.unavailable }
        }
        var written = 0, diagnosticBytes = 0
        var inputClosed = false, outputClosed = false, errorsClosed = false
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !outputClosed || !errorsClosed || process.isRunning {
            if Task.isCancelled { throw DetectorFailure.cancelled }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw DetectorFailure.timedOut }
            if !inputClosed, written == input.count {
                try? writer.close()
                inputClosed = true
            }
            var descriptors = [pollfd(fd: inputClosed ? -1 : inputFD, events: Int16(POLLOUT), revents: 0),
                               pollfd(fd: outputClosed ? -1 : outputFD, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: errorsClosed ? -1 : errorFD, events: Int16(POLLIN), revents: 0)]
            let remaining = max(1, min(25, Int((deadline - ProcessInfo.processInfo.systemUptime) * 1000)))
            let status = poll(&descriptors, nfds_t(descriptors.count), Int32(remaining))
            if status < 0 { if errno == EINTR { continue }; throw DetectorFailure.unavailable }
            if !inputClosed, descriptors[0].revents & Int16(POLLOUT) != 0 {
                let count = input.withUnsafeBytes { bytes in
                    Darwin.write(inputFD, bytes.baseAddress!.advanced(by: written), min(64 * 1024, input.count - written))
                }
                if count > 0 { written += count }
                else if count < 0, errno != EAGAIN, errno != EINTR { inputClosed = true; try? writer.close() }
            }
            for index in 1...2 where descriptors[index].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let descriptor = index == 1 ? outputFD : errorFD
                while true {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
                    if count > 0 {
                        if index == 1 {
                            guard count <= maximumOutputBytes - result.count else { throw DetectorFailure.outputLimitExceeded }
                            result.append(contentsOf: buffer.prefix(count))
                        } else {
                            // Discard diagnostics; never stringify, persist or forward them.
                            diagnosticBytes += count
                            guard diagnosticBytes <= maximumDiagnosticBytes else { throw DetectorFailure.outputLimitExceeded }
                        }
                    } else if count == 0 {
                        if index == 1 { outputClosed = true } else { errorsClosed = true }
                        break
                    } else if errno == EINTR { continue }
                    else if errno == EAGAIN { break }
                    else { throw DetectorFailure.unavailable }
                }
            }
            if !inputClosed, descriptors[0].revents & Int16(POLLHUP | POLLERR) != 0 {
                inputClosed = true
                try? writer.close()
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DetectorFailure.executionFailed(code: process.terminationStatus) }
        guard written == input.count else { throw DetectorFailure.executionFailed(code: -1) }
        return result
    }
}
