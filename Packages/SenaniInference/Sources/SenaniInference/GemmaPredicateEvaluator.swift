import SenaniRules

public struct GemmaPredicateEvaluator: PredicateEvaluator {
    private let generator: any TextGenerator

    public init(generator: any TextGenerator, maxTokens: Int = 256) {
        self.generator = generator
    }

    public func evaluate(predicates: [String], against message: Message) async -> [Bool] {
        guard !predicates.isEmpty else {
            return []
        }

        let prompt = PredicatePromptBuilder.build(predicates: predicates, message: message)
        do {
            let raw = try await generator.generateJSON(prompt: prompt, schema: PredicatePromptBuilder.schema)
            guard let parsed = JSONResultParser.parseBoolResults(raw) else {
                return Array(repeating: false, count: predicates.count)
            }
            return align(parsed, count: predicates.count)
        } catch {
            return Array(repeating: false, count: predicates.count)
        }
    }

    private func align(_ values: [Bool], count: Int) -> [Bool] {
        if values.count == count {
            return values
        }
        if values.count > count {
            return Array(values.prefix(count))
        }
        return values + Array(repeating: false, count: count - values.count)
    }
}
