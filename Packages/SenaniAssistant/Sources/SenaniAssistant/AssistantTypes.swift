import SenaniRules

public struct AssistantContext: Sendable, Equatable {
    public let sessionId: String
    public let accountEmail: String

    public init(sessionId: String, accountEmail: String) {
        self.sessionId = sessionId
        self.accountEmail = accountEmail
    }
}

public struct AssistantResponse: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case text
        case actionDispatched
        case ruleDraft(Rule)
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct ChatTurn: Codable, Sendable, Equatable {
    public let role: String
    public let text: String
    public let timestamp: Double

    public init(role: String, text: String, timestamp: Double) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}
