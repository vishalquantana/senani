import SenaniInference
import SenaniRules
import SenaniStore

public struct AssistantController: Sendable {
    private let generator: any TextGenerator
    private let messages: MessageStore
    private let rules: RuleStore
    private let dispatcher: ChatActionDispatcher
    private let sessions: ChatSessionStore

    public init(generator: any TextGenerator, messages: MessageStore, rules: RuleStore, dispatcher: ChatActionDispatcher, sessions: ChatSessionStore) {
        self.generator = generator
        self.messages = messages
        self.rules = rules
        self.dispatcher = dispatcher
        self.sessions = sessions
    }

    public func handle(userText: String, context: AssistantContext) async throws -> AssistantResponse {
        try sessions.append(sessionId: context.sessionId, turn: ChatTurn(role: "user", text: userText, timestamp: 0))
        let prompt = try buildPrompt(userText: userText, context: context)
        let raw = try await generator.generateJSON(prompt: prompt, schema: ToolSchema.schema)
        guard let call = ToolCall.parse(raw) else {
            return AssistantResponse(kind: .text, text: "I could not understand that request.")
        }

        switch call.tool {
        case .searchMessages:
            let results = try messages.all().prefix(5).map { "\($0.id): \($0.subject)" }.joined(separator: "\n")
            let response = AssistantResponse(kind: .text, text: results)
            try sessions.append(sessionId: context.sessionId, turn: ChatTurn(role: "assistant", text: response.text, timestamp: 0))
            return response
        case .createRuleDraft:
            let rule = Rule(
                id: "draft.\(context.sessionId)",
                name: call.ruleName ?? "Draft rule",
                enabled: false,
                conditions: Conditions(mode: .all, structured: [], aiPredicate: userText),
                actions: [.label("Review")],
                autonomy: .ask,
                runOn: .incoming
            )
            _ = try rules.enabled()
            return AssistantResponse(kind: .ruleDraft(rule), text: "Drafted rule: \(rule.name)")
        case .archive, .draft, .reply:
            guard let id = call.messageId,
                  let message = try messages.fetch(id: id),
                  let action = call.action()
            else {
                return AssistantResponse(kind: .text, text: "Message not found.")
            }
            let result = try await dispatcher.dispatch(action: action, message: message, turnId: context.sessionId)
            return AssistantResponse(kind: .actionDispatched, text: "Action \(result.outcome) for \(message.id)")
        }
    }

    private func buildPrompt(userText: String, context: AssistantContext) throws -> String {
        let history = try sessions.transcript(sessionId: context.sessionId).map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        return """
        Account: \(context.accountEmail)
        Conversation:
        \(history)
        User: \(userText)
        Return one JSON tool call.
        """
    }
}
