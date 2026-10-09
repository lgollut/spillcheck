import Foundation

/// A host is metadata. The profile and native source remain the canonical authority.
public struct CollectionScope: Hashable, Codable, Sendable {
    public let provider: AgentProvider
    public let profileID: String
    public let interface: AgentInterface
    public let path: CollectionPath

    public init(provider: AgentProvider, profileID: String, interface: AgentInterface,
                path: CollectionPath) {
        self.provider = provider
        self.profileID = profileID
        self.interface = interface
        self.path = path
    }
}

public enum CollectionOperation: String, Hashable, Codable, CaseIterable, Sendable {
    case hookDelivery, liveRead, historicalRead
}

public enum CollectionFormat: String, Codable, Sendable {
    case claudeTranscript = "claude-transcript-v1"
    case codexPublicHistory = "codex-public-history-v1"
    case codexNativeRollout = "codex-native-rollout-v1"
}

public enum CompatibilityFailureReason: String, Codable, Sendable {
    case routeNotEstablished, missingMethod, rejectedParameters, malformedReply
    case changedContentFormat, sourceUnavailable, transientFailure, explicitExclusion
}

public struct CompatibilityFailure: Hashable, Codable, Sendable {
    public let reason: CompatibilityFailureReason
    public let operation: CollectionOperation?
    public let contentType: ContentType?

    public init(reason: CompatibilityFailureReason, operation: CollectionOperation? = nil,
                contentType: ContentType? = nil) {
        self.reason = reason
        self.operation = operation
        self.contentType = contentType
    }
}

public enum CollectionCompatibilityStatus: String, Codable, Sendable {
    case unverified, compatible, partial, incompatible
}

/// Runtime observations never confer acceptance evidence or connection proof.
public struct CollectionAssessment: Hashable, Codable, Sendable {
    public let scope: CollectionScope
    public let observedExecutableVersion: String?
    public let format: CollectionFormat?
    public let usableOperations: Set<CollectionOperation>
    public let unavailableContent: Set<ContentType>
    public let failures: [CompatibilityFailure]
    public let acceptanceEvidence: CapabilityValidation

    public init(scope: CollectionScope, observedExecutableVersion: String? = nil,
                format: CollectionFormat? = nil, usableOperations: Set<CollectionOperation> = [],
                unavailableContent: Set<ContentType> = [], failures: [CompatibilityFailure] = [],
                acceptanceEvidence: CapabilityValidation = .unverified) {
        self.scope = scope
        self.observedExecutableVersion = observedExecutableVersion
        self.format = format
        self.usableOperations = usableOperations
        self.unavailableContent = unavailableContent
        self.failures = failures
        self.acceptanceEvidence = acceptanceEvidence
    }

    public var status: CollectionCompatibilityStatus {
        // A temporary read failure says nothing about the format; only a fresh read can settle it.
        guard !usableOperations.isEmpty else {
            return failures.allSatisfy { $0.reason == .transientFailure } ? .unverified : .incompatible
        }
        return failures.isEmpty && unavailableContent.isEmpty ? .compatible : .partial
    }

    public func canPerform(_ operation: CollectionOperation) -> Bool {
        usableOperations.contains(operation)
    }
}

public enum CollectionCompatibility {
    /// Used only to permit assessment of an authorized configuration. Adapters still recognize
    /// each record and readers still validate each passive operation. No release allowlist.
    public static func isEligible(provider: AgentProvider, interface: AgentInterface,
                                  version: String) -> Bool {
        !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !version.utf8.contains(0) && version.utf8.count <= 256
            && interface != .desktopCode
    }

    /// These are the previously published genuine acceptance tuples, never eligibility rules.
    public static func recordedEvidence(provider: AgentProvider, interface: AgentInterface,
                                        producerVersion: String, readerVersion: String? = nil,
                                        hostVersion: String? = nil) -> CapabilityValidation {
        switch (provider, interface) {
        case (.claudeCode, .standaloneCLI):
            return producerVersion == "2.1.293" ? .validated : .unverified
        case (.claudeCode, .t3):
            return producerVersion == "2.1.293" && hostVersion == "0.0.46-nightly.20261007.2761"
                ? .validated : .unverified
        case (.codex, .standaloneCLI):
            return producerVersion == "0.161.0" && readerVersion == "0.161.0" ? .validated : .unverified
        case (.codex, .t3):
            return producerVersion == "0.160.1" && readerVersion == "0.161.0"
                && hostVersion == "0.0.46-nightly.20261007.2761" ? .validated : .unverified
        default: return .unverified
        }
    }

    public static let unknownProducerVersion = "unknown"
}
