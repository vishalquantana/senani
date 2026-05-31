import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniStore
import SenaniInference

// Finding 1: Orchestrator must populate AgentContext.needsReply / documentFields / invoices
// from injectable seams, instead of leaving them at their defaults.

private func triageTagging(_ category: String) -> FakeAgent {
    FakeAgent(id: "triage", autonomy: .auto, wakes: { _, _ in true },
              emit: { _, _, _ in [.label(category)] })
}

// An agent that wakes ONLY when context.needsReply is true, and records that it ran.
private func needsReplyGated(_ id: String, category: String) -> FakeAgent {
    FakeAgent(id: id, autonomy: .auto, categories: [category],
              wakes: { m, ctx in m.labels.contains(category) && ctx.needsReply },
              emit: { m, _, tools in [tools.draftReply(to: m, body: "drafted")] })
}

// An agent that writes whatever documentFields it sees into the injected invoice store.
private func invoiceCapturing(_ id: String, category: String) -> FakeAgent {
    FakeAgent(id: id, autonomy: .auto, categories: [category],
              wakes: { m, _ in m.labels.contains(category) },
              emit: { m, ctx, _ in
                  let amount = ctx.documentFields["amount"].flatMap(Double.init)
                  try? ctx.invoices.upsert(InvoiceRecord(
                      id: "cap:\(m.id)", messageId: m.id,
                      vendor: ctx.documentFields["vendor"], invoiceNumber: nil,
                      amount: amount, currency: nil, dueDate: nil, capturedAt: ctx.now))
                  return []
              })
}

@Test func injectedNeedsReplyProviderWakesGatedAgent() async throws {
    let h = try EngineHarness()
    let message = msg("m1", labels: ["Lead"])
    try h.messages.save(message)

    let drafter = needsReplyGated("reply-drafter", category: "Lead")
    let orch = Orchestrator(
        registry: AgentRegistry(agents: [drafter]), triage: triageTagging("Lead"),
        mailBackend: h.backend, approvals: h.approvals, audit: h.audit,
        messages: h.messages, index: h.index, embedder: h.embedder,
        generator: h.generator, pipeline: h.pipeline, rules: h.rules,
        needsReply: { _ in true },
        now: h.now)

    let outcomes = try await orch.process(message)
    #expect(outcomes.contains { $0.agentId == "reply-drafter" && $0.action == .reply(body: "drafted") })
}

@Test func defaultNeedsReplyProviderLeavesGatedAgentAsleep() async throws {
    let h = try EngineHarness()
    let message = msg("m1b", labels: ["Lead"])
    try h.messages.save(message)

    let drafter = needsReplyGated("reply-drafter", category: "Lead")
    // No needsReply seam injected -> defaults to false -> drafter stays asleep.
    let orch = Orchestrator(
        registry: AgentRegistry(agents: [drafter]), triage: triageTagging("Lead"),
        mailBackend: h.backend, approvals: h.approvals, audit: h.audit,
        messages: h.messages, index: h.index, embedder: h.embedder,
        generator: h.generator, pipeline: h.pipeline, rules: h.rules,
        now: h.now)

    let outcomes = try await orch.process(message)
    #expect(outcomes.contains { $0.agentId == "reply-drafter" } == false)
}

@Test func injectedInvoiceStoreCapturesAgentWrite() async throws {
    let h = try EngineHarness()
    let message = msg("m2", labels: ["Invoice"])
    try h.messages.save(message)

    let store = InMemoryInvoiceStore()
    let capture = invoiceCapturing("invoice", category: "Invoice")
    let orch = Orchestrator(
        registry: AgentRegistry(agents: [capture]), triage: triageTagging("Invoice"),
        mailBackend: h.backend, approvals: h.approvals, audit: h.audit,
        messages: h.messages, index: h.index, embedder: h.embedder,
        generator: h.generator, pipeline: h.pipeline, rules: h.rules,
        documentFields: { _ in ["vendor": "Acme", "amount": "42.0"] },
        invoices: store,
        now: h.now)

    _ = try await orch.process(message)

    let records = try store.all()
    #expect(records.count == 1)
    #expect(records.first?.vendor == "Acme")
    #expect(records.first?.amount == 42.0)
}
