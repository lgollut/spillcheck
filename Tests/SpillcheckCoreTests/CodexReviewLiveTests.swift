import CryptoKit
import Darwin
import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private func reviewProbeIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
}

private func reviewProbeHash(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

private func reviewProbePrivateDirectory(_ path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
          info.st_uid == getuid(), info.st_mode & 0o077 == 0,
          let resolved = realpath(path, nil) else { throw CodexHistoryError.unsafeMethod }
    defer { free(resolved) }
    guard String(cString: resolved) == path else { throw CodexHistoryError.unsafeMethod }
}

private func reviewProbeAuthAbsent(_ home: String) -> Bool {
    var info = stat()
    return lstat(home + "/auth.json", &info) == -1 && errno == ENOENT
}

private func reviewProbeWritePrivate(_ data: Data, path: String, name: String, maximum: Int) throws {
    let url = URL(fileURLWithPath: path), parent = url.deletingLastPathComponent().path
    guard url.lastPathComponent == name, data.count <= maximum else {
        throw CodexHistoryError.unsafeMethod
    }
    try reviewProbePrivateDirectory(parent)
    let directory = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw CodexHistoryError.unsafeMethod }
    defer { close(directory) }
    var info = stat()
    guard fstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
          info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw CodexHistoryError.unsafeMethod }
    let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw CodexHistoryError.unsafeMethod }
    defer { close(fd) }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            guard count > 0 else { throw CodexHistoryError.unsafeMethod }
            offset += count
        }
    }
    guard fsync(fd) == 0 else { throw CodexHistoryError.unsafeMethod }
}

private func reviewProbeWriteReport(_ data: Data, path: String) throws {
    try reviewProbeWritePrivate(data, path: path, name: "passive-report.json", maximum: 65_536)
}

private func reviewProbeDescriptorDestination(root: URL, home: String, path: String) throws {
    guard root.deletingLastPathComponent().path == "/private/tmp",
          root.lastPathComponent.hasPrefix("spillcheck-signed-review-"),
          home == root.appendingPathComponent("home").path,
          path == root.appendingPathComponent("review-descriptor.json").path,
          reviewProbeAuthAbsent(home) else { throw CodexHistoryError.unsafeMethod }
    try reviewProbePrivateDirectory(root.path)
    try reviewProbePrivateDirectory(home)
    var info = stat()
    guard lstat(path, &info) == -1 && errno == ENOENT else { throw CodexHistoryError.unsafeMethod }
}

private func reviewProbeExportDescriptor(_ descriptor: [String: Any], root: URL, home: String,
                                        path: String, report: [String: Any]) throws {
    // This optional export is made only after the two-read witness succeeded
    // and its real passive reader confirmed shutdown. Live IDs never enter it.
    guard report["status"] as? String == "native-review-read-and-replayed",
          ["actualSecondRead", "replayStable", "nativeItemIdentityStable", "inputReplayStable",
           "inputNativeIdentityStable", "inputTurnRelationshipStable", "readerShutdownCompletedWithinDeadline",
           "authAbsentAfterReads"].allSatisfy({ report[$0] as? Bool == true }) else {
        throw CodexHistoryError.unsafeMethod
    }
    try reviewProbeDescriptorDestination(root: root, home: home, path: path)
    let data = try JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys, .withoutEscapingSlashes])
    try reviewProbeWritePrivate(data, path: path, name: "review-descriptor.json", maximum: 4096)
}

private func reviewProbeSelection(_ entries: [CodexJSON], turn: String, hash: String, count: Int) throws -> CodexJSON {
    let matching = entries.filter { entry in
        let item = entry["item"]
        guard entry["turnId"].string == turn, item["type"].string == "agentMessage",
              item.object?["phase"] == .null, let text = item["text"].string else { return false }
        let bytes = Data(text.utf8)
        return bytes.count == count && reviewProbeHash(bytes) == hash
    }
    guard matching.count == 1, let item = matching[0]["item"]["id"].string,
          reviewProbeIdentifier(item) else { throw CodexHistoryError.malformedResponse }
    return matching[0]
}

private func reviewProbeInputSelection(_ entries: [CodexJSON], turn expectedTurn: String, hash: String, count: Int) throws -> CodexJSON {
    let users = entries.filter { $0["item"]["type"].string == "userMessage" }
    guard users.count == 1, let entry = users.first,
          let turn = entry["turnId"].string, reviewProbeIdentifier(turn), turn == expectedTurn,
          let id = entry["item"]["id"].string, reviewProbeIdentifier(id),
          let content = entry["item"]["content"].array, content.count == 1,
          content[0]["type"].string == "text", let text = content[0]["text"].string else {
        throw CodexHistoryError.malformedResponse
    }
    let bytes = Data(text.utf8)
    guard bytes.count == count, reviewProbeHash(bytes) == hash else {
        throw CodexHistoryError.malformedResponse
    }
    return entry
}

/// The public parent-thread projection retains the delegated input's native
/// turn, while its Turn.rootTurnId records the review task that initiated it.
/// These are selected native identities, never substituted item/turn IDs.
private struct ReviewProbeInputTurnRelationship: Equatable {
    enum Kind: String {
        case sameReviewTurn = "same-review-turn"
        case nativeReviewRoot = "native-review-root"
    }
    let kind: Kind
    let inputTurn: String
    let inputRoot: String
    let reviewTurn: String
    let reviewRoot: String
}

private func reviewProbeTurnRecordIDsValidAndUnique(_ turns: [CodexJSON]) -> Bool {
    guard !turns.isEmpty, turns.count <= 256 else { return false }
    var identifiers = Set<String>()
    return turns.allSatisfy { row in
        guard let id = row["id"].string, reviewProbeIdentifier(id) else { return false }
        return identifiers.insert(id).inserted
    }
}

private func reviewProbeInputTurnRelationship(_ turns: [CodexJSON], inputTurn: String,
                                             reviewTurn: String) throws -> ReviewProbeInputTurnRelationship {
    guard reviewProbeIdentifier(inputTurn), reviewProbeIdentifier(reviewTurn),
          reviewProbeTurnRecordIDsValidAndUnique(turns) else { throw CodexHistoryError.malformedResponse }
    let inputs = turns.filter { $0["id"].string == inputTurn }
    let reviews = turns.filter { $0["id"].string == reviewTurn }
    guard inputs.count == 1, reviews.count == 1,
          let inputRoot = inputs[0]["rootTurnId"].string, reviewProbeIdentifier(inputRoot),
          let reviewRoot = reviews[0]["rootTurnId"].string, reviewProbeIdentifier(reviewRoot),
          inputRoot == reviewTurn, reviewRoot == reviewTurn else { throw CodexHistoryError.malformedResponse }
    return .init(kind: inputTurn == reviewTurn ? .sameReviewTurn : .nativeReviewRoot,
        inputTurn: inputTurn, inputRoot: inputRoot, reviewTurn: reviewTurn, reviewRoot: reviewRoot)
}

private func reviewProbeNativeDescriptor(threadID: String, turnID: String, input: CodexJSON, output: CodexJSON,
                                        relationship: ReviewProbeInputTurnRelationship,
                                        inputHash: String, inputCount: Int, outputHash: String, outputCount: Int) throws -> [String: Any] {
    guard UUID(uuidString: threadID)?.uuidString.lowercased() == threadID,
          reviewProbeIdentifier(turnID), relationship.reviewTurn == turnID,
          relationship.inputRoot == turnID, relationship.reviewRoot == turnID,
          [inputHash, outputHash].allSatisfy({ $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }),
          (1...16_384).contains(inputCount), (1...16_384).contains(outputCount) else {
        throw CodexHistoryError.malformedResponse
    }
    let savedInput = try reviewProbeInputSelection([input], turn: relationship.inputTurn, hash: inputHash, count: inputCount)
    let savedOutput = try reviewProbeSelection([output], turn: turnID, hash: outputHash, count: outputCount)
    guard let inputID = savedInput["item"]["id"].string, let outputID = savedOutput["item"]["id"].string,
          inputID != outputID else { throw CodexHistoryError.malformedResponse }
    return ["schemaVersion": 1, "threadID": threadID, "turnID": turnID, "inputID": inputID, "outputID": outputID,
            "inputSHA256": inputHash, "inputBytes": inputCount, "outputSHA256": outputHash,
            "outputBytes": outputCount, "producerVersion": "0.162.1"]
}

/// Only original producer timestamps are supplied to the adapter. Observation
/// time is never used as a substitute for a missing item or turn timestamp.
private func reviewProbeTurnTimes(_ turns: [CodexJSON]) -> [String: DateInterval] {
    var result: [String: DateInterval] = [:]
    for turn in turns {
        if let id = turn["id"].string, reviewProbeIdentifier(id),
           let start = turn["startedAt"].number, let end = turn["completedAt"].number,
           start.isFinite, end.isFinite, abs(start) < 1e12, abs(end) < 1e12, end >= start {
            result[id] = DateInterval(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
        }
    }
    return result
}

private func reviewProbeOriginalTime(_ entry: CodexJSON, times: [String: DateInterval], userPrompt: Bool = false) throws -> (Date, String) {
    if let milliseconds = entry["completedAtMs"].number ?? entry["startedAtMs"].number,
       milliseconds.isFinite, abs(milliseconds) < 1e15 {
        return (Date(timeIntervalSince1970: milliseconds / 1000),
                entry["completedAtMs"].number != nil ? "item-completed" : "item-started")
    }
    guard entry["completedAtMs"] == .null, entry["startedAtMs"] == .null,
          let turn = entry["turnId"].string, let interval = times[turn] else {
        throw CodexHistoryError.malformedResponse
    }
    return (userPrompt ? interval.start : interval.end, "matching-turn-interval")
}

private func reviewProbeInputDiagnostic(_ entries: [CodexJSON], reviewTurn: String, output: CodexJSON,
                                       hash: String, count: Int, times: [String: DateInterval],
                                       turns: [CodexJSON]) -> [String: Any] {
    let users = entries.filter { $0["item"]["type"].string == "userMessage" }
    let input = users.count == 1 ? users[0] : .null
    let inputID = input["item"]["id"].string
    let outputID = output["item"]["id"].string
    let inputTurn = input["turnId"].string
    let content = input["item"]["content"].array
    let block = content?.count == 1 ? content![0] : .null
    let text = block["text"].string
    let bytes = text.map { Data($0.utf8) }
    let singleTextBlock = content?.count == 1 && block["type"].string == "text"
    let boundedText = singleTextBlock && bytes.map { (1...16_384).contains($0.count) } == true
    let inputHash = boundedText ? bytes.map(reviewProbeHash) : nil
    let outputText = output["item"]["text"].string
    let enters = entries.filter { $0["item"]["type"].string == "enteredReviewMode" }
    let exits = entries.filter { $0["item"]["type"].string == "exitedReviewMode" }
    let inputTurns = turns.filter { $0["id"].string == inputTurn }
    let reviewTurns = turns.filter { $0["id"].string == reviewTurn }
    let inputRoot = inputTurns.count == 1 ? inputTurns[0]["rootTurnId"].string : nil
    let reviewRoot = reviewTurns.count == 1 ? reviewTurns[0]["rootTurnId"].string : nil
    let relationship = inputTurn.flatMap {
        try? reviewProbeInputTurnRelationship(turns, inputTurn: $0, reviewTurn: reviewTurn)
    }
    var result: [String: Any] = [
        "userItemCount": users.count,
        "nativeTurnValid": inputTurn.map(reviewProbeIdentifier) == true,
        "nativeTurnMatchesReview": inputTurn == reviewTurn,
        "turnRecordIDsValidAndUnique": reviewProbeTurnRecordIDsValidAndUnique(turns),
        "inputTurnRecordCount": inputTurns.count,
        "reviewTurnRecordCount": reviewTurns.count,
        "inputRootValid": inputRoot.map(reviewProbeIdentifier) == true,
        "inputRootMatchesReview": inputRoot == reviewTurn,
        "reviewRootMatchesReview": reviewRoot == reviewTurn,
        "inputTurnRelationshipVerified": relationship != nil,
        "nativeItemIDValid": inputID.map(reviewProbeIdentifier) == true,
        "contentIsArray": content != nil,
        "contentBlockCount": content?.count ?? 0,
        "singleTextBlock": singleTextBlock,
        "textPresent": text != nil,
        "inputTextBounded": boundedText,
        "inputTextBytes": bytes?.count ?? 0,
        "inputBytesMatch": bytes?.count == count,
        "inputHashMatches": inputHash == hash,
        "enteredItemCount": enters.count,
        "exitedItemCount": exits.count,
        "presentationTurnsMatchReview": (enters + exits).allSatisfy { $0["turnId"].string == reviewTurn },
        "enteredTextMatchesInput": enters.count == 1 && text != nil && enters[0]["item"]["review"].string == text,
        "exitedTextMatchesOutput": exits.count == 1 && outputText != nil && exits[0]["item"]["review"].string == outputText,
        "outputMarkerUnique": outputText?.components(separatedBy: "SPILLCHECK_FAKE_NATIVE_REVIEW_42").count == 2,
        "inputIDOccurrenceCount": inputID.map { id in entries.filter { $0["item"]["id"].string == id }.count } ?? 0,
        "outputIDOccurrenceCount": outputID.map { id in entries.filter { $0["item"]["id"].string == id }.count } ?? 0,
        "inputOutputIDsDistinct": inputID != nil && outputID != nil && inputID != outputID,
    ]
    if let inputHash { result["inputTextSHA256"] = inputHash }
    for (prefix, entry, userPrompt) in [("input", input, true), ("output", output, false)] {
        let itemTime = entry["completedAtMs"].number ?? entry["startedAtMs"].number
        result[prefix + "ItemTimestampPresent"] = entry["completedAtMs"] != .null || entry["startedAtMs"] != .null
        result[prefix + "ItemTimestampValid"] = itemTime.map { $0.isFinite && abs($0) < 1e15 } == true
        result[prefix + "TurnIntervalAvailable"] = entry["turnId"].string.flatMap { times[$0] } != nil
        result[prefix + "OriginalTimestampAvailable"] = (try? reviewProbeOriginalTime(entry, times: times, userPrompt: userPrompt)) != nil
    }
    return result
}

private func reviewProbeInputFailureStage(_ diagnostic: [String: Any]) -> String? {
    func yes(_ key: String) -> Bool { diagnostic[key] as? Bool == true }
    func one(_ key: String) -> Bool { diagnostic[key] as? Int == 1 }
    if !one("userItemCount") { return "checking-native-input-cardinality" }
    if !yes("nativeTurnValid") || !yes("inputTurnRelationshipVerified") { return "checking-native-input-turn" }
    if !yes("nativeItemIDValid") { return "checking-native-input-identity" }
    if !yes("contentIsArray") || !one("contentBlockCount") || !yes("singleTextBlock") || !yes("textPresent") {
        return "checking-native-input-content"
    }
    if !yes("inputBytesMatch") || !yes("inputHashMatches") { return "checking-native-input-bytes" }
    if !one("enteredItemCount") || !one("exitedItemCount") { return "checking-review-presentation-cardinality" }
    if !yes("presentationTurnsMatchReview") { return "checking-review-presentation-turns" }
    if !one("inputIDOccurrenceCount") || !one("outputIDOccurrenceCount") || !yes("inputOutputIDsDistinct") {
        return "checking-original-source-identities"
    }
    if !yes("enteredTextMatchesInput") { return "checking-entered-review-input-equality" }
    if !yes("exitedTextMatchesOutput") || !yes("outputMarkerUnique") { return "checking-exited-review-output-equality" }
    if !yes("outputOriginalTimestampAvailable") { return "checking-original-output-timestamp" }
    if !yes("inputOriginalTimestampAvailable") { return "checking-original-input-timestamp" }
    return nil
}

@Suite("Opt-in disposable native Codex review")
struct CodexReviewLiveTests {
    @Test func inputTurnRelationshipUsesExactPublicRootWithoutRebindingInput() throws {
        let review = CodexJSON.object(["id": .string("review-turn"), "rootTurnId": .string("review-turn"),
            "status": .string("completed"), "startedAt": .null, "completedAt": .number(110)])
        let child = CodexJSON.object(["id": .string("native-input-turn"), "rootTurnId": .string("review-turn"),
            "status": .string("inProgress"), "startedAt": .number(100), "completedAt": .null])
        let direct = try reviewProbeInputTurnRelationship([review], inputTurn: "review-turn", reviewTurn: "review-turn")
        #expect(direct.kind == .sameReviewTurn && direct.inputTurn == "review-turn")
        let delegated = try reviewProbeInputTurnRelationship([review, child], inputTurn: "native-input-turn", reviewTurn: "review-turn")
        #expect(delegated.kind == .nativeReviewRoot && delegated.inputTurn == "native-input-turn")
        #expect(delegated.inputRoot == "review-turn" && delegated.reviewRoot == "review-turn")
        #expect(delegated.inputTurn != delegated.reviewTurn)
        #expect(try reviewProbeInputTurnRelationship([child, review], inputTurn: "native-input-turn", reviewTurn: "review-turn") == delegated)
        #expect(reviewProbeTurnTimes([review, child]).isEmpty)
        let original = CodexJSON.object(["turnId": .string("native-input-turn"), "completedAtMs": .number(101_125)])
        #expect(try reviewProbeOriginalTime(original, times: [:], userPrompt: true).0 == Date(timeIntervalSince1970: 101.125))
        #expect(throws: CodexHistoryError.malformedResponse) {
            try reviewProbeOriginalTime(.object(["turnId": .string("native-input-turn")]), times: [:], userPrompt: true)
        }
    }

    @Test func inputTurnRelationshipRejectsMissingDuplicateSelfAndWrongParentLinks() throws {
        func row(_ id: String, root: CodexJSON = .string("review-turn")) -> CodexJSON {
            .object(["id": .string(id), "rootTurnId": root])
        }
        let review = row("review-turn"), input = row("native-input-turn")
        let invalid: [[CodexJSON]] = [[], [review], [input], [review, review, input], [review, input, input],
            [review, input, row("unrelated"), row("unrelated")], [review, input, row("")],
            [review, input, row("invalid\0turn")],
            [review, input, row(String(repeating: "x", count: 257))],
            [review, row("native-input-turn", root: .string("native-input-turn"))],
            [review, row("native-input-turn", root: .string("another-review"))],
            [row("review-turn", root: .string("native-input-turn")), input],
            [row("review-turn", root: .string("another-review")), input],
            [review, row("native-input-turn", root: .null)],
            [review, row("native-input-turn", root: .string(""))],
            [review, row("native-input-turn", root: .string("invalid\nroot"))],
            [review, row("native-input-turn", root: .number(7))],
            [row("review-turn", root: .null), input],
            Array(repeating: review, count: 257)]
        for turns in invalid {
            #expect(throws: CodexHistoryError.malformedResponse) {
                try reviewProbeInputTurnRelationship(turns, inputTurn: "native-input-turn", reviewTurn: "review-turn")
            }
        }
    }

    @Test func replayRelationshipRequiresTheSameNativeTurnAndRootPair() throws {
        func row(_ id: String, root: String = "review-turn") -> CodexJSON {
            .object(["id": .string(id), "rootTurnId": .string(root)])
        }
        let first = try reviewProbeInputTurnRelationship([row("review-turn"), row("input-turn")],
            inputTurn: "input-turn", reviewTurn: "review-turn")
        let substituted = try reviewProbeInputTurnRelationship([row("review-turn"), row("other-input-turn")],
            inputTurn: "other-input-turn", reviewTurn: "review-turn")
        #expect(first != substituted)
        #expect(throws: CodexHistoryError.malformedResponse) {
            try reviewProbeInputTurnRelationship([row("review-turn"), row("input-turn", root: "other-review")],
                inputTurn: "input-turn", reviewTurn: "review-turn")
        }
    }

    @Test func selectionUsesUniqueOriginalNativeIdentityRatherThanLiveIdentity() throws {
        let text = "SPILLCHECK_FAKE_NATIVE_REVIEW_42 é🙂\r\n"
        let hash = reviewProbeHash(Data(text.utf8))
        func entry(_ id: String, phase: CodexJSON? = .null, turn: String = "review-turn") -> CodexJSON {
            var item: [String: CodexJSON] = ["type": .string("agentMessage"), "id": .string(id), "text": .string(text)]
            item["phase"] = phase
            return .object(["turnId": .string(turn), "item": .object(item)])
        }
        let own = entry("persisted-1")
        #expect(try reviewProbeSelection([own, entry("other", turn: "foreign")], turn: "review-turn", hash: hash,
            count: text.utf8.count) == own)
        for entries in [[entry("missing", phase: nil)], [entry("final", phase: .string("final_answer"))],
                        [own, entry("duplicate")], [entry("foreign", turn: "foreign")]] {
            #expect(throws: CodexHistoryError.malformedResponse) {
                try reviewProbeSelection(entries, turn: "review-turn", hash: hash, count: text.utf8.count)
            }
        }
    }

    @Test func timestampsRequireOriginalItemOrMatchingCompletedTurn() throws {
        let entry = CodexJSON.object(["turnId": .string("owned")])
        let times = reviewProbeTurnTimes([
            .object(["id": .string("unrelated"), "startedAt": .null, "completedAt": .null]),
            .object(["id": .string("owned"), "startedAt": .number(100), "completedAt": .number(110)])])
        #expect(try reviewProbeOriginalTime(entry, times: times).0 == Date(timeIntervalSince1970: 110))
        #expect(try reviewProbeOriginalTime(entry, times: times, userPrompt: true).0 == Date(timeIntervalSince1970: 100))
        #expect(throws: CodexHistoryError.malformedResponse) { try reviewProbeOriginalTime(entry, times: [:]) }
        let timed = CodexJSON.object(["turnId": .string("owned"), "completedAtMs": .number(101_125)])
        #expect(try reviewProbeOriginalTime(timed, times: [:]).0 == Date(timeIntervalSince1970: 101.125))
    }

    @Test func originalInputRequiresUniqueTextBlockAndExactBytes() throws {
        let text = "Original review input é🙂\r\n"
        let hash = reviewProbeHash(Data(text.utf8))
        func entry(text: String, type: String = "text", turn: String = "native-input-turn",
                   extraBlock: Bool = false) -> CodexJSON {
            var content: [CodexJSON] = [.object(["type": .string(type), "text": .string(text)])]
            if extraBlock { content.append(.object(["type": .string("text"), "text": .string("additional")])) }
            return .object(["turnId": .string(turn), "item": .object(["type": .string("userMessage"),
                "id": .string("original-input"), "content": .array(content)])])
        }
        let own = entry(text: text)
        #expect(try reviewProbeInputSelection([own], turn: "native-input-turn", hash: hash, count: text.utf8.count) == own)
        let presentation = CodexJSON.object(["turnId": .string("review-turn"), "item": .object([
            "type": .string("enteredReviewMode"), "id": .string("presentation"), "review": .string(text)])])
        for entries in [[presentation], [own, own], [entry(text: text + " ")], [entry(text: text, type: "image")],
                        [entry(text: text, turn: "")], [entry(text: text, turn: "another-turn")],
                        [entry(text: text, extraBlock: true)]] {
            #expect(throws: CodexHistoryError.malformedResponse) {
                try reviewProbeInputSelection(entries, turn: "native-input-turn", hash: hash, count: text.utf8.count)
            }
        }
    }

    @Test func inputDiagnosticsIdentifyEachClosedFailureBranch() throws {
        let text = "Owned review input é🙂\n", outputText = "SPILLCHECK_FAKE_NATIVE_REVIEW_42: reviewed."
        let hash = reviewProbeHash(Data(text.utf8))
        let block = CodexJSON.object(["type": .string("text"), "text": .string(text)])
        func input(turn: String = "review-turn", id: String = "input-id", content: CodexJSON? = nil,
                   at: CodexJSON = .number(100_000)) -> CodexJSON {
            .object(["turnId": .string(turn), "completedAtMs": at, "item": .object([
                "type": .string("userMessage"), "id": .string(id), "content": content ?? .array([block])])])
        }
        func output(at: CodexJSON = .number(110_000)) -> CodexJSON {
            .object(["turnId": .string("review-turn"), "completedAtMs": at, "item": .object([
                "type": .string("agentMessage"), "id": .string("output-id"), "text": .string(outputText)])])
        }
        func presentation(_ kind: String, _ text: String, turn: String = "review-turn") -> CodexJSON {
            .object(["turnId": .string(turn), "item": .object([
                "type": .string(kind), "id": .string(kind), "review": .string(text)])])
        }
        let enter = presentation("enteredReviewMode", text), exit = presentation("exitedReviewMode", outputText)
        let ownOutput = output()
        let turnRows = [CodexJSON.object(["id": .string("review-turn"), "rootTurnId": .string("review-turn")])]
        func diagnostic(_ entries: [CodexJSON], output: CodexJSON? = nil) -> [String: Any] {
            reviewProbeInputDiagnostic(entries, reviewTurn: "review-turn", output: output ?? ownOutput,
                hash: hash, count: text.utf8.count, times: [:], turns: turnRows)
        }
        let valid = diagnostic([input(), ownOutput, enter, exit])
        #expect(reviewProbeInputFailureStage(valid) == nil)
        #expect(valid["inputTextSHA256"] as? String == hash)
        let delegated = reviewProbeInputDiagnostic([input(turn: "native-input-turn"), ownOutput, enter, exit],
            reviewTurn: "review-turn", output: ownOutput, hash: hash, count: text.utf8.count, times: [:],
            turns: turnRows + [.object(["id": .string("native-input-turn"), "rootTurnId": .string("review-turn"),
                "status": .string("inProgress"), "startedAt": .number(100), "completedAt": .null])])
        #expect(reviewProbeInputFailureStage(delegated) == nil)
        #expect(delegated["nativeTurnMatchesReview"] as? Bool == false)
        #expect(delegated["inputTurnRelationshipVerified"] as? Bool == true)
        #expect(delegated["inputTurnIntervalAvailable"] as? Bool == false)
        #expect(delegated["inputOriginalTimestampAvailable"] as? Bool == true)
        let cases: [([CodexJSON], String)] = [
            ([ownOutput, enter, exit], "checking-native-input-cardinality"),
            ([input(), input(), ownOutput, enter, exit], "checking-native-input-cardinality"),
            ([input(turn: "other-turn"), ownOutput, enter, exit], "checking-native-input-turn"),
            ([input(id: ""), ownOutput, enter, exit], "checking-native-input-identity"),
            ([input(content: .null), ownOutput, enter, exit], "checking-native-input-content"),
            ([input(content: .array([block, block])), ownOutput, enter, exit], "checking-native-input-content"),
            ([input(content: .array([.object(["type": .string("image"), "text": .string(text)])])), ownOutput, enter, exit], "checking-native-input-content"),
            ([input(content: .array([.object(["type": .string("text")])])), ownOutput, enter, exit], "checking-native-input-content"),
            ([input(content: .array([.object(["type": .string("text"), "text": .string(text + " ")])])), ownOutput, enter, exit], "checking-native-input-bytes"),
            ([input(), ownOutput, exit], "checking-review-presentation-cardinality"),
            ([input(), ownOutput, presentation("enteredReviewMode", text, turn: "foreign"), exit], "checking-review-presentation-turns"),
            ([input(id: "output-id"), ownOutput, enter, exit], "checking-original-source-identities"),
            ([input(), ownOutput, presentation("enteredReviewMode", "different"), exit], "checking-entered-review-input-equality"),
            ([input(), ownOutput, enter, presentation("exitedReviewMode", "different")], "checking-exited-review-output-equality"),
            ([input(at: .null), ownOutput, enter, exit], "checking-original-input-timestamp"),
        ]
        for (entries, expectedStage) in cases {
            #expect(reviewProbeInputFailureStage(diagnostic(entries)) == expectedStage)
        }
        let untimedOutput = output(at: .null)
        #expect(reviewProbeInputFailureStage(diagnostic([input(), untimedOutput, enter, exit], output: untimedOutput))
            == "checking-original-output-timestamp")
        let wrongHash = reviewProbeInputDiagnostic([input(), ownOutput, enter, exit], reviewTurn: "review-turn",
            output: ownOutput, hash: String(repeating: "0", count: 64), count: text.utf8.count, times: [:], turns: turnRows)
        #expect(wrongHash["inputBytesMatch"] as? Bool == true)
        #expect(wrongHash["inputHashMatches"] as? Bool == false)
        #expect(reviewProbeInputFailureStage(wrongHash) == "checking-native-input-bytes")
    }

    @Test func inputDiagnosticsDoNotExportNativeIdentifiersOrText() throws {
        let secretID = "PRIVATE_NATIVE_ID_NEVER_EXPORTED", text = "PRIVATE_NATIVE_TEXT_NEVER_EXPORTED"
        let input = CodexJSON.object(["turnId": .string(secretID), "item": .object([
            "type": .string("userMessage"), "id": .string(secretID),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])])])])
        let diagnostic = reviewProbeInputDiagnostic([input], reviewTurn: secretID, output: .null,
            hash: reviewProbeHash(Data(text.utf8)), count: text.utf8.count, times: [:],
            turns: [.object(["id": .string(secretID), "rootTurnId": .string(secretID)])])
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]), as: UTF8.self)
        #expect(!encoded.contains(secretID) && !encoded.contains(text))
        #expect(diagnostic["inputTextSHA256"] as? String == reviewProbeHash(Data(text.utf8)))
        #expect(diagnostic.values.allSatisfy { $0 is Bool || $0 is Int || ($0 as? String)?.count == 64 })
        let malformed = reviewProbeInputDiagnostic([], reviewTurn: secretID, output: .null,
            hash: reviewProbeHash(Data(text.utf8)), count: text.utf8.count, times: [:], turns: [])
        #expect(malformed["inputTextSHA256"] == nil)
        #expect(malformed["inputTextBytes"] as? Int == 0)
    }

    @Test func reportIsPrivateExclusiveAndAuthSymlinksAreNotAbsence() throws {
        let root = URL(fileURLWithPath: "/private/tmp/spillcheck-review-boundary-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let report = root.appendingPathComponent("passive-report.json").path
        #expect(reviewProbeAuthAbsent(root.path))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("auth.json").path,
            withDestinationPath: root.appendingPathComponent("absent").path)
        #expect(!reviewProbeAuthAbsent(root.path))
        try reviewProbeWriteReport(Data("{}".utf8), path: report)
        #expect(throws: CodexHistoryError.unsafeMethod) { try reviewProbeWriteReport(Data("{}".utf8), path: report) }
        #expect(throws: CodexHistoryError.unsafeMethod) {
            try reviewProbeWriteReport(Data("{}".utf8), path: root.appendingPathComponent("other.json").path)
        }
    }

    @Test func descriptorUsesSavedOriginalIdentitiesAndRequiresOriginalBytesRootAndNullPhase() throws {
        let thread = UUID().uuidString.lowercased(), inputText = "fake review input", outputText = "fake review output"
        let input: CodexJSON = .object(["turnId": .string("delegated-input-turn"), "item": .object([
            "type": .string("userMessage"), "id": .string("persisted-input"),
            "content": .array([.object(["type": .string("text"), "text": .string(inputText)])])])])
        let output: CodexJSON = .object(["turnId": .string("review-turn"), "item": .object([
            "type": .string("agentMessage"), "id": .string("persisted-output"), "phase": .null, "text": .string(outputText)])])
        let relation = ReviewProbeInputTurnRelationship(kind: .nativeReviewRoot, inputTurn: "delegated-input-turn",
            inputRoot: "review-turn", reviewTurn: "review-turn", reviewRoot: "review-turn")
        func descriptor(_ originalInput: CodexJSON, _ originalOutput: CodexJSON,
                        _ root: ReviewProbeInputTurnRelationship) throws -> [String: Any] {
            try reviewProbeNativeDescriptor(threadID: thread, turnID: "review-turn", input: originalInput,
                output: originalOutput, relationship: root, inputHash: reviewProbeHash(Data(inputText.utf8)),
                inputCount: inputText.utf8.count, outputHash: reviewProbeHash(Data(outputText.utf8)), outputCount: outputText.utf8.count)
        }
        let value = try descriptor(input, output, relation)
        #expect(value["inputID"] as? String == "persisted-input")
        #expect(value["outputID"] as? String == "persisted-output")
        #expect(Set(value.keys) == Set(["schemaVersion", "threadID", "turnID", "inputID", "outputID",
            "inputSHA256", "inputBytes", "outputSHA256", "outputBytes", "producerVersion"]))
        let wrongRoot = ReviewProbeInputTurnRelationship(kind: .nativeReviewRoot, inputTurn: "delegated-input-turn",
            inputRoot: "unrelated-turn", reviewTurn: "review-turn", reviewRoot: "review-turn")
        #expect(throws: CodexHistoryError.malformedResponse) { try descriptor(input, output, wrongRoot) }
        for phase in [CodexJSON.string("final"), .string("commentary"), .object([:])] {
            var fields = try #require(output["item"].object)
            if phase == .object([:]) { fields.removeValue(forKey: "phase") } else { fields["phase"] = phase }
            let invalid: CodexJSON = .object(["turnId": .string("review-turn"), "item": .object(fields)])
            #expect(throws: CodexHistoryError.malformedResponse) { try descriptor(input, invalid, relation) }
        }
        var altered = try #require(input["item"].object)
        altered["content"] = .array([.object(["type": .string("text"), "text": .string("changed input")])])
        #expect(throws: CodexHistoryError.malformedResponse) {
            try descriptor(.object(["turnId": .string("delegated-input-turn"), "item": .object(altered)]), output, relation)
        }
    }

    @Test func descriptorExportRequiresCompleteReplayStoppedReaderPrivateRootAndAbsentAuth() throws {
        let root = URL(fileURLWithPath: "/private/tmp/spillcheck-signed-review-\(UUID())")
        let home = root.appendingPathComponent("home"), path = root.appendingPathComponent("review-descriptor.json").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let proofKeys = ["actualSecondRead", "replayStable", "nativeItemIdentityStable", "inputReplayStable",
            "inputNativeIdentityStable", "inputTurnRelationshipStable", "readerShutdownCompletedWithinDeadline", "authAbsentAfterReads"]
        var report: [String: Any] = Dictionary(uniqueKeysWithValues: proofKeys.map { ($0, true as Any) })
        report["status"] = "native-review-read-and-replayed"
        for key in proofKeys + ["status"] {
            var incomplete = report; incomplete.removeValue(forKey: key)
            #expect(throws: CodexHistoryError.unsafeMethod) {
                try reviewProbeExportDescriptor([:], root: root, home: home.path, path: path, report: incomplete)
            }
            #expect(!FileManager.default.fileExists(atPath: path))
        }
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent("auth.json").path,
            withDestinationPath: home.appendingPathComponent("missing").path)
        #expect(throws: CodexHistoryError.unsafeMethod) {
            try reviewProbeExportDescriptor([:], root: root, home: home.path, path: path, report: report)
        }
        try FileManager.default.removeItem(at: home.appendingPathComponent("auth.json"))
        #expect(throws: CodexHistoryError.unsafeMethod) {
            try reviewProbeExportDescriptor([:], root: root, home: home.path,
                path: home.appendingPathComponent("review-descriptor.json").path, report: report)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        #expect(throws: CodexHistoryError.unsafeMethod) {
            try reviewProbeExportDescriptor([:], root: root, home: home.path, path: path, report: report)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try reviewProbeExportDescriptor(["fake": "descriptor-boundary"], root: root, home: home.path, path: path, report: report)
        let info = try FileManager.default.attributesOfItem(atPath: path)
        #expect((info[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("{\"fake\":\"descriptor-boundary\"}".utf8))
        #expect(throws: CodexHistoryError.unsafeMethod) {
            try reviewProbeExportDescriptor([:], root: root, home: home.path, path: path, report: report)
        }
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: root.appendingPathComponent("missing").path)
        #expect(throws: CodexHistoryError.unsafeMethod) {
            try reviewProbeExportDescriptor([:], root: root, home: home.path, path: path, report: report)
        }
    }

    @Test func exactOwnedReviewIsReadTwiceThroughProductionClient() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SPILLCHECK_REVIEW_PROBE_HOME"] != nil else { return }
        let home = try #require(env["SPILLCHECK_REVIEW_PROBE_HOME"])
        let id = try #require(env["SPILLCHECK_REVIEW_PROBE_THREAD"])
        let turnID = try #require(env["SPILLCHECK_REVIEW_PROBE_TURN"])
        let liveItemID = try #require(env["SPILLCHECK_REVIEW_PROBE_ITEM"])
        let executable = try #require(env["SPILLCHECK_REVIEW_PROBE_EXECUTABLE"])
        let reportPath = try #require(env["SPILLCHECK_REVIEW_PROBE_REPORT"])
        let expectedHash = try #require(env["SPILLCHECK_REVIEW_PROBE_SHA256"])
        let expectedBytes = try #require(env["SPILLCHECK_REVIEW_PROBE_BYTES"].flatMap(Int.init))
        let expectedInputHash = try #require(env["SPILLCHECK_REVIEW_PROBE_INPUT_SHA256"])
        let expectedInputBytes = try #require(env["SPILLCHECK_REVIEW_PROBE_INPUT_BYTES"].flatMap(Int.init))
        let descriptorPath = env["SPILLCHECK_REVIEW_PROBE_DESCRIPTOR"]
        let liveInputID = env["SPILLCHECK_REVIEW_PROBE_INPUT_ITEM"]
        let root = URL(fileURLWithPath: home).deletingLastPathComponent()
        guard UUID(uuidString: id)?.uuidString.lowercased() == id,
              reviewProbeIdentifier(turnID), reviewProbeIdentifier(liveItemID),
              expectedHash.count == 64, expectedHash.allSatisfy({ "0123456789abcdef".contains($0) }),
              (1...16_384).contains(expectedBytes),
              expectedInputHash.count == 64, expectedInputHash.allSatisfy({ "0123456789abcdef".contains($0) }),
              (1...16_384).contains(expectedInputBytes),
              URL(fileURLWithPath: home).lastPathComponent == "home",
              (root.lastPathComponent.hasPrefix("spillcheck-native-review-")
                  || (descriptorPath != nil && root.lastPathComponent.hasPrefix("spillcheck-signed-review-"))),
              reviewProbeAuthAbsent(home), CodexAdapter.parserContract == "codex-content-contract-v16" else {
            throw CodexHistoryError.malformedResponse
        }
        try reviewProbePrivateDirectory(root.path)
        try reviewProbePrivateDirectory(home)
        try reviewProbePrivateDirectory(URL(fileURLWithPath: reportPath).deletingLastPathComponent().path)
        guard URL(fileURLWithPath: reportPath).lastPathComponent == "passive-report.json" else {
            throw CodexHistoryError.unsafeMethod
        }
        var reportInfo = stat()
        guard lstat(reportPath, &reportInfo) == -1 && errno == ENOENT else { throw CodexHistoryError.unsafeMethod }
        if let descriptorPath {
            guard let liveInputID, reviewProbeIdentifier(liveInputID) else { throw CodexHistoryError.malformedResponse }
            try reviewProbeDescriptorDestination(root: root, home: home, path: descriptorPath)
        }
        let work = root.appendingPathComponent("reader")
        let producerWork = root.appendingPathComponent("work").path
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let client = CodexAppServerHistoryClient(configuration: try .init(
            executableURL: URL(fileURLWithPath: executable), codexHomeURL: URL(fileURLWithPath: home),
            workingDirectoryURL: work, requestTimeout: 8, maximumResponseBytes: 2 * 1024 * 1024))
        var report: [String: Any] = ["schemaVersion": 1, "status": "unverified", "passive": true,
            "networkDenied": true, "forkDenied": true, "threadListCalls": 0, "resumeCalls": 0, "forkCalls": 0,
            "threadReadCalls": 0, "itemReadCalls": 0, "turnReadCalls": 0,
            "parserContract": CodexAdapter.parserContract, "parentNativeSourceOnly": true,
            "childCoverageEstablished": false, "signedAcceptanceEstablished": false,
            "selectionBasis": "unique-owned-turn-null-phase-live-bytes"]
        var stage = "preparing-parser"
        var exportedDescriptor: [String: Any]?
        do {
            let crypto = try BackgroundCryptography.ephemeralForTesting()
            let adapter = try codexTestAdapter(interface: .standaloneCLI, version: "0.162.1", t3Version: nil)
            var prior: CollectedSource?, firstEntry: CodexJSON?
            var priorInput: CollectedSource?, firstInputEntry: CodexJSON?
            var priorInputTurnRelationship: ReviewProbeInputTurnRelationship?
            for attempt in 0..<2 {
                guard reviewProbeAuthAbsent(home) else { throw CodexHistoryError.unsafeMethod }
                stage = "reading-thread"
                let thread = try await client.readThread(id)
                report["threadReadCalls"] = attempt + 1
                guard thread.thread["id"].string == id, thread.thread["cliVersion"].string == "0.162.1",
                      thread.thread["parentThreadId"] == .null, thread.thread["forkedFromId"] == .null,
                      thread.thread["ephemeral"].bool == false, thread.thread["cwd"].string == producerWork,
                      thread.readerVersion == "0.162.1" else { throw CodexHistoryError.malformedResponse }
                stage = "reading-items-and-turns"
                let page = try await client.listItems(threadID: id, cursor: nil, limit: 256)
                report["itemReadCalls"] = attempt + 1
                let turns = try await client.listTurns(threadID: id, cursor: nil, limit: 256, direction: .descending)
                report["turnReadCalls"] = attempt + 1
                guard page.nextCursor == nil, turns.nextCursor == nil, page.data.count <= 256, turns.data.count <= 256,
                      page.readerVersion == "0.162.1", turns.readerVersion == "0.162.1" else {
                    throw CodexHistoryError.responseLimitExceeded
                }
                let allowed: Set<String> = ["userMessage", "agentMessage", "reasoning", "enteredReviewMode", "exitedReviewMode"]
                report["allowedItemKindCounts"] = Dictionary(uniqueKeysWithValues: allowed.sorted().map { kind in
                    (kind, page.data.filter { $0["item"]["type"].string == kind }.count)
                })
                report["otherItemKindCount"] = page.data.filter { !allowed.contains($0["item"]["type"].string ?? "") }.count
                guard page.data.allSatisfy({ allowed.contains($0["item"]["type"].string ?? "") }) else {
                    throw CodexHistoryError.unsafeMethod
                }
                let times = reviewProbeTurnTimes(turns.data)
                stage = "selecting-original-native-review"
                let entry = try reviewProbeSelection(page.data, turn: turnID, hash: expectedHash, count: expectedBytes)
                let item = entry["item"], nativeID = try #require(item["id"].string)
                let text = try #require(item["text"].string), bytes = Data(text.utf8)
                stage = "selecting-original-native-input"
                let inputDiagnostic = reviewProbeInputDiagnostic(page.data, reviewTurn: turnID, output: entry,
                    hash: expectedInputHash, count: expectedInputBytes, times: times, turns: turns.data)
                report["inputDiagnostic"] = inputDiagnostic
                if let failedStage = reviewProbeInputFailureStage(inputDiagnostic) {
                    stage = failedStage
                    throw CodexHistoryError.malformedResponse
                }
                let nativeInputs = page.data.filter { $0["item"]["type"].string == "userMessage" }
                let inputTurn = try #require(nativeInputs.first?["turnId"].string)
                let inputTurnRelationship = try reviewProbeInputTurnRelationship(turns.data, inputTurn: inputTurn, reviewTurn: turnID)
                let inputEntry = try reviewProbeInputSelection(page.data, turn: inputTurn, hash: expectedInputHash, count: expectedInputBytes)
                let inputID = try #require(inputEntry["item"]["id"].string)
                let inputContent = try #require(inputEntry["item"]["content"].array)
                let inputText = try #require(inputContent[0]["text"].string)
                let inputBytes = Data(inputText.utf8)
                let presentations = page.data.filter { ["enteredReviewMode", "exitedReviewMode"].contains($0["item"]["type"].string ?? "") }
                let enters = presentations.filter { $0["item"]["type"].string == "enteredReviewMode" }
                let exits = presentations.filter { $0["item"]["type"].string == "exitedReviewMode" }
                stage = "validating-original-input-and-presentation"
                guard enters.count == 1, exits.count == 1,
                      presentations.allSatisfy({ $0["turnId"].string == turnID }),
                      page.data.filter({ $0["item"]["id"].string == nativeID }).count == 1,
                      page.data.filter({ $0["item"]["id"].string == inputID }).count == 1,
                      inputID != nativeID, enters[0]["item"]["review"].string == inputText,
                      exits[0]["item"]["review"].string == text,
                      text.components(separatedBy: "SPILLCHECK_FAKE_NATIVE_REVIEW_42").count == 2 else {
                    throw CodexHistoryError.malformedResponse
                }
                stage = "checking-original-output-timestamp"
                let originalTime = try reviewProbeOriginalTime(entry, times: times)
                stage = "checking-original-input-timestamp"
                let originalInputTime = try reviewProbeOriginalTime(inputEntry, times: times, userPrompt: true)
                stage = "normalizing-original-native-review"
                let batch = try await adapter.importPublicItems(.init(data: [entry], readerVersion: page.readerVersion),
                    thread: thread.thread, observedAt: Date(), turnTimes: times, cryptography: crypto)
                report["gapReasons"] = batch.coverageGaps.map { $0.reason.rawValue }.sorted()
                report["gapDiagnostics"] = batch.coverageGaps.compactMap { $0.diagnosticCode?.rawValue }.sorted()
                guard batch.sources.count == 1, batch.coverageGaps.isEmpty else { throw CodexHistoryError.malformedResponse }
                let source = batch.sources[0], metadata = source.record.metadata
                guard metadata.identity.session.provider == .codex, metadata.identity.session.sessionID == id,
                      metadata.identity.itemID == nativeID, metadata.locator == .upstreamItem,
                      metadata.contentType == .intermediateResponse, metadata.contentTime == originalTime.0,
                      metadata.timeBasis == nil, metadata.origin.adapterID == "codex",
                      metadata.origin.adapterVersion == CodexAdapter.adapterVersion,
                      metadata.origin.agentVersion == "0.162.1", metadata.origin.interface == .standaloneCLI,
                      metadata.origin.canonicalization == .exclusiveAuthority, source.record.segments.count == 1,
                      source.record.segments[0].id == "/text", source.record.segments[0].utf8 == bytes else {
                    throw CodexHistoryError.malformedResponse
                }
                stage = "normalizing-original-native-input"
                let inputBatch = try await adapter.importPublicItems(.init(data: [inputEntry], readerVersion: page.readerVersion),
                    thread: thread.thread, observedAt: Date(), turnTimes: times, cryptography: crypto)
                report["inputGapReasons"] = inputBatch.coverageGaps.map { $0.reason.rawValue }.sorted()
                report["inputGapDiagnostics"] = inputBatch.coverageGaps.compactMap { $0.diagnosticCode?.rawValue }.sorted()
                guard inputBatch.sources.count == 1, inputBatch.coverageGaps.isEmpty else {
                    throw CodexHistoryError.malformedResponse
                }
                let inputSource = inputBatch.sources[0], inputMetadata = inputSource.record.metadata
                guard inputMetadata.identity.session.provider == .codex, inputMetadata.identity.session.sessionID == id,
                      inputMetadata.identity.itemID == inputID, inputMetadata.locator == .upstreamItem,
                      inputMetadata.contentType == .userPrompt, inputMetadata.contentTime == originalInputTime.0,
                      inputMetadata.timeBasis == nil, inputMetadata.origin.adapterID == "codex",
                      inputMetadata.origin.adapterVersion == CodexAdapter.adapterVersion,
                      inputMetadata.origin.agentVersion == "0.162.1", inputMetadata.origin.interface == .standaloneCLI,
                      inputMetadata.origin.canonicalization == .exclusiveAuthority,
                      inputSource.record.segments.count == 1, inputSource.record.segments[0].id == "/content/0/text",
                      inputSource.record.segments[0].utf8 == inputBytes,
                      inputMetadata.identity != metadata.identity else { throw CodexHistoryError.malformedResponse }
                stage = "reporting-separate-presentation-gaps"
                let presentationBatch = try await adapter.importPublicItems(.init(data: presentations, readerVersion: page.readerVersion),
                    thread: thread.thread, observedAt: Date(), turnTimes: times, cryptography: crypto)
                guard presentationBatch.sources.isEmpty else { throw CodexHistoryError.malformedResponse }
                report["presentationItemCount"] = presentations.count
                report["presentationSourceCount"] = presentationBatch.sources.count
                report["presentationGapReasons"] = presentationBatch.coverageGaps.map { $0.reason.rawValue }.sorted()
                report["presentationGapDiagnostics"] = presentationBatch.coverageGaps.compactMap { $0.diagnosticCode?.rawValue }.sorted()
                report["presentationRequiredGapCount"] = presentationBatch.coverageGaps.filter { $0.isRequiredFormatFailure == true }.count
                report["wholeSessionGapFreeEstablished"] = false
                if let prior {
                    guard firstEntry == entry, prior.record.metadata.identity == metadata.identity,
                          prior.record.metadata.contentTime == metadata.contentTime,
                          prior.record.revision == source.record.revision, prior.record.segments == source.record.segments else {
                        throw CodexHistoryError.malformedResponse
                    }
                    report["actualSecondRead"] = true; report["replayStable"] = true
                    report["nativeItemIdentityStable"] = true
                } else { prior = source; firstEntry = entry }
                if let priorInput {
                    guard firstInputEntry == inputEntry,
                          priorInputTurnRelationship == inputTurnRelationship,
                          priorInput.record.metadata.identity == inputMetadata.identity,
                          priorInput.record.metadata.contentTime == inputMetadata.contentTime,
                          priorInput.record.revision == inputSource.record.revision,
                          priorInput.record.segments == inputSource.record.segments else {
                        throw CodexHistoryError.malformedResponse
                    }
                    report["inputReplayStable"] = true; report["inputNativeIdentityStable"] = true
                    report["inputTurnRelationshipStable"] = true
                } else {
                    priorInput = inputSource; firstInputEntry = inputEntry
                    priorInputTurnRelationship = inputTurnRelationship
                }
                for key in ["metadataMatches", "nativeReviewMatchesLiveBytes", "nullPhasePresent", "sourceIdentityMatches",
                    "sourceBytesPreserved", "sourceOriginVerified", "intermediateResponseMapping",
                    "originalTimestampVerified", "targetGapFree", "presentationNotScanned", "onlyExpectedItemKinds", "noToolItems"] { report[key] = true }
                for key in ["nativeInputMatchesLiveBytes", "nativeInputMatchesEnteredReview", "inputSourceIdentityMatches",
                    "inputSourceBytesPreserved", "inputSourceOriginVerified", "userPromptMapping",
                    "inputOriginalTimestampVerified", "inputTargetGapFree"] { report[key] = true }
                report["liveItemIDEqualsPersistedItemID"] = liveItemID == nativeID
                if let liveInputID { report["liveInputItemIDEqualsPersistedItemID"] = liveInputID == inputID }
                report["timeEvidence"] = originalTime.1
                report["readerVersion"] = page.readerVersion; report["producerVersion"] = thread.thread["cliVersion"].string
                report["reviewItemCount"] = 1; report["reviewSourceCount"] = 1
                report["reviewTextSHA256"] = expectedHash; report["reviewTextBytes"] = bytes.count
                report["inputTimeEvidence"] = originalInputTime.1
                report["inputTurnMatchesReviewTurn"] = inputTurn == turnID
                report["inputTurnRelationshipVerified"] = true
                report["inputTurnRelation"] = inputTurnRelationship.kind.rawValue
                report["inputItemCount"] = 1; report["inputSourceCount"] = 1
                report["totalOriginalSourceCount"] = batch.sources.count + inputBatch.sources.count
                report["inputTextSHA256"] = expectedInputHash; report["inputTextBytes"] = inputBytes.count
            }
            if descriptorPath != nil {
                exportedDescriptor = try reviewProbeNativeDescriptor(threadID: id, turnID: turnID,
                    input: try #require(firstInputEntry), output: try #require(firstEntry),
                    relationship: try #require(priorInputTurnRelationship), inputHash: expectedInputHash,
                    inputCount: expectedInputBytes, outputHash: expectedHash, outputCount: expectedBytes)
            }
            report["status"] = "native-review-read-and-replayed"
        } catch {
            report["status"] = "native-review-unverified"; report["failureStage"] = stage
        }
        await client.close()
        report["readerShutdownCompletedWithinDeadline"] = await client.lastShutdownCompletedWithinDeadline == true
        report["authAbsentAfterReads"] = reviewProbeAuthAbsent(home)
        if !reviewProbeAuthAbsent(home) {
            report["status"] = "native-review-unverified"; report["failureStage"] = "post-read-auth-boundary"
        }
        if let descriptorPath {
            do {
                guard let exportedDescriptor else { throw CodexHistoryError.malformedResponse }
                try reviewProbeExportDescriptor(exportedDescriptor, root: root, home: home, path: descriptorPath, report: report)
                report["persistedOriginalDescriptorExported"] = true
            } catch {
                report["persistedOriginalDescriptorExported"] = false
                report["status"] = "native-review-unverified"
                if report["failureStage"] == nil { report["failureStage"] = "exporting-original-descriptor" }
            }
        }
        try reviewProbeWriteReport(JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), path: reportPath)
    }
}
