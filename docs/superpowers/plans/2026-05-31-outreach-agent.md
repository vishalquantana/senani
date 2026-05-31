# Outreach Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the **Outreach Agent** (Phase 3 → ROADMAP.md "**Outreach**") — a pure, fully unit-tested helper co-located in `Packages/SenaniEngine` that, given a **list of target contacts/deals** (from the injected `PipelineStore` + any thread context), generates a **personalized cold/warm outreach draft** for each target using a `VoicePrefixProviding` seam over `SenaniVoice.VoiceConditioner.promptPrefix(profile:recipient:draftGoal:)` + the injected `TextGenerator.generate`, and emits **one OUTBOUND draft proposal per eligible target**. Because outreach is **outbound** it ALWAYS queues for human approval — it is **never auto-sent**. A **per-contact cooldown + per-run cap** prevents spamming the same contact or blasting an unbounded list. Generation is **PURE** (the only I/O is the injected generator/voice seam and the synchronous `PipelineStore` reads/touch); driven entirely by an in-memory `PipelineStore` fake and a local prompt-recording `FakeTextGenerator`. **No MLX, no Gmail, no network, no SwiftUI.**

**Architecture:** Outreach is **user-initiated / list-driven**, not inbound-message-driven. The `Orchestrator.process(message:)` path (one inbound message → triage → route → agents) does NOT fit outreach, so this plan models outreach as a **method the user invokes over a target list** (`OutreachAgent.outreach(to:context:tools:)`) plus an **optional dormant-deal reactivation entry point** (`OutreachAgent.dormantTargets(in:now:)`) the Scheduler's **daily hook** can call to assemble the target list. The agent still conforms to `SenaniEngine.Agent` for registry/identity uniformity, but its inbound `wakesFor` returns `false` (outreach is never triggered by a single inbound message) and its inbound `proposals` returns `[]`; the real work lives in the list-driven `outreach(to:...)` method. `OutreachAgent` is **co-located in `Packages/SenaniEngine/Sources/SenaniEngine/Agents/`** alongside `Agent`/`AgentContext`/`AgentTools` and the Triage / Reply Drafter agents (matching their co-location decision).

**CRITICAL ACTION-MODEL FINDING (verified from source — see §"Cross-package assumptions"):** `SenaniRules.Action` (frozen) has **NO "compose new outbound message" case**. Its outbound cases are `.reply(body:)`, `.forward(to:body:)`, `.send(body:)`, plus reversible `.draft(body:)`. None carries a *fresh recipient + subject* for a brand-new conversation with a contact who is not already in a thread. **Per §5 of [`2026-05-31-APP-PLANS-RECONCILIATION.md`](2026-05-31-APP-PLANS-RECONCILIATION.md), adding a `.compose(to:subject:body:)` case is a BLOCKING change to a frozen package — this plan does NOT fork the action model.** Instead it **FLAGS the new compose-outbound case to the human (Task 8)** and, for now, models each outreach draft via the **closest existing outbound mechanism**: **`Action.send(body:)`** — chosen because (a) `.send` is `actionClass == .outbound` so `ActionRouter.route` ALWAYS yields `.queuedForApproval` (the safety guarantee holds: outbound never auto-sends), and (b) the proposal carries the target as the `Proposal.message` (a synthesized outbound `Message` addressed to the contact, `isFromUser == true`), so the Approval-queue UI / `GmailMailBackend` has the recipient + subject it needs at execution time without any new `Action` payload. The body is embedded in `.send(body:)`. **The recipient/subject travel on the `Message`, not the `Action`** — this is the documented stopgap until the human approves a dedicated `.compose(to:subject:body:)` case (Task 8 records the exact escalation).

> **Why `.send` and not `.reply` or `.draft`?** `.reply(body:)` semantically means "reply into an existing thread" (used by Reply Drafter / Follow-up) — wrong for a NEW recipient. `.draft(body:)` is `actionClass == .reversible`, which under a `.prepare`/`.auto` dial would `ActionRouter.route` to `.prepared`/`.executed` and be applied via `MailBackend.apply` **without** human approval — that **violates the outbound-always-queues trust model** for a brand-new outbound message. `.send(body:)` is the only existing case that is BOTH outbound (always queues) AND semantically "originate a message" rather than "reply in thread". The DRAFT-vs-actually-send distinction at execution is owned by the Approval-queue UI plan (it may create a Gmail DRAFT rather than literally sending), exactly as for the Reply Drafter's queued `.reply`.

**Tech Stack:** Swift 6.2, `swift-tools-version: 6.0`, macOS 14, strict concurrency (complete), Swift Testing (`import Testing`). The `SenaniEngine` package already exists with these path deps: `../SenaniRules`, `../SenaniStore`, `../SenaniInference`, `../SenaniVoice` (verified `Package.swift`). No new dependencies.

**Working directory:** All `swift` commands run from `/Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine` unless stated otherwise.

**Out of scope (separate plans):** the real `PipelineStore` persistence + the Pipeline/CRM SwiftUI view (`pipeline-crm-view` plan — owns `PipelineStore`/`Deal`/`DealStage`); the Orchestrator/Scheduler wiring that *assembles the target list and invokes* `outreach(to:...)` on a user action or the daily hook (Orchestrator/Scheduler plans own the trigger plumbing — this plan exposes the pure method + the dormant-target selector they call); the live `MLXTextGenerator` (inference plan); the live `VoiceConditioner`/`VoiceProfile`/`Embedder`/`VectorIndex` (Voice plan, already built); executing an approved outreach draft into Gmail as a DRAFT/send via `GmailMailBackend` (Approval-queue UI plan); the other Phase-3 agents (Lead Qualifier, Proposal Tracker, Follow-up, Invoice/Finance).

---

## Cross-package assumptions (verified from source — state to the human before coding)

### `SenaniEngine` already exists and is built (verified)
`Packages/SenaniEngine` exists on disk with `Agent`/`AgentContext`/`AgentTools`/`Orchestrator`/`Scheduler`/`AgentRegistry` and the Triage + Reply Drafter agents under `Sources/SenaniEngine/Agents/`. **Do NOT recreate the package or redefine those types.** This plan ADDS files under `Sources/SenaniEngine/Agents/` (the outreach agent + its value types) and `Sources/SenaniEngine/Pipeline/` (the bootstrap `PipelineStore` seam, only if not already present) plus tests. Verified shapes this plan codes against:

- **`Agent`** (`Sources/SenaniEngine/Agent.swift`):
  ```swift
  public protocol Agent: Sendable {
      var id: String { get }
      var autonomy: Autonomy { get }
      func wakesFor(_ message: Message, context: AgentContext) -> Bool
      func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action]
  }
  ```
- **`AgentContext`** (`Sources/SenaniEngine/Agent.swift`): currently has `account`, `thread`, `rules`, `retrieve`, `now`, `needsReply` (defaulted). It does **NOT yet have a `pipeline` field** (the Lead Qualifier plan adds it but has not landed). See the **PipelineStore seam** note below — this plan does NOT depend on `AgentContext.pipeline`; it takes the `PipelineStore` as an **explicit parameter** to `outreach(...)`/`dormantTargets(...)` so it is independent of whether the Lead Qualifier plan landed first.
- **`AgentTools`** (`Sources/SenaniEngine/AgentTools.swift`): holds a private `TextGenerator`; exposes pure builders `draftReply`/`proposeLabel`/`archive`/`markRead` + `generateJSON`. **It does NOT expose `generate(prompt:maxTokens:)`** (verified — only `generateJSON`). Therefore, exactly like `ReplyDrafterAgent`, **the Outreach agent holds its OWN injected `any TextGenerator`** and calls `generator.generate(prompt:maxTokens:)` directly. `AgentTools` is used only for typing parity in the `Agent` conformance; the real generation seam is the agent's own injected generator. **This plan adds NO method to `AgentTools`** (no new outbound builder there — the outbound `Action.send` is built directly, see Task 4).

### `SenaniRules` (built + frozen, do NOT edit — verified `Action.swift` / `Routing.swift`)
- `public enum Action: Sendable, Equatable` cases: `.label(String)`, `.archive`, `.markRead`, `.markUnread`, `.star`, `.unstar`, `.move(String)`, `.flagNeedsReply`, `.fileAttachment(folder:)`, `.parseDoc`, `.runAgent(id:)`, `.draft(body:)`, `.reply(body:)`, `.forward(to:body:)`, `.send(body:)`, `.markSpam`, `.localWebhook(name:)`. **There is NO `.compose(to:subject:body:)` (or any "new outbound message") case.**
- `extension Action { public var actionClass: ActionClass }`: `.reply`, `.forward`, `.send`, `.markSpam` ⇒ `.outbound`; everything else (incl. `.draft`) ⇒ `.reversible`.
- `ActionRouter.route(_:autonomy:)` **first line:** `if action.actionClass == .outbound { return .queuedForApproval }`. So `.send(body:)` ALWAYS queues regardless of the agent's autonomy dial — the trust-model guarantee outreach relies on.
- `public struct Message: Sendable, Equatable, Identifiable` with `id, from, to:[String], subject, body, hasAttachment, listUnsubscribeHeader, labels, threadId, date, isFromUser` and computed `senderDomain` (verified `Message.swift`). An **outreach target message is synthesized** with `from = account`, `to = [contact]`, `isFromUser = true`, a generated `subject`, the generated `body`, and a fresh `threadId` (no existing thread — this is a NEW conversation). This synthesized `Message` is the `Proposal.message` so the Approval-UI/connector has recipient + subject at execution time.

### `SenaniInference` (built + frozen, ships NO fakes — verified)
- `public protocol TextGenerator: Sendable { func generate(prompt: String, maxTokens: Int) async throws -> String; func generateJSON(prompt: String, schema: JSONSchema) async throws -> String }`.
- No `FakeTextGenerator` in the package. The `SenaniEngineTests` target already defines an `actor FakeTextGenerator` (in `TestSupport.swift`) that records prompts and returns canned strings/JSON FIFO via both `generate` and `generateJSON`. **This plan reuses that existing fake** — no new generator fake needed.

### `SenaniVoice` (built + frozen — verified)
- `VoiceConditioner.promptPrefix(profile:recipient:draftGoal:) async throws -> String` (verified `VoiceConditioner.swift`). The `SenaniEngine` package already wraps it behind the **`VoicePrefixProviding`** seam (`Sources/SenaniEngine/VoicePrefixProviding.swift`): `protocol VoicePrefixProviding: Sendable { func voicePrefix(recipient:draftGoal:) async throws -> String }`, with production adapter `VoiceConditionerPrefixProvider`. The Outreach agent reuses this exact seam (same contract Reply Drafter / Follow-up use). The test target already defines `actor FakeVoicePrefixProvider` (in `ReplyDrafter/FakeVoicePrefixProvider.swift`) returning a canned prefix and recording `(recipient, draftGoal)`. **This plan reuses that fake** (it is in the same test target).

### `PipelineStore` / `Deal` / `DealStage` seam (OWNED by the `pipeline-crm-view` plan — pinned MINIMAL contract)
`PipelineStore`/`Deal`/`DealStage` are owned by the `pipeline-crm-view` plan and do **not exist yet**. This plan codes to the **exact same minimal pin the Lead Qualifier plan pins** (`2026-05-31-lead-qualifier-agent.md` §"PipelineStore seam"), so the two plans agree on one definition:
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
- **`PipelineStore` methods are synchronous `throws`** (per the pin). The agent reads `byContact(...)` and writes a `lastTouch`-updated `Deal` via `upsert(...)` synchronously inside its `async` method. The in-memory fake locks internally for `Sendable` safety.
- **Bootstrap caveat (shared with Lead Qualifier — COORDINATE on the `pipeline-crm-view` slug).** Because the owning plan has not landed, the **first** of {Lead Qualifier, Outreach, Follow-up, Proposal Tracker} to run creates `Deal`/`DealStage`/`PipelineStore` in `Sources/SenaniEngine/Pipeline/PipelineStore.swift`, signature-identical to the pin. **Task 1 checks whether that file already exists and SKIPS recreating it.** If the `pipeline-crm-view` plan has shipped the real types in an importable module, SKIP the bootstrap and import that module instead — never two `PipelineStore` definitions in the final tree.
- **⚠ Divergence note (FLAG TO HUMAN).** `2026-05-31-follow-up-agent.md` pins a *different, leaner* `Deal` (`Deal(id:contact:threadId:stage:lastTouch:)` with `lastTouch: Date?`). This plan follows the **Lead Qualifier / `pipeline-crm-view` §3 contract** (the richer `Deal` above with `contactEmail` + non-optional `lastTouch`) because that is the one referenced by APP-PLANS-RECONCILIATION §3 (`context.pipeline`). The two Phase-3 plans MUST reconcile to ONE `Deal` before either persists; flagged in Task 8. This plan treats `lastTouch` as non-optional `Date` (cooldown uses it directly).

### Existing test support reused (verified `Tests/SenaniEngineTests/TestSupport.swift`)
- `func msg(...) -> Message` factory; `actor FakeTextGenerator` (records `recordedPrompts`, `generate`/`generateJSON`); `actor FakeMailBackend`; `func tools(_:) -> AgentTools`; `struct FakeEmbedder`. The Lead Qualifier plan adds `InMemoryPipelineStore` to `TestSupport.swift`; **if that has not landed, Task 1 adds `InMemoryPipelineStore` here** (signature-identical to the pin).

---

## File Structure

```
Packages/SenaniEngine/
  Package.swift                                         # (exists) unchanged — deps already present
  Sources/SenaniEngine/
    Agent.swift                                         # (exists) unchanged
    AgentTools.swift                                    # (exists) unchanged
    VoicePrefixProviding.swift                          # (exists) reused
    Pipeline/
      PipelineStore.swift                               # (Task 1) bootstrap DealStage+Deal+PipelineStore — ONLY if absent
    Agents/
      OutreachTarget.swift                              # (Task 2) OutreachTarget value type + OutreachPolicy (cooldown/cap)
      OutreachProposal.swift                            # (Task 3) OutreachProposal (synthesized Message + Action.send) + builder
      OutreachAgent.swift                               # (Task 4–6) the agent: Agent conformance + outreach(to:) + dormantTargets(in:)
  Tests/SenaniEngineTests/
    TestSupport.swift                                   # (exists) EDIT (Task 1) add InMemoryPipelineStore — ONLY if absent
    Outreach/
      OutreachFixtures.swift                            # (Task 2) target/deal/context builders
      OutreachTargetTests.swift                         # (Task 2) policy: cooldown + cap selection
      OutreachProposalTests.swift                       # (Task 3) synthesized message + outbound Action.send
      OutreachAgentTests.swift                          # (Task 4–6) generation, voice prefix, queues, cooldown, cap, dormant
```

One responsibility per file. `OutreachAgent` depends only on the SenaniEngine contract (`Agent`/`AgentContext`/`AgentTools`) + `SenaniRules.Action`/`Message` + the `VoicePrefixProviding` seam + the `PipelineStore` seam + an injected `any TextGenerator`. Every test runs against the existing `FakeTextGenerator` + `FakeVoicePrefixProvider` + an `InMemoryPipelineStore`.

---

## Task 1 — Confirm package + ensure the PipelineStore seam exists

**Files:**
- Verify: `Packages/SenaniEngine/Package.swift`, `Sources/SenaniEngine/{Agent,AgentTools,VoicePrefixProviding}.swift`
- Create (only if absent): `Packages/SenaniEngine/Sources/SenaniEngine/Pipeline/PipelineStore.swift`
- Edit (only if absent): `Tests/SenaniEngineTests/TestSupport.swift` — add `InMemoryPipelineStore`

- [ ] **Step 1: Confirm the package + contract are present:**

```
ls Packages/SenaniEngine/Sources/SenaniEngine/Agent.swift \
   Packages/SenaniEngine/Sources/SenaniEngine/AgentTools.swift \
   Packages/SenaniEngine/Sources/SenaniEngine/VoicePrefixProviding.swift \
   Packages/SenaniEngine/Sources/SenaniEngine/Agents/ReplyDrafterAgent.swift
```
Expected: all four exist (Reply Drafter / Triage plans landed). If any is missing, STOP and report — do NOT scaffold `SenaniEngine` here (the Triage plan owns the scaffold).

- [ ] **Step 2: Check whether the PipelineStore seam already exists:**

```
ls Packages/SenaniEngine/Sources/SenaniEngine/Pipeline/PipelineStore.swift 2>/dev/null && echo SEAM_EXISTS || echo SEAM_ABSENT
```
- **If `SEAM_EXISTS`:** another Phase-3 plan (Lead Qualifier) bootstrapped it. Open it and confirm `Deal`/`DealStage`/`PipelineStore` match the pinned contract above. If they differ (e.g. the Follow-up plan's leaner `Deal`), STOP and reconcile with the human (this is the §8 divergence) — do NOT define a second copy. Then skip to Step 5.
- **If `SEAM_ABSENT`:** continue to Step 3.

- [ ] **Step 3: Write a failing seam-compile test** `Packages/SenaniEngine/Tests/SenaniEngineTests/Outreach/OutreachProposalTests.swift` (the file is fleshed out in Task 3; start with a one-line seam check):

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Test func outreachPipelineSeamCompiles() throws {
    let deal = Deal(id: "a@b.com", contactEmail: "a@b.com", company: "Acme",
                    stage: .qualified, score: 70, value: nil,
                    lastTouch: Date(timeIntervalSince1970: 0), sourceMessageId: "m1")
    #expect(deal.stage == .qualified)
}
```

- [ ] **Step 4: Run to fail:**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter outreachPipelineSeamCompiles
```
Expected: failure — `cannot find 'Deal' / 'DealStage' in scope`.

- [ ] **Step 5: Create the bootstrap seam** (only if `SEAM_ABSENT`) `Packages/SenaniEngine/Sources/SenaniEngine/Pipeline/PipelineStore.swift`:

```swift
import Foundation

/// CRM pipeline seam — OWNED by the `pipeline-crm-view` plan. Bootstrapped here
/// (signature-identical to the pinned minimal contract) so Phase-3 sales agents compile and
/// test before that plan lands. When the real types ship, delete this file and import them.
public enum DealStage: String, Sendable {
    case new, qualified, proposal, negotiation, won, lost
}

public struct Deal: Sendable, Identifiable, Equatable {
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

- [ ] **Step 6: Add `InMemoryPipelineStore` test fake** (only if it is not already in `TestSupport.swift` from the Lead Qualifier plan — grep first: `grep -n InMemoryPipelineStore Tests/SenaniEngineTests/TestSupport.swift`). If absent, append to `Tests/SenaniEngineTests/TestSupport.swift`:

```swift
// ---- In-memory PipelineStore fake (real store owned by the pipeline-crm-view plan) ----

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
```

- [ ] **Step 7: Run to pass:**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter outreachPipelineSeamCompiles
```
Expected: 1 test passes.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: ensure PipelineStore/Deal seam + InMemoryPipelineStore for Outreach

Bootstrapped (idempotently) if the pipeline-crm-view plan has not landed.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2 — OutreachTarget + OutreachPolicy (cooldown + cap selection)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/OutreachTarget.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Outreach/OutreachFixtures.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Outreach/OutreachTargetTests.swift`

`OutreachTarget` is the unit of work: a contact (+ optional `Deal` + optional prior-thread context) to reach out to. `OutreachPolicy` is the pure filter that enforces the **per-contact cooldown** (skip a contact whose deal was touched within `cooldownDays`) and the **per-run cap** (never propose more than `maxPerRun` drafts in one invocation). Both are pure value types — no I/O.

- [ ] **Create** `OutreachFixtures.swift` (shared helpers, no `@Test`):

```swift
import Foundation
@testable import SenaniEngine
import SenaniRules

enum OX {
    static let account = "ramesh@quantana.in"
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static func day(_ n: Double) -> TimeInterval { n * 86_400 }

    /// A Deal whose lastTouch is `daysAgo` before OX.now.
    static func deal(
        contact: String,
        company: String? = "Acme",
        stage: DealStage = .qualified,
        score: Int? = 70,
        touchedDaysAgo: Double
    ) -> Deal {
        Deal(id: contact, contactEmail: contact, company: company, stage: stage,
             score: score, value: nil,
             lastTouch: now.addingTimeInterval(-day(touchedDaysAgo)),
             sourceMessageId: nil)
    }

    /// An OutreachTarget for `contact` with an optional deal and optional prior thread.
    static func target(
        contact: String,
        deal: Deal? = nil,
        thread: [Message] = []
    ) -> OutreachTarget {
        OutreachTarget(contact: contact, deal: deal, thread: thread)
    }

    /// AgentContext for the user's account (outreach is account-scoped, not thread-scoped).
    static func context(now: Date = now) -> AgentContext {
        AgentContext(account: account, thread: [], rules: [],
                     retrieve: { _, _ in [] }, now: now)
    }
}
```

- [ ] **Write failing test** `OutreachTargetTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct OutreachTargetTests {
    @Test func contactWithNoDealIsNeverOnCooldown() {
        let t = OX.target(contact: "new@lead.com", deal: nil)
        let policy = OutreachPolicy(cooldownDays: 7, maxPerRun: 10)
        #expect(policy.isOnCooldown(t, now: OX.now) == false)
    }

    @Test func contactTouchedWithinCooldownIsSkipped() {
        let d = OX.deal(contact: "warm@lead.com", touchedDaysAgo: 3)   // 3 < 7
        let t = OX.target(contact: "warm@lead.com", deal: d)
        let policy = OutreachPolicy(cooldownDays: 7, maxPerRun: 10)
        #expect(policy.isOnCooldown(t, now: OX.now) == true)
    }

    @Test func contactTouchedBeyondCooldownIsEligible() {
        let d = OX.deal(contact: "cold@lead.com", touchedDaysAgo: 30)  // 30 > 7
        let t = OX.target(contact: "cold@lead.com", deal: d)
        let policy = OutreachPolicy(cooldownDays: 7, maxPerRun: 10)
        #expect(policy.isOnCooldown(t, now: OX.now) == false)
    }

    @Test func eligibleFiltersCooledContactsAndAppliesCap() {
        let targets = [
            OX.target(contact: "a@x.com", deal: nil),                          // eligible
            OX.target(contact: "b@x.com", deal: OX.deal(contact: "b@x.com", touchedDaysAgo: 1)),   // cooled
            OX.target(contact: "c@x.com", deal: OX.deal(contact: "c@x.com", touchedDaysAgo: 20)),  // eligible
            OX.target(contact: "d@x.com", deal: nil),                          // eligible (but capped out)
        ]
        let policy = OutreachPolicy(cooldownDays: 7, maxPerRun: 2)
        let eligible = policy.eligible(from: targets, now: OX.now)
        #expect(eligible.map(\.contact) == ["a@x.com", "c@x.com"])   // b cooled, cap=2 drops d
    }

    @Test func capOfZeroYieldsNothing() {
        let targets = [OX.target(contact: "a@x.com")]
        let policy = OutreachPolicy(cooldownDays: 7, maxPerRun: 0)
        #expect(policy.eligible(from: targets, now: OX.now).isEmpty)
    }
}
```

- [ ] **Run to fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter OutreachTargetTests`
  - Expected: compile error — `cannot find 'OutreachTarget' / 'OutreachPolicy' in scope`.

- [ ] **Implement** `Sources/SenaniEngine/Agents/OutreachTarget.swift`:

```swift
import Foundation
import SenaniRules

/// One unit of outreach work: a contact to reach out to, with optional CRM Deal context
/// and any prior thread we have with them (empty for a true cold contact).
public struct OutreachTarget: Sendable, Equatable {
    public let contact: String          // recipient email — a NEW conversation, not a reply
    public let deal: Deal?              // optional CRM deal (drives warm vs cold framing + cooldown)
    public let thread: [Message]       // prior context, if any (empty = cold)

    public init(contact: String, deal: Deal? = nil, thread: [Message] = []) {
        self.contact = contact
        self.deal = deal
        self.thread = thread
    }

    /// Warm if we have an existing deal or prior thread; otherwise cold.
    public var isWarm: Bool { deal != nil || !thread.isEmpty }
}

/// Pure outreach gating policy: a per-contact cooldown (no repeat outreach within N days of
/// the deal's last touch) and a per-run cap (never emit more than `maxPerRun` drafts at once).
public struct OutreachPolicy: Sendable, Equatable {
    public let cooldownDays: Double
    public let maxPerRun: Int

    public init(cooldownDays: Double = 7, maxPerRun: Int = 25) {
        self.cooldownDays = cooldownDays
        self.maxPerRun = maxPerRun
    }

    /// A contact is on cooldown only if it has a deal touched within `cooldownDays` of `now`.
    /// A contact with no deal (never touched) is never on cooldown.
    public func isOnCooldown(_ target: OutreachTarget, now: Date) -> Bool {
        guard let deal = target.deal else { return false }
        let elapsed = now.timeIntervalSince(deal.lastTouch)
        return elapsed < cooldownDays * 86_400
    }

    /// Filters out cooled contacts (order preserved) then truncates to `maxPerRun`.
    public func eligible(from targets: [OutreachTarget], now: Date) -> [OutreachTarget] {
        guard maxPerRun > 0 else { return [] }
        let notCooled = targets.filter { !isOnCooldown($0, now: now) }
        return Array(notCooled.prefix(maxPerRun))
    }
}
```

- [ ] **Run to pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter OutreachTargetTests`
  - Expected: all 5 pass.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: OutreachTarget + OutreachPolicy (per-contact cooldown + per-run cap)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3 — OutreachProposal: synthesized outbound Message + Action.send

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/OutreachProposal.swift`
- Extend: `Packages/SenaniEngine/Tests/SenaniEngineTests/Outreach/OutreachProposalTests.swift` (the seam test from Task 1 lives here; add the real cases)

A queued outreach draft is `(synthesized outbound Message, Action.send(body:))`. The `Message` carries the **recipient + subject** the connector needs (the `Action` model has no compose payload — the §8 escalation). `OutreachProposal.make(...)` is a pure builder. **The agent emits the `Action.send` (the Orchestrator/caller pairs it with the synthesized `Message` when enqueuing); `OutreachProposal` bundles both so the caller has the recipient/subject** — see Task 5 for how the agent returns them.

- [ ] **Replace** `OutreachProposalTests.swift` (keep the Task-1 seam test, add these):

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Test func outreachPipelineSeamCompiles() throws {
    let deal = Deal(id: "a@b.com", contactEmail: "a@b.com", company: "Acme",
                    stage: .qualified, score: 70, value: nil,
                    lastTouch: Date(timeIntervalSince1970: 0), sourceMessageId: "m1")
    #expect(deal.stage == .qualified)
}

@Suite struct OutreachProposalTests {
    @Test func buildsAnOutboundSendActionWhoseBodyIsTheDraft() {
        let p = OutreachProposal.make(
            account: OX.account, contact: "sarah@client.com",
            subject: "Quick idea for Acme", body: "Hi Sarah, ...",
            now: OX.now
        )
        #expect(p.action == .send(body: "Hi Sarah, ..."))
        #expect(p.action.actionClass == .outbound)     // ⇒ ActionRouter ALWAYS queues it
    }

    @Test func synthesizedMessageCarriesRecipientAndSubjectFromTheUser() {
        let p = OutreachProposal.make(
            account: OX.account, contact: "sarah@client.com",
            subject: "Quick idea for Acme", body: "Hi Sarah, ...",
            now: OX.now
        )
        #expect(p.message.from == OX.account)          // originates from the user
        #expect(p.message.to == ["sarah@client.com"])  // recipient travels on the Message
        #expect(p.message.subject == "Quick idea for Acme")
        #expect(p.message.body == "Hi Sarah, ...")
        #expect(p.message.isFromUser == true)
        #expect(p.message.date == OX.now)
    }

    @Test func eachOutreachGetsAFreshThreadIdNotAReply() {
        // A NEW conversation: not tied to any inbound thread; ids are unique per (contact, time).
        let a = OutreachProposal.make(account: OX.account, contact: "sarah@client.com",
                                      subject: "S", body: "B", now: OX.now)
        let b = OutreachProposal.make(account: OX.account, contact: "leo@other.com",
                                      subject: "S", body: "B", now: OX.now)
        #expect(a.message.threadId != b.message.threadId)
        #expect(a.message.id != b.message.id)
    }
}
```

- [ ] **Run to fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter OutreachProposalTests`
  - Expected: compile error — `cannot find 'OutreachProposal' in scope`.

- [ ] **Implement** `Sources/SenaniEngine/Agents/OutreachProposal.swift`:

```swift
import Foundation
import SenaniRules

/// A single proposed outreach draft: an OUTBOUND `Action.send(body:)` paired with a synthesized
/// outbound `Message` that carries the recipient + subject (the frozen `Action` model has no
/// compose-new-message payload — see the plan's §8 escalation for a dedicated `.compose` case).
/// `Action.send` is `actionClass == .outbound`, so `ActionRouter.route` ALWAYS queues it for
/// approval — outreach is NEVER auto-sent.
public struct OutreachProposal: Sendable, Equatable {
    public let message: Message     // synthesized: from=account, to=[contact], isFromUser=true, subject/body set
    public let action: Action       // .send(body:) — outbound → always queues

    public init(message: Message, action: Action) {
        self.message = message
        self.action = action
    }

    /// Builds the proposal for a new outbound message to `contact`.
    public static func make(
        account: String,
        contact: String,
        subject: String,
        body: String,
        now: Date
    ) -> OutreachProposal {
        // A deterministic, unique thread/message id for a brand-new conversation.
        let stamp = Int(now.timeIntervalSince1970)
        let threadId = "outreach:\(contact):\(stamp)"
        let message = Message(
            id: threadId,
            from: account,
            to: [contact],
            subject: subject,
            body: body,
            hasAttachment: false,
            listUnsubscribeHeader: nil,
            labels: [],
            threadId: threadId,
            date: now,
            isFromUser: true
        )
        return OutreachProposal(message: message, action: .send(body: body))
    }
}
```

- [ ] **Run to pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter OutreachProposalTests`
  - Expected: 4 pass (incl. the seam test).

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: OutreachProposal — synthesized outbound Message + Action.send (always queues)

Recipient/subject travel on the Message because Action has no compose payload (see plan §8).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4 — OutreachAgent: Agent conformance (inbound is inert)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/OutreachAgent.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Outreach/OutreachAgentTests.swift`

The agent conforms to `Agent` for registry/identity uniformity, but **outreach is list-driven, not inbound-triggered** — so `wakesFor` returns `false` and inbound `proposals` returns `[]`. The real work is the `outreach(to:...)` method added in Task 5.

- [ ] **Write failing test** `OutreachAgentTests.swift` (start with identity + inert-inbound; Tasks 5–6 append more):

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct OutreachAgentTests {
    private func agent(
        responses: [String] = ["Hi there, quick idea."],
        prefix: String = "VOICE-PREFIX"
    ) -> (OutreachAgent, FakeTextGenerator, FakeVoicePrefixProvider) {
        let gen = FakeTextGenerator(responses: responses)
        let voice = FakeVoicePrefixProvider(prefix: prefix)
        return (OutreachAgent(generator: gen, voice: voice,
                              policy: OutreachPolicy(cooldownDays: 7, maxPerRun: 25)), gen, voice)
    }

    @Test func identityAndAutonomy() {
        let (a, _, _) = agent()
        #expect(a.id == "outreach")
        #expect(a.autonomy == .ask)   // dial is moot: outbound always queues regardless
    }

    @Test func neverWakesForAnInboundMessage() {
        let (a, _, _) = agent()
        let m = msg("in", isFromUser: false)
        #expect(a.wakesFor(m, context: OX.context()) == false)
    }

    @Test func inboundProposalsAreEmpty() async throws {
        let (a, gen, _) = agent()
        let m = msg("in", isFromUser: false)
        let actions = try await a.proposals(for: m, context: OX.context(), tools: tools(gen))
        #expect(actions.isEmpty)
        #expect(await gen.recordedPrompts.isEmpty)   // no model call on the inbound path
    }
}
```

- [ ] **Run to fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter OutreachAgentTests`
  - Expected: compile error — `cannot find 'OutreachAgent' in scope`.

- [ ] **Implement** `Sources/SenaniEngine/Agents/OutreachAgent.swift` (Agent conformance only; the `outreach(...)` method is added in Task 5):

```swift
import Foundation
import SenaniRules
import SenaniInference

/// Phase-3 Outreach agent. **List-driven, user-initiated** (not inbound-message-triggered):
/// the user (or the Scheduler's daily dormant-deal hook) hands it a list of target contacts,
/// and it generates a personalized, voice-conditioned cold/warm draft per eligible target.
/// Each draft is an OUTBOUND `Action.send` (always queues for approval — never auto-sent),
/// gated by a per-contact cooldown + per-run cap.
///
/// It conforms to `Agent` for registry/identity uniformity, but the single-inbound-message
/// path is inert: `wakesFor` is always `false` and inbound `proposals` returns `[]`. The work
/// lives in `outreach(to:context:tools:)` and the `dormantTargets(in:now:)` selector (Task 5/6).
public struct OutreachAgent: Agent {
    public let id = "outreach"
    /// Dial is moot for safety: every emitted action is outbound, which `ActionRouter` always queues.
    public let autonomy: Autonomy = .ask

    /// Bounded generation budget for a single outreach body.
    public static let maxDraftTokens = 384

    private let generator: any TextGenerator
    private let voice: any VoicePrefixProviding
    private let policy: OutreachPolicy

    public init(generator: any TextGenerator,
                voice: any VoicePrefixProviding,
                policy: OutreachPolicy = OutreachPolicy()) {
        self.generator = generator
        self.voice = voice
        self.policy = policy
    }

    // Outreach is never triggered by a single inbound message.
    public func wakesFor(_ message: Message, context: AgentContext) -> Bool { false }

    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        []   // inbound path is inert; use outreach(to:context:tools:)
    }
}
```

- [ ] **Run to pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter OutreachAgentTests`
  - Expected: 3 pass.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: OutreachAgent shell — Agent conformance; inbound path is inert

Outreach is list-driven, not inbound-triggered (wakesFor=false, inbound proposals=[]).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5 — outreach(to:): voice-conditioned draft per eligible target → queued OutreachProposals

**Files:**
- Edit: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/OutreachAgent.swift` (add the method + prompt assembly)
- Edit: `Packages/SenaniEngine/Tests/SenaniEngineTests/Outreach/OutreachAgentTests.swift` (append the generation tests)

`outreach(to:context:tools:)` is the core: filter the list through `policy.eligible`, and for each eligible target build a voice-conditioned prompt (voice prefix + optional prior-thread/deal context + a cold/warm outreach instruction), call `generator.generate`, derive a subject, and produce an `OutreachProposal` (synthesized outbound `Message` + `Action.send`). It returns `[OutreachProposal]` — outbound, so the caller/Orchestrator enqueues every one for approval.

- [ ] **Append failing tests** to `OutreachAgentTests.swift`:

```swift
extension OutreachAgentTests {
    @Test func producesOneOutboundSendProposalPerEligibleTarget() async throws {
        let (a, _, _) = agent(responses: ["Body one.", "Body two."])
        let targets = [OX.target(contact: "a@x.com"), OX.target(contact: "b@x.com")]
        let out = try await a.outreach(to: targets, context: OX.context(), tools: tools(FakeTextGenerator()))
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.action.actionClass == .outbound })   // every one queues
        #expect(out[0].message.to == ["a@x.com"])
        #expect(out[1].message.to == ["b@x.com"])
    }

    @Test func draftBodyComesFromTheGeneratorTrimmed() async throws {
        let (a, _, _) = agent(responses: ["\n  Hi Sarah, quick idea.  \n"])
        let out = try await a.outreach(to: [OX.target(contact: "sarah@client.com")],
                                       context: OX.context(), tools: tools(FakeTextGenerator()))
        #expect(out.first?.action == .send(body: "Hi Sarah, quick idea."))
        #expect(out.first?.message.body == "Hi Sarah, quick idea.")
    }

    @Test func voicePrefixIsThreadedIntoThePromptForEachTarget() async throws {
        let (a, gen, voice) = agent(prefix: "WRITE-IN-MY-VOICE")
        _ = try await a.outreach(to: [OX.target(contact: "sarah@client.com")],
                                 context: OX.context(), tools: tools(FakeTextGenerator()))
        let prompts = await gen.recordedPrompts
        #expect(prompts.count == 1)
        #expect(prompts[0].contains("WRITE-IN-MY-VOICE"))
        let calls = await voice.recordedCalls
        #expect(calls.first?.recipient == "sarah@client.com")
    }

    @Test func coldTargetPromptAsksForAColdIntro_warmReferencesTheDeal() async throws {
        let (a, gen, _) = agent(responses: ["B", "B"])
        let cold = OX.target(contact: "new@lead.com")                                   // no deal/thread
        let warm = OX.target(contact: "acme@client.com",
                             deal: OX.deal(contact: "acme@client.com", company: "Acme",
                                           touchedDaysAgo: 30))                          // deal present
        _ = try await a.outreach(to: [cold, warm], context: OX.context(), tools: tools(FakeTextGenerator()))
        let prompts = await gen.recordedPrompts
        #expect(prompts[0].lowercased().contains("cold"))      // cold intro instruction
        #expect(prompts[1].contains("Acme"))                   // warm prompt mentions the deal's company
    }

    @Test func generatorGetsABoundedTokenBudget() async throws {
        let (a, gen, _) = agent()
        _ = try await a.outreach(to: [OX.target(contact: "a@x.com")],
                                 context: OX.context(), tools: tools(FakeTextGenerator()))
        // Single call; the agent uses its bounded outreach budget.
        #expect(await gen.recordedPrompts.count == 1)
        #expect(OutreachAgent.maxDraftTokens == 384)
    }
}
```

- [ ] **Run to fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter OutreachAgentTests`
  - Expected: compile error — `value of type 'OutreachAgent' has no member 'outreach'`.

- [ ] **Implement:** add to `OutreachAgent.swift` (inside the struct, after `proposals(...)`):

```swift
    // MARK: - List-driven outreach (the real entry point)

    /// Generates a voice-conditioned outreach draft for each ELIGIBLE target (cooldown + cap
    /// applied via the injected policy). Each result is an OUTBOUND proposal (`Action.send`),
    /// so the caller/Orchestrator enqueues every one for human approval — never auto-sent.
    /// PURE except the injected voice/generator seams (no store I/O here; cooldown reads the
    /// `Deal.lastTouch` already on each target).
    public func outreach(
        to targets: [OutreachTarget],
        context: AgentContext,
        tools: AgentTools
    ) async throws -> [OutreachProposal] {
        let eligible = policy.eligible(from: targets, now: context.now)
        var proposals: [OutreachProposal] = []
        for target in eligible {
            let draftGoal = Self.draftGoal(for: target)
            let prefix = try await voice.voicePrefix(recipient: target.contact, draftGoal: draftGoal)
            let prompt = Self.buildPrompt(voicePrefix: prefix, target: target, account: context.account)
            let raw = try await generator.generate(prompt: prompt, maxTokens: Self.maxDraftTokens)
            let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = Self.subject(for: target)
            proposals.append(OutreachProposal.make(
                account: context.account, contact: target.contact,
                subject: subject, body: body, now: context.now))
        }
        return proposals
    }

    // MARK: - Prompt assembly (pure, static)

    /// One-line goal fed to voice conditioning.
    static func draftGoal(for target: OutreachTarget) -> String {
        if let company = target.deal?.company {
            return "Write a warm outreach email to a contact at \(company)"
        }
        return "Write a cold outreach email to a new prospect"
    }

    /// Subject line for the new conversation.
    static func subject(for target: OutreachTarget) -> String {
        if let company = target.deal?.company {
            return "Following up — \(company)"
        }
        return "Quick introduction"
    }

    /// Voice prefix + (warm) deal/thread context + an explicit cold/warm outreach instruction.
    static func buildPrompt(voicePrefix: String, target: OutreachTarget, account: String) -> String {
        var lines: [String] = []
        lines.append(voicePrefix)
        lines.append("")
        if let deal = target.deal {
            lines.append("CONTEXT (existing relationship):")
            if let company = deal.company { lines.append("Company: \(company)") }
            lines.append("Pipeline stage: \(deal.stage.rawValue)")
            if let score = deal.score { lines.append("Lead score: \(score)") }
            lines.append("")
        }
        if !target.thread.isEmpty {
            lines.append("PRIOR THREAD (oldest first):")
            for m in target.thread.sorted(by: { $0.date < $1.date }) {
                let who = m.isFromUser ? "Me" : m.from
                lines.append("From: \(who)")
                lines.append(m.body)
                lines.append("---")
            }
            lines.append("")
        }
        if target.isWarm {
            lines.append("Write a warm, personalized outreach email to \(target.contact). "
                + "Reference our existing relationship. Write only the email body, in my voice. "
                + "Do not include headers or a subject line.")
        } else {
            lines.append("Write a cold, personalized outreach email to \(target.contact). "
                + "Keep it short and respectful. Write only the email body, in my voice. "
                + "Do not include headers or a subject line.")
        }
        return lines.joined(separator: "\n")
    }
```

- [ ] **Run to pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter OutreachAgentTests`
  - Expected: 8 pass (3 from Task 4 + 5 here).

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: OutreachAgent.outreach(to:) — voice-conditioned outbound drafts per eligible target

Cold/warm prompt framing; bounded budget; every draft is Action.send (always queues).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6 — Cooldown/cap enforcement at the agent level + dormant-deal selector

**Files:**
- Edit: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/OutreachAgent.swift` (add `dormantTargets(in:now:)`)
- Edit: `Packages/SenaniEngine/Tests/SenaniEngineTests/Outreach/OutreachAgentTests.swift` (append cooldown/cap + dormant tests)

`outreach(...)` already routes through `policy.eligible`; these tests prove the **per-contact cooldown** and **per-run cap** at the agent boundary (not just the policy unit), and that no model call is wasted on a cooled/over-cap target. `dormantTargets(in:now:)` is the **daily-hook selector**: a pure read over the injected `PipelineStore` that returns `OutreachTarget`s for open deals (`.qualified`/`.proposal`/`.negotiation`) whose `lastTouch` is older than the cooldown — the Scheduler's daily hook calls this to assemble the list it then passes to `outreach(...)`.

- [ ] **Append failing tests** to `OutreachAgentTests.swift`:

```swift
extension OutreachAgentTests {
    @Test func cooledContactsAreSkippedAndCostNoModelCall() async throws {
        let (a, gen, _) = agent(responses: ["B", "B"])
        let cooled = OX.target(contact: "cooled@x.com",
                               deal: OX.deal(contact: "cooled@x.com", touchedDaysAgo: 1))   // < 7
        let fresh  = OX.target(contact: "fresh@x.com")
        let out = try await a.outreach(to: [cooled, fresh], context: OX.context(), tools: tools(FakeTextGenerator()))
        #expect(out.map { $0.message.to.first } == ["fresh@x.com"])
        #expect(await gen.recordedPrompts.count == 1)   // only the eligible contact hit the model
    }

    @Test func perRunCapBoundsTheNumberOfDrafts() async throws {
        let gen = FakeTextGenerator(responses: ["B"])
        let voice = FakeVoicePrefixProvider(prefix: "V")
        let capped = OutreachAgent(generator: gen, voice: voice,
                                   policy: OutreachPolicy(cooldownDays: 7, maxPerRun: 2))
        let targets = (1...5).map { OX.target(contact: "c\($0)@x.com") }
        let out = try await capped.outreach(to: targets, context: OX.context(), tools: tools(FakeTextGenerator()))
        #expect(out.count == 2)
        #expect(await gen.recordedPrompts.count == 2)   // never generates beyond the cap
    }

    @Test func outreachNeverProducesAnExecutedOrSentOutcome() {
        // Defense: every action this agent can emit is outbound, so ActionRouter.route — under ANY
        // autonomy — yields .queuedForApproval, never .executed/.prepared.
        for autonomy in [Autonomy.ask, .prepare, .auto] {
            let outcome = ActionRouter.route(.send(body: "x"), autonomy: autonomy)
            #expect(outcome == .queuedForApproval)
        }
    }

    @Test func dormantTargetsReturnsOpenDealsPastCooldown() throws {
        let (a, _, _) = agent()
        let store = InMemoryPipelineStore([
            OX.deal(contact: "stale@x.com", stage: .proposal, touchedDaysAgo: 30),   // dormant → included
            OX.deal(contact: "recent@x.com", stage: .qualified, touchedDaysAgo: 2),  // within cooldown → excluded
            OX.deal(contact: "won@x.com", stage: .won, touchedDaysAgo: 30),          // closed → excluded
        ])
        let targets = try a.dormantTargets(in: store, now: OX.now)
        #expect(targets.map(\.contact) == ["stale@x.com"])
        #expect(targets.first?.deal?.stage == .proposal)
    }

    @Test func dormantTargetsThenOutreachQueuesDraftsForReactivation() async throws {
        let (a, gen, _) = agent(responses: ["Reactivation nudge."])
        let store = InMemoryPipelineStore([
            OX.deal(contact: "stale@x.com", stage: .negotiation, company: "Acme", touchedDaysAgo: 45),
        ])
        let targets = try a.dormantTargets(in: store, now: OX.now)
        let out = try await a.outreach(to: targets, context: OX.context(), tools: tools(FakeTextGenerator()))
        #expect(out.count == 1)
        #expect(out.first?.action == .send(body: "Reactivation nudge."))
        #expect(out.first?.action.actionClass == .outbound)
        _ = gen   // silence unused warning if any
    }
}
```

- [ ] **Run to fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter OutreachAgentTests`
  - Expected: compile error — `value of type 'OutreachAgent' has no member 'dormantTargets'`.

- [ ] **Implement:** add to `OutreachAgent.swift` (inside the struct):

```swift
    // MARK: - Dormant-deal reactivation (daily-hook selector)

    /// Open deal stages eligible for reactivation outreach.
    static let openStages: Set<DealStage> = [.new, .qualified, .proposal, .negotiation]

    /// Pure read over the injected PipelineStore: returns outreach targets for OPEN deals whose
    /// `lastTouch` is older than the policy cooldown. The Scheduler's daily hook calls this to
    /// assemble the list it then passes to `outreach(to:context:tools:)`. No generation here.
    public func dormantTargets(in store: any PipelineStore, now: Date) throws -> [OutreachTarget] {
        let cooldown = policy.cooldownDays * 86_400
        return try store.all()
            .filter { Self.openStages.contains($0.stage) }
            .filter { now.timeIntervalSince($0.lastTouch) >= cooldown }
            .sorted { $0.lastTouch < $1.lastTouch }    // most dormant first
            .map { OutreachTarget(contact: $0.contactEmail, deal: $0, thread: []) }
    }
```

- [ ] **Run to pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter OutreachAgentTests`
  - Expected: 13 pass (8 prior + 5 here).

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: Outreach cooldown/cap enforcement + dormantTargets daily-hook selector

Cooled/over-cap targets cost no model call; outbound-only ⇒ never executed/sent.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7 — Full suite green + public surface check

**Files:** none (verification).

- [ ] **Run the full suite:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test`
  - Expected: ALL suites pass — the pre-existing Triage/ReplyDrafter/Orchestrator/Scheduler suites PLUS `OutreachTargetTests`, `OutreachProposalTests`, `OutreachAgentTests`. Zero failures, strict-concurrency clean (no `Sendable`/data-race warnings). If a pre-existing suite broke, you changed a shared file (most likely `TestSupport.swift`) — revert the unrelated change.

- [ ] **Confirm public surface** matches this plan: `OutreachAgent` (`id == "outreach"`, `autonomy == .ask`, `wakesFor == false`, inbound `proposals == []`, `outreach(to:context:tools:) -> [OutreachProposal]`, `dormantTargets(in:now:) -> [OutreachTarget]`, `static maxDraftTokens == 384`); `OutreachTarget`; `OutreachPolicy` (`cooldownDays`, `maxPerRun`, `isOnCooldown`, `eligible`); `OutreachProposal` (`message`, `action`, `make(...)`); the `PipelineStore`/`Deal`/`DealStage` seam (bootstrap or imported). Verify every emittable action is `Action.send` (`actionClass == .outbound`).

- [ ] **Commit (if any cleanup):**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: full Outreach suite green; public contract verified

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8 — Record §5 blocking item + §3/contract notes (FLAG TO HUMAN)

**Files:**
- Edit: `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md` (record the compose-outbound escalation + the outreach modeling decision)

This task does NOT touch code. It records the **blocking action-model decision** so the human can sign off, per §5 of the reconciliation doc ("a NEW Action case requires human sign-off").

- [ ] **Append to §5 ("Open items for the human")** in `2026-05-31-APP-PLANS-RECONCILIATION.md`:

```md
- **NEW `Action` case — compose-new-outbound-message (Outreach agent, BLOCKING — human sign-off required).**
  `SenaniRules.Action` (frozen) has NO "compose a brand-new outbound message to a new recipient"
  case. Its outbound cases are `.reply(body:)` (reply in an existing thread), `.forward(to:body:)`,
  and `.send(body:)` (body only — no first-class recipient/subject). The Outreach agent
  (`2026-05-31-outreach-agent.md`) needs to originate a NEW conversation with a contact who is not
  already in a thread. **Decision deferred to the human:** either (a) extend `SenaniRules.Action`
  with `case compose(to: String, subject: String, body: String)` (`actionClass == .outbound`) and
  re-freeze the package — the clean long-term model; or (b) keep the current STOPGAP: the Outreach
  agent emits `Action.send(body:)` (outbound → always queues) and carries the recipient + subject on
  the synthesized `Proposal.message` (`from = account`, `to = [contact]`, `isFromUser = true`,
  subject/body set), which the Approval-queue UI / `GmailMailBackend` reads at execution time.
  Until the human chooses, the stopgop (b) is in effect — it preserves the trust model (outbound
  ALWAYS queues, never auto-sent) without forking the action model. If (a) is approved, swapping
  `OutreachProposal.make` to build `.compose(...)` is a one-helper mechanical change.
- **Outreach is list-driven, not inbound-triggered.** The Outreach agent's `Agent.wakesFor` is
  always `false` and its inbound `proposals` returns `[]`; the work is `OutreachAgent.outreach(to:
  context:tools:)` over a user-supplied target list, plus `dormantTargets(in:now:)` for the
  Scheduler's daily dormant-deal reactivation hook. The Orchestrator/Scheduler plans own *assembling
  the target list and invoking* these methods (on a user action / the daily hook) and enqueuing each
  returned `OutreachProposal` via `ApprovalStore.enqueue(id:_:)` with `Trigger.rule(id: "outreach")`
  — the SAME single safety path every other agent uses.
- **`Deal` shape divergence (Outreach/Lead-Qualifier vs Follow-up).** The Outreach + Lead-Qualifier
  plans pin the richer `Deal(id, contactEmail, company, stage, score, value, lastTouch: Date,
  sourceMessageId)`; the Follow-up plan pins a leaner `Deal(id, contact, threadId, stage, lastTouch:
  Date?)`. These MUST reconcile to ONE definition (owned by `pipeline-crm-view`) before any Phase-3
  agent persists. Coordinate on the `pipeline-crm-view` claim slug.
```

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail && git add docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md && git commit -q -m "$(cat <<'EOF'
docs: record compose-outbound Action escalation + Outreach modeling decision (§5)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

> If `2026-05-31-APP-PLANS-RECONCILIATION.md` lives in a different git repo/worktree than `Packages/SenaniEngine`, run the commit from that repo's root instead; the edit content is unchanged.

---

## Self-Review

**Scope coverage (brief):**
- `OutreachAgent: SenaniEngine.Agent`, **co-located in `Packages/SenaniEngine/Sources/SenaniEngine/Agents/`** alongside the Triage + Reply Drafter agents (verified that directory + those agents exist on disk). ✅
- **Behavior:** generates a personalized cold/warm outreach draft per target contact/deal (from `PipelineStore` + optional thread context) via `VoicePrefixProviding` → `VoiceConditioner.promptPrefix(profile:recipient:draftGoal:)` + the injected `TextGenerator.generate`. Outreach to a NEW recipient is **not** a reply (synthesized fresh `Message`/`threadId`, `Action.send` not `Action.reply`). ✅
- **CRITICAL ACTION-MODEL CHECK:** verified `SenaniRules.Action` has **no compose-new-message case** (only `.reply`/`.forward`/`.send`/`.draft`). The plan does **NOT fork the action model**; it FLAGS a new `compose(to:subject:body:)` case as a **§5 blocking item for the human (Task 8)**, and for now models outreach as a **queued DRAFT proposal** via the closest existing outbound mechanism — **`Action.send(body:)`** (stated exactly; chosen because it is the only existing case that is BOTH `outbound` (always queues) AND "originate a message" rather than "reply in thread"; `.draft` is `reversible` and would auto-apply, breaking the trust model). The recipient/subject travel on the synthesized `Proposal.message`. Approval-gated: outbound ⇒ `ActionRouter.route` ALWAYS yields `.queuedForApproval` (verified `Routing.swift` first line). ✅
- **Triggering:** user-initiated / list-driven — modeled as `outreach(to:context:tools:)` over a target list, plus dormant-deal reactivation via `dormantTargets(in:now:)` for the Scheduler's daily hook. Inbound `wakesFor`/`proposals` are inert. Generation is PURE/testable (only injected generator/voice seams + synchronous `PipelineStore` reads). ✅
- **TESTS (pure):** a target contact → a queued outbound outreach draft with the voice prefix in the prompt (existing prompt-recording `FakeTextGenerator`); every emittable action is outbound (so it queues — asserted under all three autonomy dials → never `.executed`/`.prepared`); respects per-contact cooldown + per-run cap (cooled/over-cap targets cost no model call). In-memory `PipelineStore` fake + fake generator. No MLX/Gmail/network/SwiftUI anywhere. ✅

**Real-source reconciliations (verified, recorded in the plan):**
1. `SenaniEngine` already exists & is built (Agent/AgentContext/AgentTools/Orchestrator + Triage/ReplyDrafter agents) → this plan ADDS files, does NOT scaffold. ✅
2. `AgentTools` exposes only `generateJSON` (NOT `generate`) → the agent holds its OWN injected `TextGenerator` and calls `generate` directly, exactly like `ReplyDrafterAgent`. ✅
3. `Action` has no compose case; `.send` is the closest outbound mechanism; `.draft` rejected (reversible → would auto-apply). New `.compose` case flagged as §5 blocking. ✅
4. `PipelineStore`/`Deal`/`DealStage` owned by `pipeline-crm-view`, not landed → bootstrapped idempotently (skip if a sibling Phase-3 plan already created it), pinned to the Lead-Qualifier richer `Deal`. The Follow-up plan's leaner `Deal` divergence is flagged for reconciliation. ✅
5. `SenaniInference` ships no fakes, but `SenaniEngineTests` already has `FakeTextGenerator` + `FakeVoicePrefixProvider` → reused; no new fakes. ✅
6. `AgentContext` has no `pipeline` field on disk yet → this plan deliberately takes `PipelineStore` as an explicit parameter to `outreach`/`dormantTargets`, so it is independent of whether the Lead-Qualifier plan landed first (no dependency on the un-landed `AgentContext.pipeline` addition). ✅

**Conventions (§4):** agent is pure (only injected generator/voice + synchronous store reads); ONE safety path (outbound → `ActionRouter` queues, enqueued by the Orchestrator/caller via `ApprovalStore`); reads through the injected store seam, never hand-rolled SQL; macOS 14 / Swift 6.2 / strict concurrency / Swift Testing; TDD bite-sized steps with complete code, run-to-fail/run-to-pass commands + expected output, frequent commits. ✅

**Open items flagged to the human (Task 8):**
- **NEW `Action.compose(to:subject:body:)` case** — BLOCKING change to frozen `SenaniRules`; human signs off on (a) extend+re-freeze vs (b) keep the `Action.send` + recipient-on-Message stopgap. The mechanical swap point is `OutreachProposal.make`.
- **Orchestrator/Scheduler ownership** of assembling the target list + invoking `outreach(...)`/`dormantTargets(...)` and enqueuing each `OutreachProposal` via `ApprovalStore` with `Trigger.rule(id: "outreach")`.
- **`Deal` shape reconciliation** between the Outreach/Lead-Qualifier richer pin and the Follow-up leaner pin — must converge to the one `pipeline-crm-view` owns. Coordinate on the `pipeline-crm-view` claim slug; only ONE plan defines `PipelineStore`/`Deal`/`DealStage` in the final tree.
