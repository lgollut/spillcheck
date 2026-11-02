import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private let project = "/Users/test/dev/app"

private func jsonLine(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10])
}
private func claudeCall(_ id: String, name: String, input: [String: Any], uuid: String = "call-row") throws -> Data {
    try jsonLine(["type": "assistant", "uuid": uuid, "sessionId": "session", "cwd": project,
        "timestamp": "2026-10-31T12:04:20Z",
        "message": ["role": "assistant", "stop_reason": "tool_use",
                    "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
}
private func claudeResult(_ id: String, text: String, uuid: String = "result-row") throws -> Data {
    try jsonLine(["type": "user", "uuid": uuid, "sessionId": "session", "cwd": project,
        "timestamp": "2026-10-31T12:04:23Z",
        "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": text]]]])
}
private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-tool-call-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
}

@Suite("Tool calls kept with their outputs")
struct ToolCallContextTests {
    @Test(arguments: [
        ("sed -n 1,120p Tests/SpillcheckCoreTests/DetectorTests.swift", "sed", ["Tests/SpillcheckCoreTests/DetectorTests.swift"]),
        ("cat -n .env.local", "cat", [".env.local"]),
        ("head -n 50 Package.swift", "head", ["Package.swift"]),
        ("tail -n +20 -f logs/app.log", "tail", ["logs/app.log"]),
        ("grep -rn \"password\" Sources Tests", "grep", ["Sources", "Tests"]),
        ("grep -e password -A 2 config.yml", "grep", ["config.yml"]),
        ("rg -n TODO -g '*.swift'", "rg", []),
        ("rg --files Sources", "rg", ["Sources"]),
        ("cd Sources && sed -n '1,40p' App.swift", "sed", ["Sources/App.swift"]),
        ("(cd Sources && cat A.swift); cat B.swift", "cat", ["Sources/A.swift", "B.swift"]),
        ("nl -ba a.swift | sed -n '1,50p'", "nl", ["a.swift"]),
        ("git show HEAD~1:Sources/App.swift", "git show", ["HEAD~1:Sources/App.swift"]),
        ("git -C repo log -p -- Sources/App.swift", "git log", ["Sources/App.swift"]),
        ("/bin/zsh -lc \"cat ~/.zshrc\"", "cat", ["~/.zshrc"]),
        ("FOO=1 env BAR=2 cat \"$HOME/.netrc\"", "cat", ["~/.netrc"]),
        ("cat \"$DIR/x.txt\"", "cat", []),
        ("cat $(ls *.env)", "cat", []),
        ("sudo -u root cat /etc/hosts 2>/dev/null", "cat", ["/etc/hosts"]),
        ("base64 -d < key.b64 > key.bin", "base64", ["key.b64"]),
        ("jq -r --arg k token '.[$k]' config.json", "jq", ["config.json"]),
        ("awk -F= '/TOKEN/ {print $2}' .env", "awk", [".env"]),
        ("sed -i '' 's/a/b/' file.txt", "sed", ["file.txt"]),
        ("echo '---' && cat a.txt", "cat", ["a.txt"]),
        ("cat <<'EOF' > notes.txt\nnot-a-path body\nEOF\nsed -n 1p notes.txt", "sed", ["notes.txt"]),
        ("for f in a.txt b.txt; do cat \"$f\"; done", "cat", []),
        ("printenv", "printenv", []),
        ("env", "env", []),
        ("echo $TOKEN", "echo", []),
        ("security find-generic-password -s spillcheck -w", "security find-generic-password", []),
        ("curl -H 'Authorization: Bearer fake-token' https://example.com/api", "curl", []),
        ("swift test --filter DetectorTests 2>&1 | tail -20", "swift test", []),
    ])
    func shellCommandsNameTheirProgramAndOnlyTheFilesTheyPrint(command: String, program: String, paths: [String]) {
        let summary = ShellCommandSummary(command)
        #expect(summary.program == program)
        #expect(summary.paths == paths)
    }

    @Test func argumentVectorsAreSummarizedLikeTheCommandTheyRun() {
        let summary = ShellCommandSummary(arguments: ["/bin/zsh", "-lc", "sed -n 1,20p 'My Notes.md'"])
        #expect(summary.program == "sed" && summary.paths == ["My Notes.md"])
        let direct = ShellCommandSummary(arguments: ["cat", "has space.txt"])
        #expect(direct.program == "cat" && direct.paths == ["has space.txt"])
    }

    @Test func aCallKeepsBoundedNamesAndPathsOnly() throws {
        #expect(RetainedToolCall(tool: "") == nil)
        #expect(RetainedToolCall(tool: String(repeating: "x", count: 129)) == nil)
        let call = try #require(RetainedToolCall(tool: "Bash", program: "bad\u{0}name",
            paths: ["a", "a", "", "line\nbreak"] + (1...20).map { "file\($0)" }))
        #expect(call.program == nil)
        #expect(call.paths.count == RetainedToolCall.maximumPaths)
        #expect(call.paths.prefix(2) == ["a", "file1"])
    }

    @Test func callsReadAsWhatRanAndWhichFiles() throws {
        let sed = try #require(RetainedToolCall(tool: "Bash", program: "sed", paths: ["\(project)/Tests/A.swift"]))
        #expect(sed.method == "sed · Bash")
        #expect(sed.displayPaths(relativeTo: project) == ["Tests/A.swift"])
        #expect(sed.displayPaths(relativeTo: project + "/") == ["Tests/A.swift"])
        let read = try #require(RetainedToolCall(tool: "Read", paths: ["/Users/test/.aws/credentials", "/etc/hosts", project]))
        #expect(read.method == "Read")
        #expect(read.displayPaths(relativeTo: project, home: "/Users/test") == ["~/.aws/credentials", "/etc/hosts", "."])
        let env = try #require(RetainedToolCall(tool: "Bash", program: "printenv"))
        #expect(env.subject == "printenv" && env.method == "Bash")
        let mcp = try #require(RetainedToolCall(tool: "mcp__github__get_file_contents"))
        #expect(mcp.subject == "github · get_file_contents" && mcp.method == nil)
        #expect(RetainedToolCall(tool: "exec_command", program: "cat", paths: ["a"])?.method == "cat · Shell")
    }

    @Test func relativePathsResolveAgainstTheDirectoryTheCallRanIn() {
        #expect(RetainedToolCall.resolve("Tests/A.swift", against: project) == "\(project)/Tests/A.swift")
        #expect(RetainedToolCall.resolve("../other/./x.txt", against: project) == "/Users/test/dev/other/x.txt")
        #expect(RetainedToolCall.resolve("~/.zshrc", against: project) == "~/.zshrc")
        #expect(RetainedToolCall.resolve("HEAD:Sources/A.swift", against: project) == "HEAD:Sources/A.swift")
        #expect(RetainedToolCall.resolve("a.txt", against: nil) == "a.txt")
    }

    @Test func contextsKeptBeforeCallsStillDecode() throws {
        let old = Data("{\"sessionIdentifier\":\"s\",\"projectPath\":\"/p\",\"openingCapability\":\"unverified\"}".utf8)
        let decoded = try JSONDecoder().decode(RetainedSourceContext.self, from: old)
        #expect(decoded.toolCall == nil && decoded.projectPath == "/p")
        let call = try #require(RetainedToolCall(tool: "Read", paths: ["/p/.env"]))
        let kept = decoded.with(toolCall: call)
        #expect(try JSONDecoder().decode(RetainedSourceContext.self, from: JSONEncoder().encode(kept)) == kept)
        #expect(kept.projectPath == decoded.projectPath && kept.openingCapability == decoded.openingCapability)
    }

    @Test func claudeResultsKeepTheCallMadeInTheSamePage() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "test", agentVersion: "2.1.295", allowedTranscriptRoots: [])
        let sed = try claudeResult("toolu_sed", text: "let marker = 1")
        let data = try claudeCall("toolu_sed", name: "Bash",
                                  input: ["command": "sed -n 1,120p Tests/SpillcheckCoreTests/DetectorTests.swift"]) + sed
            + claudeCall("toolu_read", name: "Read", input: ["file_path": "\(project)/.env.local"], uuid: "read-call")
            + claudeResult("toolu_read", text: "API_TOKEN=fake", uuid: "read-result")
            + claudeResult("toolu_elsewhere", text: "orphan", uuid: "orphan-result")
        let batch = try await adapter.importTranscript(data, documentID: UUID(), interface: .t3,
            observedAt: Date(), cryptography: crypto)
        #expect(batch.coverageGaps.isEmpty && batch.sources.count == 3)
        func call(_ id: String) -> RetainedToolCall? {
            batch.sources.first { $0.record.metadata.identity.itemID == "tool:\(id)" }?.context?.toolCall
        }
        #expect(call("toolu_sed") == RetainedToolCall(tool: "Bash", program: "sed",
                                                      paths: ["\(project)/Tests/SpillcheckCoreTests/DetectorTests.swift"]))
        #expect(call("toolu_read") == RetainedToolCall(tool: "Read", paths: ["\(project)/.env.local"]))
        #expect(call("toolu_elsewhere") == nil)
        // The call is context only: the analyzed record is the same without it.
        let alone = try await adapter.importTranscript(sed, documentID: UUID(), interface: .t3,
            observedAt: Date(), cryptography: crypto)
        let withCall = try #require(batch.sources.first { $0.record.metadata.identity.itemID == "tool:toolu_sed" })
        #expect(alone.sources.map(\.record.revision) == [withCall.record.revision])
        #expect(alone.sources.map(\.record.segments) == [withCall.record.segments])
        #expect(alone.sources.first?.context?.toolCall == nil)
    }

    @Test func claudeResultsFindTheirCallInAnEarlierRead() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("session.jsonl")
        try claudeCall("toolu_slow", name: "Bash", input: ["command": "sleep 2; cat config/secrets.yml"]).write(to: path)
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let adapter = try ClaudeAdapter(profileID: "page-test", agentVersion: "2.1.296", allowedTranscriptRoots: [root])
        let first = try await adapter.readIncremental(path: path.path, interface: .t3, cryptography: crypto)
        #expect(first.batch.sources.isEmpty)
        let checkpoint = try #require(first.batch.checkpoints.first)
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd(); try handle.write(contentsOf: claudeResult("toolu_slow", text: "token: fake")); try handle.close()
        let second = try await adapter.readIncremental(path: path.path, interface: .t3, checkpoint: checkpoint, cryptography: crypto)
        let source = try #require(second.batch.sources.first)
        #expect(source.record.metadata.identity.itemID == "tool:toolu_slow")
        #expect(source.context?.toolCall == RetainedToolCall(tool: "Bash", program: "cat", paths: ["\(project)/config/secrets.yml"]))
        #expect(second.batch.coverageGaps.isEmpty)
    }

    @Test func aLaterLookupFindsTheClaudeCallButNeverAResultOrAnotherRow() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("session.jsonl")
        let call = try claudeCall("toolu_cat", name: "Bash", input: ["command": "cat config/.env"])
        // A row that isn't the assistant's call can still hold the same bytes.
        let lookalike = try jsonLine(["type": "user", "uuid": "lookalike", "sessionId": "session",
            "message": ["role": "user", "content": [["type": "text", "id": "toolu_cat", "text": "lookalike"]]]])
        let result = try claudeResult("toolu_cat", text: "TOKEN=fake")
        try (call + lookalike + result).write(to: path)
        let expected = RetainedToolCall(tool: "Bash", program: "cat", paths: ["\(project)/config/.env"])
        let atResult = SourceLocator.transcriptByteOffset(documentID: UUID(), byteOffset: UInt64(call.count + lookalike.count))
        #expect(ToolCallLookup.find(provider: .claudeCode, itemID: "tool:toolu_cat", transcriptPath: path.path,
                                    locator: atResult) == expected)
        // Without an offset, the search starts from the end of the file.
        #expect(ToolCallLookup.find(provider: .claudeCode, itemID: "tool:toolu_cat", transcriptPath: path.path,
                                    locator: .transcript(documentID: UUID(), recordIndex: 2)) == expected)
        #expect(ToolCallLookup.find(provider: .claudeCode, itemID: "tool:toolu_missing", transcriptPath: path.path,
                                    locator: atResult) == nil)
        #expect(ToolCallLookup.find(provider: .claudeCode, itemID: "prompt:row:block:0", transcriptPath: path.path,
                                    locator: atResult) == nil)
        #expect(ToolCallLookup.find(provider: .claudeCode, itemID: "tool:toolu_cat",
                                    transcriptPath: root.appendingPathComponent("gone.jsonl").path, locator: atResult) == nil)
    }

    @Test func codexCommandsKeepTheFilesCodexSawThemRead() throws {
        let read = try codexJSON(["type": "commandExecution", "id": "exec-1", "cwd": "/w/app",
            "command": "/bin/zsh -lc \"sed -n 1,20p README.md\"",
            "commandActions": [["type": "read", "command": "sed -n 1,20p README.md", "name": "README.md", "path": "README.md"],
                               ["type": "search", "command": "rg fake-query src", "query": "fake-query", "path": "src"]]])
        #expect(RetainedToolCall.codex(item: read) == RetainedToolCall(tool: "exec_command", program: "sed",
                                                                       paths: ["/w/app/README.md", "/w/app/src"]))
        let unknown = try codexJSON(["type": "commandExecution", "cwd": "/w/app", "command": "/bin/zsh -lc 'cat .env'",
            "commandActions": [["type": "unknown", "command": "cat .env"]]])
        #expect(RetainedToolCall.codex(item: unknown) == RetainedToolCall(tool: "exec_command", program: "cat", paths: ["/w/app/.env"]))
        let mcp = try codexJSON(["type": "mcpToolCall", "server": "github", "tool": "get_file_contents"])
        #expect(RetainedToolCall.codex(item: mcp)?.subject == "github · get_file_contents")
        #expect(RetainedToolCall.codex(item: try codexJSON(["type": "agentMessage", "text": "x"])) == nil)
    }

    @Test func codexPublicCommandOutputsCarryTheirCall() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let history = CodexTestHistory(), authority = CodexTestAuthority()
        let items = try [
            codexItem("prompt", type: "userMessage", body: ["content": [["type": "text", "text": "fake prompt"]]]),
            codexItem("exec-read", type: "commandExecution", body: ["status": "completed", "exitCode": 0,
                "aggregatedOutput": "API_TOKEN=fake", "cwd": "/w/app", "command": "/bin/zsh -lc 'cat .env.local'",
                "commandActions": [["type": "read", "command": "cat .env.local", "name": ".env.local", "path": ".env.local"]]]),
        ]
        await history.configure("thread", thread: try codexThread("thread"), pages: [.init(data: items)])
        let adapter = try codexTestAdapter(authority: authority, history: history, interface: .standaloneCLI,
            version: "0.162.1", t3Version: nil)
        let batch = try await adapter.normalize(codexPacket(thread: "thread", interface: .standaloneCLI),
            capturedAt: Date(), cryptography: crypto)
        let output = try #require(batch.sources.first { $0.record.metadata.identity.itemID == "exec-read" })
        #expect(output.context?.toolCall == RetainedToolCall(tool: "exec_command", program: "cat", paths: ["/w/app/.env.local"]))
        let prompt = try #require(batch.sources.first { $0.record.metadata.contentType == .userPrompt })
        #expect(prompt.context?.toolCall == nil)
    }

    @Test func codexRolloutOutputsCarryTheCommandsTheirCellRan() async throws {
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "thread", "cli_version": "0.162.1"]],
            ["type": "response_item", "timestamp": "2026-11-02T10:00:00Z", "payload": ["type": "custom_tool_call",
                "call_id": "call_cell", "name": "exec", "input": "await tools.exec_command({cmd: 'sed -n 1p a.txt'})"]],
            ["type": "event_msg", "payload": ["type": "item_completed", "item": ["type": "CommandExecution",
                "id": "exec-1", "cwd": "/w", "command": ["/bin/zsh", "-lc", "sed -n 1p a.txt"],
                "parsed_cmd": [["type": "read", "cmd": "sed -n 1p a.txt", "name": "a.txt", "path": "a.txt"]]]]],
            ["type": "response_item", "timestamp": "2026-11-02T10:00:01Z", "payload": ["type": "custom_tool_call_output",
                "call_id": "call_cell", "output": "TOKEN=fake"]],
            ["type": "response_item", "timestamp": "2026-11-02T10:00:02Z", "payload": ["type": "function_call",
                "call_id": "call_shell", "name": "exec_command", "arguments": "{\"cmd\":\"cat b.txt\",\"workdir\":\"/w\"}"]],
            ["type": "response_item", "timestamp": "2026-11-02T10:00:03Z", "payload": ["type": "function_call_output",
                "call_id": "call_shell", "output": "SECRET=fake"]],
            ["type": "response_item", "timestamp": "2026-11-02T10:00:04Z", "payload": ["type": "custom_tool_call",
                "call_id": "call_patch", "name": "apply_patch",
                "input": "*** Begin Patch\n*** Update File: src/x.swift\n@@\n-a\n+b\n*** End Patch"]],
            ["type": "response_item", "timestamp": "2026-11-02T10:00:05Z", "payload": ["type": "custom_tool_call_output",
                "call_id": "call_patch", "output": "Done fake"]],
        ]
        let data = try rows.reduce(into: Data()) { $0.append(try JSONSerialization.data(withJSONObject: $1)); $0.append(10) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let batch = try await codexTestAdapter(selectedAuthority: .nativeRolloutTranscript).importTranscript(data,
            documentID: UUID(), observedAt: Date(), expectedSessionID: "thread", cryptography: crypto)
        func call(_ id: String) -> RetainedToolCall? {
            batch.sources.first { $0.record.metadata.identity.itemID == id }?.context?.toolCall
        }
        #expect(batch.sources.count == 3)
        #expect(call("tool:call_cell") == RetainedToolCall(tool: "exec", program: "sed", paths: ["/w/a.txt"]))
        #expect(call("tool:call_shell") == RetainedToolCall(tool: "exec_command", program: "cat", paths: ["/w/b.txt"]))
        #expect(call("tool:call_patch") == RetainedToolCall(tool: "apply_patch", paths: ["src/x.swift"]))

        // The same rollout answers a later lookup, by output and by the command's own item.
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("rollout.jsonl")
        try data.write(to: path)
        #expect(ToolCallLookup.find(provider: .codex, itemID: "tool:call_cell", transcriptPath: path.path,
                                    locator: .transcript(documentID: UUID(), recordIndex: 3)) == call("tool:call_cell"))
        #expect(ToolCallLookup.find(provider: .codex, itemID: "exec-1", transcriptPath: path.path, locator: .upstreamItem)
                == RetainedToolCall(tool: "exec_command", program: "sed", paths: ["/w/a.txt"]))
    }
}
