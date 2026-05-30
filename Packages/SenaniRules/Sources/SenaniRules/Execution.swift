import Foundation

/// The seam to the world that performs reversible actions (labels, archive, drafts…).
/// The real implementation talks to Gmail; tests use a spy.
public protocol MailBackend: Sendable {
    func apply(_ action: Action, to message: Message) async throws
}

/// An outbound or to-be-approved action awaiting the user's decision.
public struct Proposal: Sendable, Equatable {
    public let action: Action
    public let message: Message
    public let trigger: Trigger
    public init(action: Action, message: Message, trigger: Trigger) {
        self.action = action
        self.message = message
        self.trigger = trigger
    }
}

/// Collects proposals for the SwiftUI Approval queue (later).
public actor ApprovalQueue {
    private var items: [Proposal] = []
    public init() {}
    public func enqueue(_ p: Proposal) { items.append(p) }
    public func pending() -> [Proposal] { items }
}

/// One executed/queued action, with what caused it — the auditable trail.
public struct ActionRecord: Sendable, Equatable {
    public let action: Action
    public let messageId: String
    public let trigger: Trigger
    public let outcome: Outcome
    public init(action: Action, messageId: String, trigger: Trigger, outcome: Outcome) {
        self.action = action
        self.messageId = messageId
        self.trigger = trigger
        self.outcome = outcome
    }
}

public protocol AuditLog: Sendable {
    func record(_ record: ActionRecord) async
}

/// In-memory audit log for tests and early development.
public actor InMemoryAuditLog: AuditLog {
    private var items: [ActionRecord] = []
    public init() {}
    public func record(_ record: ActionRecord) { items.append(record) }
    public func records() -> [ActionRecord] { items }
}

/// Executes a matched rule's actions, enforcing the kernel safety rule via ActionRouter.
public struct ActionExecutor: Sendable {
    private let backend: MailBackend
    private let approvals: ApprovalQueue
    private let audit: AuditLog
    public init(backend: MailBackend, approvals: ApprovalQueue, audit: AuditLog) {
        self.backend = backend
        self.approvals = approvals
        self.audit = audit
    }

    public func execute(match: RuleMatch) async throws {
        let trigger = Trigger.rule(id: match.rule.id)
        for action in match.rule.actions {
            let outcome = ActionRouter.route(action, autonomy: match.rule.autonomy)
            switch outcome {
            case .executed, .prepared:
                try await backend.apply(action, to: match.message)
            case .queuedForApproval:
                await approvals.enqueue(
                    Proposal(action: action, message: match.message, trigger: trigger))
            }
            await audit.record(ActionRecord(
                action: action, messageId: match.message.id, trigger: trigger, outcome: outcome))
        }
    }
}
