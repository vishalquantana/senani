import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniStore
import SenaniInference

// ---- Message factory ----

func msg(_ id: String,
         from: String = "a@b.com",
         to: [String] = ["me@x.com"],
         subject: String = "S",
         body: String = "B",
         labels: [String] = [],
         threadId: String = "t1",
         isFromUser: Bool = false,
         date: Date = Date(timeIntervalSince1970: 1_000)) -> Message {
    Message(id: id, from: from, to: to, subject: subject, body: body,
            hasAttachment: false, listUnsubscribeHeader: nil, labels: labels,
            threadId: threadId, date: date, isFromUser: isFromUser)
}

// ---- MailBackend spy ----

actor FakeMailBackend: MailBackend {
    private(set) var applied: [(action: Action, messageId: String)] = []
    func apply(_ action: Action, to message: Message) async throws {
        applied.append((action, message.id))
    }
}

// ---- TextGenerator fake (no MLX) — returns canned strings/JSON in FIFO order ----

actor FakeTextGenerator: TextGenerator {
    private var responses: [String]
    private(set) var recordedPrompts: [String] = []

    init(responses: [String] = []) { self.responses = responses }
    init(response: String) { self.responses = [response] }
    /// Append canned responses to a shared fake (used when the harness's generator is reused).
    func preload(_ response: String) { responses.append(response) }
    private func next() -> String {
        if responses.count > 1 { return responses.removeFirst() }
        return responses.first ?? "{}"
    }
    func generate(prompt: String, maxTokens: Int) async throws -> String {
        recordedPrompts.append(prompt)
        return next()
    }
    func generateJSON(prompt: String, schema: JSONSchema) async throws -> String {
        recordedPrompts.append(prompt)
        return next()
    }
}

// ---- Helpers ----

func tools(_ generator: any TextGenerator) -> AgentTools { AgentTools(generator: generator) }

func ctx(now: Date = Date(timeIntervalSince1970: 1_700_000_000), 
         pipeline: PipelineStore = InMemoryPipelineStore()) -> AgentContext {
    AgentContext(account: "me@x.com", thread: [], rules: [],
                 retrieve: { _, _ in [] }, now: now, pipeline: pipeline)
}

// ---- Embedder fake (no MLX) — deterministic small vector ----

struct FakeEmbedder: Embedder {
    func embed(_ text: String) async throws -> [Float] {
        [Float(text.count), 1, 0]
    }
}

// ---- A configurable fake Agent ----

struct FakeAgent: Agent {
    let id: String
    let autonomy: Autonomy
    var categories: Set<String> = []
    var wakes: @Sendable (Message, AgentContext) -> Bool = { _, _ in true }
    var emit: @Sendable (Message, AgentContext, AgentTools) async throws -> [Action]
    func wakesFor(_ message: Message, context: AgentContext) -> Bool { wakes(message, context) }
    func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        try await emit(message, context, tools)
    }
}

// ---- An in-memory store graph the Orchestrator tests build on ----

struct EngineHarness {
    let database: SenaniDatabase
    let messages: MessageStore
    let rules: RuleStore
    let approvals: ApprovalStore
    let audit: PersistentAuditLog
    let index: InMemoryVectorIndex
    let backend: FakeMailBackend
    let embedder: FakeEmbedder
    let generator: FakeTextGenerator
    let pipeline: InMemoryPipelineStore
    let now: @Sendable () -> Date

    init() throws {
        let fixedSeconds = 1_700_000_000.0
        let fixedDate = Date(timeIntervalSince1970: fixedSeconds)
        database = try SenaniDatabase.inMemory()
        messages = MessageStore(database: database)
        rules = RuleStore(database: database)
        approvals = ApprovalStore(database: database, now: { fixedSeconds })
        audit = PersistentAuditLog(database: database, now: { fixedSeconds })
        index = InMemoryVectorIndex()
        backend = FakeMailBackend()
        embedder = FakeEmbedder()
        generator = FakeTextGenerator()
        pipeline = InMemoryPipelineStore()
        now = { fixedDate }
    }
}

// ---- self-test ----

@Test func testSupportConstructsAnInMemoryGraph() throws {
    let h = try EngineHarness()
    #expect((try? h.messages.all())?.isEmpty == true)
    let action: Action = .archive
    #expect(action.actionClass == .reversible)
}
