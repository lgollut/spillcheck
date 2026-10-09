import SwiftUI
import SpillcheckCore

/// Window height of the transparent title bar. The traffic lights sit inside the sidebar header.
let windowHeaderHeight: CGFloat = 52

struct InventoryView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let sidebarWidth: CGFloat = 320

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
                .frame(width: sidebarWidth)
            Rectangle().fill(Palette.separator).frame(width: 1)
            ZStack {
                content.id(contentKind).transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background)
            // Only changes of screen fade; selection changes inside the detail stay immediate.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: contentKind)
        }
        .overlay(alignment: .top) {
            if let message = model.storageMessage {
                Label(message, systemImage: "exclamationmark.shield")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Palette.amberSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, windowHeaderHeight + 8)
                    .padding(.leading, sidebarWidth)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(message: toast)
                    .padding(.leading, sidebarWidth)
                    .padding(.bottom, 72)
                    .transition(.opacity)
                    .accessibilityIdentifier("inventory.toast")
            }
        }
        .animation(.easeOut(duration: 0.16), value: model.toast)
        .ignoresSafeArea()
        .frame(minWidth: 900, minHeight: 560)
        .tint(Palette.link)
        .focusVisible()
        .accessibilityIdentifier("inventory.window")
    }

    private enum ContentKind: Hashable {
        case empty(EmptyInventoryState.Kind), coverage, detail, noSelection, settings(SettingsPage)
    }

    /// The screen shown beside the sidebar. With nothing in the inventory, coverage is the first screen.
    private var contentKind: ContentKind {
        switch model.route {
        case .inventory:
            if let empty = EmptyInventoryState(model: model) { return empty.kind == .nothingFound ? .coverage : .empty(empty.kind) }
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
        case .noSelection:
            Text("Select a value.").foregroundStyle(Palette.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .settings(let page):
            SettingsView(model: model, page: page)
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    let model: AppModel
    @FocusState private var listFocused: Bool

    private var isSettings: Bool { if case .settings = model.route { true } else { false } }

    var body: some View {
        VStack(spacing: 0) {
            header
            if case .settings(let page) = model.route {
                SettingsNavigation(model: model, page: page)
            } else {
                searchRow
                if let banner = model.bannerSummary { CatchUpBanner(model: model, summary: banner) }
                valueList
                footer
            }
        }
        .background(Palette.sidebar)
    }

    private var header: some View {
        HStack(spacing: 14) {
            // Room for the window's traffic lights.
            Color.clear.frame(width: 62, height: 12)
            Text(AppIdentity.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
            Spacer()
            HStack(spacing: 6) {
                StatusDot(color: model.monitoringEnabled ? Palette.green : Color(hex: 0xa1a1a6))
                Text(model.monitoringEnabled ? "Monitoring" : (model.stopped ? "Stopped" : "Paused"))
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
            } label: {
                Image(systemName: model.agentFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.agentFilter == nil ? Palette.secondary : Color(oklch: 0.42, 0.06, 152, dark: 0.8))
                    .frame(width: 30, height: 30)
                    .background(model.agentFilter == nil ? Color.clear : Color(oklch: 0.94, 0.022, 150, dark: 0.32),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            // Borderless menus draw their label in the tint, not its foreground style.
            .tint(model.agentFilter == nil ? Palette.secondary : Color(oklch: 0.42, 0.06, 152, dark: 0.8))
            .fixedSize()
            .help("Filter: \(model.agentFilter?.displayName ?? "All agents")")
            .accessibilityLabel("Filter by agent")
            .accessibilityIdentifier("inventory.filter.agent")

            Menu {
                Picker("Sort", selection: $model.sortOrder) {
                    Text("Sort by latest").tag(InventorySort.latest)
                    Text("Sort by confidence").tag(InventorySort.confidence)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.sortOrder == .confidence ? Palette.ink : Palette.secondary)
                    .frame(width: 30, height: 30)
                    .background(model.sortOrder == .confidence ? Palette.shade.opacity(0.08) : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(model.sortOrder == .confidence ? Palette.ink : Palette.secondary)
            .fixedSize()
            .help(model.sortOrder == .confidence ? "Sorted by confidence" : "Sorted by latest")
            .accessibilityLabel("Sort values")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var valueList: some View {
        let groups = model.groups
        let showHandled = model.handledExpanded
        return GeometryReader { viewport in ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    if groups.isEmpty {
                        Text(model.hasEntries ? "No values match." : "Nothing found yet.")
                            .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else {
                        GroupHeading(title: "Not rotated yet", count: groups.active.count, top: 4)
                        ForEach(groups.active) { ActiveValueRow(model: model, summary: $0) }
                        if groups.active.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                Text("Nothing left to rotate")
                            }
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0xd3d9d6, dark: 0x404341), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                            .padding(.horizontal, 2)
                        }
                        if !groups.notSecrets.isEmpty {
                            GroupHeading(title: "Not secrets", count: groups.notSecrets.count, top: 14)
                            ForEach(groups.notSecrets) { CompactValueRow(model: model, summary: $0, tail: "Not a secret", dimmed: false) }
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if !groups.handled.isEmpty {
                    // The handled section sits at the bottom of the sidebar when the list leaves room.
                    Spacer(minLength: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        handledToggle(count: groups.handled.count, open: showHandled)
                            .padding(.bottom, 4)
                        if showHandled {
                            ForEach(groups.handled) { summary in
                                CompactValueRow(model: model, summary: summary,
                                                tail: summary.nothingKept ? "Nothing kept" : (summary.entry.acknowledgement?.rawValue.capitalizedFirst ?? ""),
                                                dimmed: true)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
            .frame(minHeight: viewport.size.height, alignment: .top)
        } }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
        .onAppear { listFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Values")
        .accessibilityIdentifier("inventory.list")
    }

    private func handledToggle(count: Int, open: Bool) -> some View {
        Button { model.handledExpanded = !open } label: {
            HStack(spacing: 10) {
                Text("Rotated or revoked").fontWeight(.semibold)
                Text(count.formatted()).monospacedDigit()
                Rectangle().fill(Palette.separator).frame(height: 1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.quaternary)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
            .hoverFill(hover: Palette.shade.opacity(0.04), radius: 8)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }

    /// Coverage is on screen, either chosen or as the first screen of an empty inventory.
    private var showsCoverage: Bool {
        model.route == .coverage
            || (model.route == .inventory && EmptyInventoryState(model: model)?.kind == .nothingFound)
    }

    private var footer: some View {
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
            if model.viewingAuthorized {
                Button { model.maskNow() } label: {
                    Label("Hide values", systemImage: "lock.open.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background(Palette.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Values are visible. Click to mask them again.")
                .accessibilityIdentifier("inventory.mask")
            } else {
                // Collapses to the lock alone when the coverage word needs the room.
                ViewThatFits(in: .horizontal) {
                    Label("Values hidden", systemImage: "lock.fill").labelStyle(TightLabelStyle()).fixedSize()
                    Image(systemName: "lock.fill").imageScale(.small)
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 8)
                .help("Values, excerpts, titles, and paths stay masked until you reveal one with Touch ID")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Values hidden")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
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

private struct GroupHeading: View {
    let title: String
    let count: Int
    let top: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Text(title).fontWeight(.semibold)
            Text(count.formatted()).fontWeight(.medium).monospacedDigit()
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Palette.tertiary)
        .padding(.horizontal, 10)
        .padding(.top, top)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct ActiveValueRow: View {
    let model: AppModel
    let summary: EntrySummary

    private var selected: Bool { model.selectedEntryID == summary.id }
    private var appearances: String {
        summary.occurrences.isEmpty ? "Recognition marker only" : plural(summary.occurrences.count, "appearance")
    }

    var body: some View {
        Button { model.selectEntry(summary.id) } label: {
            HStack(spacing: 10) {
                ValueTile(text: summary.kind.monogram, colors: TileColors.forEntry(summary.entry))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(summary.kind.shortName).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                        Text(summary.label).font(Palette.mono).foregroundStyle(Palette.tertiary).fixedSize()
                        if model.isNew(summary) {
                            Text("New").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.link).fixedSize()
                        }
                    }
                    HStack(spacing: 6) {
                        Text(DisplayTime.short(summary.entry.observedAt)).lineLimit(1)
                        Text("·").foregroundStyle(Palette.faint)
                        Text(appearances).monospacedDigit().fixedSize()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.quaternary)
                }
                Spacer(minLength: 0)
                SignalBars(strong: summary.strong)
                    .help(summary.strong ? "Strong match" : "Ambiguous match")
            }
            .foregroundStyle(Palette.ink)
            .padding(10)
            .contentShape(Rectangle())
            .hoverFill(selected ? Palette.selection : .clear, hover: selected ? Palette.selection : Palette.shade.opacity(0.04), radius: 10)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary.name), \(summary.needsReview ? "\(summary.unreviewed) to review" : "reviewed"), \(appearances), \(summary.strong ? "strong" : "ambiguous") match")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct CompactValueRow: View {
    let model: AppModel
    let summary: EntrySummary
    let tail: String
    let dimmed: Bool

    private var selected: Bool { model.selectedEntryID == summary.id }

    var body: some View {
        Button { model.selectEntry(summary.id) } label: {
            HStack(spacing: 10) {
                ValueTile(text: summary.kind.monogram, colors: TileColors.forEntry(summary.entry), size: 18)
                (Text(summary.kind.shortName + " ") + Text(summary.label).font(Palette.mono).foregroundColor(Palette.quaternary))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(tail).font(.system(size: 11.5)).foregroundStyle(Palette.quaternary).fixedSize()
            }
            .font(.system(size: 13))
            .foregroundStyle(dimmed ? Palette.tertiary : Palette.ink)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
            .hoverFill(selected ? Palette.selection : .clear, hover: selected ? Palette.selection : Palette.shade.opacity(0.04), radius: 8)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary.name), \(tail)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct CatchUpBanner: View {
    let model: AppModel
    let summary: HistoricalAuditSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("While you were away").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { model.dismissedBannerAuditID = summary.audit.id } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            FlowChips {
                if summary.ordinaryValueCount > 0 {
                    HStack(spacing: 5) {
                        StatusDot(color: Palette.amber, size: 6)
                        Text("\(plural(summary.ordinaryValueCount, "new value"))")
                    }
                    .chip(background: Palette.amberSoft, foreground: Palette.amberSoftText)
                }
                if model.notificationState == .denied {
                    Text("Notifications off · none announced").chip(background: Color(hex: 0xeef1ef, dark: 0x292c2a), foreground: Palette.ink2)
                }
                if !model.coverageGaps.isEmpty {
                    Button { model.route = .coverage } label: {
                        HStack(spacing: 4) { Text(plural(model.coverageGaps.count, "gap")); Text("›") }
                            .chip(background: Color(hex: 0xeef1ef, dark: 0x292c2a), foreground: Palette.link)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .card(radius: 10, ring: 0.07)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

private struct FlowChips<Content: View>: View {
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
    enum Kind: Hashable { case setup, nothingFound, noMatch }
    let kind: Kind
    let title: String
    let body: String

    /// Distinguishes unfinished setup, no detections, and filters matching nothing. With no detections
    /// the coverage screen is shown, which also reports a catch-up in progress.
    @MainActor init?(model: AppModel) {
        if model.hasEntries {
            guard model.groups.isEmpty, model.filtersActive else { return nil }
            kind = .noMatch
            title = "No values match"
            let query = model.searchText.trimmingCharacters(in: .whitespaces)
            body = query.isEmpty ? "Nothing matches this agent filter." : "Nothing matches “\(query)”\(model.agentFilter == nil ? "." : " with this filter.")"
            return
        }
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
        case .setup: ("exclamationmark", Color(oklch: 0.94, 0.05, 80, dark: 0.33), Palette.amberText)
        case .nothingFound: ("circle", Palette.chip, Palette.ink2)
        case .noMatch: ("line.3.horizontal.decrease", Palette.chip, Palette.ink2)
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
        case .setup: ("Continue setup", { model.openSetup() })
        case .nothingFound: ("Agents & coverage", { model.route = .coverage })
        case .noMatch: ("Clear search and filters", { model.clearFilters() })
        }
    }
}
