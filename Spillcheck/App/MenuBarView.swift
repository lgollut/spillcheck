import AppKit
import SwiftUI
import SpillcheckCore

/// The menu bar panel. It's placed under the status item once, as it opens, like a menu. A popover
/// stays attached to the item instead, so it followed the item away when a menu bar manager such as
/// Ice moved it back to its hidden section right after the click.
final class MenuBarPanel: NSPanel {
    var onClose: (() -> Void)?
    private var anchorTop: CGFloat?
    private var monitors: [Any] = []

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { dismiss() }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    // Content that changes while open resizes the panel; its top edge stays under the menu bar.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if let anchorTop { frame.origin.y = anchorTop - frame.height }
        super.setFrame(frame, display: flag)
    }

    /// Opens under `anchor`, left-aligned with it like a status item menu and kept on `screen`.
    /// Clicks in `statusWindow` are left to the status item, which toggles the panel itself.
    func show(_ content: NSView, below anchor: NSRect, on screen: NSScreen, statusWindow: NSWindow?) {
        contentView = content
        let size = content.fittingSize
        let visible = screen.visibleFrame
        // A status item can still be sliding in or being moved; never overlap the menu bar.
        let top = min(anchor.minY, screen.menuBarBottom) - 4
        let x = max(visible.minX + 6, min(anchor.minX, visible.maxX - size.width - 6))
        anchorTop = top
        setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        makeKeyAndOrderFront(nil)
        invalidateShadow()

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self, event.window !== self, event.window !== statusWindow { self.dismiss() }
            return event
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        } as Any)
    }

    func dismiss() {
        guard isVisible else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        anchorTop = nil
        orderOut(nil)
        onClose?()
    }
}

extension NSScreen {
    /// The menu bar's lower edge, also when it hides automatically or is taller around the camera housing.
    var menuBarBottom: CGFloat {
        frame.maxY - max(frame.maxY - visibleFrame.maxY, safeAreaInsets.top, NSStatusBar.system.thickness)
    }
}

struct MenuBarView: View {
    let model: AppModel
    let openInventory: () -> Void
    let openCoverage: () -> Void
    let quit: () -> Void
    let close: () -> Void

    private var shownRoutes: [AgentRoute] { model.routes.filter(\.shownInCoverage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            needsReviewCard
            coverage
            divider
            MenuRow(title: "Open \(AppIdentity.name)", shortcut: "⌘O", action: openInventory)
            MenuRow(title: model.monitoringEnabled ? "Pause Monitoring" : "Resume Monitoring") {
                model.toggleMonitoring()
                close()
            }
            .disabled(!model.storageReady || model.monitoringTransition || model.stopped || model.isDemo)
            divider
            MenuRow(title: "Quit \(AppIdentity.name)", shortcut: "⌘Q", action: quit)
            Text("Quitting stops monitoring. Closing the window doesn’t.")
                .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 5)
        }
        .padding(5)
        .frame(width: 296)
        .background(Color(hex: 0xf9fbfa, dark: 0x1f2321), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.shade.opacity(0.12), lineWidth: 0.5))
        // Like a menu, the panel is pointer-driven; the first button shouldn't wear a focus ring.
        .focusEffectDisabled()
    }

    private var divider: some View {
        Rectangle().fill(Palette.shade.opacity(0.08)).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 4)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppIdentity.name).font(.system(size: 13, weight: .semibold))
                Text(model.processingText).font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
            }
            Spacer()
            HStack(spacing: 6) {
                StatusDot(color: model.monitoringEnabled ? Palette.green : Color(hex: 0xa1a1a6))
                Text(model.monitoringEnabled ? "Monitoring on" : (model.stopped ? "Stopped" : "Paused"))
            }
            .font(.system(size: 12)).foregroundStyle(Palette.ink2)
        }
        .padding(8)
    }

    private var needsReviewCard: some View {
        let values = model.needsReview
        let occurrences = values.reduce(0) { $0 + max($1.unreviewed, $1.unlocated ? 1 : 0) }
        let title = values.isEmpty ? "Nothing awaiting review" : "\(plural(values.count, "value")) need\(values.count == 1 ? "s" : "") review"
        let subtitle = values.isEmpty
            ? (model.monitoringProven ? "In analyzed content. Coverage may be partial." : "Finish setup to start monitoring.")
            : "\(plural(occurrences, "unreviewed occurrence")) · latest \(DisplayTime.short(values[0].entry.observedAt))"
        return Button {
            if model.monitoringProven || !values.isEmpty {
                if let first = values.first { model.selectEntry(first.id) } else { model.route = .inventory }
                openInventory()
            } else {
                close()
                model.openSetup()
            }
        } label: {
            HStack(spacing: 10) {
                StatusDot(color: Palette.amber, outlined: values.isEmpty, size: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.quaternary)
            }
            .padding(10)
            .contentShape(Rectangle())
            .hoverFill(Color(hex: 0xffffff, dark: 0x292c2a), hover: Color(hex: 0xf2f5f3, dark: 0x2e312f), radius: 8)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.shade.opacity(0.1), lineWidth: 0.5))
            .shadow(color: Palette.shadow.opacity(0.05), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
        .padding(.top, 2).padding(.bottom, 4)
        .accessibilityLabel("\(title). \(subtitle)")
    }

    private var coverage: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Coverage").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(shownRoutes.isEmpty ? "Nothing connected" : "\(shownRoutes.filter(\.collecting).count) of \(shownRoutes.count) collecting")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.tertiary).monospacedDigit()
            }
            .padding(.horizontal, 8).padding(.bottom, 4)
            if shownRoutes.isEmpty {
                Button(action: openCoverage) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No agent is being collected").font(.system(size: 12.5, weight: .medium))
                        Text("Connect Codex or Claude Code to start. Until then, nothing is checked.")
                            .font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .contentShape(Rectangle())
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: 0xcdd3d0, dark: 0x404341), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .hoverFill(hover: Palette.shade.opacity(0.04), radius: 8)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
            }
            ForEach(shownRoutes) { route in
                let status = route.collectionStatus
                Button(action: openCoverage) {
                    HStack(spacing: 10) {
                        StatusDot(color: status.dot, outlined: status.outlined, size: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(route.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                            Text(status.text).font(.system(size: 11.5)).foregroundStyle(status.color).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .hoverFill(hover: Palette.shade.opacity(0.05), radius: 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(route.name): \(status.text)")
            }
            ForEach(model.routes.filter { $0.state == .notDetected }) { route in
                Text("\(route.provider.displayName) wasn’t found on this Mac.")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 8).padding(.top, 3)
            }
        }
        .padding(.top, 6).padding(.bottom, 4)
    }
}

private struct MenuRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).font(.system(size: 12)).opacity(0.55) }
            }
            .font(.system(size: 13))
            .foregroundStyle(hovering && enabled ? .white : Palette.ink.opacity(enabled ? 1 : 0.4))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(hovering && enabled ? Color(oklch: 0.47, 0.06, 152) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
        .buttonStyle(.plain)
    }
}
