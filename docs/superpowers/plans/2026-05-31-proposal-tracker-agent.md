# Proposal Tracker Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the **Proposal Tracker Agent** — a pure `SenaniEngine.Agent` (Phase 3, Pro sales suite) that keeps the sales **pipeline** in step with proposal/quote email. It wakes for (a) **outbound** proposal/quote mail (the user emailing a client a proposal — detected via an attached document's extracted fields or subject/body cues) and (b) **inbound replies on a thread that already tracks a Deal**. When a proposal is detected it moves (or creates) the contact's `Deal` to stage `.proposal`, recording any value extracted from the document. When an inbound reply lands on a tracked thread, it asks the model (via `generateJSON`) for an accept/decline/ambiguous classification and updates the Deal to `.won` / `.lost` / `.negotiation`. **Stage transitions are PURE writes to `PipelineStore`** (reached through `AgentContext.pipeline`, exactly like the Lead Qualifier); the only `Action` the agent ever emits is an **outbound nudge reply**, which — being `ActionClass.outbound` — `ActionRouter` ALWAYS routes to the approval queue and is never auto-sent. Fully unit-tested with a local prompt-fixed `FakeTextGenerator`, an in-memory `PipelineStore`, and an in-memory `MessageStore`; no MLX, no Gmail, no network.

**Architecture:** `ProposalTrackerAgent` conforms to `SenaniEngine.Agent` (the §3 contract from [`2026-05-31-APP-PLANS-RECONCILIATION.md`](2026-05-31-APP-PLANS-RECONCILIATION.md)) and is **co-located in `Packages/SenaniEngine/Sources/SenaniEngine/Agents/`** alongside the `Agent`/`AgentContext`/`AgentTools` definitions, matching the Triage and Reply Drafter agents' co-location decision (see *Cross-package assumptions* → **SenaniEngine dependency**). The agent is split into three pure, independently-testable collaborators:

1. **`ProposalDetector`** — a pure function `(Message, AgentContext) -> ProposalSignal?` deciding whether an **outbound** message is a proposal/quote, using (i) document fields surfaced on `AgentContext` (a `documentFields: [String: String]` field this plan adds, populated by the Orchestrator from `SenaniDocs.DocumentExtractor`) and (ii) subject/body keyword cues. It also extracts a numeric `value` from the document fields / body when present.
2. **`ReplyIntentClassifier`** — wraps an injected `TextGenerator.generateJSON` call against a tiny fixed `JSONSchema` (`{ intent: "accept"|"decline"|"negotiate"|"other" }`) to classify an **inbound** reply on a tracked thread, mapping intent → `DealStage`.
3. **`ProposalTrackerAgent`** — the `Agent`: `wakesFor` is the pure trigger predicate; `proposals(for:context:tools:)` performs the `PipelineStore` upsert (pure pipeline write, no `Action`) and optionally returns one outbound nudge `Action`.

The agent reaches the pipeline through a new **`AgentContext.pipeline: any PipelineStore`** field (the same mechanism the Lead Qualifier plan uses; this plan introduces it additively and flags it to the orchestrator owner). `PipelineStore` lives in `SenaniEngine` as the shared CRM seam pinned below (the **pipeline-crm-view plan is authoritative for `PipelineStore`/`Deal`/`DealStage`**; this plan codes to that exact seam and, if it already exists on disk, reuses it verbatim). Stage updates never touch Gmail and never create a new `Action`; the only emitted `Action` is `tools.draftReply(...)` → `SenaniRules.Action.reply(body:)` (outbound, always queues).

**Tech Stack:** Swift 6.2, `swift-tools-version: 6.0`, macOS 14, strict concurrency (complete), Swift Testing (`import Testing`). Path deps (already on `SenaniEngine`): `../SenaniRules`, `../SenaniStore`, `../SenaniInference`, `../SenaniVoice`.

**Working directory:** All `swift` commands run from `/Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine` unless stated otherwise.

**Out of scope (separate plans):** the Orchestrator/Scheduler/AgentRegistry runtime and the live wiring that populates `AgentContext.documentFields` from `SenaniDocs.DocumentPipeline`/`DocumentExtractor` and constructs the live `PipelineStore` (orchestrator + live-store-bootstrap plans); the concrete persistent `PipelineStore` (GRDB-backed, owned by the pipeline-crm-view / persistence plan); the Pipeline / CRM SwiftUI view (its own Phase-3 UI plan); the Lead Qualifier agent (its own plan, co-owner of `PipelineStore`/`AgentContext.pipeline`); executing an approved nudge into Gmail (`GmailMailBackend`, Approval-queue UI plan); the real MLX `TextGenerator` (inference plan).

---

## Cross-package assumptions (verified from source — state to the human before coding)

### `SenaniEngine` dependency — co-location decision (FLAG TO HUMAN)
`Packages/SenaniEngine` may or may not exist when this plan runs (verified ABSENT at authoring time; the Triage / Reply Drafter / orchestrator plans also scaffold it). Per §3 of the reconciliation doc, `SenaniEngine` is a NEW app-tier package owning `Agent`, `AgentContext`, `AgentTools`, `AgentRegistry`, `Orchestrator`, `Scheduler`. The Proposal Tracker is **co-located inside `SenaniEngine`** (same package as the protocol + the other agents), in an `Agents/` subfolder.

- **If `SenaniEngine` already exists** when this plan runs: do NOT recreate the package or redefine `Agent`/`AgentContext`/`AgentTools`. Skip Task 1's package scaffold and Task 2's contract file; instead **verify** the on-disk `Agent`/`AgentContext`/`AgentTools` match the §3 signatures pinned below and that `AgentContext` already carries (or you add, additively) `pipeline` and `documentFields`. Then add only the new `Agents/`, `Pipeline/`, and test files.
- **If `SenaniEngine` does not exist** (this plan runs first): Tasks 1–2 scaffold the package and define the §3 contracts + `PipelineStore` so the agent compiles and is testable today. The other agent/orchestrator plans then build on these exact files. **This is a shared-file coordination point** — flag it to the human so two plans do not both scaffold `SenaniEngine`.

### `PipelineStore` / `Deal` / `DealStage` — the CRM seam this plan PINS (pipeline-crm-view plan is AUTHORITATIVE)
This plan codes to the same `PipelineStore` seam the Lead Qualifier and the Pipeline / CRM view plan use. If `Packages/SenaniEngine/Sources/SenaniEngine/Pipeline/PipelineStore.swift` already exists, **reuse it verbatim** and skip Task 3. Otherwise Task 3 creates it exactly as pinned:

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

> `DealStage` and `PipelineStore` are **synchronous, non-throwing-where-noted** per the pin (methods are `throws`, not `async`). The Deal's `id` convention used by both agents: a deal is keyed by `contactEmail` (one open deal per contact), so the agent looks up `byContact(_:)` first and reuses the found deal's `id`, else mints `id = contactEmail`. This keeps the Lead Qualifier and Proposal Tracker pointing at the same Deal row. (If the pipeline-crm-view plan pins a different id convention, follow that and record the deviation.)

### `SenaniRules` (built + frozen, do NOT edit — verified `Action.swift`)
- `public struct Message: Sendable, Equatable, Identifiable` with `id, from, to:[String], subject, body, hasAttachment, listUnsubscribeHeader, labels, threadId, date, isFromUser` and computed `var senderDomain: String` (`Message.swift`).
- `public enum Action: Sendable, Equatable` — verified cases: `.label`, `.archive`, `.markRead`, `.markUnread`, `.star`, `.unstar`, `.move`, `.flagNeedsReply`, `.fileAttachment`, `.parseDoc`, `.runAgent`, `.draft(body:)`, `.reply(body:)`, `.forward(to:body:)`, `.send(body:)`, `.markSpam`, `.localWebhook`. **There is NO `.proposal`/stage Action** — pipeline stage is NOT an `Action`; it is a `PipelineStore` write.
- `extension Action { public var actionClass: ActionClass }` — verified `.reply`/`.forward`/`.send`/`.markSpam` are `.outbound`; everything else `.reversible`.
- `public enum ActionClass: Sendable, Equatable { case reversible; case outbound }`. The Orchestrator's `ActionRouter.route` queues all outbound actions regardless of autonomy (the nudge reply therefore always queues).

### `SenaniInference` (built + frozen, NO fakes shipped — verified)
- `public protocol TextGenerator: Sendable { func generate(prompt: String, maxTokens: Int) async throws -> String; func generateJSON(prompt: String, schema: JSONSchema) async throws -> String }` (`TextGenerator.swift`).
- `public indirect enum JSONSchema: Sendable, Equatable { case boolean; case string; case number; case array(element:); case object(properties:required:) }` with `init(json:)` and `static func boolArrayResults(key:)` (`JSONSchema.swift`). This plan builds the intent schema with `.object(properties: ["intent": .string], required: ["intent"])`.
- **No `FakeTextGenerator` exists.** This plan defines its own canned-response fake in the test target (Task 4).

### `SenaniDocs` (built + frozen — verified `DocumentExtractor.swift` / `ParsedDocument.swift`)
- `public struct DocumentExtractor: Sendable { public init(generator: any TextGenerator); public func extract(from document: ParsedDocument) async throws -> ExtractedFields }`.
- `public struct ExtractedFields: Codable, Sendable, Equatable { public var fields: [String: String] }` — a flat `[String: String]` of extracted business fields (e.g. `"total"`, `"amount"`, `"quote_total"`).
- `public struct ParsedDocument: Sendable, Equatable { id; messageId; filename; kind; text }`.
- **The agent never runs `DocumentExtractor` itself** (§4 convention: agents are pure; the Orchestrator pre-populates context). The extracted fields reach the agent through **`AgentContext.documentFields: [String: String]`**, which the Orchestrator sets by running `DocumentPipeline`/`DocumentExtractor` over the message's attachment(s) before invoking the agent. This `documentFields` field is the **SenaniEngine contract addition** this plan introduces (Task 2) — flag it to the orchestrator-plan owner.

### `SenaniStore.MessageStore` (built + frozen — verified)
- `public struct MessageStore: Sendable { init(database:); save; saveAll; fetch(id:) -> Message?; thread(id:) -> [Message]; query(from:to:isFromUser:limit:) -> [Message]; all() -> [Message] }` — all **synchronous `throws`**, NOT async.
- **The agent never reads `MessageStore` directly.** The thread it needs is already on `AgentContext.thread` (date asc). The in-memory `MessageStore` referenced by the brief's test list is used only to seed the thread the Orchestrator would pass; in these pure tests we build `AgentContext.thread` directly. (A `FakeMessageReading` port is provided in test support for completeness / future thread lookups, mirroring the SenaniAssistant pattern, but the agent depends only on `AgentContext`.)

### `AgentContext` / `AgentTools` / `Agent` — §3 signatures this plan PINS (+ two additive fields)
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
    public let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit]
    public let now: Date
    public let pipeline: any PipelineStore          // ⚠ ADDITION (Lead Qualifier + this plan): CRM seam
    public let documentFields: [String: String]     // ⚠ ADDITION (this plan): SenaniDocs extracted fields for the message
}
public struct AgentTools: Sendable {
    public func draftReply(to message: Message, body: String) -> Action   // → Action.reply (outbound, always queues)
    public func proposeLabel(_ label: String, on message: Message) -> Action
    public func archive(_ message: Message) -> Action
    public func markRead(_ message: Message) -> Action
}
```
`Rule` / `Autonomy` / `Message` / `Action` come from `SenaniRules`; `VectorHit` from `SenaniStore`.

> **If `AgentContext` already exists WITHOUT `pipeline` / `documentFields`:** add each as a defaulted initializer member (`pipeline: any PipelineStore = NullPipelineStore()`, `documentFields: [String: String] = [:]`) so existing call sites still compile, and record it as an additive, non-breaking SenaniEngine contract change in the commit body. (Task 3 ships a `NullPipelineStore` no-op default for exactly this reason — see below.) If a prior agent plan already added `pipeline`, **reuse it** and add only `documentFields`.

---

## File Structure

```
Packages/SenaniEngine/
  Package.swift                                       # (Task 1 — only if SenaniEngine absent)
  Sources/SenaniEngine/
    AgentContract.swift                               # (Task 2) Agent, AgentContext (+pipeline,+documentFields), AgentTools
    Pipeline/
      PipelineStore.swift                             # (Task 3) Deal, DealStage, PipelineStore + NullPipelineStore default
    Agents/
      ProposalDetector.swift                          # (Task 5) pure outbound proposal/quote detection + value extraction
      ReplyIntentClassifier.swift                     # (Task 6) generateJSON intent → DealStage
      ProposalTrackerAgent.swift                       # (Task 7) the Agent: wakesFor + proposals (pipeline upsert + optional nudge)
  Tests/SenaniEngineTests/
    ProposalTracker/
      ProposalTrackerFixtures.swift                   # (Task 4) Message/thread/Deal builders + AgentContext factory
      InMemoryPipelineStore.swift                     # (Task 4) in-memory PipelineStore for tests
      FakeJSONGenerator.swift                          # (Task 4) canned-JSON TextGenerator (+ prompt recording)
      ProposalDetectorTests.swift                     # (Task 5)
      ReplyIntentClassifierTests.swift                # (Task 6)
      ProposalTrackerWakesForTests.swift              # (Task 7)
      ProposalTrackerProposalsTests.swift             # (Task 7)
```

> If `SenaniEngine` already exists, only the `Pipeline/PipelineStore.swift` (if absent), the `Agents/` files, and the `ProposalTracker/` test folder are added; the `AgentContract.swift` edit is limited to the two additive fields (if not already present).

---

## Task 1 — Package scaffold (skip if `SenaniEngine` already exists)

**Files:**
- Create: `Packages/SenaniEngine/Package.swift`
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/AgentContract.swift` (temporary one-line marker)

- [ ] **First, check whether the package exists:**

```
ls /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine 2>/dev/null && echo EXISTS || echo ABSENT
```
- **If `EXISTS`:** skip Tasks 1 and 2 (do the §3 verification described in Cross-package assumptions and the additive-field check in Task 2), and jump to Task 3.
- **If `ABSENT`:** continue.

- [ ] Create `Packages/SenaniEngine/Package.swift` with exactly:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniEngine", targets: ["SenaniEngine"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
        .package(path: "../SenaniStore"),
        .package(path: "../SenaniInference"),
        .package(path: "../SenaniVoice"),
    ],
    targets: [
        .target(
            name: "SenaniEngine",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "SenaniStore", package: "SenaniStore"),
                .product(name: "SenaniInference", package: "SenaniInference"),
                .product(name: "SenaniVoice", package: "SenaniVoice"),
            ]
        ),
        .testTarget(
            name: "SenaniEngineTests",
            dependencies: ["SenaniEngine"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

- [ ] Create a temporary marker `Packages/SenaniEngine/Sources/SenaniEngine/AgentContract.swift`:

```swift
enum SenaniEnginePlaceholder {}
```

- [ ] **Run-to-resolve:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift build`
  - **Expected:** builds clean (empty library). If a sibling path dependency fails to resolve, STOP and report which is missing — do NOT fake it.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git init -q 2>/dev/null; git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: package scaffold with engine-package path deps

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2 — Agent contract types (Agent / AgentContext / AgentTools) (skip if already defined)

**Files:**
- Replace: `Packages/SenaniEngine/Sources/SenaniEngine/AgentContract.swift`
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/ProposalTracker/AgentContractContractTests.swift`

> If `SenaniEngine` already defines `Agent`/`AgentContext`/`AgentTools` (Task 1 said `EXISTS`): do NOT redefine them. If `AgentContext` is **missing `pipeline` and/or `documentFields`**, add only those fields (defaulted, as the §3 note describes) and skip the rest of this task. The `PipelineStore` type referenced here is created in Task 3 — if you are editing an existing `AgentContext`, do Task 3 first so `PipelineStore` exists.

- [ ] **Write failing test** `Packages/SenaniEngine/Tests/SenaniEngineTests/ProposalTracker/AgentContractContractTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct AgentContractContractTests {
    private func msg() -> Message {
        Message(
            id: "m1", from: "sarah@client.com", to: ["ramesh@quantana.in"],
            subject: "Proposal", body: "Please find the proposal attached.",
            hasAttachment: true, listUnsubscribeHeader: nil, labels: [],
            threadId: "t1", date: Date(timeIntervalSince1970: 1_000_000), isFromUser: true
        )
    }

    @Test func draftReplyProducesAnOutboundReplyAction() {
        let tools = AgentTools()
        let action = tools.draftReply(to: msg(), body: "Following up on our proposal.")
        #expect(action == .reply(body: "Following up on our proposal."))
        #expect(action.actionClass == .outbound)   // ⇒ ActionRouter ALWAYS queues it
    }

    @Test func agentContextCarriesPipelineAndDocumentFields() {
        let ctx = AgentContext(
            account: "ramesh@quantana.in", thread: [msg()], rules: [],
            retrieve: { _, _ in [] }, now: Date(timeIntervalSince1970: 1_000_000),
            pipeline: InMemoryPipelineStore(),
            documentFields: ["total": "12000"]
        )
        #expect(ctx.documentFields["total"] == "12000")
        #expect((try? ctx.pipeline.all())?.isEmpty == true)
    }
}
```

> `InMemoryPipelineStore` is defined in Task 4. If you reach this test before Task 4, substitute `NullPipelineStore()` (Task 3) in the `pipeline:` argument and assert `((try? ctx.pipeline.all()) ?? []).isEmpty`.

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter AgentContractContractTests`
  - **Expected:** compile error — `AgentTools` / `AgentContext` not in scope (or, if they exist, the new fields are missing).

- [ ] **Implement** `AgentContract.swift` (replace the placeholder; if the package already had this file, add ONLY the two new fields):

```swift
import Foundation
import SenaniRules
import SenaniStore

/// An agent is a pure function from (message, context, tools) → proposed Actions.
/// It NEVER touches Gmail or stores directly; the Orchestrator enforces autonomy and routes
/// every returned Action through `ActionRouter` + the MailBackend/ApprovalStore/AuditLog seams.
public protocol Agent: Sendable {
    /// Stable identity, e.g. "triage", "reply-drafter", "proposal-tracker".
    var id: String { get }
    /// Per-agent dial; the Orchestrator (not the agent) enforces it.
    var autonomy: Autonomy { get }
    /// Pure trigger predicate.
    func wakesFor(_ message: Message, context: AgentContext) -> Bool
    /// Pure proposal builder (its only I/O is the injected generator the agent holds + the
    /// pipeline writes it performs through `context.pipeline`).
    func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action]
}

/// Read-only world an agent may see. Pre-populated by the Orchestrator; agents never query stores.
public struct AgentContext: Sendable {
    public let account: String
    public let thread: [Message]            // the message's thread, date ascending
    public let rules: [Rule]
    public let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit]
    public let now: Date
    /// The sales pipeline / CRM seam. Pre-populated by the Orchestrator from the live store.
    /// ADDITIVE SenaniEngine field shared by the Lead Qualifier + Proposal Tracker agents.
    public let pipeline: any PipelineStore
    /// Business fields the Orchestrator extracted from the message's attachment(s) via
    /// SenaniDocs.DocumentExtractor (flat key→value). Empty when there is no parsed document.
    /// ADDITIVE SenaniEngine field introduced by the Proposal Tracker plan.
    public let documentFields: [String: String]

    public init(
        account: String,
        thread: [Message],
        rules: [Rule],
        retrieve: @escaping @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit],
        now: Date,
        pipeline: any PipelineStore = NullPipelineStore(),
        documentFields: [String: String] = [:]
    ) {
        self.account = account
        self.thread = thread
        self.rules = rules
        self.retrieve = retrieve
        self.now = now
        self.pipeline = pipeline
        self.documentFields = documentFields
    }
}

/// Pure builders that return an `Action` — they do NOT execute anything.
public struct AgentTools: Sendable {
    public init() {}

    /// A reply addressed back into the thread. Maps to `Action.reply(body:)`, whose
    /// `actionClass == .outbound`, so `ActionRouter` ALWAYS routes it to the approval queue.
    public func draftReply(to message: Message, body: String) -> Action { .reply(body: body) }

    public func proposeLabel(_ label: String, on message: Message) -> Action { .label(label) }
    public func archive(_ message: Message) -> Action { .archive }
    public func markRead(_ message: Message) -> Action { .markRead }
}
```

> **Coordination note for the worker:** if another agent plan (Reply Drafter) already added an `AgentContext.needsReply: Bool` field, keep it — just add `pipeline` and `documentFields` alongside it (all defaulted). The initializer parameter order is not part of the pinned contract; callers use labels.

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter AgentContractContractTests`
  - **Expected:** 2 tests pass (after Task 3 + Task 4 types exist; if running strictly in order, this task's test compiles only once `PipelineStore`/`NullPipelineStore` exist — do Task 3 next, then re-run). For a clean TDD order, you may move the `agentContextCarriesPipelineAndDocumentFields` assertion's first run to the end of Task 3.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: Agent/AgentContext/AgentTools §3 contract (+pipeline,+documentFields)

AgentContext gains the shared PipelineStore seam and SenaniDocs documentFields,
both additive and defaulted so existing call sites still compile.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3 — PipelineStore / Deal / DealStage seam (skip if already on disk)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Pipeline/PipelineStore.swift`
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/ProposalTracker/PipelineSeamTests.swift`

> **If `Packages/SenaniEngine/Sources/SenaniEngine/Pipeline/PipelineStore.swift` already exists** (the pipeline-crm-view or Lead Qualifier plan landed first): do NOT recreate it. Verify it matches the pinned seam; if it differs, adapt the agent to the real seam and record the deviation. Then skip to Task 4.

This is the **authoritative seam pinned in the plan header**. The `NullPipelineStore` is a no-op default so `AgentContext` can be constructed without a real store (previews, tests, and agents that ignore the pipeline).

- [ ] **Write failing test** `Packages/SenaniEngine/Tests/SenaniEngineTests/ProposalTracker/PipelineSeamTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine

@Suite struct PipelineSeamTests {
    @Test func dealStageRawValuesAreStable() {
        #expect(DealStage.new.rawValue == "new")
        #expect(DealStage.qualified.rawValue == "qualified")
        #expect(DealStage.proposal.rawValue == "proposal")
        #expect(DealStage.negotiation.rawValue == "negotiation")
        #expect(DealStage.won.rawValue == "won")
        #expect(DealStage.lost.rawValue == "lost")
    }

    @Test func dealIsConstructibleWithThePinnedShape() {
        let deal = Deal(
            id: "sarah@client.com", contactEmail: "sarah@client.com", company: "Client Inc",
            stage: .proposal, score: 80, value: 12000, lastTouch: Date(timeIntervalSince1970: 1),
            sourceMessageId: "m1"
        )
        #expect(deal.stage == .proposal)
        #expect(deal.value == 12000)
    }

    @Test func nullPipelineStoreIsANoOp() throws {
        let store: any PipelineStore = NullPipelineStore()
        try store.upsert(Deal(id: "x", contactEmail: "x@y.com", company: nil, stage: .new,
                              score: nil, value: nil, lastTouch: Date(), sourceMessageId: nil))
        #expect(try store.all().isEmpty)
        #expect(try store.byContact("x@y.com") == nil)
        #expect(try store.fetch(id: "x") == nil)
        #expect(try store.byStage(.new).isEmpty)
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter PipelineSeamTests`
  - **Expected:** compile error — `DealStage` / `Deal` / `PipelineStore` / `NullPipelineStore` not in scope.

- [ ] **Implement** `Sources/SenaniEngine/Pipeline/PipelineStore.swift`:

```swift
import Foundation

/// The sales pipeline stages a Deal moves through. RawValue strings are the persisted form
/// (the GRDB-backed store and the CRM view both rely on these stable strings).
public enum DealStage: String, Sendable {
    case new
    case qualified
    case proposal
    case negotiation
    case won
    case lost
}

/// One opportunity in the pipeline, keyed (by convention) on the contact's email so the
/// Lead Qualifier and Proposal Tracker operate on the same row.
public struct Deal: Sendable, Identifiable {
    public var id: String
    public var contactEmail: String
    public var company: String?
    public var stage: DealStage
    public var score: Int?
    public var value: Double?
    public var lastTouch: Date
    public var sourceMessageId: String?

    public init(
        id: String,
        contactEmail: String,
        company: String?,
        stage: DealStage,
        score: Int?,
        value: Double?,
        lastTouch: Date,
        sourceMessageId: String?
    ) {
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

/// Persistence seam for the CRM pipeline. The live implementation (GRDB-backed) is owned by the
/// pipeline-crm-view / persistence plan; agents and tests depend only on this protocol.
public protocol PipelineStore: Sendable {
    func upsert(_ deal: Deal) throws
    func fetch(id: String) throws -> Deal?
    func byContact(_ email: String) throws -> Deal?
    func all() throws -> [Deal]
    func byStage(_ stage: DealStage) throws -> [Deal]
}

/// No-op default so an `AgentContext` can be built without a real pipeline (previews / agents
/// that do not touch the pipeline). Every read returns empty/nil; `upsert` discards.
public struct NullPipelineStore: PipelineStore {
    public init() {}
    public func upsert(_ deal: Deal) throws {}
    public func fetch(id: String) throws -> Deal? { nil }
    public func byContact(_ email: String) throws -> Deal? { nil }
    public func all() throws -> [Deal] { [] }
    public func byStage(_ stage: DealStage) throws -> [Deal] { [] }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter PipelineSeamTests`
  - **Expected:** all 3 pass. Now also re-run `AgentContractContractTests` (Task 2) — both should pass.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: PipelineStore/Deal/DealStage CRM seam + NullPipelineStore default

Authoritative seam pinned by the pipeline-crm-view plan; shared by Lead Qualifier
and Proposal Tracker. NullPipelineStore is the no-op AgentContext default.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4 — Proposal Tracker fixtures, in-memory PipelineStore, canned-JSON fake generator

**Files:**
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/ProposalTracker/InMemoryPipelineStore.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/ProposalTracker/FakeJSONGenerator.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/ProposalTracker/ProposalTrackerFixtures.swift`

`SenaniInference` ships no fakes and there is no concrete in-memory `PipelineStore`, so we define our own test doubles. No `@Test` here except a self-test on the doubles.

- [ ] **Create** `InMemoryPipelineStore.swift`:

```swift
import Foundation
@testable import SenaniEngine

/// In-memory PipelineStore for tests. Keyed by Deal.id; byContact scans contactEmail.
final class InMemoryPipelineStore: PipelineStore, @unchecked Sendable {
    private let lock = NSLock()
    private var deals: [String: Deal] = [:]

    init(_ seed: [Deal] = []) {
        for d in seed { deals[d.id] = d }
    }

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
        return deals.values.first { $0.contactEmail.caseInsensitiveCompare(email) == .orderedSame }
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
```

- [ ] **Create** `FakeJSONGenerator.swift` (local fake conforming to `SenaniInference.TextGenerator`):

```swift
import Foundation
import SenaniInference

/// A local canned-response TextGenerator. SenaniInference ships no fakes, so we define one.
/// `generateJSON` returns a fixed JSON string and records every prompt it was asked, so tests can
/// assert the classifier threaded the reply text into the prompt. `generate` is unused here.
final class FakeJSONGenerator: TextGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private let cannedJSON: String
    private var prompts: [String] = []

    init(cannedJSON: String) { self.cannedJSON = cannedJSON }

    func generate(prompt: String, maxTokens: Int) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        prompts.append(prompt)
        return ""
    }

    func generateJSON(prompt: String, schema: JSONSchema) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        prompts.append(prompt)
        return cannedJSON
    }

    var recordedPrompts: [String] { lock.lock(); defer { lock.unlock() }; return prompts }
    var lastPrompt: String? { recordedPrompts.last }
}
```

- [ ] **Create** `ProposalTrackerFixtures.swift` (shared builders, no `@Test`):

```swift
import Foundation
@testable import SenaniEngine
import SenaniRules

enum PT {
    static let account = "ramesh@quantana.in"
    static let client = "sarah@client.com"
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// An OUTBOUND proposal email the user sent to a client, with an attached doc.
    static func outboundProposal(
        id: String = "m-out",
        to: [String] = [client],
        subject: String = "Our proposal for the Q3 engagement",
        body: String = "Hi Sarah,\n\nPlease find our proposal attached. Happy to discuss.\n\nRamesh",
        hasAttachment: Bool = true,
        threadId: String = "t1",
        date: Date = now
    ) -> Message {
        Message(
            id: id, from: account, to: to, subject: subject, body: body,
            hasAttachment: hasAttachment, listUnsubscribeHeader: nil, labels: [],
            threadId: threadId, date: date, isFromUser: true
        )
    }

    /// An INBOUND reply from the client on the same thread.
    static func inboundReply(
        id: String = "m-reply",
        from: String = client,
        subject: String = "Re: Our proposal for the Q3 engagement",
        body: String,
        threadId: String = "t1",
        date: Date = now.addingTimeInterval(3600)
    ) -> Message {
        Message(
            id: id, from: from, to: [account], subject: subject, body: body,
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: threadId, date: date, isFromUser: false
        )
    }

    /// A plain outbound message that is NOT a proposal (no attachment, no cues).
    static func ordinaryOutbound(threadId: String = "t9") -> Message {
        Message(
            id: "m-ord", from: account, to: [client], subject: "Lunch next week?",
            body: "Are you free Tuesday?", hasAttachment: false, listUnsubscribeHeader: nil,
            labels: [], threadId: threadId, date: now, isFromUser: true
        )
    }

    static func dealAt(_ stage: DealStage, contact: String = client, value: Double? = nil) -> Deal {
        Deal(id: contact, contactEmail: contact, company: nil, stage: stage,
             score: nil, value: value, lastTouch: now.addingTimeInterval(-86400), sourceMessageId: "seed")
    }

    /// Builds an AgentContext with the given thread, pipeline, and extracted document fields.
    static func context(
        thread: [Message],
        pipeline: any PipelineStore,
        documentFields: [String: String] = [:]
    ) -> AgentContext {
        AgentContext(
            account: account, thread: thread, rules: [],
            retrieve: { _, _ in [] }, now: now,
            pipeline: pipeline, documentFields: documentFields
        )
    }
}
```

- [ ] **Add a self-test** at the bottom of `InMemoryPipelineStore.swift`:

```swift
import Testing

@Suite struct ProposalTrackerSupportTests {
    @Test func inMemoryPipelineRoundTrips() throws {
        let store = InMemoryPipelineStore([PT.dealAt(.qualified)])
        #expect(try store.byContact(PT.client)?.stage == .qualified)
        var d = try #require(try store.byContact(PT.client))
        d.stage = .proposal
        try store.upsert(d)
        #expect(try store.byStage(.proposal).count == 1)
        #expect(try store.byStage(.qualified).isEmpty)
    }
}
```

- [ ] **Run-to-build:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter ProposalTrackerSupportTests`
  - **Expected:** the self-test passes; fixtures + fakes compile.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: Proposal Tracker test doubles — in-memory PipelineStore, canned-JSON fake, fixtures

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5 — ProposalDetector (pure outbound proposal/quote detection + value extraction)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/ProposalDetector.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/ProposalTracker/ProposalDetectorTests.swift`

`ProposalDetector` is a pure (non-async, no I/O) function. It only fires for **outbound** messages (`isFromUser == true`). It detects a proposal via: an attached document whose `documentFields` look like a proposal/quote (a value-bearing key present), OR subject/body keyword cues ("proposal", "quote", "quotation", "estimate", "statement of work", "sow"). It extracts a numeric `value` from `documentFields` (preferring keys like `total`, `amount`, `value`, `price`, `quote_total`, `grand_total`) and falls back to the first currency-looking number in the body.

- [ ] **Write failing tests** `ProposalDetectorTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct ProposalDetectorTests {
    private let detector = ProposalDetector()

    @Test func detectsProposalFromAttachedDocFieldsAndExtractsValue() {
        let m = PT.outboundProposal()
        let signal = detector.detect(m, documentFields: ["total": "$12,000.00", "client": "Client Inc"])
        let s = try? #require(signal)
        #expect(s?.value == 12000)
    }

    @Test func detectsProposalFromSubjectCueWithoutDoc() {
        let m = PT.outboundProposal(subject: "Quotation for website redesign", hasAttachment: false)
        let signal = detector.detect(m, documentFields: [:])
        #expect(signal != nil)
        #expect(signal?.value == nil)   // no doc fields, no currency in body
    }

    @Test func extractsValueFromBodyWhenNoDocField() {
        let m = PT.outboundProposal(
            subject: "Our proposal",
            body: "Hi Sarah, our proposal comes to $8,500 total. Best, Ramesh",
            hasAttachment: false)
        let signal = detector.detect(m, documentFields: [:])
        #expect(signal?.value == 8500)
    }

    @Test func ignoresInboundMessages() {
        // A reply FROM the client is not an outbound proposal, even with proposal words.
        let m = PT.inboundReply(body: "Thanks for the proposal!")
        #expect(detector.detect(m, documentFields: ["total": "999"]) == nil)
    }

    @Test func ignoresOrdinaryOutboundMail() {
        #expect(detector.detect(PT.ordinaryOutbound(), documentFields: [:]) == nil)
    }

    @Test func docFieldsAlonePromoteEvenWithoutKeywords() {
        // An attached doc with a clear monetary total counts as a proposal/quote even if the
        // covering email body is terse.
        let m = PT.outboundProposal(subject: "Documents", body: "See attached.", hasAttachment: true)
        let signal = detector.detect(m, documentFields: ["quote_total": "45000"])
        #expect(signal?.value == 45000)
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter ProposalDetectorTests`
  - **Expected:** compile error — `ProposalDetector` / `ProposalSignal` not in scope.

- [ ] **Implement** `Sources/SenaniEngine/Agents/ProposalDetector.swift`:

```swift
import Foundation
import SenaniRules

/// The result of detecting an outbound proposal/quote: presence means "this is a proposal";
/// `value` is the monetary amount if one could be extracted (nil otherwise).
public struct ProposalSignal: Sendable, Equatable {
    public let value: Double?
    public init(value: Double?) { self.value = value }
}

/// Pure detector: decides whether an OUTBOUND message is a proposal/quote and extracts its value.
/// No I/O, no async — fully unit-testable. The Orchestrator supplies `documentFields` from
/// SenaniDocs.DocumentExtractor (empty when there is no parsed attachment).
public struct ProposalDetector: Sendable {
    public init() {}

    /// Keyword cues in the subject/body that mark a proposal or quote.
    static let keywords = ["proposal", "quote", "quotation", "estimate",
                           "statement of work", "sow"]
    /// Document-field keys that carry the deal value, in preference order.
    static let valueKeys = ["total", "grand_total", "quote_total", "amount",
                            "value", "price", "subtotal"]

    /// Returns a signal if `message` (must be outbound) is a proposal/quote, else nil.
    public func detect(_ message: Message, documentFields: [String: String]) -> ProposalSignal? {
        guard message.isFromUser else { return nil }   // only the user emailing OUT a proposal

        let docValue = extractValue(from: documentFields)
        let hasProposalDoc = !documentFields.isEmpty && docValue != nil
        let hasKeyword = matchesKeyword(message.subject) || matchesKeyword(message.body)

        guard hasProposalDoc || hasKeyword else { return nil }

        let value = docValue ?? extractCurrency(from: message.body)
        return ProposalSignal(value: value)
    }

    // MARK: - Pure helpers

    func matchesKeyword(_ text: String) -> Bool {
        let lower = text.lowercased()
        return Self.keywords.contains { lower.contains($0) }
    }

    /// Picks the first value-bearing document field (by preference order) and parses a number.
    func extractValue(from fields: [String: String]) -> Double? {
        let lowered = Dictionary(fields.map { ($0.key.lowercased(), $0.value) },
                                 uniquingKeysWith: { a, _ in a })
        for key in Self.valueKeys {
            if let raw = lowered[key], let v = Self.parseAmount(raw) { return v }
        }
        return nil
    }

    /// Finds the first currency-looking number in free text (e.g. "$8,500", "8500.00").
    func extractCurrency(from body: String) -> Double? {
        // Match an optional currency symbol then a grouped/decimal number.
        guard let regex = try? NSRegularExpression(
            pattern: #"[$€£]?\s?\d{1,3}(?:[,\d]{0,})(?:\.\d{1,2})?"#) else { return nil }
        let range = NSRange(body.startIndex..., in: body)
        let matches = regex.matches(in: body, range: range)
        for m in matches {
            guard let r = Range(m.range, in: body) else { continue }
            if let v = Self.parseAmount(String(body[r])), v >= 100 { return v }  // ignore tiny ints
        }
        return nil
    }

    /// Strips currency symbols and grouping separators, then parses a Double.
    static func parseAmount(_ raw: String) -> Double? {
        let cleaned = raw
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "£", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter ProposalDetectorTests`
  - **Expected:** all 6 pass.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: ProposalDetector — pure outbound proposal/quote detection + value extraction

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6 — ReplyIntentClassifier (generateJSON intent → DealStage)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/ReplyIntentClassifier.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/ProposalTracker/ReplyIntentClassifierTests.swift`

Classifies an inbound reply on a tracked thread into an intent via `generateJSON`, then maps intent → `DealStage`: `accept → .won`, `decline → .lost`, `negotiate → .negotiation`, anything else → `.negotiation` (an ambiguous reply means the deal is in active discussion). It NEVER concludes `.won`/`.lost` without a clear signal — ambiguity stays at `.negotiation`.

- [ ] **Write failing tests** `ReplyIntentClassifierTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniInference

@Suite struct ReplyIntentClassifierTests {
    private func classifier(_ json: String) -> (ReplyIntentClassifier, FakeJSONGenerator) {
        let gen = FakeJSONGenerator(cannedJSON: json)
        return (ReplyIntentClassifier(generator: gen), gen)
    }

    @Test func acceptIntentMapsToWon() async throws {
        let (c, _) = classifier(#"{ "intent": "accept" }"#)
        let stage = try await c.classify(reply: PT.inboundReply(body: "Looks great, let's proceed!"))
        #expect(stage == .won)
    }

    @Test func declineIntentMapsToLost() async throws {
        let (c, _) = classifier(#"{ "intent": "decline" }"#)
        let stage = try await c.classify(reply: PT.inboundReply(body: "We've decided to go another way."))
        #expect(stage == .lost)
    }

    @Test func negotiateIntentMapsToNegotiation() async throws {
        let (c, _) = classifier(#"{ "intent": "negotiate" }"#)
        let stage = try await c.classify(reply: PT.inboundReply(body: "Can you do 10% less?"))
        #expect(stage == .negotiation)
    }

    @Test func ambiguousOrOtherIntentMapsToNegotiation() async throws {
        let (c, _) = classifier(#"{ "intent": "other" }"#)
        let stage = try await c.classify(reply: PT.inboundReply(body: "Thanks, will review internally."))
        #expect(stage == .negotiation)
    }

    @Test func malformedJsonDefaultsToNegotiation() async throws {
        let (c, _) = classifier("not json at all")
        let stage = try await c.classify(reply: PT.inboundReply(body: "??"))
        #expect(stage == .negotiation)   // never crashes, never jumps to won/lost on garbage
    }

    @Test func replyBodyIsThreadedIntoThePrompt() async throws {
        let (c, gen) = classifier(#"{ "intent": "accept" }"#)
        _ = try await c.classify(reply: PT.inboundReply(body: "Approved — send the contract."))
        let prompt = try #require(gen.lastPrompt)
        #expect(prompt.contains("Approved — send the contract."))
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter ReplyIntentClassifierTests`
  - **Expected:** compile error — `ReplyIntentClassifier` not in scope.

- [ ] **Implement** `Sources/SenaniEngine/Agents/ReplyIntentClassifier.swift`:

```swift
import Foundation
import SenaniRules
import SenaniInference

/// Classifies an inbound reply on a tracked proposal thread into a DealStage, using a
/// grammar-constrained `generateJSON` intent. Ambiguous/garbage → `.negotiation` (never a silent
/// jump to .won/.lost). The agent injects the generator; the classifier performs the only model call.
public struct ReplyIntentClassifier: Sendable {
    private let generator: any TextGenerator

    public init(generator: any TextGenerator) {
        self.generator = generator
    }

    /// The fixed schema the model must satisfy: { "intent": "accept"|"decline"|"negotiate"|"other" }.
    static let schema: JSONSchema = .object(properties: ["intent": .string], required: ["intent"])

    public func classify(reply: Message) async throws -> DealStage {
        let prompt = Self.buildPrompt(reply: reply)
        let raw = try await generator.generateJSON(prompt: prompt, schema: Self.schema)
        let intent = Self.parseIntent(raw)
        return Self.stage(for: intent)
    }

    // MARK: - Pure helpers

    static func buildPrompt(reply: Message) -> String {
        """
        You are tracking a sales proposal. Classify the client's reply intent.
        Reply with JSON {"intent": one of "accept", "decline", "negotiate", "other"}.
        - "accept": the client agrees / wants to proceed / approves.
        - "decline": the client says no / chose someone else / passes.
        - "negotiate": the client wants changes, a lower price, or more discussion.
        - "other": anything else / unclear.

        From: \(reply.from)
        Subject: \(reply.subject)
        Body:
        \(reply.body)
        """
    }

    /// Safe parse — unknown/missing/garbage → "other".
    static func parseIntent(_ raw: String) -> String {
        guard
            let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let intent = object["intent"] as? String
        else { return "other" }
        return intent.lowercased()
    }

    static func stage(for intent: String) -> DealStage {
        switch intent {
        case "accept": return .won
        case "decline": return .lost
        case "negotiate": return .negotiation
        default: return .negotiation   // ambiguity stays in active discussion
        }
    }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter ReplyIntentClassifierTests`
  - **Expected:** all 6 pass.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: ReplyIntentClassifier — generateJSON intent → DealStage (ambiguity stays .negotiation)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7 — ProposalTrackerAgent (wakesFor + proposals: pipeline upsert + optional nudge)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/ProposalTrackerAgent.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/ProposalTracker/ProposalTrackerWakesForTests.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/ProposalTracker/ProposalTrackerProposalsTests.swift`

The agent ties the two collaborators to the pipeline:

- **`wakesFor`** returns true when EITHER (a) the message is an outbound proposal (`ProposalDetector.detect(...) != nil`) OR (b) the message is an inbound reply (`!isFromUser`) on a thread that already tracks a Deal (`pipeline.byContact(message.from) != nil`).
- **`proposals`** (pure pipeline writes; only emits an Action for the nudge case):
  - **Outbound proposal branch:** look up the contact's Deal by the recipient (`message.to.first`); upsert it to `.proposal` with the extracted `value` (preserving company/score, updating `lastTouch`/`sourceMessageId`); if none exists, create one keyed by the recipient email. **Returns `[]`** (no outbound action — the proposal email is already sent; we only update the pipeline).
  - **Inbound reply branch:** classify the reply → new `DealStage`; upsert the existing Deal to that stage. If the new stage is `.lost`, **return `[]`** (no nudge). If `.won` or `.negotiation`, optionally emit ONE outbound nudge reply via `tools.draftReply(...)` (a short, context-appropriate follow-up). The nudge is `Action.reply` → outbound → always queues; it is never auto-sent.

> **Nudge body:** kept deterministic and template-based (NOT model-generated) so the agent's only model call remains the intent classification — this keeps `proposals` testable with the canned-JSON fake and avoids a second generator dependency. The Reply Drafter owns voice-conditioned drafting; here the nudge is a minimal stub the human edits in the approval queue.

### 7a. Failing `wakesFor` tests

- [ ] **Write** `ProposalTrackerWakesForTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct ProposalTrackerWakesForTests {
    private func agent() -> ProposalTrackerAgent {
        ProposalTrackerAgent(classifier: ReplyIntentClassifier(generator: FakeJSONGenerator(cannedJSON: #"{"intent":"other"}"#)))
    }

    @Test func wakesForOutboundProposalWithDocValue() {
        let m = PT.outboundProposal()
        let ctx = PT.context(thread: [m], pipeline: InMemoryPipelineStore(),
                             documentFields: ["total": "12000"])
        #expect(agent().wakesFor(m, context: ctx) == true)
    }

    @Test func wakesForOutboundProposalViaSubjectCue() {
        let m = PT.outboundProposal(subject: "Quotation enclosed", hasAttachment: false)
        let ctx = PT.context(thread: [m], pipeline: InMemoryPipelineStore())
        #expect(agent().wakesFor(m, context: ctx) == true)
    }

    @Test func wakesForInboundReplyOnTrackedThread() {
        let reply = PT.inboundReply(body: "Sounds good!")
        let pipeline = InMemoryPipelineStore([PT.dealAt(.proposal)])  // keyed by PT.client
        let ctx = PT.context(thread: [PT.outboundProposal(), reply], pipeline: pipeline)
        #expect(agent().wakesFor(reply, context: ctx) == true)
    }

    @Test func doesNotWakeForInboundReplyOnUntrackedThread() {
        let reply = PT.inboundReply(body: "Sounds good!")
        let ctx = PT.context(thread: [reply], pipeline: InMemoryPipelineStore())  // no deal
        #expect(agent().wakesFor(reply, context: ctx) == false)
    }

    @Test func doesNotWakeForOrdinaryOutboundMail() {
        let ctx = PT.context(thread: [PT.ordinaryOutbound()], pipeline: InMemoryPipelineStore())
        #expect(agent().wakesFor(PT.ordinaryOutbound(), context: ctx) == false)
    }

    @Test func identityAndAutonomy() {
        let a = agent()
        #expect(a.id == "proposal-tracker")
        #expect(a.autonomy == .prepare)
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter ProposalTrackerWakesForTests`
  - **Expected:** compile error — `ProposalTrackerAgent` not in scope.

### 7b. Failing `proposals` tests

- [ ] **Write** `ProposalTrackerProposalsTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct ProposalTrackerProposalsTests {
    private func agent(intent: String) -> ProposalTrackerAgent {
        ProposalTrackerAgent(classifier: ReplyIntentClassifier(
            generator: FakeJSONGenerator(cannedJSON: "{\"intent\":\"\(intent)\"}")))
    }

    // --- Proposal detected → Deal at .proposal with extracted value ---

    @Test func outboundProposalMovesDealToProposalWithValue() async throws {
        let pipeline = InMemoryPipelineStore()
        let m = PT.outboundProposal()
        let ctx = PT.context(thread: [m], pipeline: pipeline, documentFields: ["total": "$12,000"])

        let actions = try await agent(intent: "other").proposals(for: m, context: ctx, tools: AgentTools())

        #expect(actions.isEmpty)                              // sending the proposal is not our action
        let deal = try #require(try pipeline.byContact(PT.client))
        #expect(deal.stage == .proposal)
        #expect(deal.value == 12000)
        #expect(deal.sourceMessageId == "m-out")
    }

    @Test func outboundProposalUpgradesAnExistingQualifiedDeal() async throws {
        let pipeline = InMemoryPipelineStore([PT.dealAt(.qualified)])  // Lead Qualifier already scored it
        let m = PT.outboundProposal()
        let ctx = PT.context(thread: [m], pipeline: pipeline, documentFields: ["amount": "30000"])

        _ = try await agent(intent: "other").proposals(for: m, context: ctx, tools: AgentTools())

        let deal = try #require(try pipeline.byContact(PT.client))
        #expect(deal.stage == .proposal)
        #expect(deal.value == 30000)
        #expect(deal.id == PT.client)                         // same row, not a duplicate
        #expect(try pipeline.all().count == 1)
    }

    // --- Replies move the stage ---

    @Test func acceptingReplyMovesDealToWon() async throws {
        let pipeline = InMemoryPipelineStore([PT.dealAt(.proposal, value: 12000)])
        let reply = PT.inboundReply(body: "Approved, let's go!")
        let ctx = PT.context(thread: [PT.outboundProposal(), reply], pipeline: pipeline)

        let actions = try await agent(intent: "accept").proposals(for: reply, context: ctx, tools: AgentTools())

        #expect(try pipeline.byContact(PT.client)?.stage == .won)
        #expect(try pipeline.byContact(PT.client)?.value == 12000)   // value preserved
        // A won deal may emit an optional outbound nudge (thank-you / next-steps) — outbound queues.
        #expect(actions.allSatisfy { $0.actionClass == .outbound })
    }

    @Test func decliningReplyMovesDealToLostWithNoNudge() async throws {
        let pipeline = InMemoryPipelineStore([PT.dealAt(.proposal)])
        let reply = PT.inboundReply(body: "We've gone with another vendor.")
        let ctx = PT.context(thread: [PT.outboundProposal(), reply], pipeline: pipeline)

        let actions = try await agent(intent: "decline").proposals(for: reply, context: ctx, tools: AgentTools())

        #expect(try pipeline.byContact(PT.client)?.stage == .lost)
        #expect(actions.isEmpty)   // no nudge on a lost deal
    }

    @Test func ambiguousReplyMovesDealToNegotiation() async throws {
        let pipeline = InMemoryPipelineStore([PT.dealAt(.proposal)])
        let reply = PT.inboundReply(body: "Thanks, we'll review internally and circle back.")
        let ctx = PT.context(thread: [PT.outboundProposal(), reply], pipeline: pipeline)

        _ = try await agent(intent: "other").proposals(for: reply, context: ctx, tools: AgentTools())

        #expect(try pipeline.byContact(PT.client)?.stage == .negotiation)
    }

    @Test func negotiatingReplyMovesDealToNegotiationAndMayNudge() async throws {
        let pipeline = InMemoryPipelineStore([PT.dealAt(.proposal)])
        let reply = PT.inboundReply(body: "Can you sharpen the price a bit?")
        let ctx = PT.context(thread: [PT.outboundProposal(), reply], pipeline: pipeline)

        let actions = try await agent(intent: "negotiate").proposals(for: reply, context: ctx, tools: AgentTools())

        #expect(try pipeline.byContact(PT.client)?.stage == .negotiation)
        #expect(actions.allSatisfy { $0.actionClass == .outbound })   // any nudge always queues
    }

    // --- Non-proposal mail ignored ---

    @Test func nonProposalOutboundMakesNoPipelineChange() async throws {
        let pipeline = InMemoryPipelineStore()
        let m = PT.ordinaryOutbound()
        let ctx = PT.context(thread: [m], pipeline: pipeline)

        let actions = try await agent(intent: "other").proposals(for: m, context: ctx, tools: AgentTools())

        #expect(actions.isEmpty)
        #expect(try pipeline.all().isEmpty)
    }

    @Test func inboundReplyOnUntrackedThreadMakesNoChange() async throws {
        let pipeline = InMemoryPipelineStore()
        let reply = PT.inboundReply(body: "Yes!")
        let ctx = PT.context(thread: [reply], pipeline: pipeline)

        let actions = try await agent(intent: "accept").proposals(for: reply, context: ctx, tools: AgentTools())

        #expect(actions.isEmpty)
        #expect(try pipeline.all().isEmpty)   // never classifies / writes without a tracked deal
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter ProposalTrackerProposalsTests`
  - **Expected:** compile error — `ProposalTrackerAgent` not in scope.

### 7c. Implement the agent

- [ ] **Write** `Sources/SenaniEngine/Agents/ProposalTrackerAgent.swift`:

```swift
import Foundation
import SenaniRules

/// Phase-3 Proposal Tracker. Keeps the CRM pipeline in step with proposal/quote email.
///
/// Wakes for:
///  - OUTBOUND proposal/quote mail (detected via attached-doc fields or subject/body cues), or
///  - INBOUND replies on a thread that already tracks a Deal.
///
/// Behavior (all stage changes are PURE writes to `context.pipeline` — NOT Actions):
///  - Proposal detected → upsert the contact's Deal to `.proposal` with the extracted value.
///  - Reply on a tracked thread → classify intent → upsert stage (.won / .lost / .negotiation).
///
/// The ONLY `Action` it ever emits is an outbound nudge reply (won/negotiation), which
/// `ActionRouter` always routes to the approval queue — never auto-sent.
public struct ProposalTrackerAgent: Agent {
    public let id = "proposal-tracker"
    public let autonomy: Autonomy = .prepare

    private let detector: ProposalDetector
    private let classifier: ReplyIntentClassifier

    public init(detector: ProposalDetector = ProposalDetector(), classifier: ReplyIntentClassifier) {
        self.detector = detector
        self.classifier = classifier
    }

    // MARK: - Trigger

    public func wakesFor(_ message: Message, context: AgentContext) -> Bool {
        if message.isFromUser {
            return detector.detect(message, documentFields: context.documentFields) != nil
        } else {
            // Inbound reply: wake only if this contact already has a tracked Deal.
            return (try? context.pipeline.byContact(message.from)) != nil
        }
    }

    // MARK: - Proposals (pipeline upsert + optional nudge)

    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        if message.isFromUser {
            return try handleOutboundProposal(message, context: context)
        } else {
            return try await handleInboundReply(message, context: context, tools: tools)
        }
    }

    // MARK: - Outbound proposal → Deal at .proposal

    private func handleOutboundProposal(_ message: Message, context: AgentContext) throws -> [Action] {
        guard let signal = detector.detect(message, documentFields: context.documentFields) else {
            return []
        }
        let contact = message.to.first ?? ""
        guard !contact.isEmpty else { return [] }

        let existing = try context.pipeline.byContact(contact)
        let deal = Deal(
            id: existing?.id ?? contact,
            contactEmail: contact,
            company: existing?.company,
            stage: .proposal,
            score: existing?.score,
            value: signal.value ?? existing?.value,
            lastTouch: message.date,
            sourceMessageId: message.id
        )
        try context.pipeline.upsert(deal)
        return []   // the proposal email is already sent; we only update the pipeline.
    }

    // MARK: - Inbound reply → classify → stage + optional nudge

    private func handleInboundReply(_ message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        guard let existing = try context.pipeline.byContact(message.from) else {
            return []   // untracked thread: never classify or write
        }
        let stage = try await classifier.classify(reply: message)
        let updated = Deal(
            id: existing.id,
            contactEmail: existing.contactEmail,
            company: existing.company,
            stage: stage,
            score: existing.score,
            value: existing.value,
            lastTouch: message.date,
            sourceMessageId: message.id
        )
        try context.pipeline.upsert(updated)

        switch stage {
        case .won:
            return [tools.draftReply(to: message,
                body: "Thank you — delighted to move forward. I'll send next steps shortly.")]
        case .negotiation:
            return [tools.draftReply(to: message,
                body: "Thanks for the note — happy to discuss. When works for a quick call?")]
        default:
            return []   // .lost (or any other) → no nudge
        }
    }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter ProposalTrackerWakesForTests`
  - **Expected:** all 6 pass.
- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter ProposalTrackerProposalsTests`
  - **Expected:** all 8 pass.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: ProposalTrackerAgent — proposal→.proposal, reply→won/lost/negotiation

Stage transitions are pure PipelineStore writes via AgentContext.pipeline; the only
emitted Action is an outbound nudge reply (won/negotiation), which always queues.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8 — Full suite green + public surface check

**Files:** none (verification); remove the placeholder if it still exists as a separate file.

- [ ] If a separate `Placeholder.swift` was created in Task 1, delete it. (A leftover `enum SenaniEnginePlaceholder {}` inside `AgentContract.swift` is harmless but should be removed once the real types are present.)

- [ ] **Run the full suite:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test`
  - **Expected:** all Proposal Tracker suites pass — `AgentContractContractTests`, `PipelineSeamTests`, `ProposalTrackerSupportTests`, `ProposalDetectorTests`, `ReplyIntentClassifierTests`, `ProposalTrackerWakesForTests`, `ProposalTrackerProposalsTests`. Zero failures, strict-concurrency clean. (Any pre-existing suites from co-located agents must remain green too.)

- [ ] **Confirm public surface** matches the §3 contract + this plan's additions:
  - `Agent`, `AgentContext` (with `pipeline` + `documentFields`), `AgentTools` (`draftReply` → outbound `Action.reply`).
  - `DealStage`, `Deal`, `PipelineStore`, `NullPipelineStore` (the pinned CRM seam).
  - `ProposalSignal`, `ProposalDetector`, `ReplyIntentClassifier`, `ProposalTrackerAgent` (`id == "proposal-tracker"`, `autonomy == .prepare`).

- [ ] **Commit (if any cleanup):**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: full Proposal Tracker suite green; public contract verified

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Scope coverage (brief):**
- `ProposalTrackerAgent: SenaniEngine.Agent`, co-located in `Packages/SenaniEngine/Sources/SenaniEngine/Agents/` per the Triage/Reply-Drafter co-location decision; the SenaniEngine dependency + shared-scaffold coordination is stated explicitly (Cross-package assumptions). ✅
- `wakesFor` triggers for (a) outbound proposal/quote mail (detected via `documentFields` from SenaniDocs field extraction OR subject/body cues — "proposal"/"quote"/etc.) AND (b) inbound replies on a thread that already tracks a Deal. ✅
- Behavior: proposal detected → create/move Deal to `.proposal` with the value extracted from the doc (or body); reply → `generateJSON` sentiment/intent → `.won`/`.lost`/`.negotiation`. Stage transitions are PURE `PipelineStore` writes (via `AgentContext.pipeline`); the only outbound nudge is an `Action.reply` that queues. ✅
- `PipelineStore` reached via `AgentContext.pipeline`, matching the Lead Qualifier mechanism; the agent never constructs a store. ✅

**Real-source reconciliations (verified, recorded in the plan):**
1. `SenaniDocs.DocumentExtractor.extract(from:) -> ExtractedFields { fields: [String:String] }` is the field source → surfaced to the agent as the additive `AgentContext.documentFields` (agent stays pure; Orchestrator runs the pipeline). ✅
2. `SenaniRules.Action` has NO proposal/stage case → pipeline stage is a `PipelineStore` write, never an `Action`; the only emitted `Action` is `.reply` (outbound, always queues, verified `Action.swift` `actionClass`). ✅
3. `SenaniInference.TextGenerator.generateJSON(prompt:schema:)` + `JSONSchema.object(properties:required:)` verified → intent classifier uses `{"intent": .string}`; no fakes shipped → local `FakeJSONGenerator`. ✅
4. `PipelineStore`/`Deal`/`DealStage` pinned exactly per the plan header (pipeline-crm-view authoritative); `SenaniEngine` not yet on disk → Tasks 1–3 conditionally scaffold the package + contract + seam with skip-if-exists branches and a shared-scaffold coordination flag. ✅
5. `MessageStore`/`PipelineStore` methods are synchronous `throws` (verified) — tests and the agent call them without `await`. ✅

**Tests (pure, no MLX/Gmail/network):**
- Proposal email → Deal at `.proposal` with extracted value (doc-field and body-currency paths; upgrades an existing `.qualified` deal in place). ✅
- Accepting reply → `.won` (value preserved); declining reply → `.lost` (no nudge); ambiguous reply → `.negotiation`; negotiating reply → `.negotiation`. ✅
- Non-proposal outbound and untracked-thread inbound → no pipeline change, no model call, no Action. ✅
- Fakes: local `FakeJSONGenerator` (canned JSON + prompt recording), in-memory `InMemoryPipelineStore`, `AgentContext.thread` stands in for `MessageStore`; malformed JSON → safe `.negotiation`. ✅

**Conventions (§4):** agent is pure (only injected generator I/O + pipeline writes through `context.pipeline`); one safety path (nudge is outbound → `ActionRouter` queues); reads through context, never stores directly; macOS 14 / Swift 6.2 / strict concurrency / Swift Testing; TDD bite-sized steps with complete code, run-to-fail/run-to-pass commands + expected output, frequent commits. ✅

**Open items flagged to the human:**
- SenaniEngine package ownership / shared scaffold with the Triage + Reply-Drafter + Lead-Qualifier + orchestrator plans (who creates `Package.swift` + `AgentContract.swift` + `Pipeline/PipelineStore.swift` first).
- Additive `AgentContext.pipeline` (shared with Lead Qualifier) and `AgentContext.documentFields` (this plan) — the Orchestrator must populate them from the live `PipelineStore` and `SenaniDocs.DocumentPipeline`/`DocumentExtractor`.
- `PipelineStore`/`Deal`/`DealStage` seam is the pipeline-crm-view plan's authoritative contract; if that plan ships a different id convention or method shape, this agent adapts and the deviation is recorded.
- Deal id convention = `contactEmail` (one open deal per contact) so Lead Qualifier and Proposal Tracker share a row — confirm with the pipeline-crm-view owner.
- The nudge body is a deterministic template (not voice-conditioned) to keep the agent's only model call the intent classification; if a voice-conditioned nudge is wanted, route it through the Reply Drafter / a `VoicePrefixProviding` seam in a follow-up.
