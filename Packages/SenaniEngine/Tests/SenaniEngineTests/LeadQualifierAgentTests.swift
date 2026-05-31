import Testing
@testable import SenaniEngine
import SenaniRules
import Foundation

private let leadLabel = "Senani/Category/Lead"

private func leadMsg(_ id: String, from: String = "buyer@acme.com",
                     subject: String = "Interested in your product",
                     body: String = "We'd like a demo and pricing.",
                     isFromUser: Bool = false,
                     extraLabels: [String] = []) -> Message {
    Message(id: id, from: from, to: ["me@x.com"], subject: subject, body: body,
            hasAttachment: false, listUnsubscribeHeader: nil,
            labels: [leadLabel] + extraLabels,
            threadId: "t-\(id)", date: Date(), isFromUser: isFromUser)
}

@Test func identityAndAutonomy() {
    let agent = LeadQualifierAgent()
    #expect(agent.id == "lead-qualifier")
    #expect(agent.autonomy == .auto)   // reversible label -> Orchestrator may auto-apply
}

@Test func wakesForLeadCategoryMessages() {
    let agent = LeadQualifierAgent()
    #expect(agent.wakesFor(leadMsg("m1"), context: ctx()) == true)
}

@Test func ignoresNonLeadMessages() {
    let agent = LeadQualifierAgent()
    let booking = Message(id: "m2", from: "x@y.com", to: ["me@x.com"], subject: "s", body: "b",
                          hasAttachment: false, listUnsubscribeHeader: nil,
                          labels: ["Senani/Category/Booking"], threadId: "t2",
                          date: Date(), isFromUser: false)
    #expect(agent.wakesFor(booking, context: ctx()) == false)
    let untriaged = Message(id: "m3", from: "x@y.com", to: ["me@x.com"], subject: "s", body: "b",
                            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
                            threadId: "t3", date: Date(), isFromUser: false)
    #expect(agent.wakesFor(untriaged, context: ctx()) == false)
}

@Test func ignoresMessagesFromTheUser() {
    let agent = LeadQualifierAgent()
    #expect(agent.wakesFor(leadMsg("m4", isFromUser: true), context: ctx()) == false)
}

@Test func ignoresAlreadyQualifiedLeads() {
    let agent = LeadQualifierAgent()
    #expect(agent.wakesFor(leadMsg("m5", extraLabels: ["Senani/Lead/Hot"]), context: ctx()) == false)
}

@Test func hotScoreEmitsHotLabelAndUpsertsQualifiedDeal() async throws {
    let store = InMemoryPipelineStore()
    let gen = FakeTextGenerator(response:
        #"{"score":88,"company":"Acme Corp","intent":"ready","reason":"wants a quote now"}"#)
    let agent = LeadQualifierAgent()
    let m = leadMsg("m1", from: "buyer@acme.com")
    let actions = try await agent.proposals(for: m, context: ctx(pipeline: store), tools: tools(gen))

    // Label: one reversible Hot label.
    #expect(actions == [.label("Senani/Lead/Hot")])
    #expect(actions[0].actionClass == .reversible)

    // Deal: upserted with the right fields.
    let all = try store.all()
    let deal = try #require(all.first)
    #expect(all.count == 1)
    #expect(deal.contactEmail == "buyer@acme.com")
    #expect(deal.stage == .qualified)
    #expect(deal.score == 88)
    #expect(deal.company == "Acme Corp")
    #expect(deal.sourceMessageId == "m1")
    #expect(deal.id == "buyer@acme.com")   // deterministic id = contact email
}

@Test func warmAndColdThresholdsMapToLabelsAndScores() async throws {
    let agent = LeadQualifierAgent()

    let warmStore = InMemoryPipelineStore()
    let warm = try await agent.proposals(for: leadMsg("w"), context: ctx(pipeline: warmStore),
        tools: tools(FakeTextGenerator(response:
            #"{"score":55,"company":"Beta","intent":"evaluating","reason":"comparing"}"#)))
    #expect(warm == [.label("Senani/Lead/Warm")])
    #expect(try warmStore.byContact("buyer@acme.com")?.score == 55)

    let coldStore = InMemoryPipelineStore()
    let cold = try await agent.proposals(for: leadMsg("c"), context: ctx(pipeline: coldStore),
        tools: tools(FakeTextGenerator(response:
            #"{"score":12,"company":"","intent":"info","reason":"newsletter-ish"}"#)))
    #expect(cold == [.label("Senani/Lead/Cold")])
    let all = try coldStore.all()
    let coldDeal = try #require(all.first)
    #expect(coldDeal.score == 12)
    #expect(coldDeal.company == nil)   // blank company -> nil
}

@Test func malformedModelOutputFallsBackToColdAndStillUpserts() async throws {
    let store = InMemoryPipelineStore()
    let agent = LeadQualifierAgent()
    let actions = try await agent.proposals(for: leadMsg("m1"), context: ctx(pipeline: store),
        tools: tools(FakeTextGenerator(response: "I cannot comply </think>")))
    #expect(actions == [.label("Senani/Lead/Cold")])
    let all = try store.all()
    let deal = try #require(all.first)
    #expect(deal.score == 0)
    #expect(deal.stage == .qualified)   // still recorded in the pipeline, as a cold qualified deal
}

@Test func reQualifyingSameContactUpdatesTheSameDeal() async throws {
    let store = InMemoryPipelineStore()
    let agent = LeadQualifierAgent()
    let m = leadMsg("m1", from: "buyer@acme.com")
    _ = try await agent.proposals(for: m, context: ctx(pipeline: store),
        tools: tools(FakeTextGenerator(response:
            #"{"score":30,"company":"Acme","intent":"info","reason":"early"}"#)))
    // A later message from the same contact, hotter:
    let m2 = leadMsg("m9", from: "buyer@acme.com")
    _ = try await agent.proposals(for: m2, context: ctx(pipeline: store),
        tools: tools(FakeTextGenerator(response:
            #"{"score":90,"company":"Acme","intent":"ready","reason":"wants contract"}"#)))
    #expect(try store.all().count == 1)               // updated, not duplicated
    let deal = try #require(try store.byContact("buyer@acme.com"))
    #expect(deal.score == 90)
    #expect(deal.sourceMessageId == "m9")              // latest touch wins
}

@Test func leadQualifierPromptIncludesMessageSignalsAndPolicy() async throws {
    let gen = FakeTextGenerator(response: #"{"score":0,"company":"","intent":"info","reason":""}"#)
    let agent = LeadQualifierAgent()
    let m = leadMsg("m1", from: "vp@bigco.com", subject: "Budget approved for Q3",
                    body: "We have $50k allocated and want to start next month.")
    _ = try await agent.proposals(for: m, context: ctx(pipeline: InMemoryPipelineStore()), tools: tools(gen))
    let prompts = await gen.recordedPrompts
    let lastPrompt = try #require(prompts.last)
    #expect(lastPrompt.contains("vp@bigco.com"))
    #expect(lastPrompt.contains("Budget approved for Q3"))
    #expect(lastPrompt.contains("$50k"))
    #expect(lastPrompt.contains("0"))            // score range mentioned
    #expect(lastPrompt.contains("100"))
    for intent in LeadIntent.allCases { #expect(lastPrompt.contains(intent.rawValue)) }
}
