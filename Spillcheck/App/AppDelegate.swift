import AppKit
import SwiftUI

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private lazy var runtime = AppRuntime(model: model)
    private lazy var onboarding = OnboardingWindowController(model: model)
    private var shutdownStarted = false
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusPanel: MenuBarPanel?
    private var lifecycleLogURL: URL?
    /// The status item image is redrawn only when its attention dot changes.
    private var statusAttention: Bool?
    private var lifecycleEvents: [[String: String]] = []

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        #if DEBUG
        app.setActivationPolicy(CommandLine.arguments.contains("--acceptance-vault-owner") ? .prohibited : .regular)
        #else
        app.setActivationPolicy(.regular)
        #endif
        app.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        var previewOnly = false
        // The setup assistant opens on first launch instead of the main window.
        var setupStep: OnboardingStep? = OnboardingWindowController.completed ? nil : .welcome
        #if DEBUG
        let args = CommandLine.arguments
        if args.contains("--acceptance-vault-owner") {
            Task { await SignedRecoveryVaultOwner.run(arguments: args); NSApplication.shared.terminate(nil) }
            return
        }
        // Disposable acceptance vaults exercise the main window, never first-run setup.
        if args.contains("--store-directory") { setupStep = nil }
        // Sample mode never opens the vault or starts collection, so the UI can be reviewed safely.
        if args.contains("--demo") { model.loadDemo(); previewOnly = true; setupStep = nil }
        if let i = args.firstIndex(of: "--demo-setup"), args.indices.contains(i + 1) {
            // Steps are named like "how-it-works" or "choose-agents".
            let step = OnboardingStep.allCases.first { $0.title.lowercased().replacingOccurrences(of: " ", with: "-") == args[i + 1] } ?? .welcome
            model.loadSetupDemo(step: step)
            previewOnly = true
            setupStep = step
        }
        if args.contains("--demo-quiet") { model.loadQuietDemo(); previewOnly = true; setupStep = nil }
        if let i = args.firstIndex(of: "--lifecycle-log"), args.indices.contains(i + 1) {
            lifecycleLogURL = URL(fileURLWithPath: args[i + 1])
        }
        #endif
        NSApplication.shared.mainMenu = makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(toggleStatusPanel)
        model.onMonitoringChanged = { [weak self] in
            guard let self else { return }
            self.record(self.model.monitoringEnabled ? "resumed" : "paused")
            self.refreshStatusItem()
        }
        model.onMonitoringRequested = { [weak self] enabled in
            self?.runtime.requestMonitoring(enabled: enabled)
        }
        model.onQuit = { [weak self] in self?.quit() }
        model.onOpenNotificationSettings = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
        model.onOpenSetup = { [weak self] step in self?.onboarding.show(at: step) }
        onboarding.onFinish = { [weak self] in self?.showInventory() }
        onboarding.statusItemFrame = { [weak self] in self?.visibleStatusItemFrame() }
        onboarding.highlightStatusItem = { [weak self] highlighted in
            guard let self, self.statusPanel?.isVisible != true else { return }
            self.statusItem?.button?.highlight(highlighted)
        }
        runtime.onShowInventory = { [weak self] in self?.showInventory() }
        if !previewOnly { runtime.start() }
        observeStatusItem()
        record("started")
        if let setupStep { onboarding.show(at: setupStep) } else { showInventory() }
        #if DEBUG
        if previewOnly { applyPreviewArguments(args) }
        #endif
    }

    #if DEBUG
    /// Opens a specific sample state, for design review screenshots.
    private func applyPreviewArguments(_ args: [String]) {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        if let label = value("--demo-entry"),
           let summary = model.summaries.first(where: { $0.label == label }) {
            model.selectedEntryID = summary.id
        }
        if args.contains("--demo-expand") { model.expandedOccurrenceID = model.selectedOccurrenceID }
        switch value("--demo-route") {
        case "coverage": model.route = .coverage
        case "general": model.route = .settings(.general)
        case "agents": model.route = .settings(.agents)
        default: break
        }
        if let query = value("--demo-search") { model.searchText = query }
        switch value("--demo-appearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        switch value("--demo-sheet") {
        case "acknowledge": model.detailSheet = .acknowledge
        case "remove": model.detailSheet = .remove
        case "forget": model.detailSheet = .forget
        case "resume": model.selectedOccurrenceID.map { model.detailSheet = .resume($0) }
        default: break
        }
        if args.contains("--demo-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.toggleStatusPanel() }
        }
    }
    #endif

    private func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        let appMenu = NSMenu()
        let open = NSMenuItem(title: "Open \(AppIdentity.name)", action: #selector(showInventory), keyEquivalent: "o")
        open.target = self
        appMenu.addItem(open)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        #if DEBUG
        let sample = NSMenuItem(title: "Show Sample Inventory", action: #selector(showSampleInventory), keyEquivalent: "")
        sample.target = self
        appMenu.addItem(sample)
        #endif
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit \(AppIdentity.name)", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        let top = NSMenuItem(title: AppIdentity.name, action: nil, keyEquivalent: "")
        top.submenu = appMenu
        menu.addItem(top)

        // Text fields and revealed values rely on the standard responder-chain editing commands.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = editMenu
        menu.addItem(edit)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApplication.shared.windowsMenu = windowMenu
        return menu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if onboarding.isVisible { model.openSetup() } else { showInventory() }
        return true
    }

    @objc private func showInventory() {
        statusPanel?.dismiss()
        if window == nil {
            let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
            let size = NSSize(width: min(1240, screen.width - 80), height: min(800, screen.height - 60))
            let newWindow = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            newWindow.title = AppIdentity.name
            newWindow.titleVisibility = .hidden
            newWindow.titlebarAppearsTransparent = true
            // An empty unified toolbar gives the title bar the sidebar header's height, centering the traffic lights.
            let toolbar = NSToolbar(identifier: "inventory")
            toolbar.showsBaselineSeparator = false
            newWindow.toolbar = toolbar
            newWindow.toolbarStyle = .unified
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            newWindow.contentMinSize = NSSize(width: 900, height: 560)
            let hosting = NSHostingView(rootView: InventoryView(model: model))
            // Scrolling content must not grow the window to its full height.
            hosting.sizingOptions = [.minSize]
            newWindow.contentView = hosting
            newWindow.setFrameAutosaveName("SpillcheckInventory")
            if !newWindow.setFrameUsingName("SpillcheckInventory") { newWindow.center() }
            window = newWindow
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        model.windowVisible = true
        record("window-opened")
    }

    @objc private func showSettings() {
        model.route = .settings(.general)
        showInventory()
    }

    #if DEBUG
    @objc private func showSampleInventory() {
        model.loadDemo()
        showInventory()
    }
    #endif

    func windowWillClose(_ notification: Notification) {
        runtime.mask(.windowClose)
        model.windowVisible = false
        record("window-closed-process-retained")
    }

    @objc private func toggleStatusPanel() {
        onboarding.dismissCoachMark()
        if let statusPanel, statusPanel.isVisible {
            statusPanel.dismiss()
            return
        }
        guard let (anchor, screen) = statusPanelAnchor() else { return }
        let panel = statusPanel ?? MenuBarPanel()
        panel.onClose = { [weak self] in self?.statusItem?.button?.highlight(false) }
        statusPanel = panel
        // A fresh view each time, so hover state from the last opening doesn't linger.
        let content = NSHostingView(rootView: MenuBarView(
            model: model,
            openInventory: { [weak self] in self?.showInventory() },
            openCoverage: { [weak self] in
                self?.model.route = .coverage
                self?.showInventory()
            },
            quit: { [weak self] in self?.quit() },
            close: { [weak panel] in panel?.dismiss() }))
        panel.show(content, below: anchor, on: screen, statusWindow: statusItem?.button?.window)
        statusItem?.button?.highlight(true)
    }

    /// Where the menu bar panel opens: under the status item while it's on screen. A menu bar manager
    /// can keep the item off-screen, and macOS hides items behind the camera housing; then the panel
    /// opens at the top-right of the screen with the pointer.
    private func statusPanelAnchor() -> (NSRect, NSScreen)? {
        if let rect = visibleStatusItemFrame(),
           let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }) {
            return (rect, screen)
        }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return nil }
        return (NSRect(x: screen.visibleFrame.maxX, y: screen.menuBarBottom, width: 0, height: screen.frame.maxY - screen.menuBarBottom), screen)
    }

    /// The status item's screen frame, unless it's off-screen or hidden behind the camera housing.
    private func visibleStatusItemFrame() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let center = NSPoint(x: rect.midX, y: rect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else { return nil }
        let underNotch = screen.auxiliaryTopLeftArea.map { center.x > $0.maxX } == true
            && screen.auxiliaryTopRightArea.map { center.x < $0.minX } == true
        return underNotch ? nil : rect
    }

    /// The status item mirrors values awaiting review; observation keeps it current without polling.
    private func observeStatusItem() {
        withObservationTracking {
            refreshStatusItem()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatusItem() }
        }
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let attention = !model.needsReview.isEmpty || model.notificationIndicatorCount > 0
        if statusAttention != attention {
            statusAttention = attention
            button.image = Self.statusImage(attention: attention)
        }
        let tip = "\(AppIdentity.name) · \(model.processingText)"
        if button.toolTip != tip { button.toolTip = tip }
        button.setAccessibilityLabel(attention ? "\(AppIdentity.name), values need review" : AppIdentity.name)
    }

    private static func statusImage(attention: Bool) -> NSImage {
        let slot: CGFloat = 18
        guard attention else {
            let image = NSImage(size: NSSize(width: slot, height: slot), flipped: true) { rect in
                NSColor.black.set()
                drawGlyph(in: rect)
                return true
            }
            image.isTemplate = true
            image.accessibilityDescription = AppIdentity.name
            return image
        }
        // A colored dot cannot be a template image, so draw the glyph in the menu bar's text color.
        let image = NSImage(size: NSSize(width: slot + 11, height: slot), flipped: true) { rect in
            NSColor.labelColor.set()
            drawGlyph(in: NSRect(x: 0, y: 0, width: slot, height: slot))
            NSColor(srgbRed: 0.85, green: 0.6, blue: 0.2, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.width - 6, y: rect.height / 2 - 3, width: 6, height: 6)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = AppIdentity.name
        return image
    }

    /// The app icon's detection frame and drop in one color, drawn at 85% like the design's menu bar
    /// glyph. Coordinates are AppIcon.svg's 1024 grid; `rect` is in a flipped (top-down) context.
    private static func drawGlyph(in rect: NSRect) {
        let near: CGFloat = 243.712, far: CGFloat = 780.288, inner: CGFloat = 389.12, outer: CGFloat = 634.88
        let corner: CGFloat = 58.368
        let brackets = NSBezierPath()
        for (start, bend, end) in [
            (NSPoint(x: inner, y: near), NSPoint(x: near, y: near), NSPoint(x: near, y: inner)),
            (NSPoint(x: outer, y: near), NSPoint(x: far, y: near), NSPoint(x: far, y: inner)),
            (NSPoint(x: near, y: outer), NSPoint(x: near, y: far), NSPoint(x: inner, y: far)),
            (NSPoint(x: outer, y: far), NSPoint(x: far, y: far), NSPoint(x: far, y: outer)),
        ] {
            brackets.move(to: start)
            brackets.appendArc(from: bend, to: end, radius: corner)
            brackets.line(to: end)
        }
        brackets.lineWidth = 57.344
        brackets.lineCapStyle = .butt

        // A circle with one square corner, turned so the corner points up.
        let drop = NSBezierPath()
        drop.move(to: NSPoint(x: 512, y: 357.605))
        drop.line(to: NSPoint(x: 602.51, y: 448.114))
        drop.appendArc(withCenter: NSPoint(x: 512, y: 538.624), radius: 128, startAngle: -45, endAngle: 225, clockwise: false)
        drop.close()

        // The design's 18 pt slot holds a 34 pt icon canvas, and the glyph is that canvas at 85%.
        let scale = rect.width / 18 * 34 * 0.85 / 1024
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.midY)
        transform.scale(by: scale)
        transform.translateX(by: -512, yBy: -512)
        transform.concat()
        brackets.stroke()
        drop.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
        if CommandLine.arguments.contains("--acceptance-vault-owner") { return .terminateNow }
        #endif
        guard !shutdownStarted else { return .terminateLater }
        shutdownStarted = true
        runtime.mask(.windowClose)
        Task {
            await runtime.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        record("quit-workers-stopped")
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    private func record(_ event: String) {
        guard let url = lifecycleLogURL else { return }
        lifecycleEvents.append(["event": event, "time": ISO8601DateFormatter().string(from: .now),
            "pid": String(ProcessInfo.processInfo.processIdentifier), "status": model.status])
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: lifecycleEvents, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* Optional synthetic test diagnostics never prevent lifecycle actions. */ }
    }
}
