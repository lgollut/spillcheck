import SwiftUI
import SpillcheckCore

/// One value, evidence first: what it is, where it appeared with its context, and every conversation
/// that printed it. The decision bar sits in the window's bottom row, beside the sidebar footer.
struct InventoryDetailView: View {
    let model: AppModel
    let summary: EntrySummary
    @State private var moreOpen = false
    @State private var openConversation: SessionIdentity?

    private var entry: InventoryEntry { summary.entry }
    private var disabled: Bool { !model.storageReady || model.actionBusy || model.isDemo }
    private var shownOccurrence: InventoryOccurrencePresentation? {
        summary.occurrences.first { $0.id == model.selectedOccurrenceID } ?? summary.occurrences.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if summary.occurrences.isEmpty {
                    nothingKept.padding(.top, 22)
                } else {
                    evidence.padding(.top, 22)
                    appearances.padding(.top, 28)
                }
            }
            .padding(.top, 26)
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
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
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(summary.kind.title)
                        .font(.system(size: 19, weight: .semibold)).tracking(-0.2)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    if !summary.label.isEmpty {
                        Text(summary.label).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.quaternary)
                            .fixedSize()
                            .help("Entry number. It tells values apart while they’re hidden.")
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SignalTag(entry: entry)
                    if let why {
                        Text(why).font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
            if !actions.isEmpty { moreButton.padding(.top, -2) }
        }
    }

    private var why: String? {
        if summary.unlocated { return "The detector couldn’t locate the exact value, so only its source is kept." }
        return entry.evidence.first.map { $0.reason.explanation }
    }

    private var moreButton: some View {
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
        if entry.kind != .rememberedObsoleteMarker && entry.kind != .rememberedDecision {
            actions.append(ValueAction(title: "Remove retained content…",
                detail: summary.acknowledged ? "Deletes value and excerpts. Still recognized as obsolete."
                    : summary.decision != nil ? "Deletes value and excerpts. Your decision still applies."
                    : "Deletes value and excerpts. If seen again, it’s new.",
                sheet: .remove, identifier: "inventory.remove-content"))
        }
        if summary.acknowledged {
            actions.append(ValueAction(title: "Forget obsolete recognition…", detail: "Undoes the acknowledgement. May alert again.",
                sheet: .forget, identifier: "inventory.forget-marker"))
        }
        return actions
    }

    // MARK: Evidence

    /// The value in the context of one appearance: the latest, or the one picked below.
    @ViewBuilder
    private var evidence: some View {
        if let occurrence = shownOccurrence {
            let latest = summary.occurrences.max { $0.observedAt < $1.observedAt }?.id
            VStack(alignment: .leading, spacing: 8) {
                Text(occurrence.id == latest ? "Latest appearance" : "Selected appearance")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.tertiary)
                    .padding(.horizontal, 2)
                    .accessibilityAddTraits(.isHeader)
                if !hasProtectedContent || (model.viewingUnlocked && !model.valuesHidden) {
                    EvidenceCard(model: model, summary: summary, occurrence: occurrence)
                } else if model.viewingUnlocked {
                    ProtectionCard(symbol: "eye.slash", title: "Values are hidden",
                                   detail: "Still unlocked, so showing them again needs no Touch ID.") {
                        Button("Show values") { model.showValues() }
                            .buttonStyle(OutlineButtonStyle(height: 30))
                            .accessibilityIdentifier("inventory.detail.show-values")
                    }
                } else {
                    ProtectionCard(symbol: "lock.fill", title: "Unlock to see the value and where it appeared",
                                   detail: "One Touch ID for the session. Every value then shows with its context until you lock, leave it idle for 5 minutes, or the Mac sleeps.") {
                        if model.viewingBusy {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Waiting for Touch ID…")
                            }
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        } else {
                            Button("Unlock…") { model.onUnlock?() }
                                .buttonStyle(FilledButtonStyle(height: 30))
                                .disabled(model.isDemo || !model.storageReady)
                                .accessibilityIdentifier("inventory.detail.unlock")
                        }
                    }
                }
                if let issue = model.revealIssue {
                    Text(issue == .cancelled ? "Authentication was cancelled. Nothing was revealed." : "This content couldn’t be opened. Unlock to try again.")
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

    /// Something to unlock: the value, an excerpt, or a source reference.
    private var hasProtectedContent: Bool {
        entry.canRevealRetainedValue
            || summary.occurrences.contains { $0.protectedExcerpt != nil || $0.protectedMetadata != nil }
    }

    private var nothingKept: some View {
        HStack(spacing: 12) {
            Text("∅").font(.system(size: 13)).foregroundStyle(Palette.quaternary)
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(Palette.ring, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])))
            Text(entry.kind == .rememberedDecision
                 ? "Only your decision is kept, without the value or its appearances. If the value appears again, your decision still applies to it."
                 : "Recognition marker only. If it appears again: listed as obsolete, source and time only, no alert.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: 0xd1d7d4, dark: 0x404341), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
    }

    // MARK: Appearances

    private var appearances: some View {
        let count = summary.occurrences.count
        let times = count == 1 ? "once" : count == 2 ? "twice" : "\(count.formatted()) times"
        let groups = conversationGroups
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                (Text("Seen \(times)").fontWeight(.semibold) + Text(" in \(plural(summary.conversationCount, "conversation"))"))
                    .font(.system(size: 14))
                    .accessibilityAddTraits(.isHeader)
                Text("· " + summary.agents.joined(separator: ", ")).font(.system(size: 12.5)).foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
            VStack(spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.element.conversation.id) { index, group in
                    ConversationRow(model: model, summary: summary, conversation: group.conversation,
                                    occurrences: group.occurrences, shown: shownOccurrence?.id,
                                    open: openConversation == group.conversation.id, disabled: disabled) {
                        openConversation = openConversation == group.conversation.id ? nil : group.conversation.id
                    }
                    if index < groups.count - 1 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .card(ring: 0.07)
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

/// What the match itself says: a distinctive format is very likely real, a generic pattern needs its context.
private struct SignalTag: View {
    let entry: InventoryEntry

    var body: some View {
        let rule = entry.evidence.first?.rule.id
        let (title, detail, background, foreground): (String, String, Color, Color) = switch entry.detectorSignal {
        case .strong?: ("Known format", "A distinctive format, so it’s very likely a real credential.", Palette.amberSoft, Palette.amberSoftText)
        case .ambiguous? where entry.evidence.first?.reason == .recognizedFormat:
            ("Unsure match", "It has a known format, but the detector isn’t confident it’s real, so its context decides.", Palette.chip, Palette.ink2)
        case .ambiguous?: ("Generic pattern", "A generic pattern, so its context decides.", Palette.chip, Palette.ink2)
        case nil: ("Recognition marker", "No detection is kept, only the marker.", Palette.chip, Palette.ink2)
        }
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7).frame(height: 20)
            .background(background, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .fixedSize()
            .help(rule.map { "Rule \($0). \(detail)" } ?? detail)
            .accessibilityLabel("\(title). \(detail)")
    }
}

/// A locked or hidden stand-in for the evidence, with the one control that shows it.
private struct ProtectionCard<Control: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .frame(width: 34, height: 34)
                .background(Palette.chip, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control
        }
        .padding(16)
        .background(Palette.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.shade.opacity(0.06)))
    }
}

/// The selected appearance with its source, its excerpt with the value marked, and the value itself.
private struct EvidenceCard: View {
    let model: AppModel
    let summary: EntrySummary
    let occurrence: InventoryOccurrencePresentation

    private var style: SourceStyle { SourceStyle(occurrence.contentType) }
    private var excerpt: RetainedExcerpt? { model.contentRevealed ? model.revealedExcerpts[occurrence.id] : nil }
    private var source: RetainedSourceContext? { model.contentRevealed ? model.revealedSourceMetadata[occurrence.id] : nil }
    private var value: String? {
        guard model.contentRevealed, let valueID = summary.entry.valueID else { return nil }
        return model.revealedContent[valueID]
    }
    private var opening: Bool { model.viewingUnlocked && !model.valuesHidden && !model.contentRevealed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sourceHeader
            Rectangle().fill(Palette.shade.opacity(0.07)).frame(height: 1)
            if let call = source?.toolCall {
                ToolCallStrip(call: call, projectPath: source?.projectPath)
                Rectangle().fill(Palette.shade.opacity(0.07)).frame(height: 1)
            }
            context
            if let failure = occurrence.locationFailure {
                Text(InventoryDetailView.locationMessage(failure))
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            }
            valueFooter
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .card(ring: 0.08)
    }

    private var sourceHeader: some View {
        HStack(alignment: .top, spacing: 11) {
            Text(style.glyph)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(style.foreground)
                .frame(width: 28, height: 28)
                .background(style.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(style.label).font(.system(size: 12.5, weight: .semibold))
                    Text("·").foregroundStyle(Palette.faint)
                    AgentTile(provider: occurrence.conversation.provider, size: 14)
                    Text(occurrence.conversation.provider.displayName).font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                }
                if let title = source?.title {
                    Text(verbatim: title).font(.system(size: 13)).foregroundStyle(Palette.ink)
                        .lineLimit(2).textSelection(.enabled).privacySensitive()
                } else {
                    Text(occurrence.conversation.label.text).font(.system(size: 13)).foregroundStyle(Palette.ink2)
                }
                if let path = source?.projectPath {
                    Text(verbatim: path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.tertiary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled).privacySensitive()
                }
            }
            Spacer(minLength: 8)
            Text(occurrence.timestampLabel(formattedDate: DisplayTime.full(occurrence.observedAt)))
                .font(.system(size: 11.5)).foregroundStyle(Palette.quaternary).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    @ViewBuilder
    private var context: some View {
        if occurrence.metadataOnly {
            Text("Nothing kept for this appearance. Source and time only.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                .padding(14)
        } else if let excerpt {
            VStack(alignment: .trailing, spacing: 0) {
                Text(highlighted(excerpt.text))
                    .font(.system(size: 12, design: .monospaced)).lineSpacing(3)
                    .foregroundStyle(Palette.ink2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .privacySensitive()
                    .accessibilityIdentifier("inventory.occurrence.\(occurrence.id.uuidString.lowercased()).revealed-context")
                if excerpt.clipped {
                    Text("Clipped around this appearance")
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.tertiary)
                        .padding(.top, 8)
                        .accessibilityLabel("Excerpt clipped around this appearance. Not the full conversation.")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color(hex: 0xfbfcfb, dark: 0x181b19))
        } else if summary.unlocated {
            Text("No exact value was located in this source. Open the conversation to check it.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                .padding(14)
        } else if opening || occurrence.protectedExcerpt != nil {
            VStack(alignment: .leading, spacing: 7) {
                ForEach([0.92, 0.66, 0.8], id: \.self) { width in
                    GeometryReader { proxy in
                        Capsule().fill(Palette.separator).frame(width: proxy.size.width * width, height: 6)
                    }
                    .frame(height: 6)
                }
            }
            .padding(14)
            .accessibilityLabel("Opening the context")
            .accessibilityIdentifier("inventory.occurrence.\(occurrence.id.uuidString.lowercased()).masked-context")
        } else {
            Text("No excerpt was kept for this appearance.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                .padding(14)
        }
    }

    @ViewBuilder
    private var valueFooter: some View {
        if let value {
            HStack(spacing: 10) {
                Text("Value").font(.system(size: 11.5)).foregroundStyle(Palette.quaternary)
                Text(verbatim: value)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .privacySensitive()
                    .padding(.horizontal, 7).frame(height: 22)
                    .background(Palette.chip, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityIdentifier("inventory.revealed-value")
                Spacer(minLength: 8)
                hideButton
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .overlay(alignment: .top) { Rectangle().fill(Palette.shade.opacity(0.07)).frame(height: 1) }
        } else if source != nil || excerpt != nil {
            HStack {
                Text(summary.unlocated ? "No exact value located" : "No value kept")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.quaternary)
                Spacer(minLength: 8)
                hideButton
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .overlay(alignment: .top) { Rectangle().fill(Palette.shade.opacity(0.07)).frame(height: 1) }
        }
    }

    private var hideButton: some View {
        Button { model.hideValues() } label: {
            Label("Hide values", systemImage: "eye.slash").labelStyle(TightLabelStyle())
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(QuietButtonStyle(height: 24))
        .help("Hides values on screen. The app stays unlocked.")
        .accessibilityIdentifier("inventory.detail.hide-values")
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let value, !value.isEmpty else { return attributed }
        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let range = attributed[searchStart...].range(of: value) {
            attributed[range].backgroundColor = Palette.highlight
            attributed[range].foregroundColor = Palette.ink
            searchStart = range.upperBound
        }
        return attributed
    }
}

/// Where a tool output came from, above its excerpt like a file's tab: the files its call read or
/// changed, or the program it ran, and on the right the tool that ran it.
private struct ToolCallStrip: View {
    let call: RetainedToolCall
    let projectPath: String?
    private static let shownPaths = 3

    var body: some View {
        let paths = call.displayPaths(relativeTo: projectPath, home: NSHomeDirectory())
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: paths.isEmpty ? "terminal" : "doc.text")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.tertiary)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if paths.isEmpty {
                    Text(verbatim: call.subject)
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    ForEach(paths.prefix(Self.shownPaths), id: \.self) { path in
                        Text(verbatim: path)
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ink)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(path)
                    }
                    if paths.count > Self.shownPaths {
                        Text("and \(plural(paths.count - Self.shownPaths, "more file"))")
                            .font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                            .help(paths.dropFirst(Self.shownPaths).joined(separator: "\n"))
                    }
                }
            }
            .privacySensitive()
            Spacer(minLength: 12)
            if let method = call.method {
                Text(verbatim: method)
                    .font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                    .lineLimit(1).fixedSize()
                    .help(paths.isEmpty ? "The tool that ran it." : "How the agent read or changed this file.")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.well.opacity(0.6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(paths))
        .accessibilityIdentifier("inventory.detail.tool-call")
    }

    private func accessibilityText(_ paths: [String]) -> String {
        if paths.isEmpty { return "Output of \(call.subject)" + (call.method.map { ", \($0)" } ?? "") }
        return "From " + paths.joined(separator: ", ") + (call.method.map { ", \($0)" } ?? "")
    }
}

/// One conversation that printed the value. Opening it lists its appearances; picking one shows it above.
private struct ConversationRow: View {
    let model: AppModel
    let summary: EntrySummary
    let conversation: InventoryConversation
    let occurrences: [InventoryOccurrencePresentation]
    let shown: UUID?
    let open: Bool
    let disabled: Bool
    let toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var holdsShown: Bool { occurrences.contains { $0.id == shown } }
    /// The conversation's actions use the appearance shown above when it's in this conversation.
    private var subject: InventoryOccurrencePresentation? {
        occurrences.first { $0.id == shown } ?? occurrences.max { $0.observedAt < $1.observedAt }
    }
    private var title: String {
        if model.contentRevealed, let shown, holdsShown, let title = model.revealedSourceMetadata[shown]?.title { return title }
        return conversation.label.text
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    if reduceMotion { toggle() } else { withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)) { toggle() } }
                } label: {
                    HStack(spacing: 10) {
                        AgentTile(provider: conversation.provider, size: 18)
                        Text(verbatim: title).font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(1)
                            .privacySensitive(title != conversation.label.text)
                        if holdsShown {
                            Circle().fill(Palette.link).frame(width: 5, height: 5)
                                .help("Shown above")
                                .accessibilityHidden(true)
                        }
                        Spacer(minLength: 8)
                        Text("\(occurrences.count.formatted())×").font(.system(size: 12)).foregroundStyle(Palette.tertiary).monospacedDigit()
                        if let latest = occurrences.map(\.observedAt).max() {
                            Text(DisplayTime.short(latest)).font(.system(size: 12)).foregroundStyle(Palette.quaternary)
                                .monospacedDigit().frame(minWidth: 52, alignment: .trailing)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Palette.quaternary)
                            .rotationEffect(.degrees(open ? 180 : 0))
                            .frame(width: 18)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(conversation.provider.displayName), \(title), \(plural(occurrences.count, "appearance"))")
                .accessibilityValue(open ? "Expanded" : "Collapsed")
                conversationMenu
            }
            .padding(.leading, 14).padding(.trailing, 6)
            .frame(height: 44)
            if open {
                VStack(spacing: 2) {
                    ForEach(occurrences) { occurrence in
                        AppearanceLine(model: model, occurrence: occurrence, shown: occurrence.id == shown)
                    }
                }
                .padding(.leading, 40).padding(.trailing, 12).padding(.bottom, 10)
            }
        }
        .background(open ? Color(hex: 0xfafbfa, dark: 0x1f2321) : Palette.surface)
    }

    /// Opening and resuming belong to the conversation, not to the value or the decision.
    private var conversationMenu: some View {
        Menu {
            if let subject {
                if let label = openLabel(subject) {
                    Button(label) {
                        model.selectedOccurrenceID = subject.id
                        model.onOpenSource?(subject.id)
                    }
                } else {
                    Button("No verified way to open this conversation") {}.disabled(true)
                }
                if subject.protectedMetadata != nil {
                    Button("Resume in Terminal…") {
                        model.selectedOccurrenceID = subject.id
                        model.detailSheet = .resume(subject.id)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Palette.secondary)
        .fixedSize()
        .disabled(disabled)
        .help("Open or resume this conversation")
        .accessibilityLabel("Conversation actions")
    }

    private func openLabel(_ occurrence: InventoryOccurrencePresentation) -> String? {
        let agent = occurrence.conversation.provider.displayName
        let capability = model.contentRevealed ? model.revealedSourceMetadata[occurrence.id]?.openingCapability : nil
        switch capability {
        case .validatedRoute?: return "Open in \(agent)"
        case .unavailable?, .activeSessionRestriction?: return nil
        case .unverified?, nil:
            // A shared Codex profile doesn't say which app or CLI opens the conversation.
            if occurrence.conversation.provider == .codex { return nil }
            switch occurrence.interface {
            case .t3?: return "Try opening in T3"
            case .desktopCode?: return "Try opening in \(agent)"
            case .standaloneCLI?, nil: return nil
            }
        }
    }
}

private struct AppearanceLine: View {
    let model: AppModel
    let occurrence: InventoryOccurrencePresentation
    let shown: Bool

    private var style: SourceStyle { SourceStyle(occurrence.contentType) }
    private var alerted: Bool { if case .alerted(.delivered) = occurrence.alert { true } else { false } }

    var body: some View {
        Button { model.selectedOccurrenceID = occurrence.id } label: {
            HStack(spacing: 10) {
                Text(style.glyph)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(style.foreground)
                    .frame(width: 20, height: 20)
                    .background(style.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityHidden(true)
                Text(style.label).font(.system(size: 12.5))
                Text(occurrence.timestampLabel(formattedDate: DisplayTime.full(occurrence.observedAt)))
                    .font(.system(size: 11.5)).foregroundStyle(Palette.quaternary).monospacedDigit()
                if alerted {
                    Text("Alerted").font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.amberSoftText)
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(Palette.amberSoft, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                if occurrence.metadataOnly {
                    Text("Obsolete · nothing kept").font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                }
                Spacer(minLength: 8)
                if shown {
                    Text("Shown above").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.link)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .contentShape(Rectangle())
            .hoverFill(shown ? Palette.selection.opacity(0.7) : .clear,
                       hover: shown ? Palette.selection.opacity(0.7) : Palette.shade.opacity(0.04), radius: 7)
        }
        .buttonStyle(.plain)
        .help(alertHelp)
        .accessibilityLabel("\(style.label), \(DisplayTime.full(occurrence.observedAt))\(alerted ? ", alerted" : "")")
        .accessibilityAddTraits(shown ? [.isButton, .isSelected] : .isButton)
    }

    private var alertHelp: String {
        switch occurrence.alert {
        case .alerted(.delivered): "A notification was sent for this appearance."
        case .alerted(.pending): "A notification is waiting to be sent."
        case .alerted(.permissionDenied): "Notifications are off, so this wasn’t announced."
        case .alerted(.cancelled): "The notification was withdrawn."
        case .repeatInConversation: "No alert: a repeat in the same conversation."
        case .awaitingReview: "No alert: generic matches wait for your review."
        case .catchUp: "No alert: found during a catch-up and included in its summary."
        case .obsolete: "No alert: an obsolete value."
        case .unlocated: "No alert: the exact value wasn’t located."
        case .dismissed: "No alert: you decided this value needs no action."
        case .notAlerted: "No alert."
        }
    }
}

extension InventoryDetailView {
    static func locationMessage(_ reason: LocationFailure) -> String {
        switch reason {
        case .unavailableRange: "The detector didn’t provide a usable range."
        case .ambiguousRange: "The detector couldn’t tell which part of the source matched."
        case .invalidEncoding: "The reported range doesn’t match the source encoding."
        case .scannerReportMismatch: "The scanner report couldn’t be matched to the source."
        }
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
        case .userPrompt: (glyph, label, background, foreground) = ("“", "Input message", Color(oklch: 0.94, 0.022, 150, dark: 0.32), Color(oklch: 0.4, 0.05, 152, dark: 0.8))
        case .intermediateResponse, .finalResponse:
            (glyph, label, background, foreground) = ("✦", "Model response", Color(oklch: 0.94, 0.03, 300, dark: 0.32), Color(oklch: 0.42, 0.09, 300, dark: 0.8))
        case nil: (glyph, label, background, foreground) = ("•", "Appearance", Color(hex: 0xeef1ef, dark: 0x292c2a), Palette.ink2)
        }
    }
}

// MARK: - Decision

/// One decision for the value, or for every selected value, covering all their appearances,
/// including later ones. It sits in the window's bottom row, beside the sidebar footer, at the same
/// height, and under the value in Focus.
struct DecisionBar: View {
    let model: AppModel
    let summaries: [EntrySummary]
    /// Shown under the copy in Focus, where the keys are the quickest way through.
    var hint: String?

    init(model: AppModel, summaries: [EntrySummary], hint: String? = nil) {
        self.model = model
        self.summaries = summaries
        self.hint = hint
    }

    init(model: AppModel, summary: EntrySummary, hint: String? = nil) {
        self.init(model: model, summaries: [summary], hint: hint)
    }

    private typealias Copy = (title: String, body: String, quiet: Bool)

    private var summary: EntrySummary { summaries[0] }
    private var many: Bool { summaries.count > 1 }
    private var disabled: Bool { !model.storageReady || model.actionBusy || model.isDemo }
    private var service: String { many ? "each service" : summary.kind.servicePhrase }
    /// Rotation can only be acknowledged for a value Spillcheck can recognize again.
    private var recognizable: Bool { summaries.contains { !$0.unlocated && $0.entry.fingerprint != nil } }

    private var copy: Copy {
        if many { return manyCopy }
        let entry = summary.entry
        if let acknowledgement = entry.acknowledgement {
            let date = DisplayTime.day(entry.acknowledgedAt ?? entry.observedAt)
            return ("\(acknowledgement.rawValue.capitalizedFirst) · \(date)",
                    (summary.nothingKept ? "Retained content was removed. " : "") + "Later appearances show as obsolete, without alerts.",
                    true)
        }
        let since = entry.appearancesSinceDecision
        if let decision = summary.decision {
            if decision == .needsRotation {
                guard recognizable else {
                    return ("Rotate this \(summary.kind.shortName) at \(service)",
                            "With no exact value, Spillcheck can’t recognize it later.", false)
                }
                return ("Change it at \(service), then confirm",
                        "Later appearances then show as obsolete, without alerts."
                            + (since > 0 ? " Seen \(plural(since, "more time")) since you marked it." : ""), false)
            }
            let date = DisplayTime.day(entry.decidedAt ?? entry.observedAt)
            return ("\(decision.displayName) · \(date)",
                    (summary.nothingKept ? "Retained content was removed. " : "") + "Later appearances stay quiet."
                        + (since > 0 ? " \(plural(since, "new appearance")) since." : ""), true)
        }
        if summary.unlocated {
            return ("Possible \(summary.kind.shortName), exact value not located", "Check its source above, then decide.", false)
        }
        return ("Does this need rotating?", "Your answer covers every appearance of this value, including later ones.", false)
    }

    private var manyCopy: Copy {
        let count = summaries.count
        switch summary.bucket {
        case .toReview:
            return ("Do these \(count) values need rotating?", "Your answer covers all their appearances, including later ones.", false)
        case .toRotate:
            return ("Change them at each service, then confirm", "Later appearances then show as obsolete, without alerts.", false)
        case .done:
            return ("\(count) values done", "Changing the decision sends values back to review. Rotated or revoked ones stay.", true)
        }
    }

    var body: some View {
        let copy = copy
        // Side by side when the window is wide enough, otherwise the actions go under the question.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                text(copy)
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: 10) {
                text(copy)
                actions.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(copy.quiet ? Color(hex: 0xf6f8f7, dark: 0x171a19) : Palette.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What to do")
    }

    private func text(_ copy: Copy) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                if copy.quiet {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.green)
                        .accessibilityHidden(true)
                }
                Text(copy.title).font(.system(size: 14, weight: .semibold)).tracking(-0.1).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(copy.body).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(copy.body)
            if let hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(Palette.quaternary).lineLimit(1).padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if many {
            manyActions
        } else if summary.acknowledged {
            Button("Change decision…") { model.detailSheet = .forget }
                .buttonStyle(OutlineButtonStyle(height: 30))
                .disabled(disabled)
                .help("Forgets that it was rotated or revoked. Later appearances may alert again.")
                .accessibilityIdentifier("inventory.change-decision")
        } else if let decision = summary.decision {
            HStack(spacing: 8) {
                if summary.entry.kind == .rememberedDecision {
                    Button("Forget decision") { model.decide(summary, as: nil) }
                        .buttonStyle(OutlineButtonStyle(height: 30))
                        .disabled(disabled)
                        .help("Removes this entry. If the value appears again, it’s reviewed as new.")
                        .accessibilityIdentifier("inventory.forget-decision")
                } else if decision == .needsRotation {
                    backToReview
                } else {
                    Button("Change decision") { model.decide(summary, as: nil) }
                        .buttonStyle(OutlineButtonStyle(height: 30))
                        .disabled(disabled)
                        .help("Back to review")
                        .accessibilityIdentifier("inventory.change-decision")
                }
                if decision == .needsRotation, recognizable { rotationButtons }
            }
            .fixedSize()
        } else {
            reviewButtons
        }
    }

    @ViewBuilder
    private var manyActions: some View {
        switch summary.bucket {
        case .toReview: reviewButtons
        case .toRotate:
            HStack(spacing: 8) {
                backToReview
                if recognizable { rotationButtons }
            }
            .fixedSize()
        case .done:
            let decided = summaries.filter { !$0.acknowledged && $0.decision != nil }
            if !decided.isEmpty {
                Button(decided.count == summaries.count ? "Back to review" : "Send \(decided.count) back to review") {
                    model.decide(decided, as: nil)
                }
                .buttonStyle(OutlineButtonStyle(height: 30))
                .disabled(disabled)
                .accessibilityIdentifier("inventory.change-decision")
            }
        }
    }

    private var backToReview: some View {
        Button("Back to review") { model.decide(summaries, as: nil) }
            .buttonStyle(QuietButtonStyle(height: 30, horizontalPadding: 10))
            .disabled(disabled)
            .accessibilityIdentifier("inventory.change-decision")
    }

    private var rotationButtons: some View {
        HStack(spacing: 8) {
            Button("Mark revoked") { model.acknowledge(summaries, as: .revoked) }
                .buttonStyle(OutlineButtonStyle(height: 30))
                .disabled(disabled)
                .help("Invalidated at \(service) without a replacement")
                .accessibilityIdentifier("inventory.mark-revoked")
            Button { model.acknowledge(summaries, as: .rotated) } label: {
                HStack(spacing: 7) { KeyCap(key: "D", onAccent: true); Text("Mark rotated") }
            }
            .buttonStyle(FilledButtonStyle(height: 30))
            .disabled(disabled)
            .help("Replaced at \(service) and the old value invalidated. Spillcheck doesn’t check this.")
            .accessibilityIdentifier("inventory.mark-rotated")
        }
    }

    private var reviewButtons: some View {
        HStack(spacing: 8) {
            decisionButton(.testOrDevelopment, "Test or dev only", key: "T")
            decisionButton(.notSecret, "Not a secret", key: "N")
            // A known format is almost always a real credential, so rotating is the likely answer.
            decisionButton(.needsRotation, "Needs rotation", key: "R", primary: summaries.contains(where: \.strong))
            Menu {
                Button("Real, but keep it") { model.decide(summaries, as: .acceptedRisk) }
                if recognizable {
                    Divider()
                    Button("Already rotated") { model.acknowledge(summaries, as: .rotated) }
                    Button("Already revoked") { model.acknowledge(summaries, as: .revoked) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(Palette.ink2)
            .fixedSize()
            .disabled(disabled)
            .help("Other decisions")
            .accessibilityLabel("Other decisions")
            .accessibilityIdentifier("inventory.more-decisions")
        }
        .fixedSize()
    }

    @ViewBuilder
    private func decisionButton(_ decision: ValueDecision, _ title: String, key: String, primary: Bool = false) -> some View {
        let button = Button { model.decide(summaries, as: decision) } label: {
            HStack(spacing: 7) { KeyCap(key: key, onAccent: primary); Text(title) }
        }
        if primary {
            button.buttonStyle(FilledButtonStyle(height: 30)).disabled(disabled)
                .accessibilityIdentifier("inventory.decide.\(decision.rawValue)")
        } else {
            button.buttonStyle(OutlineButtonStyle(height: 30)).disabled(disabled)
                .accessibilityIdentifier("inventory.decide.\(decision.rawValue)")
        }
    }
}

/// The key that does the same as the button, shown inside it.
struct KeyCap: View {
    let key: String
    var onAccent = false

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(onAccent ? Palette.onAccent.opacity(0.8) : Palette.tertiary)
            .frame(minWidth: 16, minHeight: 16)
            .background(onAccent ? Palette.onAccent.opacity(0.16) : Palette.shade.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Sheets

enum DetailSheet: Identifiable, Equatable {
    case remove, forget, resume(UUID)
    var id: String {
        switch self {
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
    @State private var copied = false
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
        case .remove: "Remove retained content for \(name)?"
        case .forget: "Forget obsolete recognition for \(name)?"
        case .resume: "Resume \(resumeOccurrence?.conversation.label.text ?? "this conversation") in \(resumeOccurrence?.conversation.provider.displayName ?? "its agent")"
        }
    }

    private var items: [(Mark, String)] {
        let count = summary.occurrences.filter { !$0.metadataOnly }.count
        let provider = resumeOccurrence?.conversation.provider == .claudeCode ? "Anthropic" : "OpenAI"
        switch kind {
        case .remove:
            return [(.removed, "Exact value and \(plural(count, "excerpt"))"), (.removed, "Occurrence history"),
                    (.kept, "Agent histories on this Mac stay untouched"),
                    summary.acknowledged ? (.kept, "Obsolete marker kept. It holds no value.")
                        : summary.decision != nil ? (.kept, "Your decision is kept for later appearances. It holds no value.")
                        : (.caution, "Undecided, so a later appearance is reviewed and alerts as new")]
        case .forget:
            return [(.removed, "\(summary.entry.acknowledgement?.rawValue.capitalizedFirst ?? "") acknowledgement and recognition marker"),
                    (.caution, "New appearances are evaluated normally and may alert"),
                    summary.entry.kind == .rememberedObsoleteMarker ? (.kept, "Processed history won’t recreate removed occurrences")
                        : (.kept, "Retained appearances stay")]
        case .resume:
            return [(.caution, "Resuming can send new requests to \(provider)"),
                    (.info, "To only look at it, read the excerpt in Spillcheck instead")]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                // The resume sheet is about a conversation, so it carries the agent's mark rather than the value's.
                if let occurrence = resumeOccurrence {
                    AgentTile(provider: occurrence.conversation.provider, size: 38)
                } else {
                    ValueTile(text: summary.kind.monogram, colors: TileColors.forEntry(summary.entry), size: 38)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold)).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if resumeOccurrence != nil {
                        Text("Run this command in Terminal to pick the conversation up where it left off.")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // For a resume, the command is the point; the notes qualify it.
            if let occurrence = resumeOccurrence { resumeCommand(occurrence) }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 10) {
                        markIcon(item.0)
                        Text(item.1).font(.system(size: 12.5))
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                if let command = resumeCommandText {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy command", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .labelStyle(TightLabelStyle())
                            .frame(minWidth: 104)
                    }
                    .buttonStyle(OutlineButtonStyle(height: 26))
                    .task(id: copied) {
                        guard copied else { return }
                        try? await Task.sleep(for: .seconds(1.6))
                        copied = false
                    }
                }
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

    private var resumeCommandText: String? {
        guard let occurrence = resumeOccurrence, model.contentRevealed,
              model.revealedSourceMetadata[occurrence.id] != nil else { return nil }
        return model.terminalResumeCommand
    }

    private var confirmTitle: String {
        switch kind {
        case .remove: "Remove retained content"
        case .forget: "Forget recognition"
        case .resume: "Done"
        }
    }

    private func confirm() {
        defer { dismiss() }
        guard let fingerprint = summary.entry.fingerprint, model.storageReady, !model.isDemo else { return }
        switch kind {
        case .remove: model.onRemoveContent?(fingerprint)
        case .forget: model.onForgetMarker?(fingerprint)
        case .resume: break
        }
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
        let revealed = model.contentRevealed && model.revealedSourceMetadata[occurrence.id] != nil
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if revealed, let command = model.terminalResumeCommand {
                    Text(verbatim: command).textSelection(.enabled).privacySensitive()
                } else {
                    Text(occurrence.conversation.provider == .codex ? "codex resume ••••••••••••" : "claude --resume ••••••••••••")
                }
            }
            .font(.system(size: 12, design: .monospaced)).lineSpacing(3)
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(Color(hex: 0xf5f6f5, dark: 0x161917), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.shade.opacity(0.08)))
            if !revealed {
                HStack(spacing: 10) {
                    Text(model.viewingBusy ? "Waiting for Touch ID…" : "The conversation ID is protected.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Button(model.viewingUnlocked ? "Show values" : "Unlock to show…") { model.unlockOrShowValues() }
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
        guard model.contentRevealed, model.revealedSourceMetadata[occurrence.id] != nil, model.terminalResumeCommand == nil else { return }
        model.onTerminalResume?(occurrence.id)
    }
}
