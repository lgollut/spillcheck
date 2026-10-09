import SwiftUI
import SpillcheckCore

struct StepHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 22, weight: .semibold)).tracking(-0.33)
                .contentTransition(.opacity)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.system(size: 13.5)).foregroundStyle(Palette.secondary).lineSpacing(3.5)
                .contentTransition(.opacity)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 540, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: title)
    }
}

// MARK: - Welcome

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                PulseRings(color: Brand.pulse, diameter: 112)
                AppIconImage(size: 140)
            }
            .frame(width: 140, height: 140)
            .padding(.bottom, 26)
            .rise(0, distance: 10)
            Text("Welcome to \(AppIdentity.name)")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.greenText)
                .rise(1)
            Text("Know when a secret slips into an agent session")
                .font(.system(size: 30, weight: .semibold)).tracking(-0.6)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 470)
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
                .rise(2)
            Text("\(AppIdentity.name) watches your coding agents on this Mac and tells you when an API key, token, or password shows up, so you can deal with it early.")
                .font(.system(size: 14)).foregroundStyle(Palette.secondary).lineSpacing(4)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .padding(.top, 14)
                .rise(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 44)
    }
}

// MARK: - How it works

struct HowItWorksStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(title: "How \(AppIdentity.name) works",
                       detail: "Three things happen in the background while you work with your agents.")
            HStack(alignment: .top, spacing: 12) {
                FeatureCard(number: 1, title: "Watches agent sessions",
                            detail: "Prompts, replies, and tool output from Codex and Claude Code, as they happen.") {
                    SessionArt()
                }
                .rise(0)
                FeatureCard(number: 2, title: "Flags possible secrets",
                            detail: "API keys, tokens, and passwords, even when the agent never repeats them.") {
                    FlagArt()
                }
                .rise(1)
                FeatureCard(number: 3, title: "Leaves the call to you",
                            detail: "Review each appearance and record when you’ve rotated a credential.") {
                    ReviewArt()
                }
                .rise(2)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 24)
            HStack(spacing: 12) {
                CheckBadge(size: 22)
                Text("\(Text("Your work stays on your Mac.").fontWeight(.semibold)) \(AppIdentity.name) analyzes everything locally and never sends sessions, secrets, or results anywhere.")
                    .font(.system(size: 12.5)).foregroundStyle(Brand.calloutText).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Brand.calloutFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.calloutRing, lineWidth: 1))
            .accessibilityElement(children: .combine)
            .padding(.top, 16)
            .rise(3)
        }
    }
}

private struct FeatureCard<Art: View>: View {
    let number: Int
    let title: String
    let detail: String
    @ViewBuilder let art: Art

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                CardArtBackground()
                art
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .clipped()
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(number)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Brand.greenText)
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Palette.secondary).lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.cardRing, lineWidth: 1))
    }
}

/// A prompt, a reply, and a command whose output is about to include a secret.
private struct SessionArt: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer(minLength: 0)
                UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: 9, bottomTrailingRadius: 3,
                                       topTrailingRadius: 9, style: .continuous)
                    .fill(Brand.green)
                    .frame(width: 96, height: 26)
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.75)).frame(width: 47, height: 5).padding(.leading, 9)
                    }
            }
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(Brand.bubbleBar).frame(width: 99, height: 5)
                Capsule().fill(Brand.bubbleBar).frame(width: 66, height: 5)
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
            .frame(width: 128, alignment: .leading)
            .background(Palette.surface, in: UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: 3,
                                                                    bottomTrailingRadius: 9, topTrailingRadius: 9,
                                                                    style: .continuous))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: 3, bottomTrailingRadius: 9,
                                            topTrailingRadius: 9, style: .continuous)
                .strokeBorder(Palette.shade.opacity(0.06), lineWidth: 1))
            .shadow(color: Palette.shadow.opacity(0.05), radius: 3, y: 2)
            HStack(spacing: 0) {
                Text("$ cat .env.local")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xc7c7cc))
                MotionClock { time in
                    Rectangle().fill(Color(hex: 0xc7c7cc))
                        .frame(width: 5, height: 11)
                        .opacity(time.map { $0.truncatingRemainder(dividingBy: 1.1) < 0.55 ? 1 : 0 } ?? 1)
                }
                .padding(.leading, 3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Brand.terminal, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .frame(width: 150)
    }
}

/// A config file where one value gets flagged a moment after the card appears.
private struct FlagArt: View {
    @State private var flagged = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("DB_HOST=localhost")
            HStack(spacing: 2) {
                Text("API_TOKEN=").foregroundStyle(Palette.ink2)
                Text("••••••••")
                    .tracking(0.8)
                    .foregroundStyle(flagged ? Brand.flagText : Palette.quaternary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(flagged ? Brand.flagFill : .clear, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Palette.amber, lineWidth: 1.5).opacity(flagged ? 1 : 0)
                        .scaleEffect(flagged ? 1 : 1.25))
            }
            Text("DEBUG=false")
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundStyle(Palette.quaternary)
        .padding(10)
        .frame(width: 168, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.shade.opacity(0.06), lineWidth: 1))
        .shadow(color: Palette.shadow.opacity(0.06), radius: 6, y: 4)
        .onAppear {
            guard !reduceMotion else { flagged = true; return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.62).delay(0.75)) { flagged = true }
        }
    }
}

/// The decisions the user records about a value.
private struct ReviewArt: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            pill {
                Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color(oklch: 0.5, 0.12, 150, dark: 0.72))
                Text("Confirmed secret")
            }
            pill {
                Circle().fill(Palette.quaternary).frame(width: 6, height: 6)
                Text("Rotated · \(DisplayTime.day(.now))")
            }
            HStack(spacing: 7) {
                Image(systemName: "lock.fill").font(.system(size: 9.5))
                Text("Reveal with Touch ID")
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Palette.accent, in: Capsule())
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 7) { content() }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Palette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.shade.opacity(0.06), lineWidth: 1))
    }
}

// MARK: - Choose agents

struct ChooseAgentsStep: View {
    let model: AppModel
    @Binding var flow: OnboardingFlow
    let configure: (AgentProvider) -> Void

    private var state: OnboardingState { OnboardingState(model: model, flow: flow) }
    private var searching: Bool { flow.scan != .done }

    /// Agents that can be ticked or already have hooks come first, then those that need attention.
    private var listed: [AgentRoute] {
        let usable = state.found.filter { $0.connectable || $0.hooksAdded || model.agentSetupBusy.contains($0.provider) }
        return usable + state.routes.filter { route in !usable.contains { $0.id == route.id } }
    }

    private var title: String {
        if searching { return "Looking for coding agents" }
        if model.storageFailed { return "\(AppIdentity.name) can’t open its storage" }
        if state.found.isEmpty { return "No coding agents found" }
        return listed.contains { $0.connectable || $0.hooksAdded } ? "Choose what to monitor" : "No agents ready to connect"
    }

    private var detail: String {
        if searching {
            return model.storageReady || model.storageFailed
                ? "Checking the usual install locations for Codex and Claude Code on this Mac…"
                : (model.storageMessage ?? "Opening protected storage…")
        }
        if model.storageFailed { return model.storageMessage ?? "Protected storage couldn’t be opened." }
        if state.found.isEmpty {
            return "You can point \(AppIdentity.name) to an agent now, or finish setup and connect one later in Settings."
        }
        return listed.contains { $0.connectable || $0.hooksAdded }
            ? "Pick the agents you use. You can change this later in Settings."
            : "\(AppIdentity.name) found agents it can’t monitor yet. Configure or repair them below, or connect one later in Settings."
    }

    /// Codex asks the user to trust new hooks, which happens in the next step's test session.
    private var listNote: String {
        let base = "\(AppIdentity.name) adds its own hooks and leaves your configuration as it is. You can remove them anytime."
        let codex = listed.contains {
            $0.provider == .codex && $0.state != .connected
                && ($0.hooksAdded || ($0.connectable && !model.setupDeselected.contains(.codex)))
        }
        return codex ? base + " Codex asks you to trust them when you run the test session on the next step." : base
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Illustration { DiscoveryArt(model: model, searching: searching) }
            StepHeader(title: title, detail: detail).padding(.top, 24)
            VStack(spacing: 8) {
                if searching {
                    ForEach(0..<3, id: \.self) { index in
                        SkeletonRow().opacity([1, 0.6, 0.3][index])
                    }
                    .transition(.opacity)
                } else if model.storageFailed {
                    EmptyView()
                } else if state.found.isEmpty {
                    NothingFoundCard(configure: configure) { flow.scanRequest += 1 }
                        .rise(0)
                } else {
                    ForEach(Array(listed.enumerated()), id: \.element.id) { index, route in
                        AgentChoiceRow(model: model, route: route, configure: configure).rise(index, distance: 6)
                    }
                    Text(listNote)
                        .font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2).padding(.top, 4)
                        .rise(listed.count)
                }
            }
            .padding(.top, 18)
        }
    }
}

/// Codex and Claude Code on either side of Spillcheck. A radar sweeps while searching; then each agent
/// slides in, joined by a green line when it's chosen.
private struct DiscoveryArt: View {
    let model: AppModel
    let searching: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            tile(.codex, from: 16)
            line(.codex)
            ZStack {
                if searching { RadarSweep().transition(.opacity) }
                AppIconImage(size: 96)
            }
            .frame(width: 96, height: 96)
            line(.claudeCode)
            tile(.claudeCode, from: -16)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: searching)
    }

    private func route(_ provider: AgentProvider) -> AgentRoute? { model.routes.first { $0.provider == provider } }

    private func found(_ provider: AgentProvider) -> Bool {
        guard let state = route(provider)?.state else { return false }
        return state != .notDetected && state != .notChecked
    }

    private func chosen(_ provider: AgentProvider) -> Bool {
        guard let route = route(provider) else { return false }
        return route.hooksAdded || (route.connectable && !model.setupDeselected.contains(provider))
    }

    private func tile(_ provider: AgentProvider, from offset: CGFloat) -> some View {
        AgentTile(provider: provider, size: 48, glyph: provider == .codex ? 24 : 26, found: found(provider))
            .opacity(searching ? 0 : 1)
            .offset(x: searching ? offset : 0)
            .animation(reduceMotion ? nil : Brand.settle(0.5), value: searching)
    }

    private func line(_ provider: AgentProvider) -> some View {
        ConnectorLine(style: chosen(provider) ? .active : found(provider) ? .idle : .dashed)
            .frame(width: 56, height: 2)
            .padding(.horizontal, 12)
            .opacity(searching ? 0 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.4).delay(searching ? 0 : 0.12), value: searching)
            .animation(.easeOut(duration: 0.2), value: chosen(provider))
    }
}

private struct SkeletonRow: View {
    var body: some View {
        MotionClock { time in
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Brand.skeleton).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 7) {
                    Capsule().fill(Brand.skeleton).frame(width: 120, height: 9)
                    Capsule().fill(Brand.skeletonFaint).frame(width: 200, height: 7)
                }
                Spacer(minLength: 0)
            }
            // A slow breath, so the placeholders read as loading rather than empty.
            .opacity(time.map { 0.8 + 0.2 * cos($0 * .pi / 0.9) } ?? 1)
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.skeletonRing, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// One agent on the Choose agents step: a checkbox when it can be connected, its status when hooks are
/// already added, and the fix when it can't be monitored.
private struct AgentChoiceRow: View {
    let model: AppModel
    let route: AgentRoute
    let configure: (AgentProvider) -> Void

    private var busy: Bool { model.agentSetupBusy.contains(route.provider) }

    var body: some View {
        if route.hooksAdded {
            addedRow
        } else if route.connectable || busy {
            Toggle(isOn: Binding(get: { !model.setupDeselected.contains(route.provider) }, set: { selected in
                if selected { model.setupDeselected.remove(route.provider) } else { model.setupDeselected.insert(route.provider) }
            })) {
                AgentLabel(route: route, detail: Self.summary(route))
            }
            .toggleStyle(AgentChoiceStyle(busy: busy))
            .disabled(busy)
            .accessibilityIdentifier("setup.\(route.provider.rawValue).choose")
        } else {
            attentionRow
        }
    }

    /// The version and where it runs from, like “codex 0.161.0 · ~/.local/bin/codex”.
    static func summary(_ route: AgentRoute) -> String {
        guard let profile = route.profile else { return route.provider.displayName }
        let command = route.provider == .codex ? "codex" : "claude"
        return [profile.version.isEmpty ? command : "\(command) \(profile.version)",
                AgentConfigurationLine.abbreviated(profile.executablePath)].joined(separator: " · ")
    }

    private var addedRow: some View {
        HStack(spacing: 12) {
            AgentLabel(route: route, detail: Self.summary(route))
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 7) {
                    Text(route.state == .connected ? "Verified" : "Hooks added")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(route.state == .connected ? Brand.greenText : Palette.amberText)
                    if route.state == .connected { CheckBadge(size: 18) } else { StatusDot(color: Palette.amber, size: 8) }
                }
                if route.state != .connected {
                    // Adding hooks isn't the end: the test session on Connect trusts and proves them.
                    Text(route.provider == .codex ? "Trust and verify on the next step" : "Verify on the next step")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.rowRing, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var attention: (detail: String, action: String, perform: () -> Void) {
        switch route.state {
        case .unsupported:
            return (route.profile?.unsupportedMessage ?? "This collection route has not been established.",
                    "Configure…", { configure(route.provider) })
        case .unavailable:
            return (model.agentSetupMessages[route.provider] ?? "\(AppIdentity.name)’s hooks need repair.",
                    "Repair", { model.onRepairAgent?(route.provider) })
        case .detected:
            return ("Its profile folder couldn’t be found.", "Configure…", { configure(route.provider) })
        case .notDetected, .notChecked, .installedUnverified, .connected:
            return ("Not found in the usual locations", "Locate…", { configure(route.provider) })
        }
    }

    private var attentionRow: some View {
        let attention = attention
        return HStack(spacing: 12) {
            AgentTile(provider: route.provider, found: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.provider.displayName).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Palette.ink2)
                Text(attention.detail).font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineLimit(1)
                    .help(attention.detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(attention.action, action: attention.perform)
                .buttonStyle(.onboarding(.secondary, size: .mini))
                .disabled(!model.storageReady)
                .accessibilityIdentifier("setup.\(route.provider.rawValue).fix")
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Brand.dashedBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .accessibilityElement(children: .contain)
    }
}

private struct AgentLabel: View {
    let route: AgentRoute
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            AgentTile(provider: route.provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A whole-row checkbox with a green selected state.
private struct AgentChoiceStyle: ToggleStyle {
    let busy: Bool

    func makeBody(configuration: Configuration) -> some View {
        AgentChoiceBody(configuration: configuration, busy: busy)
    }
}

private struct AgentChoiceBody: View {
    let configuration: ToggleStyleConfiguration
    let busy: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var on: Bool { configuration.isOn }

    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label
                ZStack {
                    if busy {
                        RingSpinner()
                    } else {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(on ? Brand.green : Palette.surface)
                        RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Brand.control, lineWidth: 1.5)
                            .opacity(on ? 0 : 1)
                        if on {
                            Image(systemName: "checkmark").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(Brand.greenInk)
                                .transition(.scale(scale: 0.3).combined(with: .opacity))
                        }
                    }
                }
                .frame(width: 18, height: 18)
            }
            .padding(.horizontal, 14)
            .frame(height: 60)
            .background(on ? (hovering ? Brand.selectedHover : Brand.selectedFill) : (hovering ? Brand.rowHover : Palette.surface),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(on ? Brand.selectedRing : Brand.rowRing, lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.7), value: on)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

private struct NothingFoundCard: View {
    let configure: (AgentProvider) -> Void
    let searchAgain: () -> Void
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(AppIdentity.name) looked in the usual places").font(.system(size: 13.5, weight: .semibold))
            Text("~/.local/bin, /opt/homebrew/bin, and /usr/local/bin. If an agent lives somewhere else, point \(AppIdentity.name) to it.")
                .font(.system(size: 12.5)).foregroundStyle(Palette.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
            HStack(spacing: 8) {
                Button("Locate an agent…") { choosing = true }
                    .buttonStyle(.onboarding(.primary, size: .small))
                    .popover(isPresented: $choosing, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(AgentProvider.allCases, id: \.self) { provider in
                                Button {
                                    choosing = false
                                    configure(provider)
                                } label: {
                                    HStack(spacing: 10) {
                                        AgentTile(provider: provider, size: 24)
                                        Text(provider.displayName).font(.system(size: 13))
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 8).frame(width: 190, height: 34)
                                    .contentShape(Rectangle())
                                    .hoverFill(radius: 6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(6)
                    }
                Button("Search again", action: searchAgain)
                    .buttonStyle(.onboarding(.secondary, size: .small))
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Brand.dashedBorder, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
    }
}

// MARK: - Connect

struct ConnectStep: View {
    let model: AppModel
    let flow: OnboardingFlow

    private var state: OnboardingState { OnboardingState(model: model, flow: flow) }

    /// The first agent still waiting for its test session; the session box walks through them in turn.
    private var nextSession: (route: AgentRoute, command: SetupCheckCommand)? {
        for route in state.connectRoutes where route.waitingForEvent && state.phase(route) == .waiting {
            if let command = model.setupCommand(for: route.provider) { return (route, command) }
        }
        return nil
    }

    var body: some View {
        let routes = state.connectRoutes
        let session = nextSession
        VStack(alignment: .leading, spacing: 0) {
            Illustration { ConnectionArt(state: state) }
            StepHeader(title: "Connect and verify",
                       detail: "\(AppIdentity.name) adds its hooks, then waits for one test prompt from a fresh session. That prompt proves monitoring works.")
                .padding(.top, 24)
            VStack(spacing: 8) {
                if !model.monitoringEnabled { PausedNotice(model: model) }
                ForEach(Array(routes.enumerated()), id: \.element.id) { index, route in
                    ConnectRow(model: model, route: route, phase: state.phase(route)).rise(index, distance: 6)
                }
                if let session {
                    SessionBox(model: model, route: session.route, command: session.command)
                        .id(session.route.provider)
                        .padding(.top, 6)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .padding(.top, 18)
            .animation(Brand.settle(0.4), value: session?.route.provider)
        }
    }
}

/// The agent being connected, a line to Spillcheck with events traveling along it, and a check once
/// every agent is verified.
private struct ConnectionArt: View {
    let state: OnboardingState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let routes = state.connectRoutes
        let first = routes.first?.provider ?? .codex
        let allVerified = state.allVerified
        let traveling = !allVerified && routes.contains { state.phase($0) != .queued }
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                AgentTile(provider: first, size: 56, glyph: first == .codex ? 30 : 34)
                    .shadow(color: Palette.shadow.opacity(0.12), radius: 8, y: 6)
                    .overlay(alignment: .topTrailing) {
                        if routes.count > 1 {
                            Text("+\(routes.count - 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 5)
                                .frame(minWidth: 20, minHeight: 20)
                                .background(Palette.surface, in: Capsule())
                                .overlay(Capsule().strokeBorder(Palette.shade.opacity(0.08), lineWidth: 1))
                                .shadow(color: Palette.shadow.opacity(0.08), radius: 2, y: 2)
                                .offset(x: 7, y: -7)
                        }
                    }
                Text(routes.count > 1 ? "\(routes.count) agents" : routes.first?.name ?? first.displayName)
                    .font(.system(size: 11.5)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            .frame(width: 96)
            ZStack(alignment: .leading) {
                ConnectorLine(style: allVerified ? .active : .dashed)
                if traveling { TravelDot(distance: 142).transition(.opacity) }
                if allVerified {
                    CheckBadge(size: 22)
                        .overlay(Circle().strokeBorder(Brand.illustration, lineWidth: 3).padding(-3))
                        .frame(maxWidth: .infinity)
                        .transition(.scale(scale: 0.01).combined(with: .opacity))
                }
            }
            .frame(width: 150, height: 2)
            .padding(.horizontal, 6)
            .padding(.bottom, 22)
            VStack(spacing: 0) {
                AppIconImage(size: 76).padding(.top, -4)
                Text(AppIdentity.name).font(.system(size: 11.5)).foregroundStyle(Palette.secondary).padding(.top, -2)
            }
            .frame(width: 96)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.55), value: allVerified)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: traveling)
    }
}

private struct ConnectRow: View {
    let model: AppModel
    let route: AgentRoute
    let phase: ConnectPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: (title: String, detail: String, color: Color) {
        switch phase {
        case .queued:
            return ("Queued", "Waiting to add hooks", Palette.tertiary)
        case .installing:
            return ("Installing hooks…", "Adding \(AppIdentity.name)’s hooks next to your existing ones", Brand.greenText)
        case .waiting:
            let detail = route.waitingForEvent ? "Hooks installed. One test session confirms delivery."
                : !model.monitoringEnabled ? "Resume monitoring to run the test session."
                : model.agentSetupMessages[route.provider] ?? "Preparing the test session…"
            return ("Waiting for a test session", detail, Palette.amberText)
        case .verified:
            return ("Verified", "Test prompt received. You can close the test session.", Brand.greenText)
        case .failed:
            return ("Couldn’t add hooks", model.agentSetupMessages[route.provider] ?? "Check the executable version and profile path.", Palette.red)
        case .needsRepair:
            return ("Needs repair", model.agentSetupMessages[route.provider] ?? "\(AppIdentity.name)’s hooks need repair.", Palette.red)
        }
    }

    var body: some View {
        let status = status
        let verified = phase == .verified
        HStack(spacing: 12) {
            AgentTile(provider: route.provider)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(route.name).font(.system(size: 13.5, weight: .medium))
                    Text(status.title).font(.system(size: 12, weight: .medium)).foregroundStyle(status.color)
                        .contentTransition(.opacity)
                }
                Text(status.detail).font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                    .lineLimit(1).help(status.detail)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if phase == .failed, let profile = route.profile {
                Button("Try again") { model.onInstallAgent?(route.provider, profile) }
                    .buttonStyle(.onboarding(.secondary, size: .mini))
                    .disabled(!model.storageReady)
            } else if phase == .needsRepair {
                Button("Repair") { model.onRepairAgent?(route.provider) }
                    .buttonStyle(.onboarding(.secondary, size: .mini))
                    .disabled(!model.storageReady)
            }
            indicator
                .frame(width: 22, height: 22)
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .background(verified ? Brand.verifiedFill : Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(verified ? Brand.verifiedRing : Brand.rowRing, lineWidth: 1))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: phase)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("setup.\(route.provider.rawValue).connection")
    }

    @ViewBuilder private var indicator: some View {
        ZStack {
            switch phase {
            case .queued:
                Circle().strokeBorder(Brand.control, lineWidth: 1.5).frame(width: 14, height: 14)
                    .transition(.opacity)
            case .installing:
                RingSpinner().transition(.opacity)
            case .waiting:
                PingDot().transition(.opacity)
            case .verified:
                CheckBadge(size: 20)
                    .transition(.scale(scale: 0.01).combined(with: .opacity)
                        .animation(.spring(response: 0.42, dampingFraction: 0.55)))
            case .failed, .needsRepair:
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 16)).foregroundStyle(Palette.redDot)
                    .transition(.opacity)
            }
        }
        .accessibilityHidden(true)
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
                .buttonStyle(.onboarding(.secondary, size: .mini))
                .disabled(!model.storageReady || model.monitoringTransition || model.stopped)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Palette.amberSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// How to start the test session for one agent: a command to run, or a prompt to send from T3.
private struct SessionBox: View {
    let model: AppModel
    let route: AgentRoute
    let command: SetupCheckCommand
    @State private var slow = false

    private var viaT3: Bool { route.profile?.interface == .t3 }
    private var agent: String { route.provider.displayName }

    private var instructions: String {
        if viaT3 { return "In T3, start a new \(agent) conversation and send this prompt. It replies once and does nothing else." }
        return route.provider == .codex
            ? "Codex asks you to trust the new hooks. Choose Trust all and continue, then wait for its one-word reply."
            : "If Claude Code asks you to trust the folder or review hooks, approve them, then wait for its one-word reply."
    }

    var body: some View {
        let text = viaT3 ? command.prompt : command.line
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viaT3 ? "Send the test prompt from T3" : "Start a fresh \(agent) session to verify")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(instructions).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                HStack(spacing: 10) {
                    Text(viaT3 ? text : "$ " + text)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1).truncationMode(.tail)
                        .textSelection(.enabled)
                        .help(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("setup.\(route.provider.rawValue).command")
                    CompactCopyButton(text: text)
                }
                .padding(.leading, 10).padding(.trailing, 4)
                .frame(height: 30)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.shade.opacity(0.07), lineWidth: 1))
                if !viaT3 {
                    Button { model.onOpenSetupTerminal?(route.provider) } label: {
                        Label("Open in Terminal", systemImage: "terminal").labelStyle(TightLabelStyle())
                    }
                    .buttonStyle(.onboarding(.primary, size: .small))
                    .disabled(model.isDemo)
                    .accessibilityIdentifier("setup.\(route.provider.rawValue).open-terminal")
                }
            }
            if slow {
                Text(route.provider == .codex && !viaT3
                     ? "Nothing yet? If you chose “Continue without trusting”, quit Codex and run the command again. The prompt must come from a new session that uses this profile."
                     : "Nothing yet? Make sure the prompt was sent from a new session that uses this profile, then try again.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeOut(duration: 0.25), value: slow)
        .task(id: command.prompt) {
            slow = false
            try? await Task.sleep(for: .seconds(45))
            if !Task.isCancelled { slow = true }
        }
    }
}

private struct CompactCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        }
        .buttonStyle(CompactButtonStyle())
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }
}

private struct CompactButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 8)
            .frame(minWidth: 54, minHeight: 22)
            .contentShape(Rectangle())
            .hoverFill(Palette.shade.opacity(configuration.isPressed ? 0.1 : 0.05), hover: Palette.shade.opacity(0.08), radius: 5)
    }
}

// MARK: - Preferences

struct PreferencesStep: View {
    let model: AppModel
    @Binding var flow: OnboardingFlow

    /// Alerts are, or will be once allowed, delivered.
    private var alertsOn: Bool {
        model.notificationState == .allowed || (model.notificationState == .notRequested && flow.wantsAlerts)
    }

    private var notificationDetail: String {
        switch model.notificationState {
        case .notRequested:
            "One alert per strong new value in each conversation. The value never appears."
                + (flow.wantsAlerts ? " macOS asks for permission when you continue." : "")
        case .allowed: "One alert per strong new value in each conversation. The value never appears."
        case .denied: "Turned off in System Settings. Detections still show in the menu bar and inventory."
        case .unavailable: "Unavailable right now. Detections still show in the menu bar and inventory."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Illustration {
                NotificationPreview(on: alertsOn)
            }
            .overlay(alignment: .topLeading) {
                Text("Preview").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.tertiary)
                    .padding(.leading, 14).padding(.top, 11)
                    .accessibilityHidden(true)
            }
            StepHeader(title: "Stay in the loop",
                       detail: "Choose how \(AppIdentity.name) gets your attention. You can change these anytime in Settings.")
                .padding(.top, 24)
            VStack(spacing: 0) {
                PreferenceRow(symbol: "app.badge", title: "Notifications", detail: notificationDetail) {
                    notificationControl
                }
                PreferenceRow(symbol: "power", title: "Open at login",
                              detail: model.loginMessage ?? "Start monitoring automatically when you log in.", divider: true) {
                    Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { enabled in
                        if model.isDemo { model.launchAtLogin = enabled } else { model.onLaunchAtLoginRequested?(enabled) }
                    }))
                    .toggleStyle(DesignSwitchStyle(onColor: Brand.green))
                    .labelsHidden()
                    .disabled((!model.storageReady || model.loginBusy || !model.loginAvailable) && !model.isDemo)
                    .accessibilityIdentifier("setup.launch-at-login")
                }
                PreferenceRow(symbol: "lock.fill", title: "Hidden values",
                              detail: "Values, excerpts, and paths need Touch ID or your password before they show.", divider: true) {
                    Text("Always on").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.cardRing, lineWidth: 1))
            .padding(.top, 18)
        }
        // Notification permission changes in System Settings without bringing Spillcheck forward.
        .task {
            while !Task.isCancelled {
                model.onRefreshPreferences?()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder private var notificationControl: some View {
        switch model.notificationState {
        case .notRequested:
            Toggle("Notifications", isOn: $flow.wantsAlerts)
                .toggleStyle(DesignSwitchStyle(onColor: Brand.green))
                .labelsHidden()
                .accessibilityIdentifier("setup.notifications")
        case .allowed:
            Label("Allowed", systemImage: "checkmark").labelStyle(TightLabelStyle())
                .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
        case .denied:
            Button("Open System Settings") { model.onOpenNotificationSettings?() }
                .buttonStyle(.onboarding(.secondary, size: .mini))
        case .unavailable:
            Text("Unavailable").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
        }
    }
}

/// What an alert looks like: the real title and body format, never the value.
private struct NotificationPreview: View {
    let on: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                AppIconImage(size: 40).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("New token detected").fontWeight(.semibold)
                        Spacer()
                        Text("now").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                    Text("Conversation 4 · Codex")
                    Text("Value hidden. Open \(AppIdentity.name) to review.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                .font(.system(size: 13))
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .frame(width: 340)
            .background(Brand.notification, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.shade.opacity(0.14), lineWidth: 0.5))
            .shadow(color: Palette.shadow.opacity(0.12), radius: 14, y: 10)
            .opacity(on ? 1 : 0.5)
            .grayscale(on ? 0 : 1)
            .scaleEffect(on ? 1 : 0.98)
            .offset(y: on ? 0 : 2)
            .rise(1, distance: -12)
            Text(on ? "What an alert looks like. The value itself never appears."
                    : "Alerts off. New detections still show in the menu bar and inventory.")
                .font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                .contentTransition(.opacity)
        }
        .animation(reduceMotion ? nil : Brand.settle(0.36), value: on)
    }
}

private struct PreferenceRow<Control: View>: View {
    let symbol: String
    let title: String
    let detail: String
    var divider = false
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Palette.ink2)
                .frame(width: 30, height: 30)
                .background(Brand.iconWell, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .overlay(alignment: .top) { if divider { Rectangle().fill(Palette.hairline).frame(height: 1) } }
        .animation(.easeOut(duration: 0.2), value: detail)
    }
}

// MARK: - Ready

struct ReadyStep: View {
    let model: AppModel
    let flow: OnboardingFlow
    @State private var badgeShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The chosen agents by where they ended up, so a failed installation never reads as "hooks added".
    private struct Outcome {
        var verified: [AgentRoute] = []
        /// Hooks are added; the test session hasn't arrived.
        var waiting: [AgentRoute] = []
        /// Hooks weren't added, need repair, or were never installed.
        var notConnected: [AgentRoute] = []

        var isEmpty: Bool { verified.isEmpty && waiting.isEmpty && notConnected.isEmpty }
        var complete: Bool { !verified.isEmpty && waiting.isEmpty && notConnected.isEmpty }
        var remaining: Int { waiting.count + notConnected.count }
    }

    private var outcome: Outcome {
        var outcome = Outcome()
        for route in OnboardingState(model: model, flow: flow).connectRoutes {
            switch route.state {
            case .connected: outcome.verified.append(route)
            case .installedUnverified: outcome.waiting.append(route)
            default: outcome.notConnected.append(route)
            }
        }
        return outcome
    }

    var body: some View {
        let outcome = outcome
        VStack(alignment: .leading, spacing: 0) {
            Illustration(height: 170) {
                ZStack(alignment: .bottomTrailing) {
                    PulseRings(color: outcome.complete ? Brand.pulse : Brand.pulseAmber, diameter: 100)
                        .frame(width: 124, height: 124)
                    AppIconImage(size: 124)
                    badge(ok: outcome.complete)
                        .padding(.trailing, 6).padding(.bottom, 8)
                        .scaleEffect(badgeShown || reduceMotion ? 1 : 0.01)
                        .opacity(badgeShown || reduceMotion ? 1 : 0)
                }
                .frame(width: 124, height: 124)
            }
            StepHeader(title: title(outcome), detail: detail(outcome))
                .padding(.top, 24)
            VStack(spacing: 0) {
                SummaryRow(label: "Agents", dot: outcome.complete ? Brand.green : outcome.isEmpty ? Brand.control : Palette.amber,
                           value: agentsValue(outcome))
                history(verified: !outcome.verified.isEmpty)
                SummaryRow(label: "Notifications", dot: model.notificationState == .allowed ? Brand.green
                           : model.notificationState == .notRequested && flow.wantsAlerts ? Palette.amber : Brand.control,
                           value: notificationValue, divider: true)
                SummaryRow(label: "Open at login", dot: model.launchAtLogin ? Brand.green : Brand.control,
                           value: model.launchAtLogin ? "On" : "Off", divider: true)
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.cardRing, lineWidth: 1))
            .padding(.top, 18)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55).delay(0.2)) { badgeShown = true }
        }
    }

    private func badge(ok: Bool) -> some View {
        ZStack {
            Circle().fill(ok ? Brand.green : Palette.amber)
            if ok {
                Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy)).foregroundStyle(Brand.greenInk)
            } else {
                Text("!").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: 32, height: 32)
        .overlay(Circle().strokeBorder(Brand.illustration, lineWidth: 3).padding(-3))
        .shadow(color: Palette.shadow.opacity(0.15), radius: 5, y: 4)
        .accessibilityHidden(true)
    }

    private func title(_ outcome: Outcome) -> String {
        if outcome.isEmpty { return "Nothing is being checked yet" }
        if outcome.complete { return "You’re all set" }
        if !outcome.verified.isEmpty { return outcome.remaining == 1 ? "Set up, with one thing left" : "Set up, with a few things left" }
        return outcome.notConnected.isEmpty ? "Waiting for a test session" : "Not connected yet"
    }

    private func detail(_ outcome: Outcome) -> String {
        if outcome.isEmpty {
            return "Connect Codex or Claude Code from Settings › Agents whenever you’re ready. Until then, \(AppIdentity.name) doesn’t check anything."
        }
        if outcome.complete {
            return "\(AppIdentity.name) now checks new agent activity and is reading the last 7 days. Closing this window doesn’t stop it."
        }
        var sentences: [String] = []
        if !outcome.verified.isEmpty {
            sentences.append("Monitoring works for \(plural(outcome.verified.count, "agent")).")
        } else if outcome.notConnected.isEmpty {
            sentences.append("Hooks are added, but monitoring isn’t proven yet.")
        }
        if !outcome.waiting.isEmpty, !outcome.verified.isEmpty || !outcome.notConnected.isEmpty {
            let names = outcome.waiting.map(\.name).joined(separator: " and ")
            sentences.append("\(names) still \(outcome.waiting.count == 1 ? "needs its" : "need their") test session.")
        }
        for route in outcome.notConnected {
            sentences.append(route.state == .unavailable ? "\(route.name)’s hooks need repair."
                             : "\(route.name)’s hooks couldn’t be added.")
        }
        sentences.append(outcome.verified.isEmpty ? "Finish from Settings › Agents." : "You can finish later from Settings › Agents.")
        return sentences.joined(separator: " ")
    }

    private func agentsValue(_ outcome: Outcome) -> String {
        if outcome.isEmpty { return "None connected yet" }
        if outcome.verified.isEmpty, outcome.notConnected.isEmpty { return "Waiting for a test session" }
        return [(outcome.verified.count, "verified"), (outcome.waiting.count, "waiting for a test session"),
                (outcome.notConnected.count, "not connected")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    private var notificationValue: String {
        switch model.notificationState {
        case .allowed: "On"
        case .notRequested: flow.wantsAlerts ? "Waiting for your permission" : "Off · menu bar and inventory only"
        case .denied: "Off · menu bar and inventory only"
        case .unavailable: "Unavailable · menu bar and inventory only"
        }
    }

    /// Catch-up has ended once its queued work is gone, but only coverage says whether it read
    /// everything: an exhausted budget or a failed read leaves gaps.
    @ViewBuilder private func history(verified: Bool) -> some View {
        if !verified {
            SummaryRow(label: "Last 7 days", dot: Brand.control, value: "Starts once an agent is verified", divider: true)
        } else if model.catchingUp {
            SummaryRow(label: "Last 7 days", dot: Brand.green, value: "Reading…", divider: true) { ReadingBar(done: false) }
        } else if case .partial = model.monitoring.coverage {
            SummaryRow(label: "Last 7 days", dot: Palette.amber, value: "Read, with gaps · details in Coverage",
                       divider: true) { ReadingBar(done: true, tint: Palette.amber) }
        } else {
            let conversations = model.activity?.conversationCount ?? 0
            SummaryRow(label: "Last 7 days", dot: Brand.green,
                       value: conversations == 0 ? "Done · nothing to read yet" : "Done · \(plural(conversations, "conversation")) read",
                       divider: true) { ReadingBar(done: true) }
        }
    }
}

private struct SummaryRow<Accessory: View>: View {
    let label: String
    let dot: Color
    let value: String
    var divider = false
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 0) {
            Text(label).foregroundStyle(Palette.secondary).frame(width: 150, alignment: .leading)
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true)
                accessory
                Text(value).monospacedDigit().lineLimit(1).contentTransition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
        .overlay(alignment: .top) { if divider { Rectangle().fill(Palette.hairline).frame(height: 1) } }
        .animation(.easeOut(duration: 0.25), value: value)
        .accessibilityElement(children: .combine)
    }
}

extension SummaryRow where Accessory == EmptyView {
    init(label: String, dot: Color, value: String, divider: Bool = false) {
        self.init(label: label, dot: dot, value: value, divider: divider) { EmptyView() }
    }
}

/// History catch-up has no reliable percentage, so reading shows a moving segment, then a full bar.
private struct ReadingBar: View {
    let done: Bool
    var tint = Brand.green

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Brand.barTrack)
            if done {
                Capsule().fill(tint).transition(.opacity)
            } else {
                MotionClock { time in
                    let progress = time.map { $0.truncatingRemainder(dividingBy: 1.4) / 1.4 } ?? 0.35
                    Capsule().fill(Brand.green)
                        .frame(width: 40)
                        .offset(x: -40 + 160 * progress)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: 120, height: 4)
        .clipShape(Capsule())
        .animation(.easeOut(duration: 0.3), value: done)
        .accessibilityHidden(true)
    }
}
