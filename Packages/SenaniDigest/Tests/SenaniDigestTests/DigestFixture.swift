import Foundation
import GRDB
import SenaniRules
import SenaniStore
import SenaniAnalytics
@testable import SenaniDigest

enum DigestFixture {
    static let dayStart: TimeInterval = 1_773_532_800
    static var nextDayStart: TimeInterval { dayStart + 86_400 }
    static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    static func makeDatabase() throws -> SenaniDatabase { try SenaniDatabase.inMemory() }
    static func analytics(_ db: SenaniDatabase) -> AnalyticsQueries { AnalyticsQueries(database: db) }
    static func approvals(_ db: SenaniDatabase) -> ApprovalStore { ApprovalStore(database: db, now: { dayStart }) }
    static func message(id: String, from: String, to: [String] = ["me@self.com"],
                        offset: TimeInterval, isFromUser: Bool, threadId: String) -> Message {
        Message(id: id, from: from, to: to, subject: "S", body: "B",
                hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
                threadId: threadId, date: Date(timeIntervalSince1970: dayStart + offset),
                isFromUser: isFromUser)
    }
    static func insertAction(_ db: SenaniDatabase, ruleId: String?, outcome: String, messageId: String, offset: TimeInterval) throws {
        let triggerJSON: String
        if let ruleId { triggerJSON = #"{"kind":"rule","identifier":"\#(ruleId)"}"# }
        else { triggerJSON = #"{"kind":"chat","identifier":"turn-1"}"# }
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO actions_log (message_id, action_json, trigger_json, outcome, logged_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [messageId, "{}", triggerJSON, outcome, dayStart + offset])
        }
    }
    static func fixedClock(_ t: TimeInterval) -> @Sendable () -> Date {
        let d = Date(timeIntervalSince1970: t)
        return { d }
    }
}
