import Foundation
import SenaniRules
import SenaniInference

/// Classifies an inbound reply on a tracked proposal thread into a DealStage, using a
/// grammar-constrained `generateJSON` intent. Ambiguous/garbage → `.negotiation` (never a silent
/// jump to .won/.lost). The agent injects the generator; the classifier performs the only model call.
public struct ReplyIntentClassifier: Sendable {
    private let generator: any TextGenerator

    public init(generator: any TextGenerator) {
        self.generator = generator
    }

    /// The fixed schema the model must satisfy: { "intent": "accept"|"decline"|"negotiate"|"other" }.
    static let schema: JSONSchema = .object(properties: ["intent": .string], required: ["intent"])

    public func classify(reply: Message) async throws -> DealStage {
        let prompt = Self.buildPrompt(reply: reply)
        let raw = try await generator.generateJSON(prompt: prompt, schema: Self.schema)
        let intent = Self.parseIntent(raw)
        return Self.stage(for: intent)
    }

    // MARK: - Pure helpers

    static func buildPrompt(reply: Message) -> String {
        """
        You are tracking a sales proposal. Classify the client's reply intent.
        Reply with JSON {"intent": one of "accept", "decline", "negotiate", "other"}.
        - "accept": the client agrees / wants to proceed / approves.
        - "decline": the client says no / chose someone else / passes.
        - "negotiate": the client wants changes, a lower price, or more discussion.
        - "other": anything else / unclear.

        From: \(reply.from)
        Subject: \(reply.subject)
        Body:
        \(reply.body)
        """
    }

    /// Safe parse — tolerates prose/markdown-wrapped output by extracting the first balanced
    /// JSON object (shared `JSONExtraction`). unknown/missing/garbage/empty → "other".
    static func parseIntent(_ raw: String) -> String {
        guard
            let data = JSONExtraction.firstObject(in: raw),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let intent = object["intent"] as? String
        else { return "other" }
        return intent.lowercased()
    }

    static func stage(for intent: String) -> DealStage {
        switch intent {
        case "accept": return .won
        case "decline": return .lost
        case "negotiate": return .negotiation
        default: return .negotiation   // ambiguity stays in active discussion
        }
    }
}
