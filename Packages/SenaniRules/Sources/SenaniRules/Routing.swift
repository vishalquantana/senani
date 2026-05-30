/// What happened (executor) or would happen (simulator) to a single action.
public enum Outcome: Sendable, Equatable {
    case executed          // reversible action applied automatically
    case prepared          // reversible action staged for one-click commit (prepare autonomy)
    case queuedForApproval // sent to the approval queue (all outbound, or reversible under ask)
}

/// What caused an action — recorded in the audit log.
public enum Trigger: Sendable, Equatable {
    case rule(id: String)
    case chat(turnId: String)
}

/// The single source of truth for the kernel's safety guarantee.
/// Shared by the executor (which performs) and the simulator (which only records).
public enum ActionRouter {
    public static func route(_ action: Action, autonomy: Autonomy) -> Outcome {
        if action.actionClass == .outbound { return .queuedForApproval }
        switch autonomy {
        case .auto:    return .executed
        case .prepare: return .prepared
        case .ask:     return .queuedForApproval
        }
    }
}
