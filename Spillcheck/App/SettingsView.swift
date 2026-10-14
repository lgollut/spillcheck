import AppKit
import SwiftUI
import SpillcheckCore

struct SettingsNavigation: View {
    let model: AppModel
    let page: SettingsPage

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                item(.general) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 13))
                }
                Text("Agents").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.tertiary)
                    .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(model.routes) { route in
                    item(.agent(route.provider), attention: attention(route)) {
                        AgentGlyph(provider: route.provider).frame(width: 14, height: 14)
                    }
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

    /// Found agents that aren't collecting; agents that were never found have nothing to fix yet.
    private func attention(_ route: AgentRoute) -> Color? {
        guard route.shownInCoverage, !route.collecting else { return nil }
        return route.state == .unavailable || route.state == .unsupported ? Palette.redDot : Palette.amber
    }

    private func item<Icon: View>(_ item: SettingsPage, attention: Color? = nil, @ViewBuilder icon: () -> Icon) -> some View {
        Button { model.route = .settings(item) } label: {
            HStack(spacing: 8) {
                icon()
                    .foregroundStyle(page == item ? Palette.ink : Palette.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(item.title).font(.system(size: 13)).foregroundStyle(Palette.ink)
                Spacer()
                if let attention { StatusDot(color: attention).accessibilityLabel("Needs attention") }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
            .hoverFill(page == item ? Palette.shade.opacity(0.075) : .clear,
                       hover: page == item ? Palette.shade.opacity(0.075) : Palette.shade.opacity(0.04))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(page == item ? [.isButton, .isSelected] : .isButton)
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
                    case .agent(let provider): AgentSettings(model: model, provider: provider).id(provider)
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

struct SettingRow<Control: View>: View {
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
    var onColor = Palette.switchOn
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? onColor : Color(hex: 0xd3d9d6, dark: 0x4a4e4c))
                Circle().fill(.white).shadow(color: Palette.shadow.opacity(0.25), radius: 1, y: 1)
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
                    .disabled(!model.storageReady || model.loginBusy || !model.loginAvailable || model.isDemo)
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
                        Button("Allow notifications") { model.onRequestNotificationPermission?() }
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
        SettingsSection(title: "Setup") {
            SettingRow(title: "Setup assistant",
                       detail: "Walk through how \(AppIdentity.name) works, choose and verify agents, and set alerts again. Agents that are already verified stay connected.") {
                Button("Run setup again") { model.openSetup(at: .welcome) }
                    .buttonStyle(OutlineButtonStyle(height: 28))
                    .disabled(model.isDemo)
                    .accessibilityIdentifier("settings.run-setup")
            }
        }
    }
}


// MARK: - Agents

/// One agent: where its connection stands, then what can be changed.
private struct AgentSettings: View {
    let model: AppModel
    let provider: AgentProvider
    @State private var draft: AgentProfileDraft
    @State private var confirmRemoval = false

    init(model: AppModel, provider: AgentProvider) {
        self.model = model
        self.provider = provider
        _draft = State(initialValue: model.agentProfiles[provider] ?? AgentProfileDraft(provider: provider))
    }

    private var name: String { provider.displayName }
    private var route: AgentRoute {
        model.routes.first { $0.provider == provider }
            ?? AgentRoute(provider: provider, profile: nil, state: .notChecked, waitingForEvent: false)
    }
    private var saved: AgentProfileDraft? { model.agentProfiles[provider] }
    private var installed: Bool { saved?.installed == true }
    private var edited: Bool { !draft.sameSetup(as: saved) }
    private var busy: Bool { model.agentSetupBusy.contains(provider) }
    private var disabled: Bool { !model.storageReady || model.isDemo || busy }

    /// Only what the status doesn't already say; the steps explain a pending test.
    private var detail: String? {
        if route.waitingForEvent { return nil }
        if let message = model.agentSetupMessages[provider] { return message }
        return switch route.state {
        case .notDetected, .notChecked: "Not found in the usual locations. Choose its executable below."
        case .unsupported: saved?.unsupportedMessage ?? "This collection route has not been established."
        case .unavailable: "\(AppIdentity.name)’s hooks need repair."
        case .detected, .installedUnverified, .connected: nil
        }
    }

    private var action: (label: String, perform: () -> Void)? {
        switch route.state {
        case .installedUnverified where !route.waitingForEvent:
            ("Test connection", { model.onVerifyAgent?(provider) })
        case .detected:
            if let saved, saved.isComplete { ("Connect", { install(saved) }) } else { nil }
        case .unavailable:
            ("Repair", { model.onRepairAgent?(provider) })
        case .notDetected, .notChecked, .unsupported, .connected, .installedUnverified:
            nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            if route.waitingForEvent {
                SettingsSection(title: "Test the connection") {
                    DeliveryCheckSteps(model: model, route: route).padding(16)
                }
            }
            SettingsSection(title: "Setup", trailing: AnyView(detectButton)) {
                AgentSetupFields(draft: $draft, installed: installed)
            }
            VStack(alignment: .leading, spacing: 10) {
                SettingsSection(title: "Collection") {
                    AgentCollectionFields(draft: $draft, locked: saved?.requiresDesktopDeliveryRoute == true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Coverage shows what \(name) collects and its known limits.")
                        .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Open Coverage") { model.route = .coverage }
                        .buttonStyle(QuietButtonStyle(foreground: Palette.link, height: 24))
                        .fixedSize()
                        .accessibilityIdentifier("settings.open-coverage")
                }
                .padding(.horizontal, 2)
            }
            if edited { pendingChanges }
            if installed {
                SettingsSection(title: "Hooks") {
                    SettingRow(title: "Remove hooks",
                               detail: "Stops checking this profile. Only \(AppIdentity.name)’s own hooks are removed.") {
                        Button("Remove") { confirmRemoval = true }
                            .buttonStyle(QuietButtonStyle(foreground: Palette.red, horizontalPadding: 10))
                            .fixedSize()
                            .disabled(disabled)
                            .accessibilityIdentifier("settings.\(provider.rawValue).remove")
                    }
                }
            }
        }
        // A saved change, such as a detection or a failed install, replaces the draft unless it was edited.
        .onChange(of: saved) { old, new in
            if draft.sameSetup(as: old) { draft = new ?? AgentProfileDraft(provider: provider) }
        }
        .confirmationDialog("Remove \(AppIdentity.name)’s hooks from \(name)?", isPresented: $confirmRemoval) {
            Button("Remove hooks", role: .destructive) { model.onRemoveAgent?(provider) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(name)’s other settings and your saved results stay. New sessions from this profile won’t be checked.")
        }
    }

    private var header: some View {
        let status = route.status
        return HStack(alignment: .top, spacing: 14) {
            AgentGlyph(provider: provider)
                .frame(width: 20, height: 20)
                .foregroundStyle(Palette.ink)
                .frame(width: 40, height: 40)
                .background(Palette.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).font(.system(size: 15, weight: .semibold))
                    if let version = saved?.version, !version.isEmpty {
                        Text(version).font(Palette.mono).foregroundStyle(Palette.tertiary)
                    }
                }
                HStack(spacing: 6) {
                    StatusDot(color: status.dot, outlined: status.outlined)
                    Text(status.text)
                    if busy { ProgressView().controlSize(.small) }
                }
                .font(.system(size: 12)).foregroundStyle(status.color)
                .frame(minHeight: 16)
                if let detail {
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(Palette.secondary).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // While the setup has unsaved edits, the next step is applying them.
            if let action, !edited {
                Button(action.label, action: action.perform)
                    .buttonStyle(FilledButtonStyle(height: 28))
                    .fixedSize()
                    .disabled(disabled)
                    .accessibilityIdentifier("settings.\(provider.rawValue).action")
            }
        }
        .padding(16)
        .card()
    }

    private var pendingChanges: some View {
        HStack(spacing: 12) {
            Text(installed ? "Applying updates \(AppIdentity.name)’s hooks. You may be asked to test again."
                           : "Connecting adds \(AppIdentity.name)’s hooks to this profile, then asks for a short test.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Discard") { draft = saved ?? AgentProfileDraft(provider: provider) }
                .buttonStyle(OutlineButtonStyle(height: 28))
                .fixedSize()
            Button(installed ? "Apply" : "Connect") { install(draft) }
                .buttonStyle(FilledButtonStyle(height: 28))
                .fixedSize()
                .disabled(disabled || !draft.canInstall)
                .accessibilityIdentifier("settings.\(provider.rawValue).install")
        }
        .padding(12)
        .background(Palette.quiet, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private func install(_ profile: AgentProfileDraft) {
        model.agentProfiles[provider] = profile
        model.onInstallAgent?(provider, profile)
    }
}

extension AgentProfileDraft {
    /// Whether both choose the same executable, profile folder, and collection routes.
    func sameSetup(as other: AgentProfileDraft?) -> Bool {
        let other = other ?? AgentProfileDraft(provider: provider)
        return executablePath == other.executablePath && homePath == other.homePath && authorizedHosts == other.authorizedHosts
    }

    /// Installing reads the executable's version itself, so a newly chosen executable needs none yet.
    var canInstall: Bool {
        !executablePath.isEmpty && !homePath.isEmpty && !authorizedHosts.isEmpty && hasValidHostAuthorization
    }
}

/// The executable and profile folder, as rows of a settings card.
struct AgentSetupFields: View {
    @Binding var draft: AgentProfileDraft
    /// Installed hooks belong to their profile folder, so choosing another one needs them removed first.
    let installed: Bool

    var body: some View {
        let name = draft.provider.displayName
        let command = draft.provider == .codex ? "codex" : "claude"
        PathRow(title: "Executable", detail: "The \(name) command \(AppIdentity.name) checks and uses for the test.",
                placeholder: "~/.local/bin/\(command)", folder: false, path: $draft.executablePath)
            .accessibilityIdentifier("settings.\(draft.provider.rawValue).executable")
        PathRow(title: "Profile folder",
                detail: installed ? "Where \(name) keeps its sessions and settings. Remove the hooks to choose another folder."
                                  : "Where \(name) keeps its sessions and settings.",
                placeholder: draft.provider == .codex ? "~/.codex" : "~/.claude", folder: true, path: $draft.homePath,
                locked: installed, divider: true)
            .accessibilityIdentifier("settings.\(draft.provider.rawValue).home")
    }
}

/// Which apps' sessions are collected from the profile.
struct AgentCollectionFields: View {
    @Binding var draft: AgentProfileDraft
    /// Hooks registered for the desktop app need its support on; turning it off needs them removed first.
    let locked: Bool

    private var desktopDetail: String {
        let limits = draft.provider == .claudeCode
            ? "Partial support. Reads saved local Code conversations from the Claude app. Side questions, Chat, Cowork and remote Code aren’t included."
            : "Partial support. Reads saved local conversations from the Codex app. Side chats and encrypted subagent input aren’t collected."
        return locked ? limits + " Remove the hooks to turn this off." : limits
    }

    var body: some View {
        let shared = draft.authorizedHosts.contains(.standaloneCLI) || draft.authorizedHosts.contains(.t3)
        SettingRow(title: "Command line and T3",
                   detail: "Both use this profile, so their sessions can’t be told apart.") {
            Text(shared ? "Included" : "Not included").font(.system(size: 12)).foregroundStyle(Palette.tertiary).fixedSize()
        }
        SettingRow(title: "Desktop app", detail: desktopDetail, divider: true) {
            Toggle("Desktop app", isOn: Binding(
                get: { draft.authorizedHosts.contains(.desktopCode) },
                set: { enabled in
                    if enabled { draft.authorizedHosts.insert(.desktopCode) }
                    else { draft.authorizedHosts.remove(.desktopCode) }
                }))
                .toggleStyle(DesignSwitchStyle())
                .labelsHidden()
                .disabled(locked)
                .accessibilityIdentifier("settings.\(draft.provider.rawValue).desktop-partial")
        }
    }
}

/// A path with its explanation, edited in place or chosen in a file panel.
private struct PathRow: View {
    let title: String
    let detail: String
    let placeholder: String
    let folder: Bool
    @Binding var path: String
    var locked = false
    var divider = false

    /// Paths under the home folder read as ~/…; typed ones are stored in full, as installation requires.
    private var shown: Binding<String> {
        Binding(get: { path.isEmpty ? "" : AgentConfigurationLine.abbreviated(path) },
                set: { path = $0.isEmpty ? "" : NSString(string: $0).expandingTildeInPath })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField(title, text: shown, prompt: Text(placeholder))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .labelsHidden()
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Palette.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Button("Choose", action: choose)
                    .buttonStyle(OutlineButtonStyle(height: 28))
                    .fixedSize()
            }
            .disabled(locked)
            .padding(.top, 8)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { if divider { Rectangle().fill(Palette.hairline).frame(height: 1) } }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folder
        panel.canChooseDirectories = folder
        panel.allowsMultipleSelection = false
        // Agent profiles are hidden folders such as ~/.codex.
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

struct ConfigureTarget: Identifiable {
    let provider: AgentProvider
    var id: AgentProvider { provider }
}

/// The setup assistant's way to choose an agent's executable and profile; Settings edits them in place.
struct ConfigureAgentSheet: View {
    let model: AppModel
    let provider: AgentProvider
    @State private var draft: AgentProfileDraft
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, provider: AgentProvider) {
        self.model = model
        self.provider = provider
        _draft = State(initialValue: model.agentProfiles[provider] ?? AgentProfileDraft(provider: provider))
    }

    var body: some View {
        let saved = model.agentProfiles[provider]
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up \(provider.displayName)").font(.system(size: 15, weight: .semibold))
                Text("Choose the \(provider.displayName) whose sessions \(AppIdentity.name) should check.")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) { AgentSetupFields(draft: $draft, installed: saved?.installed == true) }.card()
            VStack(spacing: 0) {
                AgentCollectionFields(draft: $draft, locked: saved?.requiresDesktopDeliveryRoute == true)
            }
            .card()
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(OutlineButtonStyle(height: 28))
                    .keyboardShortcut(.cancelAction)
                Button(saved?.installed == true ? "Apply" : "Connect") {
                    model.agentProfiles[provider] = draft
                    model.onInstallAgent?(provider, draft)
                    dismiss()
                }
                .buttonStyle(FilledButtonStyle(height: 28))
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canInstall || !model.storageReady || model.isDemo)
                .accessibilityIdentifier("settings.\(provider.rawValue).install")
            }
        }
        .padding(22)
        .frame(width: 520)
        .focusVisible()
    }
}
