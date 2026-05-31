import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct StaleThreadScannerTests {
    private func scanner(_ pipe: InMemoryPipeline,
                         silenceDays: Double = 7, cooldownDays: Double = 3) -> StaleThreadScanner {
        StaleThreadScanner(threads: pipe, pipeline: pipe,
                           policy: .init(silenceDays: silenceDays, cooldownDays: cooldownDays))
    }

    @Test func flagsThreadWhereLastUserMessageIsOlderThanSilenceWindow() throws {
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)   // user sent 10d ago, no reply since
        let deal = FU.openDeal(id: "d1", threadId: "t1", lastTouch: last.date)
        let pipe = InMemoryPipeline(deals: [deal],
                                    threads: ["t1": [last]])
        let stale = try scanner(pipe).staleThreads(olderThan: 7, now: FU.now)
        #expect(stale.count == 1)
        #expect(stale.first?.threadId == "t1")
        #expect(stale.first?.lastUserMessage.id == last.id)
        #expect(stale.first?.deal.id == "d1")
    }

    @Test func doesNotFlagWhenContactRepliedAfterTheUser() throws {
        let mine = FU.fromUser(threadId: "t1", daysAgo: 10)
        let reply = FU.fromContact(threadId: "t1", daysAgo: 2)   // contact replied 2d ago = last msg
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1")],
                                    threads: ["t1": [mine, reply]])
        let stale = try scanner(pipe).staleThreads(olderThan: 7, now: FU.now)
        #expect(stale.isEmpty)   // last message is from the contact, not the user
    }

    @Test func doesNotFlagWhenLastUserMessageIsWithinSilenceWindow() throws {
        let recent = FU.fromUser(threadId: "t1", daysAgo: 3)     // only 3d of silence < 7
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1")],
                                    threads: ["t1": [recent]])
        let stale = try scanner(pipe).staleThreads(olderThan: 7, now: FU.now)
        #expect(stale.isEmpty)
    }

    @Test func doesNotFlagThreadsForClosedDeals() throws {
        let last = FU.fromUser(threadId: "t1", daysAgo: 30)
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1", stage: .won)],
                                    threads: ["t1": [last]])
        let stale = try scanner(pipe).staleThreads(olderThan: 7, now: FU.now)
        #expect(stale.isEmpty)   // won deal is closed → never nudged
    }

    @Test func respectsCooldownWhenDealWasRecentlyTouched() throws {
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)
        let touchedYesterday = FU.now.addingTimeInterval(-FU.day(1))   // within 3d cooldown
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1", lastTouch: touchedYesterday)],
                                    threads: ["t1": [last]])
        let stale = try scanner(pipe).staleThreads(olderThan: 7, now: FU.now)
        #expect(stale.isEmpty)   // cooldown not elapsed → no duplicate nudge
    }

    @Test func flagsAgainOnceCooldownHasElapsed() throws {
        let last = FU.fromUser(threadId: "t1", daysAgo: 14)
        let touchedLongAgo = FU.now.addingTimeInterval(-FU.day(5))     // beyond 3d cooldown
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1", lastTouch: touchedLongAgo)],
                                    threads: ["t1": [last]])
        let stale = try scanner(pipe).staleThreads(olderThan: 7, now: FU.now)
        #expect(stale.count == 1)
    }

    @Test func ignoresThreadsWithNoOpenDeal() throws {
        let last = FU.fromUser(threadId: "t-unknown", daysAgo: 30)
        let pipe = InMemoryPipeline(deals: [],                          // no deal for this thread
                                    threads: ["t-unknown": [last]])
        let stale = try scanner(pipe).staleThreads(olderThan: 7, now: FU.now)
        #expect(stale.isEmpty)
    }

    @Test func ignoresEmptyThreads() throws {
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1")],
                                    threads: ["t1": []])
        let stale = try scanner(pipe).staleThreads(olderThan: 7, now: FU.now)
        #expect(stale.isEmpty)
    }
}
