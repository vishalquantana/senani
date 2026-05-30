/// The Action Kernel vocabulary: every side-effecting operation both the rule
/// engine and (later) the chat assistant can request.
public enum Action: Sendable, Equatable {
    case label(String)
    case archive
    case markRead
    case markUnread
    case star
    case unstar
    case move(String)
    case flagNeedsReply
    case fileAttachment(folder: String)
    case parseDoc
    case runAgent(id: String)
    case draft(body: String)
    case reply(body: String)
    case forward(to: String, body: String)
    case send(body: String)
    case markSpam
    case localWebhook(name: String)
}

/// Safety class of an action. The kernel guarantees outbound actions never
/// execute silently — they always route to the approval queue.
public enum ActionClass: Sendable, Equatable {
    case reversible
    case outbound
}

extension Action {
    public var actionClass: ActionClass {
        switch self {
        case .reply, .forward, .send, .markSpam:
            return .outbound
        case .label, .archive, .markRead, .markUnread, .star, .unstar, .move,
             .flagNeedsReply, .fileAttachment, .parseDoc, .runAgent, .draft,
             .localWebhook:
            return .reversible
        }
    }
}
