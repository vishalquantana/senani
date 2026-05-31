import SenaniRules
import SenaniStore

/// Pure, dependency-free mapping from audit entries to the activity timeline.
/// Reuses ApprovalMapping for the shared action-summary + agent-label vocabulary
/// so the queue and the log describe actions identically.
public enum ActivityMapping {

    public static func outcomeLabel(_ outcome: Outcome) -> String {
        switch outcome {
        case .executed: return "Executed"
        case .prepared: return "Prepared"
        case .queuedForApproval: return "Queued for approval"
        }
    }

    public static func triggerLabel(_ trigger: Trigger) -> String {
        ApprovalMapping.proposingAgent(trigger)
    }

    public static func activity(from entry: AuditEntry) -> ActivityEntry {
        let r = entry.record
        return ActivityEntry(
            actionSummary: ApprovalMapping.actionSummary(r.action),
            messageId: r.messageId,
            triggerLabel: triggerLabel(r.trigger),
            outcomeLabel: outcomeLabel(r.outcome),
            loggedAt: entry.loggedAt)
    }

    /// Newest-first timeline. `records()` returns chronological (insertion) order;
    /// we sort descending by loggedAt (stable for equal timestamps via reversal of
    /// the already-chronological input).
    public static func timeline(from entries: [AuditEntry]) -> [ActivityEntry] {
        entries
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.loggedAt != rhs.element.loggedAt {
                    return lhs.element.loggedAt > rhs.element.loggedAt
                }
                return lhs.offset > rhs.offset   // later insertion first when timestamps tie
            }
            .map { activity(from: $0.element) }
    }
}
