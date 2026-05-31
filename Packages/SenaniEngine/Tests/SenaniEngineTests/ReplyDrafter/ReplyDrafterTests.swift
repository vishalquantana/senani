import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct ReplyDrafterTests {
    private func make(canned: String = "Sure, here are the figures.\n\nBest,\nRamesh")
        -> (ReplyDrafterAgent, FakeTextGenerator, FakeVoicePrefixProvider) {
        let gen = FakeTextGenerator(response: canned)
        let voice = FakeVoicePrefixProvider(prefix: "WRITE-IN-MY-VOICE-PREFIX")
        return (ReplyDrafterAgent(generator: gen, voice: voice), gen, voice)
    }

    @Test func wakesForNeedsReplyMessageFromAnother() {
        let (agent, _, _) = make()
        let m = RD.incoming()
        let ctx = RD.context(thread: [m], needsReply: true)
        #expect(agent.wakesFor(m, context: ctx) == true)
    }

    @Test func doesNotWakeWhenNotFlaggedNeedsReply() {
        let (agent, _, _) = make()
        let m = RD.incoming()
        let ctx = RD.context(thread: [m], needsReply: false)
        #expect(agent.wakesFor(m, context: ctx) == false)
    }

    @Test func producesASingleOutboundDraftReplyWithTheGeneratedBody() async throws {
        let (agent, _, _) = make(canned: "Sure, attached.")
        let m = RD.incoming()
        let ctx = RD.context(thread: [RD.priorFromUser(), m], needsReply: true)

        let actions = try await agent.proposals(for: m, context: ctx, tools: tools(FakeTextGenerator()))

        #expect(actions == [.reply(body: "Sure, attached.")])
        #expect(actions.first?.actionClass == .outbound)
    }

    @Test func promptIncludesThreadContextAndVoicePrefix() async throws {
        let (agent, gen, _) = make()
        let m = RD.incoming(body: "Could you send the latest figures?")
        let prior = RD.priorFromUser(body: "Sending the proposal now.")
        let ctx = RD.context(thread: [prior, m], needsReply: true)

        _ = try await agent.proposals(for: m, context: ctx, tools: tools(gen))

        let lastPrompt = await gen.recordedPrompts.last
        let prompt = try #require(lastPrompt)
        #expect(prompt.contains("WRITE-IN-MY-VOICE-PREFIX"))
        #expect(prompt.contains("Could you send the latest figures?"))
        #expect(prompt.contains("Sending the proposal now."))
    }
}
