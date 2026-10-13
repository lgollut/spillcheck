import Foundation

/// Allowlisted device-key failure facts shared by startup recovery and diagnostic export.
/// No error description, key identifier, or native diagnostic string is retained.
public struct KeyFailureDiagnostic: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case missingManifest, invalidManifest, missingKey, unusableKey
        case accessGroupUnavailable, unsupportedInventoryAlgorithm
    }
    public let reason: Reason
    public let component: KeyComponent?
    public let code: Int?

    public init(_ failure: KeyUnavailable) {
        switch failure {
        case .missingManifest: reason = .missingManifest; component = nil; code = nil
        case .invalidManifest: reason = .invalidManifest; component = nil; code = nil
        case .missingKey(let item): reason = .missingKey; component = item; code = nil
        case .unusableKey(let item, let status): reason = .unusableKey; component = item; code = status
        case .accessGroupUnavailable: reason = .accessGroupUnavailable; component = nil; code = nil
        case .unsupportedInventoryAlgorithm: reason = .unsupportedInventoryAlgorithm; component = nil; code = nil
        }
    }

    var isValid: Bool {
        switch reason {
        case .missingKey: component != nil && code == nil
        case .unusableKey: component != nil && code != nil
        default: component == nil && code == nil
        }
    }
}
