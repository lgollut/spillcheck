import SwiftUI
import SpillcheckCore

/// The setup assistant's brand colors. The design specifies light mode; dark values keep the same
/// contrast on the app's tinted neutrals.
enum Brand {
    /// Sage green fills: completed steps, checkboxes, switches, and the verified connection.
    static let green = Color(oklch: 0.78, 0.15, 158)
    /// Checkmarks drawn on `green`.
    static let greenInk = Color(oklch: 0.3, 0.07, 160)
    /// The current step's ring and the install spinner.
    static let greenDeep = Color(oklch: 0.52, 0.12, 160, dark: 0.72)
    static let greenText = Color(oklch: 0.48, 0.11, 160, dark: 0.8)
    static let halo = Color(oklch: 0.72, 0.14, 158, opacity: 0.25)
    static let selectedFill = Color(oklch: 0.975, 0.022, 158, dark: 0.27)
    static let selectedHover = Color(oklch: 0.96, 0.03, 158, dark: 0.3)
    static let selectedRing = Color(oklch: 0.66, 0.14, 159, dark: 0.7)
    static let verifiedFill = Color(oklch: 0.98, 0.02, 158, dark: 0.25)
    static let verifiedRing = Color(oklch: 0.87, 0.07, 158, dark: 0.4)
    static let calloutFill = Color(oklch: 0.97, 0.025, 158, dark: 0.26)
    static let calloutRing = Color(oklch: 0.9, 0.05, 158, dark: 0.36)
    static let calloutText = Color(hex: 0x2c3a33, dark: 0xc9d6cf)
    static let pulse = Color(oklch: 0.7, 0.13, 158, opacity: 0.5)
    static let pulseAmber = Color(oklch: 0.7, 0.12, 70, opacity: 0.5)
    static let radarLine = Color(oklch: 0.6, 0.09, 160)
    static let sweep = Color(oklch: 0.72, 0.14, 158, opacity: 0.38)
    static let flagFill = Color(oklch: 0.94, 0.06, 80, dark: 0.36)
    static let flagText = Color(oklch: 0.42, 0.09, 62, dark: 0.86)

    static let track = Color(hex: 0xdde3e0, dark: 0x2c312e)
    static let futureRing = Color(hex: 0xcfd5d2, dark: 0x3d4340)
    static let control = Color(hex: 0xc5ccc8, dark: 0x4a504d)
    static let dash = Color(hex: 0xc0c7c3, dark: 0x4a504d)
    static let dashedBorder = Color(hex: 0xcfd5d2, dark: 0x3d4340)
    static let cardRing = Color(hex: 0xe4e8e6, dark: 0x2c302e)
    static let rowRing = Color(hex: 0xe1e6e3, dark: 0x2e3230)
    static let rowHover = Color(hex: 0xf9fbfa, dark: 0x202422)
    static let barTrack = Color(hex: 0xe3e8e5, dark: 0x2e312f)
    static let iconWell = Color(hex: 0xeef1ef, dark: 0x262a28)
    static let primaryDisabled = Color(hex: 0xe3e7e5, dark: 0x2a2e2c)
    static let skeleton = Color(hex: 0xeceeed, dark: 0x262a28)
    static let skeletonFaint = Color(hex: 0xeff2f0, dark: 0x222624)
    static let skeletonRing = Color(hex: 0xe9edeb, dark: 0x262a28)
    static let bubbleBar = Color(hex: 0xd8dedb, dark: 0x3a3f3c)
    static let terminal = Color(hex: 0x1c1c1e, dark: 0x0c0d0d)
    static let notification = Color(light: .white.opacity(0.94), dark: Color(hex: 0x2a2e2c, opacity: 0.94))
    static let illustration = Color(hex: 0xf6f8f7, dark: 0x1a1e1c)
    static let welcome = Color(hex: 0xfafbfa, dark: 0x151816)
    static let mint = Color(oklch: 0.94, 0.045, 158, dark: 0.3)
    static let welcomeMint = Color(oklch: 0.94, 0.05, 158, dark: 0.31)
    static let lime = Color(oklch: 0.965, 0.03, 105, dark: 0.27)
    static let teal = Color(oklch: 0.955, 0.03, 185, dark: 0.27)

    /// The design's `cubic-bezier(.2, .8, .2, 1)`: fast out of the gate, long settle.
    static func settle(_ duration: Double) -> Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: duration) }
}

// MARK: - Backgrounds

/// A soft elliptical tint, like a CSS radial gradient: `radius` is a fraction of the width and height,
/// and the color has faded out at `fade` of it.
struct Glow: View {
    let color: Color
    let center: UnitPoint
    let radius: CGSize
    var fade: CGFloat = 0.7

    var body: some View {
        Canvas { context, size in
            let rx = radius.width * size.width, ry = radius.height * size.height
            guard rx > 0, ry > 0 else { return }
            var context = context
            context.translateBy(x: center.x * size.width, y: center.y * size.height)
            context.scaleBy(x: 1, y: ry / rx)
            let reach = rx * fade
            context.fill(Path(CGRect(x: -reach, y: -reach, width: reach * 2, height: reach * 2)),
                         with: .radialGradient(Gradient(colors: [color, color.opacity(0)]), center: .zero,
                                               startRadius: 0, endRadius: reach))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The welcome step's backdrop, which fades away as setup starts.
struct WelcomeBackground: View {
    var body: some View {
        ZStack {
            Brand.welcome
            Glow(color: Brand.welcomeMint, center: UnitPoint(x: 0.5, y: 0.32), radius: CGSize(width: 0.55, height: 0.48), fade: 1)
            Glow(color: Brand.lime, center: UnitPoint(x: 0.88, y: 0.96), radius: CGSize(width: 0.45, height: 0.45), fade: 1)
            Glow(color: Brand.teal, center: UnitPoint(x: 0.08, y: 0.92), radius: CGSize(width: 0.4, height: 0.4), fade: 1)
        }
    }
}

/// The tinted panel behind each step's illustration.
struct Illustration<Content: View>: View {
    var height: CGFloat = 150
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Brand.illustration
            Glow(color: Brand.mint, center: UnitPoint(x: 0.12, y: 0), radius: CGSize(width: 0.7, height: 1.2))
            Glow(color: Brand.lime, center: UnitPoint(x: 0.92, y: 1), radius: CGSize(width: 0.6, height: 1.2))
            content
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.shade.opacity(0.04), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// The same tint, cut to the top of a How it works card.
struct CardArtBackground: View {
    var body: some View {
        ZStack {
            Brand.illustration
            Glow(color: Brand.mint, center: UnitPoint(x: 0.1, y: 0), radius: CGSize(width: 0.8, height: 1.1))
            Glow(color: Brand.lime, center: UnitPoint(x: 0.95, y: 1), radius: CGSize(width: 0.7, height: 1.1))
        }
    }
}

// MARK: - Motion

/// Seconds since the view appeared, redrawn every frame. With Reduce Motion on, `time` is nil and
/// nothing is redrawn, so each animation shows a still frame instead.
struct MotionClock<Content: View>: View {
    @ViewBuilder let content: (_ time: Double?) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
            content(reduceMotion ? nil : context.date.timeIntervalSince(start))
        }
    }
}

/// Content that settles into place after its step appears, `index` beats after the first.
private struct Rise: ViewModifier {
    let index: Int
    let distance: CGFloat
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : distance)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(Brand.settle(0.5).delay(0.08 + 0.07 * Double(index))) { shown = true }
            }
    }
}

extension View {
    func rise(_ index: Int = 0, distance: CGFloat = 8) -> some View {
        modifier(Rise(index: index, distance: distance))
    }
}

/// Three rings that grow out from behind the app icon, one every 1.5 s.
struct PulseRings: View {
    let color: Color
    let diameter: CGFloat
    private static let curve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.2, y: 0.6),
                                                endControlPoint: UnitPoint(x: 0.3, y: 1))

    var body: some View {
        MotionClock { time in
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    let ring = Self.ring(index, at: time)
                    Circle().strokeBorder(color, lineWidth: 1.5)
                        .frame(width: diameter, height: diameter)
                        .scaleEffect(ring.scale)
                        .opacity(ring.opacity)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Each ring grows from 0.9× to 2.1× over 4.5 s, peaking in opacity early. Still, the rings sit at
    /// spaced sizes.
    private static func ring(_ index: Int, at time: Double?) -> (scale: CGFloat, opacity: Double) {
        guard let time else { return (1.3 + 0.32 * CGFloat(index), 0.5 - 0.15 * Double(index)) }
        let local = time - 1.5 * Double(index)
        guard local >= 0 else { return (0.9, 0) }
        let progress = local.truncatingRemainder(dividingBy: 4.5) / 4.5
        let opacity = progress < 0.12 ? 0.7 * curve.value(at: progress / 0.12)
            : 0.7 * (1 - curve.value(at: (progress - 0.12) / 0.88))
        return (0.9 + 1.2 * curve.value(at: progress), opacity)
    }
}

/// A radar sweep around the app icon while agents are being looked for.
struct RadarSweep: View {
    var body: some View {
        MotionClock { time in
            ZStack {
                Circle().strokeBorder(Brand.radarLine.opacity(0.18), lineWidth: 1).frame(width: 220, height: 220)
                Circle().strokeBorder(Brand.radarLine.opacity(0.28), lineWidth: 1).frame(width: 150, height: 150)
                Circle()
                    .fill(AngularGradient(stops: [.init(color: Brand.sweep.opacity(0), location: 0),
                                                  .init(color: Brand.sweep.opacity(0), location: 280.0 / 360),
                                                  .init(color: Brand.sweep, location: 1)],
                                          center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)))
                    .frame(width: 220, height: 220)
                    .rotationEffect(.degrees((time ?? 0) / 1.5 * 360))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A small ring spinner for hooks being added.
struct RingSpinner: View {
    var body: some View {
        MotionClock { time in
            ZStack {
                Circle().stroke(Brand.greenDeep.opacity(0.2), lineWidth: 2)
                Circle().trim(from: 0, to: 0.25).stroke(Brand.greenDeep, lineWidth: 2)
                    .rotationEffect(.degrees(-135 + (time ?? 0) / 0.8 * 360))
            }
            .frame(width: 14, height: 14)
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// An amber dot that pings while Spillcheck waits for the test session.
struct PingDot: View {
    private static let curve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0, y: 0), endControlPoint: UnitPoint(x: 0.2, y: 1))

    var body: some View {
        MotionClock { time in
            let progress = time.map { min(1, $0.truncatingRemainder(dividingBy: 1.6) / 1.6 / 0.75) }
            let ping = progress.map { Self.curve.value(at: $0) }
            ZStack {
                Circle().fill(Palette.amber)
                    .scaleEffect(1 + 1.4 * (ping ?? 0))
                    .opacity(ping.map { 1 - $0 } ?? 0)
                Circle().fill(Palette.amber)
            }
            .frame(width: 10, height: 10)
        }
        .accessibilityHidden(true)
    }
}

/// A dot that travels along the connection line while events are on their way.
struct TravelDot: View {
    let distance: CGFloat
    private static let curve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.45, y: 0), endControlPoint: UnitPoint(x: 0.55, y: 1))

    var body: some View {
        MotionClock { time in
            let progress = time.map { $0.truncatingRemainder(dividingBy: 1.7) / 1.7 }
            let x = progress.map { distance * Self.curve.value(at: $0) } ?? distance / 2
            let opacity = progress.map { $0 < 0.15 ? $0 / 0.15 : $0 > 0.85 ? (1 - $0) / 0.15 : 1 } ?? 1
            Circle().fill(Brand.green)
                .frame(width: 8, height: 8)
                .background(Circle().fill(Color(oklch: 0.72, 0.14, 158, opacity: 0.3)).padding(-4))
                .offset(x: x)
                .opacity(opacity)
        }
        .accessibilityHidden(true)
    }
}

/// A dashed or solid two-point line between the agent and Spillcheck.
struct ConnectorLine: View {
    enum Style { case dashed, idle, active }
    let style: Style

    var body: some View {
        switch style {
        case .dashed:
            HorizontalLine().stroke(Brand.dash, style: StrokeStyle(lineWidth: 2, lineCap: .butt, dash: [5, 5]))
        case .idle: Capsule().fill(Brand.dash)
        case .active: Capsule().fill(Brand.green)
        }
    }
}

struct HorizontalLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

// MARK: - Shared pieces

struct CheckBadge: View {
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(Brand.greenInk)
            .frame(width: size, height: size)
            .background(Brand.green, in: Circle())
            .accessibilityHidden(true)
    }
}

struct AppIconImage: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// An agent's mark on its tile. A missing agent shows a dashed outline with a muted mark.
struct AgentTile: View {
    let provider: AgentProvider
    var size: CGFloat = 34
    var glyph: CGFloat?
    var found = true

    private var glyphSize: CGFloat { glyph ?? size * (provider == .codex ? 0.59 : 0.65) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        AgentGlyph(provider: provider)
            .fill(found ? (provider == .codex ? Color.white : Color(hex: 0xd97757)) : Palette.quaternary,
                  style: FillStyle(eoFill: true))
            .frame(width: glyphSize, height: glyphSize)
            .frame(width: size, height: size)
            .background {
                if found {
                    shape.fill(provider == .codex ? Color(hex: 0x1c1c1e, dark: 0x0c0d0d) : Color(oklch: 0.965, 0.022, 50, dark: 0.3))
                } else {
                    shape.fill(Palette.surface.opacity(0.55))
                }
            }
            .overlay {
                if found {
                    shape.strokeBorder(Color(light: .clear, dark: .white.opacity(0.1)), lineWidth: 1)
                } else {
                    shape.strokeBorder(Brand.dash, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5]))
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Buttons

/// The setup assistant's buttons: dark primary, quiet gray secondary, and green text-only ghost.
struct OnboardingButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost }
    enum Size { case regular, small, mini }
    var kind: Kind
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        OnboardingButton(kind: kind, size: size, configuration: configuration)
    }
}

private struct OnboardingButton: View {
    let kind: OnboardingButtonStyle.Kind
    let size: OnboardingButtonStyle.Size
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    private var height: CGFloat { size == .regular ? 32 : size == .small ? 28 : 26 }
    private var radius: CGFloat { size == .regular ? 8 : size == .small ? 7 : 6 }

    private var padding: CGFloat {
        switch (kind, size) {
        case (.primary, .regular): 18
        case (.secondary, .regular): 14
        case (_, .mini): 10
        default: 12
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: enabled ? (hovering ? Palette.accentHover : Palette.accent) : Brand.primaryDisabled
        case .secondary: Palette.shade.opacity(hovering && enabled ? 0.08 : 0.05)
        case .ghost: hovering && enabled ? Palette.shade.opacity(0.04) : .clear
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: enabled ? Palette.onAccent : Palette.quaternary
        case .secondary: Palette.ink.opacity(enabled ? 1 : 0.4)
        case .ghost: Brand.greenText
        }
    }

    var body: some View {
        configuration.label
            .font(.system(size: size == .regular ? 13 : size == .small ? 12.5 : 12, weight: .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, padding)
            .frame(height: height)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: kind == .primary && enabled ? Palette.shadow.opacity(0.12) : .clear, radius: 1, y: 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .modifier(PressScale(pressed: configuration.isPressed))
            .animation(.easeOut(duration: 0.16), value: enabled)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension ButtonStyle where Self == OnboardingButtonStyle {
    static func onboarding(_ kind: OnboardingButtonStyle.Kind, size: OnboardingButtonStyle.Size = .regular) -> Self {
        OnboardingButtonStyle(kind: kind, size: size)
    }
}
