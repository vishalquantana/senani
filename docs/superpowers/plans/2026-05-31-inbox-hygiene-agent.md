# Inbox Hygiene Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the **Inbox Hygiene Agent** — a pure `SenaniEngine.Agent` that wakes for bulk/newsletter mail (detected via `Message.listUnsubscribeHeader != nil` and/or a Triage `Senani/Category/Newsletter` label combined with sender-domain frequency) and produces two kinds of proposals: (1) **reversible declutter** Actions — `proposeLabel("Senani/Newsletter")`, `archive`, `markRead` — which auto-apply per the agent's autonomy dial, and (2) an **approval-gated unsubscribe** Action, modeled as an OUTBOUND `Action.reply(body:)` addressed to the parsed `mailto:` unsubscribe address, which `ActionRouter` ALWAYS routes to the approval queue (never auto-sent). The agent parses the `List-Unsubscribe` header for both `mailto:` and `https:` forms; the HTTPS one-click POST capability has no `SenaniRules.Action` case and is **NOT forked into the action model** — it is flagged as a §5 blocking item for the human. Fully unit-tested with a local fake; no MLX, no Gmail, no network.

**Architecture:** `InboxHygieneAgent` conforms to `SenaniEngine.Agent` (the §3 contract from [`2026-05-31-APP-PLANS-RECONCILIATION.md`](2026-05-31-APP-PLANS-RECONCILIATION.md)). It is **co-located in `Packages/SenaniEngine/Sources/SenaniEngine/Agents/`** alongside the `Agent`/`AgentContext`/`AgentTools` definitions and the Triage / Reply Drafter agents — matching the co-location decision recorded in the Triage and Reply Drafter plans (the Orchestrator holds agent references and lives in the same package, so a package explosion is avoided). `wakesFor(_:context:)` is a pure predicate returning `true` when the message looks like bulk mail: it has a `listUnsubscribeHeader`, OR it carries the Triage-emitted `Senani/Category/Newsletter` label AND its sender domain has appeared frequently in the thread/visible context (a cheap repeat-sender heuristic, computed purely from `message` + `context.thread`). `proposals(for:context:tools:)` (a) always emits the reversible declutter set via `tools.proposeLabel`/`tools.archive`/`tools.markRead`, and (b) if a `mailto:` unsubscribe target is present in the header, emits ONE additional `tools.reply(...)`-shaped Action (mapping to `Action.reply(body:)`, `actionClass == .outbound`) addressed to that mailto address with an empty/standard unsubscribe body — so it ALWAYS queues for approval. Header parsing lives in a pure `ListUnsubscribeParser` value type (RFC 2369/8058 forms: angle-bracketed comma-separated `<mailto:...>, <https://...>`). The agent never auto-unsubscribes: outbound queues, and the HTTPS one-click path is deliberately not actioned (flagged to the human).

**Tech Stack:** Swift 6.2, `swift-tools-version: 6.0`, macOS 14, strict concurrency (complete), Swift Testing (`import Testing`). Path deps: `../SenaniRules`, `../SenaniStore`, `../SenaniInference`, `../SenaniVoice`.

**Working directory:** All `swift` commands run from `/Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine` unless stated otherwise.

**Out of scope (separate plans):** the Orchestrator/Scheduler/AgentRegistry runtime that invokes this agent and applies its routed Actions (orchestrator plan); the Triage agent that emits the `Senani/Category/Newsletter` label (its own plan, co-owner of `SenaniEngine`); executing an approved unsubscribe (`GmailMailBackend.apply`, owned by the Approval-queue UI plan); the HTTPS one-click unsubscribe POST capability (a new `Action` case / new tool — a §5 frozen-package escalation, NOT built here); the MLX `TextGenerator` (inference plan).

---

## Cross-package assumptions (verified from source — state to the human before coding)

### `SenaniEngine` dependency — co-location decision (FLAG TO HUMAN)
`Packages/SenaniEngine` **does not yet exist on disk** (verified: `ls Packages/` shows the nine engine packages + `SenaniReplyZero`/`SenaniVoice`, no `SenaniEngine`). Per §3 of the reconciliation doc, `SenaniEngine` is a NEW app-tier package owning `Agent`, `AgentContext`, `AgentTools`, `AgentRegistry`, `Orchestrator`, `Scheduler`. The Inbox Hygiene agent is **co-located inside `SenaniEngine` under `Sources/SenaniEngine/Agents/`**, matching the Triage and Reply Drafter plans' co-location choice.

- **If `SenaniEngine` already exists** when this plan runs (the orchestrator / Triage / Reply Drafter plan landed first): do NOT recreate the package or redefine `Agent`/`AgentContext`/`AgentTools`. Skip Task 1's package scaffold and Task 2's contract file; add only `Agents/InboxHygieneAgent.swift` + `Agents/ListUnsubscribeParser.swift` + tests. Verify the on-disk `Agent`/`AgentContext`/`AgentTools` match the §3 signatures pinned below; if they differ, adapt `InboxHygieneAgent` to the real ones and record the deviation in the commit body.
- **If `SenaniEngine` does not exist** (this plan runs first): Tasks 1–2 scaffold the package and define the §3 contracts so the agent compiles and is testable today. The Triage / Reply Drafter / orchestrator plans then build on these exact files. **This is a shared-file coordination point** — flag it to the human so two plans do not both scaffold `SenaniEngine`.

### `SenaniRules` (built + frozen, do NOT edit — verified from source)
- `public struct Message: Sendable, Equatable, Identifiable` (`Message.swift`) with `id, from, to: [String], subject, body, hasAttachment, listUnsubscribeHeader: String?, labels: [String], threadId, date, isFromUser` and a computed `public var senderDomain: String` (lowercased host after the last `@`, `""` if none). **`listUnsubscribeHeader` is exactly the seam this plan keys on.**
- `public enum Action: Sendable, Equatable` (`Action.swift`). Verified cases relevant here: `.label(String)`, `.archive`, `.markRead`, `.reply(body: String)`. **There is NO `unsubscribe` case** — confirmed (`label, archive, markRead, markUnread, star, unstar, move, flagNeedsReply, fileAttachment, parseDoc, runAgent, draft, reply, forward, send, markSpam, localWebhook`).
- `public enum ActionClass: Sendable, Equatable { case reversible; case outbound }` and `extension Action { public var actionClass: ActionClass }`. **Verified:** `.reply`, `.forward`, `.send`, `.markSpam` are `.outbound`; `.label`, `.archive`, `.markRead` are `.reversible`.
- `public enum ActionRouter { public static func route(_ action: Action, autonomy: Autonomy) -> Outcome }` — **verified first line** (`Routing.swift`): `if action.actionClass == .outbound { return .queuedForApproval }`. So the unsubscribe reply ALWAYS queues regardless of the agent's autonomy dial; reversible declutter Actions follow the dial (`.auto → .executed`, `.prepare → .prepared`, `.ask → .queuedForApproval`).
- `public enum Outcome { case executed, prepared, queuedForApproval }`; `public enum Trigger { case rule(id:), chat(turnId:) }`; `public enum Autonomy: String { case ask, prepare, auto }`.

> **Modeling unsubscribe without forking the Action model (CRITICAL — FLAG TO HUMAN).** The brief requires unsubscribe to be approval-gated and to NOT add a new `Action` case. The `List-Unsubscribe` header has two RFC forms: a **`mailto:`** address (send an email to unsubscribe — RFC 2369) and an **`https:`** URL (one-click POST — RFC 8058). This plan's decision:
> - **(a) `mailto:` form → an OUTBOUND `Action.reply(body:)`** addressed to the mailto target (recipient encoded into the proposal — see "recipient encoding" below). Because `.reply` is `actionClass == .outbound`, `ActionRouter.route` ALWAYS yields `.queuedForApproval`. The user approves it in the Approval queue; the Approval-UI plan executes it (sending the unsubscribe email) via `GmailMailBackend`. **No message is auto-unsubscribed.**
> - **(b) `https:` one-click POST form → FLAGGED as a §5 blocking item, NOT actioned here.** A real one-click unsubscribe is an HTTPS POST, not an email and not any existing `Action` case. Modeling it correctly needs either a new `SenaniRules.Action.unsubscribe(url:)` outbound case (a blocking change to a frozen package) or a new SenaniEngine tool + connector capability. This plan does **NOT** silently fork the action model: when only an `https:` target exists (no `mailto:`), the agent still emits the reversible declutter set, records the parsed HTTPS target on a `HygieneFinding` value it returns alongside (for the orchestrator/UI to surface), and the §5 escalation owns building the real capability. See §5 Open items.
>
> **Recipient encoding for the mailto reply.** `Action.reply(body:)` carries only a body, not a `to:` address; the routing/execution decides the recipient from the message being replied to. The unsubscribe target (`unsub@list.example.com`) is NOT the message sender. To keep this honest and not lose the target: the agent builds `Action.reply(body:)` whose body is the standardized unsubscribe text, and ALSO returns the parsed `mailtoTarget` on the `HygieneFinding` it produces, so the Approval-UI/connector plan can route the approved reply to the unsubscribe address rather than the sender. This is explicitly recorded as a constraint the Approval-UI/connector plan must honor (it is the same "execution-time concern" boundary the Reply Drafter plan drew for DRAFT-vs-send). **If the human prefers a first-class `Action.reply(to:body:)` or `Action.unsubscribe(...)`, that is the §5 escalation; until then this mapping is the safe, non-forking choice and is asserted in tests via `actionClass == .outbound`.**

### `SenaniInference` (built + frozen, NO fakes shipped — verified)
- `public protocol TextGenerator: Sendable { func generate(prompt:maxTokens:) async throws -> String; func generateJSON(prompt:schema:) async throws -> String }`. **This agent does NOT call the model** — declutter + unsubscribe are deterministic from the header/labels/domain frequency, so no `TextGenerator` is injected. (If a future iteration wants LLM-assisted bulk classification, inject it then; keeping it model-free now makes the agent trivially testable and fast.)

### `SenaniEngine` `Agent` / `AgentContext` / `AgentTools` — §3 signatures this plan PINS
The §3 contract (reconciliation doc). This plan codes to exactly these. The Reply Drafter plan adds an additive `needsReply: Bool` field to `AgentContext`; this plan does NOT depend on it, but if it is already present (defaulted) the agent still compiles.
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
    // (Reply Drafter plan may add `needsReply: Bool = false` — additive, unused here.)
}
public struct AgentTools: Sendable {
    public func reply(to message: Message, body: String) -> Action      // maps to Action.reply(body:) — OUTBOUND
    public func proposeLabel(_ label: String, on message: Message) -> Action   // reversible — Action.label(_)
    public func archive(_ message: Message) -> Action                          // reversible — Action.archive
    public func markRead(_ message: Message) -> Action                         // reversible — Action.markRead
}
```
`Rule` / `Message` / `Action` / `Autonomy` come from `SenaniRules`; `VectorHit` from `SenaniStore`.

> **`AgentTools.reply` vs `AgentTools.draftReply` naming reconciliation (FLAG TO HUMAN).** §3 of the reconciliation doc names the outbound tool `reply(to:body:)`. The Reply Drafter plan (which co-bootstraps the same `AgentTools`) named it `draftReply(to:body:)`. Both map to `Action.reply(body:)` (outbound). **This plan codes to whichever the on-disk `AgentTools` actually exposes:**
> - If `SenaniEngine` is ABSENT (this plan scaffolds Task 2), define the tool as `reply(to:body:)` per §3 and ALSO add a `draftReply(to:body:)` alias forwarding to it, so the Reply Drafter plan's call sites compile regardless of merge order.
> - If `SenaniEngine` EXISTS and exposes only `draftReply(...)`, call `tools.draftReply(...)` and record the deviation in the commit body.
> Either way the unsubscribe Action is `Action.reply(body:)`, `actionClass == .outbound`, asserted in tests.

---

## File Structure

```
Packages/SenaniEngine/
  Package.swift                                       # (Task 1 — only if SenaniEngine absent)
  Sources/SenaniEngine/
    AgentContract.swift                               # (Task 2 — only if absent) Agent, AgentContext, AgentTools §3 types
    Agents/
      ListUnsubscribeParser.swift                     # (Task 4) pure RFC 2369/8058 header parser
      InboxHygieneAgent.swift                          # (Task 5) the agent + HygieneFinding
  Tests/SenaniEngineTests/
    InboxHygiene/
      InboxHygieneFixtures.swift                       # (Task 3) Message/context builders
      ListUnsubscribeParserTests.swift                 # (Task 4)
      InboxHygieneWakesForTests.swift                  # (Task 5)
      InboxHygieneProposalsTests.swift                 # (Task 5)
```

> If `SenaniEngine` already exists, only the `InboxHygiene/` test folder and the two new `Sources/SenaniEngine/Agents/` files are added (Tasks 1–2 are skipped).

---

## Task 1 — Package scaffold (skip if `SenaniEngine` already exists)

**Files:**
- Create: `Packages/SenaniEngine/Package.swift`
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/AgentContract.swift` (temporary one-line marker)

- [ ] **First, check whether the package exists:**

```
ls /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine 2>/dev/null && echo EXISTS || echo ABSENT
```
- **If `EXISTS`:** skip Tasks 1 and 2 entirely; jump to Task 3. (Verify the existing `Agent`/`AgentContext`/`AgentTools` against the §3 signatures above; adapt later tasks to the real shapes — in particular the `reply`-vs-`draftReply` tool name — and record any deviation.)
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
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: package scaffold with engine-package path deps

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2 — Agent contract types (Agent / AgentContext / AgentTools) (skip if already defined)

**Files:**
- Replace: `Packages/SenaniEngine/Sources/SenaniEngine/AgentContract.swift`
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/InboxHygiene/AgentToolsContractTests.swift`

> If `SenaniEngine` already defines these (Task 1 said `EXISTS`), skip this task. If it defines them but the outbound tool is named `draftReply` not `reply`, do NOT redefine — just call `draftReply` in later tasks and note it.

- [ ] **Write failing test** `Packages/SenaniEngine/Tests/SenaniEngineTests/InboxHygiene/AgentToolsContractTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct AgentToolsContractTests {
    private func msg() -> Message {
        Message(
            id: "m1", from: "news@brand.com", to: ["ramesh@quantana.in"],
            subject: "Weekly digest", body: "...",
            hasAttachment: false, listUnsubscribeHeader: "<mailto:unsub@brand.com>", labels: [],
            threadId: "t1", date: Date(timeIntervalSince1970: 1_000_000), isFromUser: false
        )
    }

    @Test func replyToolProducesAnOutboundReplyAction() {
        let tools = AgentTools()
        let action = tools.reply(to: msg(), body: "Unsubscribe")
        #expect(action == .reply(body: "Unsubscribe"))
        #expect(action.actionClass == .outbound)   // ⇒ ActionRouter ALWAYS queues it
    }

    @Test func declutterToolsAreReversible() {
        let tools = AgentTools()
        let m = msg()
        #expect(tools.proposeLabel("Senani/Newsletter", on: m) == .label("Senani/Newsletter"))
        #expect(tools.proposeLabel("Senani/Newsletter", on: m).actionClass == .reversible)
        #expect(tools.archive(m) == .archive)
        #expect(tools.archive(m).actionClass == .reversible)
        #expect(tools.markRead(m) == .markRead)
        #expect(tools.markRead(m).actionClass == .reversible)
    }

    @Test func agentContextConstructs() {
        let ctx = AgentContext(
            account: "ramesh@quantana.in", thread: [msg()], rules: [],
            retrieve: { _, _ in [] }, now: Date(timeIntervalSince1970: 1_000_000)
        )
        #expect(ctx.thread.count == 1)
        #expect(ctx.account == "ramesh@quantana.in")
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
    /// Stable identity, e.g. "triage", "reply-drafter", "inbox-hygiene".
    var id: String { get }
    /// Per-agent dial; the Orchestrator (not the agent) enforces it.
    var autonomy: Autonomy { get }
    /// Pure trigger predicate.
    func wakesFor(_ message: Message, context: AgentContext) -> Bool
    /// Pure proposal builder.
    func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action]
}

/// Read-only world an agent may see. Pre-populated by the Orchestrator; agents never query stores.
public struct AgentContext: Sendable {
    public let account: String
    public let thread: [Message]            // the message's thread, date ascending
    public let rules: [Rule]
    public let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit]
    public let now: Date

    public init(
        account: String,
        thread: [Message],
        rules: [Rule],
        retrieve: @escaping @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit],
        now: Date
    ) {
        self.account = account
        self.thread = thread
        self.rules = rules
        self.retrieve = retrieve
        self.now = now
    }
}

/// Pure builders that return an `Action` — they do NOT execute anything.
public struct AgentTools: Sendable {
    public init() {}

    /// An outbound reply. Maps to `Action.reply(body:)`, whose `actionClass == .outbound`,
    /// so `ActionRouter` ALWAYS routes it to the approval queue (never auto-sent).
    public func reply(to message: Message, body: String) -> Action { .reply(body: body) }

    /// Alias kept so the Reply Drafter plan's `draftReply(...)` call sites compile regardless of
    /// merge order. Both map to the same outbound `Action.reply`.
    public func draftReply(to message: Message, body: String) -> Action { reply(to: message, body: body) }

    public func proposeLabel(_ label: String, on message: Message) -> Action { .label(label) }
    public func archive(_ message: Message) -> Action { .archive }
    public func markRead(_ message: Message) -> Action { .markRead }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter AgentToolsContractTests`
  - **Expected:** 3 tests pass.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: Agent/AgentContext/AgentTools §3 contract

reply tool maps to Action.reply (outbound, always queues); declutter tools reversible.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3 — Inbox Hygiene fixtures

**Files:**
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/InboxHygiene/InboxHygieneFixtures.swift`

Shared builders (no `@Test`) for newsletter/bulk messages, plain personal messages, and contexts with a repeat-sender thread.

- [ ] **Create** `InboxHygieneFixtures.swift`:

```swift
import Foundation
@testable import SenaniEngine
import SenaniRules

enum IH {
    static let account = "ramesh@quantana.in"
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A bulk/newsletter message. By default carries a List-Unsubscribe header with BOTH
    /// a mailto and an https form, and the Triage Newsletter category label.
    static func newsletter(
        id: String = "m-news",
        from: String = "news@brand.com",
        subject: String = "Brand Weekly — your digest",
        listUnsubscribeHeader: String? = "<mailto:unsubscribe@brand.com?subject=unsub>, <https://brand.com/u/abc123>",
        labels: [String] = ["Senani/Category/Newsletter"],
        threadId: String = "t-news",
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Message {
        Message(
            id: id, from: from, to: [account], subject: subject,
            body: "Lots of news this week. View in browser.",
            hasAttachment: false, listUnsubscribeHeader: listUnsubscribeHeader, labels: labels,
            threadId: threadId, date: date, isFromUser: false
        )
    }

    /// A genuine personal message: no List-Unsubscribe header, not categorized Newsletter.
    static func personal(
        id: String = "m-personal",
        from: String = "sarah@client.com",
        subject: String = "Quick question about the proposal",
        threadId: String = "t-personal"
    ) -> Message {
        Message(
            id: id, from: from, to: [account], subject: subject,
            body: "Hi Ramesh, could you confirm the figures?",
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: threadId, date: Date(timeIntervalSince1970: 1_700_000_000), isFromUser: false
        )
    }

    /// Builds an AgentContext from a thread.
    static func context(thread: [Message]) -> AgentContext {
        AgentContext(
            account: account, thread: thread, rules: [],
            retrieve: { _, _ in [] }, now: now
        )
    }

    /// A thread where the same domain sent several messages (repeat-sender signal).
    static func repeatSenderThread(domain: String = "brand.com", count: Int) -> [Message] {
        (0..<count).map { i in
            newsletter(
                id: "m-\(domain)-\(i)",
                from: "news@\(domain)",
                listUnsubscribeHeader: nil,        // no header — frequency is the only signal
                labels: ["Senani/Category/Newsletter"],
                threadId: "t-\(domain)",
                date: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 86_400)
            )
        }
    }
}
```

- [ ] **Run-to-build:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift build --build-tests`
  - **Expected:** compiles (fixtures reference only existing types). No tests run yet.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: Inbox Hygiene test fixtures (newsletter/personal/repeat-sender)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4 — ListUnsubscribeParser (pure RFC 2369 / 8058 header parsing)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/ListUnsubscribeParser.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/InboxHygiene/ListUnsubscribeParserTests.swift`

The `List-Unsubscribe` header is a comma-separated list of angle-bracketed URIs, e.g.
`<mailto:unsubscribe@brand.com?subject=unsub>, <https://brand.com/u/abc123>`.
The parser extracts the FIRST `mailto:` target (address only, query stripped) and the FIRST `https:`/`http:` URL. It must never crash on malformed input; unknown/empty → `nil` fields.

- [ ] **Write failing tests** `ListUnsubscribeParserTests.swift`:

```swift
import Testing
@testable import SenaniEngine

@Suite struct ListUnsubscribeParserTests {
    @Test func parsesBothMailtoAndHttps() {
        let p = ListUnsubscribeParser.parse("<mailto:unsubscribe@brand.com?subject=unsub>, <https://brand.com/u/abc123>")
        #expect(p.mailto == "unsubscribe@brand.com")          // query stripped
        #expect(p.https == "https://brand.com/u/abc123")
    }

    @Test func parsesMailtoOnly() {
        let p = ListUnsubscribeParser.parse("<mailto:bye@list.example.com>")
        #expect(p.mailto == "bye@list.example.com")
        #expect(p.https == nil)
    }

    @Test func parsesHttpsOnly() {
        let p = ListUnsubscribeParser.parse("<https://x.io/unsub?id=9>")
        #expect(p.mailto == nil)
        #expect(p.https == "https://x.io/unsub?id=9")
    }

    @Test func toleratesHttpAndWhitespaceAndNoBrackets() {
        let p = ListUnsubscribeParser.parse("  mailto:a@b.com ,  http://b.com/u  ")
        #expect(p.mailto == "a@b.com")
        #expect(p.https == "http://b.com/u")    // http accepted too
    }

    @Test func picksFirstOfEachScheme() {
        let p = ListUnsubscribeParser.parse("<mailto:first@b.com>, <mailto:second@b.com>, <https://one.example/u>, <https://two.example/u>")
        #expect(p.mailto == "first@b.com")
        #expect(p.https == "https://one.example/u")
    }

    @Test func emptyAndGarbageReturnNil() {
        #expect(ListUnsubscribeParser.parse("").mailto == nil)
        #expect(ListUnsubscribeParser.parse("").https == nil)
        let g = ListUnsubscribeParser.parse("<<>> not a uri ;;;")
        #expect(g.mailto == nil)
        #expect(g.https == nil)
    }

    @Test func hasAnyReflectsPresence() {
        #expect(ListUnsubscribeParser.parse("<mailto:a@b.com>").hasAny == true)
        #expect(ListUnsubscribeParser.parse("garbage").hasAny == false)
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter ListUnsubscribeParserTests`
  - **Expected:** compile error — `cannot find 'ListUnsubscribeParser' in scope`.

- [ ] **Implement** `Sources/SenaniEngine/Agents/ListUnsubscribeParser.swift`:

```swift
import Foundation

/// Pure parser for the RFC 2369 / RFC 8058 `List-Unsubscribe` header value, which is a
/// comma-separated list of (optionally angle-bracketed) URIs, e.g.
/// `<mailto:unsub@brand.com?subject=bye>, <https://brand.com/u/abc>`.
/// Extracts the first `mailto:` address (query stripped) and the first `http(s):` URL.
/// Never throws; unknown/empty inputs yield `nil` fields.
public struct ListUnsubscribeParser: Sendable, Equatable {
    public let mailto: String?
    public let https: String?

    public init(mailto: String?, https: String?) {
        self.mailto = mailto
        self.https = https
    }

    /// True if at least one actionable unsubscribe target was found.
    public var hasAny: Bool { mailto != nil || https != nil }

    public static func parse(_ header: String) -> ListUnsubscribeParser {
        var mailto: String? = nil
        var https: String? = nil

        // Split on commas; trim each token and strip surrounding angle brackets.
        for rawToken in header.split(separator: ",") {
            var token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.hasPrefix("<") { token.removeFirst() }
            if token.hasSuffix(">") { token.removeLast() }
            token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = token.lowercased()

            if mailto == nil, lower.hasPrefix("mailto:") {
                let addressPart = String(token.dropFirst("mailto:".count))
                // Strip any ?query (e.g. ?subject=unsub) and surrounding whitespace.
                let address = addressPart.split(separator: "?", maxSplits: 1).first
                    .map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if address.contains("@") { mailto = address }
            } else if https == nil, lower.hasPrefix("https://") || lower.hasPrefix("http://") {
                https = token
            }
        }

        return ListUnsubscribeParser(mailto: mailto, https: https)
    }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter ListUnsubscribeParserTests`
  - **Expected:** all 7 tests pass.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: ListUnsubscribeParser — pure RFC 2369/8058 mailto+https extraction

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5 — InboxHygieneAgent (wakesFor + proposals + HygieneFinding)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/InboxHygieneAgent.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/InboxHygiene/InboxHygieneWakesForTests.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/InboxHygiene/InboxHygieneProposalsTests.swift`

### 5a. Failing `wakesFor` tests

- [ ] **Write** `InboxHygieneWakesForTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct InboxHygieneWakesForTests {
    private let agent = InboxHygieneAgent()

    @Test func wakesWhenListUnsubscribeHeaderPresent() {
        let m = IH.newsletter()      // has a header
        #expect(agent.wakesFor(m, context: IH.context(thread: [m])) == true)
    }

    @Test func wakesForNewsletterLabelWithRepeatSender() {
        // No header, but Newsletter-labeled AND the domain recurs in the thread → bulk.
        let thread = IH.repeatSenderThread(domain: "brand.com", count: 3)
        let target = thread.last!
        #expect(agent.wakesFor(target, context: IH.context(thread: thread)) == true)
    }

    @Test func doesNotWakeForPersonalMessageWithoutHeaderOrNewsletterLabel() {
        let m = IH.personal()        // no header, no Newsletter label
        #expect(agent.wakesFor(m, context: IH.context(thread: [m])) == false)
    }

    @Test func doesNotWakeForNewsletterLabelWithoutFrequencyOrHeader() {
        // Single Newsletter-labeled message, no header, domain appears only once → below threshold.
        let m = IH.newsletter(listUnsubscribeHeader: nil)
        #expect(agent.wakesFor(m, context: IH.context(thread: [m])) == false)
    }

    @Test func doesNotWakeForMessageSentByTheUser() {
        let m = IH.newsletter()      // header present, but pretend it is from the user
        let mine = Message(
            id: m.id, from: IH.account, to: ["x@y.com"], subject: m.subject, body: m.body,
            hasAttachment: false, listUnsubscribeHeader: m.listUnsubscribeHeader, labels: m.labels,
            threadId: m.threadId, date: m.date, isFromUser: true
        )
        #expect(agent.wakesFor(mine, context: IH.context(thread: [mine])) == false)
    }

    @Test func identityAndAutonomy() {
        #expect(agent.id == "inbox-hygiene")
        #expect(agent.autonomy == .prepare)   // declutter staged for one-click; unsubscribe always queues
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter InboxHygieneWakesForTests`
  - **Expected:** compile error — `cannot find 'InboxHygieneAgent' in scope`.

### 5b. Failing `proposals` tests

- [ ] **Write** `InboxHygieneProposalsTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct InboxHygieneProposalsTests {
    private let agent = InboxHygieneAgent()

    @Test func emitsReversibleDeclutterSetForBulkMail() async throws {
        let m = IH.newsletter()
        let actions = try await agent.proposals(for: m, context: IH.context(thread: [m]), tools: AgentTools())
        // Declutter: label + markRead + archive, all reversible.
        #expect(actions.contains(.label("Senani/Newsletter")))
        #expect(actions.contains(.markRead))
        #expect(actions.contains(.archive))
        for a in actions where a.actionClass == .reversible {
            #expect([.label("Senani/Newsletter"), .markRead, .archive].contains(a))
        }
    }

    @Test func mailtoHeaderProducesOneOutboundUnsubscribeReplyThatWillQueue() async throws {
        let m = IH.newsletter(listUnsubscribeHeader: "<mailto:unsub@brand.com>")
        let actions = try await agent.proposals(for: m, context: IH.context(thread: [m]), tools: AgentTools())
        let outbound = actions.filter { $0.actionClass == .outbound }
        #expect(outbound.count == 1)
        // The single outbound action is a reply (always queues) — never auto-sent.
        guard case let .reply(body) = outbound[0] else { Issue.record("expected .reply"); return }
        #expect(body.lowercased().contains("unsubscribe"))
        // Safety: ActionRouter queues it regardless of autonomy.
        #expect(SenaniRules.ActionRouter.route(outbound[0], autonomy: .auto) == .queuedForApproval)
    }

    @Test func httpsOnlyHeaderEmitsNoOutboundActionButRecordsTheTarget() async throws {
        // No mailto → no outbound reply (the https one-click POST is a §5 capability, not built).
        let m = IH.newsletter(listUnsubscribeHeader: "<https://brand.com/u/abc123>")
        let actions = try await agent.proposals(for: m, context: IH.context(thread: [m]), tools: AgentTools())
        #expect(actions.filter { $0.actionClass == .outbound }.isEmpty)   // nothing auto-unsubscribes
        // Still declutters.
        #expect(actions.contains(.archive))
        // The finding surfaces the https target for the UI / §5 capability.
        let finding = agent.finding(for: m, context: IH.context(thread: [m]))
        #expect(finding.httpsUnsubscribe == "https://brand.com/u/abc123")
        #expect(finding.mailtoUnsubscribe == nil)
        #expect(finding.oneClickUnsupported == true)   // flag for the human/UI
    }

    @Test func findingCapturesMailtoTargetForApprovalRouting() async throws {
        let m = IH.newsletter(listUnsubscribeHeader: "<mailto:unsub@brand.com?subject=bye>, <https://brand.com/u/x>")
        let finding = agent.finding(for: m, context: IH.context(thread: [m]))
        #expect(finding.mailtoUnsubscribe == "unsub@brand.com")
        #expect(finding.httpsUnsubscribe == "https://brand.com/u/x")
        #expect(finding.oneClickUnsupported == true)
    }

    @Test func noBulkSignalYieldsNoProposals() async throws {
        let m = IH.personal()
        let actions = try await agent.proposals(for: m, context: IH.context(thread: [m]), tools: AgentTools())
        #expect(actions.isEmpty)   // wakesFor is false → defensive empty result
    }

    @Test func neverEmitsMoreThanOneOutboundAction() async throws {
        // Even with both forms present, exactly one outbound (the mailto reply) is proposed.
        let m = IH.newsletter()   // header has BOTH mailto + https
        let actions = try await agent.proposals(for: m, context: IH.context(thread: [m]), tools: AgentTools())
        #expect(actions.filter { $0.actionClass == .outbound }.count == 1)
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter InboxHygieneProposalsTests`
  - **Expected:** compile error — `cannot find 'InboxHygieneAgent' in scope`.

### 5c. Implement the agent

- [ ] **Write** `Sources/SenaniEngine/Agents/InboxHygieneAgent.swift`:

```swift
import Foundation
import SenaniRules

/// Phase-2 Inbox Hygiene agent. Wakes for bulk/newsletter mail and proposes:
///   1. REVERSIBLE declutter Actions — `proposeLabel("Senani/Newsletter")`, `markRead`, `archive` —
///      which auto-apply per the agent's autonomy dial (the Orchestrator routes them).
///   2. An approval-gated UNSUBSCRIBE: if the `List-Unsubscribe` header carries a `mailto:` target,
///      ONE outbound `Action.reply(body:)` (`actionClass == .outbound`) so `ActionRouter` ALWAYS
///      queues it. It is NEVER auto-sent. The HTTPS one-click POST form is NOT actioned (no Action
///      case exists — a §5 escalation); its target is surfaced on the `HygieneFinding` instead.
///
/// The agent is model-free: every decision is deterministic from the header, the Triage Newsletter
/// label, and a repeat-sender frequency heuristic over the thread. Pure → trivially unit-testable.
public struct InboxHygieneAgent: Agent {
    public let id = "inbox-hygiene"
    /// `.prepare`: declutter is staged for one-click (or auto under `.auto`); the unsubscribe reply
    /// is outbound so it queues regardless of this dial.
    public let autonomy: Autonomy = .prepare

    /// The Triage agent's Newsletter category label (see Triage plan).
    public static let newsletterCategoryLabel = "Senani/Category/Newsletter"
    /// The hygiene label this agent applies.
    public static let hygieneLabel = "Senani/Newsletter"
    /// How many messages from the same domain in the thread count as a "repeat sender".
    public static let repeatSenderThreshold = 2

    public init() {}

    // MARK: - Trigger

    public func wakesFor(_ message: Message, context: AgentContext) -> Bool {
        guard !message.isFromUser else { return false }
        // Strongest signal: a List-Unsubscribe header means it is bulk mail.
        if let header = message.listUnsubscribeHeader, ListUnsubscribeParser.parse(header).hasAny {
            return true
        }
        // Otherwise: Triage tagged it Newsletter AND the sender recurs in the thread.
        if message.labels.contains(Self.newsletterCategoryLabel),
           Self.senderFrequency(of: message, in: context.thread) >= Self.repeatSenderThreshold {
            return true
        }
        return false
    }

    // MARK: - Proposals

    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        guard wakesFor(message, context: context) else { return [] }

        // 1. Reversible declutter set (auto-applies per autonomy dial).
        var actions: [Action] = [
            tools.proposeLabel(Self.hygieneLabel, on: message),
            tools.markRead(message),
            tools.archive(message),
        ]

        // 2. Approval-gated unsubscribe (mailto form only). Outbound → always queues.
        let parsed = parsedHeader(for: message)
        if parsed.mailto != nil {
            actions.append(tools.reply(to: message, body: Self.unsubscribeBody))
        }
        // The https one-click form is intentionally NOT actioned here (§5 escalation); the target is
        // available via `finding(for:context:)` for the UI / a future capability.

        return actions
    }

    // MARK: - Finding (structured view the Orchestrator/UI can surface)

    /// A structured summary of what the agent saw — including the parsed unsubscribe targets and
    /// the explicit flag that one-click HTTPS unsubscribe is not yet a supported capability.
    public struct HygieneFinding: Sendable, Equatable {
        public let messageId: String
        public let isBulk: Bool
        public let mailtoUnsubscribe: String?
        public let httpsUnsubscribe: String?
        /// True when an HTTPS one-click target exists but no `Action`/tool can act on it (§5).
        public let oneClickUnsupported: Bool
    }

    public func finding(for message: Message, context: AgentContext) -> HygieneFinding {
        let parsed = parsedHeader(for: message)
        return HygieneFinding(
            messageId: message.id,
            isBulk: wakesFor(message, context: context),
            mailtoUnsubscribe: parsed.mailto,
            httpsUnsubscribe: parsed.https,
            oneClickUnsupported: parsed.https != nil
        )
    }

    // MARK: - Helpers (pure)

    /// The standardized unsubscribe email body. The Approval-UI/connector plan routes the approved
    /// reply to the parsed mailto target (carried on `HygieneFinding.mailtoUnsubscribe`), NOT to the
    /// message sender — see the recipient-encoding note in the plan header.
    static let unsubscribeBody = "Please unsubscribe me from this mailing list."

    private func parsedHeader(for message: Message) -> ListUnsubscribeParser {
        guard let header = message.listUnsubscribeHeader else {
            return ListUnsubscribeParser(mailto: nil, https: nil)
        }
        return ListUnsubscribeParser.parse(header)
    }

    /// How many messages in `thread` share `message`'s sender domain (including itself).
    static func senderFrequency(of message: Message, in thread: [Message]) -> Int {
        let domain = message.senderDomain
        guard !domain.isEmpty else { return 0 }
        return thread.filter { $0.senderDomain == domain }.count
    }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter InboxHygieneWakesForTests`
  - **Expected:** all 6 pass.
- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter InboxHygieneProposalsTests`
  - **Expected:** all 6 pass.

- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: InboxHygieneAgent — reversible declutter + approval-gated unsubscribe

Wakes for List-Unsubscribe/Newsletter bulk mail. Emits reversible label/markRead/archive
(auto-apply per autonomy) plus ONE outbound Action.reply to the mailto unsubscribe address
(always queues). HTTPS one-click POST is NOT actioned (no Action case) — surfaced on
HygieneFinding and flagged as a §5 escalation. No network, no MLX.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6 — Full suite green + public surface check

**Files:** none (verification); remove any leftover placeholder.

- [ ] If `Sources/SenaniEngine/AgentContract.swift` still contains `enum SenaniEnginePlaceholder {}` alongside the real types, remove that line; if a separate `Placeholder.swift` was created, delete it.

- [ ] **Run the full suite:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test`
  - **Expected:** all suites pass — `AgentToolsContractTests`, `ListUnsubscribeParserTests`, `InboxHygieneWakesForTests`, `InboxHygieneProposalsTests` (plus any other agents co-located in the package). Zero failures, strict-concurrency clean.

- [ ] **Confirm public surface** matches the §3 contract + this plan's additions:
  - `Agent`, `AgentContext`, `AgentTools` (`reply`/`draftReply` → outbound `Action.reply`; `proposeLabel`/`archive`/`markRead` reversible).
  - `ListUnsubscribeParser` (`parse(_:) -> ListUnsubscribeParser`, `mailto`, `https`, `hasAny`).
  - `InboxHygieneAgent` (`id == "inbox-hygiene"`, `autonomy == .prepare`, `wakesFor`, `proposals`, `finding(for:context:) -> HygieneFinding`).

- [ ] **Commit (if any cleanup):**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: full Inbox Hygiene suite green; public contract verified

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Scope coverage (brief):**
- `InboxHygieneAgent: SenaniEngine.Agent`, co-located in `Packages/SenaniEngine/Sources/SenaniEngine/Agents/` per the Triage/Reply-Drafter co-location decision; the SenaniEngine dependency + shared-scaffold coordination is stated explicitly (Cross-package assumptions). ✅
- **wakesFor** triggers on bulk/newsletter mail via `message.listUnsubscribeHeader != nil` (parsed `.hasAny`) OR the Triage `Senani/Category/Newsletter` label + a sender-domain frequency heuristic over `context.thread` (`repeatSenderThreshold`). Never wakes for the user's own mail. Pure. ✅
- **Declutter** emits REVERSIBLE Actions — `proposeLabel("Senani/Newsletter")`, `markRead`, `archive` — which auto-apply per the agent's autonomy dial (the Orchestrator routes them; `.label/.archive/.markRead` are `.reversible`, verified). ✅
- **Unsubscribe** parses both `mailto:` and `https:` forms (`ListUnsubscribeParser`, RFC 2369/8058). Chosen approach is stated clearly: (a) `mailto:` → an OUTBOUND `Action.reply(body:)` that ALWAYS queues for approval (asserted via `actionClass == .outbound` and `ActionRouter.route(_, .auto) == .queuedForApproval`); (b) `https:` one-click POST → NOT actioned, surfaced on `HygieneFinding.httpsUnsubscribe` with `oneClickUnsupported == true` and escalated as a §5 blocking item (new `Action` case / new tool + connector capability). The action model is NOT forked. ✅

**Real-source reconciliations (verified, recorded in the plan):**
1. `SenaniRules.Message.listUnsubscribeHeader: String?` exists (verified `Message.swift`) — the agent's primary signal. ✅
2. `SenaniRules.Action` has NO `unsubscribe` case (verified `Action.swift`); `.reply` is `.outbound` (verified). Unsubscribe-by-mailto therefore maps to `Action.reply` (outbound, always queues); HTTPS one-click is the §5 escalation. No frozen package edited. ✅
3. `ActionRouter.route` queues all outbound regardless of autonomy (verified first line of `Routing.swift`). ✅
4. `SenaniEngine` package not yet on disk → Tasks 1–2 conditionally scaffold it / define §3 types, with an explicit skip-if-exists branch and a shared-scaffold coordination flag; the `reply`-vs-`draftReply` tool-name divergence between this plan and the Reply Drafter plan is reconciled (alias provided). ✅
5. `Action.reply(body:)` carries no recipient → the mailto target is surfaced on `HygieneFinding.mailtoUnsubscribe` for the Approval-UI/connector to route to (recorded as an execution-time boundary). ✅

**Tests (pure, no MLX/Gmail/network):**
- A message with a `mailto:` List-Unsubscribe → exactly one OUTBOUND unsubscribe reply Action (queues) + reversible declutter labels (`mailtoHeaderProducesOneOutboundUnsubscribeReplyThatWillQueue`, `emitsReversibleDeclutterSetForBulkMail`). ✅
- A message WITHOUT the header and not a newsletter → agent does not wake (`doesNotWakeForPersonalMessageWithoutHeaderOrNewsletterLabel`) and `proposals` returns empty (`noBulkSignalYieldsNoProposals`). ✅
- Header parsing handles `mailto`+`https` forms, either-only, `http`, whitespace, no-brackets, garbage, first-of-each-scheme (`ListUnsubscribeParserTests`, 7 cases). ✅
- No message is auto-unsubscribed without approval: the only outbound action is a `.reply` that `ActionRouter` routes to `.queuedForApproval` even under `.auto`; HTTPS-only mail emits NO outbound action at all. ✅

**Conventions (§4):** agent is pure (no I/O, model-free); one safety path (outbound → `ActionRouter` queues; reversible → autonomy dial); reads through `context`, never stores; macOS 14 / Swift 6.2 / strict concurrency / Swift Testing; TDD bite-sized steps with complete code, run-to-fail/run-to-pass commands + expected output, frequent commits. ✅

**Open items flagged to the human:**
- **SenaniEngine package ownership / shared scaffold** with the Triage + Reply Drafter + orchestrator plans (who creates `Package.swift` + `AgentContract.swift` first; `reply` vs `draftReply` tool name).
- **§5 BLOCKING — HTTPS one-click unsubscribe (RFC 8058 POST)** has no `SenaniRules.Action` case and no SenaniEngine tool/connector capability. Decision needed: add an outbound `Action.unsubscribe(url:)` to the frozen `SenaniRules` (re-freeze) + a `AgentTools.unsubscribe(...)` builder + a `MailBackend`/HTTP capability to POST it, OR keep HTTPS unsubscribe out of scope (mailto-only). Until decided, the agent surfaces the target on `HygieneFinding` but takes no outbound action on it.
- **Mailto reply recipient routing** — `Action.reply(body:)` has no `to:`; the Approval-UI/connector plan must route the approved unsubscribe reply to `HygieneFinding.mailtoUnsubscribe`, not the message sender. If the human prefers a first-class `Action.reply(to:body:)`, that is a §5 frozen-package change.
- **Repeat-sender threshold** (`repeatSenderThreshold = 2`) and the hygiene label string (`Senani/Newsletter`) are tunable; confirm they match the Triage agent's emitted category label (`Senani/Category/Newsletter`).
