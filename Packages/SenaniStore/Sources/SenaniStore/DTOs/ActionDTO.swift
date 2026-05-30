import SenaniRules

public struct ActionDTO: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case label, archive, markRead, markUnread, star, unstar, move
        case flagNeedsReply, fileAttachment, parseDoc, runAgent, draft
        case reply, forward, send, markSpam, localWebhook
    }

    public var kind: Kind
    public var string1: String?
    public var string2: String?

    public init(core: Action) {
        switch core {
        case .label(let value):
            kind = .label
            string1 = value
        case .archive:
            kind = .archive
        case .markRead:
            kind = .markRead
        case .markUnread:
            kind = .markUnread
        case .star:
            kind = .star
        case .unstar:
            kind = .unstar
        case .move(let value):
            kind = .move
            string1 = value
        case .flagNeedsReply:
            kind = .flagNeedsReply
        case .fileAttachment(let folder):
            kind = .fileAttachment
            string1 = folder
        case .parseDoc:
            kind = .parseDoc
        case .runAgent(let id):
            kind = .runAgent
            string1 = id
        case .draft(let body):
            kind = .draft
            string1 = body
        case .reply(let body):
            kind = .reply
            string1 = body
        case .forward(let to, let body):
            kind = .forward
            string1 = to
            string2 = body
        case .send(let body):
            kind = .send
            string1 = body
        case .markSpam:
            kind = .markSpam
        case .localWebhook(let name):
            kind = .localWebhook
            string1 = name
        }
    }

    public func toCore() -> Action {
        switch kind {
        case .label:
            return .label(string1 ?? "")
        case .archive:
            return .archive
        case .markRead:
            return .markRead
        case .markUnread:
            return .markUnread
        case .star:
            return .star
        case .unstar:
            return .unstar
        case .move:
            return .move(string1 ?? "")
        case .flagNeedsReply:
            return .flagNeedsReply
        case .fileAttachment:
            return .fileAttachment(folder: string1 ?? "")
        case .parseDoc:
            return .parseDoc
        case .runAgent:
            return .runAgent(id: string1 ?? "")
        case .draft:
            return .draft(body: string1 ?? "")
        case .reply:
            return .reply(body: string1 ?? "")
        case .forward:
            return .forward(to: string1 ?? "", body: string2 ?? "")
        case .send:
            return .send(body: string1 ?? "")
        case .markSpam:
            return .markSpam
        case .localWebhook:
            return .localWebhook(name: string1 ?? "")
        }
    }
}
