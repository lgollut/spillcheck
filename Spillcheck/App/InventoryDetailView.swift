import SwiftUI
import SpillcheckCore

struct InventoryDetailView: View {
    let model: AppModel
    let summary: EntrySummary
    @State private var moreOpen = false

    private var entry: InventoryEntry { summary.entry }
    private var disabled: Bool { !model.storageReady || model.actionBusy || model.isDemo }
    private var selectedOccurrence: InventoryOccurrencePresentation? {
        summary.occurrences.first { $0.id == model.selectedOccurrenceID }
    }
    private var quiet: Bool { summary.acknowledged || summary.allFalsePositive }
    private var sheet: Binding<DetailSheet?> { Binding(get: { model.detailSheet }, set: { model.detailSheet = $0 }) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    secretSection.padding(.top, 14)
                    appearances.padding(.top, 14)
                }
                .padding(.top, 26)
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
            WhatToDoFooter(model: model, summary: summary, disabled: disabled, sheet: sheet)
        }
        .sheet(item: Binding(get: { model.detailSheet }, set: { model.detailSheet = $0 }),
               onDismiss: { model.terminalResumeCommand = nil }) { presented in
            ValueActionSheet(model: model, summary: summary, kind: presented)
        }
        .accessibilityIdentifier("inventory.detail")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ValueTile(text: summary.kind.monogram, colors: TileColors.forEntry(entry), size: 44)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(summary.kind.title)
                        .font(.system(size: 19, weight: .semibold)).tracking(-0.2)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Text(summary.label).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.quaternary).fixedSize()
                }
                HStack(spacing: 8) {
                    if let signal = entry.detectorSignal {
                        HStack(spacing: 7) {
                            SignalBars(strong: signal == .strong, heights: [5, 8, 11])
                            Text(signal == .strong ? "Strong match" : "Ambiguous match")
                        }
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .help(entry.evidence.first.map { $0.reason.explanation } ?? "")
                    } else {
                        Text("Recognition marker").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink)
                    }
                    if let rule = entry.evidence.first?.rule.id {
                        Text("·").foregroundStyle(Palette.faint)
                        Text(rule).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Palette.quaternary)
                            .lineLimit(1).truncationMode(.middle)
                            .help("Detector rule \(rule)")
                    }
                }
                .font(.system(size: 12.5))
            }
            Spacer(minLength: 0)
            if !actions.isEmpty {
                Button { moreOpen.toggle() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink2)
                        .frame(width: 30, height: 28)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(hex: 0xd8dedb, dark: 0x3a3e3c)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .accessibilityLabel("More actions for this value")
                .popover(isPresented: $moreOpen, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(actions, id: \.title) { action in
                            Button {
                                moreOpen = false
                                model.detailSheet = action.sheet
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.red)
                                    Text(action.detail).font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .hoverFill(hover: Color(light: Color(hex: 0xf2f5f3), dark: .white.opacity(0.08)), radius: 6)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(action.identifier)
                        }
                    }
                    .padding(5)
                    .frame(width: 290)
                    .focusVisible()
                }
                .padding(.top, -2)
            }
        }
    }

    private struct ValueAction {
        let title: String
        let detail: String
        let sheet: DetailSheet
        let identifier: String
    }

    private var actions: [ValueAction] {
        guard entry.fingerprint != nil else { return [] }
        var actions: [ValueAction] = []
        if entry.kind != .rememberedObsoleteMarker {
            actions.append(ValueAction(title: "Remove retained content…",
                detail: summary.acknowledged ? "Deletes value and excerpts. Still recognized as obsolete." : "Deletes value and excerpts. If seen again, it’s new.",
                sheet: .remove, identifier: "inventory.remove-content"))
        }
        if summary.acknowledged {
            actions.append(ValueAction(title: "Forget obsolete recognition…", detail: "Undoes the acknowledgement. May alert again.",
                sheet: .forget, identifier: "inventory.forget-marker"))
        }
        return actions
    }

    // MARK: Secret card

    @ViewBuilder
    private var secretSection: some View {
        if summary.occurrences.isEmpty {
            Text("Recognition marker only. No value kept.")
                .font(.system(size: 12.5)).foregroundStyle(Palette.tertiary)
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: 0xd3d9d6, dark: 0x404341), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    secretValue.frame(maxWidth: .infinity, alignment: .leading)
                    secretControl
                }
                .padding(.leading, 18).padding(.trailing, 14)
                .frame(minHeight: 64)
                .background(quiet ? Palette.quiet : Color(light: Color(oklch: 0.975, 0.02, 80), dark: Color(hex: 0x1d201e)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(quiet ? Palette.shade.opacity(0.05) : Color(light: Color(oklch: 0.9, 0.045, 80), dark: Color(oklch: 0.5, 0.08, 72)), lineWidth: 1))
                .shadow(color: quiet ? .clear : Color(light: Color(oklch: 0.6, 0.1, 70, opacity: 0.25), dark: .clear), radius: 10, y: 6)
                if summary.unlocated {
                    Text("The detector couldn’t locate the exact range, so there’s no value to reveal. Only the source reference is kept.")
                        .font(.system(size: 12)).foregroundStyle(Palette.tertiary).padding(.horizontal, 2)
                }
                if let issue = model.revealIssue {
                    Text(issue == .cancelled ? "Authentication was cancelled. Nothing was revealed." : "Authentication failed. Content stays masked.")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.amberText)
                        .padding(.horizontal, 2)
                        .accessibilityIdentifier("inventory.viewing-message")
                } else if let message = model.viewingMessage, !model.viewingBusy {
                    Text(message).font(.system(size: 12)).foregroundStyle(Palette.tertiary).padding(.horizontal, 2)
                        .accessibilityIdentifier("inventory.viewing-message")
                }
            }
        }
    }

    private var revealedValue: String? {
        guard model.viewingAuthorized, let valueID = entry.valueID else { return nil }
        return model.revealedContent[valueID]
    }

    @ViewBuilder
    private var secretValue: some View {
        if summary.unlocated {
            Text("no exact value located")
                .font(.system(size: 17, design: .monospaced)).tracking(3).foregroundStyle(Palette.secondary)
                .lineLimit(1)
        } else if !entry.canRevealRetainedValue {
            Text("Nothing kept").font(.system(size: 13)).foregroundStyle(Palette.tertiary)
        } else if let value = revealedValue {
            Text(verbatim: value)
                .font(.system(size: 15, design: .monospaced)).lineSpacing(4)
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .padding(.vertical, 16)
                .privacySensitive()
                .accessibilityIdentifier("inventory.revealed-value")
        } else {
            Text("•••• •••• •••• •••• ••••")
                .font(.system(size: 17, design: .monospaced)).tracking(3).foregroundStyle(Palette.secondary)
                .lineLimit(1)
                .accessibilityLabel("Masked value")
                .accessibilityIdentifier("inventory.masked-value")
        }
    }

    @ViewBuilder
    private var secretControl: some View {
        let canReveal = summary.unlocated ? selectedOccurrence?.protectedMetadata != nil : entry.canRevealRetainedValue
        if model.viewingBusy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for Touch ID…")
            }
            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
        } else if canReveal {
            let revealed = model.viewingAuthorized && (revealedValue != nil || summary.unlocated)
            Button {
                if revealed { model.maskNow() } else { model.onReveal?(entry.id, model.selectedOccurrenceID) }
            } label: {
                Label(revealed ? "Hide" : (model.revealIssue != nil ? "Try again" : (summary.unlocated ? "Reveal source…" : "Reveal…")),
                      systemImage: revealed ? "lock.open.fill" : "lock.fill")
                    .labelStyle(TightLabelStyle())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }
            .buttonStyle(QuietButtonStyle(height: 26))
            .padding(.trailing, -6)
            .disabled(disabled)
            .help(revealed ? "Masks after 5 min idle, on close, or when the Mac sleeps" : "Touch ID or password")
            .accessibilityIdentifier(revealed ? "inventory.detail.mask" : "inventory.reveal-value")
        }
    }

    // MARK: Appearances

    private var appearances: some View {
        let count = summary.occurrences.count
        let latest = summary.latestOccurrence
        let times = count == 1 ? "once" : count == 2 ? "twice" : "\(count) times"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(count == 0 ? "No appearances kept" : "Seen \(times) in \(plural(summary.conversationCount, "conversation"))")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let latest {
                    Text(count == 1 ? DisplayTime.full(latest) : "Latest \(DisplayTime.full(latest).lowercasedFirstWordIfRelative)")
                        .font(.system(size: 12)).foregroundStyle(Palette.tertiary).monospacedDigit()
                }
            }
            .padding(.horizontal, 2)
            if count == 0 {
                HStack(spacing: 12) {
                    Text("∅").font(.system(size: 13)).foregroundStyle(Palette.quaternary)
                        .frame(width: 30, height: 30)
                        .overlay(Circle().strokeBorder(Palette.ring, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])))
                    Text("Recognition marker only. If it appears again: listed as obsolete, source and time only, no alert.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(2)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0xd1d7d4, dark: 0x404341), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            } else {
                ForEach(conversationGroups, id: \.conversation.id) { group in
                    ConversationCard(model: model, summary: summary, conversation: group.conversation,
                                     occurrences: group.occurrences, disabled: disabled, sheet: sheet)
                }
            }
        }
    }

    private var conversationGroups: [(conversation: InventoryConversation, occurrences: [InventoryOccurrencePresentation])] {
        var order: [SessionIdentity] = []
        var grouped: [SessionIdentity: [InventoryOccurrencePresentation]] = [:]
        for occurrence in summary.occurrences {
            if grouped[occurrence.conversation.id] == nil { order.append(occurrence.conversation.id) }
            grouped[occurrence.conversation.id, default: []].append(occurrence)
        }
        // Conversations stay newest first; within one, appearances read in the order they happened.
        return order.compactMap { id in
            grouped[id].flatMap { list in
                list.first.map { ($0.conversation, list.sorted { $0.observedAt < $1.observedAt }) }
            }
        }
    }
}

private extension String {
    var lowercasedFirstWordIfRelative: String {
        hasPrefix("Today") || hasPrefix("Yesterday") ? prefix(1).lowercased() + dropFirst() : self
    }
}

// MARK: - Conversation card

private struct ConversationCard: View {
    let model: AppModel
    let summary: EntrySummary
    let conversation: InventoryConversation
    let occurrences: [InventoryOccurrencePresentation]
    let disabled: Bool
    @Binding var sheet: DetailSheet?

    private var agentLabel: String {
        let interface = occurrences.compactMap(\.interface).first
        return conversation.provider.displayName + (interface.map { $0 == .t3 ? " in T3" : $0 == .desktopCode ? " Desktop" : " CLI" } ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(conversation.label.text).font(.system(size: 12.5, weight: .semibold))
                Text(agentLabel).font(.system(size: 11)).foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 7).frame(height: 18)
                    .background(Palette.chip, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Spacer()
                Text(plural(occurrences.count, "appearance")).font(.system(size: 11.5)).foregroundStyle(Palette.tertiary).monospacedDigit()
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Color(hex: 0xf9fbfa, dark: 0x1f2321))
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
            ForEach(Array(occurrences.enumerated()), id: \.element.id) { index, occurrence in
                OccurrenceRow(model: model, summary: summary, occurrence: occurrence,
                              isFirst: index == 0, isLast: index == occurrences.count - 1,
                              hasRail: occurrences.count > 1, disabled: disabled, sheet: $sheet)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .card(ring: 0.07)
    }
}

struct SourceStyle {
    let glyph: String
    let label: String
    let background: Color
    let foreground: Color

    init(_ type: ContentType?) {
        switch type {
        case .toolOutput: (glyph, label, background, foreground) = (">_", "Tool output", Color(oklch: 0.94, 0.02, 255, dark: 0.32), Color(oklch: 0.4, 0.07, 255, dark: 0.8))
        case .toolError: (glyph, label, background, foreground) = ("!", "Tool error", Color(oklch: 0.94, 0.035, 25, dark: 0.32), Color(oklch: 0.45, 0.13, 25, dark: 0.8))
        case .userPrompt: (glyph, label, background, foreground) = ("“", "User message", Color(oklch: 0.94, 0.022, 150, dark: 0.32), Color(oklch: 0.4, 0.05, 152, dark: 0.8))
        case .intermediateResponse, .finalResponse:
            (glyph, label, background, foreground) = ("✦", "Model response", Color(oklch: 0.94, 0.03, 300, dark: 0.32), Color(oklch: 0.42, 0.09, 300, dark: 0.8))
        case nil: (glyph, label, background, foreground) = ("•", "Appearance", Color(hex: 0xeef1ef, dark: 0x292c2a), Palette.ink2)
        }
    }
}

private struct OccurrenceRow: View {
    let model: AppModel
    let summary: EntrySummary
    let occurrence: InventoryOccurrencePresentation
    let isFirst: Bool
    let isLast: Bool
    let hasRail: Bool
    let disabled: Bool
    @Binding var sheet: DetailSheet?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var open: Bool { model.expandedOccurrenceID == occurrence.id }
    private var style: SourceStyle { SourceStyle(occurrence.contentType) }
    private var alerted: Bool { if case .alerted(.delivered) = occurrence.alert { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if reduceMotion { model.toggleOccurrence(occurrence.id) }
                else { withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)) { model.toggleOccurrence(occurrence.id) } }
            } label: { rowLabel }
            .buttonStyle(.plain)
            .accessibilityLabel("\(style.label), \(DisplayTime.full(occurrence.observedAt))\(alerted ? ", alerted" : "")")
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows the retained context and source for this appearance.")
            if open {
                OccurrenceDetail(model: model, summary: summary, occurrence: occurrence, disabled: disabled, sheet: $sheet)
                    .padding(.leading, 54).padding(.trailing, 46).padding(.bottom, 16)
            }
        }
        .background(alignment: .topLeading) {
            if hasRail {
                Rectangle().fill(Color(hex: 0xdfe4e1, dark: 0x3a3e3c)).frame(width: 1)
                    .padding(.top, isFirst ? 26 : 0)
                    .frame(maxHeight: isLast ? 26 : .infinity, alignment: .top)
                    .padding(.leading, 27)
            }
        }
        .background(open ? Color(hex: 0xfafbfa, dark: 0x1f2321) : Palette.surface)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Color(hex: 0xeef1ef, dark: 0x242725)).frame(height: 1).padding(.leading, 54) }
        }
    }

    private var rowLabel: some View {
        HStack(spacing: 12) {
            Text(style.glyph)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(style.foreground)
                .frame(width: 28, height: 28)
                .background(style.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .background(open ? Color(hex: 0xfafbfa, dark: 0x1f2321) : Palette.surface, in: RoundedRectangle(cornerRadius: 10).inset(by: -3))
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(style.label).font(.system(size: 13, weight: .medium))
                Text(DisplayTime.full(occurrence.observedAt)).font(.system(size: 11.5)).foregroundStyle(Palette.quaternary).monospacedDigit()
                if alerted {
                    Text("Alerted").font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.amberSoftText)
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(Palette.amberSoft, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .help("A notification was sent for this appearance")
                }
            }
            Spacer(minLength: 8)
            if occurrence.metadataOnly {
                Text("Obsolete · nothing kept").font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
            } else if let review = occurrence.review, review != .unreviewed {
                Text(review == .confirmedSecret ? "Secret" : "Not a secret")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(review == .confirmedSecret ? Palette.onAccent : Palette.ink2)
                    .padding(.horizontal, 7).frame(height: 18)
                    .background(review == .confirmedSecret ? Color(hex: 0x2c2c2e, dark: 0xe1e6e3) : Palette.surface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(review == .confirmedSecret ? .clear : Color(hex: 0xced4d1, dark: 0x3a3e3c)))
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.quaternary)
                .rotationEffect(.degrees(open ? 180 : 0))
                .frame(width: 24, height: 24)
        }
        .padding(.leading, 14).padding(.trailing, 10)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .hoverFill(.clear, hover: Palette.shade.opacity(0.02), radius: 0)
    }
}

private struct OccurrenceDetail: View {
    let model: AppModel
    let summary: EntrySummary
    let occurrence: InventoryOccurrencePresentation
    let disabled: Bool
    @Binding var sheet: DetailSheet?

    private var excerpt: RetainedExcerpt? { model.viewingAuthorized ? model.revealedExcerpts[occurrence.id] : nil }
    private var source: RetainedSourceContext? { model.viewingAuthorized ? model.revealedSourceMetadata[occurrence.id] : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            context
            if let review = occurrence.review {
                ReviewToggle(review: review, disabled: disabled) { model.onReview?(occurrence.id, $0) }
                    .accessibilityIdentifier("inventory.occurrence.\(occurrence.id.uuidString.lowercased()).review")
            }
            routeRow
            Text(alertText).font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
        }
    }

    @ViewBuilder
    private var context: some View {
        if occurrence.metadataOnly {
            Text("Nothing kept for this appearance. Source and time only.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
        } else if let excerpt {
            VStack(alignment: .leading, spacing: 8) {
                Text(highlighted(excerpt.text))
                    .font(.system(size: 12, design: .monospaced)).lineSpacing(3)
                    .foregroundStyle(Palette.ink2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Palette.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .privacySensitive()
                    .accessibilityIdentifier("inventory.occurrence.\(occurrence.id.uuidString.lowercased()).revealed-context")
                sourceLine
                if excerpt.clipped {
                    Text("Excerpt, clipped around this appearance. Not the full conversation.")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                }
            }
        } else if source != nil {
            sourceLine
        } else if occurrence.protectedExcerpt != nil || occurrence.protectedMetadata != nil {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach([0.9, 0.64, 0.78], id: \.self) { width in
                        GeometryReader { proxy in
                            Capsule().fill(Palette.separator).frame(width: proxy.size.width * width, height: 6)
                        }
                        .frame(height: 6)
                    }
                }
                .accessibilityHidden(true)
                Text(summary.unlocated ? "Source masked. Reveal it to read the title and project." : "Context masked. Reveal the value to read it.")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            .padding(12)
            .background(Palette.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityIdentifier("inventory.occurrence.\(occurrence.id.uuidString.lowercased()).masked-context")
        }
        if let failure = occurrence.locationFailure {
            Text(Self.locationMessage(failure)).font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
    }

    @ViewBuilder
    private var sourceLine: some View {
        if let source {
            HStack(spacing: 12) {
                if let title = source.title { Text(verbatim: title) }
                if let path = source.projectPath { Text(verbatim: path).font(.system(size: 11, design: .monospaced)) }
            }
            .font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
            .textSelection(.enabled)
            .privacySensitive()
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        if let entryValue = summary.entry.valueID.flatMap({ model.revealedContent[$0] }), !entryValue.isEmpty,
           let range = attributed.range(of: entryValue) {
            attributed[range].backgroundColor = Palette.highlight
            attributed[range].foregroundColor = Palette.ink
        }
        return attributed
    }

    private struct RouteInfo {
        let chip: String
        let color: Color
        let outlined: Bool
        let text: String
        let openLabel: String?
    }

    private var route: RouteInfo {
        let agent = occurrence.conversation.provider.displayName
        let conversation = occurrence.conversation.label.text
        var info: RouteInfo
        switch source?.openingCapability {
        case .validatedRoute?:
            info = RouteInfo(chip: "Direct link", color: Palette.green, outlined: false,
                             text: "Opens \(conversation) in \(agent).", openLabel: "Open conversation")
        case .unavailable?:
            info = RouteInfo(chip: "Conversation gone", color: Palette.redDot, outlined: false,
                             text: "\(conversation) no longer exists in \(agent). The retained excerpt is still here.", openLabel: nil)
        case .activeSessionRestriction?:
            info = RouteInfo(chip: "In use", color: Palette.amber, outlined: false,
                             text: "This conversation is active and can’t be opened from here.", openLabel: nil)
        case .unverified?, nil:
            switch occurrence.interface {
            case .t3?:
                info = RouteInfo(chip: "Unverified", color: Palette.amber, outlined: false,
                                 text: "T3 may open without landing on this message.", openLabel: "Try opening in T3")
            case .desktopCode?:
                info = RouteInfo(chip: "Unverified", color: Palette.amber, outlined: false,
                                 text: "The desktop app may open without landing on this message.", openLabel: "Try opening")
            case .standaloneCLI?, nil:
                info = RouteInfo(chip: "No direct link", color: Palette.ring, outlined: false,
                                 text: "CLI conversations can’t be opened from here.", openLabel: nil)
            }
        }
        if occurrence.metadataOnly {
            info = RouteInfo(chip: info.chip, color: info.color, outlined: info.outlined,
                             text: info.text + " Nothing retained, so no fallback.", openLabel: info.openLabel)
        }
        return info
    }

    private var canResume: Bool {
        occurrence.protectedMetadata != nil && source?.openingCapability != .unavailable
    }

    private var routeRow: some View {
        let route = route
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                StatusDot(color: route.color)
                Text(route.chip)
            }
            .chip(background: Palette.well, foreground: Palette.ink2)
            Text(route.text).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            if let label = route.openLabel {
                Button(label) {
                    model.selectedOccurrenceID = occurrence.id
                    model.onOpenSource?(occurrence.id)
                }
                .buttonStyle(OutlineButtonStyle(height: 26))
                .disabled(disabled)
                .accessibilityIdentifier("inventory.occurrence.\(occurrence.id.uuidString.lowercased()).open-source")
            }
            if canResume {
                Button("Resume in Terminal…") {
                    model.selectedOccurrenceID = occurrence.id
                    sheet = .resume(occurrence.id)
                }
                .buttonStyle(OutlineButtonStyle(height: 26))
                .disabled(disabled)
                .help("Resuming can send new requests to \(occurrence.conversation.provider == .codex ? "OpenAI" : "Anthropic")")
                .accessibilityIdentifier("inventory.occurrence.\(occurrence.id.uuidString.lowercased()).terminal-resume")
            }
        }
    }

    private var alertText: String {
        let conversation = occurrence.conversation.label.text
        switch occurrence.alert {
        case .alerted(.delivered): return "Alerted · first strong appearance in \(conversation)"
        case .alerted(.pending): return "Alert pending · first strong appearance in \(conversation)"
        case .alerted(.permissionDenied): return "Not announced · notifications are off. First strong appearance in \(conversation)."
        case .alerted(.cancelled): return "Alert withdrawn"
        case .repeatInConversation: return "No alert · repeat in the same conversation"
        case .awaitingReview: return "No alert · ambiguous detections wait for your review"
        case .catchUp: return "No alert · found during catch-up and included in its summary"
        case .obsolete: return "No alert · obsolete value"
        case .unlocated: return "No alert · the exact value wasn’t located"
        case .notAlerted: return "No alert"
        }
    }

    static func locationMessage(_ reason: LocationFailure) -> String {
        switch reason {
        case .unavailableRange: "The detector didn’t provide a usable range."
        case .ambiguousRange: "The detector couldn’t tell which part of the source matched."
        case .invalidEncoding: "The reported range doesn’t match the source encoding."
        case .scannerReportMismatch: "The scanner report couldn’t be matched to the source."
        }
    }
}

/// Review belongs to one appearance. Clicking the selected option again clears it.
private struct ReviewToggle: View {
    let review: OccurrenceReview
    let disabled: Bool
    let onChange: (OccurrenceReview) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("This appearance").font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
            HStack(spacing: 2) {
                option("Secret", .confirmedSecret)
                option("Not a secret", .falsePositive)
            }
            .padding(2)
            .background(Palette.shade.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            if review == .unreviewed {
                Text("Unreviewed").font(.system(size: 11.5)).foregroundStyle(Palette.amberText)
            }
        }
        .disabled(disabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review for this appearance. Click the selected option again to clear.")
    }

    private func option(_ title: String, _ value: OccurrenceReview) -> some View {
        let selected = review == value
        return Button { onChange(selected ? .unreviewed : value) } label: {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(selected ? (value == .confirmedSecret ? Palette.onAccent : Palette.ink) : Palette.tertiary)
                .padding(.horizontal, 9).frame(height: 22)
                .background(selected ? (value == .confirmedSecret ? Color(hex: 0x2c2c2e, dark: 0xe1e6e3) : Color(hex: 0xffffff, dark: 0x3a3e3c)) : .clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: selected && value == .falsePositive ? Palette.shadow.opacity(0.1) : .clear, radius: 1, y: 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - What to do

private struct WhatToDoFooter: View {
    let model: AppModel
    let summary: EntrySummary
    let disabled: Bool
    @Binding var sheet: DetailSheet?

    private var service: String { summary.kind.servicePhrase }
    private var short: String { summary.kind.shortName }

    private var copy: (title: String, body: String, quiet: Bool) {
        let entry = summary.entry
        if let acknowledgement = entry.acknowledgement {
            let date = DisplayTime.day(entry.acknowledgedAt ?? entry.observedAt)
            return ("Marked \(acknowledgement.rawValue) · \(date)",
                    summary.nothingKept ? "Retained content was removed. If this value shows up again, it’s listed as obsolete without an alert."
                        : "If this value shows up again, it’s listed as obsolete without an alert. A replacement is a new value with normal alerts.",
                    true)
        }
        if summary.allFalsePositive {
            return ("You marked this as not a secret", "Nothing to rotate unless you change your mind. New appearances of this value are still checked.", true)
        }
        if summary.unlocated {
            return ("Possible \(short), exact value not located",
                    "Open the appearance below to check its source and decide whether anything needs rotating.", false)
        }
        if entry.detectorSignal == .ambiguous && summary.confirmed == 0 {
            return ("Possibly a real \(short)", "If it’s real, change it at \(service) and confirm here.", false)
        }
        return ("Rotate or revoke this \(short)", "Change it at \(service), then confirm here. Later appearances won’t alert.", false)
    }

    private var canAcknowledge: Bool {
        summary.entry.acknowledgement == nil && !summary.unlocated && summary.entry.fingerprint != nil
    }

    var body: some View {
        let copy = copy
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.title).font(.system(size: 14, weight: .semibold)).tracking(-0.1).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(copy.body).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                    .help(copy.body)
            }
            Spacer(minLength: 0)
            if canAcknowledge {
                HStack(spacing: 8) {
                    Button(summary.allFalsePositive ? "Mark as possible secret" : "Mark as not a secret") {
                        let review: OccurrenceReview = summary.allFalsePositive ? .unreviewed : .falsePositive
                        model.pinnedEntryID = summary.id
                        model.onReviewAll?(summary.reviewable.map(\.id), review)
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(disabled || summary.reviewable.isEmpty)
                    Button("Mark as handled") { sheet = .acknowledge }
                        .buttonStyle(FilledButtonStyle())
                        .disabled(disabled)
                        .help("Confirm you rotated or revoked it")
                        .accessibilityIdentifier("inventory.acknowledge-obsolete")
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 14).padding(.bottom, 16)
        .background(copy.quiet ? Color(hex: 0xf6f8f7, dark: 0x171a19) : Palette.background)
        .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xe3e8e5, dark: 0x2e312f)).frame(height: 1) }
        .shadow(color: Palette.shadow.opacity(0.035), radius: 8, y: -6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What to do")
    }
}

// MARK: - Sheets

enum DetailSheet: Identifiable, Equatable {
    case acknowledge, remove, forget, resume(UUID)
    var id: String {
        switch self {
        case .acknowledge: "acknowledge"
        case .remove: "remove"
        case .forget: "forget"
        case .resume(let id): "resume-\(id)"
        }
    }
}

private struct ValueActionSheet: View {
    let model: AppModel
    let summary: EntrySummary
    let kind: DetailSheet
    @State private var acknowledgement: ObsoleteAcknowledgement = .rotated
    @Environment(\.dismiss) private var dismiss

    private var name: String { summary.name }
    private var service: String { summary.kind.servicePhrase }

    private enum Mark { case removed, kept, caution, info }

    private var resumeOccurrence: InventoryOccurrencePresentation? {
        if case .resume(let id) = kind { return summary.occurrences.first { $0.id == id } }
        return nil
    }

    private var title: String {
        switch kind {
        case .acknowledge: "Acknowledge \(name) as addressed?"
        case .remove: "Remove retained content for \(name)?"
        case .forget: "Forget obsolete recognition for \(name)?"
        case .resume: "Prepare a resume command for \(resumeOccurrence?.conversation.label.text ?? "this conversation")?"
        }
    }

    private var items: [(Mark, String)] {
        let count = summary.reviewable.count
        let provider = resumeOccurrence?.conversation.provider == .claudeCode ? "Anthropic" : "OpenAI"
        switch kind {
        case .acknowledge:
            return [(.kept, "Later appearances of this exact value show as obsolete"), (.kept, "No alerts for them"),
                    (.caution, "Not changed or checked at \(service)"), (.info, "A replacement is a different value with normal alerts")]
        case .remove:
            return [(.removed, "Exact value and \(plural(count, "excerpt"))"), (.removed, "Occurrence history"),
                    (.kept, "Agent histories on this Mac stay untouched"),
                    summary.acknowledged ? (.kept, "Obsolete marker kept. It holds no value.")
                        : (.caution, "Not acknowledged, so a later appearance alerts as new")]
        case .forget:
            return [(.removed, "\(summary.entry.acknowledgement?.rawValue.capitalizedFirst ?? "") acknowledgement and recognition marker"),
                    (.caution, "New appearances are evaluated normally and may alert"),
                    summary.entry.kind == .rememberedObsoleteMarker ? (.kept, "Processed history won’t recreate removed occurrences")
                        : (.kept, "Retained occurrences and reviews stay")]
        case .resume:
            return [(.info, "Shows a command for you to run in Terminal"), (.caution, "Resuming can send new requests to \(provider)"),
                    (.kept, "To only inspect, reveal the retained excerpt instead")]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ValueTile(text: summary.kind.monogram, colors: TileColors.forEntry(summary.entry), size: 38)
                Text(title).font(.system(size: 14, weight: .semibold)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if kind == .acknowledge { acknowledgementChoice }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 10) {
                        markIcon(item.0)
                        Text(item.1).font(.system(size: 12.5))
                    }
                }
            }
            if let occurrence = resumeOccurrence { resumeCommand(occurrence) }
            HStack(spacing: 8) {
                Spacer()
                if resumeOccurrence == nil {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(OutlineButtonStyle(height: 26))
                        .keyboardShortcut(.cancelAction)
                }
                Button(confirmTitle, action: confirm)
                    .buttonStyle(FilledButtonStyle(destructive: kind == .remove || kind == .forget, height: 26))
                    // The resume sheet only informs, so Escape closes it too.
                    .keyboardShortcut(resumeOccurrence == nil ? .defaultAction : .cancelAction)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 18)
        .frame(width: 440)
        .background(Palette.surface)
        .focusVisible()
    }

    private var confirmTitle: String {
        switch kind {
        case .acknowledge: "Acknowledge as \(acknowledgement.rawValue)"
        case .remove: "Remove retained content"
        case .forget: "Forget recognition"
        case .resume: "Done"
        }
    }

    private func confirm() {
        defer { dismiss() }
        guard let fingerprint = summary.entry.fingerprint, model.storageReady, !model.isDemo else { return }
        switch kind {
        case .acknowledge: model.onAcknowledge?(fingerprint, acknowledgement)
        case .remove: model.onRemoveContent?(fingerprint)
        case .forget: model.onForgetMarker?(fingerprint)
        case .resume: break
        }
    }

    private var acknowledgementChoice: some View {
        HStack(spacing: 8) {
            radio(.rotated, "Rotated", "Replaced and invalidated")
            radio(.revoked, "Revoked", "Invalidated, no replacement")
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }

    private func radio(_ value: ObsoleteAcknowledgement, _ title: String, _ detail: String) -> some View {
        let selected = acknowledgement == value
        return Button { acknowledgement = value } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .strokeBorder(selected ? Palette.accent : Color(hex: 0xb8b8bc, dark: 0x636366), lineWidth: selected ? 4.5 : 1.5)
                    .background(Circle().fill(Palette.surface))
                    .frame(width: 14, height: 14)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? Color(oklch: 0.975, 0.01, 150, dark: 0.27) : Palette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Color(oklch: 0.78, 0.04, 150, dark: 0.45) : Color(hex: 0xe0e5e2, dark: 0x2e312f)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func markIcon(_ mark: Mark) -> some View {
        let (symbol, background, foreground): (String, Color, Color) = switch mark {
        case .removed: ("xmark", Color(oklch: 0.94, 0.035, 25, dark: 0.32), Palette.red)
        case .kept: ("checkmark", Color(oklch: 0.94, 0.022, 150, dark: 0.32), Color(oklch: 0.42, 0.06, 152, dark: 0.8))
        case .caution: ("exclamationmark", Color(oklch: 0.94, 0.05, 80, dark: 0.33), Palette.amberText)
        case .info: ("arrow.right", Palette.chip, Palette.ink2)
        }
        return Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(foreground)
            .frame(width: 20, height: 20)
            .background(background, in: Circle())
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func resumeCommand(_ occurrence: InventoryOccurrencePresentation) -> some View {
        let revealed = model.viewingAuthorized && model.revealedSourceMetadata[occurrence.id] != nil
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if revealed, let command = model.terminalResumeCommand {
                    Text(verbatim: command).textSelection(.enabled).privacySensitive()
                } else {
                    Text(occurrence.conversation.provider == .codex ? "codex resume ••••••••••••" : "claude --resume ••••••••••••")
                }
            }
            .font(.system(size: 12.5, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(Color(hex: 0xf5f5f3, dark: 0x262a28), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            if !revealed {
                HStack(spacing: 10) {
                    Text(model.viewingBusy ? "Waiting for Touch ID…" : "The conversation ID is protected.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Button("Unlock to show…") { model.onReveal?(summary.entry.id, occurrence.id) }
                        .buttonStyle(OutlineButtonStyle(height: 24))
                        .disabled(model.viewingBusy || model.isDemo || !model.storageReady)
                }
            } else if let message = model.sourceActionMessages[occurrence.id], model.terminalResumeCommand == nil {
                Text(message).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
        }
        .onAppear { requestCommand(occurrence) }
        .onChange(of: revealed) { _, _ in requestCommand(occurrence) }
    }

    private func requestCommand(_ occurrence: InventoryOccurrencePresentation) {
        guard model.viewingAuthorized, model.revealedSourceMetadata[occurrence.id] != nil, model.terminalResumeCommand == nil else { return }
        model.onTerminalResume?(occurrence.id)
    }
}
