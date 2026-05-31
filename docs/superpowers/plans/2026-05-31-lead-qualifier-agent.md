# Lead Qualifier Agent Implementation Plan (Phase 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure, fully-unit-tested **Lead Qualifier agent** — the first agent of Senani's Phase-3 Pro sales suite (ROADMAP.md Phase 3 → "**Lead Qualifier**"). The agent wakes for messages the Triage agent classified as `Lead` (carrying the `Senani/Category/Lead` label), scores the lead **0–100** and extracts `company` / `intent` / `budget` signals by calling the injected `tools.generateJSON(prompt:schema:)` with a **shape-constrained** schema (`score` int, `company` string, `intent` enum-in-prompt, `reason` string), parses the result **safely (never crashing on bad model output, falling back to a Cold score of 0)**, and then does two things: (1) emits a reversible `proposeLabel` Action — `Senani/Lead/Hot|Warm|Cold` per the score threshold — and (2) **upserts a `Deal`** (stage `.qualified`, the score, `contactEmail = sender`, `sourceMessageId = message.id`) into the injected `PipelineStore`. It is otherwise pure: the only I/O is `tools.generateJSON` and the single `context.pipeline.upsert` write. **No MLX, no Gmail, no SwiftUI** in this plan — driven entirely by a **local `FakeTextGenerator`** returning canned JSON and an **in-memory `PipelineStore` fake**.

**Architecture:** The Lead Qualifier conforms to the `SenaniEngine.Agent` protocol pinned in `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md` §3 (`Agent` / `AgentContext` / `AgentTools`). It is **co-located inside the `SenaniEngine` package, under `Sources/SenaniEngine/Agents/`** — the identical decision the Triage plan (`2026-05-31-triage-agent.md`) made and for the same reasons: the agent's only hard dependency is the `Agent`/`AgentContext`/`AgentTools` contract, which lives in SenaniEngine, so co-location avoids a package explosion and a cross-package import of a contract type that is meaningless outside SenaniEngine. The Orchestrator (same package, separate plan) holds agents and routes their Actions, so they belong together.

This plan assumes the **Triage plan has already landed** and therefore that `Packages/SenaniEngine` exists with the §3 contract files (`Agent.swift`, `AgentContext.swift`, `AgentTools.swift`) and the `AgentTools.generateJSON(prompt:schema:)` seam. **If `SenaniEngine` does not yet exist in this worktree, this plan bootstraps those three contract files exactly as the Triage plan specifies** (see Task 1 / Task 2 fallback) — written to match §3 so neither plan's files conflict; coordinate via `claim-coordination` on the `senani-engine` slug.

**Two structural decisions, both flagged as contract additions:**

1. **PipelineStore is reached via `AgentContext.pipeline` — FLAGGED §3 contract addition.** The Deal upsert is a *side-effecting write to a store*, not a pure Action the Orchestrator can route through `ActionRouter`. There is no `SenaniRules.Action` case for "upsert a CRM deal" (adding one would be a blocking change to a frozen package — §5 of APP-PLANS-RECONCILIATION). So the pipeline is exposed as a **read/write accessor on `AgentContext`** (the agent's injected "world"), NOT as a pure builder on `AgentTools` (whose established role, per the Triage plan, is pure Action builders + the single `generateJSON` I/O seam). This keeps the agent testable (inject an in-memory fake) and keeps the label-Action safety path untouched: the label still flows through the Orchestrator's `ActionRouter` exactly like any other reversible label. This plan **adds `AgentContext.pipeline: any PipelineStore`** and records it in APP-PLANS-RECONCILIATION §3 (Task 6). **The `pipeline-crm-view` plan owns `PipelineStore`; this is the single addition this plan flags to it.**

2. **`PipelineStore` / `Deal` / `DealStage` are owned by the `pipeline-crm-view` plan.** They do not exist yet. This plan **codes to the MINIMAL pinned contract below** and, because the owning plan has not landed, **bootstraps those types** in a small `SenaniEngine/Pipeline/` file written to match the pin exactly, so the agent compiles and tests. When the `pipeline-crm-view` plan lands its richer `PipelineStore` (e.g. a SQLite-backed implementation in `SenaniStore` or its own package), SenaniEngine adapts to it and these bootstrap types are removed in favor of the real ones — they must stay **signature-identical** so that swap is mechanical. Any field/method this plan would need beyond the pin is FLAGGED, not silently added.

**Tech Stack:** Swift 6.2, strict concurrency, `swift-tools-version: 6.0`, Swift Package Manager, Swift Testing (`import Testing`, ships with the toolchain). Target platform macOS 14. Depends only on the frozen `SenaniRules`, `SenaniInference`, and `SenaniStore` (the last only for `AgentContext.retrieve`'s `VectorHit`, already wired by the Triage plan). No MLX, no Gmail, no UI.

**Working directory:** All `swift` commands run from `Packages/SenaniEngine/` unless stated otherwise.

**Roadmap:** ROADMAP.md Phase 3 → "**Lead Qualifier**" + "Lightweight pipeline / CRM view". This plan delivers the agent + its qualification logic + the Deal upsert. The Pipeline/CRM view (SwiftUI), the real `PipelineStore` persistence, the Orchestrator wiring (routing the `Senani/Category/Lead` label to this agent via `AgentRegistry`), the Scheduler, and the live `MLXTextGenerator` path are **separate plans**.

**Out of scope (separate plans):** the `Orchestrator`/`Scheduler`/`AgentRegistry` runtime (owns routing the `Lead` category to this agent); the real `PipelineStore` persistence + the Pipeline/CRM SwiftUI view (`pipeline-crm-view` plan); the real Gemma `TextGenerator` (MLX); the Gmail `MailBackend`; the other Phase-3 agents (Proposal Tracker, Follow-up, Outreach, Invoice/Finance); all UI.

---

## Cross-package assumptions (state these to the human before coding)

This plan codes to the exact signatures below. If a sibling differs, adjust the local contract/adapter — never edit a frozen package.

### `SenaniRules` (built + frozen, verified from source — do NOT edit)
```swift
public struct Message: Sendable, Equatable, Identifiable {
    public let id, from: String
    public let to: [String]
    public let subject, body: String
    public let hasAttachment: Bool
    public let listUnsubscribeHeader: String?
    public let labels: [String]
    public let threadId: String
    public let date: Date
    public let isFromUser: Bool
    public init(id:from:to:subject:body:hasAttachment:listUnsubscribeHeader:labels:threadId:date:isFromUser:)
    public var senderDomain: String   // lowercased host after last "@", else ""
}
public enum Action: Sendable, Equatable {
    case label(String); case archive; case markRead; /* … */ case reply(body:String); /* … */
    public var actionClass: ActionClass   // .label -> .reversible ; .reply/.forward/.send/.markSpam -> .outbound
}
public enum ActionClass: Sendable, Equatable { case reversible, outbound }
public enum Autonomy: String, Sendable, Equatable { case ask, prepare, auto }
public struct Rule: Sendable, Equatable, Identifiable { /* id, name, enabled, conditions, actions, autonomy, runOn */ }
```
- **Key facts used here (verified `Action.swift`):** `Action.label(String).actionClass == .reversible`, so the Lead label proposals can be auto-applied by the Orchestrator when the agent's autonomy allows. `Message.senderDomain` is computed. `Message.from` is the sender address (used as `Deal.contactEmail`).

### `SenaniInference` (built + frozen, verified from source — do NOT edit; ships NO fakes)
```swift
public protocol TextGenerator: Sendable {
    func generate(prompt: String, maxTokens: Int) async throws -> String
    func generateJSON(prompt: String, schema: JSONSchema) async throws -> String
}
public indirect enum JSONSchema: Sendable, Equatable {
    case boolean
    case string
    case number
    case array(element: JSONSchema)
    case object(properties: [String: JSONSchema], required: [String])
    public init(json: String)   // tolerant parse; "integer"/"number" -> .number; unknown/invalid -> .object([:],[])
}
```
- **CRITICAL constraint (verified `JSONSchema.swift`):** `JSONSchema` has **no enum/`oneOf`/min/max constraint** — `.string` cannot pin `intent` to `evaluating|ready|info|spam`, and `.number` cannot bound `score` to 0–100. Therefore the schema constrains *shape only* (an object with `score:number`, `company:string`, `intent:string`, `reason:string`). The intent enum and the score range are **enforced in the prompt instructions and re-validated when parsing**, with a safe fallback (`score: 0`, `intent: .info`, empty company) on any deviation or malformed JSON. We do **not** depend on the generator to enforce them. (`JSONSchema.init(json:)` maps both `"integer"` and `"number"` to `.number`, so the score field is `.number` in the schema.)
- **No upstream fakes (verified):** `SenaniInference` ships only `MLXTextGenerator`. This plan defines its **own** local `FakeTextGenerator` in the test target (same pattern as the Triage plan).

### `SenaniEngine` (NEW — pinned by APP-PLANS-RECONCILIATION §3; created by the Triage plan, EXTENDED here)
Per §3 + the Triage plan's bootstrap. This plan assumes these already exist; if not, it creates them identically (Task 2 fallback).
```swift
public protocol Agent: Sendable {
    var id: String { get }
    var autonomy: Autonomy { get }
    func wakesFor(_ message: Message, context: AgentContext) -> Bool
    func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action]
}
public struct AgentContext: Sendable {
    public let account: String
    public let thread: [Message]
    public let rules: [Rule]
    public let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit]   // SenaniStore.VectorHit
    public let now: Date
    // ⚠ CONTRACT ADDITION (this plan): the CRM pipeline write/read seam for sales agents.
    public let pipeline: any PipelineStore
}
public struct AgentTools: Sendable {
    public func draftReply(to message: Message, body: String) -> Action
    public func proposeLabel(_ label: String, on message: Message) -> Action
    public func archive(_ message: Message) -> Action
    public func markRead(_ message: Message) -> Action
    public func generateJSON(prompt: String, schema: JSONSchema) async throws -> String   // added by Triage plan
}
```

### `PipelineStore` seam (OWNED by the `pipeline-crm-view` plan — pinned MINIMAL contract; bootstrapped here)
This plan codes to **exactly** this. The `pipeline-crm-view` plan is authoritative; this plan flags `AgentContext.pipeline` as its single addition and any field it would need beyond this pin.
```swift
public enum DealStage: String, Sendable { case new, qualified, proposal, negotiation, won, lost }
public struct Deal: Sendable, Identifiable {
    public var id: String
    public var contactEmail: String
    public var company: String?
    public var stage: DealStage
    public var score: Int?
    public var value: Double?
    public var lastTouch: Date
    public var sourceMessageId: String?
}
public protocol PipelineStore: Sendable {
    func upsert(_ deal: Deal) throws
    func fetch(id: String) throws -> Deal?
    func byContact(_ email: String) throws -> Deal?
    func all() throws -> [Deal]
    func byStage(_ stage: DealStage) throws -> [Deal]
}
```
- **`Deal.id` choice (flagged):** the pin does not say how a Deal id is derived. This agent uses a **stable, deterministic id = the contact email** (so re-qualifying the same sender *updates* the same Deal rather than creating duplicates — this is what `upsert` + `byContact` imply). The agent reads `byContact(sender)` first; if a Deal exists it preserves the existing `id`/`value` and updates `score`/`stage`/`company`/`lastTouch`/`sourceMessageId`; otherwise it creates `Deal(id: sender, ...)`. If the `pipeline-crm-view` plan prefers UUID ids keyed off `byContact`, that is a mechanical change to one helper (`Self.makeDeal`) — FLAGGED.
- **`PipelineStore` methods are synchronous `throws` (per the pin), not `async`.** The agent calls `context.pipeline.byContact(...)` / `.upsert(...)` synchronously inside its `async` `proposals`. The in-memory fake locks internally for `Sendable` safety.
- **Bootstrap caveat:** because the owning plan has not landed, this plan creates `Deal`/`DealStage`/`PipelineStore` in `Sources/SenaniEngine/Pipeline/PipelineStore.swift`, signature-identical to the pin. When the real types land (likely in `SenaniStore` or a `SenaniPipeline` package), delete this file and import them; the agent code is unchanged because it depends only on the pinned signatures. If the owning plan has ALREADY shipped these types when this plan runs, SKIP the bootstrap file and import the real module instead — do not define a second `PipelineStore`.

---

## File Structure

```
Packages/SenaniEngine/
  Package.swift                      # (exists from Triage plan; unchanged here)
  Sources/SenaniEngine/
    Agent.swift                      # (exists) Agent protocol — unchanged
    AgentContext.swift               # EDIT: add `pipeline: any PipelineStore` (flagged §3 addition)
    AgentTools.swift                 # (exists) unchanged
    Pipeline/
      PipelineStore.swift            # NEW (bootstrap): DealStage + Deal + PipelineStore (pinned contract)
    Agents/
      TriageCategory.swift           # (exists from Triage plan) — reused for the Lead category constant
      LeadIntent.swift               # NEW: LeadIntent enum + LeadTier (Hot/Warm/Cold) + score thresholds + labels
      LeadQualification.swift        # NEW: decoded {score,company,intent,reason} + safe parse + clamp + JSON schema
      LeadQualifierAgent.swift       # NEW: LeadQualifierAgent: Agent — wakesFor(Lead) + proposals (generate, parse, label + Deal upsert)
  Tests/SenaniEngineTests/
    TestSupport.swift                # (exists) EDIT: add InMemoryPipelineStore fake + ctx(pipeline:) overload
    LeadQualificationTests.swift     # NEW: schema shape + safe parse + clamp + intent validation + fallback
    LeadTierTests.swift              # NEW: score -> Hot/Warm/Cold threshold mapping + labels
    LeadQualifierAgentTests.swift    # NEW: wakesFor(Lead only) + label Action + Deal upsert fields + malformed fallback
```

One responsibility per file. `LeadQualifierAgent` depends only on the SenaniEngine contract (`Agent`/`AgentContext`/`AgentTools`) + `SenaniRules.Action`/`Message` + `SenaniInference.JSONSchema` + the `PipelineStore` seam. Every test runs against a local `FakeTextGenerator` and an `InMemoryPipelineStore`.

---

### Task 1: Confirm SenaniEngine exists (or bootstrap it) + add the Pipeline seam

**Files:**
- Verify: `Packages/SenaniEngine/Package.swift`, `Sources/SenaniEngine/{Agent,AgentContext,AgentTools}.swift` (from Triage plan)
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Pipeline/PipelineStore.swift`
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/LeadQualificationTests.swift` (placeholder import-only test)

- [ ] **Step 1: Confirm the package + contract are present**

```
ls Packages/SenaniEngine/Sources/SenaniEngine/Agent.swift \
   Packages/SenaniEngine/Sources/SenaniEngine/AgentContext.swift \
   Packages/SenaniEngine/Sources/SenaniEngine/AgentTools.swift \
   Packages/SenaniEngine/Sources/SenaniEngine/Agents/TriageCategory.swift
```

Expected: all four files exist (the Triage plan created them). **If they do NOT exist**, the Triage plan has not landed — bootstrap `Packages/SenaniEngine` exactly as Tasks 1–2 of `2026-05-31-triage-agent.md` specify (the `Package.swift` with `SenaniRules`/`SenaniInference`/`SenaniStore` path deps, and `Agent.swift`/`AgentContext.swift`/`AgentTools.swift` written to match §3, plus `TriageCategory.swift`), then return here. Coordinate on the `senani-engine` claim slug so the two plans do not collide on those files.

- [ ] **Step 2: Write a failing import test**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/LeadQualificationTests.swift`:

```swift
import Testing
@testable import SenaniEngine
import SenaniRules

@Test func leadPipelineSeamCompiles() throws {
    // Proves the PipelineStore seam types exist and Deal carries the pinned fields.
    let deal = Deal(id: "a@b.com", contactEmail: "a@b.com", company: "Acme",
                    stage: .qualified, score: 80, value: nil,
                    lastTouch: .init(timeIntervalSince1970: 0), sourceMessageId: "m1")
    #expect(deal.stage == .qualified)
    #expect(deal.score == 80)
}
```

- [ ] **Step 3: Run to fail**

```
cd Packages/SenaniEngine && swift test --filter leadPipelineSeamCompiles
```

Expected: failure — `Deal`/`DealStage`/`PipelineStore` not defined.

- [ ] **Step 4: Bootstrap the PipelineStore seam**

> **If the `pipeline-crm-view` plan has already shipped `Deal`/`DealStage`/`PipelineStore`** (check for an importable module exposing them, e.g. `SenaniStore` or `SenaniPipeline`), SKIP creating this file — instead add the owning module to `Package.swift` deps and `import` it. Do NOT define a second `PipelineStore`. Otherwise create the bootstrap below.

Create `Packages/SenaniEngine/Sources/SenaniEngine/Pipeline/PipelineStore.swift`:

```swift
import Foundation

/// CRM pipeline seam — OWNED by the `pipeline-crm-view` plan. Bootstrapped here
/// (signature-identical to the pinned minimal contract) so sales agents compile and
/// test before that plan lands. When the real types ship, delete this file and import them.
public enum DealStage: String, Sendable {
    case new, qualified, proposal, negotiation, won, lost
}

public struct Deal: Sendable, Identifiable {
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

public protocol PipelineStore: Sendable {
    func upsert(_ deal: Deal) throws
    func fetch(id: String) throws -> Deal?
    func byContact(_ email: String) throws -> Deal?
    func all() throws -> [Deal]
    func byStage(_ stage: DealStage) throws -> [Deal]
}
```

- [ ] **Step 5: Run to pass**

```
cd Packages/SenaniEngine && swift test --filter leadPipelineSeamCompiles
```

Expected: pass.

- [ ] **Step 6: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: bootstrap PipelineStore/Deal/DealStage seam for sales agents"
```

Use this commit trailer on EVERY commit in this plan:

```

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

---

### Task 2: Add `AgentContext.pipeline` (flagged §3 contract addition) + in-memory fake

**Files:**
- Edit: `Packages/SenaniEngine/Sources/SenaniEngine/AgentContext.swift`
- Edit: `Packages/SenaniEngine/Tests/SenaniEngineTests/TestSupport.swift`

The agent reaches the CRM store through `AgentContext.pipeline`. This is the single SenaniEngine contract addition this plan makes; recorded in APP-PLANS-RECONCILIATION §3 in Task 6.

- [ ] **Step 1: Write a failing fake + self-test**

Append to `Packages/SenaniEngine/Tests/SenaniEngineTests/TestSupport.swift` (the file already holds `FakeTextGenerator`, `msg`, `tools`, `ctx` from the Triage plan):

```swift
// ---- In-memory PipelineStore fake (the real store is owned by the pipeline-crm-view plan) ----
final class InMemoryPipelineStore: PipelineStore, @unchecked Sendable {
    private let lock = NSLock()
    private var deals: [String: Deal] = [:]   // keyed by Deal.id

    func upsert(_ deal: Deal) throws {
        lock.lock(); defer { lock.unlock() }
        deals[deal.id] = deal
    }
    func fetch(id: String) throws -> Deal? {
        lock.lock(); defer { lock.unlock() }
        return deals[id]
    }
    func byContact(_ email: String) throws -> Deal? {
        lock.lock(); defer { lock.unlock() }
        return deals.values.first { $0.contactEmail == email }
    }
    func all() throws -> [Deal] {
        lock.lock(); defer { lock.unlock() }
        return Array(deals.values)
    }
    func byStage(_ stage: DealStage) throws -> [Deal] {
        lock.lock(); defer { lock.unlock() }
        return deals.values.filter { $0.stage == stage }
    }
}

/// Context overload that injects a pipeline (the existing `ctx()` from the Triage plan
/// must be updated to thread a pipeline through — see Step 3). This helper keeps lead tests terse.
func ctx(pipeline: PipelineStore, now: Date = Date()) -> AgentContext {
    AgentContext(account: "me@x.com", thread: [], rules: [],
                 retrieve: { _, _ in [] }, now: now, pipeline: pipeline)
}

@Test func inMemoryPipelineUpsertsAndQueries() throws {
    let store = InMemoryPipelineStore()
    let deal = Deal(id: "a@b.com", contactEmail: "a@b.com", company: "Acme",
                    stage: .qualified, score: 90, value: nil,
                    lastTouch: .init(timeIntervalSince1970: 0), sourceMessageId: "m1")
    try store.upsert(deal)
    #expect(try store.byContact("a@b.com")?.score == 90)
    #expect(try store.byStage(.qualified).count == 1)
    // upsert is idempotent on id:
    var updated = deal; updated.score = 95
    try store.upsert(updated)
    #expect(try store.all().count == 1)
    #expect(try store.fetch(id: "a@b.com")?.score == 95)
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniEngine && swift test --filter inMemoryPipelineUpsertsAndQueries
```

Expected: failure — `AgentContext.init(...)` has no `pipeline:` parameter yet (compile error in the `ctx(pipeline:)` helper).

- [ ] **Step 3: Add `pipeline` to `AgentContext`**

Edit `Packages/SenaniEngine/Sources/SenaniEngine/AgentContext.swift` to add the stored property and the `pipeline:` init parameter. The full file after the edit:

```swift
import Foundation
import SenaniRules
import SenaniStore

/// Read-only world the agent may see, pre-populated by the Orchestrator.
/// Agents never query stores directly — they reach them through these seams.
/// (APP-PLANS-RECONCILIATION §3; `pipeline` added by the Lead Qualifier plan.)
public struct AgentContext: Sendable {
    public let account: String
    public let thread: [Message]            // the message's thread, date asc
    public let rules: [Rule]
    public let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit]
    public let now: Date
    /// ⚠ CONTRACT ADDITION (Lead Qualifier plan): the CRM pipeline seam sales agents
    /// write Deals to. The Deal upsert is a store write, not an `ActionRouter`-routable
    /// Action, so it lives on the agent's injected world, not on the pure `AgentTools`.
    public let pipeline: any PipelineStore

    public init(account: String, thread: [Message], rules: [Rule],
                retrieve: @escaping @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit],
                now: Date,
                pipeline: any PipelineStore) {
        self.account = account
        self.thread = thread
        self.rules = rules
        self.retrieve = retrieve
        self.now = now
        self.pipeline = pipeline
    }
}
```

> **Migration of the existing `ctx()` helper (from the Triage plan):** the Triage plan's `TestSupport.swift` defines `func ctx(now:) -> AgentContext` WITHOUT a pipeline, which now fails to compile. Update that helper to default-inject an `InMemoryPipelineStore`:
> ```swift
> func ctx(now: Date = Date()) -> AgentContext {
>     AgentContext(account: "me@x.com", thread: [], rules: [],
>                  retrieve: { _, _ in [] }, now: now, pipeline: InMemoryPipelineStore())
> }
> ```
> This keeps every existing Triage test green (Triage ignores `pipeline`). Run the full suite in Step 4 to confirm.

- [ ] **Step 4: Run to pass (and confirm Triage tests still green)**

```
cd Packages/SenaniEngine && swift test
```

Expected: `inMemoryPipelineUpsertsAndQueries` passes AND all pre-existing Triage tests still pass (the defaulted `pipeline` keeps them compiling).

- [ ] **Step 5: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: add AgentContext.pipeline seam + InMemoryPipelineStore fake"
```

(Append the standard trailer.)

---

### Task 3: Lead vocabulary — LeadIntent + LeadTier (thresholds, labels)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/LeadIntent.swift`
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/LeadTierTests.swift`

`LeadIntent` is the closed intent vocabulary (enforced in prompt + re-validated on parse). `LeadTier` maps a 0–100 score to `Hot`/`Warm`/`Cold` and yields the reversible label string. **Thresholds: Hot ≥ 70, Warm 40–69, Cold ≤ 39.**

- [ ] **Step 1: Write failing tier/intent tests**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/LeadTierTests.swift`:

```swift
import Testing
@testable import SenaniEngine

@Test func leadTierThresholds() {
    // Cold: 0..39, Warm: 40..69, Hot: 70..100 (inclusive boundaries).
    #expect(LeadTier(score: 0) == .cold)
    #expect(LeadTier(score: 39) == .cold)
    #expect(LeadTier(score: 40) == .warm)
    #expect(LeadTier(score: 69) == .warm)
    #expect(LeadTier(score: 70) == .hot)
    #expect(LeadTier(score: 100) == .hot)
}

@Test func leadTierLabelStrings() {
    #expect(LeadTier.hot.label == "Senani/Lead/Hot")
    #expect(LeadTier.warm.label == "Senani/Lead/Warm")
    #expect(LeadTier.cold.label == "Senani/Lead/Cold")
}

@Test func leadIntentParseIsCaseInsensitiveWithFallback() {
    #expect(LeadIntent.parse("ready") == .ready)
    #expect(LeadIntent.parse("EVALUATING") == .evaluating)
    #expect(LeadIntent.parse(" Info ") == .info)
    #expect(LeadIntent.parse("spam") == .spam)
    #expect(LeadIntent.parse("banana") == .info)   // unknown -> .info (neutral fallback)
    #expect(LeadIntent.parse("") == .info)
}

@Test func leadIntentAllCasesAreStableWireStrings() {
    #expect(LeadIntent.allCases.map(\.rawValue).sorted()
            == ["evaluating", "info", "ready", "spam"])
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniEngine && swift test --filter LeadTierTests
```

Expected: failure — `LeadTier`/`LeadIntent` undefined.

- [ ] **Step 3: Implement the vocabulary**

Create `Packages/SenaniEngine/Sources/SenaniEngine/Agents/LeadIntent.swift`:

```swift
import Foundation

/// What the prospect appears to want. Closed set, enforced in the prompt and
/// re-validated on parse (JSONSchema cannot pin an enum). Unknown -> .info.
public enum LeadIntent: String, CaseIterable, Sendable, Equatable {
    case evaluating   // actively comparing / asking detailed questions
    case ready        // ready to buy / wants pricing or a contract now
    case info         // general inquiry / early-stage interest (neutral default)
    case spam         // not a real lead

    /// Case-insensitive lookup; unknown/blank -> .info (neutral safe fallback).
    public static func parse(_ raw: String) -> LeadIntent {
        LeadIntent(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .info
    }
}

/// Lead temperature derived from the 0–100 score. Thresholds: Hot ≥ 70, Warm 40–69, Cold ≤ 39.
public enum LeadTier: String, CaseIterable, Sendable, Equatable {
    case hot, warm, cold

    public init(score: Int) {
        switch score {
        case 70...: self = .hot
        case 40..<70: self = .warm
        default: self = .cold       // <= 39, and any negative (clamped upstream anyway)
        }
    }

    /// The reversible Gmail label the agent proposes, e.g. "Senani/Lead/Hot".
    public var label: String { "Senani/Lead/\(rawValue.capitalized)" }
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniEngine && swift test --filter LeadTierTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: LeadIntent vocab + LeadTier score thresholds (Hot/Warm/Cold)"
```

(Append the standard trailer.)

---

### Task 4: LeadQualification — schema, safe parse, score clamp, intent validation, fallback

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/LeadQualification.swift`
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/LeadQualificationTests.swift` (replace the Task 1 placeholder)

`LeadQualification` decodes the model's `{score, company, intent, reason}` JSON, **clamping `score` to 0–100, validating `intent` against the enum, and falling back to `score: 0` / `intent: .info` / empty company on any deviation or malformed JSON — it never throws and never crashes.** A score of 0 → Cold tier, the honest fallback for unparseable model output.

- [ ] **Step 1: Replace the placeholder with real failing tests**

Replace `Packages/SenaniEngine/Tests/SenaniEngineTests/LeadQualificationTests.swift`:

```swift
import Testing
@testable import SenaniEngine
import SenaniInference

@Test func schemaConstrainsShapeToScoreCompanyIntentReason() {
    // JSONSchema has no enum/min/max, so this asserts SHAPE only:
    // score is .number; company/intent/reason are .string; all four required.
    guard case let .object(properties, required) = LeadQualification.schema else {
        Issue.record("schema must be an object"); return
    }
    #expect(properties["score"] == .number)
    #expect(properties["company"] == .string)
    #expect(properties["intent"] == .string)
    #expect(properties["reason"] == .string)
    #expect(Set(required) == ["score", "company", "intent", "reason"])
    #expect(LeadQualification.schema == JSONSchema(json: LeadQualification.schemaJSON))
}

@Test func parsesWellFormedQualification() {
    let q = LeadQualification.parse(
        #"{"score":82,"company":"Acme Corp","intent":"ready","reason":"wants a quote this week"}"#)
    #expect(q.score == 82)
    #expect(q.company == "Acme Corp")
    #expect(q.intent == .ready)
    #expect(q.reason == "wants a quote this week")
    #expect(q.tier == .hot)
}

@Test func parseToleratesSurroundingProseAndFloatScore() {
    // JSON embedded in chatter; score arrives as a float -> truncates to Int.
    let q = LeadQualification.parse(
        #"Here: {"score":55.7,"company":"Beta LLC","intent":"Evaluating","reason":"comparing vendors"} ok"#)
    #expect(q.score == 55)
    #expect(q.intent == .evaluating)
    #expect(q.tier == .warm)
}

@Test func scoreIsClampedTo0Through100() {
    #expect(LeadQualification.parse(#"{"score":250,"company":"","intent":"ready","reason":""}"#).score == 100)
    #expect(LeadQualification.parse(#"{"score":-40,"company":"","intent":"ready","reason":""}"#).score == 0)
}

@Test func stringScoreIsParsedThenClamped() {
    // Some models emit numbers as strings; accept and clamp.
    let q = LeadQualification.parse(#"{"score":"77","company":"X","intent":"ready","reason":"y"}"#)
    #expect(q.score == 77)
    #expect(q.tier == .hot)
}

@Test func unknownIntentFallsBackToInfoScorePreserved() {
    let q = LeadQualification.parse(#"{"score":65,"company":"Z","intent":"spaceship","reason":"?"}"#)
    #expect(q.intent == .info)
    #expect(q.score == 65)
    #expect(q.tier == .warm)
}

@Test func malformedJsonFallsBackToColdNeverCrashes() {
    for raw in ["{ this is not json", "", #"{"reason":"only reason"}"#, "I cannot comply </think>"] {
        let q = LeadQualification.parse(raw)
        #expect(q.score == 0)
        #expect(q.intent == .info)
        #expect(q.company == nil)
        #expect(q.tier == .cold)
    }
}

@Test func blankCompanyBecomesNil() {
    #expect(LeadQualification.parse(#"{"score":50,"company":"   ","intent":"info","reason":"r"}"#).company == nil)
    #expect(LeadQualification.parse(#"{"score":50,"company":"Acme","intent":"info","reason":"r"}"#).company == "Acme")
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniEngine && swift test --filter LeadQualificationTests
```

Expected: failure — `LeadQualification` undefined.

- [ ] **Step 3: Implement `LeadQualification`**

Create `Packages/SenaniEngine/Sources/SenaniEngine/Agents/LeadQualification.swift`:

```swift
import Foundation
import SenaniInference

/// The decoded result of one lead qualification. Construction NEVER fails:
/// `parse` clamps the score to 0–100, validates `intent` against the enum, and
/// falls back to score 0 / intent .info / nil company on any deviation.
public struct LeadQualification: Sendable, Equatable {
    public let score: Int            // 0...100 (clamped)
    public let company: String?      // nil if blank/missing
    public let intent: LeadIntent
    public let reason: String

    public init(score: Int, company: String?, intent: LeadIntent, reason: String) {
        self.score = min(100, max(0, score))
        self.company = company
        self.intent = intent
        self.reason = reason
    }

    /// Derived temperature used for the reversible label.
    public var tier: LeadTier { LeadTier(score: score) }

    /// The shape the generator is asked to emit. NOTE: JSONSchema has no enum/min/max,
    /// so this constrains SHAPE only. The intent enum + 0–100 range are enforced in the
    /// prompt and re-validated/clamped in `parse`. (`integer` is parsed by JSONSchema as `.number`.)
    public static let schemaJSON = """
    {
      "type": "object",
      "properties": {
        "score": { "type": "integer" },
        "company": { "type": "string" },
        "intent": { "type": "string" },
        "reason": { "type": "string" }
      },
      "required": ["score", "company", "intent", "reason"]
    }
    """

    public static let schema = JSONSchema(json: schemaJSON)

    /// Safe parse: extracts the first balanced JSON object, reads the fields, coerces/clamps
    /// the score, validates intent, nils a blank company. Never throws/crashes; on any failure
    /// returns the Cold fallback (score 0, intent .info, nil company).
    public static func parse(_ raw: String) -> LeadQualification {
        let fallback = LeadQualification(score: 0, company: nil, intent: .info, reason: "")
        guard
            let data = firstJSONObject(in: raw),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        else {
            return fallback
        }
        let score = coerceScore(dict["score"])
        let intent = LeadIntent.parse((dict["intent"] as? String) ?? "")
        let reason = (dict["reason"] as? String) ?? ""
        let rawCompany = (dict["company"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let company = (rawCompany?.isEmpty == false) ? rawCompany : nil
        return LeadQualification(score: score, company: company, intent: intent, reason: reason)
    }

    /// Accepts Int, Double, or numeric String; anything else -> 0. The init clamps to 0...100.
    private static func coerceScore(_ value: Any?) -> Int {
        switch value {
        case let n as Int: return n
        case let d as Double: return Int(d)
        case let s as String: return Int(s) ?? Int(Double(s) ?? 0)
        case let n as NSNumber: return n.intValue   // JSONSerialization boxes numbers as NSNumber
        default: return 0
        }
    }

    /// Returns the bytes of the first balanced {...} object in `raw`, tolerating surrounding prose.
    /// Mirrors the Triage agent's scanner (and SenaniInference.JSONResultParser).
    private static func firstJSONObject(in raw: String) -> Data? {
        let chars = Array(raw)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false, i = start
        while i < chars.count {
            let ch = chars[i]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" { inString = true }
            else if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(chars[start...i]).data(using: .utf8) }
            }
            i += 1
        }
        return nil
    }
}
```

> **Note on `NSNumber`:** `JSONSerialization` boxes JSON numbers as `NSNumber`, which bridges to both `Int` and `Double` casts in Swift. The `as Int` / `as Double` cases above catch the common paths; the explicit `NSNumber` case is a belt-and-suspenders fallback. The float test (`55.7 -> 55`) and the int test (`82`) both pass through these.

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniEngine && swift test --filter LeadQualificationTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: safe LeadQualification parse (clamp score, validate intent, fallback)"
```

(Append the standard trailer.)

---

### Task 5: LeadQualifierAgent — wakesFor(Lead) + proposals (generate, parse, label + Deal upsert)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/LeadQualifierAgent.swift`
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/LeadQualifierAgentTests.swift`

The agent: `id == "lead-qualifier"`, `autonomy == .auto` (its label proposal is reversible, so the Orchestrator may auto-apply it). `wakesFor` is true **only for inbound messages the Triage agent labeled `Senani/Category/Lead`** (and not from the user, and not already lead-qualified). `proposals` builds a deterministic prompt, calls `tools.generateJSON`, parses safely, **upserts a `Deal`** into `context.pipeline`, and returns **one** reversible `proposeLabel` Action (the `Senani/Lead/<Tier>` label).

- [ ] **Step 1: Write failing agent tests**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/LeadQualifierAgentTests.swift`:

```swift
import Testing
@testable import SenaniEngine
import SenaniRules
import Foundation

private let leadLabel = "Senani/Category/Lead"

private func leadMsg(_ id: String, from: String = "buyer@acme.com",
                     subject: String = "Interested in your product",
                     body: String = "We'd like a demo and pricing.",
                     isFromUser: Bool = false,
                     extraLabels: [String] = []) -> Message {
    Message(id: id, from: from, to: ["me@x.com"], subject: subject, body: body,
            hasAttachment: false, listUnsubscribeHeader: nil,
            labels: [leadLabel] + extraLabels,
            threadId: "t-\(id)", date: Date(), isFromUser: isFromUser)
}

@Test func identityAndAutonomy() {
    let agent = LeadQualifierAgent()
    #expect(agent.id == "lead-qualifier")
    #expect(agent.autonomy == .auto)   // reversible label -> Orchestrator may auto-apply
}

@Test func wakesForLeadCategoryMessages() {
    let agent = LeadQualifierAgent()
    #expect(agent.wakesFor(leadMsg("m1"), context: ctx()) == true)
}

@Test func ignoresNonLeadMessages() {
    let agent = LeadQualifierAgent()
    let booking = Message(id: "m2", from: "x@y.com", to: ["me@x.com"], subject: "s", body: "b",
                          hasAttachment: false, listUnsubscribeHeader: nil,
                          labels: ["Senani/Category/Booking"], threadId: "t2",
                          date: Date(), isFromUser: false)
    #expect(agent.wakesFor(booking, context: ctx()) == false)
    let untriaged = Message(id: "m3", from: "x@y.com", to: ["me@x.com"], subject: "s", body: "b",
                            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
                            threadId: "t3", date: Date(), isFromUser: false)
    #expect(agent.wakesFor(untriaged, context: ctx()) == false)
}

@Test func ignoresMessagesFromTheUser() {
    let agent = LeadQualifierAgent()
    #expect(agent.wakesFor(leadMsg("m4", isFromUser: true), context: ctx()) == false)
}

@Test func ignoresAlreadyQualifiedLeads() {
    let agent = LeadQualifierAgent()
    #expect(agent.wakesFor(leadMsg("m5", extraLabels: ["Senani/Lead/Hot"]), context: ctx()) == false)
}

@Test func hotScoreEmitsHotLabelAndUpsertsQualifiedDeal() async throws {
    let store = InMemoryPipelineStore()
    let gen = FakeTextGenerator(response:
        #"{"score":88,"company":"Acme Corp","intent":"ready","reason":"wants a quote now"}"#)
    let agent = LeadQualifierAgent()
    let m = leadMsg("m1", from: "buyer@acme.com")
    let actions = try await agent.proposals(for: m, context: ctx(pipeline: store), tools: tools(gen))

    // Label: one reversible Hot label.
    #expect(actions == [.label("Senani/Lead/Hot")])
    #expect(actions[0].actionClass == .reversible)

    // Deal: upserted with the right fields.
    let deal = try #require(store.allDeals().first)
    #expect(store.allDeals().count == 1)
    #expect(deal.contactEmail == "buyer@acme.com")
    #expect(deal.stage == .qualified)
    #expect(deal.score == 88)
    #expect(deal.company == "Acme Corp")
    #expect(deal.sourceMessageId == "m1")
    #expect(deal.id == "buyer@acme.com")   // deterministic id = contact email
}

@Test func warmAndColdThresholdsMapToLabelsAndScores() async throws {
    let agent = LeadQualifierAgent()

    let warmStore = InMemoryPipelineStore()
    let warm = try await agent.proposals(for: leadMsg("w"), context: ctx(pipeline: warmStore),
        tools: tools(FakeTextGenerator(response:
            #"{"score":55,"company":"Beta","intent":"evaluating","reason":"comparing"}"#)))
    #expect(warm == [.label("Senani/Lead/Warm")])
    #expect(try warmStore.byContact("buyer@acme.com")?.score == 55)

    let coldStore = InMemoryPipelineStore()
    let cold = try await agent.proposals(for: leadMsg("c"), context: ctx(pipeline: coldStore),
        tools: tools(FakeTextGenerator(response:
            #"{"score":12,"company":"","intent":"info","reason":"newsletter-ish"}"#)))
    #expect(cold == [.label("Senani/Lead/Cold")])
    let coldDeal = try #require(coldStore.allDeals().first)
    #expect(coldDeal.score == 12)
    #expect(coldDeal.company == nil)   // blank company -> nil
}

@Test func malformedModelOutputFallsBackToColdAndStillUpserts() async throws {
    let store = InMemoryPipelineStore()
    let agent = LeadQualifierAgent()
    let actions = try await agent.proposals(for: leadMsg("m1"), context: ctx(pipeline: store),
        tools: tools(FakeTextGenerator(response: "I cannot comply </think>")))
    #expect(actions == [.label("Senani/Lead/Cold")])
    let deal = try #require(store.allDeals().first)
    #expect(deal.score == 0)
    #expect(deal.stage == .qualified)   // still recorded in the pipeline, as a cold qualified deal
}

@Test func reQualifyingSameContactUpdatesTheSameDeal() async throws {
    let store = InMemoryPipelineStore()
    let agent = LeadQualifierAgent()
    let m = leadMsg("m1", from: "buyer@acme.com")
    _ = try await agent.proposals(for: m, context: ctx(pipeline: store),
        tools: tools(FakeTextGenerator(response:
            #"{"score":30,"company":"Acme","intent":"info","reason":"early"}"#)))
    // A later message from the same contact, hotter:
    let m2 = leadMsg("m9", from: "buyer@acme.com")
    _ = try await agent.proposals(for: m2, context: ctx(pipeline: store),
        tools: tools(FakeTextGenerator(response:
            #"{"score":90,"company":"Acme","intent":"ready","reason":"wants contract"}"#)))
    #expect(store.allDeals().count == 1)               // updated, not duplicated
    let deal = try #require(store.byContact("buyer@acme.com"))
    #expect(deal.score == 90)
    #expect(deal.sourceMessageId == "m9")              // latest touch wins
}

@Test func promptIncludesMessageSignalsAndPolicy() async throws {
    let gen = FakeTextGenerator(response: #"{"score":0,"company":"","intent":"info","reason":""}"#)
    let agent = LeadQualifierAgent()
    let m = leadMsg("m1", from: "vp@bigco.com", subject: "Budget approved for Q3",
                    body: "We have $50k allocated and want to start next month.")
    _ = try await agent.proposals(for: m, context: ctx(pipeline: InMemoryPipelineStore()), tools: tools(gen))
    let prompt = try #require(gen.lastPrompt)
    #expect(prompt.contains("vp@bigco.com"))
    #expect(prompt.contains("Budget approved for Q3"))
    #expect(prompt.contains("$50k"))
    #expect(prompt.contains("0"))            // score range mentioned
    #expect(prompt.contains("100"))
    for intent in LeadIntent.allCases { #expect(prompt.contains(intent.rawValue)) }
}
```

> **Test helper note:** the tests call `store.allDeals()`. Add this convenience to `InMemoryPipelineStore` in `TestSupport.swift` (it already implements `all()`):
> ```swift
> func allDeals() -> [Deal] { (try? all()) ?? [] }
> ```
> Add that one line in this task's Step 1 alongside writing the test file.

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniEngine && swift test --filter LeadQualifierAgentTests
```

Expected: failure — `LeadQualifierAgent` undefined.

- [ ] **Step 3: Implement `LeadQualifierAgent`**

Create `Packages/SenaniEngine/Sources/SenaniEngine/Agents/LeadQualifierAgent.swift`:

```swift
import Foundation
import SenaniRules

/// Phase-3 Lead Qualifier (ROADMAP Phase 3). For every inbound message Triage
/// labeled `Senani/Category/Lead`, it scores the lead 0–100 + extracts company/intent
/// via the injected TextGenerator, emits one reversible `Senani/Lead/<Tier>` label,
/// and upserts a qualified Deal into the injected PipelineStore.
/// Pure aside from two injected seams: `tools.generateJSON` and `context.pipeline`.
public struct LeadQualifierAgent: Agent {
    public init() {}

    public var id: String { "lead-qualifier" }

    /// The label proposal is reversible, so the Orchestrator may auto-apply it.
    public var autonomy: Autonomy { .auto }

    /// The Triage category label this agent subscribes to.
    public static let leadCategoryLabel = "Senani/Category/Lead"
    private static let leadTierPrefix = "Senani/Lead/"

    /// Wakes ONLY for inbound, Triage-classified Lead messages not yet lead-qualified.
    public func wakesFor(_ message: Message, context: AgentContext) -> Bool {
        if message.isFromUser { return false }
        guard message.labels.contains(Self.leadCategoryLabel) else { return false }
        if message.labels.contains(where: { $0.hasPrefix(Self.leadTierPrefix) }) { return false }
        return true
    }

    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        let prompt = Self.buildPrompt(for: message)
        let raw = try await tools.generateJSON(prompt: prompt, schema: LeadQualification.schema)
        let qualification = LeadQualification.parse(raw)

        // Side effect 1: record the Deal in the CRM pipeline (injected seam).
        let deal = Self.makeDeal(for: message, qualification: qualification,
                                 existing: try? context.pipeline.byContact(message.from),
                                 now: context.now)
        try context.pipeline.upsert(deal)

        // Side effect 2 (via the Orchestrator): propose the reversible tier label.
        return [tools.proposeLabel(qualification.tier.label, on: message)]
    }

    /// Builds (or updates) the Deal. Deterministic id = contact email so re-qualifying the
    /// same sender updates the same Deal (upsert). Preserves an existing Deal's id/value.
    static func makeDeal(for message: Message, qualification: LeadQualification,
                         existing: Deal?, now: Date) -> Deal {
        Deal(
            id: existing?.id ?? message.from,
            contactEmail: message.from,
            company: qualification.company ?? existing?.company,
            stage: .qualified,
            score: qualification.score,
            value: existing?.value,            // qualifier does not set deal value
            lastTouch: now,
            sourceMessageId: message.id
        )
    }

    /// Deterministic prompt: fixed policy/system instruction + the message signals.
    /// Body truncated to a snippet to keep the prompt small for the on-device model.
    static func buildPrompt(for message: Message) -> String {
        let intents = LeadIntent.allCases.map(\.rawValue).joined(separator: ", ")
        let snippet = String(message.body.prefix(800))
        return """
        You are Senani's B2B lead qualifier. Score ONE inbound sales lead.
        Reply with ONLY a JSON object: \
        {"score": <integer 0-100>, "company": <the prospect's company name or "">, \
        "intent": <one of: \(intents)>, "reason": <one short sentence>}.
        Scoring guide: 70-100 = hot (ready to buy, budget/timeline clear), \
        40-69 = warm (evaluating, genuine interest), 0-39 = cold (vague, info-only, or not a real lead).
        Choose exactly one intent from the list. Do not invent fields or values.

        EMAIL
        From: \(message.from)
        Subject: \(message.subject)
        Body: \(snippet)
        """
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniEngine && swift test --filter LeadQualifierAgentTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: LeadQualifierAgent scores leads, labels tier, upserts qualified Deal"
```

(Append the standard trailer.)

---

### Task 6: Full suite green + build clean + record the §3 contract addition

**Files:**
- Edit: `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md` (record `AgentContext.pipeline` + the bootstrapped PipelineStore note)

- [ ] **Step 1: Run the entire suite**

```
cd Packages/SenaniEngine && swift test
```

Expected: ALL tests pass — `LeadQualifierAgentTests`, `LeadQualificationTests`, `LeadTierTests`, the pipeline self-test, AND every pre-existing Triage test.

- [ ] **Step 2: Build clean (no warnings under strict concurrency)**

```
cd Packages/SenaniEngine && swift build
```

Expected: builds with no errors and no `Sendable`/concurrency warnings. Resolve any before finishing. (`any PipelineStore` is `Sendable` by protocol declaration; `Deal`/`DealStage` are value `Sendable` types; the agent captures nothing mutable.)

- [ ] **Step 3: Record the §3 contract addition + bootstrap note**

In `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md`, in the §3 `AgentContext` struct, add the `pipeline` line so the Orchestrator and `pipeline-crm-view` plans code to it:

```swift
public struct AgentContext: Sendable {
    public let account: String
    public let thread: [Message]
    public let rules: [Rule]
    public let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit]
    public let now: Date
    // Added by the Lead Qualifier plan: the CRM pipeline seam for sales agents.
    // The Orchestrator injects an `any PipelineStore`; the Deal upsert is a store write,
    // NOT an ActionRouter-routable Action, so it lives here on the agent's world.
    public let pipeline: any PipelineStore
}
```

Also add a note near the `PipelineStore` seam reference (or in §3) that `DealStage`/`Deal`/`PipelineStore` are **owned by the `pipeline-crm-view` plan**; the Lead Qualifier plan **bootstrapped** signature-identical copies in `SenaniEngine/Pipeline/PipelineStore.swift` only because the owning plan had not landed, and those copies must be **deleted in favor of the real types** (imported from the owning module) once they exist — the agent depends only on the pinned signatures, so the swap is mechanical.

> **Coordination:** if the `pipeline-crm-view` plan runs concurrently, the two MUST agree that `PipelineStore`/`Deal`/`DealStage` match the pinned minimal contract exactly. Claim the `pipeline-crm-view` slug or coordinate so only ONE plan defines those types in the final tree.

- [ ] **Step 4: Final commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: Lead Qualifier green; record AgentContext.pipeline §3 addition"
```

(Append the standard trailer. The docs edit lives at repo root — stage it explicitly: `git add ../../docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md`.)

---

## Self-Review

**Scope coverage (brief):**
- **`LeadQualifierAgent: SenaniEngine.Agent`, co-located in `Packages/SenaniEngine/Sources/SenaniEngine/Agents/`** — conforms to §3 `Agent` (`id`, `autonomy`, `wakesFor`, `proposals`); co-located for the same reasons the Triage plan documented (one fewer SPM package; the contract type only lives in SenaniEngine; the Orchestrator holds agents). ✅ (Task 5)
- **wakesFor Lead-category messages** — `wakesFor` returns true ONLY for inbound, non-user messages carrying `Senani/Category/Lead` and not already `Senani/Lead/*`. Tests cover Lead (true), Booking/untriaged/from-user/already-qualified (false). ✅ (Task 5)
- **Score 0–100 + extract company/intent/budget signals via `tools.generateJSON` with a shape-constrained schema (score int, company string, intent enum-in-prompt, reason)** — `LeadQualification.schema` is an object requiring `score`(number/integer), `company`/`intent`/`reason`(string). HONEST LIMITATION recorded: `SenaniInference.JSONSchema` has **no enum/min/max** (verified `JSONSchema.swift`), so the schema constrains *shape* only; the intent enum and the 0–100 range are enforced in the prompt and re-validated/clamped in `parse`. "Budget signals" are captured by the score + the prompt's scoring guide + `reason` (there is no separate budget field in the pinned schema — kept to the four shape fields; budget influences the score). ✅ (Tasks 4, 5)
- **Parse safely with fallback** — `LeadQualification.parse` extracts the first balanced JSON object, coerces/clamps the score (Int/Double/String/NSNumber), validates intent, nils blank company; on malformed/empty/missing input returns the Cold fallback (score 0, intent .info, nil company). Never throws/crashes. Covered by malformed/empty/missing/unknown-intent/out-of-range/string-score tests. ✅ (Task 4)
- **Emit a reversible label Action `Senani/Lead/Hot|Warm|Cold`** — `proposals` returns exactly one `.label(tier.label)`, `actionClass == .reversible`; thresholds Hot ≥70 / Warm 40–69 / Cold ≤39 in `LeadTier(score:)`, tested at every boundary. ✅ (Tasks 3, 5)
- **AND upsert a `Deal` (stage `.qualified`, the score, contactEmail=sender, sourceMessageId) into the injected PipelineStore** — `proposals` builds a `Deal` via `makeDeal` (id = contact email for idempotent upsert; `contactEmail = message.from`; `stage = .qualified`; `score`; `sourceMessageId = message.id`; `lastTouch = context.now`) and calls `context.pipeline.upsert`. Tests assert all fields, re-qualification updates (not duplicates), and that a malformed-output Cold lead is still upserted. ✅ (Task 5)
- **PipelineStore reached via AgentContext (added `pipeline` accessor) and FLAGGED as a §3 SenaniEngine contract addition** — DECISION: `AgentContext.pipeline: any PipelineStore` (not an `AgentTools` builder), because the upsert is a store write, not an `ActionRouter`-routable Action, and `AgentTools` is established (Triage plan) as pure Action builders + the single `generateJSON` seam. Recorded in §3 (Task 6). Single addition; flagged. ✅
- **PipelineStore pinned MINIMAL contract** — `DealStage`/`Deal`/`PipelineStore` coded EXACTLY to the pin (synchronous `throws` methods, the six DealStage cases, all Deal fields). Bootstrapped in `Pipeline/PipelineStore.swift` because the owning `pipeline-crm-view` plan hasn't landed; flagged for deletion/import-swap when it does. The only thing beyond the pin (the `Deal.id = contactEmail` derivation) is FLAGGED as a mechanical change point. ✅ (Tasks 1, 6)
- **TESTS (pure): canned JSON → correct score→label mapping (hot/warm/cold) + Deal upserted with right fields (in-memory PipelineStore fake); malformed JSON → safe fallback (cold, no crash); agent ignores non-Lead messages. No MLX.** — `LeadQualifierAgentTests` covers hot/warm/cold label+score, Deal fields, re-qualify-updates, malformed→Cold-still-upserts, and the four ignore cases; `LeadQualificationTests`/`LeadTierTests` cover parse/clamp/threshold edges. Local `FakeTextGenerator` + `InMemoryPipelineStore` only — no MLX/Gmail/UI anywhere. ✅ (Tasks 2–5)

**Conventions (APP-PLANS-RECONCILIATION §4):** Agent is pure except the two injected seams (`tools.generateJSON`, `context.pipeline`) — no direct store/Gmail/Keychain access. One safety path preserved: the tier label is a reversible Action routed by the Orchestrator via `ActionRouter`; the Deal upsert is a non-mail store write that touches no `MailBackend`/approval path. macOS 14, Swift 6.0 tools, strict concurrency, Swift Testing. TDD with bite-sized commits and complete code; no placeholders.

**Contracts exposed / changed by this plan:**
- `SenaniEngine.AgentContext.pipeline: any PipelineStore` (the flagged §3 addition)
- `SenaniEngine.DealStage` / `Deal` / `PipelineStore` (bootstrap of the `pipeline-crm-view`-owned pin; to be deleted when the owner ships)
- `LeadIntent` (`.evaluating/.ready/.info/.spam`, `.parse`)
- `LeadTier` (`.hot/.warm/.cold`, `init(score:)`, `.label`)
- `LeadQualification` (`schema`, `schemaJSON`, `parse`, `tier`)
- `LeadQualifierAgent` (`init()`, `id`, `autonomy`, `wakesFor`, `proposals`, `leadCategoryLabel`)

**Risks / assumptions to confirm with the human before/while coding:**
1. **`SenaniEngine` must already exist (Triage plan)** — this plan extends it. If absent, bootstrap per Triage Tasks 1–2 first; coordinate on the `senani-engine` claim slug so the contract files (`Agent`/`AgentContext`/`AgentTools`) are not double-defined.
2. **`AgentContext.pipeline` §3 addition** — must be reflected in APP-PLANS-RECONCILIATION §3 in the same commit (Task 6) so the Orchestrator (which constructs `AgentContext`) and `pipeline-crm-view` plans code to it. The Orchestrator MUST inject a real `PipelineStore` when building contexts.
3. **`PipelineStore`/`Deal`/`DealStage` ownership** — owned by `pipeline-crm-view`. This plan bootstraps signature-identical copies; if that plan ships first (or concurrently), import its types and DELETE the bootstrap — never two definitions in the final tree. Coordinate.
4. **`Deal.id = contactEmail`** — chosen so `upsert` + `byContact` de-duplicate per contact. If `pipeline-crm-view` mandates UUID ids, change only `makeDeal` (read `byContact` for the existing id, else `UUID().uuidString`). FLAGGED.
5. **No "budget" field in the pinned `Deal`/schema** — "budget signals" are folded into the score (prompt scoring guide) and `reason`, not a dedicated field, to stay within the pinned four-field shape and the pinned `Deal`. If a structured budget is later required, it is a change to the `pipeline-crm-view`-owned `Deal` + this schema — FLAGGED, not silently added.
6. **`JSONSchema` has no enum/min/max (confirmed from source)** — if `SenaniInference` later gains them, tighten `schemaJSON` to pin intent + the 0–100 range; the `parse` clamp/validate stays as defense-in-depth.
7. **Synchronous `PipelineStore` inside `async proposals`** — the pinned methods are sync `throws`; the agent calls them directly. If the real store is `async`, the call sites get `await` and `makeDeal` is unaffected. FLAGGED.
