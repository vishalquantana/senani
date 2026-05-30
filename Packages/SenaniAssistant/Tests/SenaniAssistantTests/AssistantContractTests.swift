import Foundation
import SenaniInference
import SenaniRules
import SenaniStore
import Testing
@testable import SenaniAssistant

@Suite struct AssistantContractTests {
    @Test func parsesToolCallsSafely() {
        #expect(ToolCall.parse(#"{"tool":"archive","messageId":"m1"}"#) == ToolCall(tool: .archive, messageId: "m1"))
        #expect(ToolCall.parse("bad") == nil)
    }

    @Test func dispatchUsesChatTriggerAndRoutesOutboundToApproval() async throws {
        let backend = SpyBackend()
        let approvals = ApprovalQueue()
        let audit = InMemoryAuditLog()
        let dispatcher = ChatActionDispatcher(backend: backend, approvals: approvals, audit: audit)
        let result = try await dispatcher.dispatch(action: .reply(body: "ok"), message: Self.message(), turnId: "turn")
        #expect(result.outcome == .queuedForApproval)
        #expect(await approvals.pending().count == 1)
        #expect(await backend.actions.isEmpty)
        #expect(await audit.records().first?.trigger == .chat(turnId: "turn"))
    }

    @Test func sessionStorePersistsTurns() throws {
        let store = ChatSessionStore(database: try SenaniDatabase.inMemory(), now: { 1 })
        try store.append(sessionId: "s", turn: ChatTurn(role: "user", text: "hi", timestamp: 1))
        #expect(try store.transcript(sessionId: "s").map(\.text) == ["hi"])
    }

    @Test func controllerSearchesAndDispatchesAction() async throws {
        let database = try SenaniDatabase.inMemory()
        let messages = MessageStore(database: database)
        try messages.save(Self.message())
        let backend = SpyBackend()
        let controller = AssistantController(
            generator: FakeGenerator(json: #"{"tool":"archive","messageId":"m1"}"#),
            messages: messages,
            rules: RuleStore(database: database),
            dispatcher: ChatActionDispatcher(backend: backend, approvals: ApprovalQueue(), audit: InMemoryAuditLog()),
            sessions: ChatSessionStore(database: database, now: { 1 })
        )
        let response = try await controller.handle(userText: "archive it", context: AssistantContext(sessionId: "s", accountEmail: "me@example.com"))
        #expect(response.kind == .actionDispatched)
        #expect(await backend.actions == [.archive])
    }

    @Test func controllerReturnsRuleDraftWithoutSaving() async throws {
        let database = try SenaniDatabase.inMemory()
        let controller = AssistantController(
            generator: FakeGenerator(json: #"{"tool":"createRuleDraft","ruleName":"VIP"}"#),
            messages: MessageStore(database: database),
            rules: RuleStore(database: database),
            dispatcher: ChatActionDispatcher(backend: SpyBackend(), approvals: ApprovalQueue(), audit: InMemoryAuditLog()),
            sessions: ChatSessionStore(database: database, now: { 1 })
        )
        let response = try await controller.handle(userText: "make a rule", context: AssistantContext(sessionId: "s", accountEmail: "me@example.com"))
        #expect(response.text.contains("VIP"))
        #expect(try RuleStore(database: database).all().isEmpty)
    }

    static func message() -> Message {
        Message(
            id: "m1",
            from: "sender@example.com",
            to: ["me@example.com"],
            subject: "Subject",
            body: "Body",
            hasAttachment: false,
            listUnsubscribeHeader: nil,
            labels: ["INBOX"],
            threadId: "t",
            date: Date(timeIntervalSince1970: 0),
            isFromUser: false
        )
    }
}

actor SpyBackend: MailBackend {
    private(set) var actions: [Action] = []
    func apply(_ action: Action, to message: Message) async throws {
        actions.append(action)
    }
}

struct FakeGenerator: TextGenerator {
    let json: String
    func generate(prompt: String, maxTokens: Int) async throws -> String { json }
    func generateJSON(prompt: String, schema: JSONSchema) async throws -> String { json }
}
