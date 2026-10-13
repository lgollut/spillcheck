import SwiftUI
import SpillcheckCore

struct RouteStatus {
    let text: String
    let color: Color
    let dot: Color
    let outlined: Bool
}

extension AgentRoute {
    /// Owned registration status, as listed in Settings, Coverage, and guided setup. It does not
    /// verify every host using this native home.
    var status: RouteStatus {
        switch state {
        case .connected: RouteStatus(text: "Registration verified", color: Palette.secondary, dot: Palette.green, outlined: false)
        case .installedUnverified where waitingForEvent:
            RouteStatus(text: "Waiting for the test prompt…", color: Palette.amberText, dot: Palette.amber, outlined: false)
        case .installedUnverified: RouteStatus(text: "Installed · not verified", color: Palette.amberText, dot: Palette.amber, outlined: false)
        case .detected: RouteStatus(text: "Found · not connected", color: Palette.secondary, dot: .clear, outlined: true)
        case .unsupported: RouteStatus(text: "Route unavailable", color: Palette.red, dot: Palette.redDot, outlined: false)
        case .unavailable: RouteStatus(text: "Needs repair", color: Palette.red, dot: Palette.redDot, outlined: false)
        case .notDetected: RouteStatus(text: "Not found", color: Palette.secondary, dot: .clear, outlined: true)
        case .notChecked: RouteStatus(text: "Not checked yet", color: Palette.secondary, dot: .clear, outlined: true)
        }
    }

    /// Collection status, as summarized in the menu bar.
    var collectionStatus: RouteStatus {
        if !monitoringActive {
            return RouteStatus(text: "Monitoring paused", color: Palette.secondary, dot: Palette.quaternary, outlined: false)
        }
        switch state {
        case .connected:
            return RouteStatus(text: limitations.isEmpty ? (collecting ? "Live reads available" : "Verified · awaiting content") : "Partial coverage",
                        color: limitations.isEmpty ? Palette.secondary : Palette.amberText,
                        dot: limitations.isEmpty ? Palette.green : Palette.amber, outlined: false)
        case .installedUnverified:
            return RouteStatus(text: waitingForEvent ? "Waiting for the test prompt" : "Installed · not verified yet",
                        color: Palette.amberText, dot: Palette.amber, outlined: false)
        case .unsupported: return RouteStatus(text: "Stopped · route unavailable", color: Palette.red, dot: Palette.redDot, outlined: false)
        case .unavailable: return RouteStatus(text: "Stopped · needs repair", color: Palette.red, dot: Palette.redDot, outlined: false)
        default: return status
        }
    }
}

extension AppModel {
    var monitoringIndicatorColor: Color {
        switch monitoringIndicator {
        case .active: Palette.green
        case .attention: Palette.amber
        case .unavailable, .paused, .waiting: Palette.quaternary
        }
    }
}

struct CoverageView: View {
    let model: AppModel

    private var window: DateInterval { model.activity?.window ?? AnalyzedActivity.recentWindow(endingAt: .now) }
    private var rangeText: String { "\(DisplayTime.day(window.start)) – \(DisplayTime.day(window.end))" }
    private var shownRoutes: [AgentRoute] { model.routes.filter(\.shownInCoverage) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Coverage").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Text("Last 7 days · \(rangeText)").font(.system(size: 12)).foregroundStyle(Palette.quaternary).monospacedDigit()
                Spacer()
                HStack(spacing: 6) {
                    StatusDot(color: model.monitoringIndicatorColor)
                    Text(model.processingText)
                }
                .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, 24)
            .frame(height: windowHeaderHeight)
            .background(WindowDragArea())
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    if model.storageUnavailable {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.coverageStateText)
                                .font(.system(size: 30, weight: .semibold))
                                .accessibilityAddTraits(.isHeader)
                            Text(model.coverageSummaryText)
                                .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                            if model.canExportStartupDiagnostics { StartupDiagnosticsButton(model: model) }
                        }
                    } else {
                        hero
                        totals
                        collectionStorage
                        dailyCoverage
                        if shownRoutes.contains(where: { $0.provider == .codex }) {
                            Text("Codex beta limits: automatic side chats, encrypted subagent instructions, and general hook-injected context are not covered. Readable replies and tool results are analyzed when available. These limits do not clear recorded gaps.")
                                .font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineSpacing(2)
                                .accessibilityIdentifier("coverage.codex-beta-limits")
                        }
                        gaps
                    }
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, 40).padding(.top, 20).padding(.bottom, 48)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityIdentifier("coverage.view")
    }

    /// With an empty inventory this is the main window's first screen, so the headline says what was
    /// found as well as how much was read. Each agent's row shows its own catch-up.
    private var hero: some View {
        let conversations = model.activity?.conversationCount ?? 0
        let nothingFound = (model.hasAnalyzedContent || model.monitoringProven) && !model.hasEntries
        let reading = model.monitoringEnabled && model.catchingUp
        let headline = switch (nothingFound, conversations) {
        case (true, 0): model.catchingUp ? "Reading recent history" : "No conversations analyzed yet"
        // While history is still being read, "nothing found" is only true so far.
        case (true, _): "Nothing found\(reading ? " so far" : "") in \(plural(conversations, "conversation"))"
        default: plural(conversations, "conversation")
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                CoverageGlyph(word: model.coverageWord)
                Text(model.coverageStateText)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(model.coverageWord == "No recent gaps" ? Palette.secondary : Palette.amberText)
            Text(headline)
                .font(.system(size: nothingFound ? 30 : 34, weight: .semibold)).tracking(-0.6).monospacedDigit()
                .accessibilityAddTraits(.isHeader)
            Text(model.coverageSummaryText)
                .monospacedDigit()
                .font(.system(size: 13)).foregroundStyle(Palette.secondary)
        }
    }

    private var totals: some View {
        let collecting = shownRoutes.filter(\.collecting).count
        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 100), spacing: 20, alignment: .leading), count: 4),
                             alignment: .leading, spacing: 20) {
                fact("Live reads ready", "\(collecting) of \(shownRoutes.count)")
                fact("Processing", model.processingShort)
                fact("Catch-up completed", model.lastCatchUp.map { DisplayTime.full($0) } ?? "Not yet")
                fact(model.coverageReport?.isTruncated == true ? "Shown issues" : "Issues", model.coverageGaps.count.formatted())
            }
            if let attempt = model.lastCatchUpAttempt {
                Text("Last catch-up attempt \(DisplayTime.full(attempt))")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var collectionStorage: some View {
        if !model.collectionStorageWarnings.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.collectionStorageWarnings) { warning in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(warning.title).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.amberText).accessibilityAddTraits(.isHeader)
                        Text(warning.detail)
                        Text(warning.countText).monospacedDigit()
                        Text(warning.byteText).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("These lifetime records prevent duplicate findings. Deleting findings does not free this space.")
                    .foregroundStyle(Palette.tertiary)
                Button("Export diagnostics") { model.performCoverageAction(.exportDiagnostics) }
                    .buttonStyle(QuietButtonStyle(foreground: Palette.link, height: 26))
                    .disabled(!model.canPerformCoverageAction(.exportDiagnostics))
            }
            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).card()
            .accessibilityIdentifier("coverage.storage-capacity")
        }
    }

    private var dailyCoverage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Text("Daily coverage").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                HStack(spacing: 12) {
                    legend(DayCell(kind: .read), "Read")
                    legend(DayCell(kind: .nothingSeen), "Nothing seen")
                    legend(DayCell(kind: .notSetUp), "Not set up")
                }
                .accessibilityHidden(true)
                Spacer()
                Button("Manage agents") { model.route = .settings(.agents) }
                    .buttonStyle(QuietButtonStyle(foreground: Palette.link, height: 26))
                    .fontWeight(.medium)
                    .padding(.trailing, -8)
            }
            .padding(.horizontal, 2)
            VStack(spacing: 0) {
                ForEach(Array(model.routes.enumerated()), id: \.element.id) { index, route in
                    routeRow(route)
                        .overlay(alignment: .top) { if index > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) } }
                }
            }
            .card()
        }
    }

    private func legend(_ cell: DayCell, _ label: String) -> some View {
        HStack(spacing: 5) {
            cell.frame(width: 9, height: 9).clipShape(RoundedRectangle(cornerRadius: 2))
            Text(label)
        }
        .font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
    }

    private func routeRow(_ route: AgentRoute) -> some View {
        let calendar = Calendar.current
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: window.start)) }
        let analyzed = model.activity?.analyzedDays(provider: route.provider) ?? []
        let everCollected = route.collecting || !analyzed.isEmpty
        let cells: [DayCell.Kind] = days.map { analyzed.contains($0) ? .read : (everCollected ? .nothingSeen : .notSetUp) }
        let read = cells.filter { $0 == .read }.count
        let status = route.status
        let reading = model.monitoringEnabled && model.catchingUpProviders.contains(route.provider)
        return HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                // Beside the name, so a catch-up starting or ending never shifts the row.
                HStack(spacing: 10) {
                    Text(route.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if reading { ReadingHistoryLabel().transition(.opacity) }
                }
                .animation(.easeOut(duration: 0.25), value: reading)
                HStack(spacing: 6) {
                    StatusDot(color: status.dot, outlined: status.outlined, size: 6)
                    Text(status.text).lineLimit(1)
                }
                .font(.system(size: 11.5)).foregroundStyle(status.color)
                ForEach(route.hostRoutes) { host in
                    Text("\(host.name): \(host.summary)")
                        .font(.system(size: 11.5)).foregroundStyle(host.status == .partial ? Palette.amberText : Palette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(host.acceptanceSummary)
                    if let lastRead = host.lastReadAt {
                        Text("Last read \(DisplayTime.full(lastRead))")
                            .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                ForEach(Array(zip(days, cells)), id: \.0) { day, kind in
                    DayCell(kind: kind).frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .help("\(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(kind.label)")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(route.name): \(status.text). Content analyzed on \(read) of the last 7 days.")
            Text("\(read) of 7").font(.system(size: 12.5)).foregroundStyle(Palette.ink2).monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var gaps: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Gaps").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Export diagnostics…") { model.performCoverageAction(.exportDiagnostics) }
                    .buttonStyle(QuietButtonStyle(foreground: Palette.link, height: 26))
                    .disabled(!model.canPerformCoverageAction(.exportDiagnostics))
                    .help(DiagnosticsExport.help)
            }.padding(.horizontal, 2)
            if model.coverageReport?.isTruncated == true {
                Text("This view reached its record limit. The counts in diagnostics show the full query size; coverage remains incomplete.")
                    .font(.system(size: 12)).foregroundStyle(Palette.amberText)
            }
            VStack(spacing: 0) {
                if model.coverageGaps.isEmpty {
                    Text(model.hasAnalyzedContent || model.monitoringProven
                        ? "No gaps recorded in the last 7 days." : model.coverageSummaryText)
                        .font(.system(size: 12.5)).foregroundStyle(Palette.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.horizontal, 16)
                }
                ForEach(Array(model.coverageGaps.enumerated()), id: \.element.id) { index, gap in
                    gapRow(gap)
                        .overlay(alignment: .top) { if index > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) } }
                }
            }
            .card()
            if !model.recoveredCoverageGaps.isEmpty {
                DisclosureGroup("Recovered · \(model.recoveredCoverageGaps.count)") {
                    VStack(spacing: 0) {
                        ForEach(model.recoveredCoverageGaps) { gapRow($0) }
                    }.card()
                }
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            Text("First and last observed times don’t prove everything in between was seen. A day with nothing seen may simply have had no agent activity. Inventory entries don’t expire.")
                .font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineSpacing(2)
                .padding(.horizontal, 2)
        }
    }

    private func gapRow(_ gap: AppModel.CoverageGapRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill([.recovered, .excluded].contains(gap.state) ? Palette.quaternary : Palette.amber)
                .frame(width: 8, height: 8).padding(.top, 5).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(gap.text).font(.system(size: 12.5)).foregroundStyle(Palette.ink2).lineSpacing(2)
                Text(gap.stateLabel + (gap.count > 1 ? " · \(gap.count) records" : ""))
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.secondary)
                if let first = gap.firstObservedAt {
                    Text("First recorded \(DisplayTime.full(first))"
                         + (gap.lastObservedAt.flatMap { $0 > first ? " · Last recorded \(DisplayTime.full($0))" : nil } ?? ""))
                        .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }
                if let detail = gap.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let action = gap.action {
                Button(action.label) { model.performCoverageAction(action) }
                    .buttonStyle(OutlineButtonStyle(height: 28))
                    .disabled(!model.canPerformCoverageAction(action))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minHeight: 48)
    }
}

/// An agent's catch-up in progress, with motion, so its days and the totals read as still growing.
/// It names the same state as the Processing total, short enough to stay on the name's line.
private struct ReadingHistoryLabel: View {
    var body: some View {
        HStack(spacing: 5) {
            RingSpinner(size: 10)
            Text("Catching up")
        }
        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Brand.greenText)
        .lineLimit(1).fixedSize()
        .help("Reading the last 7 days. Counts and results update as earlier conversations are analyzed.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Catching up: reading the last 7 days")
    }
}

struct DayCell: View {
    enum Kind {
        case read, nothingSeen, notSetUp
        var label: String {
            switch self {
            case .read: "Read"
            case .nothingSeen: "Nothing seen"
            case .notSetUp: "Not set up"
            }
        }
    }
    let kind: Kind

    var body: some View {
        switch kind {
        case .read: Rectangle().fill(Palette.readCell)
        case .nothingSeen: Rectangle().strokeBorder(Color(hex: 0xbbc2be, dark: 0x585c5a), lineWidth: 1).background(Palette.background)
        case .notSetUp: Rectangle().fill(Color(hex: 0xe3e8e5, dark: 0x2e312f))
        }
    }
}
