import Foundation
import GRDB
import SenaniStore

public struct NeedsReplyFlag: Sendable, Equatable {
    public let threadId: String
    public let messageId: String
    public let flaggedAt: Double

    public init(threadId: String, messageId: String, flaggedAt: Double) {
        self.threadId = threadId
        self.messageId = messageId
        self.flaggedAt = flaggedAt
    }
}

public struct NeedsReplyStore: Sendable {
    private let database: SenaniDatabase
    private let now: @Sendable () -> Double

    public init(database: SenaniDatabase, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.database = database
        self.now = now
    }

    public func set(threadId: String, messageId: String) throws {
        let flaggedAt = now()
        try database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO needs_reply (thread_id, message_id, flagged_at, resolved)
                VALUES (?, ?, ?, 0)
                ON CONFLICT(thread_id) DO UPDATE SET
                  message_id = excluded.message_id,
                  flagged_at = excluded.flagged_at,
                  resolved = 0
                """,
                arguments: [threadId, messageId, flaggedAt]
            )
        }
    }

    public func clear(threadId: String) throws {
        try database.queue.write { db in
            try db.execute(sql: "UPDATE needs_reply SET resolved = 1 WHERE thread_id = ?", arguments: [threadId])
        }
    }

    public func pending() throws -> [NeedsReplyFlag] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT thread_id, message_id, flagged_at FROM needs_reply WHERE resolved = 0 ORDER BY flagged_at DESC"
            )
            return rows.map {
                NeedsReplyFlag(threadId: $0["thread_id"], messageId: $0["message_id"], flaggedAt: $0["flagged_at"])
            }
        }
    }

    public func count() throws -> Int {
        try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM needs_reply WHERE resolved = 0") ?? 0
        }
    }
}
