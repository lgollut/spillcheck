import Darwin
import Foundation
@_spi(Testing) import SpillcheckCore

private let syntheticValue = "SPILLCHECK_STORAGE_CRASH_SYNTHETIC_SECRET"
private let captureID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let checkpointID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

private struct SafeReport: Encodable {
    var operation: String
    var queueCount: Int
    var valueCount: Int
    var occurrenceCount: Int
    var sourceReceiptCount: Int
    var alertCount: Int
    var notificationIdentifiers: [String]
    var markerCount: Int
    var metadataOnlyCount: Int
    var checkpointOffset: UInt64?
    var replay: Bool?
    var queueInsertion: String?
}

/// Disposable-storage acceptance driver only; this product is never embedded in the application.
/// Its deterministic SPI seed is public synthetic test material and cannot access app vault keys.
@main
private struct StorageAcceptance {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.contains("--claude-configure-hook") {
                try await ClaudeAcceptance.configureHook(arguments)
                return
            }
            if arguments.contains("--claude-live") || arguments.contains("--claude-observe") {
                try await ClaudeAcceptance.run(arguments)
                return
            }
            if arguments.contains("--codex-live") || arguments.contains("--codex-observe") {
                try await CodexAcceptance.run(arguments)
                return
            }
            func option(_ name: String) -> String? {
                guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
                return arguments[index + 1]
            }
            guard let path = option("--directory"), let operation = option("--operation"),
                  ["inspect", "enqueue", "process", "append", "replacement", "new-item", "ack-delete", "delete", "forget"].contains(operation) else {
                throw StorageError.invalidTime
            }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let probe = try ProtectedStore.probe(at: directory)
            let manifest = probe.manifest ?? ProtectionManifest.fresh(identifierPrefix: "com.spillcheck.test.crash")
            let seed = Data((arguments.contains("--wrong-key") ? "wrong synthetic acceptance seed" : "spillcheck synthetic acceptance seed v1").utf8)
            let crypto = try BackgroundCryptography.deterministicForTesting(seed: seed, manifest: manifest)
            let point = option("--failpoint").flatMap(StorageFailpoint.init(rawValue:))
            let sentinel = directory.appendingPathComponent("failpoint-reached")
            let injector: StorageFailureInjector?
            if let expected = point {
                injector = { actual in
                    if actual == expected {
                        let descriptor = Darwin.open(sentinel.path, O_CREAT | O_TRUNC | O_WRONLY | O_NOFOLLOW, 0o600)
                        guard descriptor >= 0 else { throw StorageError.injectedFailure }
                        let bytes = Data(actual.rawValue.utf8)
                        _ = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
                        _ = fsync(descriptor)
                        Darwin.close(descriptor)
                        // The parent sends SIGKILL after this handshake. No graceful close occurs.
                        raise(SIGSTOP)
                        _exit(78)
                    }
                }
            } else { injector = nil }
            let store = try await ProtectedStore.open(at: directory, cryptography: crypto, failureInjector: injector)
            let advance = Double(option("--advance") ?? "0") ?? 0
            guard advance.isFinite, advance >= 0, advance <= 86_000 else { throw StorageError.invalidTime }
            let now = Date().addingTimeInterval(advance)
            let permit = await store.processingPermit()!
            var transition: InventoryTransition?
            var insertion: String?
            switch operation {
            case "enqueue":
                let result = try await store.enqueue(Data(syntheticValue.utf8), id: captureID, capturedAt: Date(), permit: permit, at: now)
                switch result {
                case .inserted: insertion = "inserted"
                case .alreadyQueued: insertion = "alreadyQueued"
                case .alreadyProcessed: insertion = "alreadyProcessed"
                }
            case "process", "append", "replacement", "new-item":
                let input = try await preparedAnalysis(crypto: crypto, append: operation == "append",
                                                       replacement: operation == "replacement", newItem: operation == "new-item")
                let capture = try await store.nextPending(at: now, permit: permit)
                let payloads = try await sealedPayloads(input, crypto: crypto, replacement: operation == "replacement")
                let checkpoint = SourceCheckpoint(capabilityID: checkpointID, sourceDocumentID: checkpointID,
                                                  revision: input.revision, byteOffset: operation == "append" ? 200 : 100)
                transition = try await store.commit(input, payloads: payloads, checkpoint: checkpoint, consuming: capture, permit: permit, at: now)
            case "ack-delete":
                let fingerprint = try await crypto.fingerprint(exactBytes: Data(syntheticValue.utf8))
                try await store.acknowledgeObsolete(fingerprint, as: .revoked, at: Date())
                _ = try await store.removeContent(for: fingerprint)
            case "delete":
                _ = try await store.removeContent(for: crypto.fingerprint(exactBytes: Data(syntheticValue.utf8)))
            case "forget":
                try await store.forgetObsoleteMarker(crypto.fingerprint(exactBytes: Data(syntheticValue.utf8)))
            default: break
            }
            let snapshot = await store.snapshot()
            let queue = try await store.queueStatistics()
            let checkpoint = try await store.checkpoint(documentID: checkpointID)
            let report = SafeReport(
                operation: operation, queueCount: queue.count, valueCount: snapshot.records.count,
                occurrenceCount: snapshot.occurrences.count, sourceReceiptCount: snapshot.locationReceipts.count,
                alertCount: snapshot.alertDecisions.count,
                notificationIdentifiers: snapshot.alertDecisions.values.map(\.notificationIdentifier).sorted(),
                markerCount: snapshot.obsoleteMarkers.count, metadataOnlyCount: snapshot.obsoleteAppearances.count,
                checkpointOffset: checkpoint?.byteOffset, replay: transition.map { $0.outcome == .replay }, queueInsertion: insertion
            )
            try await store.close()
            let bytes = try JSONEncoder().encode(report)
            FileHandle.standardOutput.write(bytes)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            // Controlled error cases only. No SQL, paths, scanner results or captured bytes.
            let label = (error as? StorageError).map { String(describing: $0) } ?? "acceptanceFailure"
            let bytes = (try? JSONSerialization.data(withJSONObject: ["error": label])) ?? Data("{}".utf8)
            FileHandle.standardOutput.write(bytes)
            FileHandle.standardOutput.write(Data("\n".utf8))
            exit(1)
        }
    }

    private static func preparedAnalysis(
        crypto: BackgroundCryptography, append: Bool, replacement: Bool, newItem: Bool
    ) async throws -> SourceAnalysis {
        let value = replacement ? "SPILLCHECK_STORAGE_CRASH_SYNTHETIC_REPLACEMENT" : syntheticValue
        let text = append ? "\(value) \(value)" : value
        let session = try SessionIdentity(provider: .codex, profileID: "synthetic-crash-profile", sessionID: "synthetic-crash-session")
        let identity = try SourceIdentity(session: session, itemID: replacement ? "replacement-item" : (newItem ? "later-item" : "synthetic-item"))
        let origin = try SourceOrigin(adapterID: "synthetic-crash-adapter", adapterVersion: "1", agentVersion: "fixture",
                                      interface: .standaloneCLI, provenance: .live, canonicalization: .sharedUpstreamIdentity)
        let revision = try await crypto.revision(canonicalBytes: Data(text.utf8))
        let source = try SourceRecord(
            metadata: SourceRecordMetadata(identity: identity, contentType: .toolOutput, contentTime: Date(), observedAt: Date(), origin: origin),
            revision: revision,
            segments: [SourceSegment(id: "text", utf8: Data(text.utf8))]
        )
        let valueBytes = Data(value.utf8)
        let fingerprint = try await crypto.fingerprint(exactBytes: valueBytes)
        let evidence = DetectionEvidence(rule: try RuleIdentity(id: "synthetic-format", version: "1"), signal: .strong,
                                         reason: .recognizedFormat, category: .token)
        var findings: [LocatedDetection] = []
        var cursor = 0
        let textBytes = Data(text.utf8)
        while cursor < textBytes.count, let range = textBytes.range(of: valueBytes, in: cursor..<textBytes.count) {
            let location = try CanonicalLocation(segmentID: "text", range: UTF8Range(range.lowerBound, range.upperBound))
            let extraction = try ExactExtraction(valueUTF8: valueBytes, location: location, in: source)
            findings.append(try LocatedDetection(extraction: extraction, in: source, fingerprint: fingerprint, evidence: [evidence],
                                                 protectedValue: ProtectedPayloadReference(), protectedExcerpt: ProtectedPayloadReference()))
            cursor = range.upperBound
        }
        return try SourceAnalysis(source: source, detectorVersion: "synthetic-detector-1", detections: findings)
    }

    private static func sealedPayloads(_ analysis: SourceAnalysis, crypto: BackgroundCryptography, replacement: Bool) async throws -> [ProtectedPayload] {
        let exactValue = replacement ? "SPILLCHECK_STORAGE_CRASH_SYNTHETIC_REPLACEMENT" : syntheticValue
        var output: [ProtectedPayload] = []
        for finding in analysis.detections {
            output.append(try await crypto.sealInventory(Data(exactValue.utf8), binding: PayloadBinding(
                reference: finding.protectedValue, ownerID: finding.protectedValue.id, kind: .value
            )))
            if let excerpt = finding.protectedExcerpt {
                output.append(try await crypto.sealInventory(Data("synthetic excerpt \(exactValue)".utf8),
                                                           binding: PayloadBinding(reference: excerpt, ownerID: excerpt.id, kind: .excerpt)))
            }
        }
        return output
    }
}
