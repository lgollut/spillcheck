import SwiftUI
import SpillcheckCore

enum AppIdentity {
    static let name = "Spillcheck"
}

extension Color {
    /// Design tokens are specified in OKLCH; convert them once to sRGB.
    init(oklch l: Double, _ c: Double, _ h: Double, opacity: Double = 1) {
        let hue = h * .pi / 180
        let a = c * cos(hue), b = c * sin(hue)
        let l1 = l + 0.3963377774 * a + 0.2158037573 * b
        let m1 = l - 0.1055613458 * a - 0.0638541728 * b
        let s1 = l - 0.0894841775 * a - 1.2914855480 * b
        let (lc, mc, sc) = (l1 * l1 * l1, m1 * m1 * m1, s1 * s1 * s1)
        func encode(_ linear: Double) -> Double {
            let v = min(1, max(0, linear))
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        self.init(.sRGB,
                  red: encode(4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc),
                  green: encode(-1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc),
                  blue: encode(-0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc),
                  opacity: opacity)
    }

    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: opacity)
    }

    /// Follows the appearance it's drawn in. Only light mode is designed; dark values are derived
    /// from it to keep the same contrast, on neutrals tinted like the light ones.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            NSColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }

    init(hex: UInt32, dark: UInt32) {
        self.init(light: Color(hex: hex), dark: Color(hex: dark))
    }

    /// The same hue and chroma at another lightness in dark mode, for tinted fills and text.
    init(oklch l: Double, _ c: Double, _ h: Double, dark: Double) {
        self.init(light: Color(oklch: l, c, h), dark: Color(oklch: dark, c, h))
    }
}

enum Palette {
    static let ink = Color(hex: 0x1c1c1e, dark: 0xe9e9ec)
    static let ink2 = Color(hex: 0x3d3d42, dark: 0xc7c7cc)
    static let secondary = Color(hex: 0x5f5f65, dark: 0xaeaeb2)
    static let tertiary = Color(hex: 0x6e6e73, dark: 0x98989d)
    static let quaternary = Color(hex: 0x8e8e93, dark: 0x7c7c80)
    static let faint = Color(hex: 0xc7c7cc, dark: 0x48484a)
    static let ring = Color(hex: 0xaeaeb2, dark: 0x636366)
    /// The content pane. Cards on it are `surface`, a step lighter in dark mode.
    static let background = Color(hex: 0xffffff, dark: 0x151816)
    static let surface = Color(hex: 0xffffff, dark: 0x1d201e)
    static let sidebar = Color(hex: 0xf4f6f5, dark: 0x191d1b)
    static let separator = Color(hex: 0xe1e6e3, dark: 0x2e312f)
    static let hairline = Color(hex: 0xeceeed, dark: 0x242725)
    static let well = Color(hex: 0xf1f4f2, dark: 0x1f2321)
    static let quiet = Color(hex: 0xf2f5f3, dark: 0x1e2120)
    static let chip = Color(hex: 0xe9edeb, dark: 0x292c2a)
    /// Black in light mode, white in dark; give it an opacity for hover fills, wells, and rings.
    static let shade = Color(light: .black, dark: .white)
    /// Dark mode drops shadows; edges come from rings instead.
    static let shadow = Color(light: .black, dark: .clear)
    static let link = Color(oklch: 0.47, 0.06, 152, dark: 0.76)
    static let accent = Color(hex: 0x222624, dark: 0xe1e6e3)
    static let accentHover = Color(hex: 0x363b38, dark: 0xcdd3cf)
    static let onAccent = Color(hex: 0xffffff, dark: 0x151816)
    static let focus = Color(oklch: 0.62, 0.07, 150, dark: 0.66)
    static let selection = Color(oklch: 0.95, 0.018, 150, dark: 0.32)
    static let selectedRow = Color(oklch: 0.965, 0.014, 150, dark: 0.29)
    static let amber = Color(oklch: 0.74, 0.14, 70)
    static let amberText = Color(light: Color(oklch: 0.48, 0.1, 62), dark: Color(oklch: 0.8, 0.11, 72))
    static let amberSoft = Color(light: Color(oklch: 0.95, 0.04, 80), dark: Color(oklch: 0.33, 0.05, 72))
    static let amberSoftText = Color(light: Color(oklch: 0.42, 0.09, 62), dark: Color(oklch: 0.85, 0.09, 78))
    static let green = Color(oklch: 0.66, 0.07, 150, dark: 0.68)
    static let switchOn = Color(oklch: 0.66, 0.07, 150, dark: 0.6)
    static let red = Color(light: Color(oklch: 0.5, 0.16, 25), dark: Color(oklch: 0.7, 0.15, 25))
    /// Destructive buttons keep white text, so their fill stays dark enough for it.
    static let destructive = Color(oklch: 0.5, 0.16, 25, dark: 0.58)
    static let redDot = Color(oklch: 0.55, 0.17, 25, dark: 0.66)
    static let readCell = Color(oklch: 0.56, 0.03, 150, dark: 0.6)
    static let highlight = Color(oklch: 0.92, 0.07, 85, dark: 0.42)
    static let mono = Font.system(size: 11, design: .monospaced)
}

/// Inventory tiles are neutral; acknowledged values recede.
struct TileColors {
    let background: Color
    let foreground: Color

    static let neutral = TileColors(background: Color(hex: 0xffffff, dark: 0x252927), foreground: Palette.ink2)
    static let muted = TileColors(background: Palette.chip, foreground: Palette.tertiary)

    static func forEntry(_ entry: InventoryEntry) -> TileColors {
        entry.acknowledgement != nil ? muted : neutral
    }
}

struct ValueTile: View {
    let text: String
    let colors: TileColors
    var size: CGFloat = 28

    var body: some View {
        Text(text)
            .font(.system(size: size * (text.count > 2 ? 0.33 : 0.36), weight: .bold))
            .tracking(0.2)
            .foregroundStyle(colors.foreground)
            .frame(width: size, height: size)
            .background(colors.background, in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size / 4, style: .continuous).strokeBorder(Palette.shade.opacity(0.06), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

struct StatusDot: View {
    let color: Color
    var outlined = false
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(outlined ? Color.clear : color)
            .overlay { if outlined { Circle().strokeBorder(Palette.ring, lineWidth: 1.5) } }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct SignalBars: View {
    let strong: Bool
    var heights: [CGFloat] = [6, 9, 12]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < (strong ? 3 : 1) ? Palette.ink2 : Color(hex: 0xd3d9d6, dark: 0x4a4e4c))
                    .frame(width: 3, height: height)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Focus rings follow the last input, like the web's `:focus-visible`. With Keyboard navigation on,
/// macOS rings a sheet's first control even when a click opened it; a click hides rings until a key
/// moves focus again.
@MainActor @Observable
final class InputModality {
    static let shared = InputModality()
    private(set) var keyboard = false
    @ObservationIgnored private var monitor: Any?

    /// Tab and the arrow keys.
    private static let focusKeys: Set<UInt16> = [48, 123, 124, 125, 126]

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            let keyboard = event.type == .keyDown
            if keyboard && (!Self.focusKeys.contains(event.keyCode) || event.modifierFlags.contains(.command)) { return event }
            let enteredKeyboard = MainActor.assumeIsolated {
                let modality = InputModality.shared
                guard modality.keyboard != keyboard else { return false }
                modality.keyboard = keyboard
                return keyboard
            }
            guard enteredKeyboard else { return event }
            // Rings are drawn as focus moves, so the key waits until SwiftUI has enabled them.
            nonisolated(unsafe) let held = event
            DispatchQueue.main.async { NSApp.postEvent(held, atStart: true) }
            return nil
        }
    }
}

private struct FocusVisible: ViewModifier {
    func body(content: Content) -> some View {
        content.focusEffectDisabled(!InputModality.shared.keyboard)
    }
}

/// The design shows hover feedback on most controls; macOS buttons need it added explicitly.
struct HoverFill: ViewModifier {
    var normal: Color = .clear
    var hover: Color = Palette.shade.opacity(0.05)
    var radius: CGFloat = 7
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? hover : normal, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Shows focus rings only after keyboard use; apply at each window, sheet, and popover root.
    func focusVisible() -> some View {
        modifier(FocusVisible())
    }

    func hoverFill(_ normal: Color = .clear, hover: Color = Palette.shade.opacity(0.05), radius: CGFloat = 7) -> some View {
        modifier(HoverFill(normal: normal, hover: hover, radius: radius))
    }

    func card(radius: CGFloat = 12, ring: Double = 0.08) -> some View {
        background(Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.shade.opacity(ring), lineWidth: 1))
    }
}

struct PressScale: ViewModifier {
    let pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.16), value: pressed)
    }
}

struct FilledButtonStyle: ButtonStyle {
    var destructive = false
    var height: CGFloat = 34
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: height > 30 ? 13 : 12.5, weight: .medium))
            .foregroundStyle(destructive ? .white : Palette.onAccent)
            .padding(.horizontal, height > 30 ? 16 : 12)
            .frame(height: height)
            .background((destructive ? Palette.destructive : Palette.accent).opacity(enabled ? 1 : 0.45),
                        in: RoundedRectangle(cornerRadius: height > 30 ? 8 : 6, style: .continuous))
            .shadow(color: Palette.shadow.opacity(0.14), radius: 1, y: 1)
            .contentShape(Rectangle())
            .modifier(PressScale(pressed: configuration.isPressed))
    }
}

struct OutlineButtonStyle: ButtonStyle {
    var height: CGFloat = 34
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: height > 30 ? 13 : 12, weight: .medium))
            .foregroundStyle(Palette.ink.opacity(enabled ? 1 : 0.4))
            .padding(.horizontal, height > 30 ? 16 : 11)
            .frame(height: height)
            .background(configuration.isPressed ? Color(hex: 0xf2f5f3, dark: 0x2e312f) : Palette.surface,
                        in: RoundedRectangle(cornerRadius: height > 30 ? 8 : 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: height > 30 ? 8 : 6, style: .continuous)
                .strokeBorder(Color(hex: 0xced4d1, dark: 0x3a3e3c), lineWidth: 1))
            .contentShape(Rectangle())
            .modifier(PressScale(pressed: configuration.isPressed))
    }
}

/// A borderless control that shows a light fill on hover, like the design's toolbar buttons.
struct QuietButtonStyle: ButtonStyle {
    var foreground: Color = Palette.secondary
    var height: CGFloat = 28
    var horizontalPadding: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5))
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .contentShape(Rectangle())
            .hoverFill(configuration.isPressed ? Palette.shade.opacity(0.08) : .clear, hover: Palette.shade.opacity(0.06))
    }
}

/// Blank header space under the transparent title bar still moves and zooms the window.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseUp(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { super.mouseUp(with: event) }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 12.5))
            .foregroundStyle(.white)
            .lineSpacing(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: 560)
            .background(Color(hex: 0x2c2c2e, dark: 0x3a3e3c), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.shade.opacity(0.08), lineWidth: 1))
            .shadow(color: Palette.shadow.opacity(0.2), radius: 10, y: 6)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

enum DisplayTime {
    /// "14:02" today, "Yesterday", otherwise "Oct 6".
    static func short(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "Today, 14:02", "Yesterday, 18:40", otherwise "Oct 6, 10:15".
    static func full(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }

    static func day(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

func plural(_ count: Int, _ word: String, _ plural: String? = nil) -> String {
    "\(count.formatted()) \(count == 1 ? word : plural ?? word + "s")"
}
