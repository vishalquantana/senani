/// One fully-derived row of the activity timeline. Equatable; `id` is synthetic
/// (messageId + loggedAt) since AuditEntry has no stable identity of its own.
public struct ActivityEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let actionSummary: String
    public let messageId: String
    public let triggerLabel: String
    public let outcomeLabel: String
    public let loggedAt: Double

    public init(actionSummary: String, messageId: String, triggerLabel: String,
                outcomeLabel: String, loggedAt: Double) {
        self.id = "\(messageId)#\(loggedAt)"
        self.actionSummary = actionSummary
        self.messageId = messageId
        self.triggerLabel = triggerLabel
        self.outcomeLabel = outcomeLabel
        self.loggedAt = loggedAt
    }
}
