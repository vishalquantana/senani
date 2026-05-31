import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

private func categoryAgent(_ id: String, category: String) -> FakeAgent {
    // Wakes only when the probe message carries the matching category label.
    FakeAgent(id: id, autonomy: .auto,
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
