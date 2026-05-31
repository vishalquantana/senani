import Foundation
import SenaniRules

public struct TriageAgent: Agent {
    public init() {}

    public var id: String { "triage" }
    public var autonomy: Autonomy { .auto }

    private static let categoryLabelPrefix = "Senani/Category/"

    public func wakesFor(_ message: Message, context: AgentContext) -> Bool {
        if message.isFromUser { return false }
        if message.labels.contains(where: { $0.hasPrefix(Self.categoryLabelPrefix) }) { return false }
        return true
    }

    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        let prompt = Self.buildPrompt(for: message)
        let raw = try await tools.generateJSON(prompt: prompt, schema: TriageClassification.schema)
        let classification = TriageClassification.parse(raw)
        return [
            tools.proposeLabel(classification.category.label, on: message),
            tools.proposeLabel(classification.priority.label, on: message),
        ]
    }

    static func buildPrompt(for message: Message) -> String {
        let categories = TriageCategory.allCases.map { $0.rawValue.capitalized }.joined(separator: ", ")
        let priorities = TriagePriority.allCases.map { $0.rawValue }.joined(separator: ", ")
        let snippet = String(message.body.prefix(600))
        return """
        You are Senani's email triage classifier. Classify ONE email.
        Reply with ONLY a JSON object: {"category": <one of: \(categories)>, \
        "priority": <one of: \(priorities)>, "reason": <one short sentence>}.
        Choose exactly one category and one priority from the lists. Do not invent values.

        \(PromptFencing.preamble)

        EMAIL
        From: \(message.from)
        \(PromptFencing.fence("SUBJECT", message.subject))
        \(PromptFencing.fence("BODY", snippet))
        """
    }
}
