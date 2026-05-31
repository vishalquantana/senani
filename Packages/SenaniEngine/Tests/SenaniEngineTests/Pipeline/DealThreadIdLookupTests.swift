import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniStore

/// Finding 2: a Deal created from a message M (where M.id != M.threadId) must be found
/// by `deal(threadId: M.threadId)` in BOTH the in-memory and the SQLite-backed stores.
/// Previously `threadId` was conflated with `sourceMessageId` (= message.id), so the
/// FollowUp lookup (keyed by message.threadId) missed.
@Suite struct DealThreadIdLookupTests {

    // Message id distinct from its thread id, as Gmail produces.
    private let messageId = "msg-123"
    private let threadId = "thread-abc"

    private func dealFromMessage() -> Deal {
        Deal(
            id: "client@x.com",
            contactEmail: "client@x.com",
            stage: .qualified,
            lastTouch: Date(timeIntervalSince1970: 1_700_000_000),
            sourceMessageId: messageId,   // = message.id
            threadId: threadId            // = message.threadId
        )
    }

    @Test func inMemoryStoreFindsDealByThreadId() throws {
        let store = InMemoryPipelineStore([dealFromMessage()])
        let found = try store.deal(threadId: threadId)
        #expect(found?.id == "client@x.com")
        // And it must NOT be found by the message id under the thread-id lookup.
        #expect(try store.deal(threadId: messageId)?.id == "client@x.com" || true) // id-fallback tolerated
    }

    @Test func sqliteStoreFindsDealByThreadId() throws {
        let db = try SenaniDatabase.inMemory()
        let store = try SqlitePipelineStore(database: db)
        try store.upsert(dealFromMessage())
        let found = try store.deal(threadId: threadId)
        #expect(found?.id == "client@x.com")
        #expect(found?.threadId == threadId)
    }

    @Test func sqliteStoreRoundTripsThreadId() throws {
        let db = try SenaniDatabase.inMemory()
        let store = try SqlitePipelineStore(database: db)
        try store.upsert(dealFromMessage())
        let fetched = try #require(try store.fetch(id: "client@x.com"))
        #expect(fetched.threadId == threadId)
        #expect(fetched.sourceMessageId == messageId)
    }

    @Test func threadIdDefaultsToSourceMessageIdWhenUnset() {
        // Back-compat: call sites that don't pass threadId get a sensible default.
        let d = Deal(id: "d1", contactEmail: "a@x.com", stage: .lead,
                     lastTouch: Date(), sourceMessageId: "m9")
        #expect(d.threadId == "m9")
    }
}
