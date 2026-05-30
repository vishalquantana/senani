import GRDB
import SenaniRules

public struct RuleStore: Sendable {
    private let database: SenaniDatabase

    public init(database: SenaniDatabase) {
        self.database = database
    }

    public func save(_ rule: Rule) throws {
        let json = try SenaniJSON.encodeString(RuleDTO(core: rule))
        try database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO rules (id, name, enabled, json)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name,
                  enabled = excluded.enabled,
                  json = excluded.json
                """,
                arguments: [rule.id, rule.name, rule.enabled, json]
            )
        }
    }

    public func fetch(id: String) throws -> Rule? {
        try database.queue.read { db in
            guard let json = try String.fetchOne(
                db,
                sql: "SELECT json FROM rules WHERE id = ?",
                arguments: [id]
            ) else {
                return nil
            }
            return try SenaniJSON.decode(RuleDTO.self, from: json).toCore()
        }
    }

    public func all() throws -> [Rule] {
        try database.queue.read { db in
            let jsonRows = try String.fetchAll(db, sql: "SELECT json FROM rules ORDER BY id")
            return try jsonRows.map { try SenaniJSON.decode(RuleDTO.self, from: $0).toCore() }
        }
    }

    public func enabled() throws -> [Rule] {
        try database.queue.read { db in
            let jsonRows = try String.fetchAll(
                db,
                sql: "SELECT json FROM rules WHERE enabled = 1 ORDER BY id"
            )
            return try jsonRows.map { try SenaniJSON.decode(RuleDTO.self, from: $0).toCore() }
        }
    }

    public func delete(id: String) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM rules WHERE id = ?", arguments: [id])
        }
    }
}
