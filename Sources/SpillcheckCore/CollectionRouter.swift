import Foundation

public struct CollectionRoute: Sendable {
    public let provider: AgentProvider
    public let profileID: String
    public let interface: AgentInterface
    public let normalizer: any CaptureNormalizer

    public init(provider: AgentProvider, profileID: String, interface: AgentInterface,
                normalizer: any CaptureNormalizer) {
        self.provider = provider
        self.profileID = profileID
        self.interface = interface
        self.normalizer = normalizer
    }
}

/// Selects an explicitly configured collector. It never falls back to a different representation.
public struct CollectionRouter: CaptureNormalizer, Sendable {
    private let routes: [CollectionRoute]

    public init(routes: [CollectionRoute]) throws {
        let keys = routes.map { "\($0.provider.rawValue)\u{0}\($0.profileID)\u{0}\($0.interface.rawValue)" }
        guard Set(keys).count == keys.count else { throw ContractError.invalidState }
        self.routes = routes
    }

    public func normalize(_ packet: CapturePacket, capturedAt: Date,
                          cryptography: BackgroundCryptography) async throws -> CollectionBatch {
        guard let route = routes.first(where: {
            $0.provider == packet.metadata.agent && $0.profileID == packet.metadata.profileID
                && $0.interface == packet.metadata.interface
        }) else {
            return CollectionBatch(sources: [], coverageGaps: [.init(reason: .unsupportedVersion)])
        }
        return try await route.normalizer.normalize(packet, capturedAt: capturedAt, cryptography: cryptography)
    }
}
