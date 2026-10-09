import Foundation
import Observation
import ServiceManagement

enum LoginItemState: String {
    case disabled, enabled, requiresApproval, unavailable

    var message: String? {
        switch self {
        case .disabled, .enabled: nil
        case .requiresApproval: "Approve Spillcheck in System Settings, General, Login Items."
        case .unavailable: "Launch at login is unavailable for this installation."
        }
    }
}

@MainActor @Observable
final class LoginItemController {
    private(set) var state: LoginItemState = .disabled
    private(set) var isChanging = false
    private(set) var errorMessage: String?

    init() { refresh() }

    /// Merely inspecting the preference never registers or unregisters the app.
    func refresh() {
        switch SMAppService.mainApp.status {
        case .notRegistered: state = .disabled
        case .enabled: state = .enabled
        case .requiresApproval: state = .requiresApproval
        case .notFound: state = .unavailable
        @unknown default: state = .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isChanging else { return }
        isChanging = true
        errorMessage = nil
        defer { isChanging = false; refresh() }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "The launch-at-login preference could not be changed."
        }
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
