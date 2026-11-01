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
    @State private var expandedIssues: Set<AppModel.CoverageIssue.ID> = []
    @State private var showsRecovered = false

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
                fact(model.coverageReport?.isTruncated == true ? "Shown issues" : "Issues",
                     model.coverageIssues.filter { !$0.isInProgress }.count.formatted())
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
                Button("Manage agents") { model.route = .settings(model.agentsPage) }
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
            cell.frame(width: 10, height: 10).clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
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
            // History is read by conversation, not by day, so no single day is shown as current.
            // While catching up, a wave crosses the days that may still gain content.
            // The cells are laid out once at a fixed size; only their tint is redrawn every frame, in an
            // overlay, so the wave never asks the page to measure again.
            HStack(spacing: DayCell.spacing) {
                ForEach(Array(zip(days, cells).enumerated()), id: \.element.0) { index, cell in
                    let pending = reading && cell.1 != .read
                    DayCell(kind: cell.1)
                        .frame(width: DayCell.size.width, height: DayCell.size.height)
                        .clipShape(DayCell.segment(index, of: cells.count))
                        .help("\(cell.0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(pending ? "Nothing seen yet" : cell.1.label)")
                }
            }
            .frame(width: DayCell.rowWidth(cells.count), height: DayCell.size.height)
            .overlay {
                MotionClock(paused: !reading, minimumInterval: DayCell.motionInterval) { time in
                    HStack(spacing: DayCell.spacing) {
                        ForEach(Array(cells.enumerated()), id: \.offset) { index, kind in
                            // From 0 to 1, how strongly an unread day shows that its agent is still catching up.
                            let pending = reading && kind != .read ? DayCell.wave(at: time, index: index) : nil
                            Rectangle().fill(Palette.readCell.opacity(pending.map { 0.08 + 0.32 * $0 } ?? 0))
                                .frame(width: DayCell.size.width, height: DayCell.size.height)
                                .clipShape(DayCell.segment(index, of: cells.count))
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(route.name): \(status.text). Content analyzed on \(read) of the last 7 days\(reading ? " so far" : "").")
            Text("\(read) of 7").font(.system(size: 12.5)).foregroundStyle(Palette.ink2).monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// One row per cause. Reads in progress, recovered issues and stated limits follow in groups of
    /// their own, so a long catch-up cannot bury what needs action.
    private var gaps: some View {
        let issues = model.coverageIssues
        let attention = issues.filter { !$0.isInProgress }
        let reading = issues.filter(\.isInProgress)
        let recovered = model.recoveredCoverageIssues
        return VStack(alignment: .leading, spacing: 24) {
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
                if attention.isEmpty {
                    Text(!reading.isEmpty ? "Nothing needs action. Some content is still being read."
                        : model.hasAnalyzedContent || model.monitoringProven
                        ? "No gaps recorded in the last 7 days." : model.coverageSummaryText)
                        .font(.system(size: 12.5)).foregroundStyle(Palette.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.horizontal, 16)
                        .card()
                } else {
                    issueList(attention)
                }
            }
            if !reading.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    groupHeader("In progress") {
                        Text("No action needed").font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                    }
                    issueList(reading)
                }
            }
            if !recovered.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    groupHeader("Recovered · \(recovered.count.formatted())") {
                        Button(showsRecovered ? "Hide" : "Show") { showsRecovered.toggle() }
                            .buttonStyle(QuietButtonStyle(foreground: Palette.link, height: 22, horizontalPadding: 4))
                    }
                    if showsRecovered { issueList(recovered) }
                }
            }
            notAnalyzed
            Text("First and last observed times don’t prove everything in between was seen. A day with nothing seen may simply have had no agent activity. Inventory entries don’t expire.")
                .font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineSpacing(2)
                .padding(.horizontal, 2)
        }
    }

    private func groupHeader(_ title: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 2)
    }

    private func issueList(_ issues: [AppModel.CoverageIssue]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(issues.enumerated()), id: \.element.id) { index, issue in
                issueRow(issue)
                    .overlay(alignment: .top) { if index > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) } }
            }
        }
        .card()
    }

    private enum Indicator { case attention, reading, settled }

    /// Every group's rows share this column, so their text lines up from card to card.
    private func indicator(_ kind: Indicator) -> some View {
        ZStack {
            switch kind {
            case .reading: RingSpinner(minimumInterval: DayCell.motionInterval)
            case .attention, .settled:
                RoundedRectangle(cornerRadius: 2).fill(kind == .attention ? Palette.amber : Palette.quaternary)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    private func issueRow(_ issue: AppModel.CoverageIssue) -> some View {
        let expanded = expandedIssues.contains(issue.id)
        let amount = [issue.amountText, issue.detail ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                indicator(issue.isInProgress ? .reading : issue.id.recovered ? .settled : .attention)
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink2).lineSpacing(2)
                    Text(issue.stateText).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.secondary)
                    if !amount.isEmpty {
                        Text(amount).font(.system(size: 11)).foregroundStyle(Palette.tertiary).monospacedDigit()
                    }
                    if let recorded = recordedText(first: issue.firstObservedAt, last: issue.lastObservedAt) {
                        Text(recorded).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                    }
                    if issue.parts.count > 1 {
                        FlowChips {
                            ForEach(issue.parts) { part in
                                Text("\(part.id) · \(part.amount)").chip(background: Palette.chip, foreground: Palette.secondary)
                            }
                        }
                        .padding(.top, 2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 4) {
                    if let action = issue.action {
                        Button(action.label) { model.performCoverageAction(action) }
                            .buttonStyle(OutlineButtonStyle(height: 28))
                            .disabled(!model.canPerformCoverageAction(action))
                    }
                    if issue.rows.count > 1 {
                        Button(expanded ? "Hide details" : "Show details") {
                            if expanded { expandedIssues.remove(issue.id) } else { expandedIssues.insert(issue.id) }
                        }
                        .buttonStyle(QuietButtonStyle(foreground: Palette.link, height: 22, horizontalPadding: 4))
                    }
                }
            }
            if expanded { issueDetails(issue).padding(.leading, 28) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minHeight: 48)
        .accessibilityElement(children: .contain)
    }

    /// Each source and state separately, with its own retry. Labels shared by every row stay on the issue.
    private func issueDetails(_ issue: AppModel.CoverageIssue) -> some View {
        let sharedSource = issue.parts.count <= 1
        let sharedState = !issue.stateText.contains(" · ")
        return VStack(spacing: 0) {
            ForEach(Array(issue.rows.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.detail ?? (row.sourceLabel.isEmpty ? "Location unknown" : row.sourceLabel))
                            .font(.system(size: 12)).foregroundStyle(Palette.ink2)
                        Text([row.detail == nil || sharedSource ? "" : row.sourceLabel, sharedState ? "" : row.stateLabel,
                              plural(row.count, "record"),
                              recordedText(first: row.firstObservedAt, last: row.lastObservedAt) ?? ""]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let action = row.action, ownAction(action) {
                        let enabled = model.canPerformCoverageAction(action)
                        Button(action.label) { model.performCoverageAction(action) }
                            .buttonStyle(QuietButtonStyle(foreground: Palette.link, height: 22, horizontalPadding: 4))
                            .opacity(enabled ? 1 : 0.45)
                            .disabled(!enabled)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .overlay(alignment: .top) { if index > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) } }
            }
        }
        .card(radius: 8, ring: 0.05)
    }

    /// Diagnostics export already heads the section, so detail rows offer only reads.
    private func ownAction(_ action: CoverageAction) -> Bool {
        switch action {
        case .retrySource, .retrySources, .retryHistory, .manageAgents: true
        case .exportDiagnostics: false
        }
    }

    private func recordedText(first: Date?, last: Date?) -> String? {
        guard let first else { return nil }
        return "First recorded \(DisplayTime.full(first))"
            + (last.flatMap { $0 > first ? " · Last recorded \(DisplayTime.full($0))" : nil } ?? "")
    }

    /// Stated limits rather than failures: no retry can recover this content.
    @ViewBuilder private var notAnalyzed: some View {
        let excluded = model.excludedCoverageCounts
        let codex = shownRoutes.contains { $0.provider == .codex }
        if excluded != nil || codex {
            VStack(alignment: .leading, spacing: 8) {
                groupHeader("Not analyzed by design") {
                    Text("Limits, not failures").font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                }
                VStack(spacing: 0) {
                    if let excluded {
                        limitRow("Images and other non-text content", "Excluded from text analysis", excluded)
                    }
                    if codex {
                        limitRow("Codex beta limits",
                                 "Automatic side chats, encrypted subagent instructions, and general hook-injected context aren’t covered.",
                                 "Readable replies and tool results are analyzed when available. These limits do not clear recorded gaps.")
                            .overlay(alignment: .top) { if excluded != nil { Rectangle().fill(Palette.hairline).frame(height: 1) } }
                            .accessibilityIdentifier("coverage.codex-beta-limits")
                    }
                }
                .card()
            }
        }
    }

    private func limitRow(_ title: String, _ state: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            indicator(.settled)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink2)
                Text(state).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.secondary).lineSpacing(2)
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.tertiary).lineSpacing(2).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// An agent's catch-up in progress, with motion, so its days and the totals read as still growing.
/// It names the same state as the Processing total, short enough to stay on the name's line.
private struct ReadingHistoryLabel: View {
    var body: some View {
        HStack(spacing: 5) {
            RingSpinner(size: 10, minimumInterval: DayCell.motionInterval)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 18, height: 24)
    static let spacing: CGFloat = 3
    /// The fixed width of a row of `count` days, so the row's size never depends on its motion.
    static func rowWidth(_ count: Int) -> CGFloat {
        CGFloat(count) * size.width + CGFloat(max(0, count - 1)) * spacing
    }
    /// Catch-up motion on this page is decoration and doesn't need every frame of a fast display.
    static let motionInterval: TimeInterval = 1.0 / 30

    /// A narrow crest that crosses the week from left to right every 2.4 s, then rests.
    /// Under Reduce Motion the days hold a still tint instead.
    static func wave(at time: Double?, index: Int) -> Double {
        guard let time else { return 0.4 }
        let phase = time / 2.4 - Double(index) * 0.09
        return pow(0.5 - 0.5 * cos(2 * .pi * phase), 3)
    }

    /// The week reads as one bar split into days, not as a row of boxes: only its ends are rounded.
    static func segment(_ index: Int, of count: Int) -> UnevenRoundedRectangle {
        let leading: CGFloat = index == 0 ? 6 : 2, trailing: CGFloat = index == count - 1 ? 6 : 2
        return UnevenRoundedRectangle(topLeadingRadius: leading, bottomLeadingRadius: leading,
            bottomTrailingRadius: trailing, topTrailingRadius: trailing, style: .continuous)
    }

    var body: some View {
        ZStack {
            if kind == .notSetUp {
                Hatch().stroke(Color(hex: 0xd3d9d6, dark: 0x434745), lineWidth: 1)
                    .background(Color(hex: 0xf2f4f3, dark: 0x262927))
            } else {
                Rectangle().fill(Color(hex: 0xe3e8e5, dark: 0x3a3e3c))
            }
            // A day that gains content fills up from the bottom.
            Rectangle().fill(Palette.readCell)
                .scaleEffect(x: 1, y: kind == .read || reduceMotion ? 1 : 0.05, anchor: .bottom)
                .opacity(kind == .read ? 1 : 0)
        }
        .animation(Brand.settle(0.45), value: kind)
    }
}

/// Diagonal stripes, for days when the agent wasn't set up.
private struct Hatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for x in stride(from: rect.minX - rect.height, to: rect.maxX, by: 4) {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
        }
        return path
    }
}
