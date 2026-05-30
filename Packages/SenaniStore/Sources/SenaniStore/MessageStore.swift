import Foundation
import GRDB
import SenaniRules

public struct MessageStore: Sendable {
    public let database: SenaniDatabase

    public init(database: SenaniDatabase) {
        self.database = database
    }

    public func save(_ message: Message) throws {
        try database.queue.write { db in
            try Self.upsert(message, db)
        }
    }

    public func saveAll(_ messages: [Message]) throws {
        try database.queue.write { db in
            for message in messages {
                try Self.upsert(message, db)
            }
        }
    }

    public func fetch(id: String) throws -> Message? {
        try database.queue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM messages WHERE id = ?",
                arguments: [id]
            ) else {
                return nil
            }
            return try Self.message(from: row)
        }
    }

    public func thread(id: String) throws -> [Message] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM messages WHERE threadId = ? ORDER BY date ASC, id ASC",
                arguments: [id]
            )
            return try rows.map(Self.message(from:))
        }
    }

    public func query(
        from: String?,
        to: String?,
        isFromUser: Bool?,
        limit: Int?
    ) throws -> [Message] {
        var clauses: [String] = []
        var arguments = StatementArguments()
        if let from {
            clauses.append(#""from" = ?"#)
            arguments += [from]
        }
        if let to {
            clauses.append("EXISTS (SELECT 1 FROM json_each(messages.recipients) WHERE value = ?)")
            arguments += [to]
        }
        if let isFromUser {
            clauses.append("isFromUser = ?")
            arguments += [isFromUser]
        }

        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let limitSQL = limit.map { " LIMIT \($0)" } ?? ""
        let sql = "SELECT * FROM messages\(whereSQL) ORDER BY date DESC, id ASC\(limitSQL)"

        return try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return try rows.map(Self.message(from:))
        }
    }

    public func all() throws -> [Message] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM messages ORDER BY date DESC, id ASC")
            return try rows.map(Self.message(from:))
        }
    }

    static func senderDomain(of from: String) -> String {
        guard let at = from.lastIndex(of: "@") else {
            return ""
        }
        return String(from[from.index(after: at)...]).lowercased()
    }

    private static func upsert(_ message: Message, _ db: Database) throws {
        let labelsJSON = try SenaniJSON.encodeString(message.labels)
        let recipientsJSON = try SenaniJSON.encodeString(message.to)
        try db.execute(
            sql: """
            INSERT INTO messages
              (id, "from", senderDomain, subject, body, hasAttachment,
               listUnsubscribeHeader, labels, recipients, threadId, date, isFromUser)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              "from" = excluded."from",
              senderDomain = excluded.senderDomain,
              subject = excluded.subject,
              body = excluded.body,
              hasAttachment = excluded.hasAttachment,
              listUnsubscribeHeader = excluded.listUnsubscribeHeader,
              labels = excluded.labels,
              recipients = excluded.recipients,
              threadId = excluded.threadId,
              date = excluded.date,
              isFromUser = excluded.isFromUser
            """,
            arguments: [
                message.id,
                message.from,
                senderDomain(of: message.from),
                message.subject,
                message.body,
                message.hasAttachment,
                message.listUnsubscribeHeader,
                labelsJSON,
                recipientsJSON,
                message.threadId,
                message.date.timeIntervalSince1970,
                message.isFromUser,
            ]
        )
    }

    private static func message(from row: Row) throws -> Message {
        let labelsJSON: String = row["labels"]
        let recipientsJSON: String = row["recipients"]
        return Message(
            id: row["id"],
            from: row["from"],
            to: try SenaniJSON.decode([String].self, from: recipientsJSON),
            subject: row["subject"],
            body: row["body"],
            hasAttachment: row["hasAttachment"],
            listUnsubscribeHeader: row["listUnsubscribeHeader"],
            labels: try SenaniJSON.decode([String].self, from: labelsJSON),
            threadId: row["threadId"],
            date: Date(timeIntervalSince1970: row["date"]),
            isFromUser: row["isFromUser"]
        )
    }
}
