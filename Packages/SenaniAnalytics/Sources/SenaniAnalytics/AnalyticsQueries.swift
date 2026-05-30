import Foundation
import GRDB
import SenaniStore

public struct AnalyticsQueries: Sendable {
    private let reader: any DatabaseReader

    public init(database: SenaniDatabase) {
        self.reader = database.queue
    }

    public init(reader: any DatabaseReader) {
        self.reader = reader
    }

    public func topSenders(limit: Int) throws -> [SenderCount] {
        try reader.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT lower("from") AS sender, COUNT(*) AS count
                FROM messages
                WHERE isFromUser = 0
                GROUP BY lower("from")
                ORDER BY count DESC, sender ASC
                LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.map { SenderCount(sender: $0["sender"], count: $0["count"]) }
        }
    }

    public func topDomains(limit: Int) throws -> [DomainCount] {
        try reader.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT senderDomain AS domain, COUNT(*) AS count
                FROM messages
                WHERE isFromUser = 0
                GROUP BY senderDomain
                ORDER BY count DESC, domain ASC
                LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.map { DomainCount(domain: $0["domain"], count: $0["count"]) }
        }
    }

    public func volumeByDay(since: Date) throws -> [VolumePoint] {
        try reader.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT CAST(date / 86400 AS INTEGER) * 86400 AS day,
                       SUM(CASE WHEN isFromUser = 0 THEN 1 ELSE 0 END) AS inbound,
                       SUM(CASE WHEN isFromUser = 1 THEN 1 ELSE 0 END) AS outbound
                FROM messages
                WHERE date >= ?
                GROUP BY day
                ORDER BY day ASC
                """,
                arguments: [since.timeIntervalSince1970]
            )
            return rows.map {
                VolumePoint(
                    day: Date(timeIntervalSince1970: $0["day"]),
                    inbound: $0["inbound"],
                    outbound: $0["outbound"]
                )
            }
        }
    }

    public func replyLatency(since: Date) throws -> [ReplyLatency] {
        try reader.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT inbound.threadId AS threadId,
                       MIN(outbound.date - inbound.date) AS seconds
                FROM messages inbound
                JOIN messages outbound ON outbound.threadId = inbound.threadId
                  AND outbound.isFromUser = 1
                  AND outbound.date > inbound.date
                WHERE inbound.isFromUser = 0 AND inbound.date >= ?
                GROUP BY inbound.id
                ORDER BY seconds ASC, threadId ASC
                """,
                arguments: [since.timeIntervalSince1970]
            )
            return rows.map { ReplyLatency(threadId: $0["threadId"], seconds: $0["seconds"]) }
        }
    }

    public func ruleActivity(since: Date) throws -> [RuleActivity] {
        try reader.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT json_extract(trigger_json, '$.identifier') AS ruleId,
                       SUM(CASE WHEN outcome = 'executed' THEN 1 ELSE 0 END) AS executed,
                       SUM(CASE WHEN outcome = 'prepared' THEN 1 ELSE 0 END) AS prepared,
                       SUM(CASE WHEN outcome = 'queuedForApproval' THEN 1 ELSE 0 END) AS queued
                FROM actions_log
                WHERE logged_at >= ?
                  AND json_extract(trigger_json, '$.kind') = 'rule'
                GROUP BY ruleId
                ORDER BY ruleId ASC
                """,
                arguments: [since.timeIntervalSince1970]
            )
            return rows.map {
                RuleActivity(
                    ruleId: $0["ruleId"],
                    executed: $0["executed"],
                    prepared: $0["prepared"],
                    queuedForApproval: $0["queued"]
                )
            }
        }
    }
}
