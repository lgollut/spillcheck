import Darwin
import Foundation
import Testing
@_spi(Testing) @testable import SpillcheckCore

private actor CaptureRecorder {
    var packets: [CapturePacket] = []
    var gaps: [CoverageGapReason] = []
    var rejections: [CaptureRejectionDiagnostic] = []
    var enabled = true
    var hold = false
    var waiting: CheckedContinuation<Void, Never>?
    func accept() -> Bool { enabled }
    func receive(_ packet: CapturePacket) async {
        packets.append(packet)
        if hold { await withCheckedContinuation { waiting = $0 } }
    }
    func gap(_ reason: CoverageGapReason) { gaps.append(reason) }
    func rejection(_ diagnostic: CaptureRejectionDiagnostic) { rejections.append(diagnostic) }
    func configure(enabled: Bool = true, hold: Bool = false) { self.enabled = enabled; self.hold = hold }
    func release() { hold = false; waiting?.resume(); waiting = nil }
}

private final class CaptureClient {
    private(set) var descriptor: Int32
    init(path: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CaptureTransportError.unavailable }
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 400_000)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            for (i, byte) in path.utf8.enumerated() { bytes[i] = byte }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(descriptor); throw CaptureTransportError.unavailable }
    }
    deinit { disconnect() }
    func disconnect() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }
    func send(_ body: Data, declaredSize: UInt32? = nil) {
        var size = (declaredSize ?? UInt32(body.count)).bigEndian
        withUnsafeBytes(of: &size) { _ = Darwin.write(descriptor, $0.baseAddress, $0.count) }
        if !body.isEmpty { body.withUnsafeBytes { _ = Darwin.write(descriptor, $0.baseAddress, $0.count) } }
    }
    func acknowledgement() -> UInt8? {
        var byte: UInt8 = 0
        return Darwin.read(descriptor, &byte, 1) == 1 ? byte : nil
    }
    func finishSending() { _ = shutdown(descriptor, SHUT_WR) }
    func ready(milliseconds: Int32) -> Bool {
        var p = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, milliseconds) > 0
    }
}

private struct PrivateAdmissionFailure: Error, Sendable { let detail: String }

@Suite("App-owned capture transport", .serialized)
struct CaptureTransportTests {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/spillcheck-transport-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func start(_ server: LocalCaptureServer, _ recorder: CaptureRecorder, at url: URL) async throws {
        try await server.start(at: url, accepting: { await recorder.accept() },
            onCapture: { await recorder.receive($0) }, onGap: { await recorder.gap($0) },
            onRejection: { await recorder.rejection($0) })
    }

    @Test func binaryMetadataCannotBeOverriddenByOpaqueEvent() throws {
        let raw = Data("{\"agent\":\"untrusted\"} }, \"agent\":\"claude-code\"".utf8)
        let packet = try CapturePacket(metadata: CaptureMetadata(agent: .codex, interface: .t3), eventJSON: raw)
        let decoded = try CapturePacket(body: packet.body)
        #expect(decoded.metadata.agent == .codex)
        #expect(decoded.eventJSON == raw)
    }

    @Test func boundsAndVersionAreFailClosed() throws {
        #expect(throws: CaptureTransportError.self) { try CapturePacket(body: Data([0, 0, 4, 1, 0])) }
        #expect(throws: CaptureTransportError.self) {
            try CapturePacket(metadata: CaptureMetadata(agent: .codex), eventJSON: Data(repeating: 0, count: 8 * 1024 * 1024))
        }
        #expect(throws: CaptureTransportError.self) { try CaptureMetadata(agent: .codex, profileID: "") }
        let good = try CapturePacket(metadata: CaptureMetadata(agent: .codex), eventJSON: Data("{}".utf8))
        var bytes = good.body
        let metadataSize = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        let metadata = String(decoding: bytes[4..<(4 + metadataSize)], as: UTF8.self)
        let changed = Data(metadata.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":9").utf8)
        bytes.replaceSubrange(4..<(4 + metadataSize), with: changed)
        #expect(throws: CaptureTransportError.self) { try CapturePacket(body: bytes) }
    }

    @Test func acknowledgementFollowsHandlerCompletionAndShutdownRemovesSocket() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("capture.sock")
        let server = LocalCaptureServer()
        let recorder = CaptureRecorder()
        await recorder.configure(hold: true)
        try await start(server, recorder, at: url)
        let client = try CaptureClient(path: url.path)
        let packet = try CapturePacket(metadata: CaptureMetadata(agent: .claudeCode), eventJSON: Data("{\"text\":\"SYNTHETIC_CAPTURE\"}".utf8))
        client.send(packet.body)
        // Wait for the held handler itself, rather than assuming it was scheduled within 60 ms.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await recorder.packets.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await recorder.packets.count == 1)
        #expect(!client.ready(milliseconds: 0))
        await recorder.release()
        #expect(client.acknowledgement() == 1)
        #expect(await recorder.packets.first?.body == packet.body)
        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func committedCaptureKeepsItsPositiveReceiptWhenTheServerStopsBeforeAcknowledging() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("capture.sock")
        let server = LocalCaptureServer(), recorder = CaptureRecorder()
        await recorder.configure(hold: true)
        try await start(server, recorder, at: url)
        let client = try CaptureClient(path: url.path)
        client.send(try CapturePacket(metadata: CaptureMetadata(agent: .codex), eventJSON: Data("{}".utf8)).body)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await recorder.packets.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await recorder.packets.count == 1)
        // stop() cancels the held handler first and can only finish after it is released.
        let stopping = Task { await server.stop() }
        try await Task.sleep(for: .milliseconds(100))
        await recorder.release()
        await stopping.value
        #expect(client.acknowledgement() == 1)
        #expect(await recorder.gaps.isEmpty)
        #expect(await recorder.rejections.isEmpty)
    }

    @Test func pausedServerRejectsWithoutCallingCaptureHandler() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = LocalCaptureServer()
        let recorder = CaptureRecorder()
        await recorder.configure(enabled: false)
        let url = root.appendingPathComponent("capture.sock")
        try await start(server, recorder, at: url)
        let client = try CaptureClient(path: url.path)
        #expect(client.acknowledgement() == 0)
        #expect(await recorder.packets.isEmpty)
        #expect(await recorder.gaps.isEmpty)
        await server.stop()
        #expect(await recorder.rejections.isEmpty)
    }

    @Test func disconnectedAcknowledgementKeepsDurableCaptureWithoutAddingOrClearingDeliveryGaps() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("store")
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: storeURL, cryptography: crypto)
        let previousGap = CoverageGap(reason: .deliveryUncertain, observedAt: Date().addingTimeInterval(-60))
        try await store.recordCoverageGap(previousGap)
        let recorder = CaptureRecorder()
        await recorder.configure(hold: true)
        let server = LocalCaptureServer(maximumClients: 1)
        let url = root.appendingPathComponent("capture.sock")
        try await server.start(at: url, accepting: { true }, onCapture: { packet in
            let permit = try #require(await store.processingPermit())
            _ = try await store.enqueue(packet.body, capturedAt: .now, permit: permit)
            await recorder.receive(packet)
        }, onGap: { reason in
            try? await store.recordCoverageGap(reason: reason)
            // Recording last also lets the test join deliberately refused sentinel probes.
            await recorder.gap(reason)
        }, onRejection: { await recorder.rejection($0) })
        let packet = try CapturePacket(metadata: CaptureMetadata(agent: .codex),
            eventJSON: Data("{\"text\":\"SYNTHETIC_DURABLE_DISCONNECTED_Ä_🔐\"}".utf8))
        let client = try CaptureClient(path: url.path)
        client.send(packet.body)
        let admissionDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await recorder.packets.isEmpty, ContinuousClock.now < admissionDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let admitted = await recorder.packets.count == 1
        #expect(admitted)
        client.disconnect()
        await recorder.release()

        // A successful second client with capacity one proves the disconnected handler
        // finished its ACK attempt and released its slot. Calling stop immediately after
        // release could instead cancel it before ACK and produce a false passing test.
        let sentinelPacket = try CapturePacket(metadata: CaptureMetadata(agent: .codex),
            eventJSON: Data("{\"text\":\"SYNTHETIC_COMPLETION_SENTINEL\"}".utf8))
        var acknowledged = false
        var refusedProbes = 0
        let completionDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !acknowledged, ContinuousClock.now < completionDeadline {
            let sentinel = try CaptureClient(path: url.path)
            sentinel.send(sentinelPacket.body)
            acknowledged = sentinel.acknowledgement() == 1
            if !acknowledged {
                refusedProbes += 1
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(acknowledged)
        while await recorder.gaps.filter({ $0 == .queueSaturated }).count < refusedProbes,
              ContinuousClock.now < completionDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await recorder.gaps.filter({ $0 == .queueSaturated }).count == refusedProbes)
        await server.stop()
        #expect(await recorder.packets.map(\.body) == [packet.body, sentinelPacket.body])
        #expect(await recorder.gaps.allSatisfy { $0 == .queueSaturated })
        #expect(await recorder.rejections.isEmpty)
        try await store.close()

        let reopened = try await ProtectedStore.open(at: storeURL, cryptography: crypto)
        // An older uncertain delivery has no exact recovery evidence and must remain.
        let deliveryGaps = try await reopened.coverageGaps().filter { $0.reason == .deliveryUncertain }
        #expect(deliveryGaps == [previousGap])
        #expect(try await reopened.queueStatistics().count == 2)
        let permit = try #require(await reopened.processingPermit())
        var recoveredBodies: [Data] = []
        while let pending = try await reopened.nextPending(at: .now, permit: permit) {
            recoveredBodies.append(try await reopened.openCapture(pending))
            try await reopened.completeCapture(pending, permit: permit)
        }
        #expect(recoveredBodies == [packet.body, sentinelPacket.body])
        #expect(try await reopened.queueStatistics().count == 0)
        try await reopened.close()
    }

    @Test func oversizeLengthRejectedWithoutReceivingPayload() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = LocalCaptureServer()
        let recorder = CaptureRecorder()
        let url = root.appendingPathComponent("capture.sock")
        try await start(server, recorder, at: url)
        let client = try CaptureClient(path: url.path)
        client.send(Data(), declaredSize: UInt32(CapturePacket.maximumBodyBytes + 1))
        #expect(client.acknowledgement() == 0)
        #expect(await recorder.packets.isEmpty)
        await server.stop()
    }

    @Test func disconnectedPeerDoesNotHideFailedAdmission() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = CaptureRecorder()
        await recorder.configure(hold: true)
        let server = LocalCaptureServer()
        let url = root.appendingPathComponent("capture.sock")
        try await server.start(at: url, accepting: { true }, onCapture: { packet in
            await recorder.receive(packet)
            throw StorageError.protectionUnavailable
        }, onGap: { await recorder.gap($0) }, onRejection: { await recorder.rejection($0) })
        let client = try CaptureClient(path: url.path)
        client.send(try CapturePacket(metadata: CaptureMetadata(agent: .codex), eventJSON: Data("{}".utf8)).body)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await recorder.packets.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await recorder.packets.count == 1)
        client.disconnect()
        await recorder.release()
        while await recorder.gaps.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await recorder.gaps == [.captureRejected])
        await server.stop()
        #expect(await recorder.rejections == [.init(stage: .admission, reason: .protectionUnavailable)])
    }

    @Test(arguments: [false, true])
    func negativeAcknowledgementKeepsDetailedRecordedRejectionWithoutGenericDuplicate(recorded: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = LocalCaptureServer(), recorder = CaptureRecorder()
        let url = root.appendingPathComponent("capture.sock")
        try await server.start(at: url, accepting: { true }, onCapture: { _ in
            if recorded { throw CaptureTransportError.rejectionRecorded }
            throw StorageError.capacityExceeded(.sourceAuthorities)
        }, onGap: { await recorder.gap($0) }, onRejection: { await recorder.rejection($0) })
        let client = try CaptureClient(path: url.path)
        client.send(try CapturePacket(metadata: CaptureMetadata(agent: .codex), eventJSON: Data("{}".utf8)).body)
        #expect(client.acknowledgement() == 0)
        if !recorded {
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while await recorder.gaps.isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        // stop joins the handler, including its asynchronous failure reporting.
        await server.stop()
        #expect(await recorder.gaps == (recorded ? [] : [.captureRejected]))
        #expect(await recorder.rejections == (recorded ? [] : [.init(stage: .admission, reason: .capacityExceeded)]))
    }

    @Test(arguments: [false, true])
    func incompleteFrameReportsReadStageAndPreservesRejection(bodyStarted: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = LocalCaptureServer(), recorder = CaptureRecorder()
        let url = root.appendingPathComponent("capture.sock")
        try await start(server, recorder, at: url)
        let client = try CaptureClient(path: url.path)
        if bodyStarted { client.send(Data([1, 2]), declaredSize: 12) }
        client.finishSending()
        #expect(client.acknowledgement() == 0)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await recorder.rejections.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        await server.stop()
        #expect(await recorder.packets.isEmpty)
        #expect(await recorder.gaps == [.captureRejected])
        #expect(await recorder.rejections == [.init(stage: bodyStarted ? .frameBody : .frameHeader, reason: .invalidFrame)])
    }

    @Test func malformedMetadataReportsDecodeStageWithoutEchoingInput() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = LocalCaptureServer(), recorder = CaptureRecorder()
        let url = root.appendingPathComponent("capture.sock")
        try await start(server, recorder, at: url)
        let client = try CaptureClient(path: url.path)
        let marker = "PRIVATE_NATIVE_PATH_AND_AUTH_SENTINEL"
        let metadata = Data("{\"untrusted\":\"\(marker)\"}".utf8)
        var length = UInt32(metadata.count).bigEndian
        var body = withUnsafeBytes(of: &length) { Data($0) }
        body.append(metadata); body.append(Data("{}".utf8))
        client.send(body)
        #expect(client.acknowledgement() == 0)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await recorder.rejections.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        await server.stop()
        let diagnostics = await recorder.rejections
        #expect(diagnostics == [.init(stage: .packetDecode, reason: .invalidMetadata)])
        #expect(await recorder.packets.isEmpty)
        #expect(await recorder.gaps == [.captureRejected])
        #expect(!String(decoding: try JSONEncoder().encode(diagnostics), as: UTF8.self).contains(marker))
    }

    @Test(arguments: [CaptureRejectionReason.invalidTime, .expiredCapture, .staleProcessingPermit, .stateChanged, .unknown])
    func throwingAdmissionReportsControlledReasonWithoutEchoingError(reason: CaptureRejectionReason) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = LocalCaptureServer(), recorder = CaptureRecorder()
        let url = root.appendingPathComponent("capture.sock")
        let marker = "PRIVATE_ERROR_PATH_AND_AUTH_SENTINEL"
        try await server.start(at: url, accepting: { true }, onCapture: { _ in
            switch reason {
            case .invalidTime: throw StorageError.invalidTime
            case .expiredCapture: throw StorageError.expiredCapture
            case .staleProcessingPermit: throw StorageError.staleProcessingPermit
            case .stateChanged: throw StorageError.stateChanged
            default: throw PrivateAdmissionFailure(detail: marker)
            }
        }, onGap: { await recorder.gap($0) }, onRejection: { await recorder.rejection($0) })
        let client = try CaptureClient(path: url.path)
        client.send(try CapturePacket(metadata: CaptureMetadata(agent: .claudeCode), eventJSON: Data("{}".utf8)).body)
        #expect(client.acknowledgement() == 0)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await recorder.rejections.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        await server.stop()
        let diagnostics = await recorder.rejections
        #expect(diagnostics == [.init(stage: .admission, reason: reason)])
        #expect(await recorder.gaps == [.captureRejected])
        #expect(!String(decoding: try JSONEncoder().encode(diagnostics), as: UTF8.self).contains(marker))
    }

    @Test func regularFileAndPublicDirectoryArePreserved() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("capture.sock")
        let original = Data("SYNTHETIC_EXISTING_FILE".utf8)
        try original.write(to: url)
        let server = LocalCaptureServer()
        let recorder = CaptureRecorder()
        await #expect(throws: CaptureTransportError.self) { try await start(server, recorder, at: url) }
        #expect(try Data(contentsOf: url) == original)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        await #expect(throws: CaptureTransportError.self) { try await start(server, recorder, at: url) }
    }

    @Test func secondServerDoesNotReplaceLiveEndpoint() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("capture.sock")
        let first = LocalCaptureServer()
        let second = LocalCaptureServer()
        let recorder = CaptureRecorder()
        try await start(first, recorder, at: url)
        await #expect(throws: CaptureTransportError.self) { try await start(second, recorder, at: url) }
        await first.stop()
    }
}
