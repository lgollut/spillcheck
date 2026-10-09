import Darwin
import Foundation
import CryptoKit
import Security
@_spi(Testing) import SpillcheckCore

private let originalValue = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
private let replacementValue = "ghp_6tV2kQ9sR4nH7xB1wJ8mF3cL0yD5pA9eU2zG"
private enum OwnerFailure: Error { case invalidArguments, unsafeDirectory, invalidCommand, childRunning, abnormalChild, changedManifest, pendingQueue, cleanup, appNotReady }
private struct Request: Decodable { let id: UUID; let nonce: UUID; let action: String; let sandboxMode: String? }

@MainActor
private final class Run {
    let process: Process
    let report: URL
    let output: URL
    let diagnostics: URL
    init(process: Process, report: URL, output: URL, diagnostics: URL) {
        self.process = process; self.report = report; self.output = output; self.diagnostics = diagnostics
    }
    func completedNormally() -> Bool {
        guard !process.isRunning else { return false }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let value = try? object(report), value["acceptancePhase"] as? String == "shutdown-complete",
              value["viewingAuthorized"] as? Bool == false,
              ["revealedValueCount", "revealedExcerptCount", "revealedSourceMetadataCount"].allSatisfy({ value[$0] as? Int == 0 }),
              (try? Data(contentsOf: output).isEmpty) == true,
              (try? Data(contentsOf: diagnostics).isEmpty) == true else { return false }
        return true
    }
}

private func object(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard data.count <= 128 * 1024,
          let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OwnerFailure.invalidCommand }
    return result
}
private func write(_ value: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
private func safeDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_uid == getuid(),
          info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0,
          try canonicalPath(url.path) == url.path else { throw OwnerFailure.unsafeDirectory }
}
private func canonicalPath(_ path: String) throws -> String {
    guard let resolved = realpath(path, nil) else { throw OwnerFailure.unsafeDirectory }
    defer { free(resolved) }
    return String(cString: resolved)
}
private func safeRequest(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
          info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
          info.st_size <= 1024 else { throw OwnerFailure.invalidCommand }
}
private func networkDeniedProfile(store: URL) throws -> String {
    let socket = store.appendingPathComponent("capture.sock").path
    guard socket.hasPrefix("/private/tmp/spillcheck-vault-owner-"),
          socket.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }),
          !socket.contains("\""), !socket.contains("\\") else { throw OwnerFailure.unsafeDirectory }
    return "(version 1)(allow default)(deny network*)(allow network* (literal \"\(socket)\"))(allow process-exec (literal \"/usr/bin/sandbox-exec\") (with no-sandbox))"
}
private func inspectMarkers(in store: URL, source: URL) throws -> (bytes: Int, hits: Int) {
    var total = 0, hits = 0
    guard let enumerator = FileManager.default.enumerator(at: store, includingPropertiesForKeys: [.isRegularFileKey]) else { throw OwnerFailure.unsafeDirectory }
    for case let file as URL in enumerator {
        if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let bytes = try Data(contentsOf: file)
            total += bytes.count
            guard total <= 8 * 1024 * 1024 else { throw OwnerFailure.unsafeDirectory }
            for marker in [originalValue, replacementValue, "SPILLCHECK_RESTART_SYNTHETIC", source.path] {
                if bytes.range(of: Data(marker.utf8)) != nil { hits += 1 }
            }
        }
    }
    return (total, hits)
}
private func verifyTarget(_ app: URL, codeHash: String) throws {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
          SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess else { throw OwnerFailure.changedManifest }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let values = information as? [String: Any], let hash = values[kSecCodeInfoUnique as String] as? Data,
          hash.map({ String(format: "%02x", $0) }).joined() == codeHash else { throw OwnerFailure.changedManifest }
}

@main
private struct VaultOwner {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--help") {
            print("VaultOwner --directory NEW_PRIVATE_ROOT --ready PRIVATE_READY_JSON --report SAFE_REPORT_JSON --lease-seconds 3600")
            return
        }
        let args = CommandLine.arguments
        func argument(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        guard let directory = argument("--directory"), let readyPath = argument("--ready"),
              let reportPath = argument("--report"), let leaseText = argument("--lease-seconds"),
              let lease = Double(leaseText), lease >= 60, lease <= 7200,
              let group = Bundle.main.object(forInfoDictionaryKey: "SpillcheckKeychainAccessGroup") as? String,
              group == "KBLA5ALX62.com.leakret.app", Bundle.main.bundleIdentifier == "com.leakret.app",
              let target = Bundle.main.object(forInfoDictionaryKey: "SpillcheckVaultOwnerTargetApp") as? String,
              let targetHash = Bundle.main.object(forInfoDictionaryKey: "SpillcheckVaultOwnerTargetSHA256") as? String,
              let targetCodeHash = Bundle.main.object(forInfoDictionaryKey: "SpillcheckVaultOwnerTargetCDHash") as? String else { exit(64) }
        // Foundation standardization maps /private/tmp to /tmp on this macOS.
        // Keep the canonical Darwin pathname supplied by the private-directory creator.
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let ready = URL(fileURLWithPath: readyPath), finalReport = URL(fileURLWithPath: reportPath)
        let storeURL = root.appendingPathComponent("protected-store", isDirectory: true)
        let source = root.appendingPathComponent("selected-synthetic-source.jsonl")
        let requests = root.appendingPathComponent("requests", isDirectory: true)
        let responses = root.appendingPathComponent("responses", isDirectory: true)
        let nonce = UUID(), session = UUID().uuidString
        var services: ProtectionServices?
        var runs: [Run] = []
        var handled: Set<UUID> = []
        var references: Set<ProtectedPayloadReference> = []
        var snapshots: [[String: Any]] = []
        var finishing = false
        var cleaned = false
        var stage = "starting"
        var failureStage: String?
        var bootstrapAttempted = false
        do {
            stage = "validating-owned-directory"
            try safeDirectory(root)
            guard root.path.hasPrefix("/private/tmp/spillcheck-vault-owner-"),
                  !FileManager.default.fileExists(atPath: storeURL.path),
                  try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy({ ["owner-stdout.bin", "owner-stderr.bin"].contains($0) }) else { throw OwnerFailure.unsafeDirectory }
            for directory in [requests, responses] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            stage = "probing-empty-store"
            let empty = try ProtectedStore.probe(at: storeURL)
            guard empty.state == .empty, empty.manifest == nil else { throw OwnerFailure.changedManifest }
            stage = "creating-owned-vault"
            bootstrapAttempted = true
            let created = try await ProtectionBootstrap.prepare(manifest: nil, storeState: .empty,
                configuration: ProtectionConfiguration(accessGroup: group))
            services = created
            guard created.createdNewManifest else { throw OwnerFailure.cleanup }
            try JSONEncoder().encode(created.manifest).write(to: root.appendingPathComponent("owner-manifest.json"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("owner-manifest.json").path)
            let initial = try await ProtectedStore.open(at: storeURL, cryptography: created.background)
            try await initial.close()
            guard try ProtectedStore.probe(at: storeURL).manifest == created.manifest else { throw OwnerFailure.changedManifest }
            let original = try await created.background.fingerprint(exactBytes: Data(originalValue.utf8))
            let replacement = try await created.background.fingerprint(exactBytes: Data(replacementValue.utf8))

            func append(_ value: String, at date: Date) throws {
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let row: [String: Any] = ["type": "user", "uuid": UUID().uuidString, "sessionId": session,
                    "timestamp": formatter.string(from: date), "isSidechain": false, "version": "2.1.293",
                    "message": ["role": "user", "content": "SPILLCHECK_RESTART_SYNTHETIC " + value]]
                var bytes = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); bytes.append(10)
                if !FileManager.default.fileExists(atPath: source.path) {
                    guard FileManager.default.createFile(atPath: source.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw OwnerFailure.unsafeDirectory }
                }
                let file = try FileHandle(forWritingTo: source)
                defer { try? file.close() }
                try file.seekToEnd(); try file.write(contentsOf: bytes); try file.synchronize()
            }
            try append(originalValue, at: Date().addingTimeInterval(-30))

            func ensureNoChild() throws {
                guard runs.allSatisfy({ !$0.process.isRunning }) else { throw OwnerFailure.childRunning }
                guard runs.allSatisfy({ $0.completedNormally() }) else { throw OwnerFailure.abnormalChild }
            }
            func inspect() async throws -> [String: Any] {
                try ensureNoChild()
                guard try ProtectedStore.probe(at: storeURL).manifest == created.manifest else { throw OwnerFailure.changedManifest }
                let store = try await ProtectedStore.open(at: storeURL, cryptography: created.background)
                do {
                    let snapshot = await store.snapshot()
                    let queue = try await store.queueStatistics()
                    func summary(_ fingerprint: ValueFingerprint) -> [String: Any] {
                        let record = snapshot.records[fingerprint]
                        let occurrences = snapshot.occurrences.values.filter { $0.valueID == record?.id }
                        let obsolete = snapshot.obsoleteAppearances.values.filter { $0.valueID == record?.id }
                        let alerts = snapshot.alertDecisions.values.filter { $0.eligibility.fingerprint == fingerprint }
                        if let reference = record?.protectedValue { references.insert(reference) }
                        for occurrence in occurrences {
                            if let reference = occurrence.protectedExcerpt { references.insert(reference) }
                            if let reference = occurrence.source.protectedMetadata { references.insert(reference) }
                        }
                        return ["recordPresent": record != nil, "entryID": record?.id.uuidString as Any? ?? NSNull(),
                            "retainedValueCount": record?.protectedValue == nil ? 0 : 1,
                            "retainedExcerptCount": occurrences.filter { $0.protectedExcerpt != nil }.count,
                            "occurrenceCount": occurrences.count, "obsoleteAppearanceCount": obsolete.count,
                            "acknowledgement": snapshot.obsoleteMarkers[fingerprint]?.acknowledgement.rawValue as Any? ?? NSNull(),
                            "alertCount": alerts.count, "alertsByDeliveryState": Dictionary(grouping: alerts, by: { $0.delivery.rawValue }).mapValues(\.count)]
                    }
                    let originalSummary = summary(original), replacementSummary = summary(replacement)
                    var inaccessible = 0
                    for reference in references { if try await store.payload(reference) == nil { inaccessible += 1 } }
                    let markerInspection = try inspectMarkers(in: storeURL, source: source)
                    let result: [String: Any] = ["runCount": runs.count, "queueCount": queue.count,
                        "valueCount": snapshot.records.count, "occurrenceCount": snapshot.occurrences.count,
                        "obsoleteAppearanceCount": snapshot.obsoleteAppearances.count, "markerCount": snapshot.obsoleteMarkers.count,
                        "analysisReceiptCount": snapshot.analysisReceipts.count, "alertCount": snapshot.alertDecisions.count,
                        "original": originalSummary, "replacement": replacementSummary,
                        "rememberedPayloadReferences": references.count, "inaccessibleRememberedPayloadReferences": inaccessible,
                        "sameManifest": true, "privateValueDecryptions": 0,
                        "ciphertextMarkerInspectionPassed": markerInspection.hits == 0, "ciphertextInspectedBytes": markerInspection.bytes]
                    try await store.close()
                    snapshots.append(result)
                    return result
                } catch { try? await store.close(); throw error }
            }

            stage = "ready"
            try write(["ready": true, "ownerPID": ProcessInfo.processInfo.processIdentifier, "nonce": nonce.uuidString,
                "directory": root.path, "storeDirectory": storeURL.path, "source": source.path, "session": session,
                "requests": requests.path, "responses": responses.path, "report": finalReport.path, "leaseSeconds": lease,
                "createdNewManifest": true, "manifestCommitted": true, "appCleanupFlagUsed": false], to: ready)
            let deadline = ProcessInfo.processInfo.systemUptime + lease
            while !finishing, ProcessInfo.processInfo.systemUptime < deadline {
                let files = try FileManager.default.contentsOfDirectory(at: requests, includingPropertiesForKeys: [.isRegularFileKey]).sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard files.count <= 128 else { throw OwnerFailure.invalidCommand }
                for file in files where file.pathExtension == "json" {
                    try safeRequest(file)
                    let data = try Data(contentsOf: file)
                    guard data.count <= 1024 else { throw OwnerFailure.invalidCommand }
                    let command = try JSONDecoder().decode(Request.self, from: data)
                    guard command.nonce == nonce, file.lastPathComponent == command.id.uuidString + ".json" else { throw OwnerFailure.invalidCommand }
                    guard handled.insert(command.id).inserted else { continue }
                    var response: [String: Any] = ["requestID": command.id.uuidString, "success": false]
                    do {
                        switch command.action {
                        case "launch":
                            try ensureNoChild()
                            guard try ProtectedStore.probe(at: storeURL).manifest == created.manifest else { throw OwnerFailure.changedManifest }
                            let index = runs.count + 1
                            let appReport = root.appendingPathComponent("app-\(index).json")
                            let output = root.appendingPathComponent("app-\(index)-stdout.bin")
                            let diagnostics = root.appendingPathComponent("app-\(index)-stderr.bin")
                            for file in [output, diagnostics] {
                                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw OwnerFailure.unsafeDirectory }
                            }
                            let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: diagnostics)
                            defer { try? out.close(); try? err.close() }
                            let process = Process()
                            let executable = URL(fileURLWithPath: target).appendingPathComponent("Contents/MacOS/Spillcheck")
                            try verifyTarget(URL(fileURLWithPath: target), codeHash: targetCodeHash)
                            let hash = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
                            guard hash == targetHash else { throw OwnerFailure.changedManifest }
                            let appArguments = ["--store-directory", storeURL.path, "--claude-profile", "restart-synthetic",
                                "--claude-version", "2.1.293", "--claude-source-root", root.path, "--claude-active-source", source.path,
                                "--claude-session", session, "--acceptance-no-profile-catchup", "--acceptance-hold",
                                "--acceptance-report", appReport.path, "--acceptance-seconds", "8"]
                            switch command.sandboxMode {
                            case nil, "unsandboxed":
                                process.executableURL = executable; process.arguments = appArguments
                            case "network-denied-trusted-scanner-bootstrap":
                                let profile = try networkDeniedProfile(store: storeURL)
                                process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
                                process.arguments = ["-p", profile, executable.path] + appArguments
                            default: throw OwnerFailure.invalidCommand
                            }
                            process.standardOutput = out; process.standardError = err
                            try process.run()
                            runs.append(Run(process: process, report: appReport, output: output, diagnostics: diagnostics))
                            response["runIndex"] = index; response["processID"] = process.processIdentifier
                            response["appReport"] = appReport.path
                            response["sandboxMode"] = command.sandboxMode ?? "unsandboxed"
                        case "inspect": response["snapshot"] = try await inspect()
                        case "append-original", "append-replacement":
                            guard let run = runs.last, run.process.isRunning,
                                  let report = try? object(run.report), report["storageReady"] as? Bool == true,
                                  report["collectionConfigured"] as? Bool == true, report["monitoringEnabled"] as? Bool == true,
                                  report["queueCount"] as? Int == 0 else { throw OwnerFailure.appNotReady }
                            try append(command.action == "append-original" ? originalValue : replacementValue, at: Date())
                        case "cleanup":
                            guard !runs.isEmpty else { throw OwnerFailure.abnormalChild }
                            let snapshot = try await inspect()
                            guard snapshot["queueCount"] as? Int == 0 else { throw OwnerFailure.pendingQueue }
                            guard snapshot["ciphertextMarkerInspectionPassed"] as? Bool == true else { throw OwnerFailure.cleanup }
                            stage = "cleaning-original-created-services"
                            guard try await created.removeNewlyCreatedProtectionForTesting() else { throw OwnerFailure.cleanup }
                            cleaned = true; finishing = true
                        case "preserve": finishing = true; stage = "preserved-by-request"
                        default: throw OwnerFailure.invalidCommand
                        }
                        response["success"] = true; response["status"] = cleaned ? "cleaned" : "accepted"
                    } catch {
                        response["status"] = String(describing: error as? OwnerFailure ?? .cleanup)
                        if stage == "cleaning-original-created-services" { throw error }
                    }
                    try write(response, to: responses.appendingPathComponent(command.id.uuidString + ".json"))
                    if finishing { break }
                }
                if !finishing { try await Task.sleep(for: .milliseconds(100)) }
            }
            if !finishing { stage = "lease-expired-preserved" }
        } catch { failureStage = stage; stage = "owner-failed-preserved" }
        withExtendedLifetime(services) {}
        var final: [String: Any] = ["schemaVersion": 1, "passed": false, "cleanupPending": true,
            "ownerPID": ProcessInfo.processInfo.processIdentifier, "bootstrapAttempted": bootstrapAttempted,
            "stage": stage, "createdNewManifest": services?.createdNewManifest == true,
            "normalExitedRunCount": runs.filter { $0.completedNormally() }.count,
            "runCount": runs.count, "ownedChildStillRunning": runs.contains { $0.process.isRunning },
            "appReports": runs.compactMap { try? object($0.report) },
            "snapshots": snapshots, "privateValueDecryptions": 0, "existingUserHooksOrHistoriesModified": false,
            "cleanupAuthority": "Only original services created by this live owner; never loaded-manifest services"]
        if let failureStage { final["failureStage"] = failureStage }
        do {
            if cleaned {
                try FileManager.default.removeItem(at: root)
                final["stage"] = "completed"
                final["passed"] = true; final["cleanupPending"] = false; final["ownedArtifactsRemoved"] = true
            } else {
                try write(final, to: root.appendingPathComponent("owner-run-private.json"))
            }
            try write(final, to: finalReport)
            try write(["ready": false, "finished": true, "report": finalReport.path, "cleanupPending": !cleaned], to: ready)
        } catch { exit(1) }
        if !cleaned { exit(1) }
    }
}
