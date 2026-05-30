import Foundation

/// A rule that matched a message.
public struct RuleMatch: Sendable, Equatable {
    public let rule: Rule
    public let message: Message
    public init(rule: Rule, message: Message) {
        self.rule = rule
        self.message = message
    }
}

/// The hybrid matching pipeline: instant structured filtering, then at most one
/// batched predicate evaluation per message.
public struct RuleEngine: Sendable {
    private let evaluator: PredicateEvaluator
    public init(evaluator: PredicateEvaluator) { self.evaluator = evaluator }

    public func match(message: Message, rules: [Rule], now: Date) async -> [RuleMatch] {
        // 1. Structured pass (pure Swift) over enabled rules.
        let structurallyMatched = rules.filter {
            $0.enabled && $0.conditions.matchesStructured(message, now: now)
        }

        // 2. Collect predicates only for rules that passed structurally AND carry one.
        let pending = structurallyMatched.compactMap { rule -> (Rule, String)? in
            guard let p = rule.conditions.aiPredicate else { return nil }
            return (rule, p)
        }

        // 3. At most one batched model call for this message.
        var verdicts: [String: Bool] = [:]
        if !pending.isEmpty {
            let predicates = pending.map(\.1)
            let results = await evaluator.evaluate(predicates: predicates, against: message)
            for (i, predicate) in predicates.enumerated() where i < results.count {
                verdicts[predicate] = results[i]
            }
        }

        // 4. Final match: structural pass AND (no predicate OR predicate true).
        return structurallyMatched.compactMap { rule in
            if let p = rule.conditions.aiPredicate, verdicts[p] != true { return nil }
            return RuleMatch(rule: rule, message: message)
        }
    }
}
