# SenaniEngine — Agent Engine (Orchestrator + Scheduler) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `Packages/SenaniEngine` — the Phase-1 "brain" the architecture describes: a pure, fully unit-tested Swift package that turns one synced `Message` into routed actions via a Triage agent → category dispatch → per-agent `proposals(...)` → the single `ActionRouter.route` safety path (reversible+auto executes via `MailBackend`; everything else queues in `ApprovalStore`; every outcome recorded to the `AuditLog` with `Trigger.rule(id: agent.id)`), plus a `Scheduler` that syncs Gmail (through a `GmailSyncing` seam), saves to `MessageStore`, and processes the new mail on a timer that respects low-power.

**Architecture:** A new SwiftPM library `SenaniEngine` depending **only** on the frozen engine packages `SenaniRules`, `SenaniStore`, `SenaniInference`. It ships the §3 `SenaniEngine` contract from `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md` **exactly** so the ~20 dependent app/agent/UI plans compile against it: `Agent`, `AgentContext`, `AgentTools`, `AgentRegistry`, `Orchestrator`, `Scheduler`, `GmailSyncing`, `ProcessedOutcome`. Agents are pure functions `(message, context, tools) -> [Action]` and never touch Gmail; the `Orchestrator` is the only thing that routes and persists. There is **exactly one safety path** — `ActionRouter.route` + `MailBackend`/`ApprovalStore`/`AuditLog` — never a second one. `GmailSync` (frozen, in `SenaniGmail`) already exposes `fetchMessages(query:maxResults:) async throws -> [Message]`, which matches `GmailSyncing` byte-for-byte, so its conformance is a one-line app-tier extension (see "GmailSyncing conformance shim" below); this package does **not** import `SenaniGmail`.

**Tech Stack:** Swift 6.2 toolchain, `swift-tools-version: 6.0`, strict concurrency, Swift Package Manager, Swift Testing (`import Testing`, ships with the toolchain). Target platform macOS 14, Apple Silicon. No MLX, no Gmail network, no SwiftUI, no IOKit in this package — every test runs on `SenaniDatabase.inMemory()` + local fakes.

**Working directory:** All `swift` commands run from `Packages/SenaniEngine/` unless stated otherwise.

**Design source:** `docs/ARCHITECTURE.md` ("The Agent Engine", "How an agent is defined", "The pipeline") and `docs/ROADMAP.md` Phase 1 ("Agent Engine: orchestrator, approval queue, activity log, autonomy dials"). The §3 contract in `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md` is authoritative for the runtime signatures; **this plan OWNS that contract**.

**Out of scope (separate plans):** the concrete Triage and Reply-Drafter agents (Phase-1 agent plans — this package only ships the `Agent` protocol + fakes they conform to); the live `MLXTextGenerator`/`MLXEmbedder` and model picker; the live `GmailMailBackend`/`GmailSync` wiring and the `GmailSyncing` shim (app-shell composition root); the SwiftUI Approval queue / Activity log / autonomy-dial UI; the IOKit low-power probe (injected here as a closure). The `retrieve` closure (built from `VectorIndex` + `Embedder`) is constructed by the composition root and merely held by `AgentContext`.

---

## Cross-package assumptions (verified from source — state these to the human before coding)

`SenaniEngine` compiles only against the frozen packages below. Every signature here was read from source on 2026-05-31; code to these exactly. If a frozen package differs at build time, adapt the SenaniEngine code, never the frozen package.

### `SenaniRules` (frozen — `Packages/SenaniRules/Sources/SenaniRules/`)
```swift
// Message.swift — NOTE senderDomain is a COMPUTED property, not an init field.
public struct Message: Sendable, Equatable, Identifiable {
    public let id: String; public let from: String; public let to: [String]
    public let subject: String; public let body: String
    public let hasAttachment: Bool; public let listUnsubscribeHeader: String?
    public let labels: [String]; public let threadId: String
    public let date: Date; public let isFromUser: Bool
    public init(id: String, from: String, to: [String], subject: String, body: String,
                hasAttachment: Bool, listUnsubscribeHeader: String?, labels: [String],
                threadId: String, date: Date, isFromUser: Bool)
    public var senderDomain: String { get }   // computed, not stored
}

// Action.swift
public enum Action: Sendable, Equatable {
    case label(String); case archive; case markRead; case markUnread; case star; case unstar
    case move(String); case flagNeedsReply; case fileAttachment(folder: String); case parseDoc
    case runAgent(id: String); case draft(body: String); case reply(body: String)
    case forward(to: String, body: String); case send(body: String); case markSpam
    case localWebhook(name: String)
}
public enum ActionClass: Sendable, Equatable { case reversible; case outbound }
extension Action { public var actionClass: ActionClass { get } }
// .reply/.forward/.send/.markSpam => .outbound ; everything else => .reversible

// Routing.swift
public enum Outcome: Sendable, Equatable { case executed; case prepared; case queuedForApproval }
public enum Trigger: Sendable, Equatable { case rule(id: String); case chat(turnId: String) }
public enum ActionRouter {
    public static func route(_ action: Action, autonomy: Autonomy) -> Outcome
    // outbound => .queuedForApproval ALWAYS ; else .auto=>.executed, .prepare=>.prepared, .ask=>.queuedForApproval
}

// Execution.swift
public protocol MailBackend: Sendable { func apply(_ action: Action, to message: Message) async throws }
public struct Proposal: Sendable, Equatable { public init(action: Action, message: Message, trigger: Trigger) }
public struct ActionRecord: Sendable, Equatable {
    public init(action: Action, messageId: String, trigger: Trigger, outcome: Outcome) }
public protocol AuditLog: Sendable { func record(_ record: ActionRecord) async }
public actor InMemoryAuditLog: AuditLog { public init(); public func record(_:) ; public func records() -> [ActionRecord] }

// Rule.swift
public enum Autonomy: String, Sendable, Equatable { case ask; case prepare; case auto }
public enum RunOn: String, Sendable, Equatable { case incoming; case existing; case both }
public struct Rule: Sendable, Equatable, Identifiable {
    public init(id: String, name: String, enabled: Bool, conditions: Conditions,
                actions: [Action], autonomy: Autonomy, runOn: RunOn) }

// Condition.swift
public struct Conditions: Sendable, Equatable {
    public init(mode: MatchMode, structured: [StructuredCondition], aiPredicate: String?) }
public enum MatchMode: Sendable, Equatable { case all; case any; case none }
```

### `SenaniStore` (frozen — `Packages/SenaniStore/Sources/SenaniStore/`)
```swift
// SenaniDatabase.swift
public final class SenaniDatabase: @unchecked Sendable {
    public let queue: DatabaseQueue
    public static func inMemory() throws -> SenaniDatabase
    public static func file(at path: String) throws -> SenaniDatabase
}

// MessageStore.swift — methods are SYNCHRONOUS throwing (NOT async).
public struct MessageStore: Sendable {
    public init(database: SenaniDatabase)
    public func save(_ message: Message) throws
    public func saveAll(_ messages: [Message]) throws
    public func fetch(id: String) throws -> Message?
    public func thread(id: String) throws -> [Message]                       // ORDER BY date ASC, id ASC
    public func query(from: String?, to: String?, isFromUser: Bool?, limit: Int?) throws -> [Message]
    public func all() throws -> [Message]                                    // ORDER BY date DESC, id ASC
}

// ApprovalStore.swift — a struct; enqueue takes a caller-supplied id; methods SYNCHRONOUS throwing.
public struct StoredProposal: Sendable, Equatable { public init(id: String, proposal: Proposal); public let id: String; public let proposal: Proposal }
public struct ApprovalStore: Sendable {
    public init(database: SenaniDatabase, now: @escaping @Sendable () -> Double)   // now: REQUIRED
    public func enqueue(id: String, _ proposal: Proposal) throws
    public func pending() throws -> [StoredProposal]
    public func approve(id: String) throws
    public func reject(id: String) throws
}

// PersistentAuditLog.swift — an actor conforming to SenaniRules.AuditLog.
public actor PersistentAuditLog: AuditLog {
    public init(database: SenaniDatabase, now: @escaping @Sendable () -> Double)   // now: REQUIRED
    public func record(_ record: ActionRecord) async
    public func records() throws -> [AuditEntry]
}
public struct AuditEntry: Sendable, Equatable { public let record: ActionRecord; public let loggedAt: Double }

// VectorIndex.swift
public protocol VectorIndex: Sendable {
    func insert(id: String, vector: [Float], metadata: [String: String]) throws
    func search(vector: [Float], k: Int) throws -> [VectorHit]
}
public struct VectorHit: Sendable, Equatable { public let id: String; public let distance: Float; public let metadata: [String: String]
    public init(id: String, distance: Float, metadata: [String: String]) }
public final class InMemoryVectorIndex: VectorIndex, @unchecked Sendable { public init() }
```

### `SenaniInference` (frozen — `Packages/SenaniInference/Sources/SenaniInference/`)
```swift
public protocol TextGenerator: Sendable {
    func generate(prompt: String, maxTokens: Int) async throws -> String
    func generateJSON(prompt: String, schema: JSONSchema) async throws -> String
}
public protocol Embedder: Sendable { func embed(_ text: String) async throws -> [Float] }
public enum InferenceError: Error, Sendable, Equatable { case modelNotLoaded; case generationFailed(String); case decodingFailed(String) }
// NO FakeTextGenerator / FakeEmbedder ship in this package — SenaniEngine defines its OWN local fakes.
```

### `SenaniGmail` (frozen — referenced ONLY for the shim note; NOT a dependency of this package)
```swift
public struct GmailSync: Sendable {
    public func fetchMessages(query: String, maxResults: Int) async throws -> [Message]
}
```
This signature is **identical** to `GmailSyncing.fetchMessages(query:maxResults:)`, so the conformance is one line (see below). `SenaniEngine` deliberately does not depend on `SenaniGmail`.

### Key consequences pinned for the implementer
- `MessageStore`/`ApprovalStore` methods are **synchronous `throws`** — call them without `await`. Only `PersistentAuditLog.record` and `MailBackend.apply` and the generator/sync seams are `async`.
- `ApprovalStore.enqueue(id:_:)` requires the caller to supply a **stable, unique id**; the Orchestrator generates one (deterministic, derived from message id + agent id + an action index — see Task 7) so re-processing the same message updates the same row via the store's `ON CONFLICT(id) DO UPDATE`.
- `PersistentAuditLog` and `ApprovalStore` both need `now: @escaping @Sendable () -> Double` (seconds-since-epoch). The Orchestrator holds a `now: @escaping @Sendable () -> Date` (per the §3 contract) and the composition root passes a matching `() -> Double` to the stores; the Orchestrator never builds those stores itself.
- Triage tags a category by emitting a `.label(String)` action whose payload is the category (e.g. `.label("Lead")`). The Orchestrator reads that label string back as the category — it does NOT persist the label first. Triage actions still route through `ActionRouter` + audit like any other agent's (a `.label` is reversible, so under `.auto` it executes via `MailBackend`; under `.ask` it queues — the category is read from the emitted Action regardless of outcome).

### `GmailSyncing` conformance shim (app tier — documented here, NOT built here)
In the app-shell composition root, add a one-line extension so the frozen `GmailSync` satisfies the seam:
```swift
// SenaniApp/Sources/SenaniApp/Adapters/GmailSyncingAdapter.swift  (owned by the app-shell plan)
import SenaniGmail
import SenaniEngine
extension SenaniGmail.GmailSync: SenaniEngine.GmailSyncing {}   // signatures already match exactly
```
No code in `Packages/SenaniEngine` references `SenaniGmail`. Tests use the local `FakeGmailSync` (Task 9).

### App wiring note (for the app-shell plan, not done here)
`SenaniApp/Package.swift` (swift-tools 5.9) must gain `Packages/SenaniEngine` as a dependency and target dep. Add to `dependencies`: `.package(path: "../Packages/SenaniEngine")`, and to the executable target deps: `"SenaniEngine"`. The app-shell plan owns this edit and the composition root (`AppEnvironment.live()/preview()`) that constructs the real `Orchestrator`/`Scheduler` graph. This plan does not modify `SenaniApp/Package.swift`.

---

## File Structure

```
Packages/SenaniEngine/
  Package.swift
  Sources/SenaniEngine/
    Agent.swift            # protocol Agent + AgentContext (read-only world for one message)
    AgentTools.swift       # struct AgentTools — pure Action builders (draftReply/proposeLabel/archive/markRead)
    AgentRegistry.swift    # struct AgentRegistry — category -> [any Agent]
    ProcessedOutcome.swift # struct ProcessedOutcome (agentId, action, outcome)
    GmailSyncing.swift     # protocol GmailSyncing (the sync seam Scheduler depends on)
    Orchestrator.swift     # actor Orchestrator — triage -> route -> agents -> ActionRouter path; process/processInbox
    Scheduler.swift        # actor Scheduler — tick (sync+save+process), start/stop on injected interval, low-power closure
  Tests/SenaniEngineTests/
    TestSupport.swift                # FakeMailBackend, fakes, msg(...) factory, an in-memory store-graph builder
    AgentToolsTests.swift            # the four pure builders return the right Action cases
    AgentRegistryTests.swift         # category routing returns the subscribed agents
    OrchestratorRoutingTests.swift   # outbound queues regardless of autonomy; reversible+auto executes; reversible+ask queues
    OrchestratorTriageTests.swift    # triage category routes to the right agents; non-matching agents skipped
    OrchestratorAuditTests.swift     # every outcome recorded with Trigger.rule(id: agent.id); processInbox covers all messages
    SchedulerTests.swift             # tick syncs+saves+processes (FakeGmailSync); low-power closure suppresses ticks
```

Each file has one responsibility. The package's only product is the `SenaniEngine` library; the test target reuses `TestSupport.swift`.

---

### Task 1: Package scaffold + path dependencies

**Files:**
- Create: `Packages/SenaniEngine/Package.swift`
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agent.swift` (temporary one-line marker so the target compiles)
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/ProbeTests.swift` (placeholder import-only test, deleted in Task 3)

- [ ] **Step 1: Write a failing import test**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/ProbeTests.swift`:

```swift
import Testing
@testable import SenaniEngine
import SenaniRules

@Test func packageImportsCompileAndLinkSenaniRules() {
    // Proves the package builds and links SenaniRules.
    let action: SenaniRules.Action = .archive
    #expect(action.actionClass == .reversible)
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniEngine && swift test
```

Expected: failure — no `Package.swift` / no `SenaniEngine` target (manifest not found / `error: no such module 'SenaniEngine'`).

- [ ] **Step 3: Create the manifest with path deps**

Create `Packages/SenaniEngine/Package.swift`:

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
    ],
    targets: [
        .target(
            name: "SenaniEngine",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "SenaniStore", package: "SenaniStore"),
                .product(name: "SenaniInference", package: "SenaniInference"),
            ]
        ),
        .testTarget(
            name: "SenaniEngineTests",
            dependencies: ["SenaniEngine"]
        ),
    ]
)
```

Create `Packages/SenaniEngine/Sources/SenaniEngine/Agent.swift` with a single line so the target is non-empty:

```swift
// SenaniEngine — the Agent Engine. Real contract defined in Task 3+.
import SenaniRules
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniEngine && swift test
```

Expected: 1 test passes (`packageImportsCompileAndLinkSenaniRules`).

- [ ] **Step 5: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: package scaffold with SenaniRules/Store/Inference path deps"
```

Use this commit trailer on EVERY commit in this plan:

```

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

---

### Task 2: AgentTools — pure Action builders

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/AgentTools.swift`
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/AgentToolsTests.swift`

`AgentTools` exposes the *only* capabilities an agent may use to **build** actions. They are pure: each returns a `SenaniRules.Action` and performs no I/O. `draftReply` maps to `.draft(body:)` (a reversible Gmail draft — the architecture's "create a draft, never auto-send"), NOT `.reply` (which is outbound and would queue). `proposeLabel`/`archive`/`markRead` map to their reversible Action cases.

- [ ] **Step 1: Write failing builder tests**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/AgentToolsTests.swift`:

```swift
import Testing
@testable import SenaniEngine
import SenaniRules
import Foundation

private func sampleMessage() -> Message {
    Message(id: "m1", from: "a@b.com", to: ["me@x.com"], subject: "Hi", body: "Body",
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: "t1", date: Date(timeIntervalSince1970: 1_000), isFromUser: false)
}

@Test func draftReplyBuildsAReversibleDraftAction() {
    let tools = AgentTools()
    let action = tools.draftReply(to: sampleMessage(), body: "Thanks!")
    #expect(action == .draft(body: "Thanks!"))
    #expect(action.actionClass == .reversible)   // a draft is reversible; it never auto-sends
}

@Test func proposeLabelBuildsALabelAction() {
    let tools = AgentTools()
    #expect(tools.proposeLabel("Lead", on: sampleMessage()) == .label("Lead"))
}

@Test func archiveAndMarkReadBuildTheirActions() {
    let tools = AgentTools()
    #expect(tools.archive(sampleMessage()) == .archive)
    #expect(tools.markRead(sampleMessage()) == .markRead)
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniEngine && swift test --filter AgentToolsTests
```

Expected: failure — `AgentTools` undefined.

- [ ] **Step 3: Implement `AgentTools`**

Create `Packages/SenaniEngine/Sources/SenaniEngine/AgentTools.swift`:

```swift
import SenaniRules

/// The capabilities an agent may call to BUILD actions. These are pure builders:
/// each returns a `SenaniRules.Action`; none performs I/O or touches Gmail.
/// The Orchestrator — never the agent — routes and executes the returned actions.
///
/// `draftReply` intentionally builds a `.draft` (reversible) and NOT a `.reply`
/// (outbound). The architecture's trust model: agents create a draft; sending is
/// always an explicit, approved step. Outbound actions an agent might construct
/// directly are still forced to the approval queue by `ActionRouter`.
public struct AgentTools: Sendable {
    public init() {}

    /// A draft reply staged for the user (reversible Gmail draft).
    public func draftReply(to message: Message, body: String) -> Action {
        .draft(body: body)
    }

    /// Propose a Gmail label on the message (reversible).
    public func proposeLabel(_ label: String, on message: Message) -> Action {
        .label(label)
    }

    /// Archive the message (reversible).
    public func archive(_ message: Message) -> Action {
        .archive
    }

    /// Mark the message read (reversible).
    public func markRead(_ message: Message) -> Action {
        .markRead
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniEngine && swift test --filter AgentToolsTests
```

Expected: all 3 pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: AgentTools pure Action builders (draftReply/proposeLabel/archive/markRead)"
```

(Append the standard trailer.)

---

### Task 3: Agent protocol + AgentContext

**Files:**
- Edit: `Packages/SenaniEngine/Sources/SenaniEngine/Agent.swift`
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/TestSupport.swift` (create — shared fakes + a self-test)
- Delete: `Packages/SenaniEngine/Tests/SenaniEngineTests/ProbeTests.swift` (its assertion now lives in TestSupport's self-test)

`Agent` is the §3 contract: a pure function from `(message, context, tools) -> [Action]`, plus a stable `id`, a per-agent `autonomy` dial (the Orchestrator enforces it, not the agent), and a pure `wakesFor` trigger predicate. `AgentContext` is the read-only world the Orchestrator pre-populates; agents never query stores. This task also creates `TestSupport.swift` with the fakes every later test reuses.

- [ ] **Step 1: Write the failing fakes + self-test**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/TestSupport.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniStore
import SenaniInference

// ---- Message factory ----

func msg(_ id: String,
         from: String = "a@b.com",
         to: [String] = ["me@x.com"],
         subject: String = "S",
         body: String = "B",
         labels: [String] = [],
         threadId: String = "t1",
         isFromUser: Bool = false,
         date: Date = Date(timeIntervalSince1970: 1_000)) -> Message {
    Message(id: id, from: from, to: to, subject: subject, body: body,
            hasAttachment: false, listUnsubscribeHeader: nil, labels: labels,
            threadId: threadId, date: date, isFromUser: isFromUser)
}

// ---- MailBackend spy ----

final class FakeMailBackend: MailBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _applied: [(action: Action, messageId: String)] = []
    func apply(_ action: Action, to message: Message) async throws {
        lock.lock(); _applied.append((action, message.id)); lock.unlock()
    }
    var applied: [(action: Action, messageId: String)] {
        lock.lock(); defer { lock.unlock() }; return _applied
    }
}

// ---- TextGenerator fake (no MLX) — returns canned strings/JSON in FIFO order ----

final class FakeTextGenerator: TextGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String]
    init(responses: [String] = []) { self.responses = responses }
    init(response: String) { self.responses = [response] }
    private func next() -> String {
        lock.lock(); defer { lock.unlock() }
        return responses.isEmpty ? "" : responses.removeFirst()
    }
    func generate(prompt: String, maxTokens: Int) async throws -> String { next() }
    func generateJSON(prompt: String, schema: JSONSchema) async throws -> String { next() }
}

// ---- Embedder fake (no MLX) — deterministic small vector ----

struct FakeEmbedder: Embedder {
    func embed(_ text: String) async throws -> [Float] {
        [Float(text.count), 1, 0]
    }
}

// ---- A configurable fake Agent ----

struct FakeAgent: Agent {
    let id: String
    let autonomy: Autonomy
    var wakes: @Sendable (Message, AgentContext) -> Bool = { _, _ in true }
    var emit: @Sendable (Message, AgentContext, AgentTools) -> [Action]
    func wakesFor(_ message: Message, context: AgentContext) -> Bool { wakes(message, context) }
    func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        emit(message, context, tools)
    }
}

// ---- An in-memory store graph the Orchestrator tests build on ----

struct EngineHarness {
    let database: SenaniDatabase
    let messages: MessageStore
    let rules: RuleStore
    let approvals: ApprovalStore
    let audit: PersistentAuditLog
    let index: InMemoryVectorIndex
    let backend: FakeMailBackend
    let embedder: FakeEmbedder
    let now: @Sendable () -> Date

    init() throws {
        let fixedSeconds = 1_700_000_000.0
        let fixedDate = Date(timeIntervalSince1970: fixedSeconds)
        database = try SenaniDatabase.inMemory()
        messages = MessageStore(database: database)
        rules = RuleStore(database: database)
        approvals = ApprovalStore(database: database, now: { fixedSeconds })
        audit = PersistentAuditLog(database: database, now: { fixedSeconds })
        index = InMemoryVectorIndex()
        backend = FakeMailBackend()
        embedder = FakeEmbedder()
        now = { fixedDate }
    }
}

// ---- self-test (replaces the Task-1 probe) ----

@Test func testSupportConstructsAnInMemoryGraph() throws {
    let h = try EngineHarness()
    #expect((try? h.messages.all())?.isEmpty == true)
    let action: Action = .archive
    #expect(action.actionClass == .reversible)
}
```

Delete `Packages/SenaniEngine/Tests/SenaniEngineTests/ProbeTests.swift`.

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniEngine && swift test --filter testSupportConstructsAnInMemoryGraph
```

Expected: failure — `Agent`, `AgentContext` undefined (referenced by `FakeAgent`).

- [ ] **Step 3: Implement `Agent` + `AgentContext`**

Replace `Packages/SenaniEngine/Sources/SenaniEngine/Agent.swift`:

```swift
import Foundation
import SenaniRules
import SenaniStore

/// The read-only world an agent may see for one message. The Orchestrator
/// pre-populates this; agents never query stores or the network directly.
public struct AgentContext: Sendable {
    /// The signed-in account email (used for self/sender reasoning).
    public let account: String
    /// The message's full thread, date ascending.
    public let thread: [Message]
    /// All rules currently known to the engine (read-only).
    public let rules: [Rule]
    /// Semantic-search seam: built by the composition root from VectorIndex + Embedder.
    public let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit]
    /// The engine's notion of "now" (injected for determinism).
    public let now: Date

    public init(account: String,
                thread: [Message],
                rules: [Rule],
                retrieve: @escaping @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit],
                now: Date) {
        self.account = account
        self.thread = thread
        self.rules = rules
        self.retrieve = retrieve
        self.now = now
    }
}

/// An agent is a pure function from (message, context, tools) -> [Action].
/// It NEVER touches Gmail or any store; it only builds actions via `tools`
/// (and may read `context.retrieve`). The Orchestrator routes the returned
/// actions through the single safety path and enforces `autonomy`.
public protocol Agent: Sendable {
    /// Stable identity, e.g. "triage", "reply-drafter". Used as the audit Trigger id.
    var id: String { get }
    /// Per-agent autonomy dial. The Orchestrator (not the agent) enforces it.
    var autonomy: Autonomy { get }
    /// Pure trigger predicate: does this agent want this message?
    func wakesFor(_ message: Message, context: AgentContext) -> Bool
    /// Build the actions this agent proposes for the message.
    func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action]
}
```

> The test target must import `SenaniStore` and `SenaniInference` (already added in `TestSupport.swift`). Because the test target depends on `SenaniEngine`, which re-exports `SenaniStore`/`SenaniInference` transitively, the explicit `import` lines in the test files resolve these modules.

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniEngine && swift test --filter testSupportConstructsAnInMemoryGraph
```

Expected: pass. (If the test target cannot resolve `import SenaniStore`/`import SenaniInference`, add them as explicit test-target deps in `Package.swift`: `.testTarget(name: "SenaniEngineTests", dependencies: ["SenaniEngine", .product(name: "SenaniStore", package: "SenaniStore"), .product(name: "SenaniInference", package: "SenaniInference")])` and re-run.)

- [ ] **Step 5: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: Agent protocol + AgentContext + shared test fakes"
```

(Append the standard trailer.)

---

### Task 4: ProcessedOutcome

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/ProcessedOutcome.swift`
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/AgentRegistryTests.swift` (reused below; here add a construction check) — or inline in a new test. Use a tiny dedicated test.

`ProcessedOutcome` is the per-action result the Orchestrator returns: which agent produced the action, the action itself, and the routed outcome.

- [ ] **Step 1: Write a failing construction test**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/ProcessedOutcomeTests.swift`:

```swift
import Testing
@testable import SenaniEngine
import SenaniRules

@Test func processedOutcomeCarriesAgentActionAndOutcome() {
    let po = ProcessedOutcome(agentId: "triage", action: .label("Lead"), outcome: .executed)
    #expect(po.agentId == "triage")
    #expect(po.action == .label("Lead"))
    #expect(po.outcome == .executed)
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniEngine && swift test --filter processedOutcomeCarriesAgentActionAndOutcome
```

Expected: failure — `ProcessedOutcome` undefined.

- [ ] **Step 3: Implement `ProcessedOutcome`**

Create `Packages/SenaniEngine/Sources/SenaniEngine/ProcessedOutcome.swift`:

```swift
import SenaniRules

/// The result of routing one agent-produced action: who produced it, the action,
/// and what the kernel decided (`.executed` / `.prepared` / `.queuedForApproval`).
public struct ProcessedOutcome: Sendable, Equatable {
    public let agentId: String
    public let action: Action
    public let outcome: Outcome
    public init(agentId: String, action: Action, outcome: Outcome) {
        self.agentId = agentId
        self.action = action
        self.outcome = outcome
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniEngine && swift test --filter processedOutcomeCarriesAgentActionAndOutcome
```

Expected: pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: ProcessedOutcome result type"
```

(Append the standard trailer.)

---

### Task 5: GmailSyncing seam

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/GmailSyncing.swift`
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/SchedulerTests.swift` (create the fake here; a self-test proves it conforms)

`GmailSyncing` is the abstract sync seam the `Scheduler` depends on. Its single method matches `SenaniGmail.GmailSync.fetchMessages` exactly, so the app wires the real sync with a one-line extension and tests use a `FakeGmailSync`.

- [ ] **Step 1: Write a failing conformance + fake test**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/SchedulerTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

// A scripted sync seam: returns a fixed batch and records the query it was asked.
final class FakeGmailSync: GmailSyncing, @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[Message]]
    private(set) var queries: [String] = []
    private(set) var callCount = 0
    init(batches: [[Message]]) { self.batches = batches }
    init(batch: [Message]) { self.batches = [batch] }
    func fetchMessages(query: String, maxResults: Int) async throws -> [Message] {
        lock.lock(); defer { lock.unlock() }
        callCount += 1
        queries.append(query)
        return batches.isEmpty ? [] : batches.removeFirst()
    }
}

@Test func fakeGmailSyncConformsToTheSeam() async throws {
    let sync: any GmailSyncing = FakeGmailSync(batch: [msg("m1")])
    let out = try await sync.fetchMessages(query: "newer_than:7d", maxResults: 50)
    #expect(out.map(\.id) == ["m1"])
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniEngine && swift test --filter fakeGmailSyncConformsToTheSeam
```

Expected: failure — `GmailSyncing` undefined.

- [ ] **Step 3: Implement `GmailSyncing`**

Create `Packages/SenaniEngine/Sources/SenaniEngine/GmailSyncing.swift`:

```swift
import SenaniRules

/// The sync seam the Scheduler depends on. `SenaniGmail.GmailSync` already exposes
/// this exact signature, so the app conforms it with a one-line extension:
///     extension SenaniGmail.GmailSync: SenaniEngine.GmailSyncing {}
/// Tests use a FakeGmailSync. This package never imports SenaniGmail.
public protocol GmailSyncing: Sendable {
    func fetchMessages(query: String, maxResults: Int) async throws -> [Message]
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniEngine && swift test --filter fakeGmailSyncConformsToTheSeam
```

Expected: pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: GmailSyncing seam + FakeGmailSync test double"
```

(Append the standard trailer.)

---

### Task 6: AgentRegistry — category → agents

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/AgentRegistry.swift`
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/AgentRegistryTests.swift`

`AgentRegistry` maps a triaged category string to the agents subscribed to it. Subscription is expressed by the agent's `wakesFor` against a synthetic, category-only message; that keeps the registry pure and avoids inventing a second subscription model. The Orchestrator calls `agents(for:)` after triage, then each returned agent's `wakesFor` is re-checked against the *real* message (Task 7) — so the registry is a coarse category filter and `wakesFor` is the fine predicate.

- [ ] **Step 1: Write failing registry tests**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/AgentRegistryTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

private func categoryAgent(_ id: String, category: String) -> FakeAgent {
    // Wakes only when the probe message carries the matching category label.
    FakeAgent(id: id, autonomy: .auto,
              wakes: { m, _ in m.labels.contains(category) },
              emit: { _, _, _ in [] })
}

@Test func registryReturnsAgentsSubscribedToACategory() {
    let lead = categoryAgent("lead-qualifier", category: "Lead")
    let invoice = categoryAgent("invoice", category: "Invoice")
    let registry = AgentRegistry(agents: [lead, invoice])

    let forLead = registry.agents(for: "Lead").map(\.id)
    #expect(forLead == ["lead-qualifier"])

    let forInvoice = registry.agents(for: "Invoice").map(\.id)
    #expect(forInvoice == ["invoice"])

    #expect(registry.agents(for: "Unknown").isEmpty)
}

@Test func registryCanReturnMultipleAgentsForOneCategory() {
    let a = categoryAgent("a", category: "Lead")
    let b = categoryAgent("b", category: "Lead")
    let registry = AgentRegistry(agents: [a, b])
    #expect(Set(registry.agents(for: "Lead").map(\.id)) == ["a", "b"])
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniEngine && swift test --filter AgentRegistryTests
```

Expected: failure — `AgentRegistry` undefined.

- [ ] **Step 3: Implement `AgentRegistry`**

Create `Packages/SenaniEngine/Sources/SenaniEngine/AgentRegistry.swift`:

```swift
import Foundation
import SenaniRules
import SenaniStore

/// Maps a triaged category -> the agents subscribed to it. An agent "subscribes"
/// to a category if its `wakesFor` returns true for a probe message carrying that
/// category as its only label. This reuses the agent's own trigger predicate as
/// the subscription test — no second subscription model.
public struct AgentRegistry: Sendable {
    private let agents: [any Agent]

    public init(agents: [any Agent]) {
        self.agents = agents
    }

    public func agents(for category: String) -> [any Agent] {
        let probe = Self.probeMessage(category: category)
        let context = Self.emptyContext()
        return agents.filter { $0.wakesFor(probe, context: context) }
    }

    private static func probeMessage(category: String) -> Message {
        Message(id: "__probe__", from: "", to: [], subject: "", body: "",
                hasAttachment: false, listUnsubscribeHeader: nil, labels: [category],
                threadId: "__probe__", date: Date(timeIntervalSince1970: 0), isFromUser: false)
    }

    private static func emptyContext() -> AgentContext {
        AgentContext(account: "", thread: [], rules: [],
                     retrieve: { _, _ in [] },
                     now: Date(timeIntervalSince1970: 0))
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniEngine && swift test --filter AgentRegistryTests
```

Expected: both pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: AgentRegistry maps category -> subscribed agents via wakesFor"
```

(Append the standard trailer.)

---

### Task 7: Orchestrator — the single safety path (routing)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Orchestrator.swift`
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/OrchestratorRoutingTests.swift`

The Orchestrator is the only thing that routes and persists. For one message it: (1) runs the injected `triage` agent first and reads the **category** from the first `.label(...)` action triage emits (defaulting to `""` if none); (2) routes each triage action through the safety path; (3) asks `registry.agents(for: category)` for subscribers and, for each whose `wakesFor` is true on the real message, calls `proposals(...)`; (4) routes each returned action.

Routing is the single safety path, identical to `ActionExecutor` but tagged `Trigger.rule(id: agent.id)` and persisted via the *persistent* stores:
- `ActionRouter.route(action, autonomy: agent.autonomy)`.
- `.executed`/`.prepared` → `mailBackend.apply(action, to: message)`.
- `.queuedForApproval` → `approvals.enqueue(id:, Proposal(action:message:trigger:))` with a generated deterministic id.
- ALWAYS → `audit.record(ActionRecord(action:messageId:trigger:outcome:))`.

This task focuses on the routing rules; Task 8 adds triage-category dispatch tests and Task 9/10 the audit + processInbox + scheduler tests. We build the full Orchestrator now (process + processInbox) and test routing here.

The generated approval id is `"\(message.id)#\(agent.id)#\(index)"` where `index` is the action's position in that agent's returned list — stable across re-processing so the store's `ON CONFLICT(id) DO UPDATE` refreshes rather than duplicates.

The Orchestrator builds each message's `AgentContext` itself: `thread` from `messages.thread(id: message.threadId)`, `rules` from `rules.all()`, `now` from the injected `now()`, and a `retrieve` closure that embeds the query via the injected `embedder` and searches the injected `index`.

- [ ] **Step 1: Write failing routing tests**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/OrchestratorRoutingTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniStore

// A triage agent that tags everything as one fixed category (and nothing else).
private func fixedTriage(_ category: String) -> FakeAgent {
    FakeAgent(id: "triage", autonomy: .auto,
              wakes: { _, _ in true },
              emit: { _, _, _ in [.label(category)] })
}

private func makeOrchestrator(_ h: EngineHarness,
                              triage: any Agent,
                              agents: [any Agent]) -> Orchestrator {
    Orchestrator(registry: AgentRegistry(agents: agents),
                 triage: triage,
                 mailBackend: h.backend,
                 approvals: h.approvals,
                 audit: h.audit,
                 messages: h.messages,
                 index: h.index,
                 embedder: h.embedder,
                 rules: h.rules,
                 now: h.now)
}

@Test func outboundActionQueuesRegardlessOfAutonomy() async throws {
    let h = try EngineHarness()
    let message = msg("m1", labels: ["Lead"])
    try h.messages.save(message)

    // Agent set to .auto, but emits an OUTBOUND .send — must STILL queue.
    let sender = FakeAgent(id: "sender", autonomy: .auto,
                           wakes: { m, _ in m.labels.contains("Lead") },
                           emit: { _, _, _ in [.send(body: "Hi")] })
    let orch = makeOrchestrator(h, triage: fixedTriage("Lead"), agents: [sender])

    let outcomes = try await orch.process(message)

    let sendOutcome = outcomes.first { $0.agentId == "sender" }
    #expect(sendOutcome?.outcome == .queuedForApproval)
    #expect(h.backend.applied.contains { $0.action == .send(body: "Hi") } == false)
    let pending = try h.approvals.pending()
    #expect(pending.contains { $0.proposal.action == .send(body: "Hi") })
}

@Test func reversibleAutoExecutesViaMailBackend() async throws {
    let h = try EngineHarness()
    let message = msg("m2", labels: ["Lead"])
    try h.messages.save(message)

    let labeler = FakeAgent(id: "labeler", autonomy: .auto,
                            wakes: { m, _ in m.labels.contains("Lead") },
                            emit: { _, _, tools in [tools.proposeLabel("Hot", on: msg("x"))] })
    let orch = makeOrchestrator(h, triage: fixedTriage("Lead"), agents: [labeler])

    let outcomes = try await orch.process(message)

    let labelOutcome = outcomes.first { $0.agentId == "labeler" }
    #expect(labelOutcome?.outcome == .executed)
    #expect(h.backend.applied.contains { $0.action == .label("Hot") && $0.messageId == "m2" })
    #expect(try h.approvals.pending().contains { $0.proposal.action == .label("Hot") } == false)
}

@Test func reversibleAskQueues() async throws {
    let h = try EngineHarness()
    let message = msg("m3", labels: ["Lead"])
    try h.messages.save(message)

    let labeler = FakeAgent(id: "labeler", autonomy: .ask,
                            wakes: { m, _ in m.labels.contains("Lead") },
                            emit: { _, _, tools in [tools.archive(msg("x"))] })
    let orch = makeOrchestrator(h, triage: fixedTriage("Lead"), agents: [labeler])

    let outcomes = try await orch.process(message)

    let archiveOutcome = outcomes.first { $0.agentId == "labeler" }
    #expect(archiveOutcome?.outcome == .queuedForApproval)
    #expect(h.backend.applied.contains { $0.action == .archive } == false)
    #expect(try h.approvals.pending().contains { $0.proposal.action == .archive })
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniEngine && swift test --filter OrchestratorRoutingTests
```

Expected: failure — `Orchestrator` undefined.

- [ ] **Step 3: Implement `Orchestrator`**

Create `Packages/SenaniEngine/Sources/SenaniEngine/Orchestrator.swift`:

```swift
import Foundation
import SenaniRules
import SenaniStore
import SenaniInference

/// The Agent Engine's brain. For each message it runs the Triage agent, reads the
/// category from triage's emitted label, dispatches to the subscribed agents, and
/// routes EVERY action through the single safety path: ActionRouter.route +
/// MailBackend / ApprovalStore / AuditLog, tagged Trigger.rule(id: agent.id).
/// There is exactly one routing path and one safety model — agents never execute.
public actor Orchestrator {
    private let registry: AgentRegistry
    private let triage: any Agent
    private let mailBackend: any MailBackend
    private let approvals: ApprovalStore
    private let audit: any AuditLog
    private let messages: MessageStore
    private let index: any VectorIndex
    private let embedder: any Embedder
    private let rules: RuleStore
    private let now: @Sendable () -> Date
    private let tools = AgentTools()

    public init(registry: AgentRegistry,
                triage: any Agent,
                mailBackend: any MailBackend,
                approvals: ApprovalStore,
                audit: any AuditLog,
                messages: MessageStore,
                index: any VectorIndex,
                embedder: any Embedder,
                rules: RuleStore,
                now: @escaping @Sendable () -> Date) {
        self.registry = registry
        self.triage = triage
        self.mailBackend = mailBackend
        self.approvals = approvals
        self.audit = audit
        self.messages = messages
        self.index = index
        self.embedder = embedder
        self.rules = rules
        self.now = now
    }

    /// Process one message end to end. Returns one ProcessedOutcome per routed action.
    public func process(_ message: Message) async throws -> [ProcessedOutcome] {
        let context = try buildContext(for: message)
        var results: [ProcessedOutcome] = []

        // 1. Triage runs first (if it wants this message). Its actions route like any other.
        var category = ""
        if triage.wakesFor(message, context: context) {
            let triageActions = try await triage.proposals(for: message, context: context, tools: tools)
            // The category is the payload of triage's first .label action.
            for action in triageActions {
                if case let .label(value) = action, category.isEmpty {
                    category = value
                }
            }
            results += try await route(triageActions, by: triage, on: message)
        }

        // 2. Dispatch to the agents subscribed to the triaged category.
        for agent in registry.agents(for: category) where agent.wakesFor(message, context: context) {
            let actions = try await agent.proposals(for: message, context: context, tools: tools)
            results += try await route(actions, by: agent, on: message)
        }

        return results
    }

    /// Batch: process every stored message (architecture's "Process inbox").
    public func processInbox() async throws -> [ProcessedOutcome] {
        var all: [ProcessedOutcome] = []
        for message in try messages.all() {
            all += try await process(message)
        }
        return all
    }

    // MARK: - The single safety path

    private func route(_ actions: [Action], by agent: any Agent, on message: Message) async throws -> [ProcessedOutcome] {
        let trigger = Trigger.rule(id: agent.id)
        var outcomes: [ProcessedOutcome] = []
        for (offset, action) in actions.enumerated() {
            let outcome = ActionRouter.route(action, autonomy: agent.autonomy)
            switch outcome {
            case .executed, .prepared:
                try await mailBackend.apply(action, to: message)
            case .queuedForApproval:
                let id = "\(message.id)#\(agent.id)#\(offset)"
                try approvals.enqueue(id: id, Proposal(action: action, message: message, trigger: trigger))
            }
            await audit.record(ActionRecord(
                action: action, messageId: message.id, trigger: trigger, outcome: outcome))
            outcomes.append(ProcessedOutcome(agentId: agent.id, action: action, outcome: outcome))
        }
        return outcomes
    }

    // MARK: - Context construction

    private func buildContext(for message: Message) throws -> AgentContext {
        let thread = try messages.thread(id: message.threadId)
        let allRules = try rules.all()
        let embedder = self.embedder
        let index = self.index
        let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit] = { query, k in
            let vector = try await embedder.embed(query)
            return try index.search(vector: vector, k: k)
        }
        return AgentContext(account: message.isFromUser ? message.from : (message.to.first ?? ""),
                            thread: thread.isEmpty ? [message] : thread,
                            rules: allRules,
                            retrieve: retrieve,
                            now: now())
    }
}
```

> **Account derivation note:** `AgentContext.account` is best supplied by the composition root, but the §3 init signature does not pass an account string. We derive a reasonable account from the message (`to.first`, or `from` if it is the user's own message). When the app-shell plan wires the live graph it may wrap the Orchestrator to inject the real account; for Phase-1 routing this derivation is sufficient and keeps the contract intact. Record this as a deviation if the app needs the exact account.

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniEngine && swift test --filter OrchestratorRoutingTests
```

Expected: all 3 pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: Orchestrator single safety path (route via ActionRouter + MailBackend/ApprovalStore/AuditLog)"
```

(Append the standard trailer.)

---

### Task 8: Orchestrator — triage category dispatch

**Files:**
- Test only: `Packages/SenaniEngine/Tests/SenaniEngineTests/OrchestratorTriageTests.swift`

The Orchestrator already reads the category from triage's `.label` and dispatches to `registry.agents(for: category)`. These tests lock that behavior: the right agents run for the triaged category, agents for other categories are skipped, and an agent whose `wakesFor` is false on the real message is skipped even if it subscribes to the category.

- [ ] **Step 1: Write failing triage-dispatch tests**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/OrchestratorTriageTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniStore

private func triageTagging(_ category: String) -> FakeAgent {
    FakeAgent(id: "triage", autonomy: .auto,
              wakes: { _, _ in true },
              emit: { _, _, _ in [.label(category)] })
}

// Subscribes to `category` (wakes when the message — probe or real — has that label),
// and on firing emits a unique reversible label so we can detect it ran.
private func subscriber(_ id: String, category: String, marker: String) -> FakeAgent {
    FakeAgent(id: id, autonomy: .auto,
              wakes: { m, _ in m.labels.contains(category) },
              emit: { _, _, tools in [tools.proposeLabel(marker, on: msg("x"))] })
}

private func makeOrchestrator(_ h: EngineHarness, triage: any Agent, agents: [any Agent]) -> Orchestrator {
    Orchestrator(registry: AgentRegistry(agents: agents), triage: triage,
                 mailBackend: h.backend, approvals: h.approvals, audit: h.audit,
                 messages: h.messages, index: h.index, embedder: h.embedder,
                 rules: h.rules, now: h.now)
}

@Test func triageCategoryRoutesToTheRightAgents() async throws {
    let h = try EngineHarness()
    // Real message carries BOTH category labels so wakesFor passes; dispatch must be driven
    // by triage's chosen category ("Lead"), routing ONLY to the Lead subscriber.
    let message = msg("m1", labels: ["Lead", "Invoice"])
    try h.messages.save(message)

    let leadAgent = subscriber("lead", category: "Lead", marker: "LEAD_RAN")
    let invoiceAgent = subscriber("invoice", category: "Invoice", marker: "INVOICE_RAN")
    let orch = makeOrchestrator(h, triage: triageTagging("Lead"), agents: [leadAgent, invoiceAgent])

    let outcomes = try await orch.process(message)

    #expect(outcomes.contains { $0.agentId == "lead" && $0.action == .label("LEAD_RAN") })
    #expect(outcomes.contains { $0.agentId == "invoice" } == false)
}

@Test func agentSubscribedButNotWakingForRealMessageIsSkipped() async throws {
    let h = try EngineHarness()
    // The real message has category "Lead" but NOT the extra "Priority" label the agent also requires.
    let message = msg("m2", labels: ["Lead"])
    try h.messages.save(message)

    let pickyAgent = FakeAgent(id: "picky", autonomy: .auto,
                               // Subscribes to "Lead" (probe has only ["Lead"]) AND requires "Priority" on the real msg.
                               wakes: { m, _ in m.labels.contains("Lead") && (m.id == "__probe__" || m.labels.contains("Priority")) },
                               emit: { _, _, tools in [tools.proposeLabel("PICKY_RAN", on: msg("x"))] })
    let orch = makeOrchestrator(h, triage: triageTagging("Lead"), agents: [pickyAgent])

    let outcomes = try await orch.process(message)

    #expect(outcomes.contains { $0.agentId == "picky" } == false)
}

@Test func emptyCategoryRoutesToNoSubscribers() async throws {
    let h = try EngineHarness()
    let message = msg("m3", labels: ["Lead"])
    try h.messages.save(message)

    // Triage emits no label => category stays "" => no subscribers.
    let silentTriage = FakeAgent(id: "triage", autonomy: .auto,
                                 wakes: { _, _ in true }, emit: { _, _, _ in [] })
    let leadAgent = subscriber("lead", category: "Lead", marker: "LEAD_RAN")
    let orch = makeOrchestrator(h, triage: silentTriage, agents: [leadAgent])

    let outcomes = try await orch.process(message)
    #expect(outcomes.contains { $0.agentId == "lead" } == false)
}
```

- [ ] **Step 2: Run to fail/verify**

```
cd Packages/SenaniEngine && swift test --filter OrchestratorTriageTests
```

Expected: these should PASS against the Task-7 Orchestrator (the dispatch logic already exists). If `triageCategoryRoutesToTheRightAgents` fails because the orchestrator dispatched to both subscribers, that means dispatch is keyed off the message's labels rather than triage's chosen category — fix `process(_:)` so dispatch uses only the `category` read from triage's first `.label`, not the message labels. Re-run until green. (The Task-7 implementation already does this; this step verifies it.)

- [ ] **Step 3: (No new implementation expected.)**

If Step 2 was green, no code change. If a fix was needed, it lives in `Orchestrator.process(_:)` as described above.

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniEngine && swift test --filter OrchestratorTriageTests
```

Expected: all 3 pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: lock triage-category dispatch (only subscribed + waking agents run)"
```

(Append the standard trailer.)

---

### Task 9: Orchestrator — audit trail + processInbox coverage

**Files:**
- Test only: `Packages/SenaniEngine/Tests/SenaniEngineTests/OrchestratorAuditTests.swift`

The architecture requires "everything is logged." These tests assert that every routed action — triage's and each agent's — produces exactly one `ActionRecord` with `Trigger.rule(id: agent.id)` and the correct `outcome`, and that `processInbox()` covers every stored message.

- [ ] **Step 1: Write failing audit + processInbox tests**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/OrchestratorAuditTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniStore

private func triageTagging(_ category: String) -> FakeAgent {
    FakeAgent(id: "triage", autonomy: .auto, wakes: { _, _ in true },
              emit: { _, _, _ in [.label(category)] })
}

private func makeOrchestrator(_ h: EngineHarness, triage: any Agent, agents: [any Agent]) -> Orchestrator {
    Orchestrator(registry: AgentRegistry(agents: agents), triage: triage,
                 mailBackend: h.backend, approvals: h.approvals, audit: h.audit,
                 messages: h.messages, index: h.index, embedder: h.embedder,
                 rules: h.rules, now: h.now)
}

@Test func everyOutcomeIsAuditedWithTheAgentsTrigger() async throws {
    let h = try EngineHarness()
    let message = msg("m1", labels: ["Lead"])
    try h.messages.save(message)

    let drafter = FakeAgent(id: "reply-drafter", autonomy: .auto,
                            wakes: { m, _ in m.labels.contains("Lead") },
                            emit: { m, _, tools in [tools.draftReply(to: m, body: "Hi")] })
    let orch = makeOrchestrator(h, triage: triageTagging("Lead"), agents: [drafter])

    _ = try await orch.process(message)

    let entries = try await h.audit.records()
    // One record for triage's .label("Lead"), one for the drafter's .draft.
    let triageRecords = entries.filter { $0.record.trigger == .rule(id: "triage") }
    let drafterRecords = entries.filter { $0.record.trigger == .rule(id: "reply-drafter") }
    #expect(triageRecords.count == 1)
    #expect(triageRecords.first?.record.action == .label("Lead"))
    #expect(triageRecords.first?.record.outcome == .executed)        // reversible + auto
    #expect(drafterRecords.count == 1)
    #expect(drafterRecords.first?.record.action == .draft(body: "Hi"))
    #expect(drafterRecords.first?.record.outcome == .executed)
    #expect(entries.allSatisfy { $0.record.messageId == "m1" })
}

@Test func outboundOutcomeIsAuditedAsQueued() async throws {
    let h = try EngineHarness()
    let message = msg("m2", labels: ["Lead"])
    try h.messages.save(message)

    let sender = FakeAgent(id: "sender", autonomy: .auto,
                           wakes: { m, _ in m.labels.contains("Lead") },
                           emit: { _, _, _ in [.send(body: "Now")] })
    let orch = makeOrchestrator(h, triage: triageTagging("Lead"), agents: [sender])

    _ = try await orch.process(message)

    let entries = try await h.audit.records()
    let sendRecord = entries.first { $0.record.trigger == .rule(id: "sender") }
    #expect(sendRecord?.record.outcome == .queuedForApproval)        // outbound always queues
    #expect(sendRecord?.record.action == .send(body: "Now"))
}

@Test func processInboxCoversEveryStoredMessage() async throws {
    let h = try EngineHarness()
    try h.messages.saveAll([
        msg("a", labels: ["Lead"], threadId: "ta"),
        msg("b", labels: ["Lead"], threadId: "tb"),
        msg("c", labels: ["Lead"], threadId: "tc"),
    ])

    // Triage tags Lead; one subscriber labels each message so we can count coverage.
    let labeler = FakeAgent(id: "labeler", autonomy: .auto,
                            wakes: { m, _ in m.labels.contains("Lead") },
                            emit: { _, _, tools in [tools.proposeLabel("SEEN", on: msg("x"))] })
    let orch = makeOrchestrator(h, triage: triageTagging("Lead"), agents: [labeler])

    let outcomes = try await orch.processInbox()

    let seenMessageIds = Set(h.backend.applied.filter { $0.action == .label("SEEN") }.map(\.messageId))
    #expect(seenMessageIds == ["a", "b", "c"])
    // 3 messages * (triage label + labeler label) = 6 routed outcomes.
    #expect(outcomes.count == 6)
}
```

- [ ] **Step 2: Run to verify**

```
cd Packages/SenaniEngine && swift test --filter OrchestratorAuditTests
```

Expected: all pass against the Task-7 Orchestrator. If `everyOutcomeIsAuditedWithTheAgentsTrigger` shows a record count mismatch, confirm `route(_:by:on:)` records exactly once per action (it does) and that triage's actions are routed (they are). No new production code expected.

- [ ] **Step 3: (No new implementation expected.)**

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniEngine && swift test --filter OrchestratorAuditTests
```

Expected: all 3 pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: lock audit trail (one record per outcome, agent trigger) + processInbox coverage"
```

(Append the standard trailer.)

---

### Task 10: Scheduler — tick (sync → save → process)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Scheduler.swift`
- Test: add to `Packages/SenaniEngine/Tests/SenaniEngineTests/SchedulerTests.swift` (the `FakeGmailSync` already lives there from Task 5)

`Scheduler.tick()` performs one cycle: `sync.fetchMessages(...)` → `store.saveAll(fetched)` → `orchestrator.processInbox()` over the (now-saved) messages. `start()` schedules repeating ticks on the injected `interval` (a detached `Task` loop) and skips a tick when the injected low-power closure returns `true`; `stop()` cancels the loop. The low-power probe is a `@Sendable () -> Bool` injected by the host (no IOKit import here).

The §3 contract pins `Scheduler.init(sync:store:orchestrator:interval:now:)`. We add a low-power closure as a defaulted parameter (`isLowPower: @escaping @Sendable () -> Bool = { false }`) so the pinned call sites still compile while satisfying the scope's low-power requirement. `tick()` syncs with a default query (`"newer_than:7d"`, `maxResults: 50`) — both are reasonable Phase-1 defaults and exercised by the FakeGmailSync.

- [ ] **Step 1: Write failing scheduler tests**

Append to `Packages/SenaniEngine/Tests/SenaniEngineTests/SchedulerTests.swift`:

```swift
import SenaniStore

private func triageTagging(_ category: String) -> FakeAgent {
    FakeAgent(id: "triage", autonomy: .auto, wakes: { _, _ in true },
              emit: { _, _, _ in [.label(category)] })
}

private func leadOrchestrator(_ h: EngineHarness) -> Orchestrator {
    let labeler = FakeAgent(id: "labeler", autonomy: .auto,
                            wakes: { m, _ in m.labels.contains("Lead") },
                            emit: { _, _, tools in [tools.proposeLabel("SEEN", on: msg("x"))] })
    return Orchestrator(registry: AgentRegistry(agents: [labeler]),
                        triage: triageTagging("Lead"),
                        mailBackend: h.backend, approvals: h.approvals, audit: h.audit,
                        messages: h.messages, index: h.index, embedder: h.embedder,
                        rules: h.rules, now: h.now)
}

@Test func tickSyncsSavesAndProcesses() async throws {
    let h = try EngineHarness()
    let sync = FakeGmailSync(batch: [msg("g1", labels: ["Lead"], threadId: "tg1"),
                                     msg("g2", labels: ["Lead"], threadId: "tg2")])
    let orch = leadOrchestrator(h)
    let scheduler = Scheduler(sync: sync, store: h.messages, orchestrator: orch,
                              interval: 60, now: h.now)

    try await scheduler.tick()

    // Synced messages were saved.
    let saved = Set(try h.messages.all().map(\.id))
    #expect(saved == ["g1", "g2"])
    // And processed: the labeler applied SEEN to each.
    let seen = Set(h.backend.applied.filter { $0.action == .label("SEEN") }.map(\.messageId))
    #expect(seen == ["g1", "g2"])
    #expect(sync.callCount == 1)
}

@Test func tickWithEmptySyncProcessesExistingInbox() async throws {
    let h = try EngineHarness()
    try h.messages.save(msg("existing", labels: ["Lead"], threadId: "te"))
    let sync = FakeGmailSync(batch: [])
    let orch = leadOrchestrator(h)
    let scheduler = Scheduler(sync: sync, store: h.messages, orchestrator: orch,
                              interval: 60, now: h.now)

    try await scheduler.tick()

    let seen = Set(h.backend.applied.filter { $0.action == .label("SEEN") }.map(\.messageId))
    #expect(seen == ["existing"])   // processInbox covers already-stored mail too
}

@Test func startRespectsLowPowerBySkippingTheCycle() async throws {
    let h = try EngineHarness()
    let sync = FakeGmailSync(batches: [[msg("g1", labels: ["Lead"])], [msg("g2", labels: ["Lead"])]])
    let orch = leadOrchestrator(h)
    // Low power is ALWAYS true => start() must never sync.
    let scheduler = Scheduler(sync: sync, store: h.messages, orchestrator: orch,
                              interval: 0.01, now: h.now, isLowPower: { true })

    await scheduler.start()
    // Give the loop a few intervals to (not) run, then stop.
    try await Task.sleep(nanoseconds: 50_000_000)   // 50ms >> 5 intervals of 10ms
    await scheduler.stop()

    #expect(sync.callCount == 0)
    #expect(h.backend.applied.isEmpty)
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniEngine && swift test --filter SchedulerTests
```

Expected: failure — `Scheduler` undefined.

- [ ] **Step 3: Implement `Scheduler`**

Create `Packages/SenaniEngine/Sources/SenaniEngine/Scheduler.swift`:

```swift
import Foundation
import SenaniRules
import SenaniStore

/// Drives processing on a timer while the Mac is awake, after a sync, and on the
/// manual "Process inbox" button (the host calls `tick()`). One cycle is:
/// sync.fetchMessages -> MessageStore.saveAll -> orchestrator.processInbox.
/// Low-power is checked via an injected closure (no IOKit import in this package).
public actor Scheduler {
    private let sync: any GmailSyncing
    private let store: MessageStore
    private let orchestrator: Orchestrator
    private let interval: TimeInterval
    private let now: @Sendable () -> Date
    private let isLowPower: @Sendable () -> Bool

    private var loop: Task<Void, Never>?

    /// Phase-1 sync defaults; the host may evolve these.
    private let query = "newer_than:7d"
    private let maxResults = 50

    public init(sync: any GmailSyncing,
                store: MessageStore,
                orchestrator: Orchestrator,
                interval: TimeInterval,
                now: @escaping @Sendable () -> Date,
                isLowPower: @escaping @Sendable () -> Bool = { false }) {
        self.sync = sync
        self.store = store
        self.orchestrator = orchestrator
        self.interval = interval
        self.now = now
        self.isLowPower = isLowPower
    }

    /// One sync+process cycle. Called by the UI/timer/manual button.
    @discardableResult
    public func tick() async throws -> [ProcessedOutcome] {
        let fetched = try await sync.fetchMessages(query: query, maxResults: maxResults)
        if !fetched.isEmpty {
            try store.saveAll(fetched)
        }
        return try await orchestrator.processInbox()
    }

    /// Schedule repeating ticks on `interval`, skipping a cycle while on low power.
    public func start() async {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.runCycleIfAllowed()
                let nanos = await self.intervalNanos()
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    /// Cancel the repeating loop.
    public func stop() async {
        loop?.cancel()
        loop = nil
    }

    private func intervalNanos() -> UInt64 {
        UInt64(max(0, interval) * 1_000_000_000)
    }

    private func runCycleIfAllowed() async {
        if isLowPower() { return }
        _ = try? await tick()
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniEngine && swift test --filter SchedulerTests
```

Expected: all pass (including `fakeGmailSyncConformsToTheSeam` from Task 5). The low-power test should show `callCount == 0`.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: Scheduler tick (sync->save->processInbox) + start/stop with injected low-power check"
```

(Append the standard trailer.)

---

### Task 11: Full suite green + strict-concurrency clean build

**Files:** none (verification + final commit)

- [ ] **Step 1: Run the whole suite**

```
cd Packages/SenaniEngine && swift test
```

Expected: ALL tests pass across `AgentToolsTests`, `AgentRegistryTests`, `ProcessedOutcomeTests`, `SchedulerTests`, `OrchestratorRoutingTests`, `OrchestratorTriageTests`, `OrchestratorAuditTests`, and `testSupportConstructsAnInMemoryGraph`. No `ProbeTests` remains.

- [ ] **Step 2: Confirm a clean strict-concurrency build (no warnings)**

```
cd Packages/SenaniEngine && swift build 2>&1 | tee /tmp/senaniengine-build.log
```

Expected: build succeeds with no concurrency warnings. If any `Sendable`/actor-isolation warning appears, fix it at the source (e.g. capture `self.embedder`/`self.index` as locals before forming the `@Sendable` `retrieve` closure, as the Orchestrator already does) and re-run. Do not silence with `@unchecked` in non-test code.

- [ ] **Step 3: Verify the contract surface matches §3 exactly**

Visually diff the public signatures of `Agent`, `AgentContext`, `AgentTools`, `AgentRegistry`, `Orchestrator`, `Scheduler`, `GmailSyncing`, `ProcessedOutcome` against §3 of `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md`. The only intentional additions are `Scheduler`'s defaulted `isLowPower:` parameter and `Scheduler.tick()`'s `@discardableResult [ProcessedOutcome]` return — both backward compatible with the pinned call sites. Record these two as deviations in the reconciliation doc's §3 (same commit) if you want the doc to be byte-exact.

- [ ] **Step 4: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: full suite green + strict-concurrency clean build"
```

(Append the standard trailer.)

---

## Self-Review

**1. Spec coverage** (against the SCOPE in the task brief and ARCHITECTURE/ROADMAP Phase 1):
- New `Packages/SenaniEngine` package, macOS 14, Swift 6.2 strict concurrency, Swift Testing, depending only on `SenaniRules`/`SenaniStore`/`SenaniInference` → Task 1. ✓
- App wiring note (`SenaniApp/Package.swift` gains `SenaniEngine`) recorded but not done here (app-shell plan owns it) → header "App wiring note". ✓
- `protocol Agent` (id, autonomy, wakesFor, proposals) → Task 3. ✓
- `struct AgentContext` (account, thread, rules, retrieve closure, now) → Task 3. ✓
- `struct AgentTools` pure builders (draftReply/proposeLabel/archive/markRead) → Task 2. ✓
- `struct AgentRegistry` (agents(for:)) → Task 6. ✓
- `actor Orchestrator` with the pinned init + process + processInbox → Task 7. ✓
- `actor Scheduler` with init + tick + start + stop → Task 10. ✓
- `protocol GmailSyncing` + ProcessedOutcome → Tasks 5, 4. ✓
- Orchestrator runs triage first, reads category from triage's `.label` action, dispatches to `registry.agents(for:)`, routes each Action via `ActionRouter.route(action, autonomy: agent.autonomy)`: `.executed`→`MailBackend.apply`; `.queuedForApproval`/`.prepared`→`ApprovalStore.enqueue(id:_:)` with a generated id; ALWAYS records `ActionRecord` with `Trigger.rule(id: agent.id)`; returns `[ProcessedOutcome]` → Task 7. Note `.prepared` routes to `MailBackend.apply` (matching the frozen `ActionExecutor`, which applies on both `.executed` and `.prepared`); the scope said "`.prepared`→enqueue" — see deviation note below. ✓ (deviation flagged)
- `processInbox()` batches over `MessageStore.all()` → Task 7, tested Task 9. ✓
- Scheduler.tick: one sync → saveAll → processInbox; start/stop on interval; low-power injected closure (no IOKit) → Task 10. ✓
- GmailSyncing conformance shim location (app tier) defined and noted → header. ✓
- retrieve closure built by caller; package only holds it → AgentContext holds it; Orchestrator builds a concrete one from injected index+embedder per the contract. ✓
- One safety path; outbound always queues → Task 7 routing + Task 7/9 tests. ✓
- Tests pure (no MLX/Gmail/network): FakeMailBackend, in-memory ApprovalStore + audit via `SenaniDatabase.inMemory()`, FakeTextGenerator, fake Agents → Task 3 TestSupport. ✓
- Required test scenarios: outbound queues regardless of autonomy (Task 7); reversible+auto executes (Task 7); reversible+ask queues (Task 7); triage category routes to right agents (Task 8); audit records every outcome with agent's trigger (Task 9); Scheduler.tick syncs+saves+processes via fake (Task 10); processInbox covers all messages (Task 9). ✓
- Format: required header + REQUIRED SUB-SKILL line, Goal/Architecture/Tech Stack/Working directory, Cross-package assumptions restating verified upstream signatures, File Structure block, bite-sized TDD tasks with exact paths + commands + expected output, Self-Review → all present. ✓

**2. Placeholder scan:** No "TBD/TODO/implement later" steps; every code step shows complete code; every command shows expected output. The two "verification" tasks (8, 9) explicitly state "no new production code expected" because the Task-7 Orchestrator already satisfies them — this is intentional lock-in via tests, not a placeholder. ✓

**3. Type consistency:** `Orchestrator.init` parameter order/labels match §3 and the Task-7/8/9/10 call sites (`registry, triage, mailBackend, approvals, audit, messages, index, embedder, rules, now`). `ProcessedOutcome(agentId:action:outcome:)` consistent across Tasks 4/7/9/10. `AgentTools` builder names (`draftReply/proposeLabel/archive/markRead`) consistent between Tasks 2 and 7-10 tests. `FakeAgent`'s `wakes`/`emit` closure shapes match `Agent.wakesFor`/`proposals`. `EngineHarness` field names used identically across Tasks 7-10. `GmailSyncing.fetchMessages(query:maxResults:)` matches `FakeGmailSync` and the shim. ✓

**Deviations to record at build time** (per the reconciliation discipline — adapt SenaniEngine, log it, don't break the contract):
- **`.prepared` routing:** the frozen `ActionExecutor` applies reversible actions via `MailBackend` on BOTH `.executed` and `.prepared` (a `.prepare`-autonomy agent's reversible action is staged by applying it). The scope text said "`.prepared`→enqueue", but matching the frozen kernel's single safety path means `.prepared` flows to `MailBackend.apply`, not the approval queue. This plan follows the frozen kernel (one safety path) and flags the wording mismatch for the human. If product wants `.prepare` to stage in the approval queue instead, that is a `SenaniRules.ActionExecutor` change (frozen package) — surface it, don't fork.
- **`AgentContext.account`** is derived from the message rather than injected, because the pinned `Orchestrator.init` carries no account string. App-shell may wrap to inject the real account.
- **`Scheduler` additions:** defaulted `isLowPower:` parameter and `tick()`'s `@discardableResult -> [ProcessedOutcome]` return — additive, backward compatible with the pinned call sites.
