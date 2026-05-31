import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct FollowUpAgentProposalsTests {
    private func make(canned: String = "Hi Sarah, just following up on the proposal.\n\nBest,\nRamesh",
                      lastTouch: Date? = nil)
        -> (FollowUpAgent, FakeTextGenerator, FakeVoicePrefixProvider, InMemoryPipeline) {
        let gen = FakeTextGenerator(response: canned)
        let voice = FakeVoicePrefixProvider(prefix: "WRITE-IN-MY-VOICE-PREFIX")
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)
        let pipe = InMemoryPipeline(
            deals: [FU.openDeal(id: "d1", threadId: "t1", lastTouch: lastTouch ?? last.date)],
            threads: ["t1": [last]]
        )
        let agent = FollowUpAgent(generator: gen, voice: voice,
                                  pipelineRead: pipe, pipelineTouch: pipe,
                                  policy: .init(silenceDays: 7, cooldownDays: 3))
        return (agent, gen, voice, pipe)
    }

    @Test func producesASingleOutboundFollowUpReplyWithGeneratedBody() async throws {
        let (agent, _, _, pipe) = make(canned: "Just following up.")
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)
        let ctx = FU.context(thread: [last], pipeline: pipe)

        let actions = try await agent.proposals(for: last, context: ctx, tools: tools(FakeTextGenerator()))

        #expect(actions == [.reply(body: "Just following up.")])
        #expect(actions.first?.actionClass == .outbound)   // ⇒ ActionRouter ALWAYS queues it
    }

    @Test func stampsDealLastTouchWhenNudgeIsQueued() async throws {
        let (agent, _, _, pipe) = make()
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)
        let ctx = FU.context(thread: [last], at: FU.now, pipeline: pipe)

        _ = try await agent.proposals(for: last, context: ctx, tools: tools(FakeTextGenerator()))

        let touches = pipe.touches
        #expect(touches.count == 1)
        #expect(touches.first?.0 == "d1")
        #expect(touches.first?.1 == FU.now)
        #expect(pipe.currentDeal(id: "d1")?.lastTouch == FU.now)
    }

    @Test func voicePrefixIsIncludedInThePromptAndAskedForTheContact() async throws {
        let (agent, gen, voice, pipe) = make()
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)
        let ctx = FU.context(thread: [last], pipeline: pipe)

        _ = try await agent.proposals(for: last, context: ctx, tools: tools(gen))

        let prompts = await gen.recordedPrompts
        let prompt = try #require(prompts.last)
        #expect(prompt.contains("WRITE-IN-MY-VOICE-PREFIX"))     // voice prefix threaded in
        let calls = await voice.recordedCalls
        #expect(calls.first?.recipient == FU.contact)   // nudge addressed to the contact
    }

    @Test func promptIncludesThreadContextAndAFollowUpInstruction() async throws {
        let (agent, gen, _, pipe) = make()
        let last = FU.fromUser(threadId: "t1", body: "Here's the proposal — let me know what you think.", daysAgo: 10)
        let ctx = FU.context(thread: [last], pipeline: pipe)

        _ = try await agent.proposals(for: last, context: ctx, tools: tools(gen))

        let prompts = await gen.recordedPrompts
        let prompt = try #require(prompts.last)
        #expect(prompt.contains("Here's the proposal — let me know what you think."))  // thread body
        #expect(prompt.lowercased().contains("follow-up"))                              // the nudge instruction
    }

    @Test func noNudgeWhenContactAlreadyReplied() async throws {
        let gen = FakeTextGenerator(response: "should-not-be-used")
        let mine = FU.fromUser(threadId: "t1", daysAgo: 10)
        let reply = FU.fromContact(threadId: "t1", daysAgo: 2)
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1", lastTouch: mine.date)], 
                                    threads: ["t1": [mine, reply]])
        let agent = FollowUpAgent(generator: gen, voice: FakeVoicePrefixProvider(prefix: "V"),
                                  pipelineRead: pipe, pipelineTouch: pipe,
                                  policy: .init(silenceDays: 7, cooldownDays: 3))
        let ctx = FU.context(thread: [mine, reply], pipeline: pipe)

        let actions = try await agent.proposals(for: reply, context: ctx, tools: tools(gen))

        #expect(actions.isEmpty)
        let prompts = await gen.recordedPrompts
        #expect(prompts.isEmpty)   // no model call wasted
        #expect(pipe.touches.isEmpty)          // no touch on a non-stale thread
    }

    @Test func noNudgeWithinSilenceWindow() async throws {
        let gen = FakeTextGenerator(response: "x")
        let recent = FU.fromUser(threadId: "t1", daysAgo: 3)
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1", lastTouch: recent.date)], 
                                    threads: ["t1": [recent]])
        let agent = FollowUpAgent(generator: gen, voice: FakeVoicePrefixProvider(prefix: "V"),
                                  pipelineRead: pipe, pipelineTouch: pipe,
                                  policy: .init(silenceDays: 7, cooldownDays: 3))
        let ctx = FU.context(thread: [recent], pipeline: pipe)

        let actions = try await agent.proposals(for: recent, context: ctx, tools: tools(gen))
        #expect(actions.isEmpty)
        #expect(pipe.touches.isEmpty)
    }

    @Test func cooldownPreventsDuplicateNudges() async throws {
        // Deal was touched yesterday (within 3-day cooldown) → no second nudge.
        let (agent, gen, _, pipe) = make(lastTouch: FU.now.addingTimeInterval(-FU.day(1)))
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)
        let ctx = FU.context(thread: [last], pipeline: pipe)

        let actions = try await agent.proposals(for: last, context: ctx, tools: tools(gen))

        #expect(actions.isEmpty)
        let prompts = await gen.recordedPrompts
        #expect(prompts.isEmpty)
        #expect(pipe.touches.isEmpty)          // no new touch
    }

    @Test func trimsWhitespaceFromGeneratedBody() async throws {
        let (agent, _, _, pipe) = make(canned: "\n\n  Just following up.  \n")
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)
        let ctx = FU.context(thread: [last], pipeline: pipe)
        let actions = try await agent.proposals(for: last, context: ctx, tools: tools(FakeTextGenerator()))
        #expect(actions == [.reply(body: "Just following up.")])
    }
}
