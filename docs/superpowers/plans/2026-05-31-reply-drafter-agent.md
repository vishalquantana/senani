# Reply Drafter Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the **Reply Drafter Agent** — a pure `SenaniEngine.Agent` that wakes for messages flagged *needs-reply*, assembles a **voice-conditioned prompt** (`VoiceConditioner` prefix + thread context + a draft instruction), calls `SenaniInference.TextGenerator.generate(prompt:maxTokens:)`, and emits a single **outbound** reply Action via `AgentTools`. Because the action is `ActionClass.outbound`, `ActionRouter` ALWAYS routes it to the approval queue — it is never auto-sent. Fully unit-tested with a local prompt-recording `FakeTextGenerator`; no MLX, no Gmail, no network.

**Architecture:** `ReplyDrafterAgent` conforms to `SenaniEngine.Agent` (the §3 contract from [`2026-05-31-APP-PLANS-RECONCILIATION.md`](2026-05-31-APP-PLANS-RECONCILIATION.md)). It is **co-located in `Packages/SenaniEngine`** alongside the `Agent`/`AgentContext`/`AgentTools` definitions, matching the Triage agent's co-location decision (see *Cross-package assumptions* → **SenaniEngine dependency**). `wakesFor(_:context:)` is a pure predicate that returns `true` only when the orchestrator has marked the message as needs-reply — surfaced through a new **`AgentContext.needsReply: Bool`** field (a SenaniEngine contract addition this plan introduces and flags for the orchestrator owner). `proposals(for:context:tools:)` builds the prompt from an injected **`VoicePrefixProviding`** seam (which wraps `SenaniVoice.VoiceConditioner.promptPrefix(profile:recipient:draftGoal:)` in production) + the `context.thread` rendered as transcript + a draft instruction, calls the injected `TextGenerator.generate`, and returns `[tools.draftReply(to: original, body: generated)]`. `AgentTools.draftReply` maps to `SenaniRules.Action.reply(body:)`, whose `actionClass == .outbound`, so the Orchestrator's `ActionRouter.route` always yields `.queuedForApproval`. This plan emits the proposed draft only; **execution-on-approve (creating the Gmail DRAFT via `GmailMailBackend`) belongs to the Approval-queue UI plan.**

**Tech Stack:** Swift 6.2, `swift-tools-version: 6.0`, macOS 14, strict concurrency (complete), Swift Testing (`import Testing`). Path deps: `../SenaniRules`, `../SenaniStore`, `../SenaniInference`, `../SenaniVoice`.

**Working directory:** All `swift` commands run from `/Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine` unless stated otherwise.

**Out of scope (separate plans):** the Orchestrator/Scheduler/AgentRegistry runtime and the live wiring that populates `AgentContext.needsReply` from `SenaniReplyZero.NeedsReplyStore` (orchestrator plan); the Triage agent (its own plan, co-owner of `SenaniEngine`); building the live `VoiceConditioner`/`Embedder`/`VectorIndex`/`VoiceProfile` (Voice plan, already built); the MLX `TextGenerator` (inference plan); executing an approved draft into Gmail as a DRAFT (`GmailMailBackend`, owned by the Approval-queue UI plan).

---

## Cross-package assumptions (verified from source — state to the human before coding)

### `SenaniEngine` dependency — co-location decision (FLAG TO HUMAN)
`Packages/SenaniEngine` **does not yet exist on disk** (verified: `ls Packages/` shows the nine engine packages + `SenaniReplyZero`/`SenaniVoice`, no `SenaniEngine`). Per §3 of the reconciliation doc, `SenaniEngine` is a NEW app-tier package owning `Agent`, `AgentContext`, `AgentTools`, `AgentRegistry`, `Orchestrator`, `Scheduler`. The Reply Drafter is **co-located inside `SenaniEngine`** (same package as the protocol + the Triage agent), matching the Triage plan's co-location choice.

- **If `SenaniEngine` already exists** when this plan runs (the orchestrator/Triage plan landed first): do NOT recreate the package or redefine `Agent`/`AgentContext`/`AgentTools`. Skip Task 1's package scaffold and Task 2's protocol file; add only `ReplyDrafterAgent.swift` + `VoicePrefixProviding.swift` + tests. Verify the on-disk `Agent`/`AgentContext`/`AgentTools` match the §3 signatures pinned below; if they differ, adapt `ReplyDrafterAgent` to the real ones and record the deviation in the commit body.
- **If `SenaniEngine` does not exist** (this plan runs first): Tasks 1–2 scaffold the package and define the §3 contracts so the agent compiles and is testable today. The Triage/orchestrator plans then build on these exact files. **This is a shared-file coordination point** — flag it to the human so two plans do not both scaffold `SenaniEngine`.

### `SenaniRules` (built + frozen, do NOT edit — verified)
- `public struct Message: Sendable, Equatable, Identifiable` with `id, from, to:[String], subject, body, hasAttachment, listUnsubscribeHeader, labels, threadId, date, isFromUser` and computed `var senderDomain: String` (`Message.swift`).
- `public enum Action: Sendable, Equatable` (`Action.swift`). Verified cases include `.draft(body: String)`, `.reply(body: String)`, `.send(body: String)`, `.label`, `.archive`, `.markRead`, `.flagNeedsReply`, `.runAgent(id:)`, etc.
- `public enum ActionClass: Sendable, Equatable { case reversible; case outbound }` and `extension Action { public var actionClass: ActionClass }`. **Verified:** `.reply`, `.forward`, `.send`, `.markSpam` are `.outbound`; `.draft` is `.reversible`.
- `public enum ActionRouter { public static func route(_ action: Action, autonomy: Autonomy) -> Outcome }` — **verified first line:** `if action.actionClass == .outbound { return .queuedForApproval }` (`Routing.swift`). So an outbound action ALWAYS queues regardless of autonomy.
- `public enum Outcome { case executed, prepared, queuedForApproval }`; `public enum Trigger { case rule(id:), chat(turnId:) }`.

> **`draftReply` → which `Action` case? (reconciliation, FLAG TO HUMAN).** §3 declares `AgentTools.draftReply(to:body:) -> Action` and the brief says it is `ActionClass.outbound` so it ALWAYS queues, and on approval the Approval-UI executes it as a Gmail **DRAFT** (not a send). The real frozen `Action` has two relevant cases: `.draft(body:)` (`.reversible` — would auto-execute under `.auto`/`.prepare`, violating "always queues") and `.reply(body:)` (`.outbound` — always queues). To honor the brief's safety guarantee ("outbound → always routes to approval, never auto-sent") **`draftReply` builds `Action.reply(body:)`**. The "DRAFT vs send" distinction is an **execution-time** concern owned by the Approval-UI plan: when the human approves this queued `.reply`, that plan calls `GmailMailBackend.apply(_:to:)` which creates a Gmail DRAFT rather than sending. This plan does NOT add a new `Action` case (a new case would be a blocking change to a frozen package per §5). If the human later wants a dedicated `.draftReply` outbound case on `SenaniRules.Action`, that is the §5 escalation path; until then `draftReply == Action.reply(body:)` is the correct mapping and is asserted in tests via `actionClass == .outbound`.

### `SenaniInference` (built + frozen, NO fakes shipped — verified)
- `public protocol TextGenerator: Sendable { func generate(prompt: String, maxTokens: Int) async throws -> String; func generateJSON(prompt: String, schema: JSONSchema) async throws -> String }` (`TextGenerator.swift`).
- **No `FakeTextGenerator` exists** in `SenaniInference` (verified: only `MLXTextGenerator`, `MLXEmbedder`, `Embedder`, `GemmaPredicateEvaluator`, `JSONSchema`, etc.). This plan defines its **own** prompt-recording fake in the test target (Task 3).

### `SenaniVoice` (built + frozen — verified)
- `public struct VoiceConditioner: Sendable` with `public init(embedder: any Embedder, index: any VectorIndex)` and:
  ```swift
  public func promptPrefix(profile: VoiceProfile, recipient: String, draftGoal: String) async throws -> String
  ```
  (verified `VoiceConditioner.swift`). **NOTE:** the real signature is `promptPrefix(profile:recipient:draftGoal:)`, NOT the brief's shorthand `promptPrefix(for: domain)`. It needs a `VoiceProfile`, an `Embedder`, and a `VectorIndex` — none of which are on the §3 `AgentContext`. To keep the agent pure and avoid threading three live dependencies through the agent, this plan introduces a **`VoicePrefixProviding`** seam (Task 4): an async closure-like protocol `func voicePrefix(recipient:draftGoal:) async throws -> String`. In production it is satisfied by a small adapter that holds the user's `VoiceProfile` + a `VoiceConditioner` and calls `promptPrefix(profile:recipient:draftGoal:)`. In tests it is a recording fake returning a canned prefix. This isolates the agent from the live embedder/index/profile and keeps it unit-testable.
- `public struct VoiceProfile: Codable, Sendable, Equatable` (`scope, averageSentenceWords, greeting?, signoff?, commonPhrases, emojiRate, perDomain`). Used only by the production `VoicePrefixProviding` adapter, not by the agent itself.

### `SenaniReplyZero` (built + frozen — verified)
- `public struct ReplyZeroService: Sendable { public func scan(threads: [String: [Message]]) async throws; public func needsYou() throws -> [NeedsReplyFlag]; public func count() throws -> Int }` (`ReplyZeroService.swift`).
- `public struct NeedsReplyStore` with `pending() throws -> [NeedsReplyFlag]` where `NeedsReplyFlag { threadId, messageId, flaggedAt }` (`NeedsReplyStore.swift`).
- **The agent never reads these stores directly** (§4 convention: agents are pure; the Orchestrator pre-populates context). The needs-reply signal reaches the agent through **`AgentContext.needsReply: Bool`**, which the Orchestrator sets from `NeedsReplyStore.pending()` / `ReplyZeroService.needsYou()` before invoking the agent. This `needsReply` field is the **SenaniEngine contract addition** introduced by this plan (Task 2) — flag it to the orchestrator-plan owner so the Orchestrator populates it.

### `AgentContext` / `AgentTools` / `Agent` — §3 signatures this plan PINS
The §3 contract (reconciliation doc) for the types defined in Task 2, plus the one additive field:
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
    public let needsReply: Bool       // ⚠ ADDITION (this plan): orchestrator pre-populates from ReplyZero
}
public struct AgentTools: Sendable {
    public func draftReply(to message: Message, body: String) -> Action
    public func proposeLabel(_ label: String, on message: Message) -> Action
    public func archive(_ message: Message) -> Action
    public func markRead(_ message: Message) -> Action
}
```
`Rule` comes from `SenaniRules`; `VectorHit` from `SenaniStore`; `Autonomy`/`Message`/`Action` from `SenaniRules`.

> **If the Triage plan already defined `AgentContext` WITHOUT `needsReply`:** add the field as a defaulted member (`needsReply: Bool = false` in the initializer) so existing call sites still compile, and record it as an additive, non-breaking SenaniEngine contract change in the commit body.

---

## File Structure

```
Packages/SenaniEngine/
  Package.swift                                  # (Task 1 — only if SenaniEngine absent)
  Sources/SenaniEngine/
    AgentContract.swift                          # (Task 2) Agent, AgentContext, AgentTools  — shared §3 types
    VoicePrefixProviding.swift                   # (Task 4) seam + production VoiceConditioner adapter
    ReplyDrafterAgent.swift                       # (Task 5) the agent
  Tests/SenaniEngineTests/
    ReplyDrafter/
      ReplyDrafterFixtures.swift                  # (Task 3) Message/thread builders + helpers
      RecordingTextGenerator.swift                # (Task 3) local prompt-recording FakeTextGenerator
      FakeVoicePrefixProvider.swift               # (Task 4) recording voice-prefix fake
      ReplyDrafterWakesForTests.swift             # (Task 5)
      ReplyDrafterProposalsTests.swift            # (Task 5)
```

> If `SenaniEngine` already exists, only the `ReplyDrafter/` test folder and the three new `Sources` files (`VoicePrefixProviding.swift`, `ReplyDrafterAgent.swift`, and — only if missing — the `needsReply` field on `AgentContext.swift`) are added.

---

## Task 1 — Package scaffold (skip if `SenaniEngine` already exists)

**Files:**
- Create: `Packages/SenaniEngine/Package.swift`
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/AgentContract.swift` (temporary one-line marker)

- [ ] **First, check whether the package exists:**

```
ls /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine 2>/dev/null && echo EXISTS || echo ABSENT
```
- **If `EXISTS`:** skip Tasks 1 and 2 entirely; jump to Task 3. (Verify the existing `Agent`/`AgentContext`/`AgentTools` against the §3 signatures above; adapt later tasks to the real shapes and record any deviation.)
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

## Task 2 — Agent contract types (Agent / AgentContext / AgentTools) (skip if already defined)

**Files:**
- Replace: `Packages/SenaniEngine/Sources/SenaniEngine/AgentContract.swift`
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/ReplyDrafter/ReplyDrafterFixtures.swift` will exercise these in Task 3; here a tiny contract test confirms `draftReply` is outbound.

> If `SenaniEngine` already defines these (Task 1 said `EXISTS`), skip this task. If it defines them but **without** `AgentContext.needsReply`, add only that field (defaulted) and skip the rest.

- [ ] **Write failing test** `Packages/SenaniEngine/Tests/SenaniEngineTests/ReplyDrafter/AgentToolsContractTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct AgentToolsContractTests {
    private func msg() -> Message {
        Message(
            id: "m1", from: "sarah@client.com", to: ["ramesh@quantana.in"],
            subject: "Proposal", body: "Could you send the figures?",
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: "t1", date: Date(timeIntervalSince1970: 1_000_000), isFromUser: false
        )
    }

    @Test func draftReplyProducesAnOutboundReplyAction() {
        let tools = AgentTools()
        let action = tools.draftReply(to: msg(), body: "Sure — attached.")
        #expect(action == .reply(body: "Sure — attached."))
        #expect(action.actionClass == .outbound)   // ⇒ ActionRouter ALWAYS queues it
    }

    @Test func agentContextCarriesNeedsReplyFlag() {
        let ctx = AgentContext(
            account: "ramesh@quantana.in", thread: [msg()], rules: [],
            retrieve: { _, _ in [] }, now: Date(timeIntervalSince1970: 1_000_000),
            needsReply: true
        )
        #expect(ctx.needsReply == true)
        #expect(ctx.thread.count == 1)
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter AgentToolsContractTests`
  - **Expected:** compile error — `cannot find 'AgentTools' / 'AgentContext' in scope`.

- [ ] **Implement** `AgentContract.swift` (replace the placeholder):

```swift
import Foundation
import SenaniRules
import SenaniStore

/// An agent is a pure function from (message, context, tools) → proposed Actions.
/// It NEVER touches Gmail or stores directly; the Orchestrator enforces autonomy and routes
/// every returned Action through `ActionRouter` + the MailBackend/ApprovalStore/AuditLog seams.
public protocol Agent: Sendable {
    /// Stable identity, e.g. "triage", "reply-drafter".
    var id: String { get }
    /// Per-agent dial; the Orchestrator (not the agent) enforces it.
    var autonomy: Autonomy { get }
    /// Pure trigger predicate.
    func wakesFor(_ message: Message, context: AgentContext) -> Bool
    /// Pure proposal builder (its only I/O is the injected generator/retrieval the agent holds).
    func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action]
}

/// Read-only world an agent may see. Pre-populated by the Orchestrator; agents never query stores.
public struct AgentContext: Sendable {
    public let account: String
    public let thread: [Message]            // the message's thread, date ascending
    public let rules: [Rule]
    public let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit]
    public let now: Date
    /// Whether the Orchestrator has flagged this message's thread as needing the user's reply
    /// (sourced from SenaniReplyZero's NeedsReplyStore). ADDITIVE SenaniEngine field.
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

    /// A reply draft addressed back into the thread. Maps to `Action.reply(body:)`, whose
    /// `actionClass == .outbound`, so `ActionRouter` ALWAYS routes it to the approval queue
    /// (never auto-sent). On approval the Approval-UI plan executes it as a Gmail DRAFT.
    public func draftReply(to message: Message, body: String) -> Action {
        .reply(body: body)
    }

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
SenaniEngine: Agent/AgentContext/AgentTools §3 contract (+needsReply field)

draftReply maps to Action.reply (outbound) so it always queues for approval.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3 — Reply Drafter fixtures + local prompt-recording FakeTextGenerator

**Files:**
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/ReplyDrafter/ReplyDrafterFixtures.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/ReplyDrafter/RecordingTextGenerator.swift`

`SenaniInference` ships no fakes, so we define our own. The generator records every prompt it receives so the prompt-shape tests can assert the voice prefix + thread context are present.

- [ ] **Create** `ReplyDrafterFixtures.swift` (shared helpers, no `@Test`):

```swift
import Foundation
@testable import SenaniEngine
import SenaniRules

enum RD {
    static let account = "ramesh@quantana.in"
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// An incoming message from a client that asks a question.
    static func incoming(
        id: String = "m-in",
        from: String = "sarah@client.com",
        to: [String] = [account],
        subject: String = "Proposal follow-up",
        body: String = "Hi Ramesh,\n\nCould you send the latest figures?\n\nThanks,\nSarah",
        threadId: String = "t1",
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Message {
        Message(
            id: id, from: from, to: to, subject: subject, body: body,
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: threadId, date: date, isFromUser: false
        )
    }

    /// An earlier message from the user in the same thread (provides thread context).
    static func priorFromUser(
        id: String = "m-prior",
        threadId: String = "t1",
        body: String = "Hi Sarah, sending the proposal now.",
        date: Date = Date(timeIntervalSince1970: 1_699_000_000)
    ) -> Message {
        Message(
            id: id, from: account, to: ["sarah@client.com"], subject: "Proposal",
            body: body, hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: threadId, date: date, isFromUser: true
        )
    }

    /// Builds an AgentContext with the given thread and needs-reply flag.
    static func context(thread: [Message], needsReply: Bool) -> AgentContext {
        AgentContext(
            account: account, thread: thread, rules: [],
            retrieve: { _, _ in [] }, now: now, needsReply: needsReply
        )
    }
}
```

- [ ] **Create** `RecordingTextGenerator.swift` (local fake conforming to `SenaniInference.TextGenerator`):

```swift
import Foundation
import SenaniInference

/// A local prompt-recording TextGenerator. SenaniInference ships no fakes, so we define one.
/// `generate` returns a canned body and records every prompt it was asked, so tests can assert
/// the voice prefix + thread context were threaded into the prompt the model saw.
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
        // The Reply Drafter only uses `generate`; JSON path is unused here.
        lock.lock(); defer { lock.unlock() }
        prompts.append(prompt)
        return "{}"
    }

    var recordedPrompts: [String] { lock.lock(); defer { lock.unlock() }; return prompts }
    var lastPrompt: String? { recordedPrompts.last }
    var recordedMaxTokens: [Int] { lock.lock(); defer { lock.unlock() }; return maxTokensSeen }
}
```

- [ ] **Run-to-build:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift build --build-tests`
  - **Expected:** compiles (fixtures reference only existing types). No tests run yet.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: Reply Drafter test fixtures + local prompt-recording fake generator

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4 — VoicePrefixProviding seam + recording fake

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/VoicePrefixProviding.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/ReplyDrafter/FakeVoicePrefixProvider.swift`

The real `VoiceConditioner.promptPrefix(profile:recipient:draftGoal:)` needs a `VoiceProfile` + `Embedder` + `VectorIndex` — none on `AgentContext`. We wrap it behind a narrow async seam so the agent depends only on the seam and stays unit-testable.

- [ ] **Write failing test** `FakeVoicePrefixProvider.swift` (it is a test double; a tiny `@Test` confirms the production adapter compiles and forwards). First add the recording fake + a compile-smoke test:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniVoice
import SenaniInference
import SenaniStore

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

@Suite struct VoicePrefixProvidingTests {
    @Test func fakeReturnsCannedPrefixAndRecordsTheCall() async throws {
        let fake = FakeVoicePrefixProvider(prefix: "VOICE-PREFIX")
        let out = try await fake.voicePrefix(recipient: "sarah@client.com", draftGoal: "reply")
        #expect(out == "VOICE-PREFIX")
        #expect(fake.recordedCalls.first?.recipient == "sarah@client.com")
    }

    @Test func conditionerAdapterConformsAndForwardsToVoiceConditioner() async throws {
        // Compile-level guarantee that the production adapter wraps the real VoiceConditioner.
        // Uses a constant-vector embedder + empty in-memory index (no network, no MLX).
        let embedder = ConstantEmbedder()
        let index = InMemoryVectorIndex()
        let profile = VoiceProfile(
            scope: "global", averageSentenceWords: 12, greeting: "Hi", signoff: "Best,",
            commonPhrases: ["let me know"], emojiRate: 0
        )
        let adapter = VoiceConditionerPrefixProvider(
            conditioner: VoiceConditioner(embedder: embedder, index: index),
            profile: profile
        )
        let prefix = try await adapter.voicePrefix(recipient: "sarah@client.com", draftGoal: "reply about the proposal")
        #expect(prefix.contains("Best,"))   // the conditioner embeds the chosen profile's signoff
    }
}

/// Minimal deterministic embedder for the adapter smoke test (SenaniInference ships none for tests).
final class ConstantEmbedder: Embedder, @unchecked Sendable {
    func embed(_ text: String) async throws -> [Float] { [0, 0, 0] }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter VoicePrefixProvidingTests`
  - **Expected:** compile error — `cannot find 'VoicePrefixProviding' / 'VoiceConditionerPrefixProvider' in scope`.

- [ ] **Implement** `Sources/SenaniEngine/VoicePrefixProviding.swift`:

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

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter VoicePrefixProvidingTests`
  - **Expected:** both tests pass. (If `InMemoryVectorIndex()` or `Embedder` requires different construction, adjust the smoke test to the real `SenaniStore`/`SenaniInference` API and record the deviation — the seam itself is unaffected.)

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: VoicePrefixProviding seam + VoiceConditioner production adapter

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5 — ReplyDrafterAgent (wakesFor + proposals)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/ReplyDrafterAgent.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/ReplyDrafter/ReplyDrafterWakesForTests.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/ReplyDrafter/ReplyDrafterProposalsTests.swift`

### 5a. Failing `wakesFor` tests

- [ ] **Write** `ReplyDrafterWakesForTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct ReplyDrafterWakesForTests {
    private func agent() -> ReplyDrafterAgent {
        ReplyDrafterAgent(
            generator: RecordingTextGenerator(cannedBody: "ok"),
            voice: FakeVoicePrefixProvider(prefix: "VOICE")
        )
    }

    @Test func wakesForNeedsReplyMessageFromAnother() {
        let m = RD.incoming()
        let ctx = RD.context(thread: [m], needsReply: true)
        #expect(agent().wakesFor(m, context: ctx) == true)
    }

    @Test func doesNotWakeWhenNotFlaggedNeedsReply() {
        let m = RD.incoming()
        let ctx = RD.context(thread: [m], needsReply: false)
        #expect(agent().wakesFor(m, context: ctx) == false)
    }

    @Test func doesNotWakeForMessageSentByTheUser() {
        // Even if a thread is flagged, never draft a reply to our own message.
        let mine = RD.priorFromUser()
        let ctx = RD.context(thread: [mine], needsReply: true)
        #expect(agent().wakesFor(mine, context: ctx) == false)
    }

    @Test func identityAndAutonomy() {
        let a = agent()
        #expect(a.id == "reply-drafter")
        #expect(a.autonomy == .prepare)   // drafts staged; outbound still always queues regardless
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter ReplyDrafterWakesForTests`
  - **Expected:** compile error — `cannot find 'ReplyDrafterAgent' in scope`.

### 5b. Failing `proposals` tests

- [ ] **Write** `ReplyDrafterProposalsTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct ReplyDrafterProposalsTests {
    private func make(canned: String = "Sure, here are the figures.\n\nBest,\nRamesh")
        -> (ReplyDrafterAgent, RecordingTextGenerator, FakeVoicePrefixProvider) {
        let gen = RecordingTextGenerator(cannedBody: canned)
        let voice = FakeVoicePrefixProvider(prefix: "WRITE-IN-MY-VOICE-PREFIX")
        return (ReplyDrafterAgent(generator: gen, voice: voice), gen, voice)
    }

    @Test func producesASingleOutboundDraftReplyWithTheGeneratedBody() async throws {
        let (agent, _, _) = make(canned: "Sure, attached.")
        let m = RD.incoming()
        let ctx = RD.context(thread: [RD.priorFromUser(), m], needsReply: true)

        let actions = try await agent.proposals(for: m, context: ctx, tools: AgentTools())

        #expect(actions == [.reply(body: "Sure, attached.")])
        #expect(actions.first?.actionClass == .outbound)   // ⇒ ActionRouter ALWAYS queues it
    }

    @Test func draftIsAddressedBackToTheOriginalSenderInThread() async throws {
        // The draftReply tool is built from the original incoming message, so the body the
        // generator produced is wrapped as a reply to that message (same thread on execution).
        let (agent, gen, _) = make()
        let m = RD.incoming(from: "sarah@client.com")
        let ctx = RD.context(thread: [m], needsReply: true)

        let actions = try await agent.proposals(for: m, context: ctx, tools: AgentTools())

        #expect(actions == [.reply(body: gen.recordedPrompts.isEmpty ? "" : "Sure, here are the figures.\n\nBest,\nRamesh")])
        // The generator was invoked exactly once with a bounded token budget.
        #expect(gen.recordedPrompts.count == 1)
        #expect(gen.recordedMaxTokens.first == ReplyDrafterAgent.maxDraftTokens)
    }

    @Test func voicePrefixIsIncludedInThePromptTheGeneratorReceived() async throws {
        let (agent, gen, voice) = make()
        let m = RD.incoming(from: "sarah@client.com")
        let ctx = RD.context(thread: [RD.priorFromUser(), m], needsReply: true)

        _ = try await agent.proposals(for: m, context: ctx, tools: AgentTools())

        let prompt = try #require(gen.lastPrompt)
        #expect(prompt.contains("WRITE-IN-MY-VOICE-PREFIX"))   // voice prefix threaded in
        // Voice provider was asked for the original sender's address.
        #expect(voice.recordedCalls.first?.recipient == "sarah@client.com")
    }

    @Test func promptIncludesThreadContextAndADraftInstruction() async throws {
        let (agent, gen, _) = make()
        let m = RD.incoming(body: "Could you send the latest figures?")
        let prior = RD.priorFromUser(body: "Sending the proposal now.")
        let ctx = RD.context(thread: [prior, m], needsReply: true)

        _ = try await agent.proposals(for: m, context: ctx, tools: AgentTools())

        let prompt = try #require(gen.lastPrompt)
        #expect(prompt.contains("Could you send the latest figures?"))  // incoming body
        #expect(prompt.contains("Sending the proposal now."))           // prior thread message
        #expect(prompt.lowercased().contains("draft a reply"))          // the instruction
    }

    @Test func returnsNoProposalsWhenNotFlaggedNeedsReply() async throws {
        // Defensive: even if proposals() is called, an un-flagged message yields nothing
        // and never calls the generator.
        let (agent, gen, _) = make()
        let m = RD.incoming()
        let ctx = RD.context(thread: [m], needsReply: false)

        let actions = try await agent.proposals(for: m, context: ctx, tools: AgentTools())

        #expect(actions.isEmpty)
        #expect(gen.recordedPrompts.isEmpty)   // no model call wasted
    }

    @Test func trimsWhitespaceFromGeneratedBody() async throws {
        let (agent, _, _) = make(canned: "\n\n  Sure, attached.  \n")
        let m = RD.incoming()
        let ctx = RD.context(thread: [m], needsReply: true)
        let actions = try await agent.proposals(for: m, context: ctx, tools: AgentTools())
        #expect(actions == [.reply(body: "Sure, attached.")])
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter ReplyDrafterProposalsTests`
  - **Expected:** compile error — `cannot find 'ReplyDrafterAgent' in scope`.

### 5c. Implement the agent

- [ ] **Write** `Sources/SenaniEngine/ReplyDrafterAgent.swift`:

```swift
import Foundation
import SenaniRules
import SenaniInference

/// Phase-1 Reply Drafter. Wakes for messages the Orchestrator flagged as needing the
/// user's reply (SenaniReplyZero signal, surfaced via `AgentContext.needsReply`), builds a
/// voice-conditioned prompt (voice prefix + thread transcript + a draft instruction), asks the
/// injected TextGenerator for a body, and proposes ONE reply Action addressed back into the thread.
///
/// The proposed Action is `Action.reply` (`actionClass == .outbound`), so the Orchestrator's
/// `ActionRouter.route` ALWAYS yields `.queuedForApproval` — it is NEVER auto-sent. On human
/// approval, the Approval-queue UI plan executes it as a Gmail DRAFT via `GmailMailBackend`.
public struct ReplyDrafterAgent: Agent {
    public let id = "reply-drafter"
    /// `.prepare` is the per-agent dial; irrelevant to safety here because the emitted action is
    /// outbound and `ActionRouter` queues all outbound actions regardless of autonomy.
    public let autonomy: Autonomy = .prepare

    /// Bounded generation budget for a single reply body.
    public static let maxDraftTokens = 512

    private let generator: any TextGenerator
    private let voice: any VoicePrefixProviding

    public init(generator: any TextGenerator, voice: any VoicePrefixProviding) {
        self.generator = generator
        self.voice = voice
    }

    /// Wakes only for a needs-reply-flagged message that is NOT from the user.
    public func wakesFor(_ message: Message, context: AgentContext) -> Bool {
        context.needsReply && !message.isFromUser
    }

    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        guard wakesFor(message, context: context) else { return [] }

        let recipient = message.from                       // reply goes back to the sender
        let draftGoal = Self.draftGoal(for: message)
        let prefix = try await voice.voicePrefix(recipient: recipient, draftGoal: draftGoal)
        let prompt = Self.buildPrompt(
            voicePrefix: prefix,
            thread: context.thread,
            incoming: message,
            account: context.account
        )

        let raw = try await generator.generate(prompt: prompt, maxTokens: Self.maxDraftTokens)
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return [tools.draftReply(to: message, body: body)]
    }

    // MARK: - Prompt assembly (pure, static — independently reasoned about)

    /// One-line description of what the reply should accomplish, fed to voice conditioning.
    static func draftGoal(for message: Message) -> String {
        let subject = message.subject.isEmpty ? "this email" : message.subject
        return "Draft a reply to \"\(subject)\""
    }

    /// Voice prefix + a rendered thread transcript + an explicit draft instruction.
    static func buildPrompt(voicePrefix: String, thread: [Message], incoming: Message, account: String) -> String {
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
        lines.append("Draft a reply to the latest message from \(incoming.from). "
            + "Write only the reply body, in my voice. Do not include headers or a subject line.")
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter ReplyDrafterWakesForTests`
  - **Expected:** all 4 pass.
- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter ReplyDrafterProposalsTests`
  - **Expected:** all 6 pass.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: ReplyDrafterAgent — voice-conditioned outbound draft reply

Wakes for needs-reply messages, builds a voice-prefixed prompt over the thread,
generates a body, and proposes Action.reply (outbound → always queues for approval).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6 — Full suite green + public surface check

**Files:** none (verification); delete the placeholder if it still exists.

- [ ] If `Sources/SenaniEngine/AgentContract.swift` still contains `enum SenaniEnginePlaceholder {}` alongside the real types, that is fine; if a separate `Placeholder.swift` was created, remove it.

- [ ] **Run the full suite:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test`
  - **Expected:** all suites pass — `AgentToolsContractTests`, `VoicePrefixProvidingTests`, `ReplyDrafterWakesForTests`, `ReplyDrafterProposalsTests`. Zero failures, strict-concurrency clean.

- [ ] **Confirm public surface** matches the §3 contract: `Agent`, `AgentContext` (with `needsReply`), `AgentTools` (`draftReply` → outbound `Action.reply`), `VoicePrefixProviding` (+ `VoiceConditionerPrefixProvider`), `ReplyDrafterAgent` (`id == "reply-drafter"`, `autonomy == .prepare`).

- [ ] **Commit (if any cleanup):**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: full Reply Drafter suite green; public contract verified

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Scope coverage (brief):**
- `ReplyDrafterAgent: SenaniEngine.Agent`, co-located in `Packages/SenaniEngine` per the Triage plan's co-location decision; the SenaniEngine dependency + shared-scaffold coordination is stated explicitly (Cross-package assumptions). ✅
- `wakesFor` triggers on needs-reply via `AgentContext.needsReply` — a minimal **additive** SenaniEngine contract field this plan introduces and flags to the orchestrator owner (the orchestrator pre-populates it from `NeedsReplyStore`/`ReplyZeroService`). The agent never reads the store directly (§4 purity). ✅
- Behavior: voice-conditioned prompt = voice prefix (via `VoicePrefixProviding` → `VoiceConditioner.promptPrefix(profile:recipient:draftGoal:)`) + `context.thread` transcript + draft instruction → `TextGenerator.generate(prompt:maxTokens:)` → one `draftReply` Action. ✅
- `draftReply` maps to `Action.reply(body:)` which is `ActionClass.outbound`, so `ActionRouter.route` ALWAYS queues it (verified `Routing.swift` first line). The DRAFT-vs-send boundary and execution-on-approve are explicitly assigned to the Approval-queue UI plan. ✅

**Real-source reconciliations (verified, recorded in the plan):**
1. `VoiceConditioner` real signature is `promptPrefix(profile:recipient:draftGoal:)` (needs profile + embedder + index), NOT the brief's `promptPrefix(for: domain)` → wrapped behind `VoicePrefixProviding` so the agent stays pure/testable. ✅
2. `SenaniRules.Action` has `.draft` (reversible) and `.reply` (outbound) but **no** `draftReply` case → `draftReply` builds `.reply` (outbound, always queues); no frozen package edited; new-case escalation noted as the §5 path if ever needed. ✅
3. `SenaniInference` ships NO fakes → local `RecordingTextGenerator` defined in the test target. ✅
4. `SenaniEngine` package not yet on disk → Tasks 1–2 conditionally scaffold it / define §3 types, with an explicit skip-if-exists branch and a shared-scaffold coordination flag. ✅

**Tests (pure, no MLX/Gmail/network):**
- Canned-body generator → asserts a `draftReply` Action with that body (`actions == [.reply(body: ...)]`). ✅
- Addressed to original sender, in-thread: `draftReply` built from the incoming `message`; voice provider asked for `message.from`. ✅
- Outbound assertion (`actionClass == .outbound`) proving it will queue. ✅
- Voice prefix present in the prompt the generator received (prompt-recording fake; `prompt.contains("WRITE-IN-MY-VOICE-PREFIX")`). ✅
- Does NOT wake / yields no proposals + no model call for non-needs-reply messages, and never drafts a reply to the user's own message. ✅

**Conventions (§4):** agent is pure (only injected generator/voice I/O); one safety path (outbound → `ActionRouter` queues); reads through context, never stores; macOS 14 / Swift 6.2 / strict concurrency / Swift Testing; TDD bite-sized steps with complete code, run-to-fail/run-to-pass commands + expected output, frequent commits. ✅

**Open items flagged to the human:**
- SenaniEngine package ownership / shared scaffold with the Triage + orchestrator plans (who creates `Package.swift` + `AgentContract.swift` first).
- `AgentContext.needsReply` additive field — orchestrator must populate it from `NeedsReplyStore.pending()`.
- `draftReply == Action.reply` mapping; if a dedicated outbound `.draftReply` case is desired, that is the §5 frozen-package escalation.
- The smoke test in Task 4 constructs `InMemoryVectorIndex` / an `Embedder` from `SenaniStore`/`SenaniInference`; adjust to the real constructors if they differ (the seam is unaffected).
