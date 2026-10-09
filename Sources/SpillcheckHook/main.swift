import Darwin
import Foundation

// This short-lived delivery client never starts Spillcheck, reads histories, scans,
// or writes payloads to disk. Only the running app may own durable ingestion.
private enum DeliveryError: Error { case invalid, unavailable, expired }

private struct Options {
    let socketPath: String
    let agent: String
    let interface: String
    let profileID: String

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        let names = ["--socket", "--agent", "--interface", "--profile-id"]
        guard arguments.count.isMultiple(of: 2) else { throw DeliveryError.invalid }
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let name = arguments[index]
            guard names.contains(name), values[name] == nil else { throw DeliveryError.invalid }
            values[name] = arguments[index + 1]
        }
        guard let path = values["--socket"], path.hasPrefix("/"), !path.utf8.contains(0),
              path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path),
              let agent = values["--agent"], ["codex", "claude-code"].contains(agent) else {
            throw DeliveryError.invalid
        }
        let interface = values["--interface"] ?? "standalone-cli"
        let profileID = values["--profile-id"] ?? "default"
        guard ["standalone-cli", "t3", "desktop-code"].contains(interface),
              !profileID.isEmpty, profileID.utf8.count <= 256, !profileID.utf8.contains(0) else {
            throw DeliveryError.invalid
        }
        socketPath = path
        self.agent = agent
        self.interface = interface
        self.profileID = profileID
    }
}

private enum HookDelivery {
    static let maximumEnvelopeBytes = 8 * 1024 * 1024
    static let attemptNanoseconds: UInt64 = 180_000_000

    static func requireTime(_ deadline: UInt64) throws {
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw DeliveryError.expired }
    }

    static func waitFor(_ descriptor: Int32, events: Int16, deadline: UInt64, allowEOF: Bool = false) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw DeliveryError.expired }
            let remaining = deadline - now
            let milliseconds = Int32(max(1, (remaining + 999_999) / 1_000_000))
            var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&pollDescriptor, 1, milliseconds)
            if result < 0 && errno == EINTR { continue }
            guard result > 0, pollDescriptor.revents & Int16(POLLNVAL | POLLERR) == 0 else {
                throw DeliveryError.unavailable
            }
            let readable = pollDescriptor.revents & events != 0
            let eof = allowEOF && pollDescriptor.revents & Int16(POLLHUP) != 0
            guard readable || eof else { throw DeliveryError.unavailable }
            return
        }
    }

    static func readInput(maximumBytes: Int, deadline: UInt64) throws -> Data {
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        guard flags >= 0, fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw DeliveryError.unavailable
        }
        defer { _ = fcntl(STDIN_FILENO, F_SETFL, flags) }
        var payload = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try waitFor(STDIN_FILENO, events: Int16(POLLIN), deadline: deadline, allowEOF: true)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { continue }
            guard count >= 0 else { throw DeliveryError.unavailable }
            if count == 0 { return payload }
            guard payload.count + count <= maximumBytes else { throw DeliveryError.invalid }
            buffer.withUnsafeBufferPointer { payload.append($0.baseAddress!, count: count) }
        }
    }

    static func metadata(options: Options, deadline: UInt64) throws -> Data {
        try requireTime(deadline)
        let metadata: [String: Any] = ["schemaVersion": 1, "agent": options.agent,
                                       "interface": options.interface, "profileID": options.profileID,
                                       "eventEncoding": "json"]
        let bytes = try JSONSerialization.data(withJSONObject: metadata)
        guard bytes.count <= 1024 else { throw DeliveryError.invalid }
        try requireTime(deadline)
        return bytes
    }

    static func envelope(metadata: Data, event: Data, deadline: UInt64) throws -> Data {
        try requireTime(deadline)
        guard !event.isEmpty, metadata.count + 4 + event.count <= maximumEnvelopeBytes else {
            throw DeliveryError.invalid
        }
        // Event bytes are never parsed or spliced into metadata JSON. The receiver
        // encrypts them before asynchronous validation and reports malformed-source
        // coverage gaps. This keeps fragmented JSON within the helper's deadline.
        var metadataLength = UInt32(metadata.count).bigEndian
        var bytes = withUnsafeBytes(of: &metadataLength) { Data($0) }
        bytes.append(metadata)
        bytes.append(event)
        try requireTime(deadline)
        return bytes
    }

    static func socketAddress(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            for (index, byte) in path.utf8.enumerated() { bytes[index] = byte }
        }
        return address
    }

    static func send(_ data: Data, descriptor: Int32, deadline: UInt64) throws {
        var position = 0
        while position < data.count {
            try waitFor(descriptor, events: Int16(POLLOUT), deadline: deadline)
            let written = data.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: position), data.count - position)
            }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { continue }
            guard written > 0 else { throw DeliveryError.unavailable }
            position += written
        }
    }

    static func connectSocket(options: Options, deadline: UInt64) throws -> Int32 {
        try requireTime(deadline)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DeliveryError.unavailable }
        var connected = false
        defer { if !connected { close(descriptor) } }
        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw DeliveryError.unavailable }
        var address = socketAddress(options.socketPath)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 || errno == EINPROGRESS else { throw DeliveryError.unavailable }
        if result != 0 { try waitFor(descriptor, events: Int16(POLLOUT), deadline: deadline) }
        var socketError: Int32 = 0
        var errorSize = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &errorSize) == 0, socketError == 0 else {
            throw DeliveryError.unavailable
        }
        // Refuse to send captured text to an endpoint owned by another OS user.
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(descriptor, &user, &group) == 0, user == getuid() else { throw DeliveryError.unavailable }
        connected = true
        return descriptor
    }

    static func deliver(_ body: Data, descriptor: Int32, deadline: UInt64) throws {
        var length = UInt32(body.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        try send(header, descriptor: descriptor, deadline: deadline)
        try send(body, descriptor: descriptor, deadline: deadline)
        try waitFor(descriptor, events: Int16(POLLIN), deadline: deadline, allowEOF: true)
        var acknowledgement: UInt8 = 0
        let count = Darwin.read(descriptor, &acknowledgement, 1)
        guard count == 1, acknowledgement == 1 else { throw DeliveryError.unavailable }
    }

    static func run(arguments: [String]) {
        // One monotonic deadline also bounds an agent that leaves stdin open. No
        // retry may extend this attempt. Process startup is measured separately.
        let deadline = DispatchTime.now().uptimeNanoseconds + attemptNanoseconds
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
        do {
            let options = try Options(arguments: arguments)
            let metadata = try metadata(options: options, deadline: deadline)
            // An unavailable app is rejected before reading or copying agent data.
            let descriptor = try connectSocket(options: options, deadline: deadline)
            defer { close(descriptor) }
            let input = try readInput(maximumBytes: maximumEnvelopeBytes - 4 - metadata.count, deadline: deadline)
            let body = try envelope(metadata: metadata, event: input, deadline: deadline)
            try deliver(body, descriptor: descriptor, deadline: deadline)
        } catch {
            // Delivery failure is deliberately a no-effect hook response. The app
            // owns visible coverage gaps; the helper never emits captured content.
        }
        let response: [UInt8] = [123, 125, 10] // {} followed by newline.
        response.withUnsafeBytes { _ = Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
    }
}

HookDelivery.run(arguments: Array(CommandLine.arguments.dropFirst()))
