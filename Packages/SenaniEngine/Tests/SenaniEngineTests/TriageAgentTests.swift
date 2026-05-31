import Testing
@testable import SenaniEngine
import SenaniRules
import Foundation

@Test func packageImportsCompile() {
    let action: SenaniRules.Action = .label("x")
    #expect(action.actionClass == .reversible)
}

@Test func triageIdentityAndAutonomy() {
    let agent = TriageAgent()
    #expect(agent.id == "triage")
    #expect(agent.autonomy == .auto)
}

@Test func wakesForEveryUnprocessedInboundMessage() {
    let agent = TriageAgent()
    #expect(agent.wakesFor(msg("m1"), context: ctx()) == true)
}

@Test func doesNotWakeForMessagesFromTheUser() {
    let agent = TriageAgent()
    #expect(agent.wakesFor(msg("m2", isFromUser: true), context: ctx()) == false)
}

@Test func doesNotWakeForAlreadyTriagedMessages() {
    let agent = TriageAgent()
    let triaged = msg("m3", labels: ["Senani/Category/Lead"])
    #expect(agent.wakesFor(triaged, context: ctx()) == false)
}

@Test func emitsCategoryAndPriorityLabelActions() async throws {
    let gen = FakeTextGenerator(response:
        #"{"category":"Lead","priority":"high","reason":"new prospect asking for a demo"}"#)
    let agent = TriageAgent()
    let actions = try await agent.proposals(for: msg("m1"), context: ctx(), tools: tools(gen))
    #expect(actions == [.label("Senani/Category/Lead"), .label("Senani/Priority/High")])
    #expect(actions.allSatisfy { $0.actionClass == .reversible })
}

@Test func priorityMappingNormalAndLow() async throws {
    let agent = TriageAgent()
    let normal = try await agent.proposals(for: msg("a"), context: ctx(),
        tools: tools(FakeTextGenerator(response:
            #"{"category":"Newsletter","priority":"normal","reason":"weekly digest"}"#)))
    #expect(normal == [.label("Senani/Category/Newsletter"), .label("Senani/Priority/Normal")])

    let low = try await agent.proposals(for: msg("b"), context: ctx(),
        tools: tools(FakeTextGenerator(response:
            #"{"category":"Other","priority":"low","reason":"automated receipt"}"#)))
    #expect(low == [.label("Senani/Category/Other"), .label("Senani/Priority/Low")])
}

@Test func malformedModelOutputFallsBackToOtherNormalLabels() async throws {
    let agent = TriageAgent()
    let actions = try await agent.proposals(for: msg("m1"), context: ctx(),
        tools: tools(FakeTextGenerator(response: "I cannot comply </think>")))
    #expect(actions == [.label("Senani/Category/Other"), .label("Senani/Priority/Normal")])
}

@Test func unknownCategoryFromModelMapsToOtherLabel() async throws {
    let agent = TriageAgent()
    let actions = try await agent.proposals(for: msg("m1"), context: ctx(),
        tools: tools(FakeTextGenerator(response:
            #"{"category":"Invoice","priority":"high","reason":"?"}"#)))
    #expect(actions == [.label("Senani/Category/Other"), .label("Senani/Priority/High")])
}

@Test func triagePromptIncludesMessageSignalsAndPolicy() async throws {
    let gen = FakeTextGenerator(response: #"{"category":"Other","priority":"normal","reason":""}"#)
    let agent = TriageAgent()
    let m = msg("m1", from: "ceo@bigco.com", subject: "Partnership proposal", body: "Let's talk numbers.")
    _ = try await agent.proposals(for: m, context: ctx(), tools: tools(gen))
    let prompts = await gen.recordedPrompts
    let lastPrompt = try #require(prompts.last)
    #expect(lastPrompt.contains("ceo@bigco.com"))
    #expect(lastPrompt.contains("Partnership proposal"))
    #expect(lastPrompt.contains("Let's talk numbers."))
    for c in TriageCategory.allCases { #expect(lastPrompt.contains(c.rawValue.capitalized)) }
    for p in TriagePriority.allCases { #expect(lastPrompt.contains(p.rawValue)) }
}
