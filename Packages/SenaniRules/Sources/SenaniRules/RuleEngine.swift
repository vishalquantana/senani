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

    /// Matches `message` against `rules`. Callers are responsible for pre-filtering
    /// `rules` by `runOn` (incoming/existing/both); the engine evaluates whatever list it is given.
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

        // 3. At most one batched model call for this message. Deduplicate predicate
        //    texts (preserving order for determinism) so each unique predicate is
        //    evaluated exactly once and the string-keyed verdict map can't collide.
        var verdicts: [String: Bool] = [:]
        if !pending.isEmpty {
            var uniquePredicates: [String] = []
            for (_, predicate) in pending where !uniquePredicates.contains(predicate) {
                uniquePredicates.append(predicate)
            }
            let results = await evaluator.evaluate(predicates: uniquePredicates, against: message)
            assert(results.count == uniquePredicates.count)
            for (i, predicate) in uniquePredicates.enumerated() where i < results.count {
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
