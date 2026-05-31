import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct FollowUpAgentWakesForTests {
    private func agent(_ pipe: InMemoryPipeline) -> FollowUpAgent {
        FollowUpAgent(
            generator: FakeTextGenerator(response: "Just checking in."),
            voice: FakeVoicePrefixProvider(prefix: "VOICE"),
            pipelineRead: pipe, pipelineTouch: pipe,
            policy: .init(silenceDays: 7, cooldownDays: 3)
        )
    }

    @Test func wakesForSilentUserMessageOnOpenDeal() {
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)
        let deal = FU.openDeal(id: "d1", threadId: "t1", lastTouch: last.date)
        let pipe = InMemoryPipeline(deals: [deal], threads: ["t1": [last]])
        let ctx = FU.context(thread: [last], pipeline: pipe)
        #expect(agent(pipe).wakesFor(last, context: ctx) == true)
    }

    @Test func doesNotWakeWhenContactRepliedLast() {
        let mine = FU.fromUser(threadId: "t1", daysAgo: 10)
        let reply = FU.fromContact(threadId: "t1", daysAgo: 2)
        let deal = FU.openDeal(id: "d1", threadId: "t1", lastTouch: mine.date)
        let pipe = InMemoryPipeline(deals: [deal], threads: ["t1": [mine, reply]])
        let ctx = FU.context(thread: [mine, reply], pipeline: pipe)
        #expect(agent(pipe).wakesFor(reply, context: ctx) == false)
    }

    @Test func doesNotWakeWithinSilenceWindow() {
        let recent = FU.fromUser(threadId: "t1", daysAgo: 3)
        let deal = FU.openDeal(id: "d1", threadId: "t1", lastTouch: recent.date.addingTimeInterval(-86400))
        let pipe = InMemoryPipeline(deals: [deal], threads: ["t1": [recent]])
        let ctx = FU.context(thread: [recent], pipeline: pipe)
        #expect(agent(pipe).wakesFor(recent, context: ctx) == false)
    }

    @Test func doesNotWakeWhenNoOpenDealForThread() {
        let last = FU.fromUser(threadId: "t-orphan", daysAgo: 30)
        let pipe = InMemoryPipeline(deals: [], threads: ["t-orphan": [last]])
        let ctx = FU.context(thread: [last], pipeline: pipe)
        #expect(agent(pipe).wakesFor(last, context: ctx) == false)
    }

    @Test func doesNotWakeWithinCooldown() {
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)
        let touchedYesterday = FU.now.addingTimeInterval(-FU.day(1))
        let deal = FU.openDeal(id: "d1", threadId: "t1", lastTouch: touchedYesterday)
        let pipe = InMemoryPipeline(deals: [deal], threads: ["t1": [last]])
        let ctx = FU.context(thread: [last], pipeline: pipe)
        #expect(agent(pipe).wakesFor(last, context: ctx) == false)
    }

    @Test func identityAndAutonomy() {
        let pipe = InMemoryPipeline(deals: [], threads: [:])
        let a = agent(pipe)
        #expect(a.id == "follow-up")
        #expect(a.autonomy == .prepare)
    }
}
