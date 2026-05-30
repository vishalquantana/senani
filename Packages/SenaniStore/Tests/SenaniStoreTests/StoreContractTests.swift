import Foundation
import GRDB
import SenaniRules
import Testing
@testable import SenaniStore

@Suite struct StoreContractTests {
    @Test func smokeImportsGRDBAndPackage() throws {
        let queue = try DatabaseQueue()
        let value = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT 1")
        }
        #expect(value == 1)
        #expect(SenaniStoreVersion.current == "0.1.0")
    }

    @Test func migratorCreatesCanonicalTables() throws {
        let database = try SenaniDatabase.inMemory()
        let tables = try database.queue.read { db -> Set<String> in
            let names = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            )
            return Set(names)
        }
        let expected: Set<String> = [
            "rules", "rule_runs", "actions_log", "documents", "document_fields",
            "voice_profile", "needs_reply", "chat_sessions", "approvals", "vec_items",
            "messages",
        ]
        #expect(expected.isSubset(of: tables), "missing: \(expected.subtracting(tables))")
    }

    @Test func jsonCodingRejectsInvalidInput() throws {
        struct Sample: Codable, Equatable {
            let value: String
        }

        let json = try SenaniJSON.encodeString(Sample(value: "x"))
        #expect(try SenaniJSON.decode(Sample.self, from: json) == Sample(value: "x"))
        #expect(throws: (any Error).self) {
            _ = try SenaniJSON.decode(Sample.self, from: "not-json")
        }
    }

    @Test func actionDTOCoversEveryActionCase() throws {
        let actions: [Action] = [
            .label("Invoices"), .archive, .markRead, .markUnread, .star, .unstar,
            .move("Receipts"), .flagNeedsReply, .fileAttachment(folder: "Docs"),
            .parseDoc, .runAgent(id: "agent"), .draft(body: "draft"),
            .reply(body: "reply"), .forward(to: "a@b.com", body: "fyi"),
            .send(body: "send"), .markSpam, .localWebhook(name: "notify"),
        ]
        for action in actions {
            let json = try SenaniJSON.encodeString(ActionDTO(core: action))
            let decoded = try SenaniJSON.decode(ActionDTO.self, from: json)
            #expect(decoded.toCore() == action)
        }
    }

    @Test func ruleDTORoundTripsAcrossEnums() throws {
        for autonomy in [Autonomy.ask, .prepare, .auto] {
            for runOn in [RunOn.incoming, .existing, .both] {
                let rule = Self.rule("r-\(autonomy.rawValue)-\(runOn.rawValue)", autonomy: autonomy, runOn: runOn)
                let json = try SenaniJSON.encodeString(RuleDTO(core: rule))
                let decoded = try SenaniJSON.decode(RuleDTO.self, from: json)
                #expect(decoded.toCore() == rule)
            }
        }
    }

    @Test func triggerAndOutcomeDTORoundTrip() throws {
        for trigger in [Trigger.rule(id: "r1"), .chat(turnId: "c1")] {
            let json = try SenaniJSON.encodeString(TriggerDTO(core: trigger))
            #expect(try SenaniJSON.decode(TriggerDTO.self, from: json).toCore() == trigger)
        }
        for outcome in [Outcome.executed, .prepared, .queuedForApproval] {
            let json = try SenaniJSON.encodeString(OutcomeDTO(core: outcome))
            #expect(try SenaniJSON.decode(OutcomeDTO.self, from: json).toCore() == outcome)
        }
    }

    @Test func ruleStoreCRUD() throws {
        let store = RuleStore(database: try SenaniDatabase.inMemory())
        try store.save(Self.rule("b", enabled: false, name: "B"))
        try store.save(Self.rule("a", enabled: true, name: "A"))
        #expect(try store.fetch(id: "a")?.name == "A")
        #expect(try store.all().map(\.id) == ["a", "b"])
        #expect(try store.enabled().map(\.id) == ["a"])

        try store.save(Self.rule("a", enabled: true, name: "New"))
        #expect(try store.all().count == 2)
        #expect(try store.fetch(id: "a")?.name == "New")

        try store.delete(id: "a")
        #expect(try store.fetch(id: "a") == nil)
    }

    @Test func persistentAuditLogWritesCanonicalSchema() async throws {
        let database = try SenaniDatabase.inMemory()
        let log = PersistentAuditLog(database: database, now: { 42 })
        let record = ActionRecord(
            action: .label("Invoices"),
            messageId: "m1",
            trigger: .rule(id: "r1"),
            outcome: .executed
        )
        await log.record(record)

        let entries = try await log.records()
        #expect(entries == [AuditEntry(record: record, loggedAt: 42)])

        let triggerKind = try await database.queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT json_extract(trigger_json, '$.kind') FROM actions_log"
            )
        }
        #expect(triggerKind == "rule")
    }

    @Test func approvalStorePersistsPendingAndStatusChanges() throws {
        let store = ApprovalStore(database: try SenaniDatabase.inMemory(), now: { 10 })
        let proposal = Proposal(
            action: .send(body: "hello"),
            message: Self.message("m1"),
            trigger: .chat(turnId: "turn1")
        )
        try store.enqueue(id: "p1", proposal)
        #expect(try store.pending() == [StoredProposal(id: "p1", proposal: proposal)])

        try store.approve(id: "p1")
        #expect(try store.pending().isEmpty)
    }

    @Test func ruleRunStoreOrdersByTime() throws {
        let store = RuleRunStore(database: try SenaniDatabase.inMemory())
        try store.record(RuleRun(
            ruleId: "r1", kind: .live, ranAt: 200, messageId: "m2",
            matched: true, outcomes: [.executed]
        ))
        try store.record(RuleRun(
            ruleId: "r1", kind: .simulation, ranAt: 100, messageId: "m1",
            matched: false, outcomes: [.prepared, .queuedForApproval]
        ))

        let runs = try store.runs(ruleId: "r1")
        #expect(runs.map(\.messageId) == ["m1", "m2"])
        #expect(runs[0].outcomes == [.prepared, .queuedForApproval])
        #expect(try store.all().count == 2)
    }

    @Test func messageStoreRoundTripsAndQueries() throws {
        let database = try SenaniDatabase.inMemory()
        let store = MessageStore(database: database)
        try store.save(Self.message("late", from: "Boss@Example.COM", threadId: "t1", date: 300))
        try store.save(Self.message("early", threadId: "t1", date: 100))
        try store.save(Self.message("mine", from: "me@example.com", threadId: "t2", date: 200, isFromUser: true))

        #expect(try store.fetch(id: "late")?.from == "Boss@Example.COM")
        #expect(try store.fetch(id: "late")?.to == ["me@example.com"])
        #expect(try store.thread(id: "t1").map(\.id) == ["early", "late"])
        #expect(try store.query(from: nil, to: nil, isFromUser: nil, limit: 2).map(\.id) == ["late", "mine"])
        #expect(try store.query(from: "me@example.com", to: nil, isFromUser: true, limit: nil).map(\.id) == ["mine"])
        #expect(try store.query(from: nil, to: "me@example.com", isFromUser: nil, limit: nil).map(\.id) == ["late", "mine", "early"])

        let storedDomain = try database.queue.read { db in
            try String.fetchOne(db, sql: "SELECT senderDomain FROM messages WHERE id = 'late'")
        }
        #expect(storedDomain == "example.com")
    }

    @Test func inMemoryVectorIndexRanksAndExposesEntries() throws {
        let index = InMemoryVectorIndex()
        try index.insert(id: "x", vector: [1, 0, 0], metadata: ["kind": "exact"])
        try index.insert(id: "y", vector: [0, 1, 0], metadata: [:])
        try index.insert(id: "z", vector: [0.9, 0.1, 0], metadata: ["kind": "near"])

        let hits = try index.search(vector: [1, 0, 0], k: 2)
        #expect(index.count == 3)
        #expect(index.entries.map(\.id) == ["x", "y", "z"])
        #expect(hits.map(\.id) == ["x", "z"])
        #expect(hits[0].metadata["kind"] == "exact")
    }

    @Test func sqliteVecIndexFallbackUsesPersistedRows() throws {
        let index = try SqliteVecIndex.inMemory()
        try index.insert(id: "x", vector: [1, 0], metadata: ["m": "x"])
        try index.insert(id: "y", vector: [0, 1], metadata: ["m": "y"])
        #expect(try index.search(vector: [1, 0], k: 1).first?.id == "x")
    }

    static func rule(
        _ id: String,
        enabled: Bool = true,
        name: String = "Rule",
        autonomy: Autonomy = .ask,
        runOn: RunOn = .incoming
    ) -> Rule {
        Rule(
            id: id,
            name: name,
            enabled: enabled,
            conditions: Conditions(
                mode: .all,
                structured: [.domain("example.com"), .subjectContains("invoice")],
                aiPredicate: "is an invoice"
            ),
            actions: [.label("Invoices"), .flagNeedsReply],
            autonomy: autonomy,
            runOn: runOn
        )
    }

    static func message(
        _ id: String,
        from: String = "sender@example.com",
        threadId: String = "t1",
        date: Double = 100,
        isFromUser: Bool = false
    ) -> Message {
        Message(
            id: id,
            from: from,
            to: ["me@example.com"],
            subject: "Subject \(id)",
            body: "Body \(id)",
            hasAttachment: false,
            listUnsubscribeHeader: nil,
            labels: ["Inbox"],
            threadId: threadId,
            date: Date(timeIntervalSince1970: date),
            isFromUser: isFromUser
        )
    }
}
