import Darwin
import Foundation

/// The call that produced a tool output: the tool, the program a command ran, and the files it named.
/// It says where a value came from, such as a test fixture or a `.env` file, and stays with the
/// appearance's retained context after the conversation is gone.
///
/// Only names and paths are kept, never a command's arguments. An argument can hold a secret, such as
/// a password or a search for a token, and deleting that value's retained content couldn't reach a
/// copy kept here.
public struct RetainedToolCall: Codable, Sendable, Hashable {
    /// The tool as the agent names it, such as `Bash`, `Read`, `exec_command` or `mcp__github__get_issue`.
    public let tool: String
    /// The program a shell command ran, with the subcommand of a tool such as git: `sed`, `git show`.
    public let program: String?
    /// The files or folders the call read, changed or searched, as the agent named them. A relative
    /// path is resolved against the working directory when the agent recorded it.
    public let paths: [String]

    public static let maximumPaths = 8
    static let maximumToolBytes = 128
    static let maximumProgramBytes = 64
    static let maximumPathBytes = 1024

    public init?(tool: String, program: String? = nil, paths: [String] = []) {
        guard Self.acceptable(tool, maximumBytes: Self.maximumToolBytes) else { return nil }
        self.tool = tool
        self.program = program.flatMap { Self.acceptable($0, maximumBytes: Self.maximumProgramBytes) ? $0 : nil }
        var seen = Set<String>(), kept: [String] = []
        for path in paths where Self.acceptable(path, maximumBytes: Self.maximumPathBytes) && seen.insert(path).inserted {
            kept.append(path)
            if kept.count == Self.maximumPaths { break }
        }
        self.paths = kept
    }

    /// The same call with more paths, such as the files read by the commands a code cell ran.
    func adding(program: String?, paths more: [String]) -> RetainedToolCall {
        Self(tool: tool, program: self.program ?? program, paths: paths + more) ?? self
    }

    private static func acceptable(_ text: String, maximumBytes: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= maximumBytes
            && !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}

// MARK: - Presentation

extension RetainedToolCall {
    /// The tool's name for people: an MCP tool as `server · tool`, any Codex shell tool as `Shell`.
    public var toolName: String {
        if tool.hasPrefix("mcp__") {
            let parts = tool.dropFirst("mcp__".count).components(separatedBy: "__").filter { !$0.isEmpty }
            if parts.count >= 2 { return parts.joined(separator: " · ") }
        }
        return Self.codexShellTools.contains(tool) ? "Shell" : tool
    }

    /// How the content was produced, such as `Read` or `sed · Bash`. Nil when the program alone says it.
    public var method: String? {
        if paths.isEmpty { return program == nil ? nil : toolName }
        return program.map { "\($0) · \(toolName)" } ?? toolName
    }

    /// What ran, for a call that named no file: the program, or else the tool.
    public var subject: String { program ?? toolName }

    /// Paths inside the project shown relative to it, and paths in the home folder from `~`.
    public func displayPaths(relativeTo project: String?, home: String? = nil) -> [String] {
        paths.map { path in
            if let project = Self.directory(project) {
                if path == project { return "." }
                if path.hasPrefix(project + "/") { return String(path.dropFirst(project.count + 1)) }
            }
            if let home = Self.directory(home), path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
            return path
        }
    }

    private static func directory(_ path: String?) -> String? {
        guard var path, path.hasPrefix("/") || path.hasPrefix("~/"), path.count > 1 else { return nil }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static let codexShellTools: Set<String> = ["exec_command", "shell", "local_shell", "shell_command", "unified_exec"]
}

// MARK: - Paths

extension RetainedToolCall {
    /// A relative path as an absolute one under the directory the call ran in, when that is known.
    /// A git object name such as `HEAD:Sources/App.swift` stays as written.
    static func resolve(_ path: String, against directory: String?) -> String {
        guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains(":"),
              let directory, directory.hasPrefix("/") else { return path }
        let joined = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(path).standardizedFileURL.path
        return joined.isEmpty ? path : joined
    }

    static func resolve(_ paths: [String], against directory: String?) -> [String] {
        paths.map { resolve($0, against: directory) }
    }
}


// MARK: - Codex

extension RetainedToolCall {
    /// A thread item from Codex's app server: a command, with Codex's own reading of the files it
    /// read, listed or searched, or a tool it called. A search's query is never kept.
    static func codex(item: CodexJSON) -> RetainedToolCall? {
        switch item["type"].string {
        case "commandExecution"?:
            let summary = ShellCommandSummary(item["command"].string ?? "")
            let actions = (item["commandActions"].array ?? []).compactMap { action -> String? in
                ["read", "listFiles", "search"].contains(action["type"].string ?? "") ? action["path"].nonemptyString : nil
            }
            return RetainedToolCall(tool: "exec_command", program: summary.program,
                paths: resolve(actions.isEmpty ? summary.paths : actions, against: item["cwd"].string))
        case "mcpToolCall"?:
            guard let server = item["server"].nonemptyString, let tool = item["tool"].nonemptyString else { return nil }
            return RetainedToolCall(tool: "mcp__\(server)__\(tool)")
        case "dynamicToolCall"?:
            return item["tool"].nonemptyString.flatMap { RetainedToolCall(tool: $0) }
        case "webSearch"?:
            return RetainedToolCall(tool: "web_search")
        default:
            return nil
        }
    }

    /// The files an `apply_patch` input adds, updates, deletes or moves.
    static func patchPaths(_ patch: String) -> [String] {
        patch.split(whereSeparator: \.isNewline).compactMap { line in
            for header in ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "] where line.hasPrefix(header) {
                let path = line.dropFirst(header.count).trimmingCharacters(in: .whitespaces)
                return path.isEmpty ? nil : path
            }
            return nil
        }
    }
}

/// The tool calls in a Codex rollout, by the item ID each output is collected under: `tool:<call id>`
/// for a function's output, and the item's own ID for an item Codex completed. A code cell's input is
/// a script, so its files come from the commands it ran, which complete before the cell's output.
struct CodexToolCallIndex {
    private(set) var calls: [String: RetainedToolCall] = [:]
    private var pending: [String: RetainedToolCall] = [:]
    /// Calls that run commands and are still waiting for their output, oldest first.
    private var running: [String] = []
    private static let maximumRunning = 64
    private static let commandRunners: Set<String> = RetainedToolCall.codexShellTools.union(["exec", "js", "write_stdin"])

    func call(forItem itemID: String) -> RetainedToolCall? { calls[itemID] }

    mutating func observe(_ row: CodexJSON) {
        let payload = row["payload"]
        switch (row["type"].string, payload["type"].string) {
        case ("response_item"?, "function_call"?), ("response_item"?, "custom_tool_call"?), ("response_item"?, "local_shell_call"?):
            guard let id = payload["call_id"].nonemptyString, let call = Self.call(payload) else { return }
            pending[id] = call
            running.removeAll { $0 == id }
            if Self.commandRunners.contains(call.tool) {
                running.append(id)
                if running.count > Self.maximumRunning { pending.removeValue(forKey: running.removeFirst()) }
            }
        case ("response_item"?, "function_call_output"?), ("response_item"?, "custom_tool_call_output"?):
            guard let id = payload["call_id"].nonemptyString else { return }
            running.removeAll { $0 == id }
            if let call = pending.removeValue(forKey: id) { calls["tool:" + id] = call }
        case ("event_msg"?, "item_completed"?):
            let item = payload["item"]
            guard let id = item["id"].nonemptyString, let call = Self.completed(item) else { return }
            calls[id] = call
            for cell in running { pending[cell] = pending[cell]?.adding(program: call.program, paths: call.paths) }
        default:
            break
        }
    }

    /// A call as the model made it. A shell call's arguments hold its command, as text or an argument vector.
    private static func call(_ payload: CodexJSON) -> RetainedToolCall? {
        let name = payload["name"].nonemptyString ?? (payload["type"].string == "local_shell_call" ? "local_shell" : nil)
        guard let name else { return nil }
        var arguments = payload["action"]
        if let text = payload["arguments"].string, let decoded = try? JSONDecoder().decode(CodexJSON.self, from: Data(text.utf8)) {
            arguments = decoded
        }
        if name == "apply_patch" {
            let patch = payload["input"].string ?? arguments["input"].string ?? ""
            return RetainedToolCall(tool: name, paths: RetainedToolCall.patchPaths(patch))
        }
        let summary: ShellCommandSummary?
        if let command = arguments["cmd"].string ?? arguments["command"].string { summary = ShellCommandSummary(command) }
        else if let argv = arguments["command"].array?.compactMap(\.string), !argv.isEmpty { summary = ShellCommandSummary(arguments: argv) }
        else { summary = nil }
        let directory = arguments["workdir"].string ?? arguments["working_directory"].string
        return RetainedToolCall(tool: name, program: summary?.program,
            paths: RetainedToolCall.resolve(summary?.paths ?? [], against: directory))
    }

    /// An item Codex completed: a command, with Codex's own reading of its files, a file change or an MCP call.
    private static func completed(_ item: CodexJSON) -> RetainedToolCall? {
        switch item["type"].string {
        case "CommandExecution"?:
            let summary = ShellCommandSummary(arguments: (item["command"].array ?? []).compactMap(\.string))
            let parsed = (item["parsed_cmd"].array ?? []).compactMap { action -> String? in
                ["read", "list_files", "search"].contains(action["type"].string ?? "") ? action["path"].nonemptyString : nil
            }
            return RetainedToolCall(tool: "exec_command", program: summary.program,
                paths: RetainedToolCall.resolve(parsed.isEmpty ? summary.paths : parsed, against: item["cwd"].string))
        case "FileChange"?:
            return RetainedToolCall(tool: "apply_patch", paths: (item["changes"].object?.keys).map { $0.sorted() } ?? [])
        case "McpToolCall"?:
            guard let server = item["server"].nonemptyString, let tool = item["tool"].nonemptyString else { return nil }
            return RetainedToolCall(tool: "mcp__\(server)__\(tool)")
        default:
            return nil
        }
    }
}

// MARK: - Finding the call later

/// Finds the call behind a tool output collected before calls were kept with it, in the agent's own
/// history, while that history still exists. Nothing found here is stored.
public enum ToolCallLookup {
    /// How far back from a result its call is looked for.
    static let maximumSearchBytes = 32 * 1024 * 1024

    public static func find(provider: AgentProvider, itemID: String, transcriptPath: String,
                            locator: SourceLocator) -> RetainedToolCall? {
        guard provider == .codex || itemID.hasPrefix("tool:"), transcriptPath.hasPrefix("/"),
              transcriptPath.hasSuffix(".jsonl"), let fd = openRegularFile(transcriptPath) else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else { return nil }
        let size = UInt64(info.st_size)
        switch provider {
        case .claudeCode:
            let end: UInt64
            if case .transcriptByteOffset(_, let offset) = locator, offset <= size { end = offset } else { end = size }
            return ClaudeAdapter.findToolCall(id: String(itemID.dropFirst("tool:".count)), fd: fd, before: end,
                maximumBytes: maximumSearchBytes)
        case .codex:
            guard let data = try? claudePread(fd, offset: 0, count: Int(min(size, UInt64(maximumSearchBytes)))) else { return nil }
            return codexCall(itemID, in: data)
        }
    }

    /// Codex writes compact JSON. Only the rows that name the call, and the commands completed while it
    /// ran, are decoded: from the call's first row to its output.
    static func codexCall(_ itemID: String, in data: Data) -> RetainedToolCall? {
        let call = itemID.hasPrefix("tool:") ? String(itemID.dropFirst("tool:".count)) : nil
        let needle = Data((call.map { "\"call_id\":\"\($0)\"" } ?? "\"id\":\"\(itemID)\"").utf8)
        let completed = Data("\"item_completed\"".utf8)
        guard let first = data.range(of: needle) else { return nil }
        let start = data[..<first.lowerBound].lastIndex(of: 10).map { $0 + 1 } ?? data.startIndex
        var index = CodexToolCallIndex()
        for line in data[start...].split(separator: 10) {
            guard line.range(of: needle) != nil || line.range(of: completed) != nil,
                  let row = try? JSONDecoder().decode(CodexJSON.self, from: Data(line)) else { continue }
            index.observe(row)
            if let found = index.call(forItem: itemID) { return found }
        }
        return nil
    }

    /// Opens a file the agent wrote, read-only, without following a link in its last component.
    static func openRegularFile(_ path: String) -> Int32? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
            close(fd)
            return nil
        }
        return fd
    }
}
