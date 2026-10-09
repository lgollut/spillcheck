import SwiftUI
import SpillcheckCore

struct RouteStatus {
    let text: String
    let color: Color
    let dot: Color
    let outlined: Bool
}

extension AgentRoute {
    /// Connection status, as listed in Settings and Coverage.
    var status: RouteStatus {
        switch state {
        case .connected: RouteStatus(text: "Verified", color: Palette.secondary, dot: Palette.green, outlined: false)
        case .installedUnverified where waitingForEvent:
            RouteStatus(text: "Waiting for an event…", color: Palette.amberText, dot: Palette.amber, outlined: false)
        case .installedUnverified: RouteStatus(text: "Installed · not verified", color: Palette.amberText, dot: Palette.amber, outlined: false)
        case .detected: RouteStatus(text: "Found · not connected", color: Palette.secondary, dot: .clear, outlined: true)
        case .unsupported: RouteStatus(text: "Unsupported version", color: Palette.red, dot: Palette.redDot, outlined: false)
        case .unavailable: RouteStatus(text: "Needs repair", color: Palette.red, dot: Palette.redDot, outlined: false)
        case .notDetected: RouteStatus(text: "Not found", color: Palette.secondary, dot: .clear, outlined: true)
        case .notChecked: RouteStatus(text: "Not checked yet", color: Palette.secondary, dot: .clear, outlined: true)
        }
    }

    /// Collection status, as summarized in the menu bar.
    var collectionStatus: RouteStatus {
        switch state {
        case .connected: RouteStatus(text: "Collecting", color: Palette.secondary, dot: Palette.green, outlined: false)
        case .installedUnverified:
            RouteStatus(text: waitingForEvent ? "Waiting for a first event" : "Installed · not verified yet",
                        color: Palette.amberText, dot: Palette.amber, outlined: false)
        case .unsupported: RouteStatus(text: "Stopped · unsupported version", color: Palette.red, dot: Palette.redDot, outlined: false)
        case .unavailable: RouteStatus(text: "Stopped · needs repair", color: Palette.red, dot: Palette.redDot, outlined: false)
        default: status
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
                    StatusDot(color: model.monitoringEnabled ? Palette.green : Color(hex: 0xa1a1a6))
                    Text(model.processingText)
                }
                .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, 24)
            .frame(height: windowHeaderHeight)
            .background(WindowDragArea())
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    hero
                    totals
                    dailyCoverage
                    gaps
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, 40).padding(.top, 20).padding(.bottom, 48)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityIdentifier("coverage.view")
    }

    private var hero: some View {
        let conversations = model.activity?.conversationCount ?? 0
        let messages = model.activity?.messageCount ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                CoverageGlyph(word: model.coverageWord)
                Text(model.coverageStateText)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(model.coverageWord == "No recent gaps" ? Palette.secondary : Palette.amberText)
            Text(plural(conversations, "conversation"))
                .font(.system(size: 34, weight: .semibold)).tracking(-0.6).monospacedDigit()
            Text(model.monitoringProven ? "\(plural(messages, "message")) analyzed · \(rangeText)" : "Analysis starts once an agent is verified")
                .font(.system(size: 13)).foregroundStyle(Palette.secondary).monospacedDigit()
            if model.processing {
                ProgressView().progressViewStyle(.linear).frame(maxWidth: 320).tint(Palette.green).padding(.top, 8)
            }
        }
    }

    private var totals: some View {
        let collecting = shownRoutes.filter(\.collecting).count
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 100), spacing: 20, alignment: .leading), count: 4),
                         alignment: .leading, spacing: 20) {
            fact("Agents collecting", "\(collecting) of \(shownRoutes.count)")
            fact("Processing", model.processingShort)
            fact("Last catch-up", model.lastCatchUp.map { DisplayTime.full($0) } ?? "Not yet")
            fact("Gaps", model.coverageGaps.count.formatted())
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().lineLimit(1)
        }
        .accessibilityElement(children: .combine)
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
        return HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text(route.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    StatusDot(color: status.dot, outlined: status.outlined, size: 6)
                    Text(status.text).lineLimit(1)
                }
                .font(.system(size: 11.5)).foregroundStyle(status.color)
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
            Text("Gaps").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 2).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                if model.coverageGaps.isEmpty {
                    Text(model.monitoringProven ? "No gaps recorded in the last 7 days." : "No agent is verified yet, so nothing has been collected.")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.horizontal, 16)
                }
                ForEach(Array(model.coverageGaps.enumerated()), id: \.element.id) { index, gap in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 2).fill(Palette.amber).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(gap.text).font(.system(size: 12.5)).foregroundStyle(Palette.ink2).lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let action = gap.action {
                            Button(action.label) { model.route = action.route }
                                .buttonStyle(OutlineButtonStyle(height: 28))
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .frame(minHeight: 48)
                    .overlay(alignment: .top) { if index > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) } }
                }
            }
            .card()
            Text("First and last observed times don’t prove everything in between was seen. A day with nothing seen may simply have had no agent activity. Inventory entries don’t expire.")
                .font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineSpacing(2)
                .padding(.horizontal, 2)
        }
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
