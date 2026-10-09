import Foundation
import Observation
import UserNotifications
import SpillcheckCore

enum NotificationPermission: Equatable {
    case notRequested, allowed, denied, unavailable
}

enum NotificationDeliveryOutcome: Equatable {
    case delivered, permissionDenied, retry, cancelled
}

@MainActor
protocol NotificationSystem: AnyObject {
    func currentPermission() async -> NotificationPermission
    func requestPermission() async throws
    func existingIdentifiers() async -> Set<String>
    func submit(_ notification: MaskedNotification) async throws
    func removePending(_ identifiers: [String])
    func removeDelivered(_ identifiers: [String])
}

@MainActor
private final class NativeNotificationSystem: NotificationSystem {
    let center = UNUserNotificationCenter.current()

    func currentPermission() async -> NotificationPermission {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notRequested
        case .denied: return .denied
        case .authorized, .provisional: return settings.alertSetting == .disabled ? .denied : .allowed
        @unknown default: return .unavailable
        }
    }

    func requestPermission() async throws { _ = try await center.requestAuthorization(options: [.alert, .sound]) }

    func existingIdentifiers() async -> Set<String> {
        let delivered = await center.deliveredNotifications()
        let pending = await center.pendingNotificationRequests()
        return Set(delivered.map { $0.request.identifier }).union(pending.map(\.identifier))
    }

    func submit(_ notification: MaskedNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        switch notification.target {
        case .value(let id): content.userInfo = ["leakretTarget": "value", "leakretID": id.uuidString.lowercased()]
        case .historicalAudit(let id): content.userInfo = ["leakretTarget": "audit", "leakretID": id.uuidString.lowercased()]
        case .collectionHealth(let id): content.userInfo = ["leakretTarget": "health", "leakretID": id.uuidString.lowercased()]
        }
        try await center.add(UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil))
    }

    func removePending(_ identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func removeDelivered(_ identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
}

@MainActor @Observable
final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    private(set) var permission = NotificationPermission.notRequested
    private(set) var requestingPermission = false
    @ObservationIgnored var onPermissionChange: (@MainActor () -> Void)?
    @ObservationIgnored var onNavigate: (@MainActor (NotificationNavigationTarget) -> Void)? {
        didSet { schedulePendingNavigation() }
    }
    @ObservationIgnored var navigationIsCurrent: (@MainActor (NotificationNavigationTarget) async -> Bool)? {
        didSet { schedulePendingNavigation() }
    }
    @ObservationIgnored private let system: any NotificationSystem
    @ObservationIgnored private var nativeCenter: UNUserNotificationCenter?
    @ObservationIgnored private var enabled = true
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var cancelledIdentifiers: Set<String> = []
    @ObservationIgnored private var inFlightIdentifiers: Set<String> = []
    @ObservationIgnored private var pendingNavigation: NotificationNavigationTarget?
    @ObservationIgnored private var acceptingNavigation = true

    override init() {
        let system = NativeNotificationSystem()
        self.system = system
        nativeCenter = system.center
        super.init()
        nativeCenter?.delegate = self
    }

    /// Deterministic controller checks inject a system without invoking macOS permission UI.
    init(system: any NotificationSystem) {
        self.system = system
        super.init()
    }

    func refreshPermission() async {
        permission = await system.currentPermission()
        onPermissionChange?()
    }

    /// Called only by the explicit notification preference action in the UI.
    func requestPermission() async {
        guard !requestingPermission else { return }
        requestingPermission = true
        onPermissionChange?()
        defer { requestingPermission = false; onPermissionChange?() }
        do {
            try await system.requestPermission()
            await refreshPermission()
        } catch {
            let current = await system.currentPermission()
            switch current {
            case .allowed, .denied: permission = current
            case .notRequested, .unavailable: permission = .unavailable
            }
        }
    }

    func setMonitoring(enabled: Bool) {
        self.enabled = enabled
        generation = UUID()
        if !enabled {
            system.removePending(Array(inFlightIdentifiers))
        }
    }

    /// Call before content removal commits. A later add completion removes both OS copies again.
    func cancel(identifiers: Set<String>) {
        cancelledIdentifiers.formUnion(identifiers)
        system.removePending(Array(identifiers))
        system.removeDelivered(Array(identifiers))
    }

    /// Audit counts can change while their deterministic identifier remains eligible.
    /// Retire stale presentations without suppressing the updated pending decision.
    func invalidatePresentations(identifiers: Set<String>) {
        generation = UUID()
        system.removePending(Array(identifiers))
        system.removeDelivered(Array(identifiers))
    }

    func deliver(_ notification: MaskedNotification,
                 isEligible: @escaping @MainActor () async -> Bool) async -> NotificationDeliveryOutcome {
        let ticket = generation
        guard canDeliver(notification.identifier, ticket: ticket) else { return .cancelled }
        guard inFlightIdentifiers.insert(notification.identifier).inserted else { return .retry }
        defer { inFlightIdentifiers.remove(notification.identifier) }
        await refreshPermission()
        guard await isEligible(), canDeliver(notification.identifier, ticket: ticket) else { return .cancelled }
        switch permission {
        case .denied, .notRequested: return .permissionDenied
        case .unavailable: return .retry
        case .allowed: break
        }
        let existing = await system.existingIdentifiers()
        guard await isEligible(), canDeliver(notification.identifier, ticket: ticket) else { return .cancelled }
        if existing.contains(notification.identifier) { return .delivered }
        do {
            try await system.submit(notification)
            guard await isEligible(), canDeliver(notification.identifier, ticket: ticket) else {
                system.removePending([notification.identifier])
                system.removeDelivered([notification.identifier])
                return .cancelled
            }
            return .delivered
        } catch {
            return canDeliver(notification.identifier, ticket: ticket) ? .retry : .cancelled
        }
    }

    func shutdown() {
        setMonitoring(enabled: false)
        acceptingNavigation = false
        pendingNavigation = nil
        nativeCenter?.delegate = nil
        onNavigate = nil
        navigationIsCurrent = nil
    }

    private func canDeliver(_ identifier: String, ticket: UUID) -> Bool {
        enabled && generation == ticket && !cancelledIdentifiers.contains(identifier) && !Task.isCancelled
    }

    private nonisolated static func target(in content: UNNotificationContent) -> NotificationNavigationTarget? {
        guard let identifier = content.userInfo["leakretID"] as? String,
              let id = UUID(uuidString: identifier), let kind = content.userInfo["leakretTarget"] as? String else { return nil }
        switch kind {
        case "value": return .value(id)
        case "audit": return .historicalAudit(id)
        case "health": return .collectionHealth(id)
        default: return nil
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard let target = Self.target(in: notification.request.content) else { return [] }
        let identifier = notification.request.identifier
        return await presentationOptions(target: target, identifier: identifier)
    }

    private func presentationOptions(target: NotificationNavigationTarget,
                                     identifier: String) async -> UNNotificationPresentationOptions {
        let ticket = generation
        guard canDeliver(identifier, ticket: ticket), await navigationIsCurrent?(target) == true,
              canDeliver(identifier, ticket: ticket) else { return [] }
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let target = Self.target(in: response.notification.request.content) else { return }
        await receiveNavigation(target)
    }

    func receiveNavigation(_ target: NotificationNavigationTarget) async {
        guard acceptingNavigation else { return }
        guard let navigationIsCurrent, onNavigate != nil else {
            // Notification launch may precede asynchronous protected-store initialization.
            pendingNavigation = target
            return
        }
        guard await navigationIsCurrent(target), acceptingNavigation else { return }
        onNavigate?(target)
    }

    func flushPendingNavigation() async {
        guard onNavigate != nil, navigationIsCurrent != nil, let target = pendingNavigation else { return }
        pendingNavigation = nil
        await receiveNavigation(target)
    }

    private func schedulePendingNavigation() {
        Task { [weak self] in await self?.flushPendingNavigation() }
    }
}
