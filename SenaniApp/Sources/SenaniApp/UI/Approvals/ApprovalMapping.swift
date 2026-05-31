import SenaniRules
import SenaniStore

/// Pure, dependency-free mapping from store types to the approval presentation
/// model. No SwiftUI, no I/O — the seam the view model and tests share.
public enum ApprovalMapping {

    /// Human-readable one-line summary of an action.
    public static func actionSummary(_ action: Action) -> String {
        switch action {
        case .reply: return "Send reply"
        case .send: return "Send email"
        case .forward(let to, _): return "Forward to \(to)"
        case .draft: return "Save draft"
        case .label(let name): return "Apply label “\(name)”"
        case .move(let folder): return "Move to “\(folder)”"
        case .archive: return "Archive"
        case .markRead: return "Mark as read"
        case .markUnread: return "Mark as unread"
        case .star: return "Star"
        case .unstar: return "Unstar"
        case .markSpam: return "Mark as spam"
        case .flagNeedsReply: return "Flag as needs reply"
        case .fileAttachment(let folder): return "File attachment to “\(folder)”"
        case .parseDoc: return "Parse document"
        case .runAgent(let id): return "Run agent “\(humanize(id))”"
        case .localWebhook(let name): return "Run webhook “\(name)”"
        }
    }

    /// The proposing-agent display label, derived from the proposal's Trigger.
    /// Agent-originated actions are tagged `.rule(id: agent.id)`; chat is `.chat`.
    public static func proposingAgent(_ trigger: Trigger) -> String {
        switch trigger {
        case .rule(let id): return humanize(id)
        case .chat: return "Assistant (chat)"
        }
    }

    /// Trim and truncate a body to a card-sized snippet (never crashes).
    public static func snippet(from body: String, limit: Int = 140) -> String {
        let collapsed = body
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= limit { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: limit - 1)
        return String(collapsed[..<end]) + "…"
    }

    /// Build one card from a stored proposal.
    public static func card(from stored: StoredProposal) -> ApprovalCard {
        let p = stored.proposal
        return ApprovalCard(
            id: stored.id,
            actionSummary: actionSummary(p.action),
            kind: p.action.actionClass,
            sender: p.message.from,
            subject: p.message.subject,
            snippet: snippet(from: p.message.body),
            proposingAgent: proposingAgent(p.trigger),
            messageId: p.message.id,
            action: p.action,
            message: p.message)
    }

    /// Map preserving the store's ordering (pending() already sorts by created_at,id).
    public static func cards(from stored: [StoredProposal]) -> [ApprovalCard] {
        stored.map(card(from:))
    }

    /// "reply-drafter" -> "Reply Drafter"; "triage" -> "Triage".
    private static func humanize(_ id: String) -> String {
        id.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
