import Darwin
import Foundation
import Testing
@testable import SpillcheckCore

private actor CaptureRecorder {
    var packets: [CapturePacket] = []
    var gaps: [CoverageGapReason] = []
    var enabled = true
    var hold = false
    var waiting: CheckedContinuation<Void, Never>?
    func accept() -> Bool { enabled }
    func receive(_ packet: CapturePacket) async {
        packets.append(packet)
        if hold { await withCheckedContinuation { waiting = $0 } }
    }
    func gap(_ reason: CoverageGapReason) { gaps.append(reason) }
    func configure(enabled: Bool = true, hold: Bool = false) { self.enabled = enabled; self.hold = hold }
    func release() { hold = false; waiting?.resume(); waiting = nil }
}

private final class CaptureClient {
    let descriptor: Int32
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
    deinit { close(descriptor) }
    func send(_ body: Data, declaredSize: UInt32? = nil) {
        var size = (declaredSize ?? UInt32(body.count)).bigEndian
        withUnsafeBytes(of: &size) { _ = Darwin.write(descriptor, $0.baseAddress, $0.count) }
        if !body.isEmpty { body.withUnsafeBytes { _ = Darwin.write(descriptor, $0.baseAddress, $0.count) } }
    }
    func acknowledgement() -> UInt8? {
        var byte: UInt8 = 0
        return Darwin.read(descriptor, &byte, 1) == 1 ? byte : nil
    }
    func ready(milliseconds: Int32) -> Bool {
        var p = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, milliseconds) > 0
    }
}

@Suite("App-owned capture transport", .serialized)
struct CaptureTransportTests {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/spillcheck-transport-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func start(_ server: LocalCaptureServer, _ recorder: CaptureRecorder, at url: URL) async throws {
        try await server.start(at: url, accepting: { await recorder.accept() },
            onCapture: { await recorder.receive($0) }, onGap: { await recorder.gap($0) })
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
