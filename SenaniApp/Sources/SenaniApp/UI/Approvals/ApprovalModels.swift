import SenaniRules

/// The fully-derived presentation row for one pending proposal. Equatable so
/// tests assert on it directly; carries the message so the view model can
/// execute it on approve without re-reading the store.
public struct ApprovalCard: Sendable, Equatable, Identifiable {
    public let id: String                 // StoredProposal.id (used to approve/reject)
    public let actionSummary: String      // human action text, e.g. "Send reply"
    public let kind: ActionClass          // .reversible | .outbound (drives the badge)
    public let sender: String             // raw `from`
    public let subject: String
    public let snippet: String            // trimmed/truncated body preview
    public let proposingAgent: String     // derived from Trigger
    public let messageId: String

    // The full action + message, kept for on-approve execution. Excluded from
    // Equatable identity concerns by virtue of being derived from id/messageId,
    // but included so `apply` needs no store round-trip.
    public let action: Action
    public let message: Message

    public init(id: String, actionSummary: String, kind: ActionClass, sender: String,
                subject: String, snippet: String, proposingAgent: String, messageId: String,
                action: Action, message: Message) {
        self.id = id
        self.actionSummary = actionSummary
        self.kind = kind
        self.sender = sender
        self.subject = subject
        self.snippet = snippet
        self.proposingAgent = proposingAgent
        self.messageId = messageId
        self.action = action
        self.message = message
    }
}
