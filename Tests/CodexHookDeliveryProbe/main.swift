import CryptoKit
import Darwin
import Foundation
@_spi(Testing) import SpillcheckCore

// Test-only process. It neither opens a user's vault nor contacts a provider.
private struct Configuration: Decodable, Sendable {
    let directory: String
    let scanner: String
    let rules: String
    let seed: Data
    let manifest: ProtectionManifest
    let profile: String
    let session: String
    let holdAfterCommit: Bool
    let holdBeforeScan: Bool
    let maximumHookBytes: Int
}

private struct Command: Decodable { let command: String }
private enum ProbeError: Error { case configuration, unexpectedNativeRoute, command, drainLimit }

private actor Output {
    func send<T: Encodable & Sendable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var bytes = try encoder.encode(value); bytes.append(10)
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }
}

private struct Event: Encodable, Sendable {
    let event: String
    var capturedAt: Double? = nil
}

private actor NativeGuard: CaptureNormalizer {
    private(set) var calls = 0
    func normalize(_ packet: CapturePacket, capturedAt: Date,
                   cryptography: BackgroundCryptography) throws -> CollectionBatch {
        calls += 1
        throw ProbeError.unexpectedNativeRoute
    }
}

private actor MeasuredDetector: SecretDetector {
    let detector: BetterleaksSecretDetector
    let output: Output
    let holdBeforeScan: Bool
    private(set) var calls = 0
    private(set) var failures = 0
    init(detector: BetterleaksSecretDetector, output: Output, holdBeforeScan: Bool) {
        self.detector = detector; self.output = output; self.holdBeforeScan = holdBeforeScan
    }
    func scan(_ source: SourceRecord) async throws -> DetectorOutput {
        if holdBeforeScan {
            // Normalization has already committed the immutable identity, and the
            // capture is still claimed. Python kills this process at this boundary.
            try await output.send(Event(event: "beforeScan"))
            try await Task.sleep(for: .seconds(30))
        }
        calls += 1
        let result = try await detector.scan(source)
        if result.scannerFailure != nil { failures += 1 }
        return result
    }
}

private struct Statistics: Encodable, Sendable {
    let event = "statistics"
    let queueCount: Int
    let claimedCount: Int
    let records: Int
    let occurrences: Int
    let receipts: Int
    let detectorCalls: Int
    let scannerFailures: Int
    let nativeCalls: Int
    let contentTypes: [String: Int]
    let allSourcesHookObserved: Bool
    let hookReadCount: Int
    let nativeReadCount: Int
    let diagnostics: [String]
    let reasons: [String]
    let firstObserved: Double?
    let inventoryDigest: String
}

@main private struct Probe {
    static func main() async {
        do { try await run() }
        catch {
            // Never serialize arbitrary error descriptions, source text, paths,
            // process diagnostics, or crypto material.
            try? await Output().send(Event(event: "controlledFailure"))
            exit(1)
        }
    }

    static func run() async throws {
        guard let line = readLine(), let data = line.data(using: .utf8), data.count < 16_384 else {
            throw ProbeError.configuration
        }
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        let directory = URL(fileURLWithPath: config.directory)
        var info = stat()
        guard config.seed.count == 32, (directory.path.hasPrefix("/private/tmp/spillcheck-hook-e2e-") ||
                directory.path.hasPrefix("/tmp/spillcheck-hook-e2e-")) else { throw ProbeError.configuration }
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw ProbeError.configuration }
        let output = Output()
        let crypto = try BackgroundCryptography.deterministicForTesting(seed: config.seed, manifest: config.manifest)
        let store = try await ProtectedStore.open(at: directory.appendingPathComponent("store"), cryptography: crypto,
            limits: .init(claimDuration: 3))
        let session = try SessionIdentity(provider: .codex, profileID: config.profile, sessionID: config.session)
        guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
        try await store.selectAuthority(.init(session: session, adapterVersion: CodexHookContentAdapter.adapterVersion,
            authorityID: CodexHookContentAdapter.authorityID), permit: permit)
        let hooks = try CodexHookContentAdapter(profileID: config.profile, interface: .desktopCode,
            maximumBytes: config.maximumHookBytes, authorityLookup: { try await store.authority(for: $0) },
            bind: { source, revision, observedAt in
                guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
                return try await store.bindCodexHookContent(source: source, revision: revision,
                    observedAt: observedAt, permit: permit)
            })
        let native = NativeGuard()
        let enrolled = try CodexEnrolledSessionRouter(native: native, hooks: hooks,
            nativeRoute: .init(scope: .init(provider: .codex, profileID: config.profile,
                interface: .desktopCode, path: .publicHistory)), nativeAuthority: .publicNativeItems,
            authorityLookup: { try await store.authority(for: $0) })
        let router = try CollectionRouter(routes: [.init(provider: .codex, profileID: config.profile,
            interface: .desktopCode, normalizer: enrolled)])
        let scanner = BetterleaksSecretDetector(configuration: .init(
            executableURL: URL(fileURLWithPath: config.scanner), configurationURL: URL(fileURLWithPath: config.rules),
            workingDirectoryURL: directory.appendingPathComponent("scanner")))
        let detector = MeasuredDetector(detector: scanner, output: output, holdBeforeScan: config.holdBeforeScan)
        let pipeline = DetectionPipeline(store: store, cryptography: crypto, normalizer: router,
            detector: detector, detectorVersion: BetterleaksSecretDetector.version)
        let server = LocalCaptureServer()
        try await server.start(at: directory.appendingPathComponent("capture.sock"),
            accepting: { await store.processingPermit() != nil }, onCapture: { packet in
                guard let permit = await store.processingPermit() else { throw StorageError.monitoringPaused }
                let context = try await enrolled.context(for: packet, trigger: .helperDelivery, recordAuthority: { choice in
                    try await store.selectAuthority(choice, permit: permit)
                })
                let capturedAt = Date()
                _ = try await store.enqueue(packet.body, capturedAt: capturedAt, permit: permit,
                    scope: LiveCaptureScope(startedAt: capturedAt.addingTimeInterval(-1)), workContext: context)
                if config.holdAfterCommit {
                    // Actual SQLite commit succeeded; the real transport cannot ACK
                    // until this handler returns. The parent SIGKILLs at this event.
                    try await output.send(Event(event: "committedBeforeAck", capturedAt: capturedAt.timeIntervalSince1970))
                    try await Task.sleep(for: .seconds(30))
                }
            }, onGap: { reason in try? await store.recordCoverageGap(reason: reason) })
        try await output.send(Event(event: "ready"))
        // Blocking stdin reads must not occupy the main actor while the real
        // capture handler and scanner make progress on their actors.
        while let line = await Task.detached(operation: { readLine() }).value,
              let data = line.data(using: .utf8), data.count < 1024 {
            let command = try JSONDecoder().decode(Command.self, from: data).command
            switch command {
            case "pause":
                await store.setMonitoring(enabled: false)
                try await output.send(Event(event: "paused"))
            case "resume":
                await store.setMonitoring(enabled: true)
                try await output.send(Event(event: "resumed"))
            case "drain":
                var stopped = false
                for _ in 0..<64 {
                    if try await pipeline.processNext() == .idle { stopped = true; break }
                }
                guard stopped else { throw ProbeError.drainLimit }
                try await statistics(store: store, detector: detector, native: native, output: output)
            case "statistics":
                try await statistics(store: store, detector: detector, native: native, output: output)
            case "stop":
                await server.stop()
                try await store.close()
                try await output.send(Event(event: "stopped"))
                return
            default: throw ProbeError.command
            }
        }
        await server.stop()
        try await store.close()
    }

    private static func statistics(store: ProtectedStore, detector: MeasuredDetector,
                                   native: NativeGuard, output: Output) async throws {
        let snapshot = await store.snapshot(), queue = try await store.queueStatistics()
        let gaps = try await store.coverageGaps()
        let reads = try await store.coverageReport().successfulReads.items
        let occurrences = Array(snapshot.occurrences.values)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Dictionaries and Sets do not preserve order across a process restart.
        // Canonicalize only those unordered collections, retaining source ranges.
        let stableOccurrences = try occurrences.sorted { $0.id.uuidString < $1.id.uuidString }.map { occurrence in
            var object = try JSONSerialization.jsonObject(with: encoder.encode(occurrence)) as! [String: Any]
            for key in ["origins", "evidence"] {
                if let items = object[key] as? [Any] {
                    object[key] = try items.map {
                        try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
                    }.sorted { $0.lexicographicallyPrecedes($1) }.map {
                        try JSONSerialization.jsonObject(with: $0)
                    }
                }
            }
            return object
        }
        let digest = SHA256.hash(data: try JSONSerialization.data(withJSONObject: stableOccurrences, options: [.sortedKeys]))
            .map { String(format: "%02x", $0) }.joined()
        try await output.send(Statistics(queueCount: queue.count, claimedCount: queue.claimedCount,
            records: snapshot.records.count, occurrences: occurrences.count, receipts: snapshot.analysisReceipts.count,
            detectorCalls: await detector.calls, scannerFailures: await detector.failures, nativeCalls: await native.calls,
            contentTypes: Dictionary(grouping: occurrences, by: { $0.source.contentType.rawValue }).mapValues(\.count),
            allSourcesHookObserved: occurrences.allSatisfy {
                $0.source.origin.adapterID == "codex-hook-content" && $0.source.timeBasis == .firstObservation
            }, hookReadCount: reads.filter { $0.scope.path == .hook }.count,
            nativeReadCount: reads.filter { $0.scope.path != .hook }.count,
            diagnostics: Array(Set(gaps.compactMap { $0.diagnosticCode?.rawValue })).sorted(),
            reasons: Array(Set(gaps.map { $0.reason.rawValue })).sorted(),
            firstObserved: occurrences.map { $0.source.observedAt.timeIntervalSince1970 }.min(), inventoryDigest: digest))
    }
}
