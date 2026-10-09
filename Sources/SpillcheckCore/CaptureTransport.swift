import Darwin
import Foundation

public enum CaptureTransportError: Error, Sendable {
    case invalidFrame, invalidMetadata, oversizedFrame, unsafeDirectory, endpointInUse
    case unavailable, deadlineExceeded, unauthorizedPeer
}

/// Trusted transport metadata has separate framing from opaque upstream JSON.
public struct CaptureMetadata: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let agent: AgentProvider
    public let interface: AgentInterface
    public let profileID: String
    public let eventEncoding: String

    public init(agent: AgentProvider, interface: AgentInterface = .standaloneCLI, profileID: String = "default") throws {
        guard !profileID.isEmpty, profileID.utf8.count <= 256, !profileID.utf8.contains(0) else {
            throw CaptureTransportError.invalidMetadata
        }
        schemaVersion = 1
        self.agent = agent
        self.interface = interface
        self.profileID = profileID
        eventEncoding = "json"
    }

    fileprivate func validate() throws {
        guard schemaVersion == 1, eventEncoding == "json", !profileID.isEmpty,
              profileID.utf8.count <= 256, !profileID.utf8.contains(0) else {
            throw CaptureTransportError.invalidMetadata
        }
    }
}

public struct CapturePacket: Sendable {
    public static let maximumBodyBytes = 8 * 1024 * 1024
    public static let maximumMetadataBytes = 1024
    public let metadata: CaptureMetadata
    public let eventJSON: Data
    public let body: Data

    public init(metadata: CaptureMetadata, eventJSON: Data) throws {
        try metadata.validate()
        let header = try JSONEncoder().encode(metadata)
        guard header.count <= Self.maximumMetadataBytes else { throw CaptureTransportError.invalidMetadata }
        guard !eventJSON.isEmpty, header.count + eventJSON.count + 4 <= Self.maximumBodyBytes else {
            throw CaptureTransportError.oversizedFrame
        }
        var size = UInt32(header.count).bigEndian
        var bytes = withUnsafeBytes(of: &size) { Data($0) }
        bytes.append(header)
        bytes.append(eventJSON)
        self.metadata = metadata
        self.eventJSON = eventJSON
        body = bytes
    }

    public init(body: Data) throws {
        guard body.count <= Self.maximumBodyBytes else { throw CaptureTransportError.oversizedFrame }
        guard body.count > 4 else { throw CaptureTransportError.invalidFrame }
        let size = Self.length(body.prefix(4))
        guard size > 0, size <= Self.maximumMetadataBytes, 4 + size < body.count else {
            throw CaptureTransportError.invalidFrame
        }
        let header = body.subdata(in: 4..<(4 + size))
        let expected = Set(["schemaVersion", "agent", "interface", "profileID", "eventEncoding"])
        guard let fields = try JSONSerialization.jsonObject(with: header) as? [String: Any],
              Set(fields.keys) == expected else { throw CaptureTransportError.invalidMetadata }
        let metadata = try JSONDecoder().decode(CaptureMetadata.self, from: header)
        try metadata.validate()
        self.metadata = metadata
        eventJSON = body.subdata(in: (4 + size)..<body.count)
        self.body = body
    }

    fileprivate static func length(_ bytes: Data.SubSequence) -> Int {
        bytes.reduce(0) { ($0 << 8) | Int($1) }
    }
}

/// One app-owned endpoint. No capture survives shutdown except already committed encrypted rows.
public actor LocalCaptureServer {
    public typealias CaptureHandler = @Sendable (CapturePacket) async throws -> Void
    public typealias AcceptanceGate = @Sendable () async -> Bool
    public typealias GapHandler = @Sendable (CoverageGapReason) async -> Void
    private var listenerTask: Task<Void, Never>?
    private var children: [UUID: Task<Void, Never>] = [:]
    private var socketPath: String?
    private var running = false
    private let maximumClients: Int

    public init(maximumClients: Int = 4) { self.maximumClients = max(1, min(maximumClients, 16)) }

    public func start(at url: URL, accepting: @escaping AcceptanceGate,
                      onCapture: @escaping CaptureHandler, onGap: @escaping GapHandler) throws {
        guard !running else { throw CaptureTransportError.endpointInUse }
        let path = url.path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path), !path.utf8.contains(0) else {
            throw CaptureTransportError.unsafeDirectory
        }
        var parent = stat()
        guard lstat(url.deletingLastPathComponent().path, &parent) == 0,
              parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == getuid(), parent.st_mode & 0o077 == 0 else {
            throw CaptureTransportError.unsafeDirectory
        }
        try Self.removeStaleEndpoint(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CaptureTransportError.unavailable }
        do {
            try Self.configure(descriptor)
            var address = Self.address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
                throw CaptureTransportError.unavailable
            }
        } catch { close(descriptor); throw error }
        running = true
        socketPath = path
        listenerTask = Task.detached(priority: .utility) { [weak self] in
            defer { close(descriptor) }
            while !Task.isCancelled {
                var pending = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let result = poll(&pending, 1, 50)
                if result < 0 && errno == EINTR { continue }
                if result == 0 { continue }
                guard result > 0, pending.revents & Int16(POLLIN) != 0 else { break }
                let client = accept(descriptor, nil, nil)
                if client < 0 { continue }
                guard let self else { close(client); break }
                await self.acceptClient(client, accepting: accepting, onCapture: onCapture, onGap: onGap)
            }
        }
    }

    public func stop() async {
        running = false
        let listener = listenerTask
        listenerTask = nil
        listener?.cancel()
        let pending = Array(children.values)
        for child in pending { child.cancel() }
        await listener?.value
        for child in pending { await child.value }
        children.removeAll()
        if let path = socketPath {
            var info = stat()
            if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() { unlink(path) }
        }
        socketPath = nil
    }

    private func acceptClient(_ descriptor: Int32, accepting: @escaping AcceptanceGate,
                              onCapture: @escaping CaptureHandler, onGap: @escaping GapHandler) {
        guard running else { close(descriptor); return }
        guard children.count < maximumClients else {
            close(descriptor)
            Task { await onGap(.queueSaturated) }
            return
        }
        let id = UUID()
        children[id] = Task.detached(priority: .utility) { [weak self] in
            defer { close(descriptor) }
            do {
                try Self.configure(descriptor)
                var user: uid_t = 0
                var group: gid_t = 0
                guard getpeereid(descriptor, &user, &group) == 0, user == getuid() else {
                    throw CaptureTransportError.unauthorizedPeer
                }
                if await accepting() {
                    let deadline = DispatchTime.now().uptimeNanoseconds + 200_000_000
                    let length = CapturePacket.length(try Self.readExactly(4, from: descriptor, deadline: deadline))
                    guard length > 4, length <= CapturePacket.maximumBodyBytes else {
                        throw CaptureTransportError.oversizedFrame
                    }
                    let packet = try CapturePacket(body: Self.readExactly(length, from: descriptor, deadline: deadline))
                    try Task.checkCancellation()
                    try await onCapture(packet) // Return only after durable encrypted queue insertion.
                    try Task.checkCancellation()
                    if !Self.acknowledge(1, to: descriptor) { await onGap(.deliveryUncertain) }
                } else { _ = Self.acknowledge(0, to: descriptor) }
            } catch {
                _ = Self.acknowledge(0, to: descriptor)
                if !Task.isCancelled { await onGap(.captureRejected) }
            }
            await self?.finished(id)
        }
    }

    private func finished(_ id: UUID) { children.removeValue(forKey: id) }

    private static func acknowledge(_ value: UInt8, to descriptor: Int32) -> Bool {
        var byte = value
        return Darwin.write(descriptor, &byte, 1) == 1
    }

    private static func configure(_ descriptor: Int32) throws {
        var noSignal: Int32 = 1
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw CaptureTransportError.unavailable
        }
    }

    private static func readExactly(_ count: Int, from descriptor: Int32, deadline: UInt64) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: min(count, 64 * 1024))
        while data.count < count {
            try Task.checkCancellation()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw CaptureTransportError.deadlineExceeded }
            var pending = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(max(1, (deadline - now + 999_999) / 1_000_000))
            let ready = poll(&pending, 1, milliseconds)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0, pending.revents & Int16(POLLIN | POLLHUP) != 0,
                  pending.revents & Int16(POLLERR | POLLNVAL) == 0 else { throw CaptureTransportError.unavailable }
            let readCount = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, min($0.count, count - data.count))
            }
            if readCount < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            guard readCount > 0 else { throw CaptureTransportError.invalidFrame }
            data.append(contentsOf: buffer.prefix(readCount))
        }
        return data
    }

    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            for (index, byte) in path.utf8.enumerated() { bytes[index] = byte }
        }
        return address
    }

    private static func removeStaleEndpoint(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw CaptureTransportError.unsafeDirectory
        }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
            throw CaptureTransportError.unsafeDirectory
        }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw CaptureTransportError.unavailable }
        defer { close(probe) }
        try configure(probe)
        var socketAddress = address(path)
        let result = withUnsafePointer(to: &socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result != 0, errno == ECONNREFUSED || errno == ENOENT else {
            throw CaptureTransportError.endpointInUse
        }
        guard unlink(path) == 0 || errno == ENOENT else { throw CaptureTransportError.unavailable }
    }
}
