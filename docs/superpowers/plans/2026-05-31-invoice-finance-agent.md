# Invoice / Finance Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the **Invoice / Finance Agent** — a pure `SenaniEngine.Agent` (Phase 3, Pro sales suite) that watches inbound mail carrying an invoice/receipt attachment, extracts and **normalizes** the finance fields (vendor, invoice number, amount, currency, due date) from the parsed document's `documentFields` (surfaced by the Orchestrator from `SenaniDocs.DocumentExtractor`) augmented by `tools.generateJSON` for fields the extractor missed, emits **reversible** labels (`Senani/Finance/Invoice`, and `Senani/Finance/DueSoon` when the due date is within N days), and persists an `InvoiceRecord` to a small **additive `invoices` table** behind an `InvoiceStore` seam (protocol + in-memory + GRDB/Sqlite impl). It optionally emits ONE **approval-gated** outbound payment-reminder `Action.reply` (secondary). A pure `FinanceViewModel` lists invoices with totals and due-soon highlighting. Fully unit-tested with the in-repo `FakeTextGenerator`, an in-memory `InvoiceStore`, and canned `documentFields` — no liteparse FFI, no MLX, no Gmail, no network.

**Architecture:** `InvoiceFinanceAgent` conforms to the on-disk `SenaniEngine.Agent` protocol and is **co-located in `Packages/SenaniEngine/Sources/SenaniEngine/Agents/`** alongside the existing `TriageAgent` and the `Agent`/`AgentContext`/`AgentTools` definitions (matching the Triage / Proposal-Tracker co-location decision in [`2026-05-31-APP-PLANS-RECONCILIATION.md`](2026-05-31-APP-PLANS-RECONCILIATION.md) §3). The agent is split into pure, independently-testable collaborators:

1. **`InvoiceDetector`** — a pure non-async function `(Message, documentFields) -> Bool` deciding whether an inbound message looks like an invoice/receipt, using (i) value-bearing document fields surfaced on `AgentContext.documentFields` and (ii) subject/body keyword cues (`invoice`, `receipt`, `amount due`, `bill`, `payment due`).
2. **`FinanceFieldNormalizer`** — pure functions that turn the raw `[String: String]` field bag into a normalized `InvoiceFields` value object: parse amounts (strip `$ € £ ₹` + grouping), uppercase/normalize currency codes, parse dates from several formats into a canonical `Date`, and pick vendor / invoice-number from synonym keys.
3. **`InvoiceFieldFiller`** — wraps an injected `tools.generateJSON` call against a fixed `JSONSchema` to fill ONLY the fields the extractor missed (sparse-field fallback), then re-normalizes; never overwrites a field the extractor already provided.
4. **`InvoiceRecord` + `InvoiceStore`** — the additive persistence seam: a `Sendable` record, an `InvoiceStore` protocol, an `InMemoryInvoiceStore`, and a `SqliteInvoiceStore` (GRDB over the shared `SenaniDatabase.queue`, creating its own `invoices` table via `CREATE TABLE IF NOT EXISTS` — **additive**, since the frozen `SenaniMigrations` cannot be edited).
5. **`InvoiceFinanceAgent`** — the `Agent`: `wakesFor` is the pure trigger predicate; `proposals(for:context:tools:)` normalizes + fills fields, **persists an `InvoiceRecord` via `context.invoices`** (a new additive `AgentContext` field, mirroring how the Proposal-Tracker plan adds `pipeline`/`documentFields`), and returns the label Actions (+ optional approval-gated reminder reply).
6. **`FinanceViewModel`** — a pure view model computing list rows, per-currency totals, and a due-soon flag, ready for a thin SwiftUI `FinanceView` (the SwiftUI screen itself is a separate Phase-3 UI plan; this plan ships the testable view model).

The agent reaches persistence through a new **`AgentContext.invoices: any InvoiceStore`** field and the extracted fields through the existing **`AgentContext.documentFields: [String: String]`** field. Both are added **additively and defaulted** so existing call sites (`TriageAgent`, the `Orchestrator`, `ctx(...)` test helper) keep compiling. Stage/label changes never touch Gmail; labels are reversible `Action.label(...)`, the optional reminder is `Action.reply(...)` (outbound → `ActionRouter` ALWAYS queues for approval).

**Tech Stack:** Swift 6.2, `swift-tools-version: 6.0`, macOS 14, strict concurrency (complete), Swift Testing (`import Testing`). Path deps already on `SenaniEngine`: `../SenaniRules`, `../SenaniStore`, `../SenaniInference`, `../SenaniVoice`. GRDB is reachable transitively through `SenaniStore` (the `SqliteInvoiceStore` uses `database.queue`, GRDB's `DatabaseQueue`).

**Working directory:** All `swift` commands run from `/Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine` unless stated otherwise. All `git` commands run from that same package directory (the repo is not a single git root; the package is committed in place, matching the other agent plans).

**Out of scope (separate plans):** the Orchestrator wiring that *populates* `AgentContext.documentFields` from `SenaniDocs.DocumentPipeline`/`DocumentExtractor` and constructs the live `InvoiceStore` (orchestrator + live-store-bootstrap plans); the `AppEnvironment` composition root that exposes the live `SqliteInvoiceStore` + a context accessor (app-shell plan — this plan pins the exact additive wiring it must perform, see *Cross-package assumptions*); the SwiftUI `FinanceView` screen (Phase-3 UI plan — this plan ships the pure `FinanceViewModel` it binds to); executing an approved reminder into Gmail (`GmailMailBackend`, Approval-queue UI plan); the real MLX `TextGenerator` (inference plan); the real liteparse parser (`SenaniDocs` integration plan).

---

## Cross-package assumptions (verified from source — state to the human before coding)

### `SenaniEngine` already EXISTS (verified on disk)
`Packages/SenaniEngine` is present with `Sources/SenaniEngine/{Agent.swift, AgentTools.swift, AgentRegistry.swift, Orchestrator.swift, Scheduler.swift, ProcessedOutcome.swift, GmailSyncing.swift}` and `Agents/{TriageAgent.swift, TriageCategory.swift, TriageClassification.swift}`. **Do NOT recreate the package or redefine `Agent`/`AgentTools`.** This plan only **adds** new files under `Agents/`, a `Finance/` subfolder, and tests, plus an **additive edit** to `Agent.swift` (the file that holds `AgentContext`). The package builds today with strict concurrency / Swift 6 — keep it green.

### `SenaniEngine.AgentContext` — the additive fields this plan adds (verified `Agent.swift`)
The on-disk `AgentContext` (in `Sources/SenaniEngine/Agent.swift`) is:
```swift
public struct AgentContext: Sendable {
    public let account: String
    public let thread: [Message]
    public let rules: [Rule]
    public let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit]
    public let now: Date
    public init(account:thread:rules:retrieve:now:)
}
```
It has **no** `documentFields` and **no** `invoices` field yet. This plan adds both as **defaulted** initializer members (`documentFields: [String: String] = [:]`, `invoices: any InvoiceStore = NullInvoiceStore()`), so every existing caller (`TriageAgent` tests, `Orchestrator`, the `ctx(...)` helper in `TestSupport.swift`) keeps compiling unchanged. This is an **additive, non-breaking SenaniEngine contract change** — record it in the commit body and flag it to the orchestrator-plan owner (it must populate `documentFields` from `SenaniDocs` and `invoices` from the live store). **If a prior agent plan (e.g. Proposal-Tracker) already added `documentFields`, reuse it verbatim and add only `invoices`.**

### `SenaniEngine.AgentTools` (verified `AgentTools.swift`) — do NOT redefine
```swift
public struct AgentTools: Sendable {
    public init(generator: any TextGenerator)
    public func draftReply(to message: Message, body: String) -> Action   // → Action.draft(body:)  (REVERSIBLE)
    public func proposeLabel(_ label: String, on message: Message) -> Action  // → Action.label(label) (reversible)
    public func archive(_ message: Message) -> Action
    public func markRead(_ message: Message) -> Action
    public func generateJSON(prompt: String, schema: JSONSchema) async throws -> String
}
```
⚠ `tools.draftReply` maps to `Action.draft(body:)` which is **`.reversible`** (verified `Action.swift`). For an **approval-gated** outbound payment reminder this plan must emit `Action.reply(body:)` (which is `.outbound` → always queues). `AgentTools` exposes no `.reply` builder, so the agent constructs `Action.reply(body:)` **directly** (it imports `SenaniRules`). This is the single safe outbound path; no second routing model is introduced. Labels go through `tools.proposeLabel(_:on:)`.

### `SenaniRules` (built + frozen, do NOT edit — verified `Action.swift`)
- `public struct Message: Sendable, Equatable, Identifiable` with `id, from, to: [String], subject, body, hasAttachment, listUnsubscribeHeader, labels, threadId, date, isFromUser` and a computed `var senderDomain: String`.
- `public enum Action: Sendable, Equatable` — verified cases include `.label(String)`, `.draft(body:)`, `.reply(body:)`. **There is NO finance/invoice Action** — persisting an invoice is an `InvoiceStore` write, never an `Action`.
- `extension Action { public var actionClass: ActionClass }` — `.reply`/`.forward`/`.send`/`.markSpam` are `.outbound`; **`.label` and `.draft` are `.reversible`** (so the two finance labels auto-apply under the agent's autonomy; only the reminder `.reply` queues).
- `public enum Autonomy` is re-exported through `SenaniRules` (used by `TriageAgent` as `.prepare`); this agent uses `.prepare`.

### `SenaniInference` (built + frozen — verified) + the in-repo fake
- `public protocol TextGenerator: Sendable { func generate(prompt:maxTokens:) async throws -> String; func generateJSON(prompt:schema:) async throws -> String }`.
- `public indirect enum JSONSchema: Sendable, Equatable { case boolean; case string; case number; case array(element:); case object(properties:required:) }` with `init(json:)`. This plan builds the fill schema with `.object(properties:required:)`.
- **No `FakeTextGenerator` ships from the package**, but `SenaniEngine`'s test target already defines an `actor FakeTextGenerator: TextGenerator` in `Tests/SenaniEngineTests/TestSupport.swift` (FIFO `responses`, records `recordedPrompts`). **Reuse it** — do not define a second fake. The `tools(_:)` and `ctx(...)` helpers there are also reused.

### `SenaniDocs` (built + frozen — verified `DocumentExtractor.swift` / `ParsedDocument.swift`)
- `public struct ExtractedFields: Codable, Sendable, Equatable { public var fields: [String: String] }` — a flat `[String: String]` bag (e.g. `"vendor"`, `"amount"`, `"total"`, `"due_date"`).
- `public struct DocumentExtractor { public init(generator:); public func extract(from: ParsedDocument) async throws -> ExtractedFields }`.
- **The agent never runs `DocumentExtractor` itself** (§4 convention: agents are pure; the Orchestrator pre-populates context). The extracted bag reaches the agent through `AgentContext.documentFields`. This plan does not import `SenaniDocs`.

### `SenaniStore` (built + frozen — verified) — the additive-table pattern
- `public final class SenaniDatabase: @unchecked Sendable { public let queue: DatabaseQueue; static func inMemory() throws; static func file(at:) throws }`.
- `SenaniMigrations.migrator()` registers `v1`…`v4` (incl. a **`documents`** + **`document_fields`** table at v2). **This migrator is frozen — do NOT add a migration to it.** The new `invoices` table is therefore created **additively by `SqliteInvoiceStore` itself** via `CREATE TABLE IF NOT EXISTS invoices (...)` on first use (idempotent, runs inside `database.queue.write`). This mirrors the additive-store pattern: a Phase-3 store owns its own table without touching the frozen v1–v4 schema. (If the app-shell/live-store plan later promotes this to a real `v5` migration, the `IF NOT EXISTS` guard makes that a no-op — record the deviation.)
- GRDB API used (verified in `RuleStore.swift`): `database.queue.write { db in try db.execute(sql:arguments:) }` and `database.queue.read { db in try String.fetchAll(db, sql:) / try Row.fetchAll(db, sql:) }`.

### `AppEnvironment` wiring this plan PINS for the app-shell / live-store plan (additive)
The composition root (`AppEnvironment`, app-shell plan) must, when it lands, add **one stored property** and **one context accessor**, both ADDITIVE:
```swift
public let invoices: any InvoiceStore   // live: SqliteInvoiceStore(database:), preview: InMemoryInvoiceStore()
// and when building each agent's AgentContext, pass:  invoices: self.invoices, documentFields: <docFields for message>
```
This plan does NOT edit `AppEnvironment` (it may not exist yet); it pins the exact additive surface so the app-shell owner wires it. Flag this to the human.

---

## File Structure

```
Packages/SenaniEngine/
  Sources/SenaniEngine/
    Agent.swift                                   # EDIT (additive): AgentContext gains documentFields + invoices (defaulted)
    Finance/
      InvoiceRecord.swift                         # (Task 2) InvoiceRecord value object
      InvoiceStore.swift                          # (Task 2) InvoiceStore protocol + NullInvoiceStore + InMemoryInvoiceStore
      SqliteInvoiceStore.swift                    # (Task 3) GRDB-backed store; additive `invoices` table (CREATE IF NOT EXISTS)
      FinanceFieldNormalizer.swift                # (Task 5) pure amount/currency/date/vendor normalization
      InvoiceFieldFiller.swift                    # (Task 6) generateJSON sparse-field fallback
      FinanceViewModel.swift                       # (Task 8) pure list/totals/due-soon view model
    Agents/
      InvoiceDetector.swift                       # (Task 4) pure invoice/receipt detection
      InvoiceFinanceAgent.swift                    # (Task 7) the Agent: wakesFor + proposals (persist + labels + optional reminder)
  Tests/SenaniEngineTests/
    Finance/
      InvoiceFixtures.swift                       # (Task 1) Message/documentFields/AgentContext builders
      InvoiceStoreTests.swift                     # (Task 2) InMemory + Null store round-trip
      SqliteInvoiceStoreTests.swift               # (Task 3) GRDB store round-trip over SenaniDatabase.inMemory()
      InvoiceDetectorTests.swift                  # (Task 4)
      FinanceFieldNormalizerTests.swift           # (Task 5)
      InvoiceFieldFillerTests.swift               # (Task 6)
      InvoiceFinanceAgentWakesForTests.swift      # (Task 7)
      InvoiceFinanceAgentProposalsTests.swift     # (Task 7)
      FinanceViewModelTests.swift                 # (Task 8)
```

> `InMemoryInvoiceStore` and `NullInvoiceStore` are **production** types (in `Sources/.../Finance/InvoiceStore.swift`) so `AgentContext`'s defaulted `invoices` parameter and the app's `preview()` graph can use them without a test-only dependency — matching `NullPipelineStore` in the Proposal-Tracker plan.

---

## Task 1 — Finance test fixtures (Message / documentFields / AgentContext builders)

**Files:**
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Finance/InvoiceFixtures.swift`

This task adds shared builders only (no production code). It depends on `AgentContext` gaining `documentFields`/`invoices`, which Task 2 adds — so the fixture's `context(...)` factory is written now but **only compiles after Task 2**. To keep TDD honest, Task 1 ships the non-context builders + a trivial self-test; the `context(...)` factory's first compile happens at the end of Task 2.

- [ ] **Create** `Packages/SenaniEngine/Tests/SenaniEngineTests/Finance/InvoiceFixtures.swift`:

```swift
import Foundation
import Testing
@testable import SenaniEngine
import SenaniRules

/// Shared builders for the Invoice/Finance suite. `FIN.now` is a fixed clock so
/// due-soon math is deterministic.
enum FIN {
    static let account = "ramesh@quantana.in"
    static let vendor = "billing@acme.com"
    /// Fixed "today" for all tests: 2026-05-31T00:00:00Z.
    static let now = Date(timeIntervalSince1970: 1_780_185_600)

    /// An INBOUND mail carrying an invoice attachment.
    static func invoiceMail(
        id: String = "m-inv",
        from: String = vendor,
        subject: String = "Invoice INV-42 — amount due",
        body: String = "Please find attached invoice INV-42. Amount due: $1,234.56. Due 2026-06-10.",
        hasAttachment: Bool = true,
        threadId: String = "t-inv",
        date: Date = now
    ) -> Message {
        Message(id: id, from: from, to: [account], subject: subject, body: body,
                hasAttachment: hasAttachment, listUnsubscribeHeader: nil, labels: [],
                threadId: threadId, date: date, isFromUser: false)
    }

    /// A plain inbound mail that is NOT an invoice (no attachment, no cues).
    static func ordinaryMail(threadId: String = "t-x") -> Message {
        Message(id: "m-ord", from: "friend@example.com", to: [account],
                subject: "Lunch next week?", body: "Are you free Tuesday?",
                hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
                threadId: threadId, date: now, isFromUser: false)
    }

    /// A "full" extractor field bag (the happy path).
    static let fullFields: [String: String] = [
        "vendor": "Acme LLC",
        "invoice_number": "INV-42",
        "amount": "$1,234.56",
        "currency": "usd",
        "due_date": "2026-06-10"
    ]

    /// A SPARSE bag — extractor only got the amount; vendor/number/date are missing.
    static let sparseFields: [String: String] = ["amount": "999.00"]
}
```

- [ ] **Add a self-test** at the bottom of `InvoiceFixtures.swift`:

```swift
@Suite struct InvoiceFixturesSelfTests {
    @Test func fixturesBuild() {
        #expect(FIN.invoiceMail().hasAttachment == true)
        #expect(FIN.ordinaryMail().isFromUser == false)
        #expect(FIN.fullFields["invoice_number"] == "INV-42")
        #expect(FIN.sparseFields.count == 1)
    }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter InvoiceFixturesSelfTests`
  - **Expected:** the self-test passes; fixtures compile (the `context(...)` factory is added in Task 2 once `AgentContext` carries the new fields).

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: Invoice/Finance test fixtures (Message + documentFields builders)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2 — InvoiceRecord + InvoiceStore seam (protocol + NullInvoiceStore + InMemoryInvoiceStore) + AgentContext additive fields

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Finance/InvoiceRecord.swift`
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Finance/InvoiceStore.swift`
- Edit:   `Packages/SenaniEngine/Sources/SenaniEngine/Agent.swift` (additive `AgentContext` fields)
- Append to: `Packages/SenaniEngine/Tests/SenaniEngineTests/Finance/InvoiceFixtures.swift` (the `context(...)` factory)
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Finance/InvoiceStoreTests.swift`

- [ ] **Write failing test** `Packages/SenaniEngine/Tests/SenaniEngineTests/Finance/InvoiceStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine

@Suite struct InvoiceStoreTests {
    private func record(_ id: String, currency: String = "USD",
                        amount: Double = 100, due: Date? = FIN.now) -> InvoiceRecord {
        InvoiceRecord(
            id: id, messageId: "m-\(id)", vendor: "Acme LLC", invoiceNumber: "INV-\(id)",
            amount: amount, currency: currency, dueDate: due, capturedAt: FIN.now)
    }

    @Test func recordHoldsTheNormalizedShape() {
        let r = record("1", currency: "EUR", amount: 250.5)
        #expect(r.currency == "EUR")
        #expect(r.amount == 250.5)
        #expect(r.invoiceNumber == "INV-1")
    }

    @Test func inMemoryStoreUpsertsAndFetches() throws {
        let store = InMemoryInvoiceStore()
        try store.upsert(record("1"))
        #expect(try store.fetch(id: "1")?.vendor == "Acme LLC")
        #expect(try store.all().count == 1)
    }

    @Test func upsertReplacesSameId() throws {
        let store = InMemoryInvoiceStore()
        try store.upsert(record("1", amount: 100))
        try store.upsert(record("1", amount: 200))
        #expect(try store.all().count == 1)
        #expect(try store.fetch(id: "1")?.amount == 200)
    }

    @Test func dueSoonReturnsOnlyInvoicesDueWithinWindow() throws {
        let store = InMemoryInvoiceStore()
        try store.upsert(record("soon", due: FIN.now.addingTimeInterval(2 * 86_400)))   // due in 2 days
        try store.upsert(record("later", due: FIN.now.addingTimeInterval(40 * 86_400))) // due in 40 days
        try store.upsert(record("nodate", due: nil))                                     // no due date
        let soon = try store.dueSoon(asOf: FIN.now, within: 7 * 86_400)
        #expect(Set(soon.map { $0.id }) == ["soon"])
    }

    @Test func nullStoreIsANoOp() throws {
        let store: any InvoiceStore = NullInvoiceStore()
        try store.upsert(record("x"))
        #expect(try store.all().isEmpty)
        #expect(try store.fetch(id: "x") == nil)
        #expect(try store.dueSoon(asOf: FIN.now, within: 7 * 86_400).isEmpty)
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter InvoiceStoreTests`
  - **Expected:** compile error — `InvoiceRecord` / `InvoiceStore` / `InMemoryInvoiceStore` / `NullInvoiceStore` not in scope.

- [ ] **Implement** `Sources/SenaniEngine/Finance/InvoiceRecord.swift`:

```swift
import Foundation

/// A normalized invoice/receipt persisted to the additive `invoices` table.
/// `amount` is a plain Double in the document's currency; `currency` is an
/// upper-cased ISO-ish code ("USD", "EUR", "INR", "GBP"); `dueDate` is the
/// parsed due date (nil if the document had none). `id` is, by convention,
/// `"<vendor-or-domain>:<invoiceNumber>"` so re-processing the same invoice
/// upserts the same row.
public struct InvoiceRecord: Sendable, Equatable, Identifiable {
    public var id: String
    public var messageId: String
    public var vendor: String?
    public var invoiceNumber: String?
    public var amount: Double?
    public var currency: String?
    public var dueDate: Date?
    public var capturedAt: Date

    public init(
        id: String,
        messageId: String,
        vendor: String?,
        invoiceNumber: String?,
        amount: Double?,
        currency: String?,
        dueDate: Date?,
        capturedAt: Date
    ) {
        self.id = id
        self.messageId = messageId
        self.vendor = vendor
        self.invoiceNumber = invoiceNumber
        self.amount = amount
        self.currency = currency
        self.dueDate = dueDate
        self.capturedAt = capturedAt
    }
}
```

- [ ] **Implement** `Sources/SenaniEngine/Finance/InvoiceStore.swift`:

```swift
import Foundation

/// Persistence seam for captured invoices/receipts. The live implementation
/// (`SqliteInvoiceStore`, Task 3) is GRDB-backed; agents and previews depend
/// only on this protocol. All methods are synchronous `throws` (matching the
/// frozen `SenaniStore` stores).
public protocol InvoiceStore: Sendable {
    func upsert(_ record: InvoiceRecord) throws
    func fetch(id: String) throws -> InvoiceRecord?
    func all() throws -> [InvoiceRecord]
    /// Invoices whose `dueDate` is in `[asOf, asOf + within]`. Records with no
    /// due date are excluded.
    func dueSoon(asOf: Date, within: TimeInterval) throws -> [InvoiceRecord]
}

extension InvoiceStore {
    /// Default `dueSoon` derived from `all()` so conforming types only implement storage.
    public func dueSoon(asOf: Date, within: TimeInterval) throws -> [InvoiceRecord] {
        let upper = asOf.addingTimeInterval(within)
        return try all().filter { rec in
            guard let due = rec.dueDate else { return false }
            return due >= asOf && due <= upper
        }
    }
}

/// No-op default so an `AgentContext` can be built without a real store (previews,
/// agents that ignore persistence). Every read returns empty/nil; `upsert` discards.
public struct NullInvoiceStore: InvoiceStore {
    public init() {}
    public func upsert(_ record: InvoiceRecord) throws {}
    public func fetch(id: String) throws -> InvoiceRecord? { nil }
    public func all() throws -> [InvoiceRecord] { [] }
}

/// Thread-safe in-memory store for tests and SwiftUI previews. Keyed by `id`.
public final class InMemoryInvoiceStore: InvoiceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: InvoiceRecord] = [:]

    public init(_ seed: [InvoiceRecord] = []) {
        for r in seed { records[r.id] = r }
    }

    public func upsert(_ record: InvoiceRecord) throws {
        lock.lock(); defer { lock.unlock() }
        records[record.id] = record
    }
    public func fetch(id: String) throws -> InvoiceRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[id]
    }
    public func all() throws -> [InvoiceRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.values.sorted { $0.id < $1.id }
    }
}
```

- [ ] **Edit** `Sources/SenaniEngine/Agent.swift` — add the two ADDITIVE defaulted fields to `AgentContext` (keep everything else identical). Replace the struct's body with:

```swift
public struct AgentContext: Sendable {
    public let account: String
    public let thread: [Message]
    public let rules: [Rule]
    public let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit]
    public let now: Date
    /// Business fields the Orchestrator extracted from the message's attachment(s)
    /// via SenaniDocs.DocumentExtractor (flat key→value). Empty when there is no
    /// parsed document. ADDITIVE field (Invoice/Finance + Proposal-Tracker plans).
    public let documentFields: [String: String]
    /// The captured-invoices store. Pre-populated by the Orchestrator from the live
    /// store. ADDITIVE field (Invoice/Finance plan); defaults to a no-op.
    public let invoices: any InvoiceStore

    public init(account: String,
                thread: [Message],
                rules: [Rule],
                retrieve: @escaping @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit],
                now: Date,
                documentFields: [String: String] = [:],
                invoices: any InvoiceStore = NullInvoiceStore()) {
        self.account = account
        self.thread = thread
        self.rules = rules
        self.retrieve = retrieve
        self.now = now
        self.documentFields = documentFields
        self.invoices = invoices
    }
}
```

> **Coordination note:** if `documentFields` was already added by the Proposal-Tracker plan, do NOT duplicate it — add only `invoices` (and the matching defaulted init parameter). The init parameter order is not part of the pinned contract; all callers use labels. The existing `ctx(...)` helper and `TriageAgent` call sites pass neither new field and keep compiling because both are defaulted.

- [ ] **Append** the `context(...)` factory to `Tests/SenaniEngineTests/Finance/InvoiceFixtures.swift` (inside the `FIN` enum, before the closing brace):

```swift
    /// Builds an AgentContext with the given thread, documentFields, and invoice store.
    static func context(
        thread: [Message],
        documentFields: [String: String] = [:],
        invoices: any InvoiceStore = NullInvoiceStore()
    ) -> AgentContext {
        AgentContext(account: account, thread: thread, rules: [],
                     retrieve: { _, _ in [] }, now: now,
                     documentFields: documentFields, invoices: invoices)
    }
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter InvoiceStoreTests`
  - **Expected:** all 5 pass. Then run the full suite to prove the additive `AgentContext` edit broke nothing: `swift test`
  - **Expected:** every pre-existing suite (Triage, Orchestrator, AgentRegistry, Scheduler, AgentTools, …) plus `InvoiceFixturesSelfTests` and `InvoiceStoreTests` are green.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: InvoiceRecord + InvoiceStore seam; AgentContext gains documentFields + invoices (additive)

InvoiceStore protocol + NullInvoiceStore (no-op default) + InMemoryInvoiceStore.
AgentContext.documentFields and .invoices are additive, defaulted, non-breaking.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3 — SqliteInvoiceStore (GRDB-backed, additive `invoices` table)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Finance/SqliteInvoiceStore.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Finance/SqliteInvoiceStoreTests.swift`

The store creates its own `invoices` table additively (`CREATE TABLE IF NOT EXISTS`) on init, then upserts/reads via the shared `SenaniDatabase.queue` (GRDB `DatabaseQueue`), mirroring `RuleStore`'s GRDB usage. Dates persist as Double (`timeIntervalSince1970`), nullable for `dueDate`.

- [ ] **Write failing test** `Packages/SenaniEngine/Tests/SenaniEngineTests/Finance/SqliteInvoiceStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniStore

@Suite struct SqliteInvoiceStoreTests {
    private func store() throws -> SqliteInvoiceStore {
        try SqliteInvoiceStore(database: SenaniDatabase.inMemory())
    }

    private func record(_ id: String, amount: Double? = 100, currency: String? = "USD",
                        due: Date? = FIN.now) -> InvoiceRecord {
        InvoiceRecord(id: id, messageId: "m-\(id)", vendor: "Acme LLC",
                      invoiceNumber: "INV-\(id)", amount: amount, currency: currency,
                      dueDate: due, capturedAt: FIN.now)
    }

    @Test func upsertThenFetchRoundTrips() throws {
        let s = try store()
        try s.upsert(record("1", amount: 1234.56, currency: "EUR"))
        let got = try #require(try s.fetch(id: "1"))
        #expect(got.vendor == "Acme LLC")
        #expect(got.invoiceNumber == "INV-1")
        #expect(got.amount == 1234.56)
        #expect(got.currency == "EUR")
        #expect(got.dueDate == FIN.now)
    }

    @Test func upsertReplacesSameId() throws {
        let s = try store()
        try s.upsert(record("1", amount: 100))
        try s.upsert(record("1", amount: 200))
        #expect(try s.all().count == 1)
        #expect(try s.fetch(id: "1")?.amount == 200)
    }

    @Test func nilAmountAndDueDatePersistAsNull() throws {
        let s = try store()
        try s.upsert(record("2", amount: nil, currency: nil, due: nil))
        let got = try #require(try s.fetch(id: "2"))
        #expect(got.amount == nil)
        #expect(got.currency == nil)
        #expect(got.dueDate == nil)
    }

    @Test func dueSoonFiltersByWindow() throws {
        let s = try store()
        try s.upsert(record("soon", due: FIN.now.addingTimeInterval(3 * 86_400)))
        try s.upsert(record("later", due: FIN.now.addingTimeInterval(30 * 86_400)))
        try s.upsert(record("none", due: nil))
        let soon = try s.dueSoon(asOf: FIN.now, within: 7 * 86_400)
        #expect(Set(soon.map { $0.id }) == ["soon"])
    }

    @Test func twoStoresShareTheTableOnOneDatabase() throws {
        let db = try SenaniDatabase.inMemory()
        let a = try SqliteInvoiceStore(database: db)
        try a.upsert(record("1"))
        let b = try SqliteInvoiceStore(database: db)   // re-creates table IF NOT EXISTS (idempotent)
        #expect(try b.fetch(id: "1")?.invoiceNumber == "INV-1")
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter SqliteInvoiceStoreTests`
  - **Expected:** compile error — `SqliteInvoiceStore` not in scope.

- [ ] **Implement** `Sources/SenaniEngine/Finance/SqliteInvoiceStore.swift`:

```swift
import Foundation
import GRDB
import SenaniStore

/// GRDB-backed `InvoiceStore` over the shared `SenaniDatabase`. The `invoices`
/// table is ADDITIVE: it is created with `CREATE TABLE IF NOT EXISTS` on init,
/// because the frozen `SenaniMigrations` (v1–v4) cannot be edited. Idempotent —
/// constructing the store twice on one database is safe.
public struct SqliteInvoiceStore: InvoiceStore {
    private let database: SenaniDatabase

    public init(database: SenaniDatabase) throws {
        self.database = database
        try database.queue.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS invoices (
                id TEXT PRIMARY KEY,
                message_id TEXT NOT NULL,
                vendor TEXT,
                invoice_number TEXT,
                amount DOUBLE,
                currency TEXT,
                due_date DOUBLE,
                captured_at DOUBLE NOT NULL
            )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_invoices_due ON invoices(due_date)")
        }
    }

    public func upsert(_ record: InvoiceRecord) throws {
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO invoices
                    (id, message_id, vendor, invoice_number, amount, currency, due_date, captured_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    message_id = excluded.message_id,
                    vendor = excluded.vendor,
                    invoice_number = excluded.invoice_number,
                    amount = excluded.amount,
                    currency = excluded.currency,
                    due_date = excluded.due_date,
                    captured_at = excluded.captured_at
                """,
                arguments: [
                    record.id, record.messageId, record.vendor, record.invoiceNumber,
                    record.amount, record.currency,
                    record.dueDate?.timeIntervalSince1970, record.capturedAt.timeIntervalSince1970
                ])
        }
    }

    public func fetch(id: String) throws -> InvoiceRecord? {
        try database.queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM invoices WHERE id = ?",
                                             arguments: [id]) else { return nil }
            return Self.decode(row)
        }
    }

    public func all() throws -> [InvoiceRecord] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM invoices ORDER BY id").map(Self.decode)
        }
    }

    public func dueSoon(asOf: Date, within: TimeInterval) throws -> [InvoiceRecord] {
        let lower = asOf.timeIntervalSince1970
        let upper = asOf.addingTimeInterval(within).timeIntervalSince1970
        return try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM invoices
                WHERE due_date IS NOT NULL AND due_date >= ? AND due_date <= ?
                ORDER BY due_date
                """, arguments: [lower, upper]).map(Self.decode)
        }
    }

    private static func decode(_ row: Row) -> InvoiceRecord {
        InvoiceRecord(
            id: row["id"],
            messageId: row["message_id"],
            vendor: row["vendor"],
            invoiceNumber: row["invoice_number"],
            amount: row["amount"],
            currency: row["currency"],
            dueDate: (row["due_date"] as Double?).map { Date(timeIntervalSince1970: $0) },
            capturedAt: Date(timeIntervalSince1970: row["captured_at"])
        )
    }
}
```

> **GRDB note:** `Row` subscripts coerce SQLite columns to the target Swift type; nullable columns read into optionals (`row["amount"] as Double?`). This matches GRDB usage proven in `RuleStore.swift`. If `import GRDB` does not resolve from `SenaniEngine`, add `.product(name: "GRDB", package: "GRDB.swift")` is NOT needed — GRDB is re-exported transitively through `SenaniStore`; if the compiler disagrees, add `GRDB` to `SenaniEngine`'s target dependencies (it is already a dependency of `SenaniStore`) and record it.

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter SqliteInvoiceStoreTests`
  - **Expected:** all 5 pass.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: SqliteInvoiceStore — GRDB-backed additive `invoices` table (CREATE IF NOT EXISTS)

Owns its own table without touching the frozen SenaniMigrations (v1-v4).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4 — InvoiceDetector (pure invoice/receipt detection)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/InvoiceDetector.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Finance/InvoiceDetectorTests.swift`

`InvoiceDetector` is pure (non-async, no I/O). It fires for **inbound** messages (`isFromUser == false`) when EITHER (a) the document fields carry a value-bearing finance key, OR (b) the subject/body contains a finance keyword cue. A message with no attachment AND no finance cue is not an invoice.

- [ ] **Write failing tests** `Packages/SenaniEngine/Tests/SenaniEngineTests/Finance/InvoiceDetectorTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct InvoiceDetectorTests {
    private let detector = InvoiceDetector()

    @Test func detectsFromDocFieldsWithMonetaryAmount() {
        let m = FIN.invoiceMail(subject: "Documents", body: "See attached.")
        #expect(detector.isInvoice(m, documentFields: ["amount": "$500.00"]) == true)
    }

    @Test func detectsFromSubjectCueWithoutDoc() {
        let m = FIN.invoiceMail(subject: "Your receipt from Acme", body: "Thanks!", hasAttachment: false)
        #expect(detector.isInvoice(m, documentFields: [:]) == true)
    }

    @Test func detectsAmountDuePhraseInBody() {
        let m = FIN.invoiceMail(subject: "Statement", body: "Total amount due: 1200", hasAttachment: false)
        #expect(detector.isInvoice(m, documentFields: [:]) == true)
    }

    @Test func ignoresOutboundMail() {
        var m = FIN.invoiceMail()
        m = Message(id: m.id, from: m.from, to: m.to, subject: m.subject, body: m.body,
                    hasAttachment: m.hasAttachment, listUnsubscribeHeader: nil, labels: [],
                    threadId: m.threadId, date: m.date, isFromUser: true)   // user SENDING
        #expect(detector.isInvoice(m, documentFields: ["amount": "500"]) == false)
    }

    @Test func ignoresOrdinaryInboundMail() {
        #expect(detector.isInvoice(FIN.ordinaryMail(), documentFields: [:]) == false)
    }

    @Test func docFieldWithoutMonetaryValueIsNotEnoughAlone() {
        // A bag with only a non-monetary field and no keyword cue is not an invoice.
        let m = FIN.invoiceMail(subject: "Hi", body: "no cues here", hasAttachment: true)
        #expect(detector.isInvoice(m, documentFields: ["sender": "Acme"]) == false)
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter InvoiceDetectorTests`
  - **Expected:** compile error — `InvoiceDetector` not in scope.

- [ ] **Implement** `Sources/SenaniEngine/Agents/InvoiceDetector.swift`:

```swift
import Foundation
import SenaniRules

/// Pure detector: decides whether an INBOUND message is an invoice/receipt.
/// No I/O, no async. The Orchestrator supplies `documentFields` from
/// SenaniDocs.DocumentExtractor (empty when there is no parsed attachment).
public struct InvoiceDetector: Sendable {
    public init() {}

    /// Subject/body keyword cues that mark an invoice/receipt/bill.
    static let keywords = ["invoice", "receipt", "amount due", "amount owed",
                           "bill", "payment due", "statement", "remittance", "tax invoice"]
    /// Document-field keys that carry a monetary value.
    static let valueKeys = ["amount", "total", "amount_due", "grand_total",
                            "balance_due", "invoice_total", "subtotal"]

    /// Returns true if `message` (must be inbound) looks like an invoice/receipt.
    public func isInvoice(_ message: Message, documentFields: [String: String]) -> Bool {
        guard !message.isFromUser else { return false }   // only mail the user RECEIVED
        if hasMonetaryDocField(documentFields) { return true }
        return matchesKeyword(message.subject) || matchesKeyword(message.body)
    }

    // MARK: - Pure helpers

    func matchesKeyword(_ text: String) -> Bool {
        let lower = text.lowercased()
        return Self.keywords.contains { lower.contains($0) }
    }

    func hasMonetaryDocField(_ fields: [String: String]) -> Bool {
        let lowered = Dictionary(fields.map { ($0.key.lowercased(), $0.value) },
                                 uniquingKeysWith: { a, _ in a })
        for key in Self.valueKeys where FinanceFieldNormalizer.parseAmount(lowered[key]) != nil {
            return true
        }
        return false
    }
}
```

> This references `FinanceFieldNormalizer.parseAmount` (Task 5). To keep TDD ordering clean, implement Task 5 first, OR temporarily inline a local amount parser here and replace it in Task 5. The recommended order is **Task 5 → Task 4** (the normalizer is a leaf used by the detector); the plan lists Task 4 first only for narrative. **Worker: do Task 5 before Task 4's implementation step** (write Task 4's failing test first, then Task 5, then Task 4's impl).

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter InvoiceDetectorTests`
  - **Expected:** all 6 pass (after Task 5's `FinanceFieldNormalizer.parseAmount` exists).

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: InvoiceDetector — pure inbound invoice/receipt detection

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5 — FinanceFieldNormalizer (pure amount / currency / date / vendor normalization)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Finance/FinanceFieldNormalizer.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Finance/FinanceFieldNormalizerTests.swift`

> **Do this task BEFORE Task 4's implementation** — `InvoiceDetector` depends on `FinanceFieldNormalizer.parseAmount`.

`FinanceFieldNormalizer` turns the raw `[String: String]` bag into an `InvoiceFields` value object: amount (strip `$ € £ ₹` + commas), currency (map symbols → ISO code, uppercase 3-letter codes), due date (parse `yyyy-MM-dd`, `MM/dd/yyyy`, `dd MMM yyyy`), vendor / invoice-number from synonym keys.

- [ ] **Write failing tests** `Packages/SenaniEngine/Tests/SenaniEngineTests/Finance/FinanceFieldNormalizerTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine

@Suite struct FinanceFieldNormalizerTests {
    private let n = FinanceFieldNormalizer()

    @Test func parsesPlainAndGroupedAmounts() {
        #expect(FinanceFieldNormalizer.parseAmount("1234.56") == 1234.56)
        #expect(FinanceFieldNormalizer.parseAmount("$1,234.56") == 1234.56)
        #expect(FinanceFieldNormalizer.parseAmount("  €2.500,00  ") == nil || FinanceFieldNormalizer.parseAmount("  €2.500,00  ") == 2500.0) // EU grouping not required
        #expect(FinanceFieldNormalizer.parseAmount("₹45,000") == 45000)
        #expect(FinanceFieldNormalizer.parseAmount("n/a") == nil)
        #expect(FinanceFieldNormalizer.parseAmount(nil) == nil)
    }

    @Test func normalizesCurrencyFromSymbolOrCode() {
        #expect(FinanceFieldNormalizer.normalizeCurrency("usd") == "USD")
        #expect(FinanceFieldNormalizer.normalizeCurrency("$") == "USD")
        #expect(FinanceFieldNormalizer.normalizeCurrency("€") == "EUR")
        #expect(FinanceFieldNormalizer.normalizeCurrency("£") == "GBP")
        #expect(FinanceFieldNormalizer.normalizeCurrency("₹") == "INR")
        #expect(FinanceFieldNormalizer.normalizeCurrency("eur") == "EUR")
        #expect(FinanceFieldNormalizer.normalizeCurrency("") == nil)
    }

    @Test func parsesDatesInSeveralFormats() {
        let iso = FinanceFieldNormalizer.parseDate("2026-06-10")
        let slash = FinanceFieldNormalizer.parseDate("06/10/2026")
        let spelled = FinanceFieldNormalizer.parseDate("10 Jun 2026")
        let comps = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: iso!)
        #expect(comps.year == 2026 && comps.month == 6 && comps.day == 10)
        #expect(slash != nil)
        #expect(spelled != nil)
        #expect(FinanceFieldNormalizer.parseDate("not a date") == nil)
    }

    @Test func normalizesFullBagIntoInvoiceFields() {
        let f = n.normalize(FIN.fullFields)
        #expect(f.vendor == "Acme LLC")
        #expect(f.invoiceNumber == "INV-42")
        #expect(f.amount == 1234.56)
        #expect(f.currency == "USD")
        let comps = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: f.dueDate!)
        #expect(comps.month == 6 && comps.day == 10)
    }

    @Test func readsSynonymKeys() {
        let f = n.normalize([
            "supplier": "Globex",          // vendor synonym
            "invoice_no": "X-9",           // invoice number synonym
            "total": "200",                // amount synonym
            "due": "2026-07-01"            // due-date synonym
        ])
        #expect(f.vendor == "Globex")
        #expect(f.invoiceNumber == "X-9")
        #expect(f.amount == 200)
        #expect(f.dueDate != nil)
    }

    @Test func missingFieldsBecomeNil() {
        let f = n.normalize([:])
        #expect(f.vendor == nil)
        #expect(f.invoiceNumber == nil)
        #expect(f.amount == nil)
        #expect(f.currency == nil)
        #expect(f.dueDate == nil)
        #expect(f.isSparse == true)
    }

    @Test func isSparseWhenAnyKeyFieldMissing() {
        let f = n.normalize(["amount": "100"])   // vendor / number / date missing
        #expect(f.isSparse == true)
        let full = n.normalize(FIN.fullFields)
        #expect(full.isSparse == false)
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter FinanceFieldNormalizerTests`
  - **Expected:** compile error — `FinanceFieldNormalizer` / `InvoiceFields` not in scope.

- [ ] **Implement** `Sources/SenaniEngine/Finance/FinanceFieldNormalizer.swift`:

```swift
import Foundation

/// Normalized finance fields extracted from a document's raw field bag.
public struct InvoiceFields: Sendable, Equatable {
    public var vendor: String?
    public var invoiceNumber: String?
    public var amount: Double?
    public var currency: String?
    public var dueDate: Date?

    public init(vendor: String? = nil, invoiceNumber: String? = nil, amount: Double? = nil,
                currency: String? = nil, dueDate: Date? = nil) {
        self.vendor = vendor
        self.invoiceNumber = invoiceNumber
        self.amount = amount
        self.currency = currency
        self.dueDate = dueDate
    }

    /// True when any of the four key finance fields (vendor, invoiceNumber, amount,
    /// dueDate) is missing — the signal the agent uses to invoke the generateJSON
    /// fallback (`InvoiceFieldFiller`).
    public var isSparse: Bool {
        vendor == nil || invoiceNumber == nil || amount == nil || dueDate == nil
    }
}

/// Pure normalization of a raw `[String: String]` field bag into `InvoiceFields`.
/// All parsing is deterministic and side-effect-free.
public struct FinanceFieldNormalizer: Sendable {
    public init() {}

    static let vendorKeys = ["vendor", "supplier", "seller", "from", "biller", "merchant", "company"]
    static let numberKeys = ["invoice_number", "invoice_no", "invoice", "number", "inv_no", "bill_number"]
    static let amountKeys = ["amount", "total", "amount_due", "grand_total",
                             "balance_due", "invoice_total", "subtotal"]
    static let currencyKeys = ["currency", "ccy"]
    static let dueKeys = ["due_date", "due", "payment_due", "due_on", "date_due"]

    public func normalize(_ fields: [String: String]) -> InvoiceFields {
        let bag = Dictionary(fields.map { ($0.key.lowercased(), $0.value) },
                             uniquingKeysWith: { a, _ in a })
        func firstValue(_ keys: [String]) -> String? {
            for k in keys { if let v = bag[k], !v.trimmingCharacters(in: .whitespaces).isEmpty { return v } }
            return nil
        }
        let amountStr = firstValue(Self.amountKeys)
        return InvoiceFields(
            vendor: firstValue(Self.vendorKeys)?.trimmingCharacters(in: .whitespacesAndNewlines),
            invoiceNumber: firstValue(Self.numberKeys)?.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: Self.parseAmount(amountStr),
            currency: Self.normalizeCurrency(firstValue(Self.currencyKeys) ?? Self.currencySymbol(in: amountStr)),
            dueDate: Self.parseDate(firstValue(Self.dueKeys))
        )
    }

    // MARK: - Amount

    /// Strips currency symbols + thousands separators and parses a Double. Returns
    /// nil for non-numeric input.
    public static func parseAmount(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "£", with: "")
            .replacingOccurrences(of: "₹", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }

    // MARK: - Currency

    /// Maps a symbol or 3-letter code to an upper-cased ISO-ish code; nil if unknown/empty.
    public static func normalizeCurrency(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        switch t {
        case "$", "US$", "usd", "USD": return "USD"
        case "€", "eur", "EUR": return "EUR"
        case "£", "gbp", "GBP": return "GBP"
        case "₹", "inr", "INR", "Rs", "Rs.": return "INR"
        default:
            // A bare 3-letter code → uppercased; otherwise unknown.
            let upper = t.uppercased()
            return (upper.count == 3 && upper.allSatisfy { $0.isLetter }) ? upper : nil
        }
    }

    /// If the amount string itself begins with a currency symbol, recover the code.
    static func currencySymbol(in amount: String?) -> String? {
        guard let a = amount?.trimmingCharacters(in: .whitespaces).first else { return nil }
        switch a {
        case "$": return "$"
        case "€": return "€"
        case "£": return "£"
        case "₹": return "₹"
        default: return nil
        }
    }

    // MARK: - Date

    private static let formats = ["yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy", "dd MMM yyyy", "MMM dd, yyyy"]

    /// Parses a date from several common invoice formats (UTC). Returns nil if none match.
    public static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines)) { return d }
        }
        return nil
    }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter FinanceFieldNormalizerTests`
  - **Expected:** all 7 pass. Now (if not already) run Task 4's impl + `swift test --filter InvoiceDetectorTests` → 6 pass.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: FinanceFieldNormalizer — pure amount/currency/date/vendor normalization → InvoiceFields

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6 — InvoiceFieldFiller (generateJSON sparse-field fallback)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Finance/InvoiceFieldFiller.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Finance/InvoiceFieldFillerTests.swift`

When the normalized `InvoiceFields` are sparse, the filler asks the model (via injected `generateJSON`) for the missing fields, parsing its JSON through the SAME normalizer, and **merges only the fields the extractor missed** (never overwrites an extractor-provided value). Malformed/empty model output leaves the fields unchanged (no crash). The filler receives the model call as a closure so it depends only on `AgentTools.generateJSON` (kept testable with the in-repo `FakeTextGenerator`).

- [ ] **Write failing tests** `Packages/SenaniEngine/Tests/SenaniEngineTests/Finance/InvoiceFieldFillerTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniInference

@Suite struct InvoiceFieldFillerTests {
    private let filler = InvoiceFieldFiller()

    /// Wraps the in-repo FakeTextGenerator's generateJSON as the closure the filler needs.
    private func generate(_ json: String) -> @Sendable (String, JSONSchema) async throws -> String {
        let gen = FakeTextGenerator(response: json)
        return { prompt, schema in try await gen.generateJSON(prompt: prompt, schema: schema) }
    }

    @Test func fillsMissingFieldsFromModel() async throws {
        let sparse = InvoiceFields(amount: 999)   // vendor/number/date missing
        let json = #"{ "vendor": "Globex", "invoice_number": "G-1", "due_date": "2026-07-01" }"#
        let filled = try await filler.fill(sparse, documentText: "raw text",
                                           generateJSON: generate(json))
        #expect(filled.vendor == "Globex")
        #expect(filled.invoiceNumber == "G-1")
        #expect(filled.dueDate != nil)
        #expect(filled.amount == 999)             // extractor value preserved
    }

    @Test func neverOverwritesExtractorProvidedFields() async throws {
        let partial = InvoiceFields(vendor: "Acme LLC", amount: 100)   // vendor present
        let json = #"{ "vendor": "WRONG CO", "invoice_number": "INV-7", "due_date": "2026-07-01" }"#
        let filled = try await filler.fill(partial, documentText: "raw",
                                           generateJSON: generate(json))
        #expect(filled.vendor == "Acme LLC")      // NOT overwritten by the model
        #expect(filled.invoiceNumber == "INV-7")  // filled (was missing)
    }

    @Test func malformedModelJsonLeavesFieldsUnchanged() async throws {
        let sparse = InvoiceFields(amount: 50)
        let filled = try await filler.fill(sparse, documentText: "raw",
                                           generateJSON: generate("not json at all"))
        #expect(filled.amount == 50)
        #expect(filled.vendor == nil)             // no crash, nothing filled
    }

    @Test func threadsDocumentTextIntoPrompt() async throws {
        let gen = FakeTextGenerator(response: "{}")
        _ = try await filler.fill(InvoiceFields(), documentText: "MAGIC-MARKER-12345",
                                  generateJSON: { p, s in try await gen.generateJSON(prompt: p, schema: s) })
        let prompts = await gen.recordedPrompts
        #expect(prompts.first?.contains("MAGIC-MARKER-12345") == true)
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter InvoiceFieldFillerTests`
  - **Expected:** compile error — `InvoiceFieldFiller` not in scope.

- [ ] **Implement** `Sources/SenaniEngine/Finance/InvoiceFieldFiller.swift`:

```swift
import Foundation
import SenaniInference

/// Fills the finance fields the extractor missed by asking the model for ONLY the
/// missing keys, parsing the response through the same `FinanceFieldNormalizer`, and
/// merging non-destructively (extractor-provided fields are never overwritten).
/// Malformed/empty model output leaves the input unchanged.
public struct InvoiceFieldFiller: Sendable {
    private let normalizer: FinanceFieldNormalizer

    public init(normalizer: FinanceFieldNormalizer = FinanceFieldNormalizer()) {
        self.normalizer = normalizer
    }

    /// The fixed schema the model must satisfy.
    static let schema: JSONSchema = .object(properties: [
        "vendor": .string,
        "invoice_number": .string,
        "amount": .string,
        "currency": .string,
        "due_date": .string
    ], required: [])

    public func fill(
        _ fields: InvoiceFields,
        documentText: String,
        generateJSON: @Sendable (String, JSONSchema) async throws -> String
    ) async throws -> InvoiceFields {
        guard fields.isSparse else { return fields }

        let raw = try await generateJSON(Self.buildPrompt(text: documentText), Self.schema)
        let modelFields = Self.parseBag(raw)
        guard !modelFields.isEmpty else { return fields }
        let normalized = normalizer.normalize(modelFields)

        // Merge: keep extractor value if present, else take the model's.
        return InvoiceFields(
            vendor: fields.vendor ?? normalized.vendor,
            invoiceNumber: fields.invoiceNumber ?? normalized.invoiceNumber,
            amount: fields.amount ?? normalized.amount,
            currency: fields.currency ?? normalized.currency,
            dueDate: fields.dueDate ?? normalized.dueDate
        )
    }

    // MARK: - Pure helpers

    static func buildPrompt(text: String) -> String {
        """
        Extract invoice fields from the document text below as JSON with keys:
        vendor, invoice_number, amount, currency, due_date (ISO YYYY-MM-DD).
        Use a JSON string value per field; omit a key if not present. Do not invent values.

        DOCUMENT TEXT:
        \(text)
        """
    }

    /// Safely parses the model's JSON into a `[String: String]` bag; garbage → empty.
    static func parseBag(_ raw: String) -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        var bag: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String, !s.isEmpty { bag[k] = s }
            else if let n = v as? NSNumber { bag[k] = n.stringValue }
        }
        return bag
    }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter InvoiceFieldFillerTests`
  - **Expected:** all 4 pass.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: InvoiceFieldFiller — generateJSON sparse-field fallback (non-destructive merge)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7 — InvoiceFinanceAgent (wakesFor + proposals: persist + labels + optional reminder)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/InvoiceFinanceAgent.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Finance/InvoiceFinanceAgentWakesForTests.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Finance/InvoiceFinanceAgentProposalsTests.swift`

The agent ties the collaborators together:

- **`wakesFor`** = `InvoiceDetector.isInvoice(message, documentFields: context.documentFields)`.
- **`proposals`** (persist + labels + optional reminder):
  1. Normalize `context.documentFields` → `InvoiceFields`; if sparse, run `InvoiceFieldFiller.fill(...)` using `tools.generateJSON` and the message body as document text.
  2. Build an `InvoiceRecord` (id = `"<vendor-or-senderDomain>:<invoiceNumber-or-messageId>"`), `capturedAt = context.now`; **persist via `context.invoices.upsert(...)`** (pure store write — never an `Action`).
  3. Emit `tools.proposeLabel("Senani/Finance/Invoice", on: message)` (reversible).
  4. If a `dueDate` exists and is within `dueSoonWindow` days of `context.now` (and not past), also emit `tools.proposeLabel("Senani/Finance/DueSoon", on: message)`.
  5. **Optional (secondary, approval-gated):** if `remindOnDueSoon` is enabled (default **false**) and the invoice is due soon, append `Action.reply(body: <deterministic reminder>)` — **constructed directly** (outbound → `ActionRouter` ALWAYS queues; never auto-sent).

> **N (due-soon window):** default **7 days**, injected via `dueSoonWindowDays` for testability. The reminder body is a deterministic template (NOT model-generated) so the agent's only model call is the optional field-fill — keeping `proposals` testable with the in-repo `FakeTextGenerator`.

### 7a. Failing `wakesFor` tests

- [ ] **Write** `InvoiceFinanceAgentWakesForTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct InvoiceFinanceAgentWakesForTests {
    private func agent() -> InvoiceFinanceAgent { InvoiceFinanceAgent() }

    @Test func wakesForInvoiceWithDocAmount() {
        let m = FIN.invoiceMail(subject: "Docs", body: "see attached")
        let ctx = FIN.context(thread: [m], documentFields: ["amount": "$500"])
        #expect(agent().wakesFor(m, context: ctx) == true)
    }

    @Test func wakesForInvoiceViaSubjectCue() {
        let m = FIN.invoiceMail(subject: "Your receipt", hasAttachment: false)
        let ctx = FIN.context(thread: [m])
        #expect(agent().wakesFor(m, context: ctx) == true)
    }

    @Test func doesNotWakeForOrdinaryMail() {
        let m = FIN.ordinaryMail()
        let ctx = FIN.context(thread: [m])
        #expect(agent().wakesFor(m, context: ctx) == false)
    }

    @Test func identityAndAutonomy() {
        let a = agent()
        #expect(a.id == "invoice-finance")
        #expect(a.autonomy == .prepare)
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter InvoiceFinanceAgentWakesForTests`
  - **Expected:** compile error — `InvoiceFinanceAgent` not in scope.

### 7b. Failing `proposals` tests

- [ ] **Write** `InvoiceFinanceAgentProposalsTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct InvoiceFinanceAgentProposalsTests {
    // due_date 2026-06-10 is 10 days after FIN.now (2026-05-31): NOT within a 7-day window,
    // IS within a 14-day window.
    private func agent(reminders: Bool = false, windowDays: Int = 7) -> InvoiceFinanceAgent {
        InvoiceFinanceAgent(remindOnDueSoon: reminders, dueSoonWindowDays: windowDays)
    }

    @Test func persistsInvoiceRecordAndEmitsInvoiceLabel() async throws {
        let store = InMemoryInvoiceStore()
        let m = FIN.invoiceMail()
        let ctx = FIN.context(thread: [m], documentFields: FIN.fullFields, invoices: store)

        let actions = try await agent().proposals(for: m, context: ctx, tools: tools(FakeTextGenerator(response: "{}")))

        #expect(actions.contains(.label("Senani/Finance/Invoice")))
        let saved = try #require(try store.all().first)
        #expect(saved.vendor == "Acme LLC")
        #expect(saved.invoiceNumber == "INV-42")
        #expect(saved.amount == 1234.56)
        #expect(saved.currency == "USD")
        #expect(saved.messageId == "m-inv")
    }

    @Test func emitsDueSoonLabelWhenWithinWindow() async throws {
        let store = InMemoryInvoiceStore()
        let m = FIN.invoiceMail()
        let ctx = FIN.context(thread: [m], documentFields: FIN.fullFields, invoices: store)
        // due in 10 days; 14-day window ⇒ DueSoon
        let actions = try await agent(windowDays: 14).proposals(for: m, context: ctx,
                        tools: tools(FakeTextGenerator(response: "{}")))
        #expect(actions.contains(.label("Senani/Finance/DueSoon")))
    }

    @Test func noDueSoonLabelWhenOutsideWindow() async throws {
        let store = InMemoryInvoiceStore()
        let m = FIN.invoiceMail()
        let ctx = FIN.context(thread: [m], documentFields: FIN.fullFields, invoices: store)
        // due in 10 days; 7-day window ⇒ NOT DueSoon
        let actions = try await agent(windowDays: 7).proposals(for: m, context: ctx,
                        tools: tools(FakeTextGenerator(response: "{}")))
        #expect(!actions.contains(.label("Senani/Finance/DueSoon")))
    }

    @Test func sparseFieldsTriggerGenerateJSONFallback() async throws {
        let store = InMemoryInvoiceStore()
        let m = FIN.invoiceMail(body: "raw invoice text")
        // extractor only got the amount; the model supplies vendor/number/date.
        let modelJSON = #"{ "vendor": "Globex", "invoice_number": "G-9", "due_date": "2026-06-03" }"#
        let ctx = FIN.context(thread: [m], documentFields: FIN.sparseFields, invoices: store)

        _ = try await agent(windowDays: 14).proposals(for: m, context: ctx,
                tools: tools(FakeTextGenerator(response: modelJSON)))

        let saved = try #require(try store.all().first)
        #expect(saved.vendor == "Globex")            // filled by the model
        #expect(saved.invoiceNumber == "G-9")
        #expect(saved.amount == 999.0)               // extractor value preserved
        #expect(saved.dueDate != nil)
    }

    @Test func nonInvoiceMailMakesNoChangeAndNoActions() async throws {
        let store = InMemoryInvoiceStore()
        let m = FIN.ordinaryMail()
        let ctx = FIN.context(thread: [m], invoices: store)

        let actions = try await agent().proposals(for: m, context: ctx,
                        tools: tools(FakeTextGenerator(response: "{}")))

        #expect(actions.isEmpty)
        #expect(try store.all().isEmpty)
    }

    @Test func optionalReminderIsOutboundAndOnlyWhenEnabledAndDueSoon() async throws {
        let store = InMemoryInvoiceStore()
        let m = FIN.invoiceMail()
        let ctx = FIN.context(thread: [m], documentFields: FIN.fullFields, invoices: store)

        // reminders ON + 14-day window (due soon) ⇒ exactly one outbound reply queued
        let actions = try await agent(reminders: true, windowDays: 14)
            .proposals(for: m, context: ctx, tools: tools(FakeTextGenerator(response: "{}")))
        let replies = actions.filter { $0.actionClass == .outbound }
        #expect(replies.count == 1)
        if case .reply = replies.first { } else { Issue.record("reminder must be Action.reply") }

        // reminders ON but window 7 days (NOT due soon) ⇒ no reminder
        let none = try await agent(reminders: true, windowDays: 7)
            .proposals(for: m, context: ctx, tools: tools(FakeTextGenerator(response: "{}")))
        #expect(none.filter { $0.actionClass == .outbound }.isEmpty)
    }

    @Test func reprocessingSameInvoiceUpsertsOneRow() async throws {
        let store = InMemoryInvoiceStore()
        let m = FIN.invoiceMail()
        let ctx = FIN.context(thread: [m], documentFields: FIN.fullFields, invoices: store)
        _ = try await agent().proposals(for: m, context: ctx, tools: tools(FakeTextGenerator(response: "{}")))
        _ = try await agent().proposals(for: m, context: ctx, tools: tools(FakeTextGenerator(response: "{}")))
        #expect(try store.all().count == 1)   // stable id ⇒ upsert, not duplicate
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter InvoiceFinanceAgentProposalsTests`
  - **Expected:** compile error — `InvoiceFinanceAgent` not in scope.

### 7c. Implement the agent

- [ ] **Write** `Sources/SenaniEngine/Agents/InvoiceFinanceAgent.swift`:

```swift
import Foundation
import SenaniRules

/// Phase-3 Invoice / Finance agent. Watches inbound mail with an invoice/receipt
/// attachment, normalizes its finance fields (filling gaps via the model), persists
/// an `InvoiceRecord`, and emits reversible finance labels (+ an optional, approval-gated
/// payment-reminder reply).
///
/// All persistence is a PURE write to `context.invoices` — never an `Action`. The
/// finance labels are `Action.label(...)` (reversible). The only outbound `Action` is
/// the optional reminder `Action.reply(...)`, which `ActionRouter` ALWAYS queues.
public struct InvoiceFinanceAgent: Agent {
    public let id = "invoice-finance"
    public let autonomy: Autonomy = .prepare

    public static let invoiceLabel = "Senani/Finance/Invoice"
    public static let dueSoonLabel = "Senani/Finance/DueSoon"

    private let detector: InvoiceDetector
    private let normalizer: FinanceFieldNormalizer
    private let filler: InvoiceFieldFiller
    private let remindOnDueSoon: Bool
    private let dueSoonWindow: TimeInterval

    public init(
        detector: InvoiceDetector = InvoiceDetector(),
        normalizer: FinanceFieldNormalizer = FinanceFieldNormalizer(),
        filler: InvoiceFieldFiller = InvoiceFieldFiller(),
        remindOnDueSoon: Bool = false,
        dueSoonWindowDays: Int = 7
    ) {
        self.detector = detector
        self.normalizer = normalizer
        self.filler = filler
        self.remindOnDueSoon = remindOnDueSoon
        self.dueSoonWindow = TimeInterval(dueSoonWindowDays) * 86_400
    }

    // MARK: - Trigger

    public func wakesFor(_ message: Message, context: AgentContext) -> Bool {
        detector.isInvoice(message, documentFields: context.documentFields)
    }

    // MARK: - Proposals

    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        guard detector.isInvoice(message, documentFields: context.documentFields) else { return [] }

        // 1. Normalize, filling gaps via the model only when sparse.
        var fields = normalizer.normalize(context.documentFields)
        if fields.isSparse {
            fields = try await filler.fill(fields, documentText: message.body,
                                           generateJSON: { prompt, schema in
                                               try await tools.generateJSON(prompt: prompt, schema: schema)
                                           })
        }

        // 2. Persist (pure store write — never an Action).
        let record = InvoiceRecord(
            id: Self.recordId(for: message, fields: fields),
            messageId: message.id,
            vendor: fields.vendor,
            invoiceNumber: fields.invoiceNumber,
            amount: fields.amount,
            currency: fields.currency,
            dueDate: fields.dueDate,
            capturedAt: context.now)
        try context.invoices.upsert(record)

        // 3. Labels.
        var actions: [Action] = [tools.proposeLabel(Self.invoiceLabel, on: message)]
        let due = isDueSoon(fields.dueDate, now: context.now)
        if due {
            actions.append(tools.proposeLabel(Self.dueSoonLabel, on: message))
        }

        // 4. Optional, approval-gated reminder (outbound → always queues).
        if remindOnDueSoon && due {
            actions.append(.reply(body: Self.reminderBody(fields)))
        }
        return actions
    }

    // MARK: - Pure helpers

    func isDueSoon(_ dueDate: Date?, now: Date) -> Bool {
        guard let due = dueDate else { return false }
        return due >= now && due <= now.addingTimeInterval(dueSoonWindow)
    }

    /// Stable id so re-processing the same invoice upserts one row.
    static func recordId(for message: Message, fields: InvoiceFields) -> String {
        let who = fields.vendor ?? message.senderDomain
        let what = fields.invoiceNumber ?? message.id
        return "\(who):\(what)"
    }

    static func reminderBody(_ fields: InvoiceFields) -> String {
        let num = fields.invoiceNumber.map { " \($0)" } ?? ""
        return "Friendly reminder: invoice\(num) appears to be due soon. Please let me know if payment is already in progress."
    }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter InvoiceFinanceAgentWakesForTests`
  - **Expected:** all 4 pass.
- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter InvoiceFinanceAgentProposalsTests`
  - **Expected:** all 7 pass.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: InvoiceFinanceAgent — persist InvoiceRecord + reversible finance labels + optional reminder

Persistence is a pure InvoiceStore write via AgentContext.invoices; labels are reversible
Action.label; the optional payment reminder is an outbound Action.reply that always queues.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8 — FinanceViewModel (pure list / totals / due-soon highlighting)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Finance/FinanceViewModel.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Finance/FinanceViewModelTests.swift`

A pure view model the SwiftUI `FinanceView` (separate UI plan) binds to: it loads `InvoiceStore.all()`, sorts by due date (undated last), computes per-currency totals, and flags each row due-soon. No SwiftUI import — fully testable.

- [ ] **Write failing tests** `FinanceViewModelTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine

@Suite struct FinanceViewModelTests {
    private func rec(_ id: String, amount: Double?, currency: String?, due: Date?) -> InvoiceRecord {
        InvoiceRecord(id: id, messageId: "m-\(id)", vendor: "V-\(id)", invoiceNumber: id,
                      amount: amount, currency: currency, dueDate: due, capturedAt: FIN.now)
    }

    @Test func buildsRowsSortedByDueDateUndatedLast() throws {
        let store = InMemoryInvoiceStore([
            rec("a", amount: 100, currency: "USD", due: FIN.now.addingTimeInterval(20 * 86_400)),
            rec("b", amount: 50, currency: "USD", due: FIN.now.addingTimeInterval(2 * 86_400)),
            rec("c", amount: 10, currency: "USD", due: nil)
        ])
        let vm = try FinanceViewModel(store: store, now: FIN.now, dueSoonWindowDays: 7)
        #expect(vm.rows.map { $0.id } == ["b", "a", "c"])  // soonest first, undated last
    }

    @Test func flagsDueSoonRows() throws {
        let store = InMemoryInvoiceStore([
            rec("soon", amount: 100, currency: "USD", due: FIN.now.addingTimeInterval(3 * 86_400)),
            rec("later", amount: 100, currency: "USD", due: FIN.now.addingTimeInterval(30 * 86_400))
        ])
        let vm = try FinanceViewModel(store: store, now: FIN.now, dueSoonWindowDays: 7)
        let byId = Dictionary(uniqueKeysWithValues: vm.rows.map { ($0.id, $0) })
        #expect(byId["soon"]?.isDueSoon == true)
        #expect(byId["later"]?.isDueSoon == false)
    }

    @Test func totalsAreGroupedByCurrency() throws {
        let store = InMemoryInvoiceStore([
            rec("a", amount: 100, currency: "USD", due: nil),
            rec("b", amount: 50, currency: "USD", due: nil),
            rec("c", amount: 200, currency: "EUR", due: nil),
            rec("d", amount: nil, currency: "USD", due: nil)   // nil amount ignored in totals
        ])
        let vm = try FinanceViewModel(store: store, now: FIN.now, dueSoonWindowDays: 7)
        #expect(vm.totalsByCurrency["USD"] == 150)
        #expect(vm.totalsByCurrency["EUR"] == 200)
    }

    @Test func emptyStoreYieldsEmptyViewModel() throws {
        let vm = try FinanceViewModel(store: InMemoryInvoiceStore(), now: FIN.now, dueSoonWindowDays: 7)
        #expect(vm.rows.isEmpty)
        #expect(vm.totalsByCurrency.isEmpty)
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter FinanceViewModelTests`
  - **Expected:** compile error — `FinanceViewModel` not in scope.

- [ ] **Implement** `Sources/SenaniEngine/Finance/FinanceViewModel.swift`:

```swift
import Foundation

/// Pure, SwiftUI-free view model for the Finance screen. Loads the invoice store
/// once at init, sorts rows by due date (undated last), flags due-soon rows, and
/// computes per-currency totals. The SwiftUI `FinanceView` binds to this.
public struct FinanceViewModel: Sendable {
    /// One row in the finance list.
    public struct Row: Sendable, Identifiable, Equatable {
        public let id: String
        public let vendor: String?
        public let invoiceNumber: String?
        public let amount: Double?
        public let currency: String?
        public let dueDate: Date?
        public let isDueSoon: Bool
    }

    public let rows: [Row]
    /// Sum of `amount` per currency code (records with nil amount/currency are ignored).
    public let totalsByCurrency: [String: Double]

    public init(store: any InvoiceStore, now: Date, dueSoonWindowDays: Int = 7) throws {
        let window = TimeInterval(dueSoonWindowDays) * 86_400
        let records = try store.all()

        func dueSoon(_ d: Date?) -> Bool {
            guard let d else { return false }
            return d >= now && d <= now.addingTimeInterval(window)
        }

        // Sort: by due date ascending; nil due dates last; tie-break by id.
        let sorted = records.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (l?, r?): return l == r ? lhs.id < rhs.id : l < r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.id < rhs.id
            }
        }

        self.rows = sorted.map { r in
            Row(id: r.id, vendor: r.vendor, invoiceNumber: r.invoiceNumber,
                amount: r.amount, currency: r.currency, dueDate: r.dueDate,
                isDueSoon: dueSoon(r.dueDate))
        }

        var totals: [String: Double] = [:]
        for r in records {
            guard let amount = r.amount, let ccy = r.currency else { continue }
            totals[ccy, default: 0] += amount
        }
        self.totalsByCurrency = totals
    }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter FinanceViewModelTests`
  - **Expected:** all 4 pass.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: FinanceViewModel — pure list/totals/due-soon highlighting for the Finance screen

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9 — Full suite green + public surface check

**Files:** none (verification).

- [ ] **Run the full suite:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test`
  - **Expected:** all new Invoice/Finance suites pass — `InvoiceFixturesSelfTests`, `InvoiceStoreTests`, `SqliteInvoiceStoreTests`, `InvoiceDetectorTests`, `FinanceFieldNormalizerTests`, `InvoiceFieldFillerTests`, `InvoiceFinanceAgentWakesForTests`, `InvoiceFinanceAgentProposalsTests`, `FinanceViewModelTests` — AND every pre-existing suite (Triage, Orchestrator, AgentRegistry, Scheduler, AgentTools, ProcessedOutcome) stays green. Zero failures, strict-concurrency clean.

- [ ] **Confirm public surface** matches this plan's contract:
  - `AgentContext` carries `documentFields: [String: String]` + `invoices: any InvoiceStore` (both additive, defaulted).
  - `InvoiceRecord`, `InvoiceStore`, `NullInvoiceStore`, `InMemoryInvoiceStore`, `SqliteInvoiceStore`.
  - `InvoiceDetector`, `FinanceFieldNormalizer` (+ `InvoiceFields`), `InvoiceFieldFiller`.
  - `InvoiceFinanceAgent` (`id == "invoice-finance"`, `autonomy == .prepare`, labels `Senani/Finance/Invoice` + `Senani/Finance/DueSoon`).
  - `FinanceViewModel` (+ `FinanceViewModel.Row`).

- [ ] **Register the agent (flag to orchestrator owner, do NOT force here):** confirm that adding `InvoiceFinanceAgent()` to the `AgentRegistry` is the orchestrator plan's job (it also must populate `context.documentFields` from `SenaniDocs` and `context.invoices` from the live `SqliteInvoiceStore`). This plan does not edit the registry or `Orchestrator`; it leaves the agent ready to register.

- [ ] **Commit (if any cleanup):**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: full Invoice/Finance suite green; public contract verified

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Scope coverage (brief):**
- `InvoiceFinanceAgent: SenaniEngine.Agent`, co-located in `Packages/SenaniEngine/Sources/SenaniEngine/Agents/` alongside `TriageAgent` and the `Agent`/`AgentContext`/`AgentTools` definitions, matching the established co-location decision. ✅
- `wakesFor`: inbound mail with an invoice/receipt attachment, detected via SenaniDocs field extraction (`context.documentFields` monetary keys) AND subject/body cues ("invoice", "receipt", "amount due", "bill", …). ✅
- Behavior: extract + **normalize** finance fields (vendor, invoice number, amount, currency, due date) from `documentFields`, augmented by `tools.generateJSON` (`InvoiceFieldFiller`) ONLY for fields the extractor missed (non-destructive merge); amounts/dates/currency normalized in `FinanceFieldNormalizer`. ✅
- Reversible labels `Senani/Finance/Invoice` (always) + `Senani/Finance/DueSoon` (due within N days, default 7); both `Action.label` (reversible). ✅
- Persists an `InvoiceRecord` to an additive `invoices` table behind `InvoiceStore` (protocol + `NullInvoiceStore` + `InMemoryInvoiceStore` + GRDB `SqliteInvoiceStore`), wired through the new additive `AgentContext.invoices` field; the exact `AppEnvironment` additive wiring + context accessor is pinned for the app-shell owner. ✅
- Optional **approval-gated** outbound payment-reminder (`Action.reply`, outbound → always queues), default OFF, kept secondary. ✅
- Pure `FinanceViewModel` listing invoices with per-currency totals + due-soon highlighting (no SwiftUI). ✅

**Real-source reconciliations (verified, recorded in the plan):**
1. `SenaniEngine` already EXISTS on disk → no package/contract recreation; only additive files + an additive `AgentContext` edit. ✅
2. `AgentContext` (real `Agent.swift`) has NO `documentFields`/`invoices` → added as defaulted, non-breaking init members so `TriageAgent`/`Orchestrator`/`ctx(...)` keep compiling. ✅
3. `AgentTools.draftReply` maps to `Action.draft` (**reversible**), so the approval-gated reminder is constructed as `Action.reply` directly (outbound → `ActionRouter` always queues, verified `Action.swift`/`Routing.swift`); labels use `tools.proposeLabel` → `Action.label`. ✅
4. `SenaniDocs.ExtractedFields` is a flat `[String: String]` (verified) → reached via `context.documentFields`; agent never runs `DocumentExtractor`. ✅
5. `SenaniInference.TextGenerator.generateJSON` + `JSONSchema.object(properties:required:)` verified; the in-repo `actor FakeTextGenerator` (TestSupport.swift, FIFO responses + `recordedPrompts`) is reused — no new fake. ✅
6. Frozen `SenaniMigrations` (v1–v4) cannot be edited → `SqliteInvoiceStore` creates its own `invoices` table additively via `CREATE TABLE IF NOT EXISTS` over `database.queue` (GRDB usage matches `RuleStore`); idempotent across multiple stores on one DB. ✅
7. `InvoiceStore` methods are synchronous `throws` (matching frozen `SenaniStore` stores) — agent/tests call without `await`. ✅

**Tests (pure, no MLX/Gmail/network/liteparse):**
- Parsed invoice doc → correct extracted+normalized fields → `InvoiceRecord` persisted to in-memory store + `Senani/Finance/Invoice` label. ✅
- Due date within window → `Senani/Finance/DueSoon` label; outside window → no DueSoon label (window injected for determinism against the fixed `FIN.now`). ✅
- Non-invoice attachment/mail → agent ignores (no wake, no store write, no Action). ✅
- `generateJSON` fallback when extractor fields are sparse (in-repo `FakeTextGenerator` returns canned JSON; extractor-provided fields never overwritten; malformed JSON leaves fields unchanged). ✅
- GRDB `SqliteInvoiceStore` round-trips over `SenaniDatabase.inMemory()` incl. nulls + `dueSoon` window + idempotent table creation. ✅
- `FinanceViewModel`: sort (undated last), due-soon flags, per-currency totals, empty store. ✅

**Conventions (§4):** agent is pure (only the injected `tools.generateJSON` I/O + `context.invoices` write through context); one safety path (reminder is outbound → `ActionRouter` queues; labels reversible auto-apply under `.prepare`); reads through `AgentContext`, never constructs a store/backend; additive store owns its own table without touching frozen schema; macOS 14 / Swift 6.2 / strict concurrency / Swift Testing; TDD bite-sized steps with COMPLETE code, run-to-fail/run-to-pass commands + expected output, frequent commits. ✅

**Open items flagged to the human:**
- Additive `AgentContext.documentFields` (shared with Proposal-Tracker) + `AgentContext.invoices` — the Orchestrator must populate them (from `SenaniDocs.DocumentPipeline`/`DocumentExtractor` and the live `SqliteInvoiceStore`) and register `InvoiceFinanceAgent()`.
- `AppEnvironment` (app-shell plan) must add the `invoices: any InvoiceStore` stored property (live `SqliteInvoiceStore(database:)`, preview `InMemoryInvoiceStore()`) and pass `invoices:`/`documentFields:` when constructing each agent's `AgentContext` — pinned above.
- The additive `invoices` table is created by `SqliteInvoiceStore` via `CREATE TABLE IF NOT EXISTS`; if the store-bootstrap plan later promotes it to a real `v5` migration, the guard makes that a no-op (record the deviation).
- The `FinanceView` SwiftUI screen + its gold-glass styling is a separate Phase-3 UI plan binding to `FinanceViewModel`.
- The payment-reminder reply body is a deterministic template (not voice-conditioned) to keep the agent's only model call the sparse-field fill; route through Reply Drafter / a voice seam if a voice-conditioned reminder is later wanted. Reminders default OFF.
- Confirm GRDB is reachable from `SenaniEngine` (transitively via `SenaniStore`); if the compiler requires it, add `GRDB` to `SenaniEngine`'s target dependencies (already a dep of `SenaniStore`) and record it.
