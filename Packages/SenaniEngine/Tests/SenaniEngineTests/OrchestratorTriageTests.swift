import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniStore

private func triageTagging(_ category: String) -> FakeAgent {
    FakeAgent(id: "triage", autonomy: .auto,
              wakes: { _, _ in true },
              emit: { _, _, _ in [.label(category)] })
}

// Subscribes to `category` (declares it; the Orchestrator routes by `categories`) and wakes when
// the augmented message carries that label, emitting a unique reversible marker label.
private func subscriber(_ id: String, category: String, marker: String) -> FakeAgent {
    FakeAgent(id: id, autonomy: .auto, categories: [category],
              wakes: { m, _ in m.labels.contains(category) },
              emit: { _, _, tools in [tools.proposeLabel(marker, on: msg("x"))] })
}

private func makeOrchestrator(_ h: EngineHarness, triage: any Agent, agents: [any Agent]) -> Orchestrator {
    Orchestrator(registry: AgentRegistry(agents: agents), triage: triage,
                 mailBackend: h.backend, approvals: h.approvals, audit: h.audit,
                 messages: h.messages, index: h.index, embedder: h.embedder,
                 generator: h.generator, pipeline: h.pipeline, rules: h.rules, now: h.now)
}

@Test func triageCategoryRoutesToTheRightAgents() async throws {
    let h = try EngineHarness()
    // Real message carries BOTH category labels so wakesFor passes; dispatch must be driven
    // by triage's chosen category ("Lead"), routing ONLY to the Lead subscriber.
    let message = msg("m1", labels: ["Lead", "Invoice"])
    try h.messages.save(message)

    let leadAgent = subscriber("lead", category: "Lead", marker: "LEAD_RAN")
    let invoiceAgent = subscriber("invoice", category: "Invoice", marker: "INVOICE_RAN")
    let orch = makeOrchestrator(h, triage: triageTagging("Lead"), agents: [leadAgent, invoiceAgent])

    let outcomes = try await orch.process(message)

    #expect(outcomes.contains { $0.agentId == "lead" && $0.action == .label("LEAD_RAN") })
    #expect(outcomes.contains { $0.agentId == "invoice" } == false)
}

@Test func agentSubscribedButNotWakingForRealMessageIsSkipped() async throws {
    let h = try EngineHarness()
    // The real message has category "Lead" but NOT the extra "Priority" label the agent also requires.
    let message = msg("m2", labels: ["Lead"])
    try h.messages.save(message)

    let pickyAgent = FakeAgent(id: "picky", autonomy: .auto, categories: ["Lead"],
                               // Subscribes to "Lead" by category, but ALSO requires "Priority" on the real msg.
                               wakes: { m, _ in m.labels.contains("Lead") && m.labels.contains("Priority") },
                               emit: { _, _, tools in [tools.proposeLabel("PICKY_RAN", on: msg("x"))] })
    let orch = makeOrchestrator(h, triage: triageTagging("Lead"), agents: [pickyAgent])

    let outcomes = try await orch.process(message)

    #expect(outcomes.contains { $0.agentId == "picky" } == false)
}

@Test func emptyCategoryRoutesToNoSubscribers() async throws {
    let h = try EngineHarness()
    let message = msg("m3", labels: ["Lead"])
    try h.messages.save(message)

    // Triage emits no label => category stays "" => no subscribers.
    let silentTriage = FakeAgent(id: "triage", autonomy: .auto,
                                 wakes: { _, _ in true }, emit: { _, _, _ in [] })
    let leadAgent = subscriber("lead", category: "Lead", marker: "LEAD_RAN")
    let orch = makeOrchestrator(h, triage: silentTriage, agents: [leadAgent])

    let outcomes = try await orch.process(message)
    #expect(outcomes.contains { $0.agentId == "lead" } == false)
}
