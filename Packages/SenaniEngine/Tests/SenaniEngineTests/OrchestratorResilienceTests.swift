import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniStore
import SenaniInference

// Findings 2, 4, 5, 6, 7 — Orchestrator resilience & in-cycle label folding.

private func realTriageOrchestrator(
    _ h: EngineHarness,
    agents: [any Agent],
    triage: any Agent,
    autonomy: (@Sendable (String) -> Autonomy?)? = nil,
    backend: (any MailBackend)? = nil
) -> Orchestrator {
    Orchestrator(
        registry: AgentRegistry(agents: agents), triage: triage,
        mailBackend: backend ?? h.backend, approvals: h.approvals, audit: h.audit,
        messages: h.messages, index: h.index, embedder: h.embedder,
        generator: h.generator, pipeline: h.pipeline, rules: h.rules,
        autonomy: autonomy ?? { _ in nil },
        now: h.now)
}

// ---- Finding 2: triage label reaches downstream agents WITHIN one process() call ----

@Test func triageLabelReachesDownstreamAgentInSameCycle() async throws {
    let h = try EngineHarness()
    // Real TriageAgent: classifies via the model. Feed it a Lead classification.
    await h.generator.preload(#"{"category":"Lead","priority":"high","reason":"x"}"#)
    let message = msg("m1")   // NO labels yet — triage must add them in-cycle.
    try h.messages.save(message)

    // Subscriber gates on the canonical Lead category label that triage emits.
    let leadCategory = TriageCategory.lead.label
    let gated = FakeAgent(
        id: "lead-sub", autonomy: .auto, categories: [leadCategory],
        wakes: { m, _ in m.labels.contains(leadCategory) },   // ONLY wakes if the label was folded in
        emit: { _, _, tools in [tools.proposeLabel("WOKE", on: msg("x"))] })

    let orch = realTriageOrchestrator(h, agents: [gated], triage: TriageAgent())
    let outcomes = try await orch.process(message)

    #expect(outcomes.contains { $0.agentId == "lead-sub" && $0.action == .label("WOKE") })
}

// ---- Finding 4: injected autonomy override forces .ask for an otherwise-.auto agent ----

@Test func autonomyOverrideForcesReversibleActionToQueue() async throws {
    let h = try EngineHarness()
    let message = msg("m2", labels: ["Lead"])
    try h.messages.save(message)

    // Agent's STATIC autonomy is .auto -> a reversible label would normally execute.
    let labeler = FakeAgent(id: "labeler", autonomy: .auto, categories: ["Lead"],
                            wakes: { m, _ in m.labels.contains("Lead") },
                            emit: { _, _, tools in [tools.proposeLabel("Hot", on: msg("x"))] })
    let triage = FakeAgent(id: "triage", autonomy: .auto, wakes: { _, _ in true },
                           emit: { _, _, _ in [.label("Lead")] })

    // Override forces .ask for "labeler" -> the reversible action must QUEUE instead.
    let orch = realTriageOrchestrator(
        h, agents: [labeler], triage: triage,
        autonomy: { id in id == "labeler" ? .ask : nil })

    let outcomes = try await orch.process(message)
    let labelOutcome = outcomes.first { $0.agentId == "labeler" }
    #expect(labelOutcome?.outcome == .queuedForApproval)
    let applied = await h.backend.applied
    #expect(applied.contains { $0.action == .label("Hot") } == false)
    #expect(try h.approvals.pending().contains { $0.proposal.action == .label("Hot") })
}

// ---- Finding 5: one agent throwing modelNotLoaded must not abort the batch ----

struct ThrowingAgent: Agent {
    let id: String
    let autonomy: Autonomy = .auto
    var categories: Set<String>
    let error: any Error
    func wakesFor(_ message: Message, context: AgentContext) -> Bool { message.labels.contains(where: categories.contains) }
    func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        throw error
    }
}

@Test func agentThrowingModelNotLoadedDoesNotAbortBatch() async throws {
    let h = try EngineHarness()
    let message = msg("m3", labels: ["Lead"])
    try h.messages.save(message)

    let thrower = ThrowingAgent(id: "thrower", categories: ["Lead"], error: InferenceError.modelNotLoaded)
    let survivor = FakeAgent(id: "survivor", autonomy: .auto, categories: ["Lead"],
                             wakes: { m, _ in m.labels.contains("Lead") },
                             emit: { _, _, tools in [tools.proposeLabel("SURVIVED", on: msg("x"))] })
    let triage = FakeAgent(id: "triage", autonomy: .auto, wakes: { _, _ in true },
                           emit: { _, _, _ in [.label("Lead")] })
    let orch = realTriageOrchestrator(h, agents: [thrower, survivor], triage: triage)

    let outcomes = try await orch.process(message)

    // The survivor still ran despite the thrower exploding first.
    #expect(outcomes.contains { $0.agentId == "survivor" && $0.action == .label("SURVIVED") })
    // The failure was audited as a DISTINCT skipped (prepared) outcome for modelNotLoaded.
    let entries = try await h.audit.records()
    let throwerRecords = entries.filter { $0.record.trigger == .rule(id: "thrower") }
    #expect(throwerRecords.count == 1)
    #expect(throwerRecords.first?.record.outcome == .prepared)
}

@Test func triageStillLabelsWhenADownstreamAgentThrows() async throws {
    let h = try EngineHarness()
    try h.messages.saveAll([
        msg("a", labels: ["Lead"], threadId: "ta"),
        msg("b", labels: ["Lead"], threadId: "tb"),
    ])
    let triage = FakeAgent(id: "triage", autonomy: .auto, wakes: { _, _ in true },
                           emit: { _, _, _ in [.label("Lead")] })
    let thrower = ThrowingAgent(id: "thrower", categories: ["Lead"], error: InferenceError.modelNotLoaded)
    let orch = realTriageOrchestrator(h, agents: [thrower], triage: triage)

    _ = try await orch.processInbox()

    // Triage labeled BOTH messages even though the downstream agent threw on each.
    let applied = await h.backend.applied
    let labeled = Set(applied.filter { $0.action == .label("Lead") }.map(\.messageId))
    #expect(labeled == ["a", "b"])
}

// ---- Finding 6: MailBackend.apply throwing mid-batch -> record + continue ----

actor FlakyBackend: MailBackend {
    private(set) var applied: [(action: Action, messageId: String)] = []
    private let failOn: Action
    init(failOn: Action) { self.failOn = failOn }
    func apply(_ action: Action, to message: Message) async throws {
        if action == failOn {
            throw InferenceError.generationFailed("backend boom")
        }
        applied.append((action, message.id))
    }
}

@Test func backendThrowOnFirstActionStillProcessesSecond() async throws {
    let h = try EngineHarness()
    let message = msg("m4", labels: ["Lead"])
    try h.messages.save(message)
    let flaky = FlakyBackend(failOn: .label("L1"))

    // One agent emitting TWO reversible labels (auto) -> first apply throws, second succeeds.
    let twoLabels = FakeAgent(id: "two", autonomy: .auto, categories: ["Lead"],
                              wakes: { m, _ in m.labels.contains("Lead") },
                              emit: { _, _, tools in [tools.proposeLabel("L1", on: msg("x")),
                                                      tools.proposeLabel("L2", on: msg("x"))] })
    // Triage tags Lead so the agent routes; triage itself emits no extra writes the flaky backend
    // would swallow first (triage label apply could throw, but we only assert on the agent's pair).
    let triage = FakeAgent(id: "triage", autonomy: .auto, wakes: { _, _ in true },
                           emit: { _, _, _ in [.label("Lead")] })
    let orch = realTriageOrchestrator(h, agents: [twoLabels], triage: triage, backend: flaky)

    _ = try await orch.process(message)

    let applied = await flaky.applied
    #expect(applied.contains { $0.action == .label("L2") })   // second still applied
    #expect(applied.contains { $0.action == .label("L1") } == false)  // first threw
    // The failure was audited under the agent's trigger.
    let entries = try await h.audit.records()
    #expect(entries.contains { $0.record.trigger == .rule(id: "two") && $0.record.outcome == .queuedForApproval })
}

// ---- Finding 7: two ticks over the same message -> triage runs ONCE ----

@Test func reTickDoesNotReTriageAlreadyLabeledMessage() async throws {
    let h = try EngineHarness()
    await h.generator.preload(#"{"category":"Lead","priority":"normal","reason":"x"}"#)
    let message = msg("m5")   // unlabeled
    try h.messages.save(message)

    let orch = realTriageOrchestrator(h, agents: [], triage: TriageAgent())

    _ = try await orch.processInbox()   // tick 1 — triage labels it and persists
    let afterFirst = try await h.audit.records().count

    _ = try await orch.processInbox()   // tick 2 — message already carries category -> triage skips
    let afterSecond = try await h.audit.records().count

    // Audit did NOT grow on the second tick (no re-triage).
    #expect(afterSecond == afterFirst)
    // The persisted message carries the canonical category label.
    let stored = try h.messages.fetch(id: "m5")
    #expect(stored?.labels.contains(TriageCategory.lead.label) == true)
}
