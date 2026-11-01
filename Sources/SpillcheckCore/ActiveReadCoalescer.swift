import Foundation

/// Active monitors queue a read whenever a source changes or its poll is due. A queued read
/// reads its source as it is when it runs, so while it still waits for its first attempt, an
/// identical read queued behind it would find nothing new. That read stands in for the new
/// one. A read that has started, or is waiting to retry, may already be past the change, so
/// the new read is queued.
public actor ActiveReadCoalescer {
    public typealias Waiting = @Sendable (UUID) async throws -> Bool
    /// Bounds the remembered reads; each active source has at most one.
    static let maximumRemembered = 1024
    private let isWaiting: Waiting
    /// The last read queued for each identical poll.
    private var queued: [Key: UUID] = [:]

    /// Identical polls of one source have the same provider, profile and interface, and the same
    /// event: its session and transcript paths, written with sorted keys. The packet's header
    /// is not compared as bytes, since its encoding does not fix the order of its fields.
    private struct Key: Hashable {
        let metadata: CaptureMetadata
        let event: Data
    }

    public init(isWaiting: @escaping Waiting) { self.isWaiting = isWaiting }

    /// Queues the read unless an identical one is still waiting for its first attempt.
    public func enqueue(_ packet: CapturePacket, using enqueue: @Sendable (CapturePacket) async throws -> UUID) async throws {
        let key = Key(metadata: packet.metadata, event: packet.eventJSON)
        if let id = queued[key] {
            if try await isWaiting(id) { return }
            queued.removeValue(forKey: key)
        }
        let id = try await enqueue(packet)
        if queued.count >= Self.maximumRemembered { queued.removeAll() }
        queued[key] = id
    }
}
