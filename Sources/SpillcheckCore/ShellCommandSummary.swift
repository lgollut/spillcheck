import Foundation

/// The program a shell command ran and the files it printed, read from the command's text alone.
/// Only programs known to print a file's content contribute paths, and only their file operands:
/// a sed script, a grep pattern or an option's value never becomes a path. The command isn't kept.
struct ShellCommandSummary {
    private(set) var paths: [String] = []
    /// The first program that printed a file, else the first that ran, else the first echo.
    var program: String? { reader ?? other ?? weak }
    private var reader: String?
    private var other: String?
    private var weak: String?

    /// Commands longer than this are summarized from their beginning.
    static let maximumCommandLength = 16 * 1024

    init(_ command: String) {
        self.init(command: command, depth: 0)
    }

    /// A command recorded as its argument vector, such as `["/bin/zsh", "-lc", "sed -n 1p a.txt"]`.
    init(arguments: [String]) {
        var directory: String?
        add(ShellCommand(words: arguments.map { ShellWord(text: $0, literal: true) }), directory: &directory, depth: 0)
    }

    private init(command: String, depth: Int) {
        var directories: [String?] = [nil]
        for item in ShellTokenizer.tokenize(String(command.prefix(Self.maximumCommandLength))) {
            switch item {
            case .command(let command):
                var directory = directories[directories.count - 1]
                add(command, directory: &directory, depth: depth)
                directories[directories.count - 1] = directory
            case .openGroup: directories.append(directories[directories.count - 1])
            case .closeGroup: if directories.count > 1 { directories.removeLast() }
            }
        }
    }

    private mutating func add(_ command: ShellCommand, directory: inout String?, depth: Int) {
        var words = command.words[...]
        var readsFiles = true
        // Assignments, keywords and wrappers come before the program they run.
        while let word = words.first {
            if word.isAssignment { words.removeFirst(); continue }
            guard word.literal else { return }
            if Self.compoundKeywords.contains(word.text) { return }
            if Self.keywords.contains(word.text) { words.removeFirst(); continue }
            if let valued = Self.wrappers[word.text] {
                var rest = words.dropFirst()
                while let option = rest.first, option.text.hasPrefix("-") || (word.text == "env" && option.isAssignment) {
                    rest.removeFirst()
                    if valued.contains(option.text) { _ = rest.popFirst() }
                }
                if word.text == "timeout" || word.text == "gtimeout" { _ = rest.popFirst() }
                // Alone, the wrapper is the program, as `env` printing the environment.
                if rest.isEmpty { break }
                if word.text == "xargs" { readsFiles = false }
                words = rest
                continue
            }
            break
        }
        guard let first = words.popFirst(), first.literal, !first.text.isEmpty else { return }
        let name = (first.text as NSString).lastPathComponent
        let arguments = Array(words)
        if Self.shells.contains(name), depth < 2,
           let flag = arguments.firstIndex(where: { $0.text.hasPrefix("-") && !$0.text.hasPrefix("--") && $0.text.contains("c") }),
           flag + 1 < arguments.count {
            merge(ShellCommandSummary(command: arguments[flag + 1].text, depth: depth + 1))
            return
        }
        switch name {
        case "cd", "pushd":
            let target = arguments.first { !$0.text.hasPrefix("-") }
            if let target {
                directory = !target.literal || target.text.isEmpty ? nil
                    : target.text.hasPrefix("/") || target.text.hasPrefix("~") ? target.text
                    : (directory ?? ".").appendingPathComponentForShell(target.text)
            } else { directory = "~" }
            return
        case "popd":
            directory = nil
            return
        default:
            if Self.quietPrograms.contains(name) { return }
        }
        var found: [String] = []
        if readsFiles {
            if name == "git" { found = Self.gitPaths(arguments) }
            else if let grammar = Self.readers[name] {
                found = grammar.operands(arguments) + command.inputs.filter(\.isPath).map(\.text)
            }
        }
        for path in found { record(Self.join(path, under: directory)) }
        let display = Self.programName(name, arguments: arguments)
        if Self.weakPrograms.contains(name) { weak = weak ?? display }
        else if !found.isEmpty { reader = reader ?? display }
        else { other = other ?? display }
    }

    private mutating func merge(_ inner: ShellCommandSummary) {
        for path in inner.paths { record(path) }
        reader = reader ?? inner.reader
        other = other ?? inner.other
        weak = weak ?? inner.weak
    }

    private mutating func record(_ path: String) {
        guard paths.count < RetainedToolCall.maximumPaths, !paths.contains(path) else { return }
        paths.append(path)
    }

    private static func join(_ path: String, under directory: String?) -> String {
        guard let directory, directory != ".", !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains(":") else { return path }
        return directory.appendingPathComponentForShell(path)
    }

    private static func programName(_ name: String, arguments: [ShellWord]) -> String {
        guard subcommandPrograms.contains(name) else { return name }
        var index = 0
        while index < arguments.count, arguments[index].text.hasPrefix("-") {
            index += name == "git" && ["-C", "-c"].contains(arguments[index].text) ? 2 : 1
        }
        guard index < arguments.count, arguments[index].literal,
              arguments[index].text.range(of: "^[a-z][a-z0-9-]{0,31}$", options: .regularExpression) != nil else { return name }
        return name + " " + arguments[index].text
    }

    /// `git show HEAD:path`, `git cat-file -p HEAD:path`, and any path after `--`.
    private static func gitPaths(_ arguments: [ShellWord]) -> [String] {
        var index = 0
        while index < arguments.count, arguments[index].text.hasPrefix("-") {
            index += ["-C", "-c", "--git-dir", "--work-tree", "--namespace"].contains(arguments[index].text) ? 2 : 1
        }
        guard index < arguments.count else { return [] }
        let subcommand = arguments[index].text
        let rest = arguments[(index + 1)...]
        var paths: [String] = []
        if ["show", "cat-file"].contains(subcommand) {
            paths += rest.prefix { $0.text != "--" }.filter { word in
                guard word.isPath, let colon = word.text.firstIndex(of: ":") else { return false }
                return word.text.index(after: colon) < word.text.endIndex
            }.map(\.text)
        }
        if let separator = rest.firstIndex(where: { $0.text == "--" }) {
            paths += rest[(separator + 1)...].filter(\.isPath).map(\.text)
        }
        return paths
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
    private static let keywords: Set<String> = ["if", "then", "else", "elif", "fi", "do", "done", "while", "until",
                                                "!", "{", "}", "time", "coproc"]
    /// A loop or case header lists words, not a command.
    private static let compoundKeywords: Set<String> = ["for", "case", "esac", "select", "function", "in"]
    /// Wrappers run the next word as the program. Their listed options take a value.
    private static let wrappers: [String: Set<String>] = [
        "sudo": ["-u", "-g", "-h", "-p", "-C", "-U", "-r", "-t"], "env": ["-u", "-C", "-S", "-P"],
        "command": [], "builtin": [], "exec": ["-a"], "nohup": [], "noglob": [], "nice": ["-n"],
        "timeout": ["-s", "-k", "--signal", "--kill-after"], "gtimeout": ["-s", "-k"],
        "xargs": ["-I", "-L", "-n", "-P", "-s", "-E", "-J", "-R", "-S"], "watch": ["-n", "-d"],
        "caffeinate": [], "arch": [],
    ]
    /// Builtins and tests whose output says nothing about the content.
    private static let quietPrograms: Set<String> = ["cd", "pushd", "popd", "export", "set", "unset", "source", ".",
        "true", "false", ":", "local", "declare", "typeset", "alias", "unalias", "shopt", "setopt", "trap", "wait",
        "exit", "return", "read", "sleep", "umask", "ulimit", "hash", "type", "which", "test", "[", "[["]
    /// Programs named only when nothing else ran, such as a separator printed between two files.
    private static let weakPrograms: Set<String> = ["echo", "printf"]
    private static let subcommandPrograms: Set<String> = ["git", "gh", "swift", "security", "docker", "kubectl", "npm",
        "pnpm", "yarn", "bun", "cargo", "go", "brew", "op", "aws", "gcloud", "az", "launchctl", "defaults", "xcrun",
        "uv", "pip", "pip3", "poetry", "bundle", "make", "terraform", "heroku", "vercel", "fly", "doppler", "vault"]

    /// The command-line grammar of a program that prints the files it's given.
    private struct ReaderGrammar {
        /// Operands before the files, such as sed's script or grep's pattern, unless an option supplies them.
        var leading = 0
        /// Options that supply those leading operands themselves.
        var supplying: Set<String> = []
        /// Options followed by separate values, with how many words each takes.
        var values: [String: Int] = [:]

        func operands(_ arguments: [ShellWord]) -> [String] {
            var leading = leading, afterOptions = false, index = 0, operands: [String] = []
            while index < arguments.count {
                let word = arguments[index]
                index += 1
                if !afterOptions, word.text == "--" { afterOptions = true; continue }
                if !afterOptions, word.text.hasPrefix("-"), word.text != "-" {
                    let key = word.text.hasPrefix("--") ? String(word.text.prefix { $0 != "=" }) : word.text
                    if supplying.contains(key) { leading = 0 }
                    if key == word.text, let count = values[key] { index += count }
                    continue
                }
                if leading > 0 { leading -= 1; continue }
                if word.isPath { operands.append(word.text) }
            }
            return operands
        }
    }

    private static let readers: [String: ReaderGrammar] = {
        var table: [String: ReaderGrammar] = [:]
        for name in ["cat", "bat", "batcat", "tac", "less", "more", "most", "strings", "wc", "base64", "shasum",
                     "sha1sum", "sha256sum", "md5", "md5sum", "uniq", "column", "fold", "diff", "cmp", "view"] {
            table[name] = ReaderGrammar()
        }
        table["head"] = .init(values: ["-n": 1, "-c": 1])
        table["tail"] = .init(values: ["-n": 1, "-c": 1, "-b": 1])
        table["nl"] = .init(values: ["-b": 1, "-d": 1, "-f": 1, "-h": 1, "-i": 1, "-l": 1, "-n": 1, "-s": 1, "-v": 1, "-w": 1])
        table["xxd"] = .init(values: ["-l": 1, "-s": 1, "-c": 1, "-g": 1, "-o": 1, "-n": 1])
        table["hexdump"] = .init(values: ["-n": 1, "-s": 1, "-e": 1, "-f": 1])
        table["od"] = .init(values: ["-N": 1, "-j": 1, "-t": 1, "-A": 1])
        table["cut"] = .init(values: ["-d": 1, "-f": 1, "-c": 1, "-b": 1])
        table["sort"] = .init(values: ["-k": 1, "-t": 1, "-o": 1, "-S": 1, "-T": 1])
        table["plutil"] = .init(values: ["-convert": 1, "-o": 1, "-e": 1, "-extract": 2, "-type": 1])
        let sed = ReaderGrammar(leading: 1, supplying: ["-e", "-f", "--expression", "--file"],
            values: ["-e": 1, "-f": 1, "--expression": 1, "--file": 1, "-i": 1, "-l": 1])
        table["sed"] = sed
        table["gsed"] = sed
        let grep = ReaderGrammar(leading: 1, supplying: ["-e", "-f", "--regexp", "--file"],
            values: ["-e": 1, "-f": 1, "--regexp": 1, "--file": 1, "-A": 1, "-B": 1, "-C": 1, "-m": 1, "-d": 1,
                     "-D": 1, "--max-count": 1, "--context": 1, "--include": 1, "--exclude": 1, "--exclude-dir": 1,
                     "--label": 1])
        for name in ["grep", "egrep", "fgrep", "zgrep", "ggrep"] { table[name] = grep }
        table["rg"] = .init(leading: 1, supplying: ["-e", "-f", "--regexp", "--file", "--files"],
            values: ["-e": 1, "-f": 1, "--regexp": 1, "--file": 1, "-g": 1, "--glob": 1, "--iglob": 1, "-t": 1,
                     "--type": 1, "-T": 1, "--type-not": 1, "-A": 1, "-B": 1, "-C": 1, "-m": 1, "-M": 1, "-j": 1,
                     "-E": 1, "-r": 1, "--replace": 1, "-d": 1, "--max-depth": 1, "--sort": 1, "--sortr": 1,
                     "--pre": 1, "--max-filesize": 1, "--context": 1, "--max-count": 1])
        table["ag"] = .init(leading: 1, values: ["-G": 1, "--ignore": 1, "-A": 1, "-B": 1, "-C": 1, "-m": 1])
        let awk = ReaderGrammar(leading: 1, supplying: ["-f"], values: ["-f": 1, "-F": 1, "-v": 1])
        for name in ["awk", "gawk", "mawk", "nawk"] { table[name] = awk }
        table["jq"] = .init(leading: 1, supplying: ["-f", "--from-file"],
            values: ["-f": 1, "--from-file": 1, "--arg": 2, "--argjson": 2, "--slurpfile": 2, "--rawfile": 2,
                     "--indent": 1, "-L": 1])
        return table
    }()
}

private extension String {
    /// Joins without touching the file system, keeping `~` and globs as written.
    func appendingPathComponentForShell(_ component: String) -> String {
        if self == "." { return component }
        return (self as NSString).appendingPathComponent(component)
    }
}

/// One word of a shell command after quote removal. It isn't literal when it holds an expansion,
/// such as `$PWD` or a command substitution, whose value the text alone can't tell. `$HOME` is
/// written as `~`.
struct ShellWord: Equatable {
    var text: String
    var literal: Bool

    var isAssignment: Bool {
        text.range(of: "^[A-Za-z_][A-Za-z0-9_]*\\+?=", options: .regularExpression) != nil
    }

    /// A word that can name a file: no expansion, option, URL or device.
    var isPath: Bool {
        literal && !text.isEmpty && text != "-" && !text.hasPrefix("-") && !text.contains("://")
            && !text.hasPrefix("/dev/")
    }
}

/// One simple command: its words, and the files redirected into it.
struct ShellCommand: Equatable {
    var words: [ShellWord]
    var inputs: [ShellWord] = []
}

/// Splits a command into simple commands and their words, the way a POSIX shell reads it, without
/// running anything. Heredoc bodies are skipped. Output redirections are dropped.
enum ShellTokenizer {
    enum Item: Equatable {
        case command(ShellCommand)
        case openGroup, closeGroup
    }

    static func tokenize(_ command: String) -> [Item] {
        var scanner = Scanner(characters: Array(command))
        scanner.run()
        return scanner.items
    }

    private struct Scanner {
        let characters: [Character]
        var index = 0
        var items: [Item] = []
        var words: [ShellWord] = []
        var inputs: [ShellWord] = []
        var current = ""
        var inWord = false
        var literal = true
        /// Where the next word goes after a redirection operator: `true` for a file read, `false` to drop it.
        var redirection: Bool?
        var heredocs: [(delimiter: String, stripTabs: Bool)] = []

        private func character(at offset: Int) -> Character? {
            index + offset < characters.count ? characters[index + offset] : nil
        }

        mutating func run() {
            while index < characters.count {
                let character = characters[index]
                switch character {
                case " ", "\t":
                    finishWord(); index += 1
                case _ where character.isNewline:
                    finishWord(); finishCommand(); index += 1
                    skipHeredocBodies()
                case "#" where !inWord:
                    while index < characters.count, !characters[index].isNewline { index += 1 }
                case "'":
                    inWord = true; index += 1
                    while index < characters.count, characters[index] != "'" { current.append(characters[index]); index += 1 }
                    index += 1
                case "\"":
                    inWord = true; index += 1
                    while index < characters.count, characters[index] != "\"" {
                        if characters[index] == "\\", let next = self.character(at: 1), ["\"", "\\", "$", "`"].contains(next) || next.isNewline {
                            if !next.isNewline { current.append(next) }
                            index += 2; continue
                        }
                        if characters[index] == "$" { readExpansion(); continue }
                        if characters[index] == "`" { skipBackquotes(); continue }
                        current.append(characters[index]); index += 1
                    }
                    index += 1
                case "\\":
                    inWord = true
                    if let next = self.character(at: 1), !next.isNewline { current.append(next) }
                    index += 2
                case "$":
                    inWord = true
                    readExpansion()
                case "`":
                    inWord = true
                    skipBackquotes()
                case ";", "&", "|":
                    let next = self.character(at: 1)
                    if character == "&", next == ">" {
                        finishWord(); index += 2
                        if self.character(at: 0) == ">" { index += 1 }
                        redirection = false
                        continue
                    }
                    finishWord(); finishCommand()
                    index += next == character || (character == "|" && next == "&") ? 2 : 1
                case "(", ")":
                    finishWord(); finishCommand()
                    items.append(character == "(" ? .openGroup : .closeGroup)
                    index += 1
                case "<", ">":
                    readRedirection(character)
                default:
                    inWord = true; current.append(character); index += 1
                }
            }
            finishWord(); finishCommand()
        }

        /// `$HOME` reads as `~`. Any other expansion makes the word unknowable from the text.
        private mutating func readExpansion() {
            for (spelling, length) in [("$HOME", 5), ("${HOME}", 7)] {
                let end = index + length
                guard end <= characters.count, String(characters[index..<end]) == spelling else { continue }
                if spelling == "$HOME", end < characters.count,
                   characters[end].isLetter || characters[end].isNumber || characters[end] == "_" { continue }
                current.append("~"); index = end
                return
            }
            literal = false
            switch self.character(at: 1) {
            case "("?: index += 1; skipGroup(open: "(", close: ")")
            case "{"?: index += 1; skipGroup(open: "{", close: "}")
            default: current.append("$"); index += 1
            }
        }

        private mutating func skipBackquotes() {
            literal = false; index += 1
            while index < characters.count, characters[index] != "`" {
                index += characters[index] == "\\" ? 2 : 1
            }
            index += 1
        }

        /// Skips from an opening bracket to its match, past nested pairs and quoted text.
        private mutating func skipGroup(open: Character, close: Character) {
            var depth = 0
            while index < characters.count {
                let character = characters[index]
                if character == "\\" { index += 2; continue }
                if character == "'" {
                    index += 1
                    while index < characters.count, characters[index] != "'" { index += 1 }
                } else if character == open {
                    depth += 1
                } else if character == close {
                    depth -= 1
                    if depth == 0 { index += 1; return }
                }
                index += 1
            }
        }

        private mutating func readRedirection(_ character: Character) {
            let next = self.character(at: 1)
            // `<(…)` and `>(…)` are process substitutions: a word whose value the text can't tell.
            if next == "(" {
                inWord = true; literal = false; index += 1
                skipGroup(open: "(", close: ")")
                return
            }
            // A file descriptor written just before the operator, as in `2>`, belongs to it.
            if inWord, literal, !current.isEmpty, current.allSatisfy(\.isNumber) {
                current = ""; inWord = false
            } else { finishWord() }
            index += 1
            if character == "<", next == "<" {
                index += 1
                if self.character(at: 0) == "<" {
                    // A here-string is text, not a file.
                    index += 1; redirection = false
                    return
                }
                let stripTabs = self.character(at: 0) == "-"
                if stripTabs { index += 1 }
                readHeredocDelimiter(stripTabs: stripTabs)
                return
            }
            switch (character, self.character(at: 0)) {
            case ("<", ">"?): index += 1; redirection = true
            case (_, "&"?), (_, "|"?), (">", ">"?): index += 1; redirection = false
            default: redirection = character == "<"
            }
        }

        private mutating func readHeredocDelimiter(stripTabs: Bool) {
            while let character = self.character(at: 0), character == " " || character == "\t" { index += 1 }
            var delimiter = ""
            while let character = self.character(at: 0),
                  !character.isWhitespace, ![";", "&", "|", "<", ">", "(", ")"].contains(character) {
                if !["'", "\"", "\\"].contains(character) { delimiter.append(character) }
                index += 1
            }
            if !delimiter.isEmpty { heredocs.append((delimiter, stripTabs)) }
        }

        private mutating func skipHeredocBodies() {
            for heredoc in heredocs {
                while index < characters.count {
                    var end = index
                    while end < characters.count, !characters[end].isNewline { end += 1 }
                    var line = Substring(String(characters[index..<end]))
                    if heredoc.stripTabs { line = line.drop { $0 == "\t" } }
                    index = min(characters.count, end + 1)
                    if line == heredoc.delimiter { break }
                }
            }
            heredocs.removeAll()
        }

        private mutating func finishWord() {
            guard inWord else { return }
            let word = ShellWord(text: current, literal: literal)
            switch redirection {
            case true?: inputs.append(word)
            case false?: break
            case nil: words.append(word)
            }
            redirection = nil
            current = ""; inWord = false; literal = true
        }

        private mutating func finishCommand() {
            redirection = nil
            guard !words.isEmpty || !inputs.isEmpty else { return }
            items.append(.command(ShellCommand(words: words, inputs: inputs)))
            words = []; inputs = []
        }
    }
}
