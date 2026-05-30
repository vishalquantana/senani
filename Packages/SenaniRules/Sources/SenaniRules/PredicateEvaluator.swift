/// The seam for the local LLM. The engine calls this AT MOST ONCE per message,
/// passing every pending predicate at once (batching), and gets one Bool per predicate.
/// The real implementation calls Gemma via MLX with grammar-constrained decoding; tests stub it.
public protocol PredicateEvaluator: Sendable {
    func evaluate(predicates: [String], against message: Message) async -> [Bool]
}
