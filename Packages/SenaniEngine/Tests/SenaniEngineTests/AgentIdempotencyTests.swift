import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

/// Finding 3: Agents write to the pipeline/invoice stores INSIDE `proposals(...)` by design
/// (reconciliation §6). Because the Orchestrator can re-process the same message (re-tick), these
/// writes must be IDEMPOTENT: running the SAME agent's `proposals` twice on the SAME message must
/// leave the store in the same state as after the first pass — no duplicate writes, no lastTouch drift.

/// A PipelineStore that counts upserts so a re-run can be detected.
private final class CountingPipelineStore: PipelineStore, @unchecked Sendable {
    private let lock = NSLock()
    private var deals: [String: Deal] = [:]
    private(set) var upsertCount = 0

    init(_ seed: [Deal] = []) { for d in seed { deals[d.id] = d } }

    func upsert(_ deal: Deal) throws {
        lock.lock(); defer { lock.unlock() }
        upsertCount += 1
        deals[deal.id] = deal
    }
    func fetch(id: String) throws -> Deal? { lock.lock(); defer { lock.unlock() }; return deals[id] }
    func byContact(_ email: String) throws -> Deal? {
        lock.lock(); defer { lock.unlock() }
        return deals.values.first { $0.contactEmail.caseInsensitiveCompare(email) == .orderedSame }
    }
    func all() throws -> [Deal] { lock.lock(); defer { lock.unlock() }; return Array(deals.values) }
    func byStage(_ stage: DealStage) throws -> [Deal] {
        lock.lock(); defer { lock.unlock() }; return deals.values.filter { $0.stage == stage }
    }
    func deal(threadId: String) throws -> Deal? {
        lock.lock(); defer { lock.unlock() }
        return deals.values.first { $0.threadId == threadId || $0.id == threadId }
    }
}

private final class CountingInvoiceStore: InvoiceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: InvoiceRecord] = [:]
    private(set) var upsertCount = 0
    func upsert(_ record: InvoiceRecord) throws {
        lock.lock(); defer { lock.unlock() }
        upsertCount += 1
        records[record.id] = record
    }
    func fetch(id: String) throws -> InvoiceRecord? { lock.lock(); defer { lock.unlock() }; return records[id] }
    func all() throws -> [InvoiceRecord] { lock.lock(); defer { lock.unlock() }; return Array(records.values) }
}

@Suite struct AgentIdempotencyTests {

    private func leadMsg() -> Message {
        Message(id: "m1", from: "buyer@acme.com", to: ["me@x.com"],
                subject: "Interested", body: "We'd like a demo and pricing.",
                hasAttachment: false, listUnsubscribeHeader: nil,
                labels: ["Senani/Category/Lead"], threadId: "t-m1",
                date: Date(timeIntervalSince1970: 1_000), isFromUser: false)
    }

    private func leadCtx(_ store: PipelineStore, now: Date) -> AgentContext {
        AgentContext(account: "me@x.com", thread: [], rules: [],
                     retrieve: { _, _ in [] }, now: now, pipeline: store)
    }

    // MARK: LeadQualifierAgent

    @Test func leadQualifierReprocessingDoesNotRewriteUnchangedDeal() async throws {
        let store = CountingPipelineStore()
        let gen = FakeTextGenerator(response:
            #"{"score":88,"company":"Acme Corp","intent":"ready","reason":"wants a quote"}"#)
        let agent = LeadQualifierAgent()
        let m = leadMsg()
        let now = Date(timeIntervalSince1970: 2_000)

        _ = try await agent.proposals(for: m, context: leadCtx(store, now: now), tools: tools(gen))
        let afterFirst = try #require(try store.byContact("buyer@acme.com"))
        let countAfterFirst = store.upsertCount

        // Re-tick: same message, same now. FakeTextGenerator replays the same response.
        _ = try await agent.proposals(for: m, context: leadCtx(store, now: now), tools: tools(gen))

        #expect(store.upsertCount == countAfterFirst)            // no redundant write
        #expect(try store.byContact("buyer@acme.com") == afterFirst)  // identical state
    }

    // MARK: ProposalTrackerAgent (outbound proposal upsert)

    @Test func proposalTrackerReprocessingDoesNotRewriteUnchangedDeal() async throws {
        let store = CountingPipelineStore()
        let classifier = ReplyIntentClassifier(generator: FakeTextGenerator(response: #"{"intent":"other"}"#))
        let agent = ProposalTrackerAgent(classifier: classifier)
        let proposal = Message(
            id: "p1", from: "me@x.com", to: ["client@x.com"],
            subject: "Our proposal", body: "Please find our proposal attached. Quote: $12,000.",
            hasAttachment: true, listUnsubscribeHeader: nil, labels: [],
            threadId: "tp1", date: Date(timeIntervalSince1970: 1_000), isFromUser: true)
        let ctx = AgentContext(account: "me@x.com", thread: [proposal], rules: [],
                               retrieve: { _, _ in [] }, now: Date(timeIntervalSince1970: 2_000),
                               documentFields: [:], pipeline: store)

        _ = try await agent.proposals(for: proposal, context: ctx, tools: tools(FakeTextGenerator()))
        let afterFirst = try store.byContact("client@x.com")
        let countAfterFirst = store.upsertCount
        try #require(afterFirst != nil)

        _ = try await agent.proposals(for: proposal, context: ctx, tools: tools(FakeTextGenerator()))

        #expect(store.upsertCount == countAfterFirst)
        #expect(try store.byContact("client@x.com") == afterFirst)
    }

    // MARK: FollowUpAgent (lastTouch must not drift on re-tick)

    @Test func followUpReprocessingDoesNotRestampLastTouch() async throws {
        let gen = FakeTextGenerator(response: "Just following up.")
        let voice = FakeVoicePrefixProvider(prefix: "V")
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)
        let pipe = InMemoryPipeline(
            deals: [FU.openDeal(id: "d1", threadId: "t1", lastTouch: last.date)],
            threads: ["t1": [last]])
        let agent = FollowUpAgent(generator: gen, voice: voice,
                                  pipelineRead: pipe, pipelineTouch: pipe,
                                  policy: .init(silenceDays: 7, cooldownDays: 3))
        let ctx = FU.context(thread: [last], at: FU.now, pipeline: pipe)

        _ = try await agent.proposals(for: last, context: ctx, tools: tools(FakeTextGenerator()))
        let touchesAfterFirst = pipe.touches.count
        let touchAfterFirst = pipe.currentDeal(id: "d1")?.lastTouch

        // Re-tick at the SAME now.
        _ = try await agent.proposals(for: last, context: ctx, tools: tools(FakeTextGenerator()))

        #expect(pipe.touches.count == touchesAfterFirst)   // no second touch
        #expect(pipe.currentDeal(id: "d1")?.lastTouch == touchAfterFirst)  // no drift
    }

    // MARK: InvoiceFinanceAgent

    @Test func invoiceFinanceReprocessingDoesNotRewriteUnchangedRecord() async throws {
        let invoices = CountingInvoiceStore()
        let agent = InvoiceFinanceAgent()
        let docFields = ["vendor": "Acme", "invoice_number": "INV-1", "amount": "100", "currency": "USD"]
        let m = Message(id: "inv1", from: "billing@acme.com", to: ["me@x.com"],
                        subject: "Invoice INV-1", body: "Invoice attached.",
                        hasAttachment: true, listUnsubscribeHeader: nil, labels: [],
                        threadId: "ti1", date: Date(timeIntervalSince1970: 1_000), isFromUser: false)
        let ctx = AgentContext(account: "me@x.com", thread: [m], rules: [],
                               retrieve: { _, _ in [] }, now: Date(timeIntervalSince1970: 2_000),
                               documentFields: docFields, pipeline: InMemoryPipelineStore(),
                               invoices: invoices)

        _ = try await agent.proposals(for: m, context: ctx, tools: tools(FakeTextGenerator()))
        let countAfterFirst = invoices.upsertCount
        let recordAfterFirst = try invoices.all().first

        _ = try await agent.proposals(for: m, context: ctx, tools: tools(FakeTextGenerator()))

        #expect(invoices.upsertCount == countAfterFirst)            // no redundant write
        #expect(try invoices.all().first == recordAfterFirst)        // identical state
    }
}
