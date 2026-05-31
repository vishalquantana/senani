# Follow-up Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the **Follow-up Agent** (Phase 3) — a pure `SenaniEngine.Agent` that, for threads on an **open Deal** where the last message is **from the user**, sent **more than N days ago**, with **no reply since**, drafts a **voice-matched follow-up nudge** (via a `VoicePrefixProviding` seam over `SenaniVoice.VoiceConditioner.promptPrefix(profile:recipient:draftGoal:)` + the thread transcript + a nudge instruction), calls the injected `TextGenerator.generate`, and emits **one OUTBOUND reply Action** (`tools.followUpReply → Action.reply(body:)`, `actionClass == .outbound`) which `ActionRouter` ALWAYS routes to the approval queue — **never auto-sent**. When a nudge is queued the agent records a `Deal.lastTouch` update through an injected `PipelineTouching` seam, and a **per-contact cooldown** prevents duplicate nudges. The staleness scan that *finds* such threads is a **pure, injectable-clock** function (`StaleThreadScanner.staleThreads(olderThan:now:)`) the Scheduler's **daily hook** calls; per-message reactivation runs through the normal `wakesFor`/`proposals` agent path. Fully unit-tested with a fake clock, in-memory `MessageStore` + `PipelineStore`, and a local prompt-recording `FakeTextGenerator`; no MLX, no Gmail, no network.

**Architecture:** `FollowUpAgent` conforms to `SenaniEngine.Agent` (the §3 contract from [`2026-05-31-APP-PLANS-RECONCILIATION.md`](2026-05-31-APP-PLANS-RECONCILIATION.md)) and is **co-located in `Packages/SenaniEngine/Sources/SenaniEngine/Agents/`** alongside the `Agent`/`AgentContext`/`AgentTools` definitions and the Triage + Reply Drafter agents (matching their co-location decision). Follow-up is partly **timer-based**: the staleness logic lives in a pure value type `StaleThreadScanner` that takes an in-memory `MessageStore` + a `PipelineStore` (open-deal scope) + a `cooldownDays`/`silenceDays` policy + an injected `now`, and returns `[StaleThread]` (threadId + the last user message + the deal). The Scheduler's daily hook calls `scanner.staleThreads(olderThan:now:)` and then routes each `StaleThread` through the Orchestrator/agent path. **Per-message reactivation** (a new inbound message arrives on a previously-stale thread) is handled by the agent's own `wakesFor`/`proposals` over the live `AgentContext.thread`. `proposals(for:context:tools:)` re-checks the staleness predicate (defensive purity), builds a voice-conditioned nudge prompt, calls the injected `TextGenerator.generate`, returns `[tools.followUpReply(to:body:)]` (= `Action.reply(body:)`, outbound → always queues), and — as a side effect through the injected `PipelineTouching` seam — stamps `Deal.lastTouch = now`. The cooldown is enforced by comparing `now` against the deal's `lastTouch` (no nudge if within `cooldownDays`). **Execution-on-approve** (creating the Gmail send/draft via `GmailMailBackend`) belongs to the Approval-queue UI plan, NOT this plan.

**Tech Stack:** Swift 6.2, `swift-tools-version: 6.0`, macOS 14, strict concurrency (complete), Swift Testing (`import Testing`). Path deps: `../SenaniRules`, `../SenaniStore`, `../SenaniInference`, `../SenaniVoice`.

**Working directory:** All `swift` commands run from `/Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine` unless stated otherwise.

**Out of scope (separate plans):** the Orchestrator/Scheduler/AgentRegistry runtime (orchestrator plan) — this plan only defines the pure `StaleThreadScanner` the daily hook will call and documents the wiring; the live `PipelineStore` schema/persistence and the Pipeline/CRM view (the pipeline-crm-view plan, authoritative for `Deal`/`DealStage`/`PipelineStore` — this plan pins the **minimal** contract it codes against and ships an in-memory test double); the Lead Qualifier / Proposal Tracker agents (their own plans, co-owners of the pipeline seam); building the live `VoiceConditioner`/`Embedder`/`VectorIndex`/`VoiceProfile` (Voice plan, already built/frozen); the MLX `TextGenerator` (inference plan); executing an approved nudge into Gmail (`GmailMailBackend`, owned by the Approval-queue UI plan).

---

## Cross-package assumptions (verified from source — state to the human before coding)

### `SenaniEngine` dependency + co-location (FLAG TO HUMAN — shared scaffold)
`Packages/SenaniEngine` **does not yet exist on disk** (verified: `ls Packages/` shows the nine engine packages — `SenaniAnalytics`, `SenaniAssistant`, `SenaniDocs`, `SenaniGmail`, `SenaniInference`, `SenaniReplyZero`, `SenaniRules`, `SenaniStore`, `SenaniVoice` — no `SenaniEngine`). Per §3 of the reconciliation doc, `SenaniEngine` is a NEW app-tier package owning `Agent`, `AgentContext`, `AgentTools`, `AgentRegistry`, `Orchestrator`, `Scheduler`. The Follow-up agent is **co-located inside `SenaniEngine`**, in `Sources/SenaniEngine/Agents/`, with the Triage + Reply Drafter agents. This is a **shared-scaffold coordination point** — the Triage, Reply Drafter, orchestrator, and this plan may all want to create `Package.swift` + the `Agent` contract file. **Flag to the human so only ONE plan scaffolds the package.**

- **If `SenaniEngine` already exists** (Triage/Reply-Drafter/orchestrator plan landed first): do NOT recreate the package or redefine `Agent`/`AgentContext`/`AgentTools`. Skip Task 1's package scaffold and Task 2's contract file; add only `Agents/FollowUpAgent.swift`, `Agents/StaleThreadScanner.swift`, `PipelineStore.swift` (the pinned pipeline seam), `VoicePrefixProviding.swift` (only if absent — the Reply Drafter plan also defines it), and the tests. Verify the on-disk `Agent`/`AgentContext`/`AgentTools` match the §3 signatures pinned below; if they differ, adapt `FollowUpAgent` to the real ones and record the deviation in the commit body.
- **If `SenaniEngine` does not exist** (this plan runs first): Tasks 1–2 scaffold the package and define the §3 contracts so the agent compiles and is testable today. The other agent plans then build on these exact files.

### `VoicePrefixProviding` seam — shared with the Reply Drafter plan (FLAG TO HUMAN)
The Reply Drafter plan ([`2026-05-31-reply-drafter-agent.md`](2026-05-31-reply-drafter-agent.md), Task 4) introduces a `VoicePrefixProviding` protocol + `VoiceConditionerPrefixProvider` adapter in `Sources/SenaniEngine/VoicePrefixProviding.swift`. **This plan reuses the EXACT SAME seam** — it does NOT define a second one. If the Reply Drafter plan already shipped `VoicePrefixProviding.swift`, this plan does not recreate it (Task 3 becomes a no-op verification). If it has not landed, this plan creates the identical file (same protocol + adapter), and the Reply Drafter plan must then skip its own. Coordinate which plan owns the file.

### `SenaniRules` (built + frozen, do NOT edit — verified)
- `public struct Message: Sendable, Equatable, Identifiable` with `id, from, to:[String], subject, body, hasAttachment, listUnsubscribeHeader, labels, threadId, date, isFromUser` and computed `var senderDomain: String` (verified `Message.swift`).
- `public enum Action: Sendable, Equatable` (verified `Action.swift`). Relevant cases: `.draft(body:)`, `.reply(body:)`, `.send(body:)`, `.label(String)`, `.archive`, `.markRead`, `.forward(to:body:)`, `.markSpam`, …
- `public enum ActionClass: Sendable, Equatable { case reversible; case outbound }` and `extension Action { public var actionClass: ActionClass }`. **Verified:** `.reply`, `.forward`, `.send`, `.markSpam` are `.outbound`; `.draft`, `.label`, `.archive`, `.markRead` are `.reversible`.
- `public enum ActionRouter { public static func route(_ action: Action, autonomy: Autonomy) -> Outcome }` — **verified first line of `Routing.swift`:** `if action.actionClass == .outbound { return .queuedForApproval }`. So an outbound action ALWAYS queues regardless of the agent's autonomy dial.
- `public enum Outcome { case executed, prepared, queuedForApproval }`; `public enum Autonomy: String { case ask, prepare, auto }`; `public enum Trigger { case rule(id:), chat(turnId:) }`.

> **`followUpReply` → which `Action` case? (reconciliation).** The brief says the nudge is OUTBOUND and queues for approval, never auto-sent. The frozen `Action` has `.draft(body:)` (`.reversible` — would auto-execute under `.auto`/`.prepare`, violating "always queues") and `.reply(body:)` (`.outbound` — always queues). To honor the safety guarantee, **`followUpReply` builds `Action.reply(body:)`**, identical to the Reply Drafter's `draftReply` mapping. The send-vs-draft distinction is an **execution-time** concern owned by the Approval-UI plan. This plan adds NO new `Action` case (a new case is a §5 blocking change to a frozen package).

### `SenaniStore` (built + frozen, do NOT edit — verified)
- `public struct MessageStore: Sendable` (verified `MessageStore.swift`): `init(database:)`, `save`, `saveAll`, `fetch(id:)`, **`thread(id:) throws -> [Message]`** (ORDER BY date ASC — date ascending, exactly what the scanner needs), `query(from:to:isFromUser:limit:)`, `all()`. **The store API is synchronous `throws` (not async)** — verified from source. The scanner uses `MessageStore.all()` (or per-thread `thread(id:)`) to find candidate threads.
- `public struct StoredProposal`, `public struct ApprovalStore` (`enqueue(id:_:)`, `pending()`, `approve`, `reject`), `public actor PersistentAuditLog`, `public protocol VectorIndex`, `public struct VectorHit`, `public final class InMemoryVectorIndex` — used only by the Orchestrator/adapters, not by this agent directly (agents are pure per §4).
- **`MessageStore` is a concrete `struct` backed by `SenaniDatabase`.** It is not a protocol. The scanner depends on a **narrow local read protocol `ThreadReading`** (Task 4) so tests can supply an in-memory fake without a real `SenaniDatabase`; the production wiring (orchestrator plan) adapts the concrete `MessageStore` to `ThreadReading` in one line. This mirrors the assistant-chat-core plan's `MessageReading` seam pattern.

### `SenaniInference` (built + frozen, NO fakes shipped — verified)
- `public protocol TextGenerator: Sendable { func generate(prompt: String, maxTokens: Int) async throws -> String; func generateJSON(prompt: String, schema: JSONSchema) async throws -> String }`.
- **No `FakeTextGenerator` exists.** This plan defines its own prompt-recording fake in the test target (Task 5).

### `SenaniVoice` (built + frozen — verified)
- `public struct VoiceConditioner: Sendable` with `public init(embedder: any Embedder, index: any VectorIndex)` and `public func promptPrefix(profile: VoiceProfile, recipient: String, draftGoal: String) async throws -> String` (verified `VoiceConditioner.swift`). The real signature is `promptPrefix(profile:recipient:draftGoal:)`, NOT a shorthand. It needs a `VoiceProfile` + `Embedder` + `VectorIndex` — none of which are on `AgentContext`, so it is wrapped behind the shared `VoicePrefixProviding` seam (Task 3) to keep the agent pure/testable.
- `public struct VoiceProfile: Codable, Sendable, Equatable` with `init(scope:averageSentenceWords:greeting:signoff:commonPhrases:emojiRate:perDomain:)` (verified `VoiceProfile.swift`; `perDomain` defaults to `[:]`). Used only by the production `VoiceConditionerPrefixProvider` adapter, not the agent.

### `PipelineStore` / `Deal` / `DealStage` — MINIMAL pinned contract (this plan PINS; pipeline-crm-view authoritative) (FLAG TO HUMAN)
No pipeline/CRM types exist anywhere in the repo yet (verified: `grep -ri "PipelineStore\|DealStage" docs Packages` → none). Per the brief, follow-ups are scoped to **open deals**, and this plan codes to the **same `PipelineStore` seam** the Lead Qualifier / pipeline-crm-view plans own. Because those plans have not landed, this plan **pins the minimal contract below** and ships an **in-memory test double** (`InMemoryPipeline`). When the real pipeline-crm-view plan lands, it MUST expose at least these symbols (or this plan adapts and records the deviation). Pin:

```swift
public enum DealStage: String, Sendable, Equatable, Codable {
    case lead, qualified, proposalSent, negotiation, won, lost
    /// "Open" = not yet closed. Follow-ups only fire on open deals.
    public var isOpen: Bool { self != .won && self != .lost }
}

public struct Deal: Sendable, Equatable, Identifiable, Codable {
    public let id: String           // stable deal id
    public var contact: String      // the counterpart's email address (recipient of nudges)
    public var threadId: String     // the email thread this deal tracks
    public var stage: DealStage
    public var lastTouch: Date?     // when we last reached out / were touched; nil = never
    public init(id: String, contact: String, threadId: String, stage: DealStage, lastTouch: Date?)
}

/// Read/touch seam over the deals pipeline. The orchestrator adapts the live
/// pipeline-crm-view `PipelineStore` to this protocol; tests use `InMemoryPipeline`.
public protocol PipelineReading: Sendable {
    func openDeals() throws -> [Deal]          // all deals whose stage.isOpen
    func deal(threadId: String) throws -> Deal? // the open/any deal for a thread, if any
}
public protocol PipelineTouching: Sendable {
    func touch(dealId: String, at date: Date) throws   // sets Deal.lastTouch = date
}
```

> This plan defines `Deal`/`DealStage`/`PipelineReading`/`PipelineTouching` **inside `SenaniEngine`** as the pinned seam (file `PipelineStore.swift`). It is NOT a re-implementation of the persistent pipeline — it is the contract the agent + scanner code against. **Flag to the human:** when the pipeline-crm-view plan ships the persistent `PipelineStore`, it should either (a) define these exact types and have `PipelineStore` conform to `PipelineReading`/`PipelineTouching`, or (b) provide an app-tier adapter. Do not fork two `Deal` models.

### `Agent` / `AgentContext` / `AgentTools` — §3 signatures this plan PINS / reuses
The §3 contract for the types in `AgentContract.swift` (created by Task 2 only if `SenaniEngine` is absent; otherwise reused as-is):
```swift
public protocol Agent: Sendable {
    var id: String { get }
    var autonomy: Autonomy { get }
    func wakesFor(_ message: Message, context: AgentContext) -> Bool
    func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action]
}
public struct AgentContext: Sendable {
    public let account: String
    public let thread: [Message]            // the message's thread, date ascending
    public let rules: [Rule]
    public let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit]
    public let now: Date
    public let needsReply: Bool             // additive field from the Reply Drafter plan (defaulted)
}
public struct AgentTools: Sendable {
    public func draftReply(to message: Message, body: String) -> Action   // = .reply (outbound)
    public func proposeLabel(_ label: String, on message: Message) -> Action
    public func archive(_ message: Message) -> Action
    public func markRead(_ message: Message) -> Action
}
```
`Rule` comes from `SenaniRules`; `VectorHit` from `SenaniStore`; `Autonomy`/`Message`/`Action` from `SenaniRules`.

> **`AgentTools.followUpReply` (this plan ADDS, additive):** this plan adds one pure builder `func followUpReply(to message: Message, body: String) -> Action { .reply(body: body) }` to `AgentTools`. It is identical in mapping to `draftReply` but named for follow-up call-sites. **Flag to the SenaniEngine owner:** additive, non-breaking. If the owner prefers reusing `draftReply`, the agent calls `tools.draftReply` instead — record the deviation. (Tests below use `tools.followUpReply`.)

---

## File Structure

```
Packages/SenaniEngine/
  Package.swift                                       # (Task 1 — only if SenaniEngine absent)
  Sources/SenaniEngine/
    AgentContract.swift                               # (Task 2 — only if absent) Agent/AgentContext/AgentTools (+followUpReply)
    VoicePrefixProviding.swift                        # (Task 3 — only if absent; shared w/ Reply Drafter) seam + adapter
    PipelineStore.swift                               # (Task 4) Deal/DealStage/PipelineReading/PipelineTouching pinned seam + ThreadReading
    Agents/
      StaleThreadScanner.swift                        # (Task 6) PURE staleness scan (injected clock) — the daily-hook entry point
      FollowUpAgent.swift                             # (Task 7) the agent (wakesFor + proposals + lastTouch + cooldown)
  Tests/SenaniEngineTests/
    FollowUp/
      FollowUpFixtures.swift                          # (Task 5) Message/thread/Deal builders + fake clock helpers
      RecordingTextGenerator.swift                    # (Task 5) local prompt-recording FakeTextGenerator (reuse Reply Drafter's if present)
      FakeVoicePrefixProvider.swift                   # (Task 5) recording voice-prefix fake (reuse Reply Drafter's if present)
      InMemoryPipeline.swift                          # (Task 5) in-memory PipelineReading + PipelineTouching + ThreadReading fakes
      StaleThreadScannerTests.swift                   # (Task 6)
      FollowUpAgentWakesForTests.swift                # (Task 7)
      FollowUpAgentProposalsTests.swift               # (Task 7)
```

> If `SenaniEngine` (and/or `VoicePrefixProviding.swift`) already exist, only the missing `Sources` files (`PipelineStore.swift`, `Agents/StaleThreadScanner.swift`, `Agents/FollowUpAgent.swift`) and the `FollowUp/` test folder are added. If `RecordingTextGenerator.swift` / `FakeVoicePrefixProvider.swift` already exist in the test target (from the Reply Drafter plan), reuse them and skip the duplicates in Task 5.

---

## Task 1 — Package scaffold (skip if `SenaniEngine` already exists)

**Files:**
- Create: `Packages/SenaniEngine/Package.swift`
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/AgentContract.swift` (temporary one-line marker)

- [ ] **First, check whether the package exists:**

```
ls /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine 2>/dev/null && echo EXISTS || echo ABSENT
```
- **If `EXISTS`:** skip Tasks 1 and 2; jump to Task 3. (Verify the existing `Agent`/`AgentContext`/`AgentTools` against the §3 signatures above; adapt later tasks to the real shapes and record any deviation in the commit body.)
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
  - **Expected:** builds clean (empty library). If a sibling package fails to resolve, STOP and report which path dependency is missing — do NOT fake it.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git init -q 2>/dev/null; git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: package scaffold with engine-package path deps

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2 — Agent contract types (skip if already defined)

**Files:**
- Replace: `Packages/SenaniEngine/Sources/SenaniEngine/AgentContract.swift`
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/FollowUp/AgentToolsContractTests.swift`

> If `SenaniEngine` already defines `Agent`/`AgentContext`/`AgentTools` (Task 1 said `EXISTS`), skip the protocol/struct definitions. If `AgentTools` lacks `followUpReply`, add ONLY that method (additive). If `AgentContext` lacks `needsReply`, add it defaulted. Skip everything else.

- [ ] **Write failing test** `Packages/SenaniEngine/Tests/SenaniEngineTests/FollowUp/AgentToolsContractTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct AgentToolsContractTests {
    private func msg() -> Message {
        Message(
            id: "m1", from: "ramesh@quantana.in", to: ["sarah@client.com"],
            subject: "Proposal", body: "Sending the proposal now.",
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: "t1", date: Date(timeIntervalSince1970: 1_000_000), isFromUser: true
        )
    }

    @Test func followUpReplyProducesAnOutboundReplyAction() {
        let tools = AgentTools()
        let action = tools.followUpReply(to: msg(), body: "Just following up.")
        #expect(action == .reply(body: "Just following up."))
        #expect(action.actionClass == .outbound)   // ⇒ ActionRouter ALWAYS queues it
    }

    @Test func agentContextCarriesThreadAndNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ctx = AgentContext(
            account: "ramesh@quantana.in", thread: [msg()], rules: [],
            retrieve: { _, _ in [] }, now: now
        )
        #expect(ctx.now == now)
        #expect(ctx.thread.count == 1)
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter AgentToolsContractTests`
  - **Expected:** compile error — `cannot find 'AgentTools' / 'AgentContext' in scope` (or, if the package exists, `value of type 'AgentTools' has no member 'followUpReply'`).

- [ ] **Implement** `AgentContract.swift` (replace the placeholder — OR, if the package exists, only add `followUpReply`/`needsReply`):

```swift
import Foundation
import SenaniRules
import SenaniStore

/// An agent is a pure function from (message, context, tools) → proposed Actions.
/// It NEVER touches Gmail or stores directly; the Orchestrator enforces autonomy and routes
/// every returned Action through `ActionRouter` + the MailBackend/ApprovalStore/AuditLog seams.
public protocol Agent: Sendable {
    /// Stable identity, e.g. "triage", "reply-drafter", "follow-up".
    var id: String { get }
    /// Per-agent dial; the Orchestrator (not the agent) enforces it.
    var autonomy: Autonomy { get }
    /// Pure trigger predicate.
    func wakesFor(_ message: Message, context: AgentContext) -> Bool
    /// Pure proposal builder (its only I/O is the injected generator/voice/pipeline seams the agent holds).
    func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action]
}

/// Read-only world an agent may see. Pre-populated by the Orchestrator; agents never query stores.
public struct AgentContext: Sendable {
    public let account: String
    public let thread: [Message]            // the message's thread, date ascending
    public let rules: [Rule]
    public let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit]
    public let now: Date
    /// Whether the Orchestrator flagged this thread as needing the user's reply (Reply Drafter signal).
    public let needsReply: Bool

    public init(
        account: String,
        thread: [Message],
        rules: [Rule],
        retrieve: @escaping @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit],
        now: Date,
        needsReply: Bool = false
    ) {
        self.account = account
        self.thread = thread
        self.rules = rules
        self.retrieve = retrieve
        self.now = now
        self.needsReply = needsReply
    }
}

/// Pure builders that return an `Action` — they do NOT execute anything.
public struct AgentTools: Sendable {
    public init() {}

    /// A reply draft addressed back into the thread (Reply Drafter). Maps to `Action.reply` (outbound).
    public func draftReply(to message: Message, body: String) -> Action { .reply(body: body) }

    /// A follow-up nudge addressed back into the thread (Follow-up agent). Maps to `Action.reply`,
    /// whose `actionClass == .outbound`, so `ActionRouter` ALWAYS queues it (never auto-sent).
    public func followUpReply(to message: Message, body: String) -> Action { .reply(body: body) }

    public func proposeLabel(_ label: String, on message: Message) -> Action { .label(label) }
    public func archive(_ message: Message) -> Action { .archive }
    public func markRead(_ message: Message) -> Action { .markRead }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter AgentToolsContractTests`
  - **Expected:** 2 tests pass.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: Agent/AgentContext/AgentTools contract (+followUpReply outbound)

followUpReply maps to Action.reply (outbound) so it always queues for approval.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3 — VoicePrefixProviding seam (skip if Reply Drafter plan already shipped it)

**Files:**
- Create (only if absent): `Packages/SenaniEngine/Sources/SenaniEngine/VoicePrefixProviding.swift`

- [ ] **Check whether the seam already exists:**
```
ls /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine/Sources/SenaniEngine/VoicePrefixProviding.swift 2>/dev/null && echo EXISTS || echo ABSENT
```
- **If `EXISTS`:** skip this task; the Reply Drafter plan owns the file. Verify it declares `protocol VoicePrefixProviding { func voicePrefix(recipient:draftGoal:) async throws -> String }` and adapt if it differs.
- **If `ABSENT`:** create it below (and tell the Reply Drafter plan owner to skip its own Task 4).

- [ ] **Create** `Sources/SenaniEngine/VoicePrefixProviding.swift`:

```swift
import Foundation
import SenaniVoice
import SenaniInference
import SenaniStore

/// Narrow seam over voice conditioning so an Agent can obtain a voice-conditioned prompt
/// prefix without holding the live VoiceProfile / Embedder / VectorIndex itself.
/// The Orchestrator (or composition root) injects a concrete provider.
public protocol VoicePrefixProviding: Sendable {
    /// Returns the conditioning prefix that instructs the model to write in the user's voice,
    /// selected for the recipient's domain and seeded with retrieved exemplars.
    func voicePrefix(recipient: String, draftGoal: String) async throws -> String
}

/// Production adapter: wraps `SenaniVoice.VoiceConditioner` + the user's `VoiceProfile`.
public struct VoiceConditionerPrefixProvider: VoicePrefixProviding {
    private let conditioner: VoiceConditioner
    private let profile: VoiceProfile

    public init(conditioner: VoiceConditioner, profile: VoiceProfile) {
        self.conditioner = conditioner
        self.profile = profile
    }

    public func voicePrefix(recipient: String, draftGoal: String) async throws -> String {
        try await conditioner.promptPrefix(profile: profile, recipient: recipient, draftGoal: draftGoal)
    }
}
```

- [ ] **Run-to-build:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift build`
  - **Expected:** builds clean.

- [ ] **Commit (only if the file was created here):**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: VoicePrefixProviding seam + VoiceConditioner adapter

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4 — Pipeline seam (Deal / DealStage / PipelineReading / PipelineTouching / ThreadReading)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/PipelineStore.swift`
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/FollowUp/PipelineContractTests.swift`

This pins the **minimal** pipeline contract the scanner + agent code against (pipeline-crm-view is authoritative; this is the seam). It also defines `ThreadReading` — the narrow read seam over `MessageStore.thread(id:)` / `all()` so the scanner is testable without a real `SenaniDatabase`.

- [ ] **Write failing test** `PipelineContractTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine

@Suite struct PipelineContractTests {
    @Test func dealStageOpennessIsClosedOnlyWhenWonOrLost() {
        #expect(DealStage.lead.isOpen)
        #expect(DealStage.qualified.isOpen)
        #expect(DealStage.proposalSent.isOpen)
        #expect(DealStage.negotiation.isOpen)
        #expect(!DealStage.won.isOpen)
        #expect(!DealStage.lost.isOpen)
    }

    @Test func dealCarriesContactThreadStageAndLastTouch() {
        let deal = Deal(
            id: "d1", contact: "sarah@client.com", threadId: "t1",
            stage: .proposalSent, lastTouch: nil
        )
        #expect(deal.contact == "sarah@client.com")
        #expect(deal.threadId == "t1")
        #expect(deal.stage.isOpen)
        #expect(deal.lastTouch == nil)
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter PipelineContractTests`
  - **Expected:** compile error — `cannot find 'DealStage' / 'Deal' in scope`.

- [ ] **Implement** `Sources/SenaniEngine/PipelineStore.swift`:

```swift
import Foundation
import SenaniRules

/// Lifecycle stage of a sales deal. Follow-ups only fire on OPEN deals.
public enum DealStage: String, Sendable, Equatable, Codable {
    case lead
    case qualified
    case proposalSent
    case negotiation
    case won
    case lost

    /// "Open" = not yet closed (neither won nor lost).
    public var isOpen: Bool { self != .won && self != .lost }
}

/// A tracked sales deal. Minimal pinned shape; the pipeline-crm-view plan owns the persistent store.
public struct Deal: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var contact: String      // counterpart email — recipient of any nudge
    public var threadId: String     // the email thread this deal tracks
    public var stage: DealStage
    public var lastTouch: Date?     // last outreach/touch; nil = never touched

    public init(id: String, contact: String, threadId: String, stage: DealStage, lastTouch: Date?) {
        self.id = id
        self.contact = contact
        self.threadId = threadId
        self.stage = stage
        self.lastTouch = lastTouch
    }
}

/// Read seam over the deals pipeline. The orchestrator adapts the live PipelineStore to this.
public protocol PipelineReading: Sendable {
    func openDeals() throws -> [Deal]
    func deal(threadId: String) throws -> Deal?
}

/// Write seam: stamp a deal's lastTouch when a nudge is queued.
public protocol PipelineTouching: Sendable {
    func touch(dealId: String, at date: Date) throws
}

/// Narrow read seam over the message thread store. Production adapts SenaniStore.MessageStore;
/// tests supply an in-memory fake. Returns thread messages in DATE-ASCENDING order
/// (matching MessageStore.thread(id:)).
public protocol ThreadReading: Sendable {
    func thread(id: String) throws -> [Message]   // date ascending
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter PipelineContractTests`
  - **Expected:** 2 tests pass.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: minimal pipeline seam (Deal/DealStage/PipelineReading/Touching) + ThreadReading

Pinned contract for the Follow-up agent; pipeline-crm-view plan is authoritative.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5 — Fixtures + fakes (clock, generator, voice, pipeline, thread store)

**Files:**
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/FollowUp/FollowUpFixtures.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/FollowUp/RecordingTextGenerator.swift` (skip if Reply Drafter test target already has it)
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/FollowUp/FakeVoicePrefixProvider.swift` (skip if already present)
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/FollowUp/InMemoryPipeline.swift`

- [ ] **Check for reuse:**
```
ls /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine/Tests/SenaniEngineTests/**/RecordingTextGenerator.swift 2>/dev/null && echo GEN-EXISTS || echo GEN-ABSENT
ls /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine/Tests/SenaniEngineTests/**/FakeVoicePrefixProvider.swift 2>/dev/null && echo VOICE-EXISTS || echo VOICE-ABSENT
```
- If `GEN-EXISTS` / `VOICE-EXISTS` (the Reply Drafter plan shipped them), do NOT recreate — they are visible across the test target. Skip those two files below; still create `FollowUpFixtures.swift` and `InMemoryPipeline.swift`.

- [ ] **Create** `FollowUpFixtures.swift` (shared helpers, no `@Test`):

```swift
import Foundation
@testable import SenaniEngine
import SenaniRules

enum FU {
    static let account = "ramesh@quantana.in"
    static let contact = "sarah@client.com"
    /// "Now" reference for the fake clock: 2023-11-14 22:13:20 UTC.
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static func day(_ n: Double) -> TimeInterval { n * 86_400 }

    /// A message FROM the user out to the contact (our outreach in the thread).
    static func fromUser(
        id: String = "m-user",
        threadId: String = "t1",
        subject: String = "Proposal",
        body: String = "Hi Sarah,\n\nHere's the proposal — let me know what you think.\n\nBest,\nRamesh",
        daysAgo: Double = 10
    ) -> Message {
        Message(
            id: id, from: account, to: [contact], subject: subject, body: body,
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: threadId, date: now.addingTimeInterval(-day(daysAgo)), isFromUser: true
        )
    }

    /// A message FROM the contact back to the user (a reply).
    static func fromContact(
        id: String = "m-contact",
        threadId: String = "t1",
        subject: String = "Re: Proposal",
        body: String = "Thanks Ramesh, reviewing now.",
        daysAgo: Double = 2
    ) -> Message {
        Message(
            id: id, from: contact, to: [account], subject: subject, body: body,
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: threadId, date: now.addingTimeInterval(-day(daysAgo)), isFromUser: false
        )
    }

    static func openDeal(
        id: String = "d1", threadId: String = "t1",
        stage: DealStage = .proposalSent, lastTouch: Date? = nil
    ) -> Deal {
        Deal(id: id, contact: contact, threadId: threadId, stage: stage, lastTouch: lastTouch)
    }

    /// Builds an AgentContext over the given thread (date-sorted ascending defensively).
    static func context(thread: [Message], at when: Date = now) -> AgentContext {
        AgentContext(
            account: account, thread: thread.sorted { $0.date < $1.date },
            rules: [], retrieve: { _, _ in [] }, now: when
        )
    }
}
```

- [ ] **Create** `RecordingTextGenerator.swift` (skip if `GEN-EXISTS`):

```swift
import Foundation
import SenaniInference

/// Local prompt-recording TextGenerator (SenaniInference ships no fakes).
final class RecordingTextGenerator: TextGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private let cannedBody: String
    private var prompts: [String] = []
    private var maxTokensSeen: [Int] = []

    init(cannedBody: String) { self.cannedBody = cannedBody }

    func generate(prompt: String, maxTokens: Int) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        prompts.append(prompt)
        maxTokensSeen.append(maxTokens)
        return cannedBody
    }

    func generateJSON(prompt: String, schema: JSONSchema) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        prompts.append(prompt)
        return "{}"
    }

    var recordedPrompts: [String] { lock.lock(); defer { lock.unlock() }; return prompts }
    var lastPrompt: String? { recordedPrompts.last }
    var recordedMaxTokens: [Int] { lock.lock(); defer { lock.unlock() }; return maxTokensSeen }
}
```

- [ ] **Create** `FakeVoicePrefixProvider.swift` (skip if `VOICE-EXISTS`):

```swift
import Foundation
@testable import SenaniEngine

/// Recording fake: returns a canned prefix and records the (recipient, draftGoal) it was asked.
final class FakeVoicePrefixProvider: VoicePrefixProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let prefix: String
    private var calls: [(recipient: String, draftGoal: String)] = []

    init(prefix: String) { self.prefix = prefix }

    func voicePrefix(recipient: String, draftGoal: String) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        calls.append((recipient, draftGoal))
        return prefix
    }

    var recordedCalls: [(recipient: String, draftGoal: String)] {
        lock.lock(); defer { lock.unlock() }; return calls
    }
}
```

- [ ] **Create** `InMemoryPipeline.swift` (in-memory `PipelineReading` + `PipelineTouching` + `ThreadReading`):

```swift
import Foundation
@testable import SenaniEngine
import SenaniRules

/// In-memory pipeline + thread store for tests. Records touch() calls so tests can assert
/// Deal.lastTouch updates without a real PipelineStore or SenaniDatabase.
final class InMemoryPipeline: PipelineReading, PipelineTouching, ThreadReading, @unchecked Sendable {
    private let lock = NSLock()
    private var deals: [Deal]
    private var threads: [String: [Message]]
    private(set) var touches: [(dealId: String, at: Date)] = []

    init(deals: [Deal], threads: [String: [Message]]) {
        self.deals = deals
        self.threads = threads
    }

    func openDeals() throws -> [Deal] {
        lock.lock(); defer { lock.unlock() }
        return deals.filter { $0.stage.isOpen }
    }

    func deal(threadId: String) throws -> Deal? {
        lock.lock(); defer { lock.unlock() }
        return deals.first { $0.threadId == threadId }
    }

    func touch(dealId: String, at date: Date) throws {
        lock.lock(); defer { lock.unlock() }
        touches.append((dealId, date))
        if let i = deals.firstIndex(where: { $0.id == dealId }) {
            deals[i].lastTouch = date
        }
    }

    func thread(id: String) throws -> [Message] {
        lock.lock(); defer { lock.unlock() }
        return (threads[id] ?? []).sorted { $0.date < $1.date }
    }

    /// Current snapshot of a deal (post-touch), for assertions.
    func currentDeal(id: String) -> Deal? {
        lock.lock(); defer { lock.unlock() }
        return deals.first { $0.id == id }
    }
}
```

- [ ] **Run-to-build:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift build --build-tests`
  - **Expected:** compiles (fixtures/fakes reference only existing types). No tests run yet.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: Follow-up test fixtures + in-memory pipeline/thread/voice/generator fakes

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6 — StaleThreadScanner (PURE staleness scan, injected clock)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/StaleThreadScanner.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/FollowUp/StaleThreadScannerTests.swift`

The scanner is the **timer-based entry point**: the Scheduler's daily hook calls `staleThreads(olderThan:now:)`. It is pure — given `ThreadReading` + `PipelineReading` + a policy + `now`, it returns the threads needing a nudge. A thread qualifies when, for an OPEN deal: the **last** message in the thread is **from the user**, that message's `date` is **> silenceDays before `now`**, and the deal's **cooldown** has elapsed (`lastTouch` is nil OR `now - lastTouch > cooldownDays`).

- [ ] **Write failing test** `StaleThreadScannerTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct StaleThreadScannerTests {
    private func scanner(_ pipe: InMemoryPipeline,
                         silenceDays: Double = 7, cooldownDays: Double = 3) -> StaleThreadScanner {
        StaleThreadScanner(threads: pipe, pipeline: pipe,
                           policy: .init(silenceDays: silenceDays, cooldownDays: cooldownDays))
    }

    @Test func flagsThreadWhereLastUserMessageIsOlderThanSilenceWindow() throws {
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)   // user sent 10d ago, no reply since
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1")],
                                    threads: ["t1": [last]])
        let stale = try scanner(pipe).staleThreads(olderThan: 7, now: FU.now)
        #expect(stale.count == 1)
        #expect(stale.first?.threadId == "t1")
        #expect(stale.first?.lastUserMessage.id == last.id)
        #expect(stale.first?.deal.id == "d1")
    }

    @Test func doesNotFlagWhenContactRepliedAfterTheUser() throws {
        let mine = FU.fromUser(threadId: "t1", daysAgo: 10)
        let reply = FU.fromContact(threadId: "t1", daysAgo: 2)   // contact replied 2d ago = last msg
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1")],
                                    threads: ["t1": [mine, reply]])
        let stale = try scanner(pipe).staleThreads(olderThan: 7, now: FU.now)
        #expect(stale.isEmpty)   // last message is from the contact, not the user
    }

    @Test func doesNotFlagWhenLastUserMessageIsWithinSilenceWindow() throws {
        let recent = FU.fromUser(threadId: "t1", daysAgo: 3)     // only 3d of silence < 7
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1")],
                                    threads: ["t1": [recent]])
        let stale = try scanner(pipe).staleThreads(olderThan: 7, now: FU.now)
        #expect(stale.isEmpty)
    }

    @Test func doesNotFlagThreadsForClosedDeals() throws {
        let last = FU.fromUser(threadId: "t1", daysAgo: 30)
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1", stage: .won)],
                                    threads: ["t1": [last]])
        let stale = try scanner(pipe).staleThreads(olderThan: 7, now: FU.now)
        #expect(stale.isEmpty)   // won deal is closed → never nudged
    }

    @Test func respectsCooldownWhenDealWasRecentlyTouched() throws {
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)
        let touchedYesterday = FU.now.addingTimeInterval(-FU.day(1))   // within 3d cooldown
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1", lastTouch: touchedYesterday)],
                                    threads: ["t1": [last]])
        let stale = try scanner(pipe).staleThreads(olderThan: 7, now: FU.now)
        #expect(stale.isEmpty)   // cooldown not elapsed → no duplicate nudge
    }

    @Test func flagsAgainOnceCooldownHasElapsed() throws {
        let last = FU.fromUser(threadId: "t1", daysAgo: 14)
        let touchedLongAgo = FU.now.addingTimeInterval(-FU.day(5))     // beyond 3d cooldown
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1", lastTouch: touchedLongAgo)],
                                    threads: ["t1": [last]])
        let stale = try scanner(pipe).staleThreads(olderThan: 7, now: FU.now)
        #expect(stale.count == 1)
    }

    @Test func ignoresThreadsWithNoOpenDeal() throws {
        let last = FU.fromUser(threadId: "t-unknown", daysAgo: 30)
        let pipe = InMemoryPipeline(deals: [],                          // no deal for this thread
                                    threads: ["t-unknown": [last]])
        let stale = try scanner(pipe).staleThreads(olderThan: 7, now: FU.now)
        #expect(stale.isEmpty)
    }

    @Test func ignoresEmptyThreads() throws {
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1")],
                                    threads: ["t1": []])
        let stale = try scanner(pipe).staleThreads(olderThan: 7, now: FU.now)
        #expect(stale.isEmpty)
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter StaleThreadScannerTests`
  - **Expected:** compile error — `cannot find 'StaleThreadScanner' in scope`.

- [ ] **Implement** `Sources/SenaniEngine/Agents/StaleThreadScanner.swift`:

```swift
import Foundation
import SenaniRules

/// A thread that has gone silent on an open deal and is due a follow-up nudge.
public struct StaleThread: Sendable, Equatable {
    public let threadId: String
    public let lastUserMessage: Message   // the user's last outreach (the message to reply into)
    public let deal: Deal
    public init(threadId: String, lastUserMessage: Message, deal: Deal) {
        self.threadId = threadId
        self.lastUserMessage = lastUserMessage
        self.deal = deal
    }
}

/// Follow-up timing policy. `silenceDays` = how long a thread may sit unanswered before a nudge;
/// `cooldownDays` = minimum gap between nudges on the same deal (prevents duplicates).
public struct FollowUpPolicy: Sendable, Equatable {
    public let silenceDays: Double
    public let cooldownDays: Double
    public init(silenceDays: Double = 7, cooldownDays: Double = 3) {
        self.silenceDays = silenceDays
        self.cooldownDays = cooldownDays
    }
}

/// PURE staleness scan. Given a thread store + pipeline + policy + an injected `now`, returns the
/// open-deal threads whose last message is the user's, older than `silenceDays`, past cooldown.
/// The Scheduler's DAILY HOOK calls `staleThreads(olderThan:now:)` and routes each result through
/// the Follow-up agent's `proposals(...)` path (per-message reactivation uses the same predicate).
public struct StaleThreadScanner: Sendable {
    private let threads: any ThreadReading
    private let pipeline: any PipelineReading
    private let policy: FollowUpPolicy

    public init(threads: any ThreadReading, pipeline: any PipelineReading, policy: FollowUpPolicy) {
        self.threads = threads
        self.pipeline = pipeline
        self.policy = policy
    }

    /// `silenceDays` may override the policy for an ad-hoc scan; defaults to the policy value if nil.
    public func staleThreads(olderThan silenceDays: Double? = nil, now: Date) throws -> [StaleThread] {
        let silence = silenceDays ?? policy.silenceDays
        var result: [StaleThread] = []
        for deal in try pipeline.openDeals() {
            let messages = try threads.thread(id: deal.threadId)   // date ascending
            guard let last = messages.last else { continue }       // empty thread → skip
            guard Self.isStale(lastMessage: last, deal: deal, silenceDays: silence,
                               cooldownDays: policy.cooldownDays, now: now) else { continue }
            result.append(StaleThread(threadId: deal.threadId, lastUserMessage: last, deal: deal))
        }
        return result
    }

    /// PURE predicate, reused by the agent's wakesFor. A thread is stale when:
    /// • the last message is FROM the user (we're waiting on them, not the reverse),
    /// • that message is older than `silenceDays`, AND
    /// • the deal's cooldown has elapsed (never touched, or touched > cooldownDays ago).
    public static func isStale(
        lastMessage: Message, deal: Deal,
        silenceDays: Double, cooldownDays: Double, now: Date
    ) -> Bool {
        guard deal.stage.isOpen else { return false }
        guard lastMessage.isFromUser else { return false }
        let silentFor = now.timeIntervalSince(lastMessage.date)
        guard silentFor > silenceDays * 86_400 else { return false }
        if let touched = deal.lastTouch {
            guard now.timeIntervalSince(touched) > cooldownDays * 86_400 else { return false }
        }
        return true
    }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter StaleThreadScannerTests`
  - **Expected:** all 8 tests pass.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: StaleThreadScanner — pure, injected-clock staleness scan for follow-ups

Daily-hook entry point: open-deal threads whose last message is the user's, silent
> N days, past cooldown. Closed deals and recently-touched deals are skipped.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7 — FollowUpAgent (wakesFor + proposals + lastTouch + cooldown)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/FollowUpAgent.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/FollowUp/FollowUpAgentWakesForTests.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/FollowUp/FollowUpAgentProposalsTests.swift`

The agent reuses `StaleThreadScanner.isStale` as its pure `wakesFor` predicate over `AgentContext.thread` (per-message reactivation), draws the deal from the injected `PipelineReading`, builds a voice-conditioned nudge prompt, generates a body, returns one `followUpReply` Action (outbound → always queues), and stamps `Deal.lastTouch = now` via `PipelineTouching`.

### 7a. Failing `wakesFor` tests

- [ ] **Write** `FollowUpAgentWakesForTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct FollowUpAgentWakesForTests {
    private func agent(_ pipe: InMemoryPipeline) -> FollowUpAgent {
        FollowUpAgent(
            generator: RecordingTextGenerator(cannedBody: "Just checking in."),
            voice: FakeVoicePrefixProvider(prefix: "VOICE"),
            pipelineRead: pipe, pipelineTouch: pipe,
            policy: .init(silenceDays: 7, cooldownDays: 3)
        )
    }

    @Test func wakesForSilentUserMessageOnOpenDeal() {
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1")], threads: ["t1": [last]])
        let ctx = FU.context(thread: [last])
        #expect(agent(pipe).wakesFor(last, context: ctx) == true)
    }

    @Test func doesNotWakeWhenContactRepliedLast() {
        let mine = FU.fromUser(threadId: "t1", daysAgo: 10)
        let reply = FU.fromContact(threadId: "t1", daysAgo: 2)
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1")], threads: ["t1": [mine, reply]])
        let ctx = FU.context(thread: [mine, reply])
        #expect(agent(pipe).wakesFor(reply, context: ctx) == false)
    }

    @Test func doesNotWakeWithinSilenceWindow() {
        let recent = FU.fromUser(threadId: "t1", daysAgo: 3)
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1")], threads: ["t1": [recent]])
        let ctx = FU.context(thread: [recent])
        #expect(agent(pipe).wakesFor(recent, context: ctx) == false)
    }

    @Test func doesNotWakeWhenNoOpenDealForThread() {
        let last = FU.fromUser(threadId: "t-orphan", daysAgo: 30)
        let pipe = InMemoryPipeline(deals: [], threads: ["t-orphan": [last]])
        let ctx = FU.context(thread: [last])
        #expect(agent(pipe).wakesFor(last, context: ctx) == false)
    }

    @Test func doesNotWakeWithinCooldown() {
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)
        let touchedYesterday = FU.now.addingTimeInterval(-FU.day(1))
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1", lastTouch: touchedYesterday)],
                                    threads: ["t1": [last]])
        let ctx = FU.context(thread: [last])
        #expect(agent(pipe).wakesFor(last, context: ctx) == false)
    }

    @Test func identityAndAutonomy() {
        let pipe = InMemoryPipeline(deals: [], threads: [:])
        let a = agent(pipe)
        #expect(a.id == "follow-up")
        #expect(a.autonomy == .prepare)
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter FollowUpAgentWakesForTests`
  - **Expected:** compile error — `cannot find 'FollowUpAgent' in scope`.

### 7b. Failing `proposals` tests

- [ ] **Write** `FollowUpAgentProposalsTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct FollowUpAgentProposalsTests {
    private func make(canned: String = "Hi Sarah, just following up on the proposal.\n\nBest,\nRamesh",
                      lastTouch: Date? = nil)
        -> (FollowUpAgent, RecordingTextGenerator, FakeVoicePrefixProvider, InMemoryPipeline) {
        let gen = RecordingTextGenerator(cannedBody: canned)
        let voice = FakeVoicePrefixProvider(prefix: "WRITE-IN-MY-VOICE-PREFIX")
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)
        let pipe = InMemoryPipeline(
            deals: [FU.openDeal(threadId: "t1", lastTouch: lastTouch)],
            threads: ["t1": [last]]
        )
        let agent = FollowUpAgent(generator: gen, voice: voice,
                                  pipelineRead: pipe, pipelineTouch: pipe,
                                  policy: .init(silenceDays: 7, cooldownDays: 3))
        return (agent, gen, voice, pipe)
    }

    @Test func producesASingleOutboundFollowUpReplyWithGeneratedBody() async throws {
        let (agent, _, _, _) = make(canned: "Just following up.")
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)
        let ctx = FU.context(thread: [last])

        let actions = try await agent.proposals(for: last, context: ctx, tools: AgentTools())

        #expect(actions == [.reply(body: "Just following up.")])
        #expect(actions.first?.actionClass == .outbound)   // ⇒ ActionRouter ALWAYS queues it
    }

    @Test func stampsDealLastTouchWhenNudgeIsQueued() async throws {
        let (agent, _, _, pipe) = make()
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)
        let ctx = FU.context(thread: [last], at: FU.now)

        _ = try await agent.proposals(for: last, context: ctx, tools: AgentTools())

        #expect(pipe.touches.count == 1)
        #expect(pipe.touches.first?.dealId == "d1")
        #expect(pipe.touches.first?.at == FU.now)
        #expect(pipe.currentDeal(id: "d1")?.lastTouch == FU.now)
    }

    @Test func voicePrefixIsIncludedInThePromptAndAskedForTheContact() async throws {
        let (agent, gen, voice, _) = make()
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)
        let ctx = FU.context(thread: [last])

        _ = try await agent.proposals(for: last, context: ctx, tools: AgentTools())

        let prompt = try #require(gen.lastPrompt)
        #expect(prompt.contains("WRITE-IN-MY-VOICE-PREFIX"))     // voice prefix threaded in
        #expect(voice.recordedCalls.first?.recipient == FU.contact)   // nudge addressed to the contact
        #expect(gen.recordedMaxTokens.first == FollowUpAgent.maxNudgeTokens)
    }

    @Test func promptIncludesThreadContextAndAFollowUpInstruction() async throws {
        let (agent, gen, _, _) = make()
        let last = FU.fromUser(threadId: "t1", daysAgo: 10,
                               body: "Here's the proposal — let me know what you think.")
        let ctx = FU.context(thread: [last])

        _ = try await agent.proposals(for: last, context: ctx, tools: AgentTools())

        let prompt = try #require(gen.lastPrompt)
        #expect(prompt.contains("Here's the proposal — let me know what you think."))  // thread body
        #expect(prompt.lowercased().contains("follow up"))                              // the nudge instruction
    }

    @Test func noNudgeWhenContactAlreadyReplied() async throws {
        let gen = RecordingTextGenerator(cannedBody: "should-not-be-used")
        let mine = FU.fromUser(threadId: "t1", daysAgo: 10)
        let reply = FU.fromContact(threadId: "t1", daysAgo: 2)
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1")], threads: ["t1": [mine, reply]])
        let agent = FollowUpAgent(generator: gen, voice: FakeVoicePrefixProvider(prefix: "V"),
                                  pipelineRead: pipe, pipelineTouch: pipe,
                                  policy: .init(silenceDays: 7, cooldownDays: 3))
        let ctx = FU.context(thread: [mine, reply])

        let actions = try await agent.proposals(for: reply, context: ctx, tools: AgentTools())

        #expect(actions.isEmpty)
        #expect(gen.recordedPrompts.isEmpty)   // no model call wasted
        #expect(pipe.touches.isEmpty)          // no touch on a non-stale thread
    }

    @Test func noNudgeWithinSilenceWindow() async throws {
        let gen = RecordingTextGenerator(cannedBody: "x")
        let recent = FU.fromUser(threadId: "t1", daysAgo: 3)
        let pipe = InMemoryPipeline(deals: [FU.openDeal(threadId: "t1")], threads: ["t1": [recent]])
        let agent = FollowUpAgent(generator: gen, voice: FakeVoicePrefixProvider(prefix: "V"),
                                  pipelineRead: pipe, pipelineTouch: pipe,
                                  policy: .init(silenceDays: 7, cooldownDays: 3))
        let ctx = FU.context(thread: [recent])

        let actions = try await agent.proposals(for: recent, context: ctx, tools: AgentTools())
        #expect(actions.isEmpty)
        #expect(pipe.touches.isEmpty)
    }

    @Test func cooldownPreventsDuplicateNudges() async throws {
        // Deal was touched yesterday (within 3-day cooldown) → no second nudge.
        let (agent, gen, _, pipe) = make(lastTouch: FU.now.addingTimeInterval(-FU.day(1)))
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)
        let ctx = FU.context(thread: [last])

        let actions = try await agent.proposals(for: last, context: ctx, tools: AgentTools())

        #expect(actions.isEmpty)
        #expect(gen.recordedPrompts.isEmpty)
        #expect(pipe.touches.isEmpty)          // no new touch
    }

    @Test func trimsWhitespaceFromGeneratedBody() async throws {
        let (agent, _, _, _) = make(canned: "\n\n  Just following up.  \n")
        let last = FU.fromUser(threadId: "t1", daysAgo: 10)
        let ctx = FU.context(thread: [last])
        let actions = try await agent.proposals(for: last, context: ctx, tools: AgentTools())
        #expect(actions == [.reply(body: "Just following up.")])
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter FollowUpAgentProposalsTests`
  - **Expected:** compile error — `cannot find 'FollowUpAgent' in scope`.

### 7c. Implement the agent

- [ ] **Write** `Sources/SenaniEngine/Agents/FollowUpAgent.swift`:

```swift
import Foundation
import SenaniRules
import SenaniInference

/// Phase-3 Follow-up agent. For threads on an OPEN deal where the user's last message has gone
/// unanswered longer than the silence window (and the deal's cooldown has elapsed), it drafts a
/// voice-matched follow-up NUDGE and proposes ONE reply Action back into the thread.
///
/// The proposed Action is `Action.reply` (`actionClass == .outbound`), so the Orchestrator's
/// `ActionRouter.route` ALWAYS yields `.queuedForApproval` — it is NEVER auto-sent. When a nudge is
/// queued the agent stamps `Deal.lastTouch = context.now` via `PipelineTouching`, and the per-deal
/// cooldown (checked through the same staleness predicate) prevents duplicate nudges.
///
/// `wakesFor`/`proposals` cover PER-MESSAGE reactivation over `context.thread`; the TIMER-based scan
/// (find all stale threads daily) is `StaleThreadScanner.staleThreads(olderThan:now:)`, which the
/// Scheduler's daily hook calls and routes through this same `proposals(...)`.
public struct FollowUpAgent: Agent {
    public let id = "follow-up"
    /// `.prepare` is the per-agent dial; irrelevant to safety because the emitted action is outbound
    /// and `ActionRouter` queues all outbound actions regardless of autonomy.
    public let autonomy: Autonomy = .prepare

    /// Bounded generation budget for a single nudge body.
    public static let maxNudgeTokens = 320

    private let generator: any TextGenerator
    private let voice: any VoicePrefixProviding
    private let pipelineRead: any PipelineReading
    private let pipelineTouch: any PipelineTouching
    private let policy: FollowUpPolicy

    public init(
        generator: any TextGenerator,
        voice: any VoicePrefixProviding,
        pipelineRead: any PipelineReading,
        pipelineTouch: any PipelineTouching,
        policy: FollowUpPolicy
    ) {
        self.generator = generator
        self.voice = voice
        self.pipelineRead = pipelineRead
        self.pipelineTouch = pipelineTouch
        self.policy = policy
    }

    /// Wakes when `message` is the last (most recent) message in its thread, is from the user, the
    /// thread sits on an open deal, and the staleness + cooldown predicate holds.
    public func wakesFor(_ message: Message, context: AgentContext) -> Bool {
        guard let last = context.thread.max(by: { $0.date < $1.date }) else { return false }
        guard last.id == message.id else { return false }          // only consider the latest message
        guard let deal = (try? pipelineRead.deal(threadId: message.threadId)) ?? nil else { return false }
        return StaleThreadScanner.isStale(
            lastMessage: message, deal: deal,
            silenceDays: policy.silenceDays, cooldownDays: policy.cooldownDays, now: context.now
        )
    }

    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        guard wakesFor(message, context: context) else { return [] }
        guard let deal = try pipelineRead.deal(threadId: message.threadId) else { return [] }

        let recipient = deal.contact                       // nudge goes to the deal's contact
        let draftGoal = Self.draftGoal(for: message)
        let prefix = try await voice.voicePrefix(recipient: recipient, draftGoal: draftGoal)
        let prompt = Self.buildPrompt(
            voicePrefix: prefix,
            thread: context.thread,
            recipient: recipient
        )

        let raw = try await generator.generate(prompt: prompt, maxTokens: Self.maxNudgeTokens)
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Record the touch ONLY when we actually queue a nudge.
        try pipelineTouch.touch(dealId: deal.id, at: context.now)
        return [tools.followUpReply(to: message, body: body)]
    }

    // MARK: - Prompt assembly (pure, static)

    static func draftGoal(for message: Message) -> String {
        let subject = message.subject.isEmpty ? "this conversation" : message.subject
        return "Write a polite follow-up nudge about \"\(subject)\""
    }

    static func buildPrompt(voicePrefix: String, thread: [Message], recipient: String) -> String {
        var lines: [String] = []
        lines.append(voicePrefix)
        lines.append("")
        lines.append("THREAD (oldest first):")
        let ordered = thread.sorted { $0.date < $1.date }
        for m in ordered {
            let who = m.isFromUser ? "Me" : m.from
            lines.append("From: \(who)")
            if !m.subject.isEmpty { lines.append("Subject: \(m.subject)") }
            lines.append(m.body)
            lines.append("---")
        }
        lines.append("")
        lines.append("Write a brief, polite follow-up nudge to \(recipient) — we have not heard back. "
            + "Reference the conversation, keep it short, and write only the reply body in my voice. "
            + "Do not include headers or a subject line.")
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter FollowUpAgentWakesForTests`
  - **Expected:** all 6 pass.
- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter FollowUpAgentProposalsTests`
  - **Expected:** all 8 pass.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: FollowUpAgent — voice-matched outbound nudge for stale open-deal threads

Wakes on the user's last message after N days of silence on an open deal, drafts a
voice-conditioned nudge, proposes Action.reply (outbound → always queues), stamps
Deal.lastTouch, and respects a per-deal cooldown to avoid duplicate nudges.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8 — Full suite green + public surface check

**Files:** none (verification); remove any leftover placeholder.

- [ ] If a standalone `Placeholder.swift` (or a bare `enum SenaniEnginePlaceholder {}` not co-located with real types) still exists, remove it.

- [ ] **Run the full suite:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test`
  - **Expected:** all suites pass — `AgentToolsContractTests`, `PipelineContractTests`, `StaleThreadScannerTests`, `FollowUpAgentWakesForTests`, `FollowUpAgentProposalsTests` (plus any Reply Drafter/Triage suites already present). Zero failures, strict-concurrency clean.

- [ ] **Confirm public surface** matches the pinned contracts: `DealStage` (`.isOpen`), `Deal`, `PipelineReading`, `PipelineTouching`, `ThreadReading`, `FollowUpPolicy`, `StaleThread`, `StaleThreadScanner` (`staleThreads(olderThan:now:)` + static `isStale`), `FollowUpAgent` (`id == "follow-up"`, `autonomy == .prepare`, `maxNudgeTokens`), `AgentTools.followUpReply` (→ outbound `Action.reply`).

- [ ] **Commit (if any cleanup):**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: full Follow-up suite green; public contract verified

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Scope coverage (brief):**
- `FollowUpAgent: SenaniEngine.Agent`, co-located in `Packages/SenaniEngine/Sources/SenaniEngine/Agents/` per the Triage/Reply-Drafter co-location decision; the SenaniEngine dependency + shared-scaffold + shared-`VoicePrefixProviding` coordination is stated explicitly. ✅
- **Timer-based + per-message:** staleness lives in the PURE, injected-clock `StaleThreadScanner.staleThreads(olderThan:now:)` (the daily-hook entry point) over `ThreadReading` (MessageStore seam) + `PipelineReading` (PipelineStore seam); per-message reactivation runs through `wakesFor`/`proposals` reusing the same `StaleThreadScanner.isStale` predicate — one staleness rule, two entry points. ✅
- **Behavior:** finds threads where the last message is the user's, sent > N days ago, no reply since, on an OPEN deal; drafts a voice-matched nudge via `VoicePrefixProviding` (→ `VoiceConditioner.promptPrefix(profile:recipient:draftGoal:)`) + thread transcript + nudge instruction → `TextGenerator.generate(prompt:maxTokens:)`; emits ONE `followUpReply` → `Action.reply` (outbound → `ActionRouter` ALWAYS queues, verified `Routing.swift` first line); updates `Deal.lastTouch` via `PipelineTouching` only when a nudge is queued. ✅
- **Pipeline seam to the same PipelineStore contract:** `Deal`/`DealStage`/`PipelineReading`/`PipelineTouching` pinned minimally (pipeline-crm-view authoritative; flagged to the human; in-memory double for tests). Follow-ups scoped to `stage.isOpen`. ✅

**Real-source reconciliations (verified, recorded in the plan):**
1. `VoiceConditioner` real signature `promptPrefix(profile:recipient:draftGoal:)` (needs profile + embedder + index) → wrapped behind shared `VoicePrefixProviding`. ✅
2. `SenaniRules.Action` has `.reply` (outbound) but no follow-up-specific case → `followUpReply` builds `.reply`; no frozen package edited; new-case escalation is the §5 path. ✅
3. `MessageStore` is a concrete `struct` with synchronous `throws` `thread(id:)` (date ASC) / `all()` — wrapped behind the narrow `ThreadReading` protocol so the scanner is testable without `SenaniDatabase`. ✅
4. `SenaniInference` ships NO fakes → local `RecordingTextGenerator`. ✅
5. `SenaniEngine` package + `VoicePrefixProviding.swift` not yet on disk → conditional scaffold with explicit skip-if-exists branches and shared-file coordination flags. ✅
6. No `PipelineStore`/`Deal`/`DealStage` anywhere in the repo → minimal contract pinned here (flagged). ✅

**Tests (pure, fake clock, in-memory MessageStore + PipelineStore, no MLX/Gmail/network):**
- User-sent thread silent > N days on open deal → ONE queued outbound nudge (`actions == [.reply(...)]`, `actionClass == .outbound`) with the voice prefix present in the recorded prompt (prompt-recording fake; `WRITE-IN-MY-VOICE-PREFIX`). ✅
- Thread that got a reply (contact's message is last) → no nudge, no model call, no touch. ✅
- Thread within N days of silence → no nudge. ✅
- Per-deal cooldown prevents duplicate nudges (touched within cooldown → no second nudge); fires again once cooldown elapses (scanner test). ✅
- Closed (won/lost) deal and threads with no open deal → no nudge. ✅
- `Deal.lastTouch` stamped to `context.now` only when a nudge is queued; whitespace trimmed from the generated body. ✅

**Conventions (§4):** agent is pure (only injected generator/voice/pipeline I/O); one safety path (outbound → `ActionRouter` queues); reads through injected seams, never raw SQL; macOS 14 / Swift 6.2 / strict concurrency / Swift Testing; TDD bite-sized steps with complete code, run-to-fail/run-to-pass commands + expected output, frequent commits; no placeholders. ✅

**Open items flagged to the human:**
- SenaniEngine package ownership / shared scaffold with the Triage + Reply Drafter + orchestrator plans (who creates `Package.swift` + `AgentContract.swift` first).
- `VoicePrefixProviding.swift` is shared with the Reply Drafter plan — exactly one plan creates it.
- `AgentTools.followUpReply` is an additive method on the shared `AgentTools` (non-breaking); or reuse `draftReply`.
- The minimal `Deal`/`DealStage`/`PipelineReading`/`PipelineTouching` pin must be reconciled with the pipeline-crm-view plan's persistent `PipelineStore` (conform or adapt — do not fork two `Deal` models).
- The Scheduler's daily hook (orchestrator plan) must call `StaleThreadScanner.staleThreads(olderThan:now:)` and route each `StaleThread` through `FollowUpAgent.proposals(...)`; the orchestrator adapts the concrete `MessageStore`/`PipelineStore` to `ThreadReading`/`PipelineReading`/`PipelineTouching`.
- The `silenceDays` (N) and `cooldownDays` defaults (7 / 3) should be a user-configurable setting (Settings UI plan).
