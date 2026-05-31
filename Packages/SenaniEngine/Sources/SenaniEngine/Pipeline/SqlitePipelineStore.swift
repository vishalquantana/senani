import Foundation
import GRDB
import SenaniStore

/// PipelineStore backed by the SHARED `SenaniDatabase`. The frozen `SenaniStore` migrator does not
/// know about deals and is not extensible from the app tier (its migrator is `internal`), so this
/// store adds its table idempotently with `CREATE TABLE IF NOT EXISTS` on the public `queue` at
/// construction. This does NOT touch GRDB's migration ledger, so the frozen migrator is unaffected.
public struct SqlitePipelineStore: PipelineStore {
    private let database: SenaniDatabase

    public init(database: SenaniDatabase) throws {
        self.database = database
        try database.queue.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS deals (
                id TEXT PRIMARY KEY,
                contactEmail TEXT NOT NULL COLLATE NOCASE,
                company TEXT,
                stage TEXT NOT NULL,
                score INTEGER,
                value DOUBLE,
                lastTouch DOUBLE NOT NULL,
                sourceMessageId TEXT
            )
            """)
            // Additive migration: older databases created before `threadId` existed get the column
            // backfilled to `sourceMessageId` (or `id`). Guarded so re-running construction is safe.
            let hasThreadId = try Row.fetchAll(db, sql: "PRAGMA table_info(deals)")
                .contains { ($0["name"] as String?) == "threadId" }
            if !hasThreadId {
                try db.execute(sql: "ALTER TABLE deals ADD COLUMN threadId TEXT")
                try db.execute(sql: "UPDATE deals SET threadId = COALESCE(sourceMessageId, id) WHERE threadId IS NULL")
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_deals_contact ON deals(contactEmail)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_deals_stage ON deals(stage)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_deals_thread ON deals(threadId)")
        }
    }

    public func upsert(_ deal: Deal) throws {
        try database.queue.write { db in
            try db.execute(sql: """
            INSERT INTO deals
              (id, contactEmail, company, stage, score, value, lastTouch, sourceMessageId, threadId)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              contactEmail = excluded.contactEmail,
              company = excluded.company,
              stage = excluded.stage,
              score = excluded.score,
              value = excluded.value,
              lastTouch = excluded.lastTouch,
              sourceMessageId = excluded.sourceMessageId,
              threadId = excluded.threadId
            """, arguments: [
                deal.id, deal.contactEmail, deal.company, deal.stage.rawValue,
                deal.score, deal.value, deal.lastTouch.timeIntervalSince1970,
                deal.sourceMessageId, deal.threadId,
            ])
        }
    }

    public func fetch(id: String) throws -> Deal? {
        try database.queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM deals WHERE id = ?",
                                             arguments: [id]) else { return nil }
            return Self.deal(from: row)
        }
    }

    public func byContact(_ email: String) throws -> Deal? {
        try database.queue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM deals WHERE contactEmail = ? COLLATE NOCASE ORDER BY lastTouch DESC LIMIT 1",
                arguments: [email]) else { return nil }
            return Self.deal(from: row)
        }
    }

    public func all() throws -> [Deal] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM deals ORDER BY lastTouch DESC, id ASC")
                .map(Self.deal(from:))
        }
    }

    public func byStage(_ stage: DealStage) throws -> [Deal] {
        try database.queue.read { db in
            try Row.fetchAll(db,
                             sql: "SELECT * FROM deals WHERE stage = ? ORDER BY lastTouch DESC, id ASC",
                             arguments: [stage.rawValue])
                .map(Self.deal(from:))
        }
    }

    public func deal(threadId: String) throws -> Deal? {
        try database.queue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM deals WHERE threadId = ? OR id = ? LIMIT 1",
                arguments: [threadId, threadId]) else { return nil }
            return Self.deal(from: row)
        }
    }

    private static func deal(from row: Row) -> Deal {
        let stageRaw: String = row["stage"]
        return Deal(
            id: row["id"],
            contactEmail: row["contactEmail"],
            company: row["company"],
            stage: DealStage(rawValue: stageRaw) ?? .lead,
            score: row["score"],
            value: row["value"],
            lastTouch: Date(timeIntervalSince1970: row["lastTouch"]),
            sourceMessageId: row["sourceMessageId"],
            threadId: (row["threadId"] as String?) ?? (row["sourceMessageId"] as String?) ?? row["id"]
        )
    }
}
