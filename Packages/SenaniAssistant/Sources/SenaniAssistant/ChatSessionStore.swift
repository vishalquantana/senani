import Foundation
import GRDB
import SenaniStore

public struct ChatSessionStore: Sendable {
    private let database: SenaniDatabase
    private let now: @Sendable () -> Double

    public init(database: SenaniDatabase, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.database = database
        self.now = now
    }

    public func append(sessionId: String, turn: ChatTurn) throws {
        var turns = try transcript(sessionId: sessionId)
        turns.append(turn)
        let json = String(data: try JSONEncoder().encode(turns), encoding: .utf8)!
        try database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO chat_sessions (id, started_at, transcript_json, summary)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET transcript_json = excluded.transcript_json
                """,
                arguments: [sessionId, now(), json, turns.suffix(3).map(\.text).joined(separator: "\n")]
            )
        }
    }

    public func transcript(sessionId: String) throws -> [ChatTurn] {
        try database.queue.read { db in
            guard let json = try String.fetchOne(db, sql: "SELECT transcript_json FROM chat_sessions WHERE id = ?", arguments: [sessionId]),
                  let data = json.data(using: .utf8)
            else { return [] }
            return try JSONDecoder().decode([ChatTurn].self, from: data)
        }
    }
}
