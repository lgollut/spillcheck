import SwiftUI
import SpillcheckCore

/// What the user has chosen during one run of the setup assistant. The agents' actual state comes
/// from the model, so leaving and reopening setup reflects what really happened.
struct OnboardingFlow {
    enum Scan { case idle, scanning, done }

    var step: OnboardingStep
    var forward = true
    var scan: Scan
    /// Bumped to start, or restart, looking for agents.
    var scanRequest = 0
    /// Agents whose hooks were requested in this run, listed on Connect before their installation starts.
    var connecting: Set<AgentProvider> = []
    /// Agents whose installation has started, so one that is back to "found" failed rather than waits.
    var attempted: Set<AgentProvider> = []
    /// Whether to ask macOS for alert permission when leaving Preferences.
    var wantsAlerts = true

    init(step: OnboardingStep) {
        self.step = step
        scan = step > .chooseAgents ? .done : .idle
    }
}

/// A connection's progress on the Connect step.
enum ConnectPhase: Equatable {
    case queued, installing, waiting, verified, failed, needsRepair
}

/// What the steps show, derived from the model and the user's choices.
@MainActor
struct OnboardingState {
    let model: AppModel
    let flow: OnboardingFlow

    var routes: [AgentRoute] { model.routes }

    /// Agents with an executable on this Mac, whether or not they can be monitored.
    var found: [AgentRoute] { routes.filter { $0.state != .notDetected && $0.state != .notChecked } }

    /// Agents Connect lists: those chosen in this run and any that already have hooks.
    var connectRoutes: [AgentRoute] {
        routes.filter {
            flow.connecting.contains($0.provider) || $0.hooksAdded
                || ($0.state == .unavailable && $0.profile?.installed == true)
        }
    }

    /// With nothing to connect, Connect is passed over and marked as skipped.
    var connectSkipped: Bool { flow.step > .chooseAgents && connectRoutes.isEmpty }

    func phase(_ route: AgentRoute) -> ConnectPhase {
        if route.state == .connected { return .verified }
        if model.agentSetupBusy.contains(route.provider) { return route.hooksAdded ? .waiting : .installing }
        switch route.state {
        case .installedUnverified: return .waiting
        case .unavailable: return .needsRepair
        default: return flow.attempted.contains(route.provider) ? .failed : .queued
        }
    }

    var allVerified: Bool { !connectRoutes.isEmpty && connectRoutes.allSatisfy { $0.state == .connected } }

    /// Hooks are still queued or being added.
    var connectBusy: Bool { connectRoutes.contains { [.queued, .installing].contains(phase($0)) } }

    /// Agents with hooks whose test session hasn't been prepared, one at a time, so each gets a prompt.
    var awaitingCheck: [AgentProvider] {
        guard flow.step == .connect, model.monitoringEnabled, !model.monitoringTransition else { return [] }
        return connectRoutes.filter {
            $0.state == .installedUnverified && !$0.waitingForEvent && !model.agentSetupBusy.contains($0.provider)
        }.map(\.provider)
    }
}

/// The setup assistant's window content: a step rail beside the current step, with Back and the
/// step's main action below.
struct OnboardingView: View {
    let model: AppModel
    /// Called with true while the summary shows, so the menu bar item can be pointed out.
    let pointOutMenuBar: (Bool) -> Void
    let finish: () -> Void
    @State private var flow: OnboardingFlow
    @State private var configuring: AgentProvider?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, start: OnboardingStep, pointOutMenuBar: @escaping (Bool) -> Void, finish: @escaping () -> Void) {
        self.model = model
        self.pointOutMenuBar = pointOutMenuBar
        self.finish = finish
        _flow = State(initialValue: OnboardingFlow(step: start))
    }

    private var state: OnboardingState { OnboardingState(model: model, flow: flow) }

    var body: some View {
        let state = state
        HStack(spacing: 0) {
            OnboardingRail(current: flow.step, skipped: state.connectSkipped ? [.connect] : []) { go($0) }
            Rectangle().fill(Palette.separator).frame(width: 1)
            ZStack(alignment: .top) {
                Palette.background
                WelcomeBackground()
                    .opacity(flow.step == .welcome ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.42), value: flow.step == .welcome)
                WindowDragArea().frame(height: 32)
                VStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        stepContent
                            .id(flow.step)
                            .transition(stepTransition)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    footer(state).padding(.top, 16)
                }
            }
        }
        .frame(width: 960, height: 640)
        .ignoresSafeArea()
        .tint(Palette.link)
        .focusVisible()
        .sheet(item: Binding(get: { configuring.map(ConfigureTarget.init) }, set: { configuring = $0?.provider })) { target in
            ConfigureAgentSheet(model: model, provider: target.provider)
        }
        .task(id: flow.scanRequest) {
            guard flow.scanRequest > 0 else { return }
            await lookForAgents()
        }
        .task(id: state.awaitingCheck) {
            if let provider = state.awaitingCheck.first { model.onVerifyAgent?(provider) }
        }
        .onChange(of: model.agentSetupBusy) { _, busy in flow.attempted.formUnion(busy) }
        .task(id: flow.step) {
            // The callout follows the summary in, once the window is on screen.
            if flow.step == .ready { try? await Task.sleep(for: .milliseconds(450)) }
            if !Task.isCancelled { pointOutMenuBar(flow.step == .ready) }
        }
        .onAppear { if flow.step == .chooseAgents { flow.scanRequest += 1 } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.window")
    }

    @ViewBuilder private var stepContent: some View {
        switch flow.step {
        case .welcome:
            WelcomeStep().padding(.horizontal, 40).padding(.top, 32)
        case .howItWorks: scrolling { HowItWorksStep() }
        case .chooseAgents: scrolling { ChooseAgentsStep(model: model, flow: $flow, configure: { configuring = $0 }) }
        case .connect: scrolling { ConnectStep(model: model, flow: flow) }
        case .preferences: scrolling { PreferencesStep(model: model, flow: $flow) }
        case .ready: scrolling { ReadyStep(model: model, flow: flow) }
        }
    }

    /// Steps fit the window; a long message or hint scrolls rather than pushing the footer away.
    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, 40).padding(.top, 32).padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// The next step slides in from the side it comes from, the previous one gets out of the way.
    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .offset(x: flow.forward ? 24 : -24).combined(with: .opacity),
                           removal: .opacity.animation(.easeOut(duration: 0.1)))
    }

    private func go(_ step: OnboardingStep) {
        guard step != flow.step else { return }
        flow.forward = step > flow.step
        withAnimation(reduceMotion ? nil : Brand.settle(0.38)) { flow.step = step }
        if step == .chooseAgents, flow.scan == .idle { flow.scanRequest += 1 }
    }

    /// Looks for agents once storage is open. The search shows for at least two seconds, so it reads as
    /// one rather than a flash, and until detection finishes.
    private func lookForAgents() async {
        withAnimation(.easeOut(duration: 0.2)) { flow.scan = .scanning }
        let shown = ContinuousClock.now
        while !model.storageReady, !model.storageFailed {
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
        }
        model.onDetectAgents?()
        try? await Task.sleep(until: shown + .seconds(2), clock: .continuous)
        while model.detectingAgents, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : Brand.settle(0.5)) { flow.scan = .done }
    }

    // MARK: Footer

    private func footer(_ state: OnboardingState) -> some View {
        let primary = primaryAction(state)
        return HStack(spacing: 8) {
            if let back = previous(state) {
                Button("Back") { go(back) }
                    .buttonStyle(.onboarding(.secondary))
                    .keyboardShortcut(.cancelAction)
                    .transition(.opacity)
                    .accessibilityIdentifier("setup.back")
            }
            Spacer()
            if flow.step == .connect, !state.allVerified, !state.connectBusy {
                Button("Verify later") { go(.preferences) }
                    .buttonStyle(.onboarding(.ghost))
                    .help("Continue without a verified agent. Until one is verified, nothing is checked.")
                    .transition(.opacity)
                    .accessibilityIdentifier("setup.later")
            }
            Button(primary.label, action: primary.perform)
                .buttonStyle(.onboarding(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!primary.enabled)
                // The label switches with the step instead of cross-fading two labels at once.
                .transaction { $0.animation = nil }
                .accessibilityIdentifier("setup.primary")
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.hairline).frame(height: 1).opacity(flow.step == .welcome ? 0 : 1)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: flow.step)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.connectBusy)
    }

    private func previous(_ state: OnboardingState) -> OnboardingStep? {
        switch flow.step {
        case .welcome: nil
        case .preferences: state.connectRoutes.isEmpty ? .chooseAgents : .connect
        default: OnboardingStep(rawValue: flow.step.rawValue - 1)
        }
    }

    private func primaryAction(_ state: OnboardingState) -> (label: String, enabled: Bool, perform: () -> Void) {
        switch flow.step {
        case .welcome:
            return ("Get started", true, { go(.howItWorks) })
        case .howItWorks:
            return ("Continue", true, { go(.chooseAgents) })
        case .chooseAgents:
            guard flow.scan == .done else { return ("Continue", false, {}) }
            let selection = model.setupSelection
            if !selection.isEmpty {
                let label = selection.count == 1 ? "Connect \(selection[0].name)" : "Connect \(selection.count) agents"
                return (label, model.storageReady, {
                    flow.connecting.formUnion(model.connectSelectedAgents())
                    go(.connect)
                })
            }
            if !state.connectRoutes.isEmpty { return ("Continue", true, { go(.connect) }) }
            return (state.found.isEmpty ? "Set up later" : "Skip for now", true, { go(.preferences) })
        case .connect:
            return ("Continue", state.allVerified, { go(.preferences) })
        case .preferences:
            return ("Continue", true, {
                if flow.wantsAlerts, model.notificationState == .notRequested { model.onRequestNotificationPermission?() }
                go(.ready)
            })
        case .ready:
            return ("Open \(AppIdentity.name)", true, finish)
        }
    }
}

// MARK: - Rail

/// The steps down the sidebar. Completed steps can be revisited; a green line fills as setup advances.
private struct OnboardingRail: View {
    let current: OnboardingStep
    let skipped: Set<OnboardingStep>
    let visit: (OnboardingStep) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Each row is 40 points tall with 4 between, so the line advances 44 points per step.
    private let pitch: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window's traffic lights.
            WindowDragArea().frame(height: windowHeaderHeight)
            HStack(spacing: 10) {
                AppIconImage(size: 44).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppIdentity.name).font(.system(size: 13, weight: .semibold))
                    Text("Setup").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                }
            }
            .padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 28)
            ZStack(alignment: .topLeading) {
                Capsule().fill(Brand.track)
                    .frame(width: 2, height: pitch * CGFloat(OnboardingStep.allCases.count - 1))
                    .offset(x: 20, y: 20)
                Capsule().fill(Brand.green)
                    .frame(width: 2, height: pitch * CGFloat(current.rawValue))
                    .offset(x: 20, y: 20)
                    .animation(reduceMotion ? nil : Brand.settle(0.46), value: current)
                VStack(spacing: 4) {
                    ForEach(OnboardingStep.allCases, id: \.self) { step in
                        RailRow(step: step, current: current, skipped: skipped.contains(step)) { visit(step) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Setup steps")
            Spacer(minLength: 0)
        }
        .frame(width: 248)
        .background(Palette.sidebar)
    }
}

private struct RailRow: View {
    let step: OnboardingStep
    let current: OnboardingStep
    let skipped: Bool
    let visit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Mark: Equatable { case done, current, upcoming, skipped }

    private var mark: Mark {
        if skipped { return .skipped }
        if step == current { return .current }
        return step < current ? .done : .upcoming
    }

    private var visitable: Bool { mark == .done }

    var body: some View {
        Button(action: visit) {
            HStack(spacing: 12) {
                circle
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.title)
                        .font(.system(size: 13, weight: mark == .current ? .semibold : .medium))
                        .foregroundStyle(mark == .current ? Palette.ink : mark == .done ? Palette.ink2 : Palette.tertiary)
                    if mark == .skipped {
                        Text("Skipped").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
        }
        .buttonStyle(RailButtonStyle(visitable: visitable))
        .disabled(!visitable)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: mark)
        .accessibilityLabel("Step \(step.rawValue + 1): \(step.title)")
        .accessibilityValue(mark == .done ? "Completed" : mark == .current ? "Current step" : mark == .skipped ? "Skipped" : "")
    }

    private var circle: some View {
        ZStack {
            switch mark {
            case .done:
                Circle().fill(Brand.green)
                Image(systemName: "checkmark").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(Brand.greenInk)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            case .current:
                Circle().fill(Brand.halo).padding(-4)
                Circle().fill(Palette.surface)
                Circle().strokeBorder(Brand.greenDeep, lineWidth: 2)
                number(Brand.greenDeep)
            case .upcoming:
                Circle().fill(Palette.sidebar)
                Circle().strokeBorder(Brand.futureRing, lineWidth: 1.5)
                number(Palette.quaternary)
            case .skipped:
                Circle().fill(Palette.sidebar)
                Circle().strokeBorder(Brand.futureRing, lineWidth: 1.5)
                Capsule().fill(Palette.quaternary).frame(width: 8, height: 2)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }

    private func number(_ color: Color) -> some View {
        Text("\(step.rawValue + 1)").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(color)
    }
}

private struct RailButtonStyle: ButtonStyle {
    let visitable: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .hoverFill(configuration.isPressed && visitable ? Palette.shade.opacity(0.06) : .clear,
                       hover: visitable ? Palette.shade.opacity(0.04) : .clear, radius: 8)
    }
}
