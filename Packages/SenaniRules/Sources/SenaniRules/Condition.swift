import Foundation

/// A condition that is evaluated instantly in pure Swift, with no model call.
public enum StructuredCondition: Sendable, Equatable {
    case from(String)
    case to(String)
    case domain(String)
    case subjectContains(String)
    case bodyContains(String)
    case hasAttachment
    case listUnsubscribeHeader
    case isInThread(String)
    case olderThan(TimeInterval)
    case hasLabel(String)

    public func matches(_ m: Message, now: Date) -> Bool {
        switch self {
        case .from(let a):            return m.from.caseInsensitiveCompare(a) == .orderedSame
        case .to(let a):              return m.to.contains { $0.caseInsensitiveCompare(a) == .orderedSame }
        case .domain(let d):          return m.senderDomain == d.lowercased()
        case .subjectContains(let s): return m.subject.range(of: s, options: .caseInsensitive) != nil
        case .bodyContains(let s):    return m.body.range(of: s, options: .caseInsensitive) != nil
        case .hasAttachment:          return m.hasAttachment
        case .listUnsubscribeHeader:  return m.listUnsubscribeHeader != nil
        case .isInThread(let t):      return m.threadId == t
        case .olderThan(let secs):    return now.timeIntervalSince(m.date) > secs
        case .hasLabel(let l):        return m.labels.contains(l)
        }
    }
}

/// How the structured conditions combine.
public enum MatchMode: Sendable, Equatable {
    case all
    case any
    case none
}

/// A rule's conditions: a structured set (instant) plus an optional plain-English
/// AI predicate (evaluated separately by the engine, only when the structured set matches).
public struct Conditions: Sendable, Equatable {
    public var mode: MatchMode
    public var structured: [StructuredCondition]
    public var aiPredicate: String?

    public init(mode: MatchMode, structured: [StructuredCondition], aiPredicate: String?) {
        self.mode = mode
        self.structured = structured
        self.aiPredicate = aiPredicate
    }

    /// Evaluates ONLY the structured conditions. The AI predicate is handled by the engine.
    /// Empty structured + `.all` is vacuously true so pure-AI rules can reach their predicate.
    public func matchesStructured(_ m: Message, now: Date) -> Bool {
        switch mode {
        case .all:  return structured.allSatisfy { $0.matches(m, now: now) }
        case .any:  return structured.contains { $0.matches(m, now: now) }
        case .none: return !structured.contains { $0.matches(m, now: now) }
        }
    }
}
