import SenaniRules

public struct TriggerDTO: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case rule, chat
    }

    public var kind: Kind
    public var identifier: String

    public init(core: Trigger) {
        switch core {
        case .rule(let id):
            kind = .rule
            identifier = id
        case .chat(let turnId):
            kind = .chat
            identifier = turnId
        }
    }

    public func toCore() -> Trigger {
        switch kind {
        case .rule:
            return .rule(id: identifier)
        case .chat:
            return .chat(turnId: identifier)
        }
    }
}

public struct OutcomeDTO: Codable, Equatable, Sendable {
    public enum Raw: String, Codable, Sendable {
        case executed, prepared, queuedForApproval
    }

    public var raw: Raw

    public init(core: Outcome) {
        switch core {
        case .executed:
            raw = .executed
        case .prepared:
            raw = .prepared
        case .queuedForApproval:
            raw = .queuedForApproval
        }
    }

    public init(raw: Raw) {
        self.raw = raw
    }

    public func toCore() -> Outcome {
        switch raw {
        case .executed:
            return .executed
        case .prepared:
            return .prepared
        case .queuedForApproval:
            return .queuedForApproval
        }
    }
}
