import AppKit
import SwiftUI
import SpillcheckCore

/// Window height of the transparent title bar. The traffic lights sit inside the sidebar header.
let windowHeaderHeight: CGFloat = 52

struct InventoryView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let sidebarWidth: CGFloat = 320

    var body: some View {
        if model.focus != nil {
            FocusView(model: model)
                .ignoresSafeArea()
                .frame(minWidth: 900, minHeight: 560)
                .tint(Palette.link)
                .focusVisible()
                .accessibilityIdentifier("inventory.window")
        } else {
            inbox
        }
    }

    private var inbox: some View {
        let barSummaries: [EntrySummary] = switch contentKind {
        case .detail: model.selectedSummary.map { [$0] } ?? []
        case .selection: model.selectedSummaries
        default: []
        }
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    SidebarView(model: model)
                    if barSummaries.isEmpty, !isSettings {
                        SidebarFooter(model: model)
                            .frame(height: 52)
                            .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
                    }
                }
                .frame(width: sidebarWidth)
                .background(Palette.sidebar)
                Rectangle().fill(Palette.separator).frame(width: 1)
                ZStack {
                    content.id(contentKind).transition(.opacity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.background)
                // Only changes of screen fade; selection changes inside the detail stay immediate.
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: contentKind)
                // Above the bottom row, whatever its height.
                .overlay(alignment: .bottom) {
                    if let toast = model.toast {
                        ToastView(message: toast, undo: model.toastOffersUndo ? { model.undoLastDecision() } : nil)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 16)
                            .transition(.opacity)
                            .accessibilityIdentifier("inventory.toast")
                    }
                }
                .animation(.easeOut(duration: 0.16), value: model.toast)
            }
            if !barSummaries.isEmpty {
                // The sidebar footer and the decision bar share one row: same height, same top edge.
                HStack(spacing: 0) {
                    SidebarFooter(model: model)
                        .frame(width: sidebarWidth)
                        .frame(minHeight: 52, maxHeight: .infinity)
                        .background(Palette.sidebar)
                    Rectangle().fill(Palette.separator).frame(width: 1)
                    DecisionBar(model: model, summaries: barSummaries)
                        .frame(maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xe3e8e5, dark: 0x2e312f)).frame(height: 1) }
                .shadow(color: Palette.shadow.opacity(0.03), radius: 8, y: -6)
            }
        }
        .overlay(alignment: .top) {
            if let message = model.storageMessage {
                HStack(spacing: 12) {
                    Label(message, systemImage: "exclamationmark.shield")
                    if model.canExportStartupDiagnostics { StartupDiagnosticsButton(model: model) }
                }
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Palette.amberSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, windowHeaderHeight + 8)
                    .padding(.leading, sidebarWidth)
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: 900, minHeight: 560)
        .tint(Palette.link)
        .focusVisible()
        .accessibilityIdentifier("inventory.window")
    }

    private var isSettings: Bool { if case .settings = model.route { true } else { false } }

    private enum ContentKind: Hashable {
        case empty(EmptyInventoryState.Kind), coverage, detail, selection, noSelection, settings(SettingsPage)
    }

    /// The screen shown beside the sidebar. With nothing in the inventory, coverage is the first screen.
    private var contentKind: ContentKind {
        switch model.route {
        case .inventory:
            if let empty = EmptyInventoryState(model: model) { return empty.kind == .nothingFound ? .coverage : .empty(empty.kind) }
            if model.multiSelection.count > 1 { return .selection }
            return model.selectedSummary == nil ? .noSelection : .detail
        case .coverage: return .coverage
        case .settings(let page): return .settings(page)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch contentKind {
        case .empty:
            if let empty = EmptyInventoryState(model: model) { EmptyStateView(state: empty, model: model) }
        case .coverage:
            CoverageView(model: model)
        case .detail:
            if let summary = model.selectedSummary { InventoryDetailView(model: model, summary: summary).id(summary.id) }
        case .selection:
            SelectionDetail(model: model)
        case .noSelection:
            BucketEmptyState(model: model)
        case .settings(let page):
            SettingsView(model: model, page: page)
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    let model: AppModel
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if case .settings(let page) = model.route {
                SettingsNavigation(model: model, page: page)
            } else {
                searchRow
                BucketPicker(model: model)
                listHeader
                valueList
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            // Room for the window's traffic lights.
            Color.clear.frame(width: 62, height: 12)
            Text(AppIdentity.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
            Spacer()
            HStack(spacing: 6) {
                StatusDot(color: model.monitoringIndicatorColor)
                Text(model.storageStatusTitle ?? (model.monitoringEnabled ? "Monitoring" : (model.stopped ? "Stopped" : "Paused")))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.secondary)
            .help(model.processingText)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.processingText)
        }
        .padding(.horizontal, 16)
        .frame(height: windowHeaderHeight)
        .background(WindowDragArea())
    }

    private var searchRow: some View {
        @Bindable var model = model
        return HStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.quaternary)
                TextField("Search", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .accessibilityLabel("Search values")
                    .accessibilityIdentifier("inventory.search")
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.quaternary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Palette.shade.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Menu {
                Picker("Agent", selection: $model.agentFilter) {
                    Text("All agents").tag(nil as AgentProvider?)
                    ForEach(AgentProvider.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }
                .pickerStyle(.inline)
                Picker("Sort", selection: $model.sortOrder) {
                    Text("Newest first").tag(InventorySort.latest)
                    Text("Known formats first").tag(InventorySort.confidence)
                }
                .pickerStyle(.inline)
            } label: {
                let active = model.agentFilter != nil || model.sortOrder != .latest
                Image(systemName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? Color(oklch: 0.42, 0.06, 152, dark: 0.8) : Palette.secondary)
                    .frame(width: 30, height: 30)
                    .background(active ? Color(oklch: 0.94, 0.022, 150, dark: 0.32) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            // Borderless menus draw their label in the tint, not its foreground style.
            .tint(model.agentFilter != nil || model.sortOrder != .latest ? Color(oklch: 0.42, 0.06, 152, dark: 0.8) : Palette.secondary)
            .fixedSize()
            .help("Filter and order. Unread values always come first.")
            .accessibilityLabel("Filter and order values")
            .accessibilityIdentifier("inventory.filter.agent")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var listHeader: some View {
        let entries = model.bucketEntries
        let unread = entries.filter(model.isUnread).count
        let noun: String = switch model.bucket {
        case .toReview: "to review"
        case .toRotate: "to rotate"
        case .done: "done"
        }
        return HStack(spacing: 4) {
            HStack(spacing: 4) {
                Text("\(entries.count.formatted()) \(noun)")
                if unread > 0 {
                    Text("·").foregroundStyle(Palette.faint)
                    Text("\(unread.formatted()) unread").foregroundStyle(Palette.link)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if model.bucket != .done, !entries.isEmpty {
                Button { model.startFocus(model.multiSelection.count > 1 ? .selection : .list) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "viewfinder").font(.system(size: 10.5, weight: .semibold))
                        Text("Focus")
                        KeyCap(key: "F")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(QuietButtonStyle(foreground: Palette.secondary, height: 22, horizontalPadding: 6))
                .help("Go through them one at a time, from the top")
                .accessibilityIdentifier("inventory.focus")
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Palette.tertiary)
        .padding(.leading, 20).padding(.trailing, 12)
        .frame(height: 24)
        .padding(.bottom, 4)
    }

    private var valueList: some View {
        let entries = model.bucketEntries
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if entries.isEmpty {
                        Text(model.filtersActive ? "No values match." : "Nothing here.")
                            .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                    ForEach(entries) { summary in
                        InboxRow(model: model, summary: summary, unread: model.isUnread(summary)).id(summary.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .onChange(of: model.selectedEntryID) { _, selected in
                guard let selected else { return }
                proxy.scrollTo(selected)
            }
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "jkntrdzf"), phases: .down) { press in handle(press) }
        .onAppear { listFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Values")
        .accessibilityIdentifier("inventory.list")
    }

    /// J and K move like the arrows; T, N and R decide what's selected to review; D marks it rotated;
    /// F goes through the list, or the selection, in Focus; Command-Z takes the last decision back.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let key = press.characters.lowercased()
        if key == "z" {
            guard press.modifiers == .command, model.undo != nil else { return .ignored }
            model.undoLastDecision()
            return .handled
        }
        guard press.modifiers.isEmpty else { return .ignored }
        switch key {
        case "j": model.moveSelection(by: 1)
        case "k": model.moveSelection(by: -1)
        case "f": model.startFocus(model.multiSelection.count > 1 ? .selection : .list)
        default: return model.decide(byKey: key) ? .handled : .ignored
        }
        return .handled
    }
}

/// The three lists. Each says what still has to happen, with an unread dot when it holds new values.
private struct BucketPicker: View {
    let model: AppModel

    var body: some View {
        let counts = model.bucketCounts
        HStack(spacing: 2) {
            ForEach(InventoryBucket.allCases) { bucket in
                let selected = model.bucket == bucket
                let unread = model.hasUnread(in: bucket)
                Button { model.selectBucket(bucket) } label: {
                    HStack(spacing: 5) {
                        Text(bucket.title).fontWeight(selected ? .semibold : .medium).lineLimit(1)
                        Text((counts[bucket] ?? 0).formatted()).font(.system(size: 11.5)).monospacedDigit()
                            .foregroundStyle(Palette.tertiary)
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected ? Palette.ink : Palette.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(selected ? Palette.surface : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: selected ? Palette.shadow.opacity(0.08) : .clear, radius: 1, y: 1)
                    .overlay(alignment: .topTrailing) {
                        if unread { UnreadDot(size: 6).padding(.top, 4).padding(.trailing, 5) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(bucket.title), \(counts[bucket] ?? 0)\(unread ? ", unread values" : "")")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("inventory.bucket.\(bucket.rawValue)")
            }
        }
        .padding(2)
        .background(Palette.shade.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

struct UnreadDot: View {
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(Palette.green).frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct InboxRow: View {
    let model: AppModel
    let summary: EntrySummary
    let unread: Bool

    private var selected: Bool { model.isSelected(summary.id) }
    private var appearances: String {
        summary.occurrences.isEmpty
            ? (summary.entry.kind == .rememberedDecision ? "Decision only" : "Marker only")
            : "\(summary.occurrences.count.formatted())×"
    }
    /// Done rows lead with the reason; the others with the entry number and how often it appeared.
    private var detail: String {
        if summary.bucket == .done {
            let reason = summary.entry.acknowledgement.map { $0.rawValue.capitalizedFirst }
                ?? summary.decision?.displayName ?? "Done"
            let since = summary.entry.appearancesSinceDecision
            return reason + (summary.nothingKept ? " · nothing kept" : "") + (since > 0 ? " · +\(since.formatted()) since" : "")
        }
        return [summary.label, appearances].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        Button {
            // Command adds or removes a value, Shift selects a range, like Finder.
            let flags = NSEvent.modifierFlags
            model.select(summary.id, gesture: flags.contains(.command) ? .toggle : flags.contains(.shift) ? .range : .single)
        } label: {
            HStack(spacing: 10) {
                ValueTile(text: summary.kind.monogram, colors: TileColors.forEntry(summary.entry))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(summary.kind.shortName).font(.system(size: 13.5, weight: unread ? .semibold : .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(DisplayTime.short(summary.latestActivity)).font(.system(size: 11.5))
                            .foregroundStyle(unread ? Palette.link : Palette.quaternary).monospacedDigit().fixedSize()
                    }
                    HStack(spacing: 6) {
                        if summary.strong, summary.bucket == .toReview {
                            Text("Known format").foregroundStyle(Palette.amberText).fixedSize()
                            Text("·").foregroundStyle(Palette.faint)
                        }
                        Text(detail).lineLimit(1)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.quaternary)
                }
            }
            .foregroundStyle(summary.bucket == .done ? Palette.ink2 : Palette.ink)
            .padding(.vertical, 9).padding(.horizontal, 12)
            .contentShape(Rectangle())
            .hoverFill(selected ? Palette.selection : .clear, hover: selected ? Palette.selection : Palette.shade.opacity(0.04), radius: 10)
            .overlay(alignment: .leading) { if unread { UnreadDot().offset(x: 2) } }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(unread ? "Unread, " : "")\(summary.name), \(summary.bucket == .done ? detail : summary.bucket.title.lowercased()), \(appearances)\(summary.strong ? ", known format" : "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Shown beside the sidebar when the open list has nothing selected, which means it's empty.
private struct BucketEmptyState: View {
    let model: AppModel

    private func copy(toRotate: Int) -> (title: String, detail: String) {
        if model.filtersActive {
            return ("No values match", "Nothing in “\(model.bucket.title)” matches the search or filter.")
        }
        switch model.bucket {
        case .toReview:
            return ("Nothing left to review", toRotate > 0
                ? "\(plural(toRotate, "value")) still \(toRotate == 1 ? "needs" : "need") rotating."
                : "Every value has a decision. New ones will show up here.")
        case .toRotate:
            return ("Nothing to rotate", "Values you mark “Needs rotation” wait here until you mark them rotated or revoked.")
        case .done:
            return ("No decisions yet", "Values you’ve dealt with land here, with the reason.")
        }
    }

    var body: some View {
        let toRotate = model.bucketCounts[.toRotate] ?? 0
        let (title, detail) = copy(toRotate: toRotate)
        VStack(spacing: 12) {
            Image(systemName: model.filtersActive ? "line.3.horizontal.decrease" : "checkmark")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Palette.ink2)
                .frame(width: 56, height: 56)
                .background(Palette.chip, in: Circle())
                .accessibilityHidden(true)
            Text(title).font(.system(size: 17, weight: .semibold)).padding(.top, 4)
            Text(detail).font(.system(size: 13)).lineSpacing(3).foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
            if model.filtersActive {
                Button("Clear search and filters") { model.clearFilters() }
                    .buttonStyle(OutlineButtonStyle(height: 28)).padding(.top, 4)
            } else if model.bucket == .toReview, toRotate > 0 {
                Button("Show values to rotate") { model.selectBucket(.toRotate) }
                    .buttonStyle(OutlineButtonStyle(height: 28)).padding(.top, 4)
            }
        }
        .frame(maxWidth: 400)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Unlock when locked; Hide or Show values and Lock when unlocked.
struct ViewingLockControls: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            if model.viewingUnlocked {
                Button { model.valuesHidden ? model.showValues() : model.hideValues() } label: {
                    Image(systemName: model.valuesHidden ? "eye" : "eye.slash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .hoverFill(hover: Palette.shade.opacity(0.06))
                }
                .buttonStyle(.plain)
                .help(model.valuesHidden ? "Show values. Unlocked, so no prompt." : "Hide values. The app stays unlocked.")
                .accessibilityLabel(model.valuesHidden ? "Show values" : "Hide values")
                .accessibilityIdentifier("inventory.toggle-values")
                Button { model.lockNow() } label: {
                    Label("Lock", systemImage: "lock.open.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background(Palette.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Unlocked. Every value shows with its context until you lock, after 5 min idle, when the window closes, or when the Mac sleeps.")
                .accessibilityLabel("Unlocked. Lock now")
                .accessibilityIdentifier("inventory.lock")
            } else {
                Button { model.onUnlock?() } label: {
                    // Collapses to the lock alone when the coverage word needs the room.
                    ViewThatFits(in: .horizontal) {
                        Label("Unlock…", systemImage: "lock.fill").labelStyle(TightLabelStyle()).fixedSize()
                        Image(systemName: "lock.fill").imageScale(.small)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                    .hoverFill(hover: Palette.shade.opacity(0.06))
                }
                .buttonStyle(.plain)
                .disabled(model.viewingBusy || model.isDemo || !model.storageReady)
                .help("Values, excerpts, titles, and paths stay hidden. Unlock once with Touch ID or your password to show every value with its context.")
                .accessibilityLabel("Values locked. Unlock")
                .accessibilityIdentifier("inventory.unlock")
            }
        }
    }
}

/// Coverage, settings, and the viewing lock. It shares the window's bottom row with the decision bar.
private struct SidebarFooter: View {
    let model: AppModel

    /// Coverage is on screen, either chosen or as the first screen of an empty inventory.
    private var showsCoverage: Bool {
        model.route == .coverage
            || (model.route == .inventory && EmptyInventoryState(model: model)?.kind == .nothingFound)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.route = model.route == .coverage && model.hasEntries ? .inventory : .coverage
            } label: {
                HStack(spacing: 7) {
                    CoverageGlyph(word: model.coverageWord)
                    Text("Coverage").fontWeight(.medium).foregroundStyle(Palette.ink)
                    Text(model.coverageWord == "No recent gaps" ? "No gaps" : model.coverageWord)
                        .foregroundStyle(model.coverageWord == "No recent gaps" ? Palette.secondary : Palette.amberText)
                }
                .fixedSize()
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .contentShape(Rectangle())
                .hoverFill(showsCoverage ? Palette.shade.opacity(0.08) : .clear, hover: Palette.shade.opacity(0.06))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(model.coverageStateText). Open coverage details.")
            .accessibilityAddTraits(showsCoverage ? .isSelected : [])
            .accessibilityIdentifier("inventory.coverage")

            Button { model.route = .settings(.general) } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .hoverFill(hover: Palette.shade.opacity(0.06))
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("inventory.settings")

            Spacer(minLength: 0)
            ViewingLockControls(model: model)
        }
        .padding(.horizontal, 10)
    }
}

struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) { configuration.icon.imageScale(.small); configuration.title }
    }
}

struct CoverageGlyph: View {
    let word: String

    var body: some View {
        Group {
            if word == "No recent gaps" {
                Circle().fill(Palette.green)
            } else {
                Circle()
                    .fill(LinearGradient(stops: [.init(color: Palette.amber, location: 0.5), .init(color: .clear, location: 0.5)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(Circle().strokeBorder(Color(oklch: 0.68, 0.14, 70), lineWidth: 1.5))
            }
        }
        .frame(width: 11, height: 11)
        .accessibilityHidden(true)
    }
}

struct FlowChips<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { content }
            VStack(alignment: .leading, spacing: 6) { content }
        }
    }
}

extension View {
    func chip(background: Color, foreground: Color) -> some View {
        font(.system(size: 11.5))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Empty states

struct EmptyInventoryState {
    enum Kind: Hashable { case storageUnavailable, setup, nothingFound }
    let kind: Kind
    let title: String
    let body: String

    /// Distinguishes unavailable storage, unfinished setup and no detections. With no detections
    /// the coverage screen is shown, which also reports a catch-up in progress.
    @MainActor init?(model: AppModel) {
        if model.storageUnavailable {
            kind = .storageUnavailable
            title = model.inventoryStatusTitle ?? "Inventory unavailable"
            body = model.storageSummaryText ?? "The vault must open before inventory can be read."
            return
        }
        // With entries, an empty or filtered-out list is the open list's own empty state.
        if model.hasEntries { return nil }
        let connected = model.routes.filter(\.collecting).map(\.name)
        if !model.monitoringProven {
            kind = .setup
            title = "Monitoring isn’t proven yet"
            body = model.routes.contains { $0.state == .installedUnverified }
                ? "Hooks are added, but no test prompt has arrived yet. An empty list doesn’t mean nothing leaked."
                : "No agent is connected yet. Until one is, nothing is checked, and an empty list doesn’t mean nothing leaked."
        } else {
            kind = .nothingFound
            title = "Nothing found in analyzed content"
            let analyzed = model.activity.map { "Read \(plural($0.conversationCount, "conversation")) from \(connected.joined(separator: " and ")) in the last 7 days." } ?? ""
            let missing = model.routes.filter { !$0.collecting }.map(\.name)
            body = analyzed + (missing.isEmpty ? " Coverage can still have gaps." : " \(missing.joined(separator: " and ")) \(missing.count == 1 ? "wasn’t" : "weren’t") checked.")
        }
    }
}

private struct EmptyStateView: View {
    let state: EmptyInventoryState
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            glyph
            Text(state.title).font(.system(size: 18, weight: .semibold)).padding(.top, 4)
            Text(state.body)
                .font(.system(size: 13)).lineSpacing(3).foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
            if let action {
                Button(action.label, action: action.perform)
                    .buttonStyle(FilledButtonStyle(height: 28))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: 400)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var glyph: some View {
        let (symbol, background, foreground): (String, Color, Color) = switch state.kind {
        case .storageUnavailable: ("lock.shield", Palette.amberSoft, Palette.amberText)
        case .setup: ("exclamationmark", Color(oklch: 0.94, 0.05, 80, dark: 0.33), Palette.amberText)
        case .nothingFound: ("circle", Palette.chip, Palette.ink2)
        }
        return Image(systemName: symbol)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: 60, height: 60)
            .background(background, in: Circle())
            .accessibilityHidden(true)
    }

    private var action: (label: String, perform: () -> Void)? {
        switch state.kind {
        case .storageUnavailable: nil
        case .setup: ("Continue setup", { model.openSetup() })
        case .nothingFound: ("Agents & coverage", { model.route = .coverage })
        }
    }
}

/// Available from onboarding and the main window when encrypted storage cannot be opened.
struct StartupDiagnosticsButton: View {
    let model: AppModel

    var body: some View {
        Button("Export diagnostics…") { model.performCoverageAction(.exportDiagnostics) }
            .buttonStyle(QuietButtonStyle(foreground: Palette.link, height: 26))
            .disabled(!model.canPerformCoverageAction(.exportDiagnostics))
            .help(DiagnosticsExport.help)
            .accessibilityIdentifier("storage.export-diagnostics")
    }
}

// MARK: - Several selected values

/// Two or more values selected with Command or Shift. The decision bar below applies to all of them.
private struct SelectionDetail: View {
    let model: AppModel

    var body: some View {
        let summaries = model.selectedSummaries
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(summaries.count) values selected")
                        .font(.system(size: 19, weight: .semibold)).tracking(-0.2)
                        .accessibilityAddTraits(.isHeader)
                    Text(model.bucket == .done ? "Change their decisions together below."
                         : "Decide them together below, or go through them one at a time.")
                        .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                }
                if model.bucket != .done {
                    Button { model.startFocus(.selection) } label: {
                        Label("Go through one by one", systemImage: "viewfinder").labelStyle(TightLabelStyle())
                    }
                    .buttonStyle(OutlineButtonStyle(height: 30))
                    .accessibilityIdentifier("inventory.focus-selection")
                }
                VStack(spacing: 0) {
                    ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                        HStack(spacing: 10) {
                            ValueTile(text: summary.kind.monogram, colors: TileColors.forEntry(summary.entry), size: 24)
                            Text(summary.kind.shortName).font(.system(size: 13))
                            Text(summary.label).font(Palette.mono).foregroundStyle(Palette.quaternary)
                            if summary.strong, summary.bucket == .toReview {
                                Text("Known format").font(.system(size: 11.5)).foregroundStyle(Palette.amberText)
                            }
                            Spacer(minLength: 8)
                            Text("\(summary.occurrences.count.formatted())×").font(.system(size: 12))
                                .foregroundStyle(Palette.tertiary).monospacedDigit()
                            Text(DisplayTime.short(summary.latestActivity)).font(.system(size: 12))
                                .foregroundStyle(Palette.quaternary).monospacedDigit().frame(minWidth: 52, alignment: .trailing)
                        }
                        .padding(.horizontal, 14).frame(height: 40)
                        if index < summaries.count - 1 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                    }
                }
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .card(ring: 0.07)
            }
            .padding(.top, 26).padding(.horizontal, 32).padding(.bottom, 32)
        }
        .accessibilityIdentifier("inventory.selection")
    }
}

// MARK: - Focus

/// One value at a time, started from the Inbox. The session's set is fixed when it starts; it ends
/// with a summary, and a review session can continue with the values it sent to To rotate.
private struct FocusView: View {
    let model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        if let session = model.focus {
            let left = model.pending(in: session).count
            VStack(spacing: 0) {
                header(session, left: left)
                Rectangle().fill(Palette.separator).frame(height: 1)
                if session.current != nil, let summary = model.selectedSummary {
                    InventoryDetailView(model: model, summary: summary)
                        .id(summary.id)
                        .frame(maxWidth: 900)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    DecisionBar(model: model, summary: summary, hint: hint(for: summary))
                        .fixedSize(horizontal: false, vertical: true)
                        .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xe3e8e5, dark: 0x2e312f)).frame(height: 1) }
                } else {
                    FocusSummary(model: model, session: session)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Palette.background)
            .overlay(alignment: .bottom) {
                if let toast = model.toast {
                    ToastView(message: toast, undo: model.toastOffersUndo ? { model.undoLastDecision() } : nil)
                        .padding(.horizontal, 24)
                        .padding(.bottom, session.current == nil ? 24 : 110)
                        .transition(.opacity)
                        .accessibilityIdentifier("inventory.toast")
                }
            }
            .animation(.easeOut(duration: 0.16), value: model.toast)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.escape) { model.exitFocus(); return .handled }
            .onKeyPress(.upArrow) { model.moveFocus(by: -1); return .handled }
            .onKeyPress(.downArrow) { model.moveFocus(by: 1); return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: "jkntrdzf"), phases: .down) { press in handle(press) }
            .onAppear { focused = true }
            .accessibilityIdentifier("inventory.focus-session")
        }
    }

    private func header(_ session: FocusSession, left: Int) -> some View {
        let done = session.ids.count - left
        return HStack(spacing: 12) {
            // Room for the window's traffic lights.
            Color.clear.frame(width: 62, height: 12)
            Button { model.exitFocus() } label: {
                Label("Inbox", systemImage: "chevron.left").labelStyle(TightLabelStyle())
                    .font(.system(size: 12.5, weight: .medium))
            }
            .buttonStyle(QuietButtonStyle(height: 26))
            .help("Back to the Inbox (Esc)")
            .accessibilityIdentifier("inventory.focus.exit")
            Text(session.title(left: left)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 12)
            if session.current != nil {
                HStack(spacing: 2) {
                    Button { model.moveFocus(by: -1) } label: { Image(systemName: "chevron.up").frame(width: 24, height: 24) }
                        .buttonStyle(QuietButtonStyle(height: 26, horizontalPadding: 2))
                        .disabled(session.ids.first == session.current)
                        .help("Previous (↑)")
                        .accessibilityLabel("Previous value")
                    Button { model.moveFocus(by: 1) } label: { Image(systemName: "chevron.down").frame(width: 24, height: 24) }
                        .buttonStyle(QuietButtonStyle(height: 26, horizontalPadding: 2))
                        .disabled(session.ids.last == session.current)
                        .help("Next (↓)")
                        .accessibilityLabel("Next value")
                }
            }
            HStack(spacing: 8) {
                ProgressView(value: Double(done), total: Double(max(1, session.ids.count)))
                    .progressViewStyle(.linear)
                    .frame(width: 110)
                    .tint(Palette.green)
                Text("\(done) of \(session.ids.count) done").font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            ViewingLockControls(model: model)
        }
        .padding(.horizontal, 16)
        .frame(height: windowHeaderHeight)
        .background(WindowDragArea())
    }

    private func hint(for summary: EntrySummary) -> String {
        let keys = switch summary.bucket {
        case .toReview: "T, N or R to decide · "
        case .toRotate: "D once rotated · "
        case .done: ""
        }
        return keys + "↑ ↓ previous and next · Esc back to the Inbox · ⌘Z undo"
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let key = press.characters.lowercased()
        if key == "z" {
            guard press.modifiers == .command, model.undo != nil else { return .ignored }
            model.undoLastDecision()
            return .handled
        }
        guard press.modifiers.isEmpty else { return .ignored }
        switch key {
        case "j": model.moveFocus(by: 1)
        case "k": model.moveFocus(by: -1)
        case "f": model.exitFocus()
        default: return model.decide(byKey: key) ? .handled : .ignored
        }
        return .handled
    }
}

/// The end of a session: what became of its values, and where to go next.
private struct FocusSummary: View {
    let model: AppModel
    let session: FocusSession

    var body: some View {
        let outcomes = model.outcomes(of: session)
        let reviewing = session.bucket == .toReview
        let toRotate = reviewing ? model.summaries.filter { session.ids.contains($0.id) && $0.bucket == .toRotate }.count : 0
        VStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Palette.ink2)
                .frame(width: 56, height: 56)
                .background(Palette.chip, in: Circle())
                .accessibilityHidden(true)
            Text("\(plural(session.ids.count, "value")) \(reviewing ? "reviewed" : "handled")")
                .font(.system(size: 17, weight: .semibold)).padding(.top, 4)
            FlowChips {
                ForEach(outcomes, id: \.label) { outcome in
                    Text("\(outcome.count) \(outcome.label)").chip(background: Palette.chip, foreground: Palette.ink2)
                }
            }
            Text(reviewing
                 ? "These decisions cover later appearances too." + (toRotate > 0 ? " What needs rotation waits in To rotate." : "")
                 : "Later appearances of rotated or revoked values show as obsolete, without alerts.")
                .font(.system(size: 13)).lineSpacing(3).foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("Back to Inbox") { model.exitFocus() }
                    .buttonStyle(OutlineButtonStyle(height: 30))
                    .keyboardShortcut(.cancelAction)
                if toRotate > 0 {
                    Button(toRotate == 1 ? "Continue with the one to rotate" : "Continue with the \(toRotate) to rotate") {
                        model.startFocus(.rotationAfterReview)
                    }
                    .buttonStyle(FilledButtonStyle(height: 30))
                    .accessibilityIdentifier("inventory.focus.continue-rotation")
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: 440)
        .padding(40)
    }
}
