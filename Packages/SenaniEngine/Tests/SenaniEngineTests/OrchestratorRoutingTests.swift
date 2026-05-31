import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniStore

// A triage agent that tags everything as one fixed category (and nothing else).
private func fixedTriage(_ category: String) -> FakeAgent {
    FakeAgent(id: "triage", autonomy: .auto,
              wakes: { _, _ in true },
              emit: { _, _, _ in [.label(category)] })
}

private func makeOrchestrator(_ h: EngineHarness,
                              triage: any Agent,
                              agents: [any Agent]) -> Orchestrator {
    Orchestrator(registry: AgentRegistry(agents: agents),
                 triage: triage,
                 mailBackend: h.backend,
                 approvals: h.approvals,
                 audit: h.audit,
                 messages: h.messages,
                 index: h.index,
                 embedder: h.embedder,
                 generator: h.generator,
                 pipeline: h.pipeline,
                 rules: h.rules,
                 now: h.now)
}

@Test func outboundActionQueuesRegardlessOfAutonomy() async throws {
    let h = try EngineHarness()
    let message = msg("m1", labels: ["Lead"])
    try h.messages.save(message)

    // Agent set to .auto, but emits an OUTBOUND .send — must STILL queue.
    let sender = FakeAgent(id: "sender", autonomy: .auto, categories: ["Lead"],
                           wakes: { m, _ in m.labels.contains("Lead") },
                           emit: { _, _, _ in [.send(body: "Hi")] })
    let orch = makeOrchestrator(h, triage: fixedTriage("Lead"), agents: [sender])

    let outcomes = try await orch.process(message)

    let sendOutcome = outcomes.first { $0.agentId == "sender" }
    #expect(sendOutcome?.outcome == .queuedForApproval)
    let applied = await h.backend.applied
    #expect(applied.contains { $0.action == .send(body: "Hi") } == false)
    let pending = try h.approvals.pending()
    #expect(pending.contains { $0.proposal.action == .send(body: "Hi") })
}

@Test func reversibleAutoExecutesViaMailBackend() async throws {
    let h = try EngineHarness()
    let message = msg("m2", labels: ["Lead"])
    try h.messages.save(message)

    let labeler = FakeAgent(id: "labeler", autonomy: .auto, categories: ["Lead"],
                            wakes: { m, _ in m.labels.contains("Lead") },
                            emit: { _, _, tools in [tools.proposeLabel("Hot", on: msg("x"))] })
    let orch = makeOrchestrator(h, triage: fixedTriage("Lead"), agents: [labeler])

    let outcomes = try await orch.process(message)

    let labelOutcome = outcomes.first { $0.agentId == "labeler" }
    #expect(labelOutcome?.outcome == .executed)
    let applied = await h.backend.applied
    #expect(applied.contains { $0.action == .label("Hot") && $0.messageId == "m2" })
    #expect(try h.approvals.pending().contains { $0.proposal.action == .label("Hot") } == false)
}

@Test func reversibleAskQueues() async throws {
    let h = try EngineHarness()
    let message = msg("m3", labels: ["Lead"])
    try h.messages.save(message)

    let labeler = FakeAgent(id: "labeler", autonomy: .ask, categories: ["Lead"],
                            wakes: { m, _ in m.labels.contains("Lead") },
                            emit: { _, _, tools in [tools.archive(msg("x"))] })
    let orch = makeOrchestrator(h, triage: fixedTriage("Lead"), agents: [labeler])

    let outcomes = try await orch.process(message)

    let archiveOutcome = outcomes.first { $0.agentId == "labeler" }
    #expect(archiveOutcome?.outcome == .queuedForApproval)
    let applied = await h.backend.applied
    #expect(applied.contains { $0.action == .archive } == false)
    #expect(try h.approvals.pending().contains { $0.proposal.action == .archive })
}
