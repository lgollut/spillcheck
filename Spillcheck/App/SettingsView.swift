import SwiftUI
import SpillcheckCore

struct SettingsNavigation: View {
    let model: AppModel
    let page: SettingsPage

    private var agentsNeedAttention: Bool {
        !model.monitoringProven || model.routes.contains { $0.shownInCoverage && !$0.collecting }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                ForEach(SettingsPage.allCases, id: \.self) { item in
                    Button { model.route = .settings(item) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 13))
                                .foregroundStyle(page == item ? Palette.ink : Palette.secondary)
                                .frame(width: 18)
                                .accessibilityHidden(true)
                            Text(item.title).font(.system(size: 13)).foregroundStyle(Palette.ink)
                            Spacer()
                            if item == .agents && agentsNeedAttention {
                                StatusDot(color: Palette.amber).accessibilityLabel("Needs attention")
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                        .hoverFill(page == item ? Color.black.opacity(0.075) : .clear,
                                   hover: page == item ? Color.black.opacity(0.075) : Color.black.opacity(0.04))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == item ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            Spacer()
            HStack {
                Button { model.route = .inventory } label: {
                    Label("Back", systemImage: "arrow.left").labelStyle(TightLabelStyle())
                }
                .buttonStyle(QuietButtonStyle(foreground: Palette.ink2, horizontalPadding: 10))
                .keyboardShortcut(.cancelAction)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
    }
}

struct SettingsView: View {
    let model: AppModel
    let page: SettingsPage

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Settings").foregroundStyle(Palette.tertiary)
                Text("/").foregroundStyle(Palette.faint)
                Text(page.title).fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .font(.system(size: 13))
            .padding(.horizontal, 24)
            .frame(height: windowHeaderHeight)
            .background(WindowDragArea())
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    switch page {
                    case .general: GeneralSettings(model: model)
                    case .agents: AgentSettings(model: model)
                    }
                }
                .frame(maxWidth: 680)
                .padding(.horizontal, 40).padding(.top, 20).padding(.bottom, 48)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityIdentifier("settings.window")
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    var trailing: AnyView?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.tertiary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                trailing
            }
            .padding(.horizontal, 2)
            VStack(spacing: 0) { content }.card()
        }
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    var divider = false
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .overlay(alignment: .top) { if divider { Rectangle().fill(Palette.hairline).frame(height: 1) } }
    }
}

struct DesignSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Palette.switchOn : Color(hex: 0xd6d6d3))
                Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .frame(width: 18, height: 18).padding(2)
            }
            .frame(width: 38, height: 22)
            .opacity(enabled ? 1 : 0.5)
            .animation(reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.16), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

private struct GeneralSettings: View {
    let model: AppModel

    private var notificationDetail: String {
        switch model.notificationState {
        case .allowed: "Strong new values alert once per conversation. Ambiguous detections and obsolete values never alert."
        case .denied: "Notifications are turned off in System Settings. Detections still appear here and in the menu bar."
        case .notRequested: "\(AppIdentity.name) asks once you allow it. Detections always appear here and in the menu bar."
        case .unavailable: "Notifications aren’t available right now. Detections still appear here and in the menu bar."
        }
    }

    var body: some View {
        SettingsSection(title: "Monitoring") {
            SettingRow(title: "Monitor agent sessions",
                       detail: "Collects, analyzes, and alerts on new agent content. While paused, nothing is checked.") {
                Toggle("Monitor agent sessions", isOn: Binding(get: { model.monitoringEnabled }, set: { _ in model.toggleMonitoring() }))
                    .toggleStyle(DesignSwitchStyle())
                    .labelsHidden()
                    .disabled(!model.storageReady || model.monitoringTransition || model.stopped || model.isDemo)
                    .accessibilityIdentifier("inventory.toggle-monitoring")
            }
            SettingRow(title: "Launch at login", detail: "On start, \(AppIdentity.name) catches up on the last 7 days.", divider: true) {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.onLaunchAtLoginRequested?($0) }))
                    .toggleStyle(DesignSwitchStyle())
                    .labelsHidden()
                    .disabled(!model.storageReady || model.loginBusy || model.isDemo)
                    .accessibilityIdentifier("settings.launch-at-login")
            }
        }
        if let message = model.loginMessage {
            Text(message).font(.system(size: 12)).foregroundStyle(Palette.tertiary).padding(.horizontal, 2).padding(.top, -18)
        }
        SettingsSection(title: "Notifications") {
            SettingRow(title: "Alerts", detail: notificationDetail) {
                HStack(spacing: 10) {
                    Text(model.notificationState.label).font(.system(size: 12)).foregroundStyle(Palette.tertiary).fixedSize()
                    switch model.notificationState {
                    case .notRequested:
                        Button("Allow notifications…") { model.onRequestNotificationPermission?() }
                            .buttonStyle(OutlineButtonStyle(height: 28))
                            .disabled(!model.storageReady || model.notificationBusy || model.isDemo)
                            .accessibilityIdentifier("settings.allow-notifications")
                    case .denied:
                        Button("Open System Settings") { model.onOpenNotificationSettings?() }
                            .buttonStyle(OutlineButtonStyle(height: 28))
                    case .allowed, .unavailable:
                        EmptyView()
                    }
                }
            }
        }
        Text("Values, excerpts, conversation titles, and project paths stay masked until you reveal them with Touch ID or your password. Viewing locks after 5 minutes idle, when the window closes, or when the Mac sleeps or locks.")
            .font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineSpacing(2)
            .padding(.horizontal, 2).padding(.top, -18)
    }
}

private struct AgentSettings: View {
    let model: AppModel
    @State private var configuring: AgentProvider?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSection(title: "Agents on this Mac", trailing: AnyView(detectButton)) {
                ForEach(Array(model.routes.enumerated()), id: \.element.id) { index, route in
                    AgentRow(model: model, route: route, divider: index > 0) { configuring = route.provider }
                }
            }
            Text("\(AppIdentity.name) only adds and removes its own hooks. Codex asks you to trust them on next start.")
                .font(.system(size: 12)).foregroundStyle(Palette.tertiary).padding(.horizontal, 2)
        }
        .sheet(item: Binding(get: { configuring.map(ConfigureTarget.init) }, set: { configuring = $0?.provider })) { target in
            ConfigureAgentSheet(model: model, provider: target.provider)
        }
    }

    private var detectButton: some View {
        HStack(spacing: 6) {
            if model.detectingAgents { ProgressView().controlSize(.small) }
            Button("Detect again") { model.onDetectAgents?() }
                .buttonStyle(QuietButtonStyle(foreground: Palette.link, height: 24))
                .disabled(!model.storageReady || model.detectingAgents || model.isDemo)
                .accessibilityIdentifier("settings.detect-agents")
        }
    }
}

private struct ConfigureTarget: Identifiable {
    let provider: AgentProvider
    var id: AgentProvider { provider }
}

private struct AgentRow: View {
    let model: AppModel
    let route: AgentRoute
    let divider: Bool
    let configure: () -> Void

    private var busy: Bool { model.agentSetupBusy.contains(route.provider) }
    private var disabled: Bool { !model.storageReady || model.isDemo || busy }

    private var configuration: String {
        guard let profile = route.profile, !profile.executablePath.isEmpty else {
            return "Searched ~/.local/bin, /opt/homebrew/bin, /usr/local/bin"
        }
        let command = route.provider == .codex ? "codex" : "claude"
        let interface = profile.interface == .t3 ? "managed by T3\(profile.t3Version.map { " \($0)" } ?? "")" : profile.executablePath
        return [profile.version.isEmpty ? command : "\(command) \(profile.version)", interface,
                profile.homePath.isEmpty ? nil : "profile \(profile.homePath)"].compactMap { $0 }.joined(separator: " · ")
    }

    private var detail: String {
        if route.waitingForEvent {
            return "Start a new conversation with \(route.name) and send the prompt below. \(AppIdentity.name) confirms as soon as the hook event arrives."
        }
        if let message = model.agentSetupMessages[route.provider] { return message }
        return switch route.state {
        case .notDetected, .notChecked: "Not found in the usual locations."
        case .detected: "Executable found. Not connected yet."
        case .installedUnverified: "Hooks are installed. No event has arrived from a fresh session yet, so monitoring isn’t proven."
        case .connected: "Connected and delivering events."
        case .unsupported: "This version isn’t validated, so its sessions aren’t collected."
        case .unavailable: "Hook configuration needs repair."
        }
    }

    private var action: (label: String, primary: Bool, perform: () -> Void)? {
        switch route.state {
        case .installedUnverified where !route.waitingForEvent:
            return ("Check delivery", true, { model.onVerifyAgent?(route.provider) })
        case .detected:
            guard let profile = route.profile, profile.isComplete else { return ("Connect…", true, configure) }
            return ("Connect…", true, { model.onInstallAgent?(route.provider, profile) })
        case .unsupported: return ("Choose version…", false, configure)
        case .unavailable: return ("Repair", false, { model.onRepairAgent?(route.provider) })
        case .notDetected, .notChecked: return ("Locate…", false, configure)
        case .connected, .installedUnverified: return nil
        }
    }

    var body: some View {
        let status = route.status
        HStack(alignment: .top, spacing: 14) {
            Text(route.monogram)
                .font(.system(size: 11, weight: .bold)).tracking(0.2).foregroundStyle(Palette.ink2)
                .frame(width: 32, height: 32)
                .background(Color(hex: 0xefefec), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(route.name).font(.system(size: 13.5, weight: .semibold))
                    HStack(spacing: 6) {
                        StatusDot(color: status.dot, outlined: status.outlined)
                        Text(status.text)
                    }
                    .font(.system(size: 12)).foregroundStyle(status.color)
                    if busy { ProgressView().controlSize(.small) }
                }
                .frame(minHeight: 20)
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Palette.secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(configuration).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.quaternary)
                    .textSelection(.enabled)
                if route.waitingForEvent, let prompt = model.verificationPrompts[route.provider] {
                    VerificationPrompt(provider: route.provider, prompt: prompt)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                if let action {
                    Button(action.label, action: action.perform)
                        .buttonStyle(action.primary ? AnyButtonStyle(FilledButtonStyle(height: 28)) : AnyButtonStyle(OutlineButtonStyle(height: 28)))
                        .accessibilityIdentifier("settings.\(route.provider.rawValue).action")
                }
                Button("Configure…", action: configure)
                    .buttonStyle(QuietButtonStyle(foreground: Palette.secondary, horizontalPadding: 10))
                    .accessibilityIdentifier("settings.\(route.provider.rawValue).configure")
            }
            .disabled(disabled)
        }
        .padding(16)
        .overlay(alignment: .top) { if divider { Rectangle().fill(Color(hex: 0xe6e6e3)).frame(height: 1) } }
    }
}

struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<Style: ButtonStyle>(_ style: Style) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

private struct VerificationPrompt: View {
    let provider: AgentProvider
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(provider == .codex
                 ? "Open Codex with this profile, enter /hooks, review the \(AppIdentity.name) helper, trust it, then send this prompt:"
                 : "Open a fresh Claude Code session with this profile and send this prompt:")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(prompt).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityIdentifier("settings.\(provider.rawValue).verification-prompt")
            Text("The prompt contains no credential.").font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
        }
        .padding(.top, 4)
    }
}

private struct ConfigureAgentSheet: View {
    let model: AppModel
    let provider: AgentProvider
    @State private var draft: AgentProfileDraft
    @State private var confirmRemoval = false
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, provider: AgentProvider) {
        self.model = model
        self.provider = provider
        _draft = State(initialValue: model.agentProfiles[provider] ?? AgentProfileDraft(provider: provider))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Configure \(provider.displayName)").font(.system(size: 14, weight: .semibold))
            Text("Choose the executable and profile you want analyzed. An executable alone doesn’t establish a working connection.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Executable", text: $draft.executablePath)
                    .accessibilityIdentifier("settings.\(provider.rawValue).executable")
                TextField("Profile directory", text: $draft.homePath)
                    .accessibilityIdentifier("settings.\(provider.rawValue).home")
                TextField("Agent version", text: $draft.version)
                    .accessibilityIdentifier("settings.\(provider.rawValue).version")
                Picker("Interface", selection: $draft.interface) {
                    Text("Standalone CLI").tag(AgentInterface.standaloneCLI)
                    Text("T3").tag(AgentInterface.t3)
                }
                .accessibilityIdentifier("settings.\(provider.rawValue).interface")
                if draft.interface == .t3 {
                    TextField("T3 version", text: Binding(get: { draft.t3Version ?? "" },
                                                          set: { draft.t3Version = $0.isEmpty ? nil : $0 }))
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: draft.interface == .t3 ? 230 : 196)
            if let message = model.agentSetupMessages[provider] {
                Text(message).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if draft.installed {
                    Button("Remove hooks…", role: .destructive) { confirmRemoval = true }
                        .buttonStyle(QuietButtonStyle(foreground: Palette.red))
                        .accessibilityIdentifier("settings.\(provider.rawValue).remove")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(OutlineButtonStyle(height: 26))
                    .keyboardShortcut(.cancelAction)
                Button(draft.installed ? "Reinstall hooks" : "Install hooks") {
                    model.agentProfiles[provider] = draft
                    model.onInstallAgent?(provider, draft)
                    dismiss()
                }
                .buttonStyle(FilledButtonStyle(height: 26))
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isComplete || !model.storageReady || model.isDemo)
                .accessibilityIdentifier("settings.\(provider.rawValue).install")
            }
        }
        .padding(22)
        .frame(width: 480)
        .environment(\.colorScheme, .light)
        .confirmationDialog("Remove \(AppIdentity.name) hooks?", isPresented: $confirmRemoval) {
            Button("Remove \(AppIdentity.name) hooks", role: .destructive) {
                model.onRemoveAgent?(provider)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes only \(AppIdentity.name)’s own hooks from this \(provider.displayName) profile. Existing agent settings and retained inventory stay. New content from this profile won’t be collected.")
        }
    }
}
