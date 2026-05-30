import Foundation
import GRDB
import SenaniRules

struct MessageDTO: Codable, Equatable, Sendable {
    var id: String
    var from: String
    var to: [String]
    var subject: String
    var body: String
    var hasAttachment: Bool
    var listUnsubscribeHeader: String?
    var labels: [String]
    var threadId: String
    var date: Double
    var isFromUser: Bool

    init(core: Message) {
        id = core.id
        from = core.from
        to = core.to
        subject = core.subject
        body = core.body
        hasAttachment = core.hasAttachment
        listUnsubscribeHeader = core.listUnsubscribeHeader
        labels = core.labels
        threadId = core.threadId
        date = core.date.timeIntervalSince1970
        isFromUser = core.isFromUser
    }

    func toCore() -> Message {
        Message(
            id: id,
            from: from,
            to: to,
            subject: subject,
            body: body,
            hasAttachment: hasAttachment,
            listUnsubscribeHeader: listUnsubscribeHeader,
            labels: labels,
            threadId: threadId,
            date: Date(timeIntervalSince1970: date),
            isFromUser: isFromUser
        )
    }
}

public struct StoredProposal: Sendable, Equatable {
    public let id: String
    public let proposal: Proposal

    public init(id: String, proposal: Proposal) {
        self.id = id
        self.proposal = proposal
    }
}

public struct ApprovalStore: Sendable {
    private let database: SenaniDatabase
    private let now: @Sendable () -> Double

    public init(database: SenaniDatabase, now: @escaping @Sendable () -> Double) {
        self.database = database
        self.now = now
    }

    public func enqueue(id: String, _ proposal: Proposal) throws {
        let actionJSON = try SenaniJSON.encodeString(ActionDTO(core: proposal.action))
        let messageJSON = try SenaniJSON.encodeString(MessageDTO(core: proposal.message))
        let triggerJSON = try SenaniJSON.encodeString(TriggerDTO(core: proposal.trigger))
        let createdAt = now()
        try database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO approvals
                  (id, action_json, message_json, trigger_json, status, created_at)
                VALUES (?, ?, ?, ?, 'pending', ?)
                ON CONFLICT(id) DO UPDATE SET
                  action_json = excluded.action_json,
                  message_json = excluded.message_json,
                  trigger_json = excluded.trigger_json,
                  status = 'pending',
                  created_at = excluded.created_at
                """,
                arguments: [id, actionJSON, messageJSON, triggerJSON, createdAt]
            )
        }
    }

    public func pending() throws -> [StoredProposal] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, action_json, message_json, trigger_json
                FROM approvals WHERE status = 'pending' ORDER BY created_at, id
                """
            )
            return try rows.map { row in
                let actionJSON: String = row["action_json"]
                let messageJSON: String = row["message_json"]
                let triggerJSON: String = row["trigger_json"]
                let action = try SenaniJSON.decode(ActionDTO.self, from: actionJSON).toCore()
                let message = try SenaniJSON.decode(MessageDTO.self, from: messageJSON).toCore()
                let trigger = try SenaniJSON.decode(TriggerDTO.self, from: triggerJSON).toCore()
                return StoredProposal(
                    id: row["id"],
                    proposal: Proposal(action: action, message: message, trigger: trigger)
                )
            }
        }
    }

    public func approve(id: String) throws {
        try setStatus(id: id, status: "approved")
    }

    public func reject(id: String) throws {
        try setStatus(id: id, status: "rejected")
    }

    private func setStatus(id: String, status: String) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE approvals SET status = ? WHERE id = ?",
                arguments: [status, id]
            )
        }
    }
}
