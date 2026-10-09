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

@MainActor @Observable
final class ViewingController {
    private(set) var content = RevealedInventoryContent()
    private(set) var state = InventoryViewingState.masked
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private let session: InventoryViewingSession
    @ObservationIgnored private let loadPayload: @MainActor (ProtectedPayloadReference) async throws -> ProtectedPayload?
    @ObservationIgnored private let selectionIsCurrent: @MainActor (InventoryRevealSelection) async -> Bool
    @ObservationIgnored private var guardState = InventoryRevealGuard()

    init(session: InventoryViewingSession,
         loadPayload: @escaping @MainActor (ProtectedPayloadReference) async throws -> ProtectedPayload?,
         selectionIsCurrent: @escaping @MainActor (InventoryRevealSelection) async -> Bool) {
        self.session = session
        self.loadPayload = loadPayload
        self.selectionIsCurrent = selectionIsCurrent
    }

    var isAuthorized: Bool { session.isAuthorized }

    func select(valueID: UUID?) {
        guard guardState.selectedValueID != valueID else { return }
        guardState.select(valueID: valueID)
        invalidate(.userMask)
    }

    func invalidate(_ reason: ViewingInvalidationReason = .userMask) {
        didInvalidate()
        session.invalidate(reason: reason)
    }

    /// Called by the session's existing lifecycle callback, without recursively invalidating it.
    func didInvalidate(_ reason: ViewingInvalidationReason = .userMask) {
        let requestWillReportFailure = reason == .authorizationFailure && state == .authenticating
        if !requestWillReportFailure { guardState.invalidate() }
        content = RevealedInventoryContent()
        if !requestWillReportFailure { state = .masked }
        onChange?()
    }

    func reveal(_ selection: InventoryRevealSelection) async {
        guard state != .authenticating else { return }
        let ticket: InventoryRevealGuard.Ticket
        do { ticket = try guardState.begin(selection) } catch { return }
        state = .authenticating
        onChange?()
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
            onChange?()
        } catch {
            // A stale request cannot clear a newer selection or overwrite its state.
            guard guardState.accepts(ticket) else { return }
            invalidate(.authorizationFailure)
            state = (error as? ViewingAuthorizationError) == .cancelled ? .cancelled : .unavailable
            onChange?()
        }
    }
}
