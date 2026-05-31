import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

private func categoryAgent(_ id: String, category: String) -> FakeAgent {
    // Declares its category (Finding 9): the registry routes by `categories`, NOT by probing wakesFor.
    FakeAgent(id: id, autonomy: .auto, categories: [category],
              wakes: { m, _ in m.labels.contains(category) },
              emit: { _, _, _ in [] })
}

@Test func registryReturnsAgentsSubscribedToACategory() {
    let lead = categoryAgent("lead-qualifier", category: "Lead")
    let invoice = categoryAgent("invoice", category: "Invoice")
    let registry = AgentRegistry(agents: [lead, invoice])

    let forLead = registry.agents(for: "Lead").map(\.id)
    #expect(forLead == ["lead-qualifier"])

    let forInvoice = registry.agents(for: "Invoice").map(\.id)
    #expect(forInvoice == ["invoice"])

    #expect(registry.agents(for: "Unknown").isEmpty)
}

@Test func registryCanReturnMultipleAgentsForOneCategory() {
    let a = categoryAgent("a", category: "Lead")
    let b = categoryAgent("b", category: "Lead")
    let registry = AgentRegistry(agents: [a, b])
    #expect(Set(registry.agents(for: "Lead").map(\.id)) == ["a", "b"])
}

// Finding 9: the previous probe-based registry passed a synthetic __probe__ message + EMPTY context,
// so an agent whose `wakesFor` needs real context (e.g. ProposalTracker reading documentFields, or
// FollowUp reading the pipeline) NEVER subscribed. Routing by declared `categories` fixes that:
// such an agent subscribes to its category regardless of what its wakesFor predicate requires.
@Test func contextNeedingAgentStillSubscribesViaCategory() {
    // This agent would have NEVER woken for an empty-context probe, but it declares its category.
    let contextHungry = FakeAgent(
        id: "proposal-tracker", autonomy: .auto, categories: ["Senani/Category/Proposal"],
        wakes: { _, ctx in !ctx.documentFields.isEmpty },   // needs real context to fire
        emit: { _, _, _ in [] })
    let registry = AgentRegistry(agents: [contextHungry])

    #expect(registry.agents(for: "Senani/Category/Proposal").map(\.id) == ["proposal-tracker"])
}

@Test func emptyCategoryReturnsNoAgents() {
    let registry = AgentRegistry(agents: [categoryAgent("a", category: "Lead")])
    #expect(registry.agents(for: "").isEmpty)
}
