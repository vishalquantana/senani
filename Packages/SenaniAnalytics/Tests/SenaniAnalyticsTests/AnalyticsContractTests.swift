import Foundation
import SenaniRules
import SenaniStore
import Testing
@testable import SenaniAnalytics

@Suite struct AnalyticsContractTests {
    @Test func aggregatesMessagesAndCanonicalActionLog() async throws {
        let database = try SenaniDatabase.inMemory()
        let messages = MessageStore(database: database)
        try messages.saveAll([
            Self.msg("a1", from: "Alice@Example.com", date: Self.day0 + 10, threadId: "ta"),
            Self.msg("a2", from: "alice@example.com", date: Self.day0 + 20, threadId: "tb"),
            Self.msg("b1", from: "bob@other.com", date: Self.day1 + 10, threadId: "tc"),
            Self.msg("me1", from: Self.account, to: ["alice@example.com"], date: Self.day1 + 100, threadId: "ta", isFromUser: true),
        ])

        let audit = PersistentAuditLog(database: database, now: { Self.day1 + 200 })
        await audit.record(ActionRecord(action: .archive, messageId: "a1", trigger: .rule(id: "r1"), outcome: .executed))
        await audit.record(ActionRecord(action: .draft(body: "ok"), messageId: "a2", trigger: .rule(id: "r1"), outcome: .prepared))
        await audit.record(ActionRecord(action: .send(body: "ok"), messageId: "b1", trigger: .chat(turnId: "c1"), outcome: .queuedForApproval))

        let analytics = AnalyticsQueries(database: database)
        #expect(try analytics.topSenders(limit: 2) == [
            SenderCount(sender: "alice@example.com", count: 2),
            SenderCount(sender: "bob@other.com", count: 1),
        ])
        #expect(try analytics.topDomains(limit: 2) == [
            DomainCount(domain: "example.com", count: 2),
            DomainCount(domain: "other.com", count: 1),
        ])
        #expect(try analytics.volumeByDay(since: Date(timeIntervalSince1970: Self.day0)) == [
            VolumePoint(day: Date(timeIntervalSince1970: Self.day0), inbound: 2, outbound: 0),
            VolumePoint(day: Date(timeIntervalSince1970: Self.day1), inbound: 1, outbound: 1),
        ])
        #expect(try analytics.replyLatency(since: Date(timeIntervalSince1970: Self.day0)) == [
            ReplyLatency(threadId: "ta", seconds: 86_490),
        ])
        #expect(try analytics.ruleActivity(since: Date(timeIntervalSince1970: Self.day0)) == [
            RuleActivity(ruleId: "r1", executed: 1, prepared: 1, queuedForApproval: 0),
        ])
    }

    static let account = "me@example.com"
    static let day0: Double = 1_767_225_600
    static let day1: Double = 1_767_312_000

    static func msg(
        _ id: String,
        from: String,
        to: [String] = [Self.account],
        date: Double,
        threadId: String,
        isFromUser: Bool = false
    ) -> SenaniRules.Message {
        SenaniRules.Message(
            id: id,
            from: from,
            to: to,
            subject: "Subject",
            body: "Body",
            hasAttachment: false,
            listUnsubscribeHeader: nil,
            labels: ["INBOX"],
            threadId: threadId,
            date: Date(timeIntervalSince1970: date),
            isFromUser: isFromUser
        )
    }
}
