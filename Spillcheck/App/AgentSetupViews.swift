import SwiftUI
import SpillcheckCore

/// The three things the user does for a delivery check, as listed in Settings › Agents.
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

/// The agents' own marks, from their published 24-point SVG artwork. Arcs are pre-converted to
/// curves, so the data holds only move, line, curve, and close commands.
struct AgentGlyph: Shape {
    let provider: AgentProvider

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        let artwork = provider == .codex ? Self.codex : Self.claude
        return artwork.applying(CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: scale, y: scale))
    }

    private static let codex = parse("""
        M 8.086 0.457 C 9.049 0.061 10.098 -0.082 11.132 0.042 C 12.465 0.195 13.653 0.762 14.696 1.742 C 14.725
        1.769 14.765 1.78 14.803 1.771 C 16.211 1.425 17.565 1.547 18.864 2.137 L 18.927 2.167 L 19.081 2.243 C
        20.438 2.946 21.411 4.013 21.999 5.441 C 22.277 6.12 22.417 6.829 22.42 7.567 C 22.44 8.117 22.379 8.666
        22.24 9.198 C 22.226 9.253 22.241 9.312 22.28 9.353 C 23.066 10.15 23.613 11.152 23.858 12.244 C 24.243
        14.145 23.848 15.859 22.675 17.384 L 22.493 17.604 C 21.716 18.494 20.696 19.137 19.559 19.455 C 19.509
        19.47 19.468 19.508 19.451 19.557 C 19.196 20.293 18.94 20.921 18.464 21.549 C 17.265 23.131 15.502
        24.011 13.516 24 C 11.933 23.992 10.53 23.413 9.306 22.264 C 9.268 22.229 9.215 22.217 9.166 22.232 C
        8.648 22.399 8.126 22.423 7.562 22.417 C 6.661 22.41 5.773 22.197 4.967 21.795 C 4.123 21.376 3.388
        20.766 2.821 20.014 C 2.618 19.745 2.417 19.492 2.27 19.193 C 2.067 18.781 1.902 18.352 1.775 17.91 C
        1.509 16.907 1.503 15.852 1.758 14.846 C 1.766 14.822 1.769 14.797 1.766 14.772 C 1.761 14.747 1.748
        14.725 1.729 14.708 C 1.113 14.084 0.641 13.333 0.349 12.506 C 0.155 11.997 0.043 11.461 0.016 10.917 C
        -0.032 10.201 0.031 9.482 0.204 8.785 C 0.654 7.301 1.513 6.137 2.781 5.292 C 3.063 5.104 3.331 4.958
        3.583 4.854 C 3.869 4.734 4.156 4.634 4.444 4.55 C 4.486 4.538 4.519 4.505 4.531 4.463 C 4.749 3.678
        5.125 2.945 5.635 2.31 C 6.315 1.464 7.132 0.846 8.086 0.457 Z M 7.282 8.307 C 7.049 7.9 6.531 7.759
        6.125 7.992 C 5.718 8.224 5.576 8.742 5.809 9.149 L 7.503 12.114 L 5.815 14.962 C 5.6 15.363 5.739
        15.862 6.131 16.094 C 6.522 16.326 7.027 16.207 7.275 15.826 L 9.215 12.554 C 9.371 12.291 9.373 11.965
        9.222 11.7 L 7.282 8.307 Z M 12.728 14.547 C 12.279 14.574 11.929 14.945 11.929 15.395 C 11.929 15.844
        12.279 16.215 12.728 16.242 L 17.576 16.242 C 18.028 16.22 18.384 15.847 18.384 15.394 C 18.384 14.941
        18.028 14.568 17.576 14.546 L 12.728 14.546 Z
        """)

    private static let claude = parse("""
        M 20.998 10.949 L 24 10.949 L 24 14.051 L 21 14.051 L 21 17.079 L 19.513 17.079 L 19.513 20 L 18 20 L 18
        17.079 L 16.513 17.079 L 16.513 20 L 15 20 L 15 17.079 L 9 17.079 L 9 20 L 7.488 20 L 7.488 17.079 L 6
        17.079 L 6 20 L 4.487 20 L 4.487 17.079 L 3 17.079 L 3 14.05 L 0 14.05 L 0 10.95 L 3 10.95 L 3 5 L
        20.998 5 L 20.998 10.949 Z M 6 10.949 L 7.488 10.949 L 7.488 8.102 L 6 8.102 L 6 10.949 Z M 16.51 10.949
        L 18 10.949 L 18 8.102 L 16.51 8.102 L 16.51 10.949 Z
        """)

    private static func parse(_ data: String) -> Path {
        var path = Path()
        var command = "M"
        var values: [CGFloat] = []
        for token in data.split(whereSeparator: \.isWhitespace) {
            if let number = Double(token) {
                values.append(CGFloat(number))
            } else {
                command = String(token)
                values = []
                if command == "Z" { path.closeSubpath() }
            }
            switch (command, values.count) {
            case ("M", 2): path.move(to: CGPoint(x: values[0], y: values[1])); values = []
            case ("L", 2): path.addLine(to: CGPoint(x: values[0], y: values[1])); values = []
            case ("C", 6):
                path.addCurve(to: CGPoint(x: values[4], y: values[5]), control1: CGPoint(x: values[0], y: values[1]),
                              control2: CGPoint(x: values[2], y: values[3]))
                values = []
            default: break
            }
        }
        return path
    }
}
