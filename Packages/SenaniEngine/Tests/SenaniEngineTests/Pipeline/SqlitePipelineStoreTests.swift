import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniStore

@Suite struct SqlitePipelineStoreTests {
    private func tempDBPath() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("senani-pipeline-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("senani.sqlite").path
    }

    private func deal(_ id: String, contact: String, company: String? = nil,
                      stage: DealStage = .qualified, score: Int? = nil, value: Double? = nil,
                      touch: TimeInterval = 1_700_000_000, src: String? = nil) -> Deal {
        Deal(id: id, contactEmail: contact, company: company, stage: stage, score: score,
             value: value, lastTouch: Date(timeIntervalSince1970: touch), sourceMessageId: src)
    }

    @Test func crudRoundTripsInMemory() throws {
        let db = try SenaniDatabase.inMemory()
        let store = try SqlitePipelineStore(database: db)

        try store.upsert(deal("d1", contact: "a@x.com", company: "Acme", stage: .qualified,
                              score: 80, value: nil, src: "m1"))
        try store.upsert(deal("d2", contact: "b@x.com", company: nil, stage: .proposal,
                              value: 12000, src: "m2"))

        let d1 = try #require(try store.fetch(id: "d1"))
        #expect(d1.contactEmail == "a@x.com")
        #expect(d1.company == "Acme")
        #expect(d1.stage == .qualified)
        #expect(d1.score == 80)
        #expect(d1.value == nil)
        #expect(d1.sourceMessageId == "m1")
        #expect(d1.lastTouch == Date(timeIntervalSince1970: 1_700_000_000))

        #expect(try store.byContact("B@X.com")?.id == "d2")   // case-insensitive
        #expect(try store.byContact("none@x.com") == nil)
        #expect(try store.all().count == 2)
        #expect(try store.byStage(.proposal).map(\.id) == ["d2"])
        #expect(try store.byStage(.lost).isEmpty)
    }

    @Test func upsertUpdatesExistingRow() throws {
        let db = try SenaniDatabase.inMemory()
        let store = try SqlitePipelineStore(database: db)
        try store.upsert(deal("d1", contact: "a@x.com", stage: .qualified, score: 10))
        try store.upsert(deal("d1", contact: "a@x.com", stage: .won, score: 95, value: 5000))
        #expect(try store.all().count == 1)
        let d = try #require(try store.fetch(id: "d1"))
        #expect(d.stage == .won)
        #expect(d.score == 95)
        #expect(d.value == 5000)
    }

    @Test func dataSurvivesReopen() throws {
        let path = tempDBPath()
        do {
            let db = try SenaniDatabase.file(at: path)
            let store = try SqlitePipelineStore(database: db)
            try store.upsert(deal("d1", contact: "a@x.com", company: "Acme",
                                  stage: .negotiation, score: 60, value: 9000, src: "m9"))
        }
        // Reopen the SAME file with a fresh database + store instance.
        let db2 = try SenaniDatabase.file(at: path)
        let store2 = try SqlitePipelineStore(database: db2)
        let d = try #require(try store2.fetch(id: "d1"))
        #expect(d.company == "Acme")
        #expect(d.stage == .negotiation)
        #expect(d.score == 60)
        #expect(d.value == 9000)
        #expect(d.sourceMessageId == "m9")
        #expect(try store2.all().count == 1)
    }

    @Test func sharesTheSameDatabaseAsMessageStore() throws {
        // Proves the additive `deals` table coexists with the frozen migrator's tables on one db.
        let db = try SenaniDatabase.inMemory()
        let messages = MessageStore(database: db)
        let pipeline = try SqlitePipelineStore(database: db)
        try messages.save(Message(id: "m1", from: "a@x.com", to: ["me@x.com"], subject: "s",
                                  body: "b", hasAttachment: false, listUnsubscribeHeader: nil,
                                  labels: [], threadId: "t1", date: Date(), isFromUser: false))
        try pipeline.upsert(deal("d1", contact: "a@x.com"))
        #expect(try messages.all().count == 1)
        #expect(try pipeline.all().count == 1)
    }
}
