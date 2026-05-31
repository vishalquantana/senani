import Foundation
import Observation
import SenaniRules
import SenaniStore

/// Owns the Approval Queue's read/approve/reject/execute logic. Pure of SwiftUI;
/// constructed from closure ports so it is testable with in-memory fakes OR the
/// live AppEnvironment graph. On approve it executes the proposal through the
/// MailBackend — THIS is the on-approve execution boundary (outbound mail only
/// reaches Gmail when the human approves here).
@MainActor
@Observable
public final class ApprovalQueueViewModel {
    public private(set) var cards: [ApprovalCard] = []
    public private(set) var lastError: String?

    private let pendingPort: @Sendable () throws -> [StoredProposal]
    private let approvePort: @Sendable (String) throws -> Void
    private let rejectPort: @Sendable (String) throws -> Void
    private let applyPort: @Sendable (Action, Message) async throws -> Void

    public init(
        pending: @escaping @Sendable () throws -> [StoredProposal],
        approve: @escaping @Sendable (String) throws -> Void,
        reject: @escaping @Sendable (String) throws -> Void,
        apply: @escaping @Sendable (Action, Message) async throws -> Void
    ) {
        self.pendingPort = pending
        self.approvePort = approve
        self.rejectPort = reject
        self.applyPort = apply
    }

    /// Live wiring: reads/writes THROUGH the injected composition root (reconciliation §4.1).
    public convenience init(environment env: AppEnvironment) {
        let approvals = env.approvals
        let backend = env.mailBackend
        self.init(
            pending: { try approvals.pending() },
            approve: { try approvals.approve(id: $0) },
            reject: { try approvals.reject(id: $0) },
            apply: { try await backend.apply($0, to: $1) })
    }

    /// Reload the pending cards (synchronous store read).
    public func refresh() {
        do {
            cards = ApprovalMapping.cards(from: try pendingPort())
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Approve → mark approved → EXECUTE via the backend → refresh.
    /// If execution fails, capture the error but still refresh (row stays approved).
    public func approve(id: String) async {
        lastError = nil
        guard let card = cards.first(where: { $0.id == id }) else { return }
        do {
            try approvePort(id)
            try await applyPort(card.action, card.message)
        } catch {
            lastError = String(describing: error)
        }
        refresh()
    }

    /// Reject → mark rejected → refresh. NEVER executes.
    public func reject(id: String) async {
        lastError = nil
        do {
            try rejectPort(id)
        } catch {
            lastError = String(describing: error)
        }
        refresh()
    }
}
