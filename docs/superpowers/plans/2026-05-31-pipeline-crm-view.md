# Pipeline / CRM Store + View Implementation Plan (Phase 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Senani's **lightweight pipeline / CRM** (ROADMAP.md Phase 3 → "Lightweight pipeline / CRM view") in two layers, both owned by this plan because this plan is **authoritative for the `PipelineStore` contract** the three Phase-3 sales agents (Lead Qualifier, Proposal Tracker, Follow-up) code against:

1. **The `PipelineStore` contract + two implementations** — the pinned `DealStage` / `Deal` / `PipelineStore` types, an `InMemoryPipelineStore` (tests/preview), and a `SqlitePipelineStore` backed by the **shared** `SenaniDatabase` via an **additive app-tier `deals` table** created idempotently on the shared `DatabaseQueue` (the frozen `SenaniStore` package is NOT edited). The contract is wired into `SenaniEngine.AgentContext.pipeline` so agents can write `Deal`s.
2. **A gold-glass `PipelineView`** showing deals grouped by `DealStage` in canonical order (a simple kanban/list of glass cards). Each card shows contact/company, stage, score, value, and last touch; tapping a card opens the source thread. A **pure `PipelineViewModel`** owns the grouping/sorting so it is unit-testable with no SwiftUI.

The store + contract live in `Packages/SenaniEngine` (where `AgentContext` already lives and where the agents are co-located, so the CRM seam needs no new package). The view + view model live in the `SenaniApp` executable target alongside the existing gold-glass design system. **No MLX, no Gmail, no network anywhere in this plan.**

**Architecture:**

- **Why `SenaniEngine` owns `PipelineStore`.** `SenaniEngine.AgentContext` is the agent's injected world; the three sales agents reach the CRM through `context.pipeline` (a *store write*, not an `ActionRouter`-routable `Action`). The Lead Qualifier / Proposal Tracker / Follow-up plans each say `PipelineStore`/`Deal`/`DealStage` are **owned by this plan** and that they bootstrap signature-identical copies only until this plan lands. So this plan defines the **single canonical** `DealStage` / `Deal` / `PipelineStore` in `SenaniEngine`, and adds `AgentContext.pipeline` (additively, defaulted) so existing `SenaniEngine` code (Triage agent, Orchestrator, Scheduler, their tests) keeps compiling untouched.
- **Why the additive table lives on the shared `SenaniDatabase.queue`, not in `SenaniStore`'s migrator.** Verified from source: `SenaniStore.SenaniMigrations.migrator()` is **`internal`** (`Packages/SenaniStore/Sources/SenaniStore/Migrations.swift` — `enum SenaniMigrations` with no `public`), so an app-tier package **cannot register a migration into it** without editing the frozen package. However `SenaniDatabase.queue: DatabaseQueue` **is `public`** (`SenaniDatabase.swift`). The standard additive pattern is therefore: `SqlitePipelineStore.init(database:)` runs an **idempotent `CREATE TABLE IF NOT EXISTS deals (...)`** on `database.queue.write` at construction. This adds the `deals` table to the **shared** `senani.sqlite` without touching GRDB's migration ledger (`grdb_migrations`) — so the frozen migrator never sees an unknown migration and never errors. We do NOT need a separate `pipeline.sqlite` file; the shared DB is correct (the CRM is part of the user's single local store per ARCHITECTURE.md "Local store: SQLite ... pipeline/CRM"). This decision is recorded for the human in Self-Review.
- **Pure view model.** `PipelineViewModel` is a plain `struct` that takes `[Deal]` and produces `[StageColumn]` (one per `DealStage` in canonical `allCases` order: `new, qualified, proposal, negotiation, won, lost`), each column's deals sorted by `lastTouch` descending then `id`. It performs no I/O — the view (or a preview/test) loads `Deal`s from a `PipelineStore` and hands them in. This keeps grouping/sorting unit-testable without SwiftUI or a database.
- **The view.** `PipelineView` is a SwiftUI view reusing the existing gold-glass design system (`GlassCard`, `.goldGlass()`, `.senaniGold`, `StatusBadge` in `SenaniApp/Sources/SenaniApp/UI/`). It renders the columns horizontally (kanban) with a `DealCard` per deal; tapping a card invokes an `onOpenThread: (String) -> Void` closure with the deal's `sourceMessageId` (the seam the host wires to open the source thread). A `#Preview` drives it from seeded in-memory deals.
- **Preview/UI-test graph.** The brief asks for a test "over `AppEnvironment.preview()` with seeded deals." `AppEnvironment` is pinned in APP-PLANS-RECONCILIATION §3 but **does not exist yet** (the scaffold currently injects `@Observable AppState` — verified `SenaniApp/Sources/SenaniApp/SenaniApp.swift`). To satisfy the brief without colliding with the app-shell plan that owns the full `AppEnvironment`, this plan adds a **minimal, additive `AppEnvironment` shim** in `SenaniApp` exposing exactly `pipeline: any PipelineStore` + `static func live() throws` + `static func preview()` (seeded). If the app-shell plan has **already** shipped `AppEnvironment`, this plan instead **adds only the `pipeline` property** to it (defaulted/seeded the same way) and skips the shim — FLAGGED in Self-Review. Either way the pipeline UI reads its store through this `AppEnvironment.pipeline`, per §4 ("no screen constructs a store itself").

**Tech Stack:** Swift 6 (strict concurrency; `swift-tools-version: 6.0` for `SenaniEngine`, `5.9` for the `SenaniApp` executable — matching each on-disk manifest), Swift Package Manager, Swift Testing (`import Testing`). macOS 14+. `SenaniEngine` depends on the frozen `SenaniRules` / `SenaniStore` / `SenaniInference` (already wired); `SqlitePipelineStore` uses `GRDB` transitively via `SenaniStore` (re-exported through the `SenaniDatabase.queue`). The `SenaniApp` target gains a dependency on `SenaniEngine`.

**Working directory:** Engine `swift` commands run from `/Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine`. App `swift` commands run from `/Users/vishalkumar/Downloads/qmail/SenaniApp`. Git commands run from the repo root `/Users/vishalkumar/Downloads/qmail` (the repo is the working tree; commit explicit paths).

**Out of scope (separate plans):** the three sales agents themselves (Lead Qualifier / Proposal Tracker / Follow-up — they consume this contract); the Orchestrator wiring that pre-populates `AgentContext.pipeline` with the live `SqlitePipelineStore` (orchestrator plan; this plan only makes the field available + defaulted); the full `AppEnvironment` composition root + the `AppState→AppEnvironment` migration (app-shell plan); editing the real source-thread navigation target (this plan exposes the `onOpenThread` closure seam and wires it to the existing `NavigationItem.inbox`/selection only as far as the scaffold allows); Gmail/MLX/vector retrieval.

---

## Cross-package assumptions (verified from source — state to the human before coding)

This plan codes to the exact signatures below. If a sibling differs at build time, adapt the app-tier adapter/view — never edit a frozen package.

### `SenaniEngine` (app-tier, EXISTS — verified) — this plan EXTENDS it
- `Packages/SenaniEngine/Package.swift`: `swift-tools-version: 6.0`, macOS 14, deps `../SenaniRules`, `../SenaniStore`, `../SenaniInference`. (No `swiftLanguageModes` line — leave as is.)
- `Sources/SenaniEngine/Agent.swift` (verified) defines BOTH `AgentContext` and `Agent`:
```swift
public struct AgentContext: Sendable {
    public let account: String
    public let thread: [Message]
    public let rules: [Rule]
    public let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit]
    public let now: Date
    public init(account:thread:rules:retrieve:now:)
}
public protocol Agent: Sendable {
    var id: String { get }; var autonomy: Autonomy { get }
    func wakesFor(_ message: Message, context: AgentContext) -> Bool
    func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action]
}
```
- `Sources/SenaniEngine/AgentTools.swift` (verified): `public struct AgentTools` with `init(generator: any TextGenerator)` and `proposeLabel/draftReply/archive/markRead/generateJSON`. **Unchanged by this plan.**
- `Orchestrator.swift`, `Scheduler.swift`, `Agents/TriageAgent.swift`, and `Tests/SenaniEngineTests/TestSupport.swift` construct `AgentContext(account:thread:rules:retrieve:now:)` with **no** `pipeline`. **Adding `pipeline` as a defaulted init parameter keeps every one of these compiling** — verify with the full engine test run in Task 4.
- `Tests/.../TestSupport.swift` (verified) already provides `FakeTextGenerator` (an `actor`), `msg(...)`, `tools(_:)`, `ctx(now:)`, `EngineHarness` (an in-memory `SenaniDatabase`/`MessageStore`/...). This plan reuses them.

### `SenaniStore` (frozen — do NOT edit; verified)
- `SenaniDatabase.swift`: `public final class SenaniDatabase: @unchecked Sendable { public let queue: DatabaseQueue; public static func inMemory() throws -> SenaniDatabase; public static func file(at: String) throws -> SenaniDatabase }`. Both factories run `SenaniMigrations.migrator().migrate(queue)`.
- `Migrations.swift`: `enum SenaniMigrations` (internal) registers `v1_core … v4_messages`. **There is NO `deals` table and the migrator is not public** → this plan adds `deals` via an idempotent `CREATE TABLE IF NOT EXISTS` on `database.queue`, NOT via the migrator.
- `MessageStore.swift`: the canonical raw-SQL-over-GRDB pattern this plan mirrors — `database.queue.write { db in try db.execute(sql:..., arguments:[...]) }` and `database.queue.read { db in try Row.fetchAll(db, sql:..., arguments:...) }`. GRDB types (`Database`, `Row`, `StatementArguments`) are reachable by `import GRDB` in the `SenaniEngine` target (GRDB is a transitive product of `SenaniStore`; if the symbol is not visible, add `import GRDB` — it resolves through the `SenaniStore` dependency).

> **GRDB import note (verify at build):** `SenaniStore`'s `MessageStore` does `import GRDB` directly. `SenaniEngine` already depends on `SenaniStore`. If `import GRDB` does not resolve transitively in `SenaniEngine` (SPM does not always re-export transitive deps), add `GRDB` explicitly to `SenaniEngine/Package.swift` as a dependency on the same package `SenaniStore` uses. Task 2 includes a build check that catches this; the fallback is recorded there.

### `SenaniRules` (frozen — verified): `Message` (`id, from, to, subject, body, hasAttachment, listUnsubscribeHeader, labels, threadId, date, isFromUser`, computed `senderDomain`), `Action`, `Autonomy`, `Rule`. `VectorHit` comes from `SenaniStore`.

### `SenaniApp` (executable scaffold — verified)
- `Package.swift`: `swift-tools-version: 5.9`, macOS 14, executable target `SenaniApp` depending on the 9 engine packages **but NOT `SenaniEngine`** → this plan ADDS `../Packages/SenaniEngine` to both `dependencies` and the target's `dependencies`.
- `SenaniApp.swift`: injects `@Observable AppState` (NOT `AppEnvironment`). `NavigationItem` already has a `.crm` case ("CRM / Pipeline"); `MainNavigationView.swift`'s `ContentView` currently shows a placeholder for every non-`.settings` item.
- Design system (verified `UI/DesignSystem.swift`, `UI/Theme.swift`): `GlassCard<Content>`, `GoldButton`, `StatusBadge(text:color:)`, `WordmarkHeader`, `.glassCard()`, `.goldGlass()`, `Color.senaniGold`, `Color.senaniObsidian`. This plan reuses these (it does NOT introduce the pinned `DesignSystem.GlassPanel`/`Gold` names — those are the design-system plan's; flagged).

### `PipelineStore` contract this plan SHIPS (authoritative — the agents code to this exact shape)
```swift
public enum DealStage: String, Sendable, CaseIterable { case new, qualified, proposal, negotiation, won, lost }
public struct Deal: Sendable, Identifiable, Codable {
    public var id: String; public var contactEmail: String; public var company: String?
    public var stage: DealStage; public var score: Int?; public var value: Double?
    public var lastTouch: Date; public var sourceMessageId: String?
}
public protocol PipelineStore: Sendable {
    func upsert(_ deal: Deal) throws
    func fetch(id: String) throws -> Deal?
    func byContact(_ email: String) throws -> Deal?
    func all() throws -> [Deal]
    func byStage(_ stage: DealStage) throws -> [Deal]
}
```
> **Reconciliation with the Follow-up plan.** The Follow-up plan's *draft* pins a divergent shape (`DealStage` cases `lead/qualified/proposalSent/...`, a `Deal` with `contact`/`threadId`/`isOpen`, and `PipelineReading`/`PipelineTouching`). **This plan is authoritative** (per the Lead-Qualifier + Proposal-Tracker plans, which match THIS shape exactly). The Follow-up agent must adapt to this contract (its `Deal.contact` → `contactEmail`; "open" = `stage != .won && stage != .lost`; touch = `upsert` a deal with updated `lastTouch`). This divergence is FLAGGED in Self-Review for the human/Follow-up owner to reconcile; this plan does NOT ship the Follow-up variant.

---

## File Structure

```
Packages/SenaniEngine/
  Package.swift                                  # EDIT (Task 2, only if GRDB import fails): add GRDB dep
  Sources/SenaniEngine/
    Agent.swift                                  # EDIT (Task 3): add AgentContext.pipeline (defaulted)
    Pipeline/
      PipelineStore.swift                        # NEW (Task 1): DealStage + Deal + PipelineStore + InMemoryPipelineStore + NullPipelineStore
      SqlitePipelineStore.swift                  # NEW (Task 2): SqlitePipelineStore over shared SenaniDatabase.queue (additive `deals` table)
      PipelineViewModel.swift                    # NEW (Task 5): pure grouping/sorting (StageColumn, columns(from:))
  Tests/SenaniEngineTests/
    Pipeline/
      InMemoryPipelineStoreTests.swift           # NEW (Task 1)
      SqlitePipelineStoreTests.swift             # NEW (Task 2): CRUD round-trips on a temp file db + survives reopen
      AgentContextPipelineTests.swift            # NEW (Task 3): AgentContext.pipeline default + injection
      PipelineViewModelTests.swift               # NEW (Task 5): canonical-order grouping + sort

SenaniApp/
  Package.swift                                  # EDIT (Task 6): add SenaniEngine dependency
  Sources/SenaniApp/
    AppEnvironment.swift                         # NEW (Task 6): minimal shim exposing pipeline + live()/preview() (or EDIT if app-shell already shipped it)
    UI/
      PipelineView.swift                         # NEW (Task 7): gold-glass kanban + DealCard + #Preview
  # (MainNavigationView.swift ContentView gets a `.crm` branch wired to PipelineView — Task 7)
```

One responsibility per file. `PipelineStore.swift` is the pure contract + in-memory impls; `SqlitePipelineStore.swift` is the only file touching SQL; `PipelineViewModel.swift` is pure grouping; `PipelineView.swift` is the only SwiftUI file.

---

## Task 1 — `PipelineStore` contract + `InMemoryPipelineStore` (the authoritative seam)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Pipeline/PipelineStore.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Pipeline/InMemoryPipelineStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/Pipeline/InMemoryPipelineStoreTests.swift`:

```swift
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
        #expect(DealStage.allCases == [.new, .qualified, .proposal, .negotiation, .won, .lost])
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
        var updated = deal("d1", contact: "a@x.com", stage: .won, score: 99)
        try store.upsert(updated)
        #expect(try store.all().count == 1)
        #expect(try store.fetch(id: "d1")?.stage == .won)
        #expect(try store.fetch(id: "d1")?.score == 99)
        _ = updated // silence unused-mutation warning paths
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
        #expect(try store.byStage(.new).isEmpty)
    }
}
```

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter InMemoryPipelineStoreTests
```

Expected: failure — `DealStage` / `Deal` / `PipelineStore` / `InMemoryPipelineStore` / `NullPipelineStore` not in scope.

- [ ] **Step 3: Implement the contract + in-memory impls**

Create `Packages/SenaniEngine/Sources/SenaniEngine/Pipeline/PipelineStore.swift`:

```swift
import Foundation

/// The sales pipeline stages a Deal moves through, in canonical left→right order.
/// RawValue strings are the persisted form (the SQLite store and the CRM view both
/// rely on these stable strings); `allCases` defines column order in the view.
public enum DealStage: String, Sendable, CaseIterable, Codable {
    case new, qualified, proposal, negotiation, won, lost
}

/// One opportunity in the pipeline. Keyed by `id`; sales agents use the contact email as
/// the id (one open deal per contact) so re-qualifying the same sender updates one row.
public struct Deal: Sendable, Identifiable, Codable {
    public var id: String
    public var contactEmail: String
    public var company: String?
    public var stage: DealStage
    public var score: Int?
    public var value: Double?
    public var lastTouch: Date
    public var sourceMessageId: String?

    public init(id: String, contactEmail: String, company: String?, stage: DealStage,
                score: Int?, value: Double?, lastTouch: Date, sourceMessageId: String?) {
        self.id = id
        self.contactEmail = contactEmail
        self.company = company
        self.stage = stage
        self.score = score
        self.value = value
        self.lastTouch = lastTouch
        self.sourceMessageId = sourceMessageId
    }
}

/// Persistence seam for the CRM pipeline. The live implementation is `SqlitePipelineStore`
/// (over the shared SenaniDatabase); tests/preview use `InMemoryPipelineStore`.
/// Synchronous `throws` (not async) — callers may invoke from sync or async contexts.
public protocol PipelineStore: Sendable {
    func upsert(_ deal: Deal) throws
    func fetch(id: String) throws -> Deal?
    func byContact(_ email: String) throws -> Deal?
    func all() throws -> [Deal]
    func byStage(_ stage: DealStage) throws -> [Deal]
}

/// In-memory PipelineStore for tests, SwiftUI previews, and any agent that needs a real store
/// without a database. Keyed by `Deal.id`; `byContact` matches `contactEmail` case-insensitively.
public final class InMemoryPipelineStore: PipelineStore, @unchecked Sendable {
    private let lock = NSLock()
    private var deals: [String: Deal] = [:]

    public init(_ seed: [Deal] = []) {
        for d in seed { deals[d.id] = d }
    }

    public func upsert(_ deal: Deal) throws {
        lock.lock(); defer { lock.unlock() }
        deals[deal.id] = deal
    }
    public func fetch(id: String) throws -> Deal? {
        lock.lock(); defer { lock.unlock() }
        return deals[id]
    }
    public func byContact(_ email: String) throws -> Deal? {
        lock.lock(); defer { lock.unlock() }
        return deals.values.first { $0.contactEmail.caseInsensitiveCompare(email) == .orderedSame }
    }
    public func all() throws -> [Deal] {
        lock.lock(); defer { lock.unlock() }
        return Array(deals.values)
    }
    public func byStage(_ stage: DealStage) throws -> [Deal] {
        lock.lock(); defer { lock.unlock() }
        return deals.values.filter { $0.stage == stage }
    }
}

/// No-op default so an `AgentContext` can be constructed without a real pipeline (agents that
/// ignore the CRM, and the existing engine tests). Every read returns empty/nil; `upsert` discards.
public struct NullPipelineStore: PipelineStore {
    public init() {}
    public func upsert(_ deal: Deal) throws {}
    public func fetch(id: String) throws -> Deal? { nil }
    public func byContact(_ email: String) throws -> Deal? { nil }
    public func all() throws -> [Deal] { [] }
    public func byStage(_ stage: DealStage) throws -> [Deal] { [] }
}
```

- [ ] **Step 4: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter InMemoryPipelineStoreTests
```

Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```
cd /Users/vishalkumar/Downloads/qmail && git add Packages/SenaniEngine/Sources/SenaniEngine/Pipeline/PipelineStore.swift Packages/SenaniEngine/Tests/SenaniEngineTests/Pipeline/InMemoryPipelineStoreTests.swift && git commit -m "$(cat <<'EOF'
SenaniEngine: PipelineStore/Deal/DealStage contract + InMemory + Null impls

Authoritative CRM seam the Phase-3 sales agents code against (canonical DealStage
order new→lost). InMemoryPipelineStore for tests/preview; NullPipelineStore default.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

> If on the repo's default branch, create a branch first (`git switch -c pipeline-crm-view`). Use the trailer on EVERY commit.

---

## Task 2 — `SqlitePipelineStore` over the shared `SenaniDatabase` (additive `deals` table)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Pipeline/SqlitePipelineStore.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Pipeline/SqlitePipelineStoreTests.swift`
- Possibly edit: `Packages/SenaniEngine/Package.swift` (only if `import GRDB` does not resolve)

The store creates the `deals` table idempotently on construction and uses the same raw-SQL-over-GRDB pattern as `SenaniStore.MessageStore`. `byContact` matches case-insensitively (`COLLATE NOCASE`).

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/Pipeline/SqlitePipelineStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
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
```

(The `Message` initializer used here is the frozen `SenaniRules.Message` — `import SenaniRules` is already in scope via `@testable import SenaniEngine`; if the test target complains, add `import SenaniRules`.)

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter SqlitePipelineStoreTests
```

Expected: failure — `SqlitePipelineStore` not in scope.

- [ ] **Step 3: Implement `SqlitePipelineStore`**

Create `Packages/SenaniEngine/Sources/SenaniEngine/Pipeline/SqlitePipelineStore.swift`:

```swift
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
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_deals_contact ON deals(contactEmail)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_deals_stage ON deals(stage)")
        }
    }

    public func upsert(_ deal: Deal) throws {
        try database.queue.write { db in
            try db.execute(sql: """
            INSERT INTO deals
              (id, contactEmail, company, stage, score, value, lastTouch, sourceMessageId)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              contactEmail = excluded.contactEmail,
              company = excluded.company,
              stage = excluded.stage,
              score = excluded.score,
              value = excluded.value,
              lastTouch = excluded.lastTouch,
              sourceMessageId = excluded.sourceMessageId
            """, arguments: [
                deal.id, deal.contactEmail, deal.company, deal.stage.rawValue,
                deal.score, deal.value, deal.lastTouch.timeIntervalSince1970, deal.sourceMessageId,
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

    private static func deal(from row: Row) -> Deal {
        let stageRaw: String = row["stage"]
        return Deal(
            id: row["id"],
            contactEmail: row["contactEmail"],
            company: row["company"],
            stage: DealStage(rawValue: stageRaw) ?? .new,
            score: row["score"],
            value: row["value"],
            lastTouch: Date(timeIntervalSince1970: row["lastTouch"]),
            sourceMessageId: row["sourceMessageId"]
        )
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter SqlitePipelineStoreTests
```

Expected: all 4 tests pass.

> **If Step 4 fails to COMPILE with `no such module 'GRDB'`:** SPM did not re-export the transitive dependency. Add GRDB to `SenaniEngine/Package.swift`. Determine the GRDB package URL/version `SenaniStore` uses:
> ```
> cat /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Package.swift
> ```
> Then mirror that exact `.package(url:..., from:...)` (or `.package(path:...)`) line into `SenaniEngine/Package.swift`'s `dependencies`, and add `.product(name: "GRDB", package: "GRDB.swift")` (use the real product/package names from SenaniStore's manifest) to the `SenaniEngine` target. Re-run Step 4. Commit the manifest edit in Step 5.

- [ ] **Step 5: Commit**

```
cd /Users/vishalkumar/Downloads/qmail && git add Packages/SenaniEngine/Sources/SenaniEngine/Pipeline/SqlitePipelineStore.swift Packages/SenaniEngine/Tests/SenaniEngineTests/Pipeline/SqlitePipelineStoreTests.swift Packages/SenaniEngine/Package.swift && git commit -m "$(cat <<'EOF'
SenaniEngine: SqlitePipelineStore over shared SenaniDatabase (additive deals table)

Adds the `deals` table idempotently via CREATE TABLE IF NOT EXISTS on the public
queue — frozen SenaniStore migrator is untouched. CRUD round-trips + survives reopen.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

(`git add Package.swift` is a no-op if it was not edited — harmless.)

---

## Task 3 — Wire `PipelineStore` into `AgentContext.pipeline` (additive, defaulted)

**Files:**
- Edit: `Packages/SenaniEngine/Sources/SenaniEngine/Agent.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Pipeline/AgentContextPipelineTests.swift`

Adding `pipeline` as a defaulted init parameter (`= NullPipelineStore()`) means every existing `AgentContext(account:thread:rules:retrieve:now:)` call site (Orchestrator, Scheduler, TriageAgent, TestSupport's `ctx`) keeps compiling unchanged. The Orchestrator plan later injects the live `SqlitePipelineStore`.

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/Pipeline/AgentContextPipelineTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine

@Suite struct AgentContextPipelineTests {
    @Test func defaultPipelineIsANoOp() throws {
        // The existing ctx() helper (no pipeline arg) must still build and default to a no-op store.
        let context = ctx()
        try context.pipeline.upsert(
            Deal(id: "d1", contactEmail: "a@x.com", company: nil, stage: .new,
                 score: nil, value: nil, lastTouch: Date(timeIntervalSince1970: 0),
                 sourceMessageId: nil))
        #expect(try context.pipeline.all().isEmpty)   // NullPipelineStore default
    }

    @Test func injectedPipelineIsReadableThroughContext() throws {
        let store = InMemoryPipelineStore([
            Deal(id: "d1", contactEmail: "a@x.com", company: "Acme", stage: .qualified,
                 score: 70, value: nil, lastTouch: Date(timeIntervalSince1970: 1), sourceMessageId: nil)
        ])
        let context = AgentContext(account: "me@x.com", thread: [], rules: [],
                                   retrieve: { _, _ in [] },
                                   now: Date(timeIntervalSince1970: 1_700_000_000),
                                   pipeline: store)
        #expect(try context.pipeline.byContact("a@x.com")?.score == 70)
    }
}
```

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter AgentContextPipelineTests
```

Expected: failure — `AgentContext` has no member `pipeline` and no `pipeline:` init parameter.

- [ ] **Step 3: Add `pipeline` to `AgentContext`**

Edit `Packages/SenaniEngine/Sources/SenaniEngine/Agent.swift`. Replace the `AgentContext` struct (the `Agent` protocol below it stays unchanged):

```swift
public struct AgentContext: Sendable {
    public let account: String
    public let thread: [Message]
    public let rules: [Rule]
    public let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit]
    public let now: Date
    /// The CRM pipeline seam sales agents write Deals to. The Deal upsert is a store write,
    /// not an `ActionRouter`-routable Action, so it lives on the agent's injected world here
    /// (not on the pure `AgentTools`). Defaulted to a no-op so existing call sites and agents
    /// that ignore the pipeline keep compiling; the Orchestrator injects the live store.
    public let pipeline: any PipelineStore

    public init(account: String,
                thread: [Message],
                rules: [Rule],
                retrieve: @escaping @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit],
                now: Date,
                pipeline: any PipelineStore = NullPipelineStore()) {
        self.account = account
        self.thread = thread
        self.rules = rules
        self.retrieve = retrieve
        self.now = now
        self.pipeline = pipeline
    }
}
```

- [ ] **Step 4: Run to pass + confirm NOTHING else broke**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test
```

Expected: `AgentContextPipelineTests` passes AND every pre-existing engine test (Triage, Orchestrator, Scheduler, AgentRegistry, AgentTools, ProcessedOutcome, TestSupport self-test) still passes — the defaulted `pipeline` parameter keeps all existing `AgentContext(...)` constructions compiling.

- [ ] **Step 5: Commit**

```
cd /Users/vishalkumar/Downloads/qmail && git add Packages/SenaniEngine/Sources/SenaniEngine/Agent.swift Packages/SenaniEngine/Tests/SenaniEngineTests/Pipeline/AgentContextPipelineTests.swift && git commit -m "$(cat <<'EOF'
SenaniEngine: add AgentContext.pipeline seam (additive, defaulted to NullPipelineStore)

Sales agents reach the CRM through context.pipeline; defaulted so existing engine
call sites and tests compile unchanged. Orchestrator injects the live store.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4 — Record the contract in APP-PLANS-RECONCILIATION §3

**Files:**
- Edit: `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md`

The reconciliation doc's §3 `AgentContext` already lists a commented `pipeline: (any PipelineStore)?` and says "PipelineStore/Deal/DealStage are pinned by the pipeline-crm-view plan". This task makes the pin concrete now that this plan owns it.

- [ ] **Step 1: Add the canonical `PipelineStore` block to §3**

In `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md`, immediately after the `AgentContext` struct in §3 (where the `// ⚠ PipelineStore/Deal/DealStage are pinned by the pipeline-crm-view plan` note sits), insert:

```swift
// PINNED by the pipeline-crm-view plan (authoritative; ships SqlitePipelineStore + InMemoryPipelineStore):
public enum DealStage: String, Sendable, CaseIterable { case new, qualified, proposal, negotiation, won, lost }
public struct Deal: Sendable, Identifiable, Codable {
    public var id: String; public var contactEmail: String; public var company: String?
    public var stage: DealStage; public var score: Int?; public var value: Double?
    public var lastTouch: Date; public var sourceMessageId: String?
}
public protocol PipelineStore: Sendable {
    func upsert(_ deal: Deal) throws; func fetch(id: String) throws -> Deal?
    func byContact(_ email: String) throws -> Deal?; func all() throws -> [Deal]
    func byStage(_ stage: DealStage) throws -> [Deal]
}
// Lives in SenaniEngine (Pipeline/). AgentContext.pipeline is `any PipelineStore` (non-optional,
// defaulted to NullPipelineStore). SqlitePipelineStore adds an additive `deals` table to the SHARED
// SenaniDatabase via CREATE TABLE IF NOT EXISTS (SenaniStore migrator is internal, so not edited).
// NOTE: the Follow-up agent plan's draft pins a DIVERGENT DealStage/Deal — it must adapt to THIS shape.
```

Also change the `AgentContext.pipeline` line in §3 from `public let pipeline: (any PipelineStore)?` (nil pre-Phase-3) to `public let pipeline: any PipelineStore   // defaulted to NullPipelineStore; live store injected by the Orchestrator`.

- [ ] **Step 2: Commit**

```
cd /Users/vishalkumar/Downloads/qmail && git add docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md && git commit -m "$(cat <<'EOF'
docs: pin canonical PipelineStore/Deal/DealStage contract in APP-PLANS §3

Records the pipeline-crm-view plan's authoritative CRM seam + the additive-table
decision; flags the Follow-up plan's divergent draft for reconciliation.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5 — Pure `PipelineViewModel` (grouping + canonical-order sorting)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Pipeline/PipelineViewModel.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Pipeline/PipelineViewModelTests.swift`

The view model lives in `SenaniEngine` (no SwiftUI dependency — pure value logic), so it is unit-tested in the engine test target. It groups `[Deal]` into `[StageColumn]`, one column per `DealStage` in `allCases` order, each column's deals sorted by `lastTouch` descending then `id` ascending. Columns are emitted for ALL stages (empty columns included) so the kanban always shows every lane.

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/Pipeline/PipelineViewModelTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine

@Suite struct PipelineViewModelTests {
    private func deal(_ id: String, stage: DealStage, touch: TimeInterval) -> Deal {
        Deal(id: id, contactEmail: "\(id)@x.com", company: nil, stage: stage, score: nil,
             value: nil, lastTouch: Date(timeIntervalSince1970: touch), sourceMessageId: nil)
    }

    @Test func emitsAllSixStagesInCanonicalOrderEvenWhenEmpty() {
        let columns = PipelineViewModel.columns(from: [])
        #expect(columns.map(\.stage) == [.new, .qualified, .proposal, .negotiation, .won, .lost])
        #expect(columns.allSatisfy { $0.deals.isEmpty })
    }

    @Test func groupsDealsIntoTheirStageColumns() {
        let deals = [
            deal("a", stage: .qualified, touch: 10),
            deal("b", stage: .proposal, touch: 20),
            deal("c", stage: .qualified, touch: 30),
        ]
        let columns = PipelineViewModel.columns(from: deals)
        let qualified = columns.first { $0.stage == .qualified }!
        let proposal = columns.first { $0.stage == .proposal }!
        #expect(qualified.deals.map(\.id) == ["c", "a"])   // newer lastTouch first
        #expect(proposal.deals.map(\.id) == ["b"])
        #expect(columns.first { $0.stage == .won }!.deals.isEmpty)
    }

    @Test func sortsByLastTouchDescThenIdAsc() {
        let deals = [
            deal("z", stage: .new, touch: 100),
            deal("a", stage: .new, touch: 100),   // tie on lastTouch → id ascending
            deal("m", stage: .new, touch: 200),
        ]
        let column = PipelineViewModel.columns(from: deals).first { $0.stage == .new }!
        #expect(column.deals.map(\.id) == ["m", "a", "z"])
    }

    @Test func columnCountReflectsDealsInThatStage() {
        let deals = [deal("a", stage: .won, touch: 1), deal("b", stage: .won, touch: 2)]
        let columns = PipelineViewModel.columns(from: deals)
        #expect(columns.first { $0.stage == .won }!.deals.count == 2)
        #expect(columns.first { $0.stage == .lost }!.deals.count == 0)
    }
}
```

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter PipelineViewModelTests
```

Expected: failure — `PipelineViewModel` / `StageColumn` not in scope.

- [ ] **Step 3: Implement the view model**

Create `Packages/SenaniEngine/Sources/SenaniEngine/Pipeline/PipelineViewModel.swift`:

```swift
import Foundation

/// One kanban lane: a stage and the deals currently in it (already sorted for display).
public struct StageColumn: Sendable, Identifiable {
    public var stage: DealStage
    public var deals: [Deal]
    public var id: String { stage.rawValue }
    public init(stage: DealStage, deals: [Deal]) {
        self.stage = stage
        self.deals = deals
    }
}

/// Pure grouping/sorting for the Pipeline view — no SwiftUI, no I/O. The view loads `[Deal]`
/// from a `PipelineStore` and hands them here; this returns one column per stage in canonical
/// order (every stage present, even empty), each column sorted by lastTouch desc then id asc.
public enum PipelineViewModel {
    public static func columns(from deals: [Deal]) -> [StageColumn] {
        let grouped = Dictionary(grouping: deals, by: \.stage)
        return DealStage.allCases.map { stage in
            let sorted = (grouped[stage] ?? []).sorted { lhs, rhs in
                if lhs.lastTouch != rhs.lastTouch { return lhs.lastTouch > rhs.lastTouch }
                return lhs.id < rhs.id
            }
            return StageColumn(stage: stage, deals: sorted)
        }
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter PipelineViewModelTests
```

Expected: all 4 tests pass.

- [ ] **Step 5: Full engine suite green**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test
```

Expected: ALL engine tests pass (Pipeline tests + every pre-existing test).

- [ ] **Step 6: Commit**

```
cd /Users/vishalkumar/Downloads/qmail && git add Packages/SenaniEngine/Sources/SenaniEngine/Pipeline/PipelineViewModel.swift Packages/SenaniEngine/Tests/SenaniEngineTests/Pipeline/PipelineViewModelTests.swift && git commit -m "$(cat <<'EOF'
SenaniEngine: pure PipelineViewModel — group deals into canonical-order stage columns

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6 — Add `SenaniEngine` to `SenaniApp` + minimal `AppEnvironment.pipeline`

**Files:**
- Edit: `SenaniApp/Package.swift`
- Create (or edit if app-shell shipped it): `SenaniApp/Sources/SenaniApp/AppEnvironment.swift`

This makes the live + preview pipeline store available to the UI through a single composition point, per §1/§4 ("no screen constructs a store itself").

- [ ] **Step 1: Add the dependency**

Edit `SenaniApp/Package.swift`. In `dependencies`, add after the `SenaniAssistant` line:
```swift
        .package(path: "../Packages/SenaniEngine"),
```
In the `SenaniApp` target's `dependencies`, add after `"SenaniAssistant",`:
```swift
                "SenaniEngine",
```

- [ ] **Step 2: Resolve the build**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift build
```

Expected: builds clean (the app now links `SenaniEngine`). If resolution fails, STOP and report — do not fake it.

- [ ] **Step 3: Check whether `AppEnvironment` already exists**

```
ls /Users/vishalkumar/Downloads/qmail/SenaniApp/Sources/SenaniApp/AppEnvironment.swift 2>/dev/null && echo EXISTS || echo ABSENT
```
- **If `EXISTS`** (app-shell plan landed it): do NOT recreate. Add only a `public let pipeline: any PipelineStore` property, set it in `live()` to `try SqlitePipelineStore(database: database)` and in `preview()` to `InMemoryPipelineStore(AppEnvironment.seededDeals)`, and add the `seededDeals` static (Step 4's array). Record the deviation in the commit body. Skip the rest of Step 4.
- **If `ABSENT`:** create the minimal shim in Step 4.

- [ ] **Step 4: Create the minimal `AppEnvironment` shim**

Create `SenaniApp/Sources/SenaniApp/AppEnvironment.swift`:

```swift
import Foundation
import SenaniStore
import SenaniEngine

/// Minimal composition shim exposing the CRM pipeline store to the UI. The full AppEnvironment
/// (messages/rules/approvals/orchestrator/…) is owned by the app-shell plan; this ships only the
/// `pipeline` seam the Pipeline/CRM view needs, with live + preview factories. When the app-shell
/// AppEnvironment lands, fold `pipeline` into it and delete this shim.
@MainActor
final class AppEnvironment {
    let pipeline: any PipelineStore

    private init(pipeline: any PipelineStore) {
        self.pipeline = pipeline
    }

    /// Production graph: the CRM table lives in the shared senani.sqlite.
    static func live(database: SenaniDatabase) throws -> AppEnvironment {
        AppEnvironment(pipeline: try SqlitePipelineStore(database: database))
    }

    /// In-memory graph for SwiftUI previews + UI tests — no Keychain, MLX, or network.
    static func preview() -> AppEnvironment {
        AppEnvironment(pipeline: InMemoryPipelineStore(seededDeals))
    }

    /// Deterministic seed covering several stages for previews/tests.
    static let seededDeals: [Deal] = [
        Deal(id: "sarah@acme.com", contactEmail: "sarah@acme.com", company: "Acme Corp",
             stage: .qualified, score: 82, value: nil,
             lastTouch: Date(timeIntervalSince1970: 1_700_000_000), sourceMessageId: "m-1"),
        Deal(id: "vp@globex.com", contactEmail: "vp@globex.com", company: "Globex",
             stage: .proposal, score: 64, value: 24_000,
             lastTouch: Date(timeIntervalSince1970: 1_700_100_000), sourceMessageId: "m-2"),
        Deal(id: "ops@initech.com", contactEmail: "ops@initech.com", company: "Initech",
             stage: .negotiation, score: 71, value: 9_500,
             lastTouch: Date(timeIntervalSince1970: 1_700_200_000), sourceMessageId: "m-3"),
        Deal(id: "ceo@hooli.com", contactEmail: "ceo@hooli.com", company: "Hooli",
             stage: .won, score: 90, value: 50_000,
             lastTouch: Date(timeIntervalSince1970: 1_700_300_000), sourceMessageId: "m-4"),
    ]
}
```

- [ ] **Step 5: Build**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift build
```

Expected: builds clean.

- [ ] **Step 6: Commit**

```
cd /Users/vishalkumar/Downloads/qmail && git add SenaniApp/Package.swift SenaniApp/Sources/SenaniApp/AppEnvironment.swift && git commit -m "$(cat <<'EOF'
SenaniApp: depend on SenaniEngine + minimal AppEnvironment.pipeline (live/preview)

live() opens SqlitePipelineStore over the shared db; preview() seeds an
InMemoryPipelineStore. Shim folds into the app-shell AppEnvironment when it lands.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7 — Gold-glass `PipelineView` + `DealCard` + `#Preview` + CRM wiring

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/UI/PipelineView.swift`
- Edit: `SenaniApp/Sources/SenaniApp/UI/MainNavigationView.swift` (route `.crm` to `PipelineView`)

`PipelineView` takes a `[Deal]` (loaded by its host from `AppEnvironment.pipeline.all()`), runs them through `PipelineViewModel.columns(from:)`, and renders a horizontal kanban of glass cards. Each `DealCard` shows contact/company, a stage `StatusBadge`, score, value (formatted currency), and last touch (relative). Tapping a card calls `onOpenThread(deal.sourceMessageId ?? deal.id)`.

There is no SwiftUI unit-test harness in this repo (the scaffold has no UI tests target), so the testable surface is the pure `PipelineViewModel` (Task 5) + the `AppEnvironment.preview()` graph (Task 6). `PipelineView` is verified via the `#Preview` (rendered manually) and by compiling against the seeded preview environment. This matches the brief's "TESTS … view model groups deals by stage in canonical order; over AppEnvironment.preview() with seeded deals."

- [ ] **Step 1: Create `PipelineView.swift`**

```swift
import SwiftUI
import SenaniEngine

/// The Phase-3 Pipeline / CRM view: deals grouped by stage in a gold-glass kanban.
/// Pure grouping/sorting is delegated to `PipelineViewModel`; this file is presentation only.
struct PipelineView: View {
    let deals: [Deal]
    /// Host seam: open the source thread for a tapped deal (passes sourceMessageId or deal id).
    var onOpenThread: (String) -> Void = { _ in }

    private var columns: [StageColumn] { PipelineViewModel.columns(from: deals) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(columns) { column in
                    StageLane(column: column, onOpenThread: onOpenThread)
                        .frame(width: 280)
                }
            }
            .padding(20)
        }
        .background(Color.senaniObsidian.opacity(0.6))
        .navigationTitle("Pipeline")
    }
}

private struct StageLane: View {
    let column: StageColumn
    var onOpenThread: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                WordmarkHeader(title: column.stage.rawValue)
                Spacer()
                Text("\(column.deals.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            if column.deals.isEmpty {
                Text("No deals")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(column.deals) { deal in
                    DealCard(deal: deal)
                        .onTapGesture { onOpenThread(deal.sourceMessageId ?? deal.id) }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct DealCard: View {
    let deal: Deal

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(deal.company ?? deal.contactEmail)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                if deal.company != nil {
                    Text(deal.contactEmail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    StatusBadge(text: deal.stage.rawValue, color: .senaniGold)
                    if let score = deal.score {
                        Text("score \(score)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if let value = deal.value {
                        Text(Self.currency(value))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.senaniGold)
                    }
                    Spacer()
                    Text(Self.relative(deal.lastTouch))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func currency(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        return f.string(from: value as NSNumber) ?? "\(Int(value))"
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    PipelineView(deals: AppEnvironment.preview().pipeline.previewDealsForView())
}

/// Small bridge so the #Preview can pull the seeded deals out of the in-memory store synchronously.
private extension PipelineStore {
    func previewDealsForView() -> [Deal] { (try? all()) ?? [] }
}
```

> **`#Preview` note:** `AppEnvironment.preview()` is `@MainActor`; `#Preview` bodies run on the main actor, so the call is valid. The private `previewDealsForView()` extension reads the seeded in-memory store. If the build flags the `@MainActor` access, wrap the preview body's environment construction in the documented preview pattern; do not weaken `AppEnvironment`'s isolation.

- [ ] **Step 2: Route `.crm` to `PipelineView`**

Edit `SenaniApp/Sources/SenaniApp/UI/MainNavigationView.swift`. In `ContentView.body`, replace the `else` branch that shows the placeholder so `.crm` renders the pipeline. Change:

```swift
                if selection == .settings {
                    ModelPickerView()
                } else {
```
to:
```swift
                if selection == .settings {
                    ModelPickerView()
                } else if selection == .crm {
                    PipelineView(deals: crmDeals)
                } else {
```

And add, inside `ContentView` (it already has `let selection: NavigationItem?`), a computed property that reads the seeded preview store as a stand-in until the live `AppEnvironment` is injected by the app-shell plan:

```swift
    // Until the app-shell AppEnvironment is injected app-wide, the CRM view reads the
    // preview-seeded pipeline. Replace `AppEnvironment.preview()` with the injected
    // environment's `pipeline` once the app-shell plan wires AppEnvironment into @Environment.
    private var crmDeals: [Deal] {
        (try? AppEnvironment.preview().pipeline.all()) ?? []
    }
```

Add `import SenaniEngine` at the top of `MainNavigationView.swift` (for `Deal`).

> **FLAGGED stand-in:** `ContentView` is constructed by `MainNavigationView` which injects `@Environment(AppState.self)`. Wiring the *live* `SqlitePipelineStore` into the UI requires the app-shell plan's `AppEnvironment` to be injected via `@Environment`; until then the CRM screen renders seeded preview data so the view is reviewable. When app-shell lands, swap `crmDeals` to read the injected `AppEnvironment.pipeline`. This is recorded in Self-Review.

- [ ] **Step 3: Build the app**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift build
```

Expected: builds clean. (SwiftUI views are not unit-tested here; correctness of grouping/sorting is covered by `PipelineViewModelTests`, and the seeded data path by `AppEnvironment.preview()`.)

- [ ] **Step 4: Commit**

```
cd /Users/vishalkumar/Downloads/qmail && git add SenaniApp/Sources/SenaniApp/UI/PipelineView.swift SenaniApp/Sources/SenaniApp/UI/MainNavigationView.swift && git commit -m "$(cat <<'EOF'
SenaniApp: gold-glass PipelineView (kanban by stage) wired to the CRM sidebar item

Deals grouped via PipelineViewModel; each card shows contact/company/stage/score/
value/last-touch and taps to open the source thread. #Preview over seeded deals.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8 — Full verification + branch finish

**Files:** none (verification only).

- [ ] **Step 1: Engine suite green**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test
```
Expected: every test passes (Pipeline contract, Sqlite CRUD + reopen, AgentContext, view model, and all pre-existing Triage/Orchestrator/Scheduler tests).

- [ ] **Step 2: Engine builds clean under strict concurrency**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift build
```
Expected: no errors, no `Sendable`/concurrency warnings. (`Deal`/`DealStage`/`StageColumn` are value `Sendable`; `InMemoryPipelineStore` is `@unchecked Sendable` with an `NSLock`; `SqlitePipelineStore` is a `struct` over `@unchecked Sendable` `SenaniDatabase`; `PipelineViewModel` is a stateless enum.)

- [ ] **Step 3: App builds clean**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift build
```
Expected: builds clean with the new `SenaniEngine` dependency, `AppEnvironment`, and `PipelineView`.

- [ ] **Step 4: Finish the branch** — invoke the **superpowers:finishing-a-development-branch** skill to decide merge/PR/cleanup. Do not merge to the default branch without the user's go-ahead.

---

## Self-Review

**Scope coverage (brief → delivered):**
- **Ship EXACTLY the pinned `DealStage`/`Deal`/`PipelineStore` contract** — `Pipeline/PipelineStore.swift` ships them verbatim (`DealStage: String, Sendable, CaseIterable` with `new/qualified/proposal/negotiation/won/lost`; `Deal: Sendable, Identifiable, Codable` with all eight fields; `PipelineStore` with the five synchronous `throws` methods). ✅ (Task 1)
- **`SqlitePipelineStore: PipelineStore` over the SHARED `SenaniDatabase` via an additive app-tier `deals` table; do NOT edit frozen `SenaniStore`** — DECISION + JUSTIFICATION: `SenaniStore.SenaniMigrations.migrator()` is `internal` (verified) so it cannot be extended externally; `SenaniDatabase.queue` is `public`, so the store runs an idempotent `CREATE TABLE IF NOT EXISTS deals` on the shared queue at init, never touching GRDB's migration ledger. No separate `pipeline.sqlite` needed; the CRM correctly shares the single local store (ARCHITECTURE.md). The frozen package is untouched; a test (`sharesTheSameDatabaseAsMessageStore`) proves coexistence. ✅ (Task 2)
- **Plus `InMemoryPipelineStore` for tests/preview** — shipped, with `NullPipelineStore` as the `AgentContext` default. ✅ (Task 1)
- **Wire `PipelineStore` into `AppEnvironment` and `AgentContext.pipeline`** — `AgentContext.pipeline: any PipelineStore` added additively (defaulted to `NullPipelineStore`, so all existing engine code/tests compile unchanged; Orchestrator injects the live store later). `AppEnvironment` shim exposes `pipeline` with `live()` (Sqlite) + `preview()` (seeded in-memory). ✅ (Tasks 3, 6)
- **`PipelineView` (gold-glass) showing deals grouped by stage; each card: contact/company, stage, score, value, last touch; tapping opens the source thread; a pure view model owns grouping/sorting** — `PipelineView` renders a horizontal kanban of `GlassCard` lanes; `DealCard` shows company/contact, a stage `StatusBadge`, score, formatted currency value, relative last touch; `onTapGesture` calls `onOpenThread(sourceMessageId ?? id)`. `PipelineViewModel.columns(from:)` (pure, no SwiftUI) owns grouping into canonical-order columns + sort. ✅ (Tasks 5, 7)
- **TESTS: Sqlite CRUD round-trips on a temp db (upsert/fetch/byContact/byStage/all); data survives reopen; view model groups by stage in canonical order; over `AppEnvironment.preview()` with seeded deals; no MLX/Gmail/network; `#Preview`** — `SqlitePipelineStoreTests` covers all five methods + `dataSurvivesReopen` (write to a temp file, reopen a fresh db+store, read back). `PipelineViewModelTests` covers canonical six-stage order (incl. empty columns), grouping, and the lastTouch-desc-then-id-asc sort. `AppEnvironment.preview()` ships seeded deals across four stages; `PipelineView` has a `#Preview` driven by them. Everything is in-memory/temp-file — no MLX/Gmail/network anywhere. ✅ (Tasks 2, 5, 6, 7)

**Conventions (APP-PLANS-RECONCILIATION §4):** Composition root only — the view reads its store through `AppEnvironment.pipeline`, never constructs a store inline (the `crmDeals` stand-in calls `AppEnvironment.preview()`, the documented seam, flagged for swap to the injected env). One safety path preserved — the CRM is a pure store write, it never builds/executes an `Action` or touches `MailBackend`/`ApprovalStore`. Read through canonical stores — `SqlitePipelineStore` uses the same raw-SQL-over-`SenaniDatabase.queue` pattern as `MessageStore`. Live vs preview parity — `live()`/`preview()` factories; `#Preview` + seeded data. Swift 6 strict concurrency, Swift Testing. TDD bite-sized commits, complete code, no placeholders.

**Contracts this plan OWNS / exposes:**
- `SenaniEngine.DealStage` / `Deal` / `PipelineStore` (authoritative pin), `InMemoryPipelineStore`, `NullPipelineStore`, `SqlitePipelineStore`.
- `SenaniEngine.AgentContext.pipeline: any PipelineStore` (additive, defaulted).
- `SenaniEngine.StageColumn` / `PipelineViewModel.columns(from:)`.
- `SenaniApp.AppEnvironment` (minimal shim: `pipeline`, `live(database:)`, `preview()`, `seededDeals`), `PipelineView`.

**Risks / assumptions to confirm with the human (state before/while coding):**
1. **Follow-up plan divergence (BLOCKING for that plan, not this one).** The Follow-up agent plan's draft pins a different `DealStage` (`lead/qualified/proposalSent/negotiation/won/lost`) and a different `Deal` (`contact`/`threadId`/`lastTouch?`/`isOpen`, plus `PipelineReading`/`PipelineTouching`). THIS plan is authoritative (Lead-Qualifier + Proposal-Tracker match this shape). The Follow-up agent must adapt: `contact`→`contactEmail`, "open" = `stage != .won && != .lost`, "touch" = upsert with new `lastTouch`, and there is no `threadId` on `Deal` (it derives the deal from `byContact`). Flagged in Task 4's doc edit. Do not ship the Follow-up variant.
2. **`AppEnvironment` ownership.** This plan ships a MINIMAL `AppEnvironment` shim (pipeline only) because the app-shell plan that owns the full composition root has not landed and the scaffold still uses `AppState`. If app-shell shipped `AppEnvironment` first, add only `pipeline` to it (Task 6 Step 3) — do not create a second type. When app-shell lands, fold the shim in and swap `ContentView.crmDeals` to the injected environment.
3. **Live store wiring into the UI is deferred.** `ContentView` currently renders the CRM from `AppEnvironment.preview()` seeded data (the view is reviewable now). Wiring the live `SqlitePipelineStore(database:)` into the screen requires the app-shell plan to inject `AppEnvironment` via `@Environment`. Flagged at Task 7 Step 2.
4. **GRDB visibility in `SenaniEngine`.** If `import GRDB` does not resolve transitively, Task 2's fallback adds GRDB explicitly to `SenaniEngine/Package.swift` (mirroring `SenaniStore`'s exact package/product names). Verify at build.
5. **Design-system names.** This plan reuses the scaffold's `GlassCard`/`.goldGlass()`/`StatusBadge`/`.senaniGold`, NOT the APP-PLANS §3 pinned `DesignSystem.GlassPanel`/`Gold` (owned by the design-system plan). If that plan lands its tokens, re-skin `DealCard`/`StageLane` to them — purely cosmetic.
6. **`Deal.id = contactEmail` convention.** The store is id-keyed and agnostic; the agents (not this plan) choose `id = contactEmail` for one-deal-per-contact upserts. `byContact` is provided + case-insensitive so that convention works. No constraint enforced store-side beyond the `id` primary key.
