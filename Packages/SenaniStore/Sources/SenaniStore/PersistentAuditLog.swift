import GRDB
import SenaniRules

public struct AuditEntry: Sendable, Equatable {
    public let record: ActionRecord
    public let loggedAt: Double

    public init(record: ActionRecord, loggedAt: Double) {
        self.record = record
        self.loggedAt = loggedAt
    }
}

public actor PersistentAuditLog: AuditLog {
    private let database: SenaniDatabase
    private let now: @Sendable () -> Double

    public init(database: SenaniDatabase, now: @escaping @Sendable () -> Double) {
        self.database = database
        self.now = now
    }

    public func record(_ record: ActionRecord) async {
        do {
            let actionJSON = try SenaniJSON.encodeString(ActionDTO(core: record.action))
            let triggerJSON = try SenaniJSON.encodeString(TriggerDTO(core: record.trigger))
            let outcome = OutcomeDTO(core: record.outcome).raw.rawValue
            let loggedAt = now()
            try await database.queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO actions_log
                      (message_id, action_json, trigger_json, outcome, logged_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [record.messageId, actionJSON, triggerJSON, outcome, loggedAt]
                )
            }
        } catch {
            // The core AuditLog protocol is non-throwing. Persistence failures are contained.
        }
    }

    public func records() throws -> [AuditEntry] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT message_id, action_json, trigger_json, outcome, logged_at
                FROM actions_log ORDER BY id
                """
            )
            return try rows.map { row in
                let actionJSON: String = row["action_json"]
                let triggerJSON: String = row["trigger_json"]
                let outcomeRaw: String = row["outcome"]
                let action = try SenaniJSON.decode(ActionDTO.self, from: actionJSON).toCore()
                let trigger = try SenaniJSON.decode(TriggerDTO.self, from: triggerJSON).toCore()
                let outcome = OutcomeDTO(raw: OutcomeDTO.Raw(rawValue: outcomeRaw) ?? .executed)
                    .toCore()
                let record = ActionRecord(
                    action: action,
                    messageId: row["message_id"],
                    trigger: trigger,
                    outcome: outcome
                )
                return AuditEntry(record: record, loggedAt: row["logged_at"])
            }
        }
    }
}
