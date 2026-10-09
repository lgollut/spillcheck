import Darwin
import Foundation

public enum CodexHistoryError: Error, Equatable, Sendable {
    case invalidConfiguration, unsupportedVersion, unavailable, timedOut, cancelled
    case responseLimitExceeded, malformedResponse, remoteFailure(code: Int), unsafeMethod
}
/// Failed bounded protocol reads carry counts, never diagnostics or captured content.
public struct CodexHistoryReadFailure: Error, Equatable, Sendable {
    public let reason: CodexHistoryError
    public let bytesRead: Int
    public init(reason: CodexHistoryError, bytesRead: Int) { self.reason = reason; self.bytesRead = bytesRead }
}

/// Transient protocol data. It must be protected before persistence and never logged.
public enum CodexJSON: Codable, Equatable, Sendable {
    case object([String: CodexJSON]), array([CodexJSON]), string(String), bool(Bool), number(Double), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode([String: CodexJSON].self) { self = .object(x) }
        else if let x = try? c.decode([CodexJSON].self) { self = .array(x) }
        else { self = .number(try c.decode(Double.self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .string(let x): try c.encode(x)
        case .bool(let x): try c.encode(x)
        case .number(let x): try c.encode(x)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> CodexJSON { if case .object(let x) = self { return x[key] ?? .null }; return .null }
    public var string: String? { if case .string(let x) = self { return x }; return nil }
    public var array: [CodexJSON]? { if case .array(let x) = self { return x }; return nil }
    public var number: Double? { if case .number(let x) = self { return x }; return nil }
    public var bool: Bool? { if case .bool(let x) = self { return x }; return nil }
    var nonemptyString: String? { string.flatMap { $0.isEmpty ? nil : $0 } }
    var object: [String: CodexJSON]? { if case .object(let x) = self { return x }; return nil }
}

public struct CodexHistoryPage: Sendable {
    public let data: [CodexJSON]
    public let nextCursor: String?
    public let backwardsCursor: String?
    public let bytesRead: Int
    public init(data: [CodexJSON], nextCursor: String? = nil, backwardsCursor: String? = nil, bytesRead: Int = 0) {
        self.data = data; self.nextCursor = nextCursor; self.backwardsCursor = backwardsCursor; self.bytesRead = bytesRead
    }
}

public struct CodexThreadRead: Sendable {
    public let thread: CodexJSON
    public let bytesRead: Int
    public init(thread: CodexJSON, bytesRead: Int = 0) { self.thread = thread; self.bytesRead = bytesRead }
}

public enum CodexHistoryDirection: String, Sendable { case ascending = "asc", descending = "desc" }
public struct CodexRPCBudget: Sendable {
    public let maximumBytes: Int
    public let timeout: TimeInterval
    public init(maximumBytes: Int, timeout: TimeInterval) throws {
        guard maximumBytes > 0, maximumBytes <= 100 * 1024 * 1024, timeout > 0, timeout <= 30 else {
            throw CodexHistoryError.invalidConfiguration
        }
        self.maximumBytes = maximumBytes; self.timeout = timeout
    }
}

public protocol CodexHistoryReading: Sendable {
    func readThread(_ threadID: String) async throws -> CodexThreadRead
    func listThreads(cursor: String?, limit: Int, archived: Bool) async throws -> CodexHistoryPage
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection) async throws -> CodexHistoryPage
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int,
                   direction: CodexHistoryDirection) async throws -> CodexHistoryPage
    func readThread(_ threadID: String, budget: CodexRPCBudget) async throws -> CodexThreadRead
    func listThreads(cursor: String?, limit: Int, archived: Bool, budget: CodexRPCBudget) async throws -> CodexHistoryPage
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection,
                   budget: CodexRPCBudget) async throws -> CodexHistoryPage
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int,
                   direction: CodexHistoryDirection, budget: CodexRPCBudget) async throws -> CodexHistoryPage
}
public extension CodexHistoryReading {
    func readThread(_ id: String, budget: CodexRPCBudget) async throws -> CodexThreadRead {
        let result = try await readThread(id)
        guard result.bytesRead >= 0, result.bytesRead <= budget.maximumBytes else { throw CodexHistoryError.responseLimitExceeded }
        return result
    }
    func listThreads(cursor: String?, limit: Int, archived: Bool, budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        let result = try await listThreads(cursor: cursor, limit: limit, archived: archived)
        guard result.bytesRead >= 0, result.bytesRead <= budget.maximumBytes else { throw CodexHistoryError.responseLimitExceeded }
        return result
    }
    func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection, budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        let result = try await listTurns(threadID: threadID, cursor: cursor, limit: limit, direction: direction)
        guard result.bytesRead >= 0, result.bytesRead <= budget.maximumBytes else { throw CodexHistoryError.responseLimitExceeded }
        return result
    }
    func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int, direction: CodexHistoryDirection, budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        let result = try await listItems(threadID: threadID, turnID: turnID, cursor: cursor, limit: limit, direction: direction)
        guard result.bytesRead >= 0, result.bytesRead <= budget.maximumBytes else { throw CodexHistoryError.responseLimitExceeded }
        return result
    }
}

public struct CodexHistoryClientConfiguration: Sendable {
    public let executableURL: URL
    public let codexHomeURL: URL
    public let workingDirectoryURL: URL
    public let agentVersion: String
    public let requestTimeout: TimeInterval
    public let maximumResponseBytes: Int
    public init(executableURL: URL, codexHomeURL: URL, workingDirectoryURL: URL,
                agentVersion: String = "0.161.0", requestTimeout: TimeInterval = 10,
                maximumResponseBytes: Int = 8 * 1024 * 1024) throws {
        guard [executableURL, codexHomeURL, workingDirectoryURL].allSatisfy({
            $0.isFileURL && $0.path.hasPrefix("/") && !$0.path.utf8.contains(0)
        }), requestTimeout > 0, requestTimeout <= 30, maximumResponseBytes > 0,
        maximumResponseBytes <= 100 * 1024 * 1024 else { throw CodexHistoryError.invalidConfiguration }
        self.executableURL = executableURL; self.codexHomeURL = codexConfiguredURL(codexHomeURL)
        self.workingDirectoryURL = codexConfiguredURL(workingDirectoryURL); self.agentVersion = agentVersion
        self.requestTimeout = requestTimeout; self.maximumResponseBytes = maximumResponseBytes
    }
}

/// Passive local history RPCs only. No subscription, resume, turn start, tools or model requests.
/// A fork-denied, network-denied child owns no persistent service and is stopped on cancellation.
public actor CodexAppServerHistoryClient: CodexHistoryReading {
    public static let sandboxProfile = "(version 1)(allow default)(deny network*)(deny process-fork)"
    private let configuration: CodexHistoryClientConfiguration
    private var server: CodexPassiveProcess?
    public init(configuration: CodexHistoryClientConfiguration) { self.configuration = configuration }
    public func close() { server?.close(); server = nil }

    public func readThread(_ threadID: String) async throws -> CodexThreadRead {
        try await readThread(threadID, budget: configuredBudget())
    }
    public func readThread(_ threadID: String, budget: CodexRPCBudget) async throws -> CodexThreadRead {
        try validate(threadID)
        let (result, count) = try request("thread/read", .object(["threadId": .string(threadID), "includeTurns": .bool(false)]), budget: budget)
        guard result["thread"]["id"].string == threadID else { throw CodexHistoryError.malformedResponse }
        return .init(thread: result["thread"], bytesRead: count)
    }
    public func listThreads(cursor: String?, limit: Int = 64, archived: Bool = false) async throws -> CodexHistoryPage {
        try await listThreads(cursor: cursor, limit: limit, archived: archived, budget: configuredBudget())
    }
    public func listThreads(cursor: String?, limit: Int, archived: Bool, budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        try validatePage(cursor: cursor, limit: limit)
        return try page("thread/list", .object([
            "cursor": cursor.map(CodexJSON.string) ?? .null, "limit": .number(Double(limit)),
            "archived": .bool(archived), "sortKey": .string("updated_at"), "sortDirection": .string("desc"),
            "useStateDbOnly": .bool(true), "sourceKinds": .array(["cli", "exec", "appServer", "subAgent",
                "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther"].map(CodexJSON.string))]), budget: budget)
    }
    public func listTurns(threadID: String, cursor: String?, limit: Int = 64,
                          direction: CodexHistoryDirection = .descending) async throws -> CodexHistoryPage {
        try await listTurns(threadID: threadID, cursor: cursor, limit: limit, direction: direction, budget: configuredBudget())
    }
    public func listTurns(threadID: String, cursor: String?, limit: Int, direction: CodexHistoryDirection, budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        try validate(threadID); try validatePage(cursor: cursor, limit: limit)
        return try page("thread/turns/list", .object(["threadId": .string(threadID),
            "cursor": cursor.map(CodexJSON.string) ?? .null, "limit": .number(Double(limit)),
            "itemsView": .string("full"), "sortDirection": .string(direction.rawValue)]), budget: budget)
    }
    public func listItems(threadID: String, turnID: String? = nil, cursor: String?, limit: Int = 64,
                          direction: CodexHistoryDirection = .ascending) async throws -> CodexHistoryPage {
        try await listItems(threadID: threadID, turnID: turnID, cursor: cursor, limit: limit, direction: direction, budget: configuredBudget())
    }
    public func listItems(threadID: String, turnID: String?, cursor: String?, limit: Int,
                          direction: CodexHistoryDirection, budget: CodexRPCBudget) async throws -> CodexHistoryPage {
        try validate(threadID); if let turnID { try validate(turnID) }; try validatePage(cursor: cursor, limit: limit)
        return try page("thread/items/list", .object(["threadId": .string(threadID),
            "turnId": turnID.map(CodexJSON.string) ?? .null, "cursor": cursor.map(CodexJSON.string) ?? .null,
            "limit": .number(Double(limit)), "sortDirection": .string(direction.rawValue)]), budget: budget)
    }
    private func configuredBudget() throws -> CodexRPCBudget {
        try .init(maximumBytes: configuration.maximumResponseBytes, timeout: configuration.requestTimeout)
    }
    private func page(_ method: String, _ parameters: CodexJSON, budget: CodexRPCBudget) throws -> CodexHistoryPage {
        let (result, count) = try request(method, parameters, budget: budget)
        guard let rows = result["data"].array else { throw CodexHistoryError.malformedResponse }
        for key in ["nextCursor", "backwardsCursor"] {
            if result[key] != .null, result[key].string == nil { throw CodexHistoryError.malformedResponse }
        }
        return .init(data: rows, nextCursor: result["nextCursor"].string,
                     backwardsCursor: result["backwardsCursor"].string, bytesRead: count)
    }
    private func request(_ method: String, _ parameters: CodexJSON, budget: CodexRPCBudget) throws -> (CodexJSON, Int) {
        guard ["thread/read", "thread/list", "thread/turns/list", "thread/items/list"].contains(method) else {
            throw CodexHistoryError.unsafeMethod
        }
        guard configuration.agentVersion == "0.161.0" else { throw CodexHistoryError.unsupportedVersion }
        do {
            let started = ProcessInfo.processInfo.systemUptime
            let accounting = CodexReadAccounting(maximumBytes: min(budget.maximumBytes, configuration.maximumResponseBytes))
            do {
            if server == nil { server = try CodexPassiveProcess(configuration: configuration, budget: budget, accounting: accounting) }
            let remaining = budget.timeout - (ProcessInfo.processInfo.systemUptime - started)
            guard remaining > 0 else { throw CodexHistoryError.timedOut }
            let result = try server!.request(method, parameters, budget: .init(maximumBytes: accounting.maximumBytes,
                timeout: min(remaining, configuration.requestTimeout)), accounting: accounting)
            return (result.0, accounting.bytesRead)
            } catch let error as CodexHistoryError where error == .timedOut || error == .responseLimitExceeded {
                throw CodexHistoryReadFailure(reason: error, bytesRead: accounting.bytesRead)
            }
        } catch {
            close()
            if error is CancellationError { throw CodexHistoryError.cancelled }
            throw error
        }
    }
    private func validate(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 4096, !value.utf8.contains(0) else { throw CodexHistoryError.invalidConfiguration }
    }
    private func validatePage(cursor: String?, limit: Int) throws {
        guard limit > 0, limit <= 256, cursor == nil || cursor!.utf8.count <= 64 * 1024 else { throw CodexHistoryError.invalidConfiguration }
    }
}

private final class CodexReadAccounting {
    let maximumBytes: Int
    var bytesRead = 0
    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }
}
private final class CodexPassiveProcess {
    private let configuration: CodexHistoryClientConfiguration
    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private var pending = Data()
    private var serial = 0
    private var closed = false
    init(configuration: CodexHistoryClientConfiguration, budget: CodexRPCBudget, accounting: CodexReadAccounting) throws {
        self.configuration = configuration
        guard FileManager.default.isExecutableFile(atPath: configuration.executableURL.path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { throw CodexHistoryError.unavailable }
        _ = try ScannerProcess.prepareWorkingDirectory(configuration.workingDirectoryURL)
        let environment = ["PATH": "/usr/bin:/bin", "HOME": configuration.workingDirectoryURL.path,
            "CODEX_HOME": configuration.codexHomeURL.path, "TMPDIR": configuration.workingDirectoryURL.path,
            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        let started = ProcessInfo.processInfo.systemUptime
        let version: Data
        do {
            version = try ScannerProcess.runBounded(Data(), executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                arguments: ["-p", CodexAppServerHistoryClient.sandboxProfile, configuration.executableURL.path, "--version"],
                directory: configuration.workingDirectoryURL, timeout: min(configuration.requestTimeout, budget.timeout), maximumOutputBytes: 1024)
        } catch DetectorFailure.cancelled { throw CodexHistoryError.cancelled }
        catch DetectorFailure.timedOut { throw CodexHistoryError.timedOut }
        catch { throw CodexHistoryError.unavailable }
        guard String(data: version, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "codex-cli 0.161.0" else {
            throw CodexHistoryError.unsupportedVersion
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", CodexAppServerHistoryClient.sandboxProfile, configuration.executableURL.path,
            "app-server", "--stdio", "-c", "analytics.enabled=false", "-c", "otel.exporter=\"none\""]
        process.environment = environment; process.currentDirectoryURL = configuration.workingDirectoryURL
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        do {
            try process.run()
            try? stdin.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
            for fd in [stdin.fileHandleForWriting.fileDescriptor, stdout.fileHandleForReading.fileDescriptor, stderr.fileHandleForReading.fileDescriptor] {
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw CodexHistoryError.unavailable }
            }
            guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw CodexHistoryError.unavailable }
            let remaining = budget.timeout - (ProcessInfo.processInfo.systemUptime - started)
            guard remaining > 0 else { throw CodexHistoryError.timedOut }
            _ = try request("initialize", .object(["clientInfo": .object(["name": .string("spillcheck-passive-history"),
                "version": .string("1")]), "capabilities": .object(["experimentalApi": .bool(true)])]),
                budget: .init(maximumBytes: accounting.maximumBytes, timeout: remaining), accounting: accounting)
            try writeNotification()
        } catch { close(); throw error }
    }
    deinit { close() }
    func close() {
        guard !closed else { return }; closed = true
        for handle in [stdin.fileHandleForReading, stdin.fileHandleForWriting, stdout.fileHandleForReading,
                       stdout.fileHandleForWriting, stderr.fileHandleForReading, stderr.fileHandleForWriting] { try? handle.close() }
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        pending.removeAll(keepingCapacity: false)
    }
    private func writeNotification() throws {
        let bytes = Data("{\"method\":\"initialized\",\"params\":{}}\n".utf8)
        let count = bytes.withUnsafeBytes { Darwin.write(stdin.fileHandleForWriting.fileDescriptor, $0.baseAddress!, $0.count) }
        guard count == bytes.count else { throw CodexHistoryError.unavailable }
    }
    func request(_ method: String, _ parameters: CodexJSON, budget: CodexRPCBudget,
                 accounting: CodexReadAccounting) throws -> (CodexJSON, Int) {
        guard !closed else { throw CodexHistoryError.unavailable }
        serial += 1
        var encoded = try JSONEncoder().encode(CodexJSON.object(["id": .number(Double(serial)),
            "method": .string(method), "params": parameters])); encoded.append(10)
        let deadline = ProcessInfo.processInfo.systemUptime + min(configuration.requestTimeout, budget.timeout)
        var written = 0, readCount = 0, errorCount = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if Task.isCancelled { throw CodexHistoryError.cancelled }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodexHistoryError.timedOut }
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard let row = try? JSONDecoder().decode(CodexJSON.self, from: line) else { throw CodexHistoryError.malformedResponse }
                // An unexpected server request is never answered with an authorization/decision.
                if row["method"].string != nil, row["id"] != .null { throw CodexHistoryError.unsafeMethod }
                guard row["id"].number == Double(serial) else { continue }
                if row["error"] != .null {
                    let code = row["error"]["code"].number ?? 0
                    guard code.isFinite, code >= Double(Int32.min), code <= Double(Int32.max) else { throw CodexHistoryError.malformedResponse }
                    throw CodexHistoryError.remoteFailure(code: Int(code))
                }
                guard row.object?["result"] != nil else { throw CodexHistoryError.malformedResponse }
                return (row["result"], readCount)
            }
            guard accounting.bytesRead < accounting.maximumBytes else { throw CodexHistoryError.responseLimitExceeded }
            guard process.isRunning else { throw CodexHistoryError.unavailable }
            var fds = [pollfd(fd: written == encoded.count ? -1 : stdin.fileHandleForWriting.fileDescriptor, events: Int16(POLLOUT), revents: 0),
                       pollfd(fd: stdout.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: stderr.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)]
            let status = poll(&fds, nfds_t(fds.count), 25)
            if status < 0 { if errno == EINTR { continue }; throw CodexHistoryError.unavailable }
            if fds[0].revents & Int16(POLLOUT) != 0 {
                let n = encoded.withUnsafeBytes { Darwin.write(fds[0].fd, $0.baseAddress!.advanced(by: written), min(64 * 1024, encoded.count - written)) }
                if n > 0 { written += n } else if errno != EAGAIN && errno != EINTR { throw CodexHistoryError.unavailable }
            }
            for index in 1...2 where fds[index].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                while true {
                    let allowedRead = index == 1 ? accounting.maximumBytes - accounting.bytesRead : 64 * 1024 - errorCount
                    if allowedRead <= 0 { break }
                    let n = buffer.withUnsafeMutableBytes { Darwin.read(fds[index].fd, $0.baseAddress!, min($0.count, allowedRead)) }
                    if n > 0 {
                        if index == 1 {
                            accounting.bytesRead += n
                            guard accounting.bytesRead <= accounting.maximumBytes else { throw CodexHistoryError.responseLimitExceeded }
                            readCount += n; pending.append(contentsOf: buffer.prefix(n))
                        } else {
                            errorCount += n
                            guard errorCount <= 64 * 1024 else { throw CodexHistoryError.responseLimitExceeded }
                        }
                    } else if n == 0 { break }
                    else if errno == EINTR { continue }
                    else if errno == EAGAIN { break }
                    else { throw CodexHistoryError.unavailable }
                }
            }
            if fds[0].revents & Int16(POLLHUP | POLLERR) != 0 { throw CodexHistoryError.unavailable }
        }
    }
}

/// Resolve configured root aliases once; untrusted transcript descendants remain O_NOFOLLOW.
func codexConfiguredURL(_ url: URL) -> URL { claudeConfiguredURL(url) }
