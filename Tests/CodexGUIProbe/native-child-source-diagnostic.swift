import Foundation
@_spi(Testing) import SpillcheckCore

// Source-contract diagnostic only. This never feeds rollout records to collection,
// publishes native identities, or archives any original provider content.
@main
private enum NativeChildSourceDiagnostic {
    private struct Selection: Decodable {
        let nativeThreadID: String
        let workingDirectory: String
        let storeCandidate: String
        let nativeIdentitySource: String
    }
    private enum Failure: Error { case controlled }
    static func main() async {
        do { try await run() }
        catch { emit(["passed": false, "reason": "exact-owned-native-source-diagnostic-unavailable"]); exit(1) }
    }
    private static func run() async throws {
        func option(_ name: String) throws -> String {
            let args = CommandLine.arguments
            guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { throw Failure.controlled }
            return args[index + 1]
        }
        let project = URL(fileURLWithPath: try option("--project")).resolvingSymlinksInPath()
        let home = URL(fileURLWithPath: try option("--authorized-home")).resolvingSymlinksInPath()
        let work = URL(fileURLWithPath: try option("--private-directory")).resolvingSymlinksInPath()
        func selection(_ role: String) throws -> Selection {
            let bytes = try Data(contentsOf: project.appendingPathComponent(role + "-identity.json"))
            guard bytes.count <= 8192 else { throw Failure.controlled }
            let value = try JSONDecoder().decode(Selection.self, from: bytes)
            guard value.nativeIdentitySource == "own-runtime-CODEX_THREAD_ID",
                  URL(fileURLWithPath: value.workingDirectory).resolvingSymlinksInPath() == project,
                  URL(fileURLWithPath: value.storeCandidate).resolvingSymlinksInPath() == home else { throw Failure.controlled }
            return value
        }
        let parent = try selection("parent"), child = try selection("child")
        guard parent.nativeThreadID != child.nativeThreadID else { throw Failure.controlled }
        let client = CodexAppServerHistoryClient(configuration: try .init(
            executableURL: URL(fileURLWithPath: option("--executable")), codexHomeURL: home,
            workingDirectoryURL: work, requestTimeout: 10))
        let parentRead = try await client.readThread(parent.nativeThreadID)
        func sourcePath(_ read: CodexThreadRead, id: String) throws -> URL {
            guard read.thread["id"].string == id, let cwd = read.thread["cwd"].string,
                  URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == project,
                  let path = read.thread["path"].string, path.hasPrefix("/") else { throw Failure.controlled }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard url.path.hasPrefix(home.path + "/") else { throw Failure.controlled }
            return url
        }
        let parentSource = try sourcePath(parentRead, id: parent.nativeThreadID)
        var linked = false, parentLinkedPromptMarker = false, parentLinkedPromptField = false
        var linkedPublicItemIDs: Set<String> = []
        var cursor: String?, seen: Set<String> = [], bytes = parentRead.bytesRead
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        for _ in 0..<16 {
            guard bytes < 8 * 1024 * 1024, ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.controlled }
            let page = try await client.listItems(threadID: parent.nativeThreadID, turnID: nil, cursor: cursor, limit: 64,
                direction: .ascending, budget: .init(maximumBytes: 8 * 1024 * 1024 - bytes,
                    timeout: min(10, deadline - ProcessInfo.processInfo.systemUptime)))
            bytes += page.bytesRead
            for entry in page.data {
                let item = entry["item"]
                guard ["collabAgentToolCall", "subAgentActivity"].contains(item["type"].string ?? "") else { continue }
                let ids = [item["agentThreadId"].string].compactMap { $0 }
                    + (item["receiverThreadIds"].array ?? []).compactMap(\.string)
                if ids.contains(child.nativeThreadID) {
                    linked = true
                    if let id = item["id"].string { linkedPublicItemIDs.insert(id) }
                    parentLinkedPromptField = parentLinkedPromptField || item["prompt"].string != nil
                    if let itemBytes = try? JSONEncoder().encode(item),
                       String(decoding: itemBytes, as: UTF8.self).contains("SPILLCHECK_GUI_CHILD_PROMPT") {
                        parentLinkedPromptMarker = true
                    }
                }
            }
            guard let next = page.nextCursor else { break }
            guard seen.insert(next).inserted else { throw Failure.controlled }
            cursor = next
        }
        guard linked else { throw Failure.controlled }
        func boundedOriginal(_ source: URL) throws -> Data {
            let properties = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard properties.isRegularFile == true, let size = properties.fileSize, size <= 8 * 1024 * 1024 else { throw Failure.controlled }
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
            guard data.count <= 8 * 1024 * 1024 else { throw Failure.controlled }
            return data
        }
        var parentOriginalMetadataMatched = false, parentSpawnCalls = 0, parentSpawnPromptMarker = false
        var parentSpawnPublicItemIDMatched = false, anyParentSpawnPublicItemIDMatched = false
        var parentSpawnArgumentsJSONObject = false, parentSpawnMessageField = false
        var parentOriginalUserPromptContainsRequestedChildMarker = false
        for line in try boundedOriginal(parentSource).split(separator: 10) where !line.isEmpty {
            guard line.count <= 1024 * 1024,
                  let value = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { throw Failure.controlled }
            let payload = value["payload"] as? [String: Any] ?? [:]
            if value["type"] as? String == "session_meta" {
                guard payload["id"] as? String == parent.nativeThreadID else { throw Failure.controlled }
                parentOriginalMetadataMatched = true
            }
            if value["type"] as? String == "response_item", payload["type"] as? String == "message",
               payload["role"] as? String == "user",
               String(decoding: line, as: UTF8.self).contains("SPILLCHECK_GUI_CHILD_PROMPT") {
                parentOriginalUserPromptContainsRequestedChildMarker = true
            }
            guard value["type"] as? String == "response_item", payload["type"] as? String == "function_call",
                  ["spawn_agent", "functions.spawn_agent"].contains(payload["name"] as? String ?? "") else { continue }
            parentSpawnCalls += 1
            let arguments: Data?
            if let string = payload["arguments"] as? String { arguments = Data(string.utf8) }
            else if let object = payload["arguments"] as? [String: Any] { arguments = try JSONSerialization.data(withJSONObject: object) }
            else { arguments = nil }
            if let arguments, let object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any] {
                parentSpawnArgumentsJSONObject = true
                parentSpawnMessageField = parentSpawnMessageField || object["message"] is String || object["task"] is String
            }
            let hasMarker = arguments.map { String(decoding: $0, as: UTF8.self).contains("SPILLCHECK_GUI_CHILD_PROMPT") } == true
            parentSpawnPromptMarker = parentSpawnPromptMarker || hasMarker
            if let id = payload["call_id"] as? String, linkedPublicItemIDs.contains(id) {
                anyParentSpawnPublicItemIDMatched = true
            }
            if hasMarker, let id = payload["call_id"] as? String, linkedPublicItemIDs.contains(id) {
                parentSpawnPublicItemIDMatched = true
            }
        }
        guard parentOriginalMetadataMatched else { throw Failure.controlled }
        let childRead = try await client.readThread(child.nativeThreadID)
        let source = try sourcePath(childRead, id: child.nativeThreadID)
        let data = try boundedOriginal(source)
        var sessionMatched = false, producerVersion: String?, markers: [String: Set<String>] = [:]
        var recordKinds: [String: Int] = [:]
        var messageRecordCount = 0, messageRecordsWithNativeIDs = 0
        for line in data.split(separator: 10) where !line.isEmpty {
            guard line.count <= 1024 * 1024,
                  let value = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { throw Failure.controlled }
            let payload = value["payload"] as? [String: Any] ?? [:]
            let type = value["type"] as? String ?? "unknown"
            if type == "session_meta" {
                guard payload["id"] as? String == child.nativeThreadID else { throw Failure.controlled }
                sessionMatched = true
                producerVersion = payload["cli_version"] as? String
            }
            let subType = payload["type"] as? String ?? "unknown"
            let kind: String
            if type == "response_item", subType == "message" {
                messageRecordCount += 1
                if let id = payload["id"] as? String, !id.isEmpty { messageRecordsWithNativeIDs += 1 }
                kind = "response_item/message/" + (["user", "assistant", "developer", "system"].contains(payload["role"] as? String ?? "") ? payload["role"] as! String : "other")
            } else if type == "event_msg", ["user_message", "agent_message", "agent_reasoning", "exec_command_begin", "exec_command_end"].contains(subType) {
                kind = "event_msg/" + subType
            } else { kind = ["session_meta", "response_item", "event_msg", "turn_context", "compacted"].contains(type) ? type : "other" }
            recordKinds[kind, default: 0] += 1
            let text = String(decoding: line, as: UTF8.self)
            for suffix in ["PROMPT", "INTERMEDIATE", "FINAL", "TOOL_OUTPUT", "TOOL_ERROR"] where text.contains("SPILLCHECK_GUI_CHILD_" + suffix) {
                markers[suffix, default: []].insert(kind)
            }
        }
        guard sessionMatched else { throw Failure.controlled }
        await client.close()
        emit(["passed": await client.lastShutdownCompletedWithinDeadline == true,
            "scope": "exact-public-verified-parent-spawn-input-and-native-child-original-JSONL-only-after-producer",
            "nativeParentChildRelationshipVerified": linked, "nativeChildSessionMetadataMatched": sessionMatched,
            "nativeParentLinkedChildItemHasPromptField": parentLinkedPromptField,
            "nativeParentLinkedChildItemContainsRequestedPromptMarker": parentLinkedPromptMarker,
            "nativeParentOriginalMetadataMatched": parentOriginalMetadataMatched,
            "nativeParentSpawnCallCount": parentSpawnCalls,
            "nativeParentSpawnArgumentsContainRequestedPromptMarker": parentSpawnPromptMarker,
            "nativeParentSpawnArgumentsAreJSONObject": parentSpawnArgumentsJSONObject,
            "nativeParentSpawnArgumentsHaveMessageOrTaskField": parentSpawnMessageField,
            "nativeParentOriginalUserPromptContainsRequestedChildMarker": parentOriginalUserPromptContainsRequestedChildMarker,
            "nativeParentPromptBearingSpawnCallIDMatchesPublicLinkedChildItemID": parentSpawnPublicItemIDMatched,
            "nativeParentSpawnCallIDMatchesPublicLinkedChildItemID": anyParentSpawnPublicItemIDMatched,
            "nativeChildResponseMessageRecords": messageRecordCount,
            "nativeChildResponseMessagesWithItemID": messageRecordsWithNativeIDs,
            "actualReaderVersion": await client.observedReaderVersion as Any? ?? NSNull(),
            "actualNativeProducerVersion": producerVersion as Any? ?? NSNull(),
            "nativeFileBytes": data.count, "recordKinds": recordKinds,
            "childFixtureMarkerRecordKinds": markers.mapValues { $0.sorted() },
            "nativeChildUserPromptMarkerAvailable": markers["PROMPT"]?.contains("response_item/message/user") == true
                || markers["PROMPT"]?.contains("event_msg/user_message") == true,
            "readerShutdownCompletedWithinDeadline": await client.lastShutdownCompletedWithinDeadline as Any? ?? NSNull(),
            "noOriginalSourceArchive": true, "noUnrelatedHistoryEnumeration": true,
            "productionGUICollectionEnabled": false, "liveCoverageEstablished": false,
            "collectionFallbackImplemented": false])
    }
    private static func emit(_ object: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(bytes + Data([10]))
    }
}
