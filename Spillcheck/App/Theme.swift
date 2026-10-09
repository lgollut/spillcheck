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
}

enum Palette {
    static let ink = Color(hex: 0x1c1c1e)
    static let ink2 = Color(hex: 0x3d3d42)
    static let secondary = Color(hex: 0x5f5f65)
    static let tertiary = Color(hex: 0x6e6e73)
    static let quaternary = Color(hex: 0x8e8e93)
    static let faint = Color(hex: 0xc7c7cc)
    static let ring = Color(hex: 0xaeaeb2)
    static let sidebar = Color(hex: 0xf6f6f4)
    static let separator = Color(hex: 0xe4e4e1)
    static let hairline = Color(hex: 0xefefed)
    static let well = Color(hex: 0xf3f3f1)
    static let quiet = Color(hex: 0xf4f4f2)
    static let chip = Color(hex: 0xececea)
    static let link = Color(hex: 0x2f5fb3)
    static let accent = Color(oklch: 0.5, 0.13, 255)
    static let accentHover = Color(oklch: 0.46, 0.13, 255)
    static let focus = Color(oklch: 0.6, 0.13, 255)
    static let selection = Color(oklch: 0.93, 0.028, 255)
    static let selectedRow = Color(oklch: 0.95, 0.02, 255)
    static let amber = Color(oklch: 0.74, 0.14, 70)
    static let amberText = Color(oklch: 0.48, 0.1, 62)
    static let amberSoft = Color(oklch: 0.95, 0.04, 80)
    static let amberSoftText = Color(oklch: 0.42, 0.09, 62)
    static let green = Color(oklch: 0.62, 0.14, 150)
    static let switchOn = Color(oklch: 0.64, 0.13, 155)
    static let red = Color(oklch: 0.5, 0.16, 25)
    static let redDot = Color(oklch: 0.55, 0.17, 25)
    static let readCell = Color(oklch: 0.55, 0.03, 255)
    static let highlight = Color(oklch: 0.92, 0.07, 85)
    static let mono = Font.system(size: 11, design: .monospaced)
}

/// Inventory labels pick one of seven hues so masked values of one type stay distinguishable.
struct TileColors {
    let background: Color
    let foreground: Color

    static let hues: [Double] = [250, 160, 60, 20, 300, 200, 110]
    static let muted = TileColors(background: Palette.chip, foreground: Palette.tertiary)

    static func forEntry(_ entry: InventoryEntry) -> TileColors {
        if entry.acknowledgement != nil { return muted }
        let hue = hues[(entry.label?.index ?? 0) % hues.count]
        return TileColors(background: Color(oklch: 0.92, 0.045, hue), foreground: Color(oklch: 0.4, 0.09, hue))
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
                    .fill(index < (strong ? 3 : 1) ? Palette.ink2 : Color(hex: 0xd6d6d3))
                    .frame(width: 3, height: height)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The design shows hover feedback on most controls; macOS buttons need it added explicitly.
struct HoverFill: ViewModifier {
    var normal: Color = .clear
    var hover: Color = Color.black.opacity(0.05)
    var radius: CGFloat = 7
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? hover : normal, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverFill(_ normal: Color = .clear, hover: Color = Color.black.opacity(0.05), radius: CGFloat = 7) -> some View {
        modifier(HoverFill(normal: normal, hover: hover, radius: radius))
    }

    func card(radius: CGFloat = 12, ring: Double = 0.08) -> some View {
        background(Color.white, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.black.opacity(ring), lineWidth: 1))
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
    var color: Color = Palette.accent
    var height: CGFloat = 34
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: height > 30 ? 13 : 12.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, height > 30 ? 16 : 12)
            .frame(height: height)
            .background(color.opacity(enabled ? 1 : 0.45), in: RoundedRectangle(cornerRadius: height > 30 ? 8 : 6, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
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
            .background(configuration.isPressed ? Color(hex: 0xf4f4f2) : .white,
                        in: RoundedRectangle(cornerRadius: height > 30 ? 8 : 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: height > 30 ? 8 : 6, style: .continuous)
                .strokeBorder(Color.black.opacity(0.14), lineWidth: 1))
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
            .hoverFill(configuration.isPressed ? Color.black.opacity(0.08) : .clear, hover: Color.black.opacity(0.06))
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
            .background(Color(hex: 0x2c2c2e), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 6)
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
