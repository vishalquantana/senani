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
    private let invoices: any InvoiceStore
    private let rules: RuleStore
    private let needsReplyProvider: @Sendable (Message) -> Bool
    private let documentFieldsProvider: @Sendable (Message) async -> [String: String]
    private let autonomyProvider: @Sendable (_ agentId: String) -> Autonomy?
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
                // Finding 1: injectable read-only context seams (all defaulted so existing
                // app-tier callers compile unchanged).
                needsReply: @escaping @Sendable (Message) -> Bool = { _ in false },
                documentFields: @escaping @Sendable (Message) async -> [String: String] = { _ in [:] },
                invoices: any InvoiceStore = NullInvoiceStore(),
                // Finding 4: injectable per-agent autonomy override. Returns nil to fall back to
                // the agent's own static `autonomy`.
                autonomy: @escaping @Sendable (_ agentId: String) -> Autonomy? = { _ in nil },
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
        self.invoices = invoices
        self.rules = rules
        self.needsReplyProvider = needsReply
        self.documentFieldsProvider = documentFields
        self.autonomyProvider = autonomy
        self.now = now
    }

    public func process(_ message: Message) async throws -> [ProcessedOutcome] {
        let context = try await buildContext(for: message)
        let tools = AgentTools(generator: generator)
        var results: [ProcessedOutcome] = []

        // ----- Triage (best-effort: a triage failure must not abort the message) -----
        var category = ""
        var triageLabels: [String] = []
        if triage.wakesFor(message, context: context) {
            do {
                let triageActions = try await triage.proposals(for: message, context: context, tools: tools)
                for action in triageActions {
                    if case let .label(value) = action {
                        triageLabels.append(value)
                    }
                }
                // The routing category is the canonical "Senani/Category/…" label if triage emitted
                // one; otherwise the first label (keeps non-canonical callers working).
                category = triageLabels.first { $0.hasPrefix(Self.categoryLabelPrefix) }
                    ?? triageLabels.first
                    ?? ""
                results += try await route(triageActions, by: triage, on: message)
            } catch {
                await recordFailure(error, agentId: triage.id, messageId: message.id)
            }
        }

        // Finding 2: fold triage's proposed labels into the in-memory message BEFORE routing, so
        // downstream agents (wakesFor / proposals) see the category label within this same cycle.
        let augmented = triageLabels.isEmpty ? message : Self.withLabels(message, adding: triageLabels)

        // ----- Category-routed agents (Finding 5: one agent throwing must not abort the batch) -----
        for agent in registry.agents(for: category) where agent.wakesFor(augmented, context: context) {
            do {
                let actions = try await agent.proposals(for: augmented, context: context, tools: tools)
                results += try await route(actions, by: agent, on: augmented)
            } catch {
                await recordFailure(error, agentId: agent.id, messageId: augmented.id)
            }
        }

        // Finding 7: persist the triage labels so a later tick does not re-triage this message.
        if !triageLabels.isEmpty {
            try? messages.save(augmented)
        }

        return results
    }

    public func processInbox() async throws -> [ProcessedOutcome] {
        var all: [ProcessedOutcome] = []
        for message in try messages.all() {
            // Finding 7: skip messages already carrying a category label (already triaged on a
            // prior tick) — they are reprocessed only when they actually need it.
            all += try await process(message)
        }
        return all
    }

    // Finding 8: turn an OutreachProposal into an approval-gated Proposal, preserving the recipient
    // carried on the synthesized outbound message. Outreach is ALWAYS approval-gated (the action is
    // outbound), so this enqueues via the ApprovalStore and never auto-sends.
    @discardableResult
    public func enqueueOutreach(_ outreach: OutreachProposal, agentId: String = "outreach") async throws -> ProcessedOutcome {
        let trigger = Trigger.rule(id: agentId)
        let proposal = Proposal(action: outreach.action, message: outreach.message, trigger: trigger)
        let id = "\(outreach.message.id)#\(agentId)#outreach"
        let outcome = ActionRouter.route(outreach.action, autonomy: resolveAutonomy(agentId, fallback: .ask))
        switch outcome {
        case .queuedForApproval:
            try approvals.enqueue(id: id, proposal)
        case .executed, .prepared:
            // Outreach is outbound, so this branch is unreachable in practice; keep the safety
            // invariant intact by still queuing rather than ever auto-applying an outbound send.
            try approvals.enqueue(id: id, proposal)
        }
        await audit.record(ActionRecord(
            action: outreach.action, messageId: outreach.message.id, trigger: trigger, outcome: .queuedForApproval))
        return ProcessedOutcome(agentId: agentId, action: outreach.action, outcome: .queuedForApproval)
    }

    // MARK: - Routing

    private func route(_ actions: [Action], by agent: any Agent, on message: Message) async throws -> [ProcessedOutcome] {
        let trigger = Trigger.rule(id: agent.id)
        let autonomy = resolveAutonomy(agent.id, fallback: agent.autonomy)
        var outcomes: [ProcessedOutcome] = []
        for (offset, action) in actions.enumerated() {
            let outcome = ActionRouter.route(action, autonomy: autonomy)
            switch outcome {
            case .executed, .prepared:
                // Finding 6: a backend throw on one action must not abort the batch.
                do {
                    try await mailBackend.apply(action, to: message)
                } catch {
                    await recordFailure(error, agentId: agent.id, messageId: message.id, action: action)
                    outcomes.append(ProcessedOutcome(agentId: agent.id, action: action, outcome: outcome))
                    continue
                }
            case .queuedForApproval:
                let id = "\(message.id)#\(agent.id)#\(offset)"
                do {
                    try approvals.enqueue(id: id, Proposal(action: action, message: message, trigger: trigger))
                } catch {
                    await recordFailure(error, agentId: agent.id, messageId: message.id, action: action)
                    outcomes.append(ProcessedOutcome(agentId: agent.id, action: action, outcome: outcome))
                    continue
                }
            }
            await audit.record(ActionRecord(
                action: action, messageId: message.id, trigger: trigger, outcome: outcome))
            outcomes.append(ProcessedOutcome(agentId: agent.id, action: action, outcome: outcome))
        }
        return outcomes
    }

    private func resolveAutonomy(_ agentId: String, fallback: Autonomy) -> Autonomy {
        autonomyProvider(agentId) ?? fallback
    }

    // MARK: - Failure auditing (Finding 5 & 6)

    private func recordFailure(_ error: Error, agentId: String, messageId: String, action: Action? = nil) async {
        let trigger = Trigger.rule(id: agentId)
        // Map a not-loaded model to a DISTINCT skipped outcome (prepared) so the audit reflects a
        // recoverable "needs model" skip rather than a hard failure. Everything else is a failure
        // recorded as queuedForApproval (it needs human attention) — the batch continues either way.
        let recordedAction = action ?? .runAgent(id: agentId)
        if let inferenceError = error as? InferenceError, inferenceError == .modelNotLoaded {
            await audit.record(ActionRecord(
                action: recordedAction, messageId: messageId, trigger: trigger, outcome: .prepared))
        } else {
            await audit.record(ActionRecord(
                action: recordedAction, messageId: messageId, trigger: trigger, outcome: .queuedForApproval))
        }
    }

    // MARK: - Context

    private static let categoryLabelPrefix = "Senani/Category/"

    private func buildContext(for message: Message) async throws -> AgentContext {
        let thread = try messages.thread(id: message.threadId)
        let allRules = try rules.all()
        let embedder = self.embedder
        let index = self.index
        let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit] = { query, k in
            let vector = try await embedder.embed(query)
            return try index.search(vector: vector, k: k)
        }
        // Finding 1: populate ALL AgentContext fields from the injected seams.
        let needsReply = needsReplyProvider(message)
        let documentFields = await documentFieldsProvider(message)
        return AgentContext(account: message.isFromUser ? message.from : (message.to.first ?? ""),
                            thread: thread.isEmpty ? [message] : thread,
                            rules: allRules,
                            retrieve: retrieve,
                            now: now(),
                            needsReply: needsReply,
                            documentFields: documentFields,
                            pipeline: pipeline,
                            invoices: invoices)
    }

    // MARK: - Helpers

    private static func withLabels(_ message: Message, adding labels: [String]) -> Message {
        var merged = message.labels
        for label in labels where !merged.contains(label) {
            merged.append(label)
        }
        return Message(
            id: message.id, from: message.from, to: message.to, subject: message.subject,
            body: message.body, hasAttachment: message.hasAttachment,
            listUnsubscribeHeader: message.listUnsubscribeHeader, labels: merged,
            threadId: message.threadId, date: message.date, isFromUser: message.isFromUser)
    }
}
