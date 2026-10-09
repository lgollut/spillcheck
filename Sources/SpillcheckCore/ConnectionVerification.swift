import Foundation

/// Persisted only in protected preferences. Executable releases are deliberately absent.
public struct HookRegistrationBinding: Hashable, Codable, Sendable {
    public let provider: AgentProvider
    public let profileID: String
    public let registrationID: UUID
    public let interface: AgentInterface
    public let configurationPath: String
    public let helperPath: String
    public let socketPath: String

    public init(provider: AgentProvider, profileID: String, registrationID: UUID,
                interface: AgentInterface, configurationPath: String, helperPath: String,
                socketPath: String) {
        self.provider = provider
        self.profileID = profileID
        self.registrationID = registrationID
        self.interface = interface
        self.configurationPath = configurationPath
        self.helperPath = helperPath
        self.socketPath = socketPath
    }
}

public struct ConnectionVerificationProof: Hashable, Codable, Sendable {
    public let binding: HookRegistrationBinding
    public let durableQueueID: UUID
    public let verifiedAt: Date

    public init(binding: HookRegistrationBinding, durableQueueID: UUID, verifiedAt: Date) {
        self.binding = binding
        self.durableQueueID = durableQueueID
        self.verifiedAt = verifiedAt
    }

    public func applies(to binding: HookRegistrationBinding) -> Bool {
        self.binding == binding && verifiedAt.timeIntervalSince1970.isFinite
    }
}
