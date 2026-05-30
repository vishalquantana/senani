import Foundation

/// An email message, modeled with exactly the fields the rules engine needs.
/// Decoupled from Gmail so it is trivially constructible in tests.
public struct Message: Sendable, Equatable, Identifiable {
    public let id: String
    public let from: String
    public let to: [String]
    public let subject: String
    public let body: String
    public let hasAttachment: Bool
    public let listUnsubscribeHeader: String?
    public let labels: [String]
    public let threadId: String
    public let date: Date
    public let isFromUser: Bool

    public init(
        id: String, from: String, to: [String], subject: String, body: String,
        hasAttachment: Bool, listUnsubscribeHeader: String?, labels: [String],
        threadId: String, date: Date, isFromUser: Bool
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.subject = subject
        self.body = body
        self.hasAttachment = hasAttachment
        self.listUnsubscribeHeader = listUnsubscribeHeader
        self.labels = labels
        self.threadId = threadId
        self.date = date
        self.isFromUser = isFromUser
    }

    /// Lowercased host portion after the last "@", or "" if there is no "@".
    public var senderDomain: String {
        guard let at = from.lastIndex(of: "@") else { return "" }
        return String(from[from.index(after: at)...]).lowercased()
    }
}
