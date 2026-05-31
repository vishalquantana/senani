import Testing
import Foundation
@testable import SenaniEngine

@Suite struct InMemoryPipelineStoreTests {
    private func deal(_ id: String, contact: String, stage: DealStage = .qualified,
                      score: Int? = nil, value: Double? = nil,
                      touch: TimeInterval = 0) -> Deal {
        Deal(id: id, contactEmail: contact, company: nil, stage: stage, score: score,
             value: value, lastTouch: Date(timeIntervalSince1970: touch), sourceMessageId: nil)
    }

    @Test func dealStageCanonicalOrder() {
        #expect(DealStage.allCases == [.lead, .qualified, .proposal, .negotiation, .won, .lost])
    }

    @Test func upsertFetchByContactAllByStage() throws {
        let store = InMemoryPipelineStore()
        try store.upsert(deal("d1", contact: "a@x.com", stage: .qualified, score: 80))
        try store.upsert(deal("d2", contact: "b@x.com", stage: .proposal, value: 1000))

        #expect(try store.fetch(id: "d1")?.score == 80)
        #expect(try store.fetch(id: "missing") == nil)
        #expect(try store.byContact("b@x.com")?.id == "d2")
        #expect(try store.byContact("nobody@x.com") == nil)
        #expect(try store.all().count == 2)
        #expect(try store.byStage(.proposal).map(\.id) == ["d2"])
        #expect(try store.byStage(.won).isEmpty)
    }

    @Test func upsertIsIdempotentOnId() throws {
        let store = InMemoryPipelineStore()
        try store.upsert(deal("d1", contact: "a@x.com", stage: .qualified, score: 10))
        let updated = deal("d1", contact: "a@x.com", stage: .won, score: 99)
        try store.upsert(updated)
        #expect(try store.all().count == 1)
        #expect(try store.fetch(id: "d1")?.stage == .won)
        #expect(try store.fetch(id: "d1")?.score == 99)
    }

    @Test func byContactIsCaseInsensitive() throws {
        let store = InMemoryPipelineStore()
        try store.upsert(deal("d1", contact: "Sarah@Client.com"))
        #expect(try store.byContact("sarah@client.com")?.id == "d1")
    }

    @Test func nullPipelineStoreIsANoOp() throws {
        let store: any PipelineStore = NullPipelineStore()
        try store.upsert(deal("d1", contact: "a@x.com"))
        #expect(try store.all().isEmpty)
        #expect(try store.fetch(id: "d1") == nil)
        #expect(try store.byContact("a@x.com") == nil)
        #expect(try store.byStage(.lead).isEmpty)
    }
}
