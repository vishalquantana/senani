import Foundation
import SenaniRules

public struct StructuredConditionDTO: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case from, to, domain, subjectContains, bodyContains
        case hasAttachment, listUnsubscribeHeader, isInThread, olderThan, hasLabel
    }

    public var kind: Kind
    public var string1: String?
    public var seconds: TimeInterval?

    public init(core: StructuredCondition) {
        switch core {
        case .from(let value):
            kind = .from
            string1 = value
        case .to(let value):
            kind = .to
            string1 = value
        case .domain(let value):
            kind = .domain
            string1 = value
        case .subjectContains(let value):
            kind = .subjectContains
            string1 = value
        case .bodyContains(let value):
            kind = .bodyContains
            string1 = value
        case .hasAttachment:
            kind = .hasAttachment
        case .listUnsubscribeHeader:
            kind = .listUnsubscribeHeader
        case .isInThread(let value):
            kind = .isInThread
            string1 = value
        case .olderThan(let value):
            kind = .olderThan
            seconds = value
        case .hasLabel(let value):
            kind = .hasLabel
            string1 = value
        }
    }

    public func toCore() -> StructuredCondition {
        switch kind {
        case .from:
            return .from(string1 ?? "")
        case .to:
            return .to(string1 ?? "")
        case .domain:
            return .domain(string1 ?? "")
        case .subjectContains:
            return .subjectContains(string1 ?? "")
        case .bodyContains:
            return .bodyContains(string1 ?? "")
        case .hasAttachment:
            return .hasAttachment
        case .listUnsubscribeHeader:
            return .listUnsubscribeHeader
        case .isInThread:
            return .isInThread(string1 ?? "")
        case .olderThan:
            return .olderThan(seconds ?? 0)
        case .hasLabel:
            return .hasLabel(string1 ?? "")
        }
    }
}

public struct MatchModeDTO: Codable, Equatable, Sendable {
    public enum Raw: String, Codable, Sendable {
        case all, any, none
    }

    public var raw: Raw

    public init(core: MatchMode) {
        switch core {
        case .all:
            raw = .all
        case .any:
            raw = .any
        case .none:
            raw = .none
        }
    }

    public func toCore() -> MatchMode {
        switch raw {
        case .all:
            return .all
        case .any:
            return .any
        case .none:
            return .none
        }
    }
}

public struct ConditionsDTO: Codable, Equatable, Sendable {
    public var mode: MatchModeDTO
    public var structured: [StructuredConditionDTO]
    public var aiPredicate: String?

    public init(core: Conditions) {
        mode = MatchModeDTO(core: core.mode)
        structured = core.structured.map(StructuredConditionDTO.init(core:))
        aiPredicate = core.aiPredicate
    }

    public func toCore() -> Conditions {
        Conditions(
            mode: mode.toCore(),
            structured: structured.map { $0.toCore() },
            aiPredicate: aiPredicate
        )
    }
}
