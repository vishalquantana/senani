import SenaniRules

public struct ChatActionDispatchResult: Sendable, Equatable {
    public let outcome: Outcome
    public let undoToken: String?
}

public struct ChatActionDispatcher: Sendable {
    private let backend: any MailBackend
    private let approvals: ApprovalQueue
    private let audit: any AuditLog

    public init(backend: any MailBackend, approvals: ApprovalQueue, audit: any AuditLog) {
        self.backend = backend
        self.approvals = approvals
        self.audit = audit
    }

    public func dispatch(action: Action, message: Message, turnId: String, autonomy: Autonomy = .auto) async throws -> ChatActionDispatchResult {
        let trigger = Trigger.chat(turnId: turnId)
        let outcome = ActionRouter.route(action, autonomy: autonomy)
        switch outcome {
        case .executed, .prepared:
            try await backend.apply(action, to: message)
        case .queuedForApproval:
            await approvals.enqueue(Proposal(action: action, message: message, trigger: trigger))
        }
        await audit.record(ActionRecord(action: action, messageId: message.id, trigger: trigger, outcome: outcome))
        return ChatActionDispatchResult(outcome: outcome, undoToken: outcome == .executed ? "\(turnId):\(message.id)" : nil)
    }
}
