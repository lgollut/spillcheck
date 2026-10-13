import CryptoKit
import Darwin
import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

/// Same optional native timestamp projection as CodexHistoryWork. A nullable
/// unrelated turn does not invalidate an item carrying its own original time.
private func hookProbeTurnTimes(_ turns: [CodexJSON]) -> [String: DateInterval] {
    var result: [String: DateInterval] = [:]
    for turn in turns {
        if let id = turn["id"].string, !id.isEmpty, let start = turn["startedAt"].number,
           let end = turn["completedAt"].number ?? turn["startedAt"].number,
           start.isFinite, end.isFinite, end >= start {
            result[id] = DateInterval(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
        }
    }
    return result
}

private func hookProbeTurnIdentifier(_ value: String?) -> Bool {
    guard let value else { return false }
    return !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains { $0.value < 32 }
}

/// Private cross-process handoff only. The public report never contains these IDs.
private func hookProbeWriteDescriptor(_ data: Data, root: URL, path: String) throws {
    guard path == root.appendingPathComponent("native-content-descriptor.json").path,
          data.count > 0, data.count <= 8192, let resolved = realpath(root.path, nil) else {
        throw CodexHistoryError.unsafeMethod
    }
    defer { free(resolved) }
    guard String(cString: resolved) == root.path else { throw CodexHistoryError.unsafeMethod }
    let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw CodexHistoryError.unsafeMethod }
    defer { close(directory) }
    var info = stat()
    guard fstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
          info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw CodexHistoryError.unsafeMethod }
    let fd = openat(directory, "native-content-descriptor.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
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

@Suite("Opt-in disposable native Codex hook prompt")
struct CodexHookPromptLiveTests {
    @Test func absentUnrelatedTurnTimesDoNotDiscardAnOriginalInterval() {
        let times = hookProbeTurnTimes([
            .object(["id": .string("unrelated"), "startedAt": .null, "completedAt": .null]),
            .object(["id": .string("owned"), "startedAt": .number(100), "completedAt": .number(110)]),
            .object(["id": .string("invalid"), "startedAt": .number(110), "completedAt": .number(100)])
        ])
        #expect(Set(times.keys) == ["owned"])
        #expect(times["owned"] == DateInterval(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 110)))
    }

    @Test func hookTargetWithoutAnyOriginalTimestampStillReportsGap() async throws {
        let entry = CodexJSON.object(["turnId": .string("owned"), "item": .object([
            "id": .string("hook-item"), "type": .string("hookPrompt"), "fragments": .array([
                .object(["text": .string("harmless"), "hookRunId": .string("run")])])])])
        let adapter = try codexTestAdapter(version: "0.162.1")
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let missing = try await adapter.importPublicItems(.init(data: [entry]), thread: codexThread(), observedAt: Date(),
            turnTimes: hookProbeTurnTimes([.object(["id": .string("owned"), "startedAt": .null])]), cryptography: crypto)
        #expect(missing.sources.isEmpty && missing.coverageGaps.contains { $0.reason == .missingTimestamp })
        let original = try await adapter.importPublicItems(.init(data: [entry]), thread: codexThread(), observedAt: Date(),
            turnTimes: hookProbeTurnTimes([.object(["id": .string("owned"), "startedAt": .number(100), "completedAt": .number(110)])]),
            cryptography: crypto)
        #expect(original.sources.count == 1 && original.coverageGaps.isEmpty)
    }

    @Test func nativeHistoryTurnIdentifiersMayBeOpaqueWithoutChangingSessionAuthority() {
        #expect(hookProbeTurnIdentifier("rollout-3"))
        #expect(hookProbeTurnIdentifier("00000000-0000-4000-8000-000000000001"))
        for value: String? in [nil, "", "turn\n", String(repeating: "a", count: 257)] {
            #expect(!hookProbeTurnIdentifier(value))
        }
    }

    @Test func privateDescriptorExportIsExclusiveBoundedAndRootLocal() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("spillcheck-hook-export-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("native-content-descriptor.json").path
        try hookProbeWriteDescriptor(Data("{}".utf8), root: root, path: path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("{}".utf8))
        #expect(throws: CodexHistoryError.unsafeMethod) { try hookProbeWriteDescriptor(Data("{}".utf8), root: root, path: path) }
        #expect(throws: CodexHistoryError.unsafeMethod) { try hookProbeWriteDescriptor(Data("{}".utf8), root: root, path: root.appendingPathComponent("other.json").path) }
        try FileManager.default.removeItem(atPath: path)
        #expect(throws: CodexHistoryError.unsafeMethod) { try hookProbeWriteDescriptor(Data(repeating: 0, count: 8193), root: root, path: path) }
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: root.appendingPathComponent("absent").path)
        #expect(throws: CodexHistoryError.unsafeMethod) { try hookProbeWriteDescriptor(Data("{}".utf8), root: root, path: path) }
    }

    @Test func exactOwnedHookPromptIsReadTwiceThroughProductionClient() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SPILLCHECK_HOOK_PROBE_HOME"] != nil else { return }
        let home = try #require(env["SPILLCHECK_HOOK_PROBE_HOME"])
        let id = try #require(env["SPILLCHECK_HOOK_PROBE_THREAD"])
        let selectionPath = try #require(env["SPILLCHECK_HOOK_PROBE_SELECTION"])
        let executable = try #require(env["SPILLCHECK_HOOK_PROBE_EXECUTABLE"])
        let reportPath = try #require(env["SPILLCHECK_HOOK_PROBE_REPORT"])
        let attributes = try FileManager.default.attributesOfItem(atPath: selectionPath)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 8192,
              UUID(uuidString: id)?.uuidString.lowercased() == id,
              URL(fileURLWithPath: home).lastPathComponent == "home",
              URL(fileURLWithPath: home).deletingLastPathComponent().lastPathComponent.hasPrefix("spillcheck-native-hook-"),
              !FileManager.default.fileExists(atPath: home + "/auth.json") else {
            throw CodexHistoryError.malformedResponse
        }
        let selection = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: selectionPath))) as? [String: Any])
        let reason = try #require(selection["reason"] as? String)
        let identityPrompt = try #require(selection["identityPrompt"] as? String)
        let fixturePrompt = try #require(selection["fixturePrompt"] as? String)
        let command = try #require(selection["identityCommand"] as? String)
        let callbackTurn = try #require(selection["callbackTurnID"] as? String)
        let expected = "SPILLCHECK_INJECTED_HOOK_ONLY_97 é🙂\nThis is harmless hook-provided input. Do not use tools. Reply with only the following line, without punctuation or formatting:\nSPILLCHECK_HOOK_AFTER_42"
        guard reason == expected, selection["threadID"] as? String == id,
              selection["home"] as? String == home,
              !callbackTurn.isEmpty, callbackTurn.utf8.count <= 256,
              !callbackTurn.unicodeScalars.contains(where: { $0.value < 32 }),
              !identityPrompt.contains("SPILLCHECK_INJECTED_HOOK_ONLY_97"),
              !fixturePrompt.contains("SPILLCHECK_INJECTED_HOOK_ONLY_97") else {
            throw CodexHistoryError.malformedResponse
        }
        let root = URL(fileURLWithPath: home).deletingLastPathComponent()
        let producerWork = root.appendingPathComponent("work").path
        guard selection["cwd"] as? String == producerWork else { throw CodexHistoryError.malformedResponse }
        let work = root.appendingPathComponent("reader")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let client = CodexAppServerHistoryClient(configuration: try .init(
            executableURL: URL(fileURLWithPath: executable), codexHomeURL: URL(fileURLWithPath: home),
            workingDirectoryURL: work, requestTimeout: 8, maximumResponseBytes: 2 * 1024 * 1024))
        var report: [String: Any] = ["schemaVersion": 1, "status": "unverified", "passive": true,
            "networkDenied": true, "forkDenied": true, "threadListCalls": 0, "resumeCalls": 0,
            "threadReadCalls": 0, "itemReadCalls": 0, "turnReadCalls": 0, "parserContract": CodexAdapter.parserContract]
        var privateDescriptor: Data?
        var stage = "preparing-parser"
        do {
            let crypto = try BackgroundCryptography.ephemeralForTesting()
            let adapter = try codexTestAdapter(interface: .standaloneCLI, version: "0.162.1", t3Version: nil)
            var prior: CollectedSource?
            var priorEntry: CodexJSON?
            for attempt in 0..<2 {
                stage = "reading-thread"
                let thread = try await client.readThread(id)
                report["threadReadCalls"] = attempt + 1
                guard thread.thread["id"].string == id, thread.thread["cliVersion"].string == "0.162.1",
                      thread.thread["parentThreadId"] == .null, thread.thread["forkedFromId"] == .null,
                      thread.thread["ephemeral"].bool == false, thread.thread["cwd"].string == producerWork,
                      thread.readerVersion == "0.162.1" else { throw CodexHistoryError.malformedResponse }
                stage = "reading-items"
                let page = try await client.listItems(threadID: id, cursor: nil, limit: 256)
                report["itemReadCalls"] = attempt + 1
                // Same bounded original-time fallback as the production adapter;
                // Date() below is observation time, never fabricated content time.
                stage = "reading-turns"
                let turns = try await client.listTurns(threadID: id, cursor: nil, limit: 256, direction: .descending)
                report["turnReadCalls"] = attempt + 1
                stage = "verifying-page-bounds"
                report["returnedItemCount"] = page.data.count; report["returnedTurnCount"] = turns.data.count
                report["itemPageComplete"] = page.nextCursor == nil; report["turnPageComplete"] = turns.nextCursor == nil
                report["turnReaderMatches"] = turns.readerVersion == "0.162.1"
                report["itemReaderMatches"] = page.readerVersion == "0.162.1"
                guard turns.nextCursor == nil, turns.data.count <= 256, turns.readerVersion == "0.162.1" else {
                    throw CodexHistoryError.responseLimitExceeded
                }
                let turnTimes = hookProbeTurnTimes(turns.data)
                report["usableTurnIntervalCount"] = turnTimes.count
                let allowed: Set<String> = ["userMessage", "agentMessage", "reasoning", "commandExecution", "hookPrompt"]
                stage = "verifying-item-kinds"
                report["allowedItemKindCounts"] = Dictionary(uniqueKeysWithValues: allowed.sorted().map { kind in
                    (kind, page.data.filter { $0["item"]["type"].string == kind }.count)
                })
                report["otherItemKindCount"] = page.data.filter { !allowed.contains($0["item"]["type"].string ?? "") }.count
                guard page.nextCursor == nil, page.readerVersion == "0.162.1", page.data.count <= 256,
                      page.data.allSatisfy({ allowed.contains($0["item"]["type"].string ?? "") }) else {
                    throw CodexHistoryError.unsafeMethod
                }
                // Exact allowed human inputs and sole identity command prevent an
                // assistant echo or another command from manufacturing the proof.
                let users = page.data.filter { $0["item"]["type"].string == "userMessage" }
                let userTexts = users.map { entry in
                    entry["item"]["content"].array?.compactMap { $0["text"].string }.joined(separator: "") ?? ""
                }
                stage = "verifying-human-inputs"
                report["userInputCount"] = userTexts.count
                report["identityInputExactCount"] = userTexts.filter { $0 == identityPrompt }.count
                report["fixtureInputExactCount"] = userTexts.filter { $0 == fixturePrompt }.count
                report["reasonAbsentUserInputs"] = userTexts.allSatisfy { !$0.contains("SPILLCHECK_INJECTED_HOOK_ONLY_97") }
                guard userTexts.count == 2, Set(userTexts) == Set([identityPrompt, fixturePrompt]),
                      userTexts.allSatisfy({ !$0.contains("SPILLCHECK_INJECTED_HOOK_ONLY_97") }) else {
                    throw CodexHistoryError.malformedResponse
                }
                let commands = page.data.filter { $0["item"]["type"].string == "commandExecution" }
                let expectedCommands = try #require(selection["allowedIdentityCommands"] as? [String])
                stage = "verifying-identity-command"
                report["identityCommandCount"] = commands.count
                if let item = commands.first?["item"] {
                    report["commandSpellingMatches"] = expectedCommands.contains(item["command"].string ?? "")
                    report["commandCwdMatches"] = item["cwd"].string == producerWork
                    report["commandCompleted"] = item["status"].string == "completed"
                    report["commandExitZero"] = item["exitCode"].number == 0
                    report["commandHasOutput"] = item["aggregatedOutput"].string != nil
                    report["commandOutputMatches"] = item["aggregatedOutput"].string?.trimmingCharacters(in: .whitespacesAndNewlines) == "{\"recorded\":true}"
                }
                guard commands.count == 1, expectedCommands.contains(command), expectedCommands.count <= 4,
                      expectedCommands.contains(commands[0]["item"]["command"].string ?? ""),
                      commands[0]["item"]["cwd"].string == producerWork,
                      commands[0]["item"]["status"].string == "completed",
                      commands[0]["item"]["exitCode"].number == 0,
                      commands[0]["item"]["aggregatedOutput"].string?.trimmingCharacters(in: .whitespacesAndNewlines) == "{\"recorded\":true}" else {
                    throw CodexHistoryError.malformedResponse
                }
                let hooks = page.data.filter { $0["item"]["type"].string == "hookPrompt" }
                stage = "verifying-native-hook-prompt"
                report["returnedHookPromptCount"] = hooks.count
                if let hook = hooks.first {
                    let nativeTurn = hook["turnId"].string ?? ""
                    report["nativeTurnIsUUID"] = UUID(uuidString: nativeTurn)?.uuidString.lowercased() == nativeTurn
                    report["nativeTurnBounded"] = hookProbeTurnIdentifier(nativeTurn)
                    report["nativeItemHasTimestamp"] = hook["completedAtMs"].number != nil || hook["startedAtMs"].number != nil
                    report["nativeTurnHasInterval"] = turnTimes[nativeTurn] != nil
                    report["nativeFragmentCount"] = hook["item"]["fragments"].array?.count ?? -1
                    report["nativeFragmentTextMatches"] = hook["item"]["fragments"].array?.first?["text"].string == reason
                    report["nativeHookRunIDBounded"] = hook["item"]["fragments"].array?.first?["hookRunId"].string.map {
                        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256
                    } ?? false
                }
                guard hooks.count == 1, let actualTurn = hooks[0]["turnId"].string,
                      hookProbeTurnIdentifier(actualTurn),
                      let actualItem = hooks[0]["item"]["id"].string, !actualItem.isEmpty, actualItem.utf8.count <= 256,
                      let fragments = hooks[0]["item"]["fragments"].array, fragments.count == 1,
                      fragments[0]["text"].string == reason,
                      let runID = fragments[0]["hookRunId"].string, !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      runID.utf8.count <= 256 else { throw CodexHistoryError.malformedResponse }
                stage = "normalizing-native-hook-prompt"
                let batch = try await adapter.importPublicItems(.init(data: hooks, readerVersion: page.readerVersion),
                    thread: thread.thread, observedAt: Date(), turnTimes: turnTimes, cryptography: crypto)
                report["gapReasons"] = batch.coverageGaps.map { $0.reason.rawValue }.sorted()
                report["gapDiagnostics"] = batch.coverageGaps.compactMap { $0.diagnosticCode?.rawValue }.sorted()
                guard batch.sources.count == 1, batch.coverageGaps.isEmpty else { throw CodexHistoryError.malformedResponse }
                let source = batch.sources[0], metadata = source.record.metadata
                stage = "verifying-normalized-source"
                guard metadata.identity.session.provider == .codex, metadata.identity.session.sessionID == id,
                      metadata.identity.itemID == actualItem, metadata.locator == .upstreamItem,
                      metadata.contentType == .userPrompt, metadata.origin.adapterID == "codex",
                      metadata.origin.adapterVersion == CodexAdapter.adapterVersion,
                      metadata.origin.agentVersion == "0.162.1", metadata.origin.interface == .standaloneCLI,
                      metadata.origin.canonicalization == .exclusiveAuthority,
                      source.record.segments.count == 1, source.record.segments[0].id == "/fragments/0/text",
                      source.record.segments[0].utf8 == Data(reason.utf8) else { throw CodexHistoryError.malformedResponse }
                if let prior {
                    stage = "verifying-second-read"
                    guard priorEntry == hooks[0], prior.record.metadata.identity == metadata.identity,
                          prior.record.revision == source.record.revision, prior.record.segments == source.record.segments else {
                        throw CodexHistoryError.malformedResponse
                    }
                    report["actualSecondRead"] = true; report["replayStable"] = true
                } else { prior = source; priorEntry = hooks[0] }
                for key in ["nativeHookPromptVerified", "nativeTurnMeasured", "metadataMatches", "sourceIdentityMatches",
                    "sourceBytesAndPointersPreserved", "sourceOriginVerified", "userPromptMapping", "reasonAbsentHumanInput",
                    "hookRunIDMetadataOnly", "gapFree"] { report[key] = true }
                report["nativeTurnEqualsStopCallbackTurn"] = actualTurn == callbackTurn
                report["readerVersion"] = page.readerVersion; report["producerVersion"] = thread.thread["cliVersion"].string
                report["hookPromptItemCount"] = 1; report["hookPromptSourceCount"] = 1
                report["segmentCount"] = 1; report["segmentPointers"] = ["/fragments/0/text"]
                report["textBytes"] = reason.utf8.count
                report["textSHA256"] = SHA256.hash(data: Data(reason.utf8)).map { String(format: "%02x", $0) }.joined()
                guard hookProbeTurnIdentifier(actualItem), hookProbeTurnIdentifier(runID) else { throw CodexHistoryError.malformedResponse }
                privateDescriptor = try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 1, "fixtureKind": "hook-prompt", "threadID": id, "turnID": actualTurn,
                    "itemID": actualItem, "producerVersion": "0.162.1", "hookRunID": runID,
                    "segments": [["pointer": "/fragments/0/text", "textSHA256": report["textSHA256"]!, "textBytes": reason.utf8.count]]
                ], options: [.sortedKeys, .withoutEscapingSlashes])
            }
            report["status"] = "native-hook-prompt-read-and-replayed"
        } catch {
            report["status"] = "native-hook-prompt-unverified"; report["failureStage"] = stage
        }
        await client.close()
        report["readerShutdownCompletedWithinDeadline"] = await client.lastShutdownCompletedWithinDeadline == true
        if let path = env["SPILLCHECK_HOOK_PROBE_DESCRIPTOR"] {
            guard report["status"] as? String == "native-hook-prompt-read-and-replayed",
                  report["readerShutdownCompletedWithinDeadline"] as? Bool == true,
                  report["threadReadCalls"] as? Int == 2, report["itemReadCalls"] as? Int == 2,
                  report["actualSecondRead"] as? Bool == true, report["replayStable"] as? Bool == true,
                  let privateDescriptor else { throw CodexHistoryError.malformedResponse }
            try hookProbeWriteDescriptor(privateDescriptor, root: root, path: path)
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: reportPath), options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportPath)
    }
}
