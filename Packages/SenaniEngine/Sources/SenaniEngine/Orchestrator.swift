import Foundation
import SenaniRules
import SenaniStore
import SenaniInference

public actor Orchestrator {
    private let registry: AgentRegistry
    private let triage: any Agent
    private let mailBackend: any MailBackend
    private let approvals: ApprovalStore
    private let audit: any AuditLog
    private let messages: MessageStore
    private let index: any VectorIndex
    private let embedder: any Embedder
    private let generator: any TextGenerator
    private let pipeline: any PipelineStore
    private let rules: RuleStore
    private let now: @Sendable () -> Date

    public init(registry: AgentRegistry,
                triage: any Agent,
                mailBackend: any MailBackend,
                approvals: ApprovalStore,
                audit: any AuditLog,
                messages: MessageStore,
                index: any VectorIndex,
                embedder: any Embedder,
                generator: any TextGenerator,
                pipeline: any PipelineStore,
                rules: RuleStore,
                now: @escaping @Sendable () -> Date) {
        self.registry = registry
        self.triage = triage
        self.mailBackend = mailBackend
        self.approvals = approvals
        self.audit = audit
        self.messages = messages
        self.index = index
        self.embedder = embedder
        self.generator = generator
        self.pipeline = pipeline
        self.rules = rules
        self.now = now
    }

    public func process(_ message: Message) async throws -> [ProcessedOutcome] {
        let context = try buildContext(for: message)
        let tools = AgentTools(generator: generator)
        var results: [ProcessedOutcome] = []

        var category = ""
        if triage.wakesFor(message, context: context) {
            let triageActions = try await triage.proposals(for: message, context: context, tools: tools)
            for action in triageActions {
                if case let .label(value) = action, category.isEmpty {
                    category = value
                }
            }
            results += try await route(triageActions, by: triage, on: message)
        }

        for agent in registry.agents(for: category) where agent.wakesFor(message, context: context) {
            let actions = try await agent.proposals(for: message, context: context, tools: tools)
            results += try await route(actions, by: agent, on: message)
        }

        return results
    }

    public func processInbox() async throws -> [ProcessedOutcome] {
        var all: [ProcessedOutcome] = []
        for message in try messages.all() {
            all += try await process(message)
        }
        return all
    }

    private func route(_ actions: [Action], by agent: any Agent, on message: Message) async throws -> [ProcessedOutcome] {
        let trigger = Trigger.rule(id: agent.id)
        var outcomes: [ProcessedOutcome] = []
        for (offset, action) in actions.enumerated() {
            let outcome = ActionRouter.route(action, autonomy: agent.autonomy)
            switch outcome {
            case .executed, .prepared:
                try await mailBackend.apply(action, to: message)
            case .queuedForApproval:
                let id = "\(message.id)#\(agent.id)#\(offset)"
                try approvals.enqueue(id: id, Proposal(action: action, message: message, trigger: trigger))
            }
            await audit.record(ActionRecord(
                action: action, messageId: message.id, trigger: trigger, outcome: outcome))
            outcomes.append(ProcessedOutcome(agentId: agent.id, action: action, outcome: outcome))
        }
        return outcomes
    }

    private func buildContext(for message: Message) throws -> AgentContext {
        let thread = try messages.thread(id: message.threadId)
        let allRules = try rules.all()
        let embedder = self.embedder
        let index = self.index
        let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit] = { query, k in
            let vector = try await embedder.embed(query)
            return try index.search(vector: vector, k: k)
        }
        return AgentContext(account: message.isFromUser ? message.from : (message.to.first ?? ""),
                            thread: thread.isEmpty ? [message] : thread,
                            rules: allRules,
                            retrieve: retrieve,
                            now: now(),
                            pipeline: pipeline)
    }
}
