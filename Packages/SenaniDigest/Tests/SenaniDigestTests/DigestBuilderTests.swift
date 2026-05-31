import Testing
import Foundation
import SenaniAnalytics
import SenaniRules
import SenaniStore
@testable import SenaniDigest

@Suite struct DigestBuilderTests {
    @Test func digestReportCarriesAllSections() {
        let report = DigestReport(
            day: Date(timeIntervalSince1970: DigestFixture.dayStart),
            inboundCount: 3,
            outboundCount: 1,
            topSenders: [SenderCount(sender: "a@x.com", count: 2)],
            topDomains: [DomainCount(domain: "x.com", count: 2)],
            medianReplyLatencySeconds: 120,
            replyCount: 1,
            ruleActivity: [RuleActivity(ruleId: "triage", executed: 2, prepared: 0, queuedForApproval: 1)],
            pendingApprovals: 4
        )
        #expect(report.inboundCount == 3)
        #expect(report.outboundCount == 1)
        #expect(report.topSenders.first?.sender == "a@x.com")
        #expect(report.medianReplyLatencySeconds == 120)
        #expect(report.replyCount == 1)
        #expect(report.ruleActivity.first?.queuedForApproval == 1)
        #expect(report.pendingApprovals == 4)
    }

    private func seededBuilder() throws -> (DigestBuilder, SenaniStore.SenaniDatabase) {
        let db = try DigestFixture.makeDatabase()
        let messages = SenaniStore.MessageStore(database: db)

        // ---- messages for the day (2026-03-15) ----
        // inbound: alice x2, bob x1 (alice clogs the inbox); outbound: 1 user reply.
        try messages.saveAll([
            DigestFixture.message(id: "m1", from: "alice@x.com", offset: 100, isFromUser: false, threadId: "t1"),
            DigestFixture.message(id: "m2", from: "alice@x.com", offset: 200, isFromUser: false, threadId: "t2"),
            DigestFixture.message(id: "m3", from: "bob@y.com",   offset: 300, isFromUser: false, threadId: "t3"),
            // user replies to t1 at +220 => latency 120s for that inbound
            DigestFixture.message(id: "m4", from: "me@self.com", offset: 220, isFromUser: true,  threadId: "t1"),
        ])

        // ---- actions_log for the day ----
        try DigestFixture.insertAction(db, ruleId: "triage", outcome: "executed", messageId: "m1", offset: 110)
        try DigestFixture.insertAction(db, ruleId: "triage", outcome: "executed", messageId: "m2", offset: 210)
        try DigestFixture.insertAction(db, ruleId: "triage", outcome: "queuedForApproval", messageId: "m3", offset: 310)
        try DigestFixture.insertAction(db, ruleId: nil,      outcome: "executed", messageId: "m1", offset: 120) // chat -> excluded

        // ---- a pending approval ----
        let approvals = DigestFixture.approvals(db)
        try approvals.enqueue(
            id: "m3#triage#0",
            SenaniRules.Proposal(
                action: .send(body: "Hi"),
                message: DigestFixture.message(id: "m3", from: "bob@y.com", offset: 300, isFromUser: false, threadId: "t3"),
                trigger: .rule(id: "triage")
            )
        )

        let builder = DigestBuilder(
            analytics: DigestFixture.analytics(db),
            approvals: approvals,
            calendar: DigestFixture.utcCalendar,
            topLimit: 5
        )
        return (builder, db)
    }

    @Test func buildAggregatesTheDaysActivity() throws {
        let (builder, _) = try seededBuilder()
        let report = try builder.build(for: Date(timeIntervalSince1970: DigestFixture.dayStart + 50_000))

        #expect(report.day == Date(timeIntervalSince1970: DigestFixture.dayStart))
        #expect(report.inboundCount == 3)
        #expect(report.outboundCount == 1)
        #expect(report.topSenders == [
            SenderCount(sender: "alice@x.com", count: 2),
            SenderCount(sender: "bob@y.com", count: 1),
        ])
        #expect(report.topDomains == [
            DomainCount(domain: "x.com", count: 2),
            DomainCount(domain: "y.com", count: 1),
        ])
        #expect(report.medianReplyLatencySeconds == 120)
        #expect(report.replyCount == 1)
        #expect(report.ruleActivity == [
            RuleActivity(ruleId: "triage", executed: 2, prepared: 0, queuedForApproval: 1),
        ])
        #expect(report.pendingApprovals == 1)
    }

    @Test func buildForPastDayExcludesLaterDaysRows() throws {
        // FINDING 1: replyLatency / ruleActivity use an unbounded `since:` floor,
        // so building for a PAST day must NOT fold in rows from later days.
        let db = try DigestFixture.makeDatabase()
        let messages = SenaniStore.MessageStore(database: db)

        // ---- DAY 1 (the past day we build for) ----
        // one inbound + a user reply 200s later => latency 200s, replyCount 1.
        try messages.saveAll([
            DigestFixture.message(id: "d1m1", from: "alice@x.com", offset: 100, isFromUser: false, threadId: "t1"),
            DigestFixture.message(id: "d1m2", from: "me@self.com", offset: 300, isFromUser: true,  threadId: "t1"),
            // ---- DAY 2 (later day — must be excluded from DAY 1's digest) ----
            DigestFixture.message(id: "d2m1", from: "bob@y.com",   offset: 86_400 + 100, isFromUser: false, threadId: "t2"),
            DigestFixture.message(id: "d2m2", from: "me@self.com", offset: 86_400 + 110, isFromUser: true,  threadId: "t2"),
        ])

        // rule activity: 1 executed on DAY 1, plenty on DAY 2.
        try DigestFixture.insertAction(db, ruleId: "triage", outcome: "executed", messageId: "d1m1", offset: 110)
        try DigestFixture.insertAction(db, ruleId: "triage", outcome: "executed", messageId: "d2m1", offset: 86_400 + 120)
        try DigestFixture.insertAction(db, ruleId: "triage", outcome: "executed", messageId: "d2m1", offset: 86_400 + 130)

        let builder = DigestBuilder(
            analytics: DigestFixture.analytics(db),
            approvals: DigestFixture.approvals(db),
            calendar: DigestFixture.utcCalendar,
            topLimit: 5
        )

        // Build for DAY 1 (a past date relative to DAY 2's data).
        let report = try builder.build(for: Date(timeIntervalSince1970: DigestFixture.dayStart + 50_000))

        #expect(report.day == Date(timeIntervalSince1970: DigestFixture.dayStart))
        // Only DAY 1's reply counts: latency 200s, count 1 (NOT folding in DAY 2's 10s reply).
        #expect(report.medianReplyLatencySeconds == 200)
        #expect(report.replyCount == 1)
        // Only DAY 1's rule activity: 1 executed (NOT 3).
        #expect(report.ruleActivity == [
            RuleActivity(ruleId: "triage", executed: 1, prepared: 0, queuedForApproval: 0),
        ])
    }

    @Test func emptyDayYieldsZeroes() throws {
        let db = try DigestFixture.makeDatabase()
        let builder = DigestBuilder(
            analytics: DigestFixture.analytics(db),
            approvals: DigestFixture.approvals(db),
            calendar: DigestFixture.utcCalendar,
            topLimit: 5
        )
        let report = try builder.build(for: Date(timeIntervalSince1970: DigestFixture.dayStart))
        #expect(report.inboundCount == 0)
        #expect(report.outboundCount == 0)
        #expect(report.topSenders.isEmpty)
        #expect(report.medianReplyLatencySeconds == 0)
        #expect(report.replyCount == 0)
        #expect(report.ruleActivity.isEmpty)
        #expect(report.pendingApprovals == 0)
    }
}
