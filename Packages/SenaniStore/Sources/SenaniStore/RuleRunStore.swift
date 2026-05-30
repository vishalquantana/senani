import GRDB
import SenaniRules

public struct RuleRun: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case simulation, live
    }

    public var ruleId: String
    public var kind: Kind
    public var ranAt: Double
    public var messageId: String
    public var matched: Bool
    public var outcomes: [Outcome]

    public init(
        ruleId: String,
        kind: Kind,
        ranAt: Double,
        messageId: String,
        matched: Bool,
        outcomes: [Outcome]
    ) {
        self.ruleId = ruleId
        self.kind = kind
        self.ranAt = ranAt
        self.messageId = messageId
        self.matched = matched
        self.outcomes = outcomes
    }
}

public struct RuleRunStore: Sendable {
    private let database: SenaniDatabase

    public init(database: SenaniDatabase) {
        self.database = database
    }

    public func record(_ run: RuleRun) throws {
        let outcomesJSON = try SenaniJSON.encodeString(run.outcomes.map(OutcomeDTO.init(core:)))
        try database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO rule_runs
                  (rule_id, kind, ran_at, message_id, matched, outcomes_json)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    run.ruleId,
                    run.kind.rawValue,
                    run.ranAt,
                    run.messageId,
                    run.matched,
                    outcomesJSON,
                ]
            )
        }
    }

    public func runs(ruleId: String) throws -> [RuleRun] {
        try fetch(
            sql: "SELECT * FROM rule_runs WHERE rule_id = ? ORDER BY ran_at, id",
            arguments: [ruleId]
        )
    }

    public func all() throws -> [RuleRun] {
        try fetch(sql: "SELECT * FROM rule_runs ORDER BY ran_at, id", arguments: [])
    }

    private func fetch(sql: String, arguments: StatementArguments) throws -> [RuleRun] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return try rows.map { row in
                let outcomesJSON: String = row["outcomes_json"]
                let outcomes = try SenaniJSON
                    .decode([OutcomeDTO].self, from: outcomesJSON)
                    .map { $0.toCore() }
                let rawKind: String = row["kind"]
                return RuleRun(
                    ruleId: row["rule_id"],
                    kind: RuleRun.Kind(rawValue: rawKind) ?? .simulation,
                    ranAt: row["ran_at"],
                    messageId: row["message_id"],
                    matched: row["matched"],
                    outcomes: outcomes
                )
            }
        }
    }
}
