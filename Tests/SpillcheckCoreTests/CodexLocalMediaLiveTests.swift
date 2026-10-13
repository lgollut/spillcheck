import CryptoKit
import Darwin
import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private let localMediaProbeMarker = "SPILLCHECK_FAKE_LOCAL_IMAGE_42"
private func localMediaProbeHash(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}
private func localMediaProbeIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
}
private func localMediaProbeDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
private func localMediaProbeAbsent(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == -1 && errno == ENOENT
}
private func localMediaProbeDirectory(_ path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
          info.st_uid == getuid(), info.st_mode & 0o077 == 0,
          let resolved = realpath(path, nil) else { throw CodexHistoryError.unsafeMethod }
    defer { free(resolved) }
    guard String(cString: resolved) == path else { throw CodexHistoryError.unsafeMethod }
}
private func localMediaProbeWrite(_ report: [String: Any], path: String, descriptor: Bool = false) throws {
    let options: JSONSerialization.WritingOptions = descriptor ? [.sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .prettyPrinted]
    let bytes = try JSONSerialization.data(withJSONObject: report, options: options)
    let url = URL(fileURLWithPath: path), parent = url.deletingLastPathComponent().path
    guard url.lastPathComponent == (descriptor ? "local-media-descriptor.json" : "passive-report.json"), bytes.count <= (descriptor ? 8192 : 65_536) else { throw CodexHistoryError.unsafeMethod }
    try localMediaProbeDirectory(parent)
    let directory = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw CodexHistoryError.unsafeMethod }
    defer { close(directory) }
    var info = stat()
    guard fstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
          info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw CodexHistoryError.unsafeMethod }
    let fd = openat(directory, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw CodexHistoryError.unsafeMethod }
    defer { close(fd) }
    try bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            guard count > 0 else { throw CodexHistoryError.unsafeMethod }
            offset += count
        }
    }
    guard fsync(fd) == 0 else { throw CodexHistoryError.unsafeMethod }
}

/// The first passive response supplies the persisted identity. A live event ID
/// is only compared later; legacy history can assign a different native ID.
private func localMediaProbeSelect(_ entries: [CodexJSON], turn: String, imagePath: String,
                                   textHash: String, textBytes: Int) throws -> (CodexJSON, Data) {
    let users = entries.filter { $0["item"]["type"].string == "userMessage" }
    guard users.count == 1, let entry = users.first, entry["turnId"].string == turn,
          let id = entry["item"]["id"].string, localMediaProbeIdentifier(id),
          let content = entry["item"]["content"].array, content.count == 2,
          let textFields = content[0].object, Set(textFields.keys) == ["type", "text", "text_elements"],
          content[0]["type"].string == "text", content[0]["text_elements"].array == [],
          let text = content[0]["text"].string,
          let imageFields = content[1].object, Set(imageFields.keys).isSubset(of: ["type", "path", "detail"]),
          content[1]["type"].string == "localImage", content[1]["path"].string == imagePath,
          imageFields["detail"] == nil || imageFields["detail"] == .null else { throw CodexHistoryError.malformedResponse }
    let bytes = Data(text.utf8)
    guard (1...16_384).contains(bytes.count), bytes.count == textBytes, localMediaProbeHash(bytes) == textHash,
          text.components(separatedBy: localMediaProbeMarker).count == 2,
          text.contains("\r\n"), text.unicodeScalars.contains(where: { $0.value > 127 }) else {
        throw CodexHistoryError.malformedResponse
    }
    return (entry, bytes)
}

private func localMediaProbeTime(_ entry: CodexJSON, interval: DateInterval) throws -> (Date, String) {
    if let milliseconds = entry["completedAtMs"].number ?? entry["startedAtMs"].number,
       milliseconds.isFinite, abs(milliseconds) < 1e15 {
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        // Turn seconds are coarse. This is the measured containing turn, not observation time.
        guard date >= interval.start, date < interval.end.addingTimeInterval(1) else { throw CodexHistoryError.malformedResponse }
        return (date, entry["completedAtMs"].number == nil ? "item-started" : "item-completed")
    }
    guard entry["completedAtMs"] == .null, entry["startedAtMs"] == .null else { throw CodexHistoryError.malformedResponse }
    return (interval.start, "matching-turn-interval")
}

@Suite("Opt-in disposable native Codex local image", .timeLimit(.minutes(1)))
struct CodexLocalMediaLiveTests {
    @Test func nativeSelectionRequiresUniqueUnmodifiedTextAndActualLocalImage() throws {
        let text = "Original é🙂\r\n" + localMediaProbeMarker, bytes = Data(text.utf8), image = "/owned/fixture.png"
        func row(_ imageBlock: [String: CodexJSON], id: String = "persisted-original") -> CodexJSON {
            .object(["turnId": .string("own-turn"), "item": .object(["id": .string(id), "type": .string("userMessage"),
                "content": .array([.object(["type": .string("text"), "text": .string(text), "text_elements": .array([])]), .object(imageBlock)])])])
        }
        let valid = ["type": CodexJSON.string("localImage"), "path": .string(image)]
        for block in [valid, valid.merging(["detail": .null], uniquingKeysWith: { _, new in new })] {
            let selected = try localMediaProbeSelect([row(block)], turn: "own-turn", imagePath: image,
                textHash: localMediaProbeHash(bytes), textBytes: bytes.count)
            #expect(selected.0["item"]["id"].string == "persisted-original" && selected.1 == bytes)
        }
        for block in [valid.merging(["type": .string("image")], uniquingKeysWith: { _, new in new }),
            valid.merging(["path": .string("/other/fixture.png")], uniquingKeysWith: { _, new in new }),
            valid.merging(["detail": .string("high")], uniquingKeysWith: { _, new in new }),
            valid.merging(["futureText": .string("unknown")], uniquingKeysWith: { _, new in new })] {
            #expect(throws: CodexHistoryError.malformedResponse) {
                try localMediaProbeSelect([row(block)], turn: "own-turn", imagePath: image,
                    textHash: localMediaProbeHash(bytes), textBytes: bytes.count)
            }
        }
        for rows in [[row(valid), row(valid, id: "second")], [row(valid, id: "")]] {
            #expect(throws: CodexHistoryError.malformedResponse) {
                try localMediaProbeSelect(rows, turn: "own-turn", imagePath: image,
                    textHash: localMediaProbeHash(bytes), textBytes: bytes.count)
            }
        }
        #expect(throws: CodexHistoryError.malformedResponse) {
            try localMediaProbeSelect([row(valid)], turn: "another-turn", imagePath: image,
                textHash: localMediaProbeHash(bytes), textBytes: bytes.count)
        }
        #expect(throws: CodexHistoryError.malformedResponse) {
            try localMediaProbeSelect([row(valid)], turn: "own-turn", imagePath: image,
                textHash: String(repeating: "0", count: 64), textBytes: bytes.count)
        }
    }

    @Test func originalTimeUsesNativeItemOrTheMeasuredMatchingTurn() throws {
        let interval = DateInterval(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 110))
        let measured = try localMediaProbeTime(.object(["completedAtMs": .number(105_123)]), interval: interval)
        #expect(measured.0 == Date(timeIntervalSince1970: 105.123) && measured.1 == "item-completed")
        let fallback = try localMediaProbeTime(.object([:]), interval: interval)
        #expect(fallback.0 == interval.start && fallback.1 == "matching-turn-interval")
        for value in [CodexJSON.string("bad"), .number(99_999), .number(111_000)] {
            #expect(throws: CodexHistoryError.malformedResponse) {
                try localMediaProbeTime(.object(["completedAtMs": value]), interval: interval)
            }
        }
    }

    @Test func exactOwnedLocalImageIsReadTwiceWithoutItsAttachmentFile() async throws {
        let env = ProcessInfo.processInfo.environment, prefix = "SPILLCHECK_LOCAL_MEDIA_PROBE_"
        guard env[prefix + "HOME"] != nil else { return }
        let home = try #require(env[prefix + "HOME"]), threadID = try #require(env[prefix + "THREAD"])
        let turnID = try #require(env[prefix + "TURN"]), liveID = try #require(env[prefix + "LIVE_ITEM"])
        let executable = try #require(env[prefix + "EXECUTABLE"]), reportPath = try #require(env[prefix + "REPORT"])
        let textHash = try #require(env[prefix + "TEXT_SHA256"]), textBytes = try #require(env[prefix + "TEXT_BYTES"].flatMap(Int.init))
        let imageHash = try #require(env[prefix + "IMAGE_SHA256"])
        let descriptorPath = env[prefix + "DESCRIPTOR"]
        let root = URL(fileURLWithPath: home).deletingLastPathComponent(), work = root.appendingPathComponent("work")
        let imagePath = work.appendingPathComponent("fixture.png").path
        guard UUID(uuidString: threadID)?.uuidString.lowercased() == threadID,
              localMediaProbeIdentifier(turnID), localMediaProbeIdentifier(liveID),
              localMediaProbeDigest(textHash), localMediaProbeDigest(imageHash), (1...16_384).contains(textBytes),
              URL(fileURLWithPath: home).lastPathComponent == "home",
              root.deletingLastPathComponent().path == "/private/tmp",
              root.lastPathComponent.hasPrefix("spillcheck-native-local-media-"),
              executable.hasPrefix("/"), localMediaProbeAbsent(home + "/auth.json"), localMediaProbeAbsent(imagePath) else {
            throw CodexHistoryError.unsafeMethod
        }
        for path in [root.path, home, work.path] { try localMediaProbeDirectory(path) }
        let readerWork = root.appendingPathComponent("reader")
        try FileManager.default.createDirectory(at: readerWork, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try localMediaProbeDirectory(readerWork.path)
        let client = CodexAppServerHistoryClient(configuration: try .init(executableURL: URL(fileURLWithPath: executable),
            codexHomeURL: URL(fileURLWithPath: home), workingDirectoryURL: readerWork,
            requestTimeout: 6, maximumResponseBytes: 2 * 1024 * 1024))
        var report: [String: Any] = ["schemaVersion": 1, "status": "unverified", "parserContract": CodexAdapter.parserContract,
            "passive": true, "networkDenied": true, "forkDenied": true, "threadListCalls": 0, "resumeCalls": 0, "forkCalls": 0,
            "threadReadCalls": 0, "itemReadCalls": 0, "turnReadCalls": 0, "authAbsentBeforeReads": true,
            "attachmentAbsentBeforeReads": true, "suppliedImageSHA256": imageHash,
            "signedAppAcceptance": false, "detectorRun": false, "attachmentContentScanned": false,
            "localAudioAcceptance": false, "fullHostAcceptance": false]
        if let descriptorPath {
            guard descriptorPath == root.appendingPathComponent("local-media-descriptor.json").path,
                  localMediaProbeAbsent(descriptorPath) else { throw CodexHistoryError.unsafeMethod }
        }
        var exportedDescriptor: [String: Any]?
        var stage = "preparing-parser"
        do {
            let crypto = try BackgroundCryptography.ephemeralForTesting()
            let adapter = try codexTestAdapter(interface: .standaloneCLI, version: "0.162.1", t3Version: nil)
            var prior: CollectedSource?, priorEntry: CodexJSON?, priorTurn: CodexJSON?
            for attempt in 0..<2 {
                guard localMediaProbeAbsent(home + "/auth.json"), localMediaProbeAbsent(imagePath) else { throw CodexHistoryError.unsafeMethod }
                stage = "reading-thread"
                let thread = try await client.readThread(threadID)
                report["threadReadCalls"] = attempt + 1
                guard thread.thread["id"].string == threadID, thread.thread["cliVersion"].string == "0.162.1",
                      thread.thread["parentThreadId"] == .null, thread.thread["forkedFromId"] == .null,
                      thread.thread["ephemeral"].bool == false, thread.thread["cwd"].string == work.path,
                      thread.readerVersion == "0.162.1" else { throw CodexHistoryError.malformedResponse }
                stage = "reading-items"
                let page = try await client.listItems(threadID: threadID, cursor: nil, limit: 256)
                report["itemReadCalls"] = attempt + 1
                guard page.nextCursor == nil, page.readerVersion == "0.162.1", !page.data.isEmpty, page.data.count <= 256,
                      page.data.allSatisfy({ ["userMessage", "agentMessage", "reasoning"].contains($0["item"]["type"].string ?? "")
                        && $0["turnId"].string == turnID && $0["item"]["id"].string.map(localMediaProbeIdentifier) == true }),
                      Set(page.data.compactMap { $0["item"]["id"].string }).count == page.data.count else {
                    throw CodexHistoryError.malformedResponse
                }
                stage = "reading-turns"
                let turns = try await client.listTurns(threadID: threadID, cursor: nil, limit: 256)
                report["turnReadCalls"] = attempt + 1
                guard turns.nextCursor == nil, turns.readerVersion == "0.162.1", turns.data.count == 1,
                      let turn = turns.data.first, turn["id"].string == turnID,
                      turn["status"].string == "completed", turn["error"] == .null,
                      let start = turn["startedAt"].number, let end = turn["completedAt"].number,
                      start.isFinite, end.isFinite, abs(start) < 1e12, abs(end) < 1e12, end >= start else {
                    throw CodexHistoryError.malformedResponse
                }
                let interval = DateInterval(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
                stage = "selecting-native-input"
                let (entry, bytes) = try localMediaProbeSelect(page.data, turn: turnID, imagePath: imagePath, textHash: textHash, textBytes: textBytes)
                let nativeID = try #require(entry["item"]["id"].string)
                let (originalTime, basis) = try localMediaProbeTime(entry, interval: interval)
                stage = "normalizing-native-input"
                let batch = try await adapter.importPublicItems(.init(data: [entry], readerVersion: page.readerVersion),
                    thread: thread.thread, observedAt: Date(), turnTimes: [turnID: interval], cryptography: crypto)
                report["gapReasons"] = batch.coverageGaps.map { $0.reason.rawValue }.sorted()
                report["gapDiagnostics"] = batch.coverageGaps.compactMap { $0.diagnosticCode?.rawValue }.sorted()
                guard batch.sources.count == 1, batch.coverageGaps.count == 1, batch.recoveredReferences.isEmpty,
                      let gap = batch.coverageGaps.first, gap.reason == .unsupportedContent,
                      gap.diagnosticCode == .excludedBinaryContent, gap.excludedContent == true,
                      gap.isRequiredFormatFailure == false, !gap.requiresAnalysis, gap.sourceKind == .codexUserMessage,
                      gap.contentType == .userPrompt, gap.recovery?.constraint == .recognizedLocalMedia,
                      gap.recovery?.session?.sessionID == threadID, gap.recovery?.itemID == nativeID,
                      gap.recovery?.locator == .upstreamItem, gap.recovery?.contentTime == originalTime else {
                    throw CodexHistoryError.malformedResponse
                }
                let source = batch.sources[0], metadata = source.record.metadata
                guard metadata.identity.session.provider == .codex, metadata.identity.session.profileID == adapter.profileID,
                      metadata.identity.session.sessionID == threadID, metadata.identity.itemID == nativeID,
                      metadata.contentTime == originalTime, metadata.timeBasis == nil,
                      metadata.locator == .upstreamItem, metadata.contentType == .userPrompt,
                      metadata.origin.adapterID == "codex", metadata.origin.adapterVersion == CodexAdapter.adapterVersion,
                      metadata.origin.agentVersion == "0.162.1", metadata.origin.interface == .standaloneCLI,
                      metadata.origin.canonicalization == .exclusiveAuthority, source.record.segments.count == 1,
                      source.record.segments[0].id == "/content/0/text", source.record.segments[0].utf8 == bytes else {
                    throw CodexHistoryError.malformedResponse
                }
                if let prior {
                    guard priorEntry == entry, priorTurn == turn, prior.record.metadata.identity == metadata.identity,
                          prior.record.metadata.contentTime == metadata.contentTime, prior.record.metadata.origin == metadata.origin,
                          prior.record.revision == source.record.revision, prior.record.segments == source.record.segments else {
                        throw CodexHistoryError.malformedResponse
                    }
                    for key in ["actualSecondRead", "replayStable", "nativeItemIdentityStable"] { report[key] = true }
                } else { prior = source; priorEntry = entry; priorTurn = turn }
                for key in ["metadataMatches", "nativeLocalImageMatchesFixture", "nativeTextMatchesProducer", "sourceIdentityMatches",
                    "sourceBytesAndPointersPreserved", "sourceOriginVerified", "userPromptMapping", "originalTimestampVerified",
                    "noToolItems", "onlyExpectedExclusion", "recognizedLocalMediaProof"] { report[key] = true }
                report["liveItemIDMatchesNative"] = liveID == nativeID
                report["timestampBasis"] = basis
                report["readerVersion"] = page.readerVersion
                report["producerVersion"] = thread.thread["cliVersion"].string
                report["userItemCount"] = 1; report["sourceCount"] = 1; report["segmentCount"] = 1
                report["excludedGapCount"] = 1; report["requiredGapCount"] = 0
                report["textSHA256"] = localMediaProbeHash(bytes); report["textBytes"] = bytes.count
                exportedDescriptor = ["schemaVersion": 1, "threadID": threadID, "turnID": turnID,
                    "itemID": nativeID, "producerVersion": "0.162.1", "textSHA256": localMediaProbeHash(bytes),
                    "textBytes": bytes.count, "imageSHA256": imageHash]
            }
            report["authAbsentAfterReads"] = localMediaProbeAbsent(home + "/auth.json")
            report["attachmentAbsentAfterReads"] = localMediaProbeAbsent(imagePath)
            guard report["authAbsentAfterReads"] as? Bool == true, report["attachmentAbsentAfterReads"] as? Bool == true else {
                throw CodexHistoryError.unsafeMethod
            }
            report["status"] = "native-local-image-read-and-replayed"
        } catch { report["status"] = "unverified"; report["failureStage"] = stage }
        await client.close()
        let stopped = await client.lastShutdownCompletedWithinDeadline == true
        report["readerShutdownCompletedWithinDeadline"] = stopped
        if !stopped { report["status"] = "unverified"; report["failureStage"] = "closing-reader" }
        if let descriptorPath, let exportedDescriptor, stopped, report["status"] as? String == "native-local-image-read-and-replayed" {
            try localMediaProbeWrite(exportedDescriptor, path: descriptorPath, descriptor: true)
        }
        try localMediaProbeWrite(report, path: reportPath)
    }
}
