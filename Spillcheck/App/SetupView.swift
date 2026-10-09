import SwiftUI
import SpillcheckCore

/// Guided setup fills the window until an agent is verified. Each step reflects actual setup state, so
/// leaving and coming back resumes where the user still has something to do.
struct SetupView: View {
    let model: AppModel
    @State private var configuring: AgentProvider?
    @FocusState private var primaryFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                Group {
                    switch model.setupStep {
                    case .welcome: SetupWelcome()
                    case .connect: SetupConnect(model: model, configure: { configuring = $0 })
                    case .confirm: SetupConfirm(model: model)
                    case .ready: SetupReady(model: model)
                    }
                }
                .id(model.setupStep)
                .transition(.opacity)
                .frame(maxWidth: 600, alignment: .leading)
                .padding(.horizontal, 40).padding(.top, 36).padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            footer
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.setupStep)
        // Keyboard focus starts on each step's main action rather than the first control in the header.
        .task(id: model.setupStep) { primaryFocused = true }
        .background(Palette.background)
        .sheet(item: Binding(get: { configuring.map(ConfigureTarget.init) }, set: { configuring = $0?.provider })) { target in
            ConfigureAgentSheet(model: model, provider: target.provider)
        }
        .accessibilityIdentifier("setup.window")
    }

    private var header: some View {
        HStack(spacing: 0) {
            // Room for the window's traffic lights, mirrored so the stepper stays centered.
            Color.clear.frame(width: 78, height: 12)
            Spacer(minLength: 0)
            SetupStepper(current: model.setupStep)
            Spacer(minLength: 0)
            Color.clear.frame(width: 78, height: 12)
        }
        .padding(.horizontal, 16)
        .frame(height: windowHeaderHeight)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    /// Leaving setup sits after the step's content, so keyboard focus never starts on it.
    private var footer: some View {
        HStack(spacing: 12) {
            if let back = previous {
                Button { model.setupStep = back } label: {
                    Label("Back", systemImage: "arrow.left").labelStyle(TightLabelStyle())
                }
                .buttonStyle(QuietButtonStyle(foreground: Palette.ink2, horizontalPadding: 10))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("setup.back")
            }
            if model.setupStep != .ready {
                Button("Set up later") { model.closeSetup() }
                    .buttonStyle(QuietButtonStyle(foreground: Palette.secondary, horizontalPadding: 10))
                    .help("Leave setup. Until an agent is verified, nothing is checked.")
                    .accessibilityIdentifier("setup.later")
            }
            Spacer()
            if let note = primary.note {
                HStack(spacing: 7) {
                    if primary.waiting { ProgressView().controlSize(.small) }
                    Text(note)
                }
                .font(.system(size: 12.5)).foregroundStyle(Palette.tertiary)
            }
            Button(primary.label, action: primary.perform)
                .buttonStyle(FilledButtonStyle())
                .keyboardShortcut(.defaultAction)
                .focused($primaryFocused)
                .disabled(!primary.enabled)
                .accessibilityIdentifier("setup.primary")
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private var previous: SetupStep? {
        switch model.setupStep {
        case .welcome: nil
        case .connect: .welcome
        case .confirm: .connect
        case .ready: .confirm
        }
    }

    private var primary: (label: String, enabled: Bool, waiting: Bool, note: String?, perform: () -> Void) {
        let routes = model.routes
        switch model.setupStep {
        case .welcome:
            return ("Get started", true, false, nil, { model.setupStep = .connect })
        case .connect:
            let selected = model.setupSelection.count
            if selected > 0 {
                return (selected == 1 ? "Connect 1 agent" : "Connect \(selected) agents",
                        model.storageReady && model.agentSetupBusy.isEmpty, false, nil, { model.connectSelectedAgents() })
            }
            let added = routes.contains(where: \.hooksAdded)
            return ("Continue", added, false, added ? nil : "Choose at least one agent", { model.setupStep = .confirm })
        case .confirm:
            let waiting = routes.filter { $0.state == .installedUnverified }
            if model.monitoringProven { return ("Continue", true, false, nil, { model.setupStep = .ready }) }
            let names = waiting.map(\.name).joined(separator: " and ")
            return ("Continue", false, !waiting.isEmpty, waiting.isEmpty ? nil : "Waiting for \(names)", {})
        case .ready:
            return ("Open \(AppIdentity.name)", true, false, nil, { model.closeSetup() })
        }
    }
}

private struct SetupStepper: View {
    let current: SetupStep

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SetupStep.allCases, id: \.self) { step in
                if step != .welcome {
                    Rectangle()
                        .fill(step.rawValue <= current.rawValue ? Palette.accent.opacity(0.45) : Palette.separator)
                        .frame(width: 24, height: 1.5)
                }
                HStack(spacing: 6) {
                    ZStack {
                        if step.rawValue <= current.rawValue {
                            Circle().fill(Palette.accent)
                        } else {
                            Circle().strokeBorder(Palette.ring, lineWidth: 1.5)
                        }
                        if step.rawValue < current.rawValue {
                            Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Palette.onAccent)
                        } else {
                            Text("\(step.rawValue + 1)").font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(step == current ? Palette.onAccent : Palette.tertiary)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(step.title)
                        .font(.system(size: 12.5, weight: step == current ? .semibold : .regular))
                        .foregroundStyle(step == current ? Palette.ink : Palette.tertiary)
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(SetupStep.allCases.count): \(current.title)")
    }
}

private struct SetupHeading: View {
    let title: String
    let lead: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 24, weight: .semibold)).tracking(-0.3)
                .accessibilityAddTraits(.isHeader)
            Text(lead).font(.system(size: 13.5)).foregroundStyle(Palette.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 24)
    }
}

// MARK: - Welcome

private struct SetupWelcome: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 64, height: 64)
                .padding(.leading, -4).padding(.bottom, 14)
                .accessibilityHidden(true)
            SetupHeading(title: "Set up \(AppIdentity.name)",
                         lead: "\(AppIdentity.name) finds secrets that appear in your Codex and Claude Code sessions, including prompts, replies, and tool output. It keeps an encrypted list on this Mac.")
            VStack(alignment: .leading, spacing: 18) {
                feature("puzzlepiece.extension", "Adds hooks to the agents you choose",
                        "\(AppIdentity.name) adds its own hooks to each agent profile. Your other agent settings stay as they are, and you can remove the hooks at any time.")
                feature("checkmark.bubble", "Confirms with one test session",
                        "A short test prompt proves that events reach \(AppIdentity.name). The agent replies once and does nothing else.")
                feature("lock.shield", "Stays on this Mac",
                        "Analysis runs locally. Found values stay encrypted and masked until you reveal them with Touch ID or your password.")
            }
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.accent)
                .frame(width: 34, height: 34)
                .background(Palette.selection, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Palette.secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Connect

private struct SetupConnect: View {
    let model: AppModel
    let configure: (AgentProvider) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupHeading(title: "Choose agents to monitor",
                         lead: "\(AppIdentity.name) looked in the usual install locations. Choose the agents whose sessions you want checked.")
            VStack(spacing: 0) {
                ForEach(Array(model.routes.enumerated()), id: \.element.id) { index, route in
                    SetupAgentChoice(model: model, route: route, configure: configure)
                        .overlay(alignment: .top) { if index > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) } }
                }
            }
            .card()
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(AppIdentity.name) only adds and removes its own hooks. Codex asks you to trust them when it next starts; the next step shows what to choose.")
                    .font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if model.detectingAgents { ProgressView().controlSize(.small) }
                    Button("Detect again") { model.onDetectAgents?() }
                        .buttonStyle(QuietButtonStyle(foreground: Palette.link, height: 24))
                        .disabled(!model.storageReady || model.detectingAgents)
                }
                .fixedSize()
            }
            .padding(.top, 10).padding(.horizontal, 2)
        }
    }
}

private struct SetupAgentChoice: View {
    let model: AppModel
    let route: AgentRoute
    let configure: (AgentProvider) -> Void

    private var selected: Bool { route.connectable && !model.setupDeselected.contains(route.provider) }
    private var busy: Bool { model.agentSetupBusy.contains(route.provider) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            leading.frame(width: 18, height: 32)
            // Clicking the description also ticks the agent; the checkbox handles its own clicks.
            HStack(alignment: .top, spacing: 12) {
                AgentMonogram(route: route)
                VStack(alignment: .leading, spacing: 4) {
                    Text(route.name).font(.system(size: 13.5, weight: .semibold))
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(detailColor).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let configuration = AgentConfigurationLine(route: route).text {
                        Text(configuration).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.quaternary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture { if route.connectable { toggle() } }
            trailing
        }
        .padding(16)
        .accessibilityElement(children: .contain)
    }

    private func toggle() {
        if selected { model.setupDeselected.insert(route.provider) } else { model.setupDeselected.remove(route.provider) }
    }

    @ViewBuilder private var leading: some View {
        if route.connectable {
            Toggle(isOn: Binding(get: { selected }, set: { _ in toggle() })) { Text("Monitor \(route.name)") }
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityIdentifier("setup.\(route.provider.rawValue).choose")
        } else if route.hooksAdded {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(Palette.green)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "minus.circle").font(.system(size: 15)).foregroundStyle(Palette.faint)
                .accessibilityHidden(true)
        }
    }

    private var detail: String {
        switch route.state {
        case .detected where route.connectable: "Found on this Mac. \(AppIdentity.name) adds hooks to this profile."
        case .detected: "Found, but the profile isn’t complete. Choose its profile folder."
        case .installedUnverified: "Hooks added. The next step confirms that events arrive."
        case .connected: "Connected. Events from this profile reach \(AppIdentity.name)."
        case .unsupported: model.agentSetupMessages[route.provider] ?? route.profile?.unsupportedMessage ?? "This collection route has not been established."
        case .unavailable: model.agentSetupMessages[route.provider] ?? "\(AppIdentity.name)’s hooks need repair."
        case .notDetected, .notChecked: "Not found in ~/.local/bin, /opt/homebrew/bin, or /usr/local/bin."
        }
    }

    private var detailColor: Color {
        route.state == .unsupported || route.state == .unavailable ? Palette.ink2 : Palette.secondary
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 6) {
            if busy { ProgressView().controlSize(.small) }
            switch route.state {
            case .unsupported:
                Button("Configure…") { configure(route.provider) }.buttonStyle(OutlineButtonStyle(height: 28))
            case .unavailable:
                Button("Repair") { model.onRepairAgent?(route.provider) }.buttonStyle(OutlineButtonStyle(height: 28))
            case .notDetected, .notChecked:
                Button("Locate…") { configure(route.provider) }.buttonStyle(OutlineButtonStyle(height: 28))
            case .detected where !route.connectable:
                Button("Configure…") { configure(route.provider) }.buttonStyle(OutlineButtonStyle(height: 28))
            case .detected, .installedUnverified, .connected:
                EmptyView()
            }
        }
        .disabled(!model.storageReady || busy)
    }
}

// MARK: - Confirm

private struct SetupConfirm: View {
    let model: AppModel

    /// Agents with hooks, plus any chosen in the previous step, in a stable order.
    private var routes: [AgentRoute] {
        model.routes.filter {
            $0.hooksAdded || $0.state == .unavailable || model.agentSetupBusy.contains($0.provider)
                || model.setupConnecting.contains($0.provider)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupHeading(title: "Run one test session",
                         lead: "Start a new session for each agent below. It sends a single test prompt, and \(AppIdentity.name) confirms the connection as soon as it arrives.")
            if !model.monitoringEnabled {
                PausedNotice(model: model).padding(.bottom, 16)
            }
            VStack(spacing: 14) {
                ForEach(routes) { route in
                    DeliveryCheckCard(model: model, route: route)
                }
                if routes.isEmpty {
                    Text("No agent has hooks yet. Go back and choose an agent to connect.")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .card()
                }
            }
        }
    }
}

private struct PausedNotice: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "pause.circle.fill").font(.system(size: 15)).foregroundStyle(Palette.amberText)
                .accessibilityHidden(true)
            Text("Monitoring is paused, so the test prompt can’t be received.")
                .font(.system(size: 12.5)).foregroundStyle(Palette.amberSoftText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Resume monitoring") { model.toggleMonitoring() }
                .buttonStyle(OutlineButtonStyle(height: 28))
                .disabled(!model.storageReady || model.monitoringTransition || model.stopped)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Palette.amberSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// One agent's delivery check in guided setup: adding hooks, waiting for the test prompt, or connected.
private struct DeliveryCheckCard: View {
    let model: AppModel
    let route: AgentRoute

    private var busy: Bool { model.agentSetupBusy.contains(route.provider) }

    var body: some View {
        let status = route.status
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AgentMonogram(route: route)
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.name).font(.system(size: 13.5, weight: .semibold))
                    HStack(spacing: 6) {
                        StatusDot(color: status.dot, outlined: status.outlined)
                        Text(busy && !route.waitingForEvent ? "Adding hooks…" : status.text)
                    }
                    .font(.system(size: 12)).foregroundStyle(status.color)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            content
        }
        .padding(16)
        .card()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var content: some View {
        if route.waitingForEvent {
            DeliveryCheckSteps(model: model, route: route)
        } else if route.state == .connected {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green)
                Text("Test prompt received. You can close the test session.")
            }
            .font(.system(size: 12.5)).foregroundStyle(Palette.ink2)
        } else if route.state == .unavailable {
            HStack(alignment: .top, spacing: 12) {
                Text(model.agentSetupMessages[route.provider] ?? "\(AppIdentity.name)’s hooks need repair.")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Repair") { model.onRepairAgent?(route.provider) }
                    .buttonStyle(OutlineButtonStyle(height: 28)).disabled(busy || !model.storageReady)
            }
        } else if route.state == .detected, !busy, let profile = route.profile {
            HStack(alignment: .top, spacing: 12) {
                Text(model.agentSetupMessages[route.provider] ?? "Hooks weren’t added.")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Try again") { model.onInstallAgent?(route.provider, profile) }
                    .buttonStyle(OutlineButtonStyle(height: 28)).disabled(!model.storageReady)
            }
        } else if route.state == .installedUnverified, !busy {
            HStack(alignment: .top, spacing: 12) {
                Text("Hooks are added. Start the test to get the command for a test session.")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Start test") { model.onVerifyAgent?(route.provider) }
                    .buttonStyle(FilledButtonStyle(height: 28))
                    .disabled(!model.storageReady || !model.monitoringEnabled)
                    .accessibilityIdentifier("setup.\(route.provider.rawValue).start-test")
            }
        }
    }
}

/// The three things the user does for a delivery check. Shared by guided setup and Settings.
struct DeliveryCheckSteps: View {
    let model: AppModel
    let route: AgentRoute
    @State private var slow = false
    @State private var showPrompt = false

    private var command: SetupCheckCommand? { model.setupCommand(for: route.provider) }
    private var viaT3: Bool { route.profile?.interface == .t3 }
    private var agent: String { route.provider.displayName }

    var body: some View {
        if let command {
            VStack(alignment: .leading, spacing: 14) {
                if viaT3 {
                    step(1, "Send the test prompt from T3",
                         "In T3, start a new \(agent) conversation and send this prompt.") {
                        promptBox(command.prompt)
                    }
                } else {
                    step(1, "Start a test session",
                         "This command opens a new \(agent) session that sends the test prompt.") {
                        VStack(alignment: .leading, spacing: 8) {
                            CommandBox(text: command.line)
                                .accessibilityIdentifier("setup.\(route.provider.rawValue).command")
                            HStack(spacing: 8) {
                                Button { model.onOpenSetupTerminal?(route.provider) } label: {
                                    Label("Open in Terminal", systemImage: "terminal").labelStyle(TightLabelStyle())
                                }
                                .buttonStyle(FilledButtonStyle(height: 28))
                                .disabled(model.isDemo)
                                .accessibilityIdentifier("setup.\(route.provider.rawValue).open-terminal")
                                CopyButton(text: command.line, label: "Copy command")
                                    .accessibilityIdentifier("setup.\(route.provider.rawValue).copy")
                                Spacer(minLength: 0)
                                Button(showPrompt ? "Hide prompt" : "Use another session…") { showPrompt.toggle() }
                                    .buttonStyle(QuietButtonStyle(foreground: Palette.link, height: 24))
                            }
                            if showPrompt {
                                Text("Paste this prompt into a new \(agent) session that uses \(route.profile.map { AgentConfigurationLine.abbreviated($0.homePath) } ?? "this profile"):")
                                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                promptBox(command.prompt)
                            }
                        }
                    }
                }
                if route.provider == .codex {
                    step(2, "Trust \(AppIdentity.name)’s hooks",
                         "Codex shows “Hooks need review” for the \(CodexHookConfiguration.events.count) hooks \(AppIdentity.name) added. Choose **Trust all and continue**. Each hook passes session events to \(AppIdentity.name) on this Mac.") {
                        EmptyView()
                    }
                } else {
                    step(2, "Approve any startup prompts",
                         "If Claude Code asks you to review hooks or to trust the folder, approve them. The hooks pass session events to \(AppIdentity.name) on this Mac.") {
                        EmptyView()
                    }
                }
                step(3, "Wait for the reply",
                     "The agent replies “Connected” and does nothing else. This page updates as soon as the prompt arrives.") {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the test prompt…").foregroundStyle(Palette.amberText)
                    }
                    .font(.system(size: 12))
                }
                if slow {
                    Text(route.provider == .codex
                         ? "Nothing yet? If you chose “Continue without trusting”, quit Codex and run the command again. The prompt must be sent from a new session that uses this profile."
                         : "Nothing yet? Make sure the prompt was sent from a new session that uses this profile, then run the command again.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.quiet, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .task(id: command.prompt) {
                slow = false
                try? await Task.sleep(for: .seconds(45))
                if !Task.isCancelled { slow = true }
            }
        }
    }

    private func step<Extra: View>(_ number: Int, _ title: String, _ detail: LocalizedStringKey,
                                   @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink2)
                .frame(width: 20, height: 20)
                .background(Palette.chip, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Palette.secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                extra()
            }
        }
    }

    private func promptBox(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CommandBox(text: prompt)
                .accessibilityIdentifier("settings.\(route.provider.rawValue).verification-prompt")
            CopyButton(text: prompt, label: "Copy prompt")
        }
    }
}

struct CommandBox: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .lineSpacing(2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct CopyButton: View {
    let text: String
    var label = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(TightLabelStyle())
        }
        .buttonStyle(OutlineButtonStyle(height: 28))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }
}

// MARK: - Ready

private struct SetupReady: View {
    let model: AppModel

    private var connected: [AgentRoute] { model.routes.filter(\.collecting) }
    private var remaining: [AgentRoute] { model.routes.filter { $0.shownInCoverage && !$0.collecting } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "checkmark")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(Palette.onAccent)
                .frame(width: 52, height: 52)
                .background(Palette.green, in: Circle())
                .padding(.bottom, 16)
                .accessibilityHidden(true)
            SetupHeading(title: connected.isEmpty ? "Almost ready" : "Monitoring is on",
                         lead: lead)
            if !remaining.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(remaining) { route in
                        HStack(alignment: .top, spacing: 8) {
                            StatusDot(color: route.status.dot, outlined: route.status.outlined).padding(.top, 5)
                            Text("\(route.name) isn’t monitored yet: \(route.status.text.lowercased()). You can connect it later in Settings › Agents.")
                                .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            Text("Options").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.tertiary)
                .padding(.horizontal, 2).padding(.bottom, 10)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                SettingRow(title: "Alert me about new secrets", detail: notificationDetail) { notificationControl }
                SettingRow(title: "Open at login",
                           detail: "Monitoring runs only while \(AppIdentity.name) is open. Closing the window keeps it running in the menu bar.",
                           divider: true) {
                    Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.onLaunchAtLoginRequested?($0) }))
                        .toggleStyle(DesignSwitchStyle())
                        .labelsHidden()
                        .disabled(!model.storageReady || model.loginBusy || model.isDemo)
                }
            }
            .card()
        }
    }

    private var lead: String {
        guard !connected.isEmpty else {
            return "No agent is verified yet. Until one is, nothing is checked."
        }
        let names = connected.map(\.name).joined(separator: " and ")
        return "\(AppIdentity.name) is reading the last 7 days of \(names) history, then checks new sessions as they happen. Results appear in the main window and the menu bar."
    }

    private var notificationDetail: String {
        switch model.notificationState {
        case .allowed: "A masked notification for each strong new value. Values never appear in notifications."
        case .denied: "Notifications are off in System Settings. Detections still appear in the app and the menu bar."
        case .notRequested, .unavailable: "A masked notification for each strong new value. Values never appear in notifications."
        }
    }

    @ViewBuilder private var notificationControl: some View {
        switch model.notificationState {
        case .notRequested:
            Button("Allow notifications…") { model.onRequestNotificationPermission?() }
                .buttonStyle(OutlineButtonStyle(height: 28))
                .disabled(!model.storageReady || model.notificationBusy || model.isDemo)
        case .denied:
            Button("Open System Settings") { model.onOpenNotificationSettings?() }
                .buttonStyle(OutlineButtonStyle(height: 28))
        case .allowed:
            Label("Allowed", systemImage: "checkmark").labelStyle(TightLabelStyle())
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
        case .unavailable:
            Text("Unavailable").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
        }
    }
}

// MARK: - Shared agent presentation

struct AgentMonogram: View {
    let route: AgentRoute

    var body: some View {
        Text(route.monogram)
            .font(.system(size: 11, weight: .bold)).tracking(0.2).foregroundStyle(Palette.ink2)
            .frame(width: 32, height: 32)
            .background(Color(hex: 0xeceeed, dark: 0x292c2a), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The selected executable, version, and profile on one line, or nil before anything was found.
struct AgentConfigurationLine {
    let route: AgentRoute

    var text: String? {
        guard let profile = route.profile, !profile.executablePath.isEmpty else { return nil }
        let command = route.provider == .codex ? "codex" : "claude"
        return [profile.version.isEmpty ? command : "\(command) \(profile.version)", Self.abbreviated(profile.executablePath),
                profile.homePath.isEmpty ? nil : "profile \(Self.abbreviated(profile.homePath))"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Paths under the home folder read as ~/…, which keeps the line short enough not to wrap mid-path.
    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
