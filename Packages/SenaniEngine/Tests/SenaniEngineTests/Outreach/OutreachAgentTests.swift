import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct OutreachAgentTests {
    private func agent(
        responses: [String] = ["Hi there, quick idea."],
        prefix: String = "VOICE-PREFIX"
    ) -> (OutreachAgent, FakeTextGenerator, FakeVoicePrefixProvider) {
        let gen = FakeTextGenerator(responses: responses)
        let voice = FakeVoicePrefixProvider(prefix: prefix)
        return (OutreachAgent(generator: gen, voice: voice,
                              policy: OutreachPolicy(cooldownDays: 7, maxPerRun: 25)), gen, voice)
    }

    @Test func identityAndAutonomy() {
        let (a, _, _) = agent()
        #expect(a.id == "outreach")
        #expect(a.autonomy == .ask)   // dial is moot: outbound always queues regardless
    }

    @Test func neverWakesForAnInboundMessage() {
        let (a, _, _) = agent()
        let m = msg("in", isFromUser: false)
        #expect(a.wakesFor(m, context: OX.context()) == false)
    }

    @Test func inboundProposalsAreEmpty() async throws {
        let (a, gen, _) = agent()
        let m = msg("in", isFromUser: false)
        let actions = try await a.proposals(for: m, context: OX.context(), tools: tools(gen))
        #expect(actions.isEmpty)
        let prompts = await gen.recordedPrompts
        #expect(prompts.isEmpty)   // no model call on the inbound path
    }

    @Test func producesOneOutboundSendProposalPerEligibleTarget() async throws {
        let (a, _, _) = agent(responses: ["Body one.", "Body two."])
        let targets = [OX.target(contact: "a@x.com"), OX.target(contact: "b@x.com")]
        let out = try await a.outreach(to: targets, context: OX.context(), tools: tools(FakeTextGenerator()))
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.action.actionClass == .outbound })   // every one queues
        #expect(out[0].message.to == ["a@x.com"])
        #expect(out[1].message.to == ["b@x.com"])
    }

    @Test func draftBodyComesFromTheGeneratorTrimmed() async throws {
        let (a, _, _) = agent(responses: ["\n  Hi Sarah, quick idea.  \n"])
        let out = try await a.outreach(to: [OX.target(contact: "sarah@client.com")],
                                       context: OX.context(), tools: tools(FakeTextGenerator()))
        #expect(out.first?.action == .send(body: "Hi Sarah, quick idea."))
        #expect(out.first?.message.body == "Hi Sarah, quick idea.")
    }

    @Test func voicePrefixIsThreadedIntoThePromptForEachTarget() async throws {
        let (a, gen, voice) = agent(prefix: "WRITE-IN-MY-VOICE")
        _ = try await a.outreach(to: [OX.target(contact: "sarah@client.com")],
                                 context: OX.context(), tools: tools(FakeTextGenerator()))
        let prompts = await gen.recordedPrompts
        #expect(prompts.count == 1)
        #expect(prompts[0].contains("WRITE-IN-MY-VOICE"))
        let calls = await voice.recordedCalls
        #expect(calls.first?.recipient == "sarah@client.com")
    }

    @Test func coldTargetPromptAsksForAColdIntro_warmReferencesTheDeal() async throws {
        let (a, gen, _) = agent(responses: ["B", "B"])
        let cold = OX.target(contact: "new@lead.com")                                   // no deal/thread
        let warm = OX.target(contact: "acme@client.com",
                             deal: OX.deal(contact: "acme@client.com", 
                                           company: "Acme",
                                           stage: .qualified,
                                           touchedDaysAgo: 30))                          // deal present
        _ = try await a.outreach(to: [cold, warm], context: OX.context(), tools: tools(FakeTextGenerator()))
        let prompts = await gen.recordedPrompts
        #expect(prompts[0].lowercased().contains("cold"))      // cold intro instruction
        #expect(prompts[1].contains("Acme"))                   // warm prompt mentions the deal's company
    }

    @Test func generatorGetsABoundedTokenBudget() async throws {
        let (a, gen, _) = agent()
        _ = try await a.outreach(to: [OX.target(contact: "a@x.com")],
                                 context: OX.context(), tools: tools(FakeTextGenerator()))
        // Single call; the agent uses its bounded outreach budget.
        let prompts = await gen.recordedPrompts
        #expect(prompts.count == 1)
        #expect(OutreachAgent.maxDraftTokens == 384)
    }

    @Test func cooledContactsAreSkippedAndCostNoModelCall() async throws {
        let (a, gen, _) = agent(responses: ["B", "B"])
        let cooled = OX.target(contact: "cooled@x.com",
                               deal: OX.deal(contact: "cooled@x.com", touchedDaysAgo: 1))   // < 7
        let fresh  = OX.target(contact: "fresh@x.com")
        let out = try await a.outreach(to: [cooled, fresh], context: OX.context(), tools: tools(FakeTextGenerator()))
        #expect(out.map { $0.message.to.first } == ["fresh@x.com"])
        let prompts = await gen.recordedPrompts
        #expect(prompts.count == 1)   // only the eligible contact hit the model
    }

    @Test func perRunCapBoundsTheNumberOfDrafts() async throws {
        let gen = FakeTextGenerator(responses: ["B"])
        let voice = FakeVoicePrefixProvider(prefix: "V")
        let capped = OutreachAgent(generator: gen, voice: voice,
                                   policy: OutreachPolicy(cooldownDays: 7, maxPerRun: 2))
        let targets = (1...5).map { OX.target(contact: "c\($0)@x.com") }
        let out = try await capped.outreach(to: targets, context: OX.context(), tools: tools(FakeTextGenerator()))
        #expect(out.count == 2)
        let prompts = await gen.recordedPrompts
        #expect(prompts.count == 2)   // never generates beyond the cap
    }

    @Test func outreachNeverProducesAnExecutedOrSentOutcome() {
        // Defense: every action this agent can emit is outbound, so ActionRouter.route — under ANY
        // autonomy — yields .queuedForApproval, never .executed/.prepared.
        for autonomy in [Autonomy.ask, .prepare, .auto] {
            let outcome = ActionRouter.route(.send(body: "x"), autonomy: autonomy)
            #expect(outcome == .queuedForApproval)
        }
    }

    @Test func dormantTargetsReturnsOpenDealsPastCooldown() throws {
        let (a, _, _) = agent()
        let store = InMemoryPipelineStore()
        try? store.upsert(OX.deal(contact: "stale@x.com", company: "Acme", stage: .proposal, touchedDaysAgo: 30))
        try? store.upsert(OX.deal(contact: "recent@x.com", company: "Acme", stage: .qualified, touchedDaysAgo: 2))
        try? store.upsert(OX.deal(contact: "won@x.com", company: "Acme", stage: .won, touchedDaysAgo: 30))
        
        let targets = try a.dormantTargets(in: store, now: OX.now)
        #expect(targets.map(\.contactEmail) == ["stale@x.com"])
        #expect(targets.first?.deal?.stage == .proposal)
    }

    @Test func dormantTargetsThenOutreachQueuesDraftsForReactivation() async throws {
        let (a, gen, _) = agent(responses: ["Reactivation nudge."])
        let store = InMemoryPipelineStore()
        try? store.upsert(OX.deal(contact: "stale@x.com", company: "Acme", stage: .negotiation, touchedDaysAgo: 45))
        
        let targets = try a.dormantTargets(in: store, now: OX.now)
        let out = try await a.outreach(to: targets, context: OX.context(), tools: tools(FakeTextGenerator()))
        #expect(out.count == 1)
        #expect(out.first?.action == .send(body: "Reactivation nudge."))
        #expect(out.first?.action.actionClass == ActionClass.outbound)
    }
}
