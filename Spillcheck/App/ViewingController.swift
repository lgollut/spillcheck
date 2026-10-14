import Foundation
import Observation
import SpillcheckCore

struct RevealedInventoryContent {
    var value: String?
    var excerpts: [UUID: RetainedExcerpt] = [:]
    var sourceMetadata: [UUID: RetainedSourceContext] = [:]
}

enum InventoryViewingState: Equatable {
    case masked, authenticating, revealed, cancelled, unavailable

    var message: String? {
        switch self {
        case .masked, .revealed: nil
        case .authenticating: "Authenticate in the macOS prompt."
        case .cancelled: "Authentication cancelled. Content remains masked."
        case .unavailable: "Protected content is unavailable. Content remains masked."
        }
    }
}

/// Unlocking authorizes the viewing session once. Revealing decrypts one selection's content, and
/// the exact value shows only once asked for. Hiding it, or selecting something else, leaves the
/// session unlocked.
@MainActor @Observable
final class ViewingController {
    private(set) var content = RevealedInventoryContent()
    private(set) var state = InventoryViewingState.masked
    /// The exact value is on screen, not only decrypted to hide it within its context.
    private(set) var valueShown = false
    /// An unlock without a reveal is waiting for authentication.
    private(set) var unlocking = false
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private let session: InventoryViewingSession
    @ObservationIgnored private let loadPayload: @MainActor (ProtectedPayloadReference) async throws -> ProtectedPayload?
    @ObservationIgnored private let selectionIsCurrent: @MainActor (InventoryRevealSelection) async -> Bool
    @ObservationIgnored private var guardState = InventoryRevealGuard()
    @ObservationIgnored private var currentRequest: InventoryRevealGuard.Ticket?
    /// A request still in flight was asked to show the value, so a newer one for the same value does too.
    @ObservationIgnored private var valueRequested = false

    init(session: InventoryViewingSession,
         loadPayload: @escaping @MainActor (ProtectedPayloadReference) async throws -> ProtectedPayload?,
         selectionIsCurrent: @escaping @MainActor (InventoryRevealSelection) async -> Bool) {
        self.session = session
        self.loadPayload = loadPayload
        self.selectionIsCurrent = selectionIsCurrent
    }

    var isAuthorized: Bool { session.isAuthorized }
    var selectedValueID: UUID? { guardState.selectedValueID }

    func select(valueID: UUID?) {
        guard guardState.selectedValueID != valueID else { return }
        guardState.select(valueID: valueID)
        hide()
    }

    /// Hides revealed content and drops any reveal still in flight. The session stays unlocked.
    func hide() {
        guardState.invalidate()
        session.conceal()
        content = RevealedInventoryContent()
        state = .masked
        valueShown = false
        valueRequested = false
        onChange?()
    }

    /// Shows the already decrypted value. Returns false when it must be revealed first.
    func showValue() -> Bool {
        guard state == .revealed, content.value != nil, session.isAuthorized else { return false }
        if !valueShown {
            valueShown = true
            onChange?()
        }
        return true
    }

    /// Hides the value and keeps its context on screen.
    func hideValue() {
        valueRequested = false
        guard valueShown else { return }
        valueShown = false
        onChange?()
    }

    /// Locks the session, so the next reveal asks for authentication again.
    func invalidate(_ reason: ViewingInvalidationReason = .userMask) {
        didInvalidate()
        session.invalidate(reason: reason)
    }

    func unlock() async throws {
        guard !unlocking, state != .authenticating, !session.isAuthorized else { return }
        unlocking = true
        onChange?()
        defer {
            unlocking = false
            onChange?()
        }
        try await session.unlock(localizedReason: "unlock protected content")
    }

    /// Called by the session's existing lifecycle callback, without recursively invalidating it.
    func didInvalidate(_ reason: ViewingInvalidationReason = .userMask) {
        let requestWillReportFailure = reason == .authorizationFailure
            && currentRequest.map { guardState.accepts($0) } == true
        if !requestWillReportFailure { guardState.invalidate() }
        content = RevealedInventoryContent()
        valueShown = false
        if !requestWillReportFailure { valueRequested = false }
        if !requestWillReportFailure { state = .masked }
        onChange?()
    }

    /// A newer reveal supersedes one still in flight. Adding another appearance's context to revealed
    /// content keeps that content on screen meanwhile. The value shows once a request asks for it.
    func reveal(_ selection: InventoryRevealSelection, showingValue: Bool = false) async {
        guard !unlocking else { return }
        let extending = state == .revealed
        let ticket: InventoryRevealGuard.Ticket
        do { ticket = try guardState.begin(selection) } catch { return }
        currentRequest = ticket
        valueRequested = valueRequested || showingValue
        defer {
            if currentRequest == ticket {
                currentRequest = nil
                valueRequested = false
            }
        }
        if !extending {
            state = .authenticating
            onChange?()
        }
        do {
            guard await selectionIsCurrent(selection), guardState.accepts(ticket) else {
                throw ViewingAuthorizationError.invalidated
            }
            var next = content
            for field in selection.fields {
                try Task.checkCancellation()
                guard guardState.accepts(ticket), let payload = try await loadPayload(field.reference),
                      payload.binding == field.binding else { throw StorageError.payloadMissing }
                guard guardState.accepts(ticket) else { throw ViewingAuthorizationError.invalidated }
                let bytes = try await session.reveal(payload, binding: field.binding,
                    localizedReason: "show protected content")
                guard guardState.accepts(ticket), await selectionIsCurrent(selection),
                      try await loadPayload(field.reference) == payload, session.isAuthorized else {
                    throw ViewingAuthorizationError.invalidated
                }
                switch field {
                case .value:
                    guard let value = String(data: bytes, encoding: .utf8) else { throw ContractError.invalidUTF8 }
                    next.value = value
                case .excerpt(let occurrenceID, _):
                    next.excerpts[occurrenceID] = try JSONDecoder().decode(RetainedExcerpt.self, from: bytes)
                case .sourceMetadata(let occurrenceID, _), .unlocatedSourceMetadata(let occurrenceID, _):
                    next.sourceMetadata[occurrenceID] = try JSONDecoder().decode(RetainedSourceContext.self, from: bytes)
                }
            }
            guard guardState.accepts(ticket), session.isAuthorized else { throw ViewingAuthorizationError.invalidated }
            content = next
            state = .revealed
            if valueRequested { valueShown = true }
            onChange?()
        } catch {
            // A stale request cannot clear a newer selection or overwrite its state,
            // but its authentication may have unlocked the session.
            guard guardState.accepts(ticket) else {
                onChange?()
                return
            }
            invalidate(.authorizationFailure)
            state = (error as? ViewingAuthorizationError) == .cancelled ? .cancelled : .unavailable
            onChange?()
        }
    }
}
