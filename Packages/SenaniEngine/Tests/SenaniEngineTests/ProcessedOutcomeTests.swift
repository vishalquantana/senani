import Testing
@testable import SenaniEngine
import SenaniRules

@Test func processedOutcomeCarriesAgentActionAndOutcome() {
    let po = ProcessedOutcome(agentId: "triage", action: .label("Lead"), outcome: .executed)
    #expect(po.agentId == "triage")
    #expect(po.action == .label("Lead"))
    #expect(po.outcome == .executed)
}
