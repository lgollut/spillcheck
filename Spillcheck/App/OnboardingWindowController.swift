import AppKit
import SwiftUI

/// The setup assistant's window. It opens on first launch and from Settings, and points out the menu
/// bar item while its summary shows.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private static let completedKey = "OnboardingCompleted"

    /// Set once the assistant has been finished or closed, so later launches open the main window.
    static var completed: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }

    private let model: AppModel
    private var window: NSWindow?
    private let coachMark = CoachMarkPanel()
    private var coachMarkShown = false
    private var finishing = false
    /// The menu bar item's frame, while it's visible on screen.
    var statusItemFrame: (() -> NSRect?)?
    var highlightStatusItem: ((Bool) -> Void)?
    /// Opens the main window after the assistant fades out.
    var onFinish: (() -> Void)?

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool { window?.isVisible == true }

    /// Opens the assistant at `step`, or brings an open one forward where the user left it.
    func show(at step: OnboardingStep) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        let window = window ?? makeWindow()
        self.window = window
        // A fresh view on every opening, so each run starts from its own choices.
        let hosting = NSHostingView(rootView: OnboardingView(
            model: model, start: step,
            pointOutMenuBar: { [weak self] show in self?.pointOutMenuBar(show) },
            finish: { [weak self] in self?.finish() }))
        // The view fills the whole window under the transparent title bar; its insets mustn't grow it.
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(NSSize(width: 960, height: 640))
        window.alphaValue = 1
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "\(AppIdentity.name) Setup"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar gives the title bar the sidebar header's height, centering the traffic lights.
        let toolbar = NSToolbar(identifier: "onboarding")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.animationBehavior = .documentWindow
        window.delegate = self
        return window
    }

    /// The window fades and settles slightly as it leaves; the main window opens behind it.
    private func finish() {
        guard !finishing, let window else { return }
        finishing = true
        // Sample runs leave first-launch state alone.
        if !model.isDemo { Self.completed = true }
        model.finishSetup()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let origin = window.frame.origin
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            window.animator().alphaValue = 0
            if !reduceMotion { window.animator().setFrameOrigin(NSPoint(x: origin.x, y: origin.y - 10)) }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.didFadeOut() }
        }
    }

    private func didFadeOut() {
        window?.orderOut(nil)
        window?.contentView = nil
        window?.alphaValue = 1
        finishing = false
        onFinish?()
        // The callout stays a moment longer, so it's clear where Spillcheck went.
        guard coachMarkShown else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !self.isVisible else { return }
            self.dismissCoachMark()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if !model.isDemo { Self.completed = true }
        dismissCoachMark()
        window?.contentView = nil
    }

    private func pointOutMenuBar(_ show: Bool) {
        guard !finishing else { return }
        if show, window?.isVisible == true, let anchor = statusItemFrame?(),
           let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }) {
            coachMarkShown = true
            coachMark.show(below: anchor, on: screen)
            highlightStatusItem?(true)
        } else if !show {
            dismissCoachMark()
        }
    }

    /// Hides the menu bar callout, for instance when the user opens the menu bar item.
    func dismissCoachMark() {
        guard coachMarkShown else { return }
        coachMarkShown = false
        coachMark.dismiss()
        highlightStatusItem?(false)
    }
}

/// A callout under the menu bar item saying that Spillcheck keeps running there once its window closes.
/// The window server draws its shadow from the bubble's shape, so it's never clipped and looks the same
/// whichever app is active; the window itself fades and settles in.
private final class CoachMarkPanel: NSPanel {
    private static let width: CGFloat = 272
    /// Where the arrow's tip sits, measured from the bubble's right edge.
    private static let arrowFromRight: CGFloat = 59

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }

    func show(below anchor: NSRect, on screen: NSScreen) {
        let visible = screen.visibleFrame
        // The arrow points at the item; the bubble stays on screen, reaching mostly to the item's left.
        let x = max(visible.minX + 8, min(anchor.midX - Self.width + Self.arrowFromRight, visible.maxX - Self.width - 8))
        let content = NSHostingView(rootView: CoachMarkView(arrowX: anchor.midX - x))
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        // The arrow's tip sits just under the menu bar, even while the item is still sliding in.
        let top = min(anchor.minY, screen.menuBarBottom) - 4
        let frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        contentView = content
        alphaValue = reduceMotion ? 1 : 0
        setFrame(reduceMotion ? frame : frame.offsetBy(dx: 0, dy: 6), display: true)
        orderFrontRegardless()
        // The shadow follows what's drawn, so it's computed once the bubble is on screen.
        displayIfNeeded()
        invalidateShadow()
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
        guard !reduceMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.42
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            animator().alphaValue = 1
            animator().setFrame(frame, display: true)
        }
    }

    func dismiss() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.orderOut(nil)
                self.contentView = nil
            }
        }
    }
}

private struct CoachMarkView: View {
    let arrowX: CGFloat

    private let fill = Color(hex: 0xffffff, dark: 0x2a2e2c)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(AppIdentity.name) lives up here").font(.system(size: 13, weight: .semibold))
            Text("Open the inventory, pause, or check coverage from the menu bar. Closing the window keeps monitoring on.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 272, alignment: .leading)
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill)
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(fill)
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(45))
                    .offset(x: arrowX - 6, y: -5)
            }
        }
        // Room for the arrow inside the window, which clips anything outside it.
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }
}
