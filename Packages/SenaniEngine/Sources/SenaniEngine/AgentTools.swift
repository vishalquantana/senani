import SenaniRules
import SenaniInference

public struct AgentTools: Sendable {
    private let generator: any TextGenerator

    public init(generator: any TextGenerator) {
        self.generator = generator
    }

    /// An outbound reply. Maps to `Action.reply(body:)`, whose `actionClass == .outbound`,
    /// so `ActionRouter` ALWAYS routes it to the approval queue (never auto-sent).
    public func reply(to message: Message, body: String) -> Action { .reply(body: body) }

    /// Alias kept so the Reply Drafter plan's `draftReply(...)` call sites compile regardless of
    /// merge order. Both map to the same outbound `Action.reply`.
    public func draftReply(to message: Message, body: String) -> Action { reply(to: message, body: body) }
    /// A follow-up nudge. Maps to outbound `Action.reply`.
    public func followUpReply(to message: Message, body: String) -> Action { reply(to: message, body: body) }

    public func proposeLabel(_ label: String, on message: Message) -> Action { .label(label) }
    public func archive(_ message: Message) -> Action { .archive }
    public func markRead(_ message: Message) -> Action { .markRead }

    public func generateJSON(prompt: String, schema: JSONSchema) async throws -> String {
        try await generator.generateJSON(prompt: prompt, schema: schema)
    }
}
