import Foundation
import SenaniRules

public enum PredicatePromptBuilder {
    static let maxSnippet = 1_000
    public static let schema = JSONSchema.boolArrayResults(key: "results")

    public static func build(predicates: [String], message: Message) -> String {
        let snippet: String
        if message.body.count <= maxSnippet {
            snippet = message.body
        } else {
            snippet = String(message.body.prefix(maxSnippet)) + "..."
        }

        let questions = predicates.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        return """
        You judge an email against a numbered list of yes/no questions.
        Answer each question for this email only, in order.

        EMAIL
        From: \(message.from)
        To: \(message.to.joined(separator: ", "))
        Subject: \(message.subject)
        Body: \(snippet)

        QUESTIONS
        \(questions)

        Reply with only a JSON object of the form {"results":[<bool>, ...]}
        containing exactly \(predicates.count) booleans, one per question in order.
        true = yes, false = no. No prose.
        """
    }
}
