import Foundation

public enum NotificationNavigationTarget: Hashable, Codable, Sendable {
    case value(UUID)
    case historicalAudit(UUID)
    case collectionHealth(UUID)
}

/// The label can only contain app-generated numbering, never a provider title or identifier.
public struct MaskedConversationLabel: Hashable, Codable, Sendable {
    public let index: Int
    public init(index: Int) { self.index = max(1, index) }
    public var text: String { "Conversation \(index)" }
}

/// A stable inventory entry number. It identifies an entry without any part of its value.
public struct MaskedValueLabel: Hashable, Codable, Sendable {
    public let index: Int
    public init(index: Int) { self.index = max(1, index) }
    public var text: String { "L-\(index)" }
}

public struct HistoricalNotificationDecision: Equatable, Codable, Sendable {
    public let audit: HistoricalAuditContext
    public let ordinaryValueCount: Int
    public let ordinaryOccurrenceCount: Int
    public let obsoleteOccurrenceCount: Int
    public internal(set) var delivery: AlertDeliveryState
    public var notificationIdentifier: String { "leakret-audit-\(audit.id.uuidString.lowercased())" }

    public init(summary: HistoricalAuditSummary, delivery: AlertDeliveryState = .pending) {
        audit = summary.audit
        ordinaryValueCount = summary.ordinaryValueCount
        ordinaryOccurrenceCount = summary.ordinaryOccurrenceCount
        obsoleteOccurrenceCount = summary.obsoleteOccurrenceCount
        self.delivery = delivery
    }
}

/// Only controlled labels and counts can enter notification text. Navigation contains app UUIDs.
public struct MaskedNotification: Equatable, Sendable {
    public let identifier: String
    public let target: NotificationNavigationTarget
    public let title: String
    public let body: String

    public static func live(_ alert: AlertDecision, conversation: MaskedConversationLabel) -> Self {
        let kind = alert.categories.count == 1 ? alert.categories.first!.displayName : "secret"
        let noun = kind.hasPrefix("API") ? kind : kind.prefix(1).lowercased() + kind.dropFirst()
        return Self(identifier: alert.notificationIdentifier, target: .value(alert.valueID),
            title: "New \(noun) detected",
            body: "\(conversation.text) · \(alert.provider.displayName)\nValue hidden. Open Spillcheck to review.")
    }

    public static func historical(_ decision: HistoricalNotificationDecision) -> Self {
        Self(identifier: decision.notificationIdentifier, target: .historicalAudit(decision.audit.id),
             title: "Recent history reviewed",
             body: "\(decision.ordinaryValueCount) values in \(decision.ordinaryOccurrenceCount) occurrences. Open Spillcheck to review the masked summary.")
    }

    public static func health(_ incident: CollectionHealthIncident) -> Self {
        let affected = [incident.contentType?.pluralLabel, incident.operation?.label].compactMap { $0 }.joined(separator: " · ")
        return Self(identifier: incident.notificationIdentifier, target: .collectionHealth(incident.id),
             title: "Collection needs attention",
             body: "\(incident.scope.provider.displayName) · \(incident.scope.interface.hostLabel) · \(affected.isEmpty ? "Required collection" : affected) unavailable. Other readable content continues. Open Spillcheck to review coverage.")
    }
}

public enum ProtectedPreferenceKey: String, Codable, Sendable {
    case agentProfiles
    public static let maximumBytes = 256 * 1024
}
