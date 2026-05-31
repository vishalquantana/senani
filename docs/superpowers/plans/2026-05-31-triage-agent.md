# Triage Agent Implementation Plan (Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure, fully-unit-tested **Triage agent** — the first agent in Senani's pipeline (ARCHITECTURE.md "The pipeline": `Gmail sync → Triage (classify + prioritize) → Orchestrator routes by category`). The Triage agent classifies every unprocessed inbound message into a **category** (`Lead` / `Booking` / `Proposal` / `Newsletter` / `Personal` / `Other`) and a **priority** (`high` / `normal` / `low`) by calling an injected `TextGenerator.generateJSON(prompt:schema:)` with a strict JSON-shape schema, parses the result **safely (never crashing on bad model output)**, and emits reversible `proposeLabel` Actions (`Senani/Category/<Category>`, `Senani/Priority/<Priority>`). It wakes for every unprocessed inbound message. It is a pure function `(message, context, tools) → [Action]` with **no MLX, no Gmail, no SwiftUI** in this plan — driven entirely by a **local `FakeTextGenerator`** returning canned JSON.

**Architecture:** The Triage agent conforms to the `SenaniEngine.Agent` protocol pinned in `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md` §3 (`Agent` / `AgentContext` / `AgentTools` / `AgentRegistry`). That `SenaniEngine` package **does not exist yet** in this worktree (verified: `Packages/` has no `SenaniEngine` and no `SenaniAgents`). Two consequences drive the structure below:

1. **Where the agent lives — DECISION: co-locate Phase-1 agents inside the `SenaniEngine` package, under `Sources/SenaniEngine/Agents/`.** Rationale: the brief offers a sibling `Packages/SenaniAgents` (depends on SenaniEngine) *or* co-location in SenaniEngine. The agent's only hard dependency is the `Agent`/`AgentContext`/`AgentTools` contract, which lives in SenaniEngine; co-locating avoids a package explosion (one fewer SPM package, one fewer `path:` ref in `SenaniApp/Package.swift`) and removes a cross-package import edge for a type that is meaningless without SenaniEngine. The Orchestrator (a separate plan) already lives in SenaniEngine and must hold a reference to the Triage agent as its `triage:` init parameter, so they belong together. If a future phase grows agents large enough to warrant isolation, extracting a `SenaniAgents` package is a mechanical move (the agent depends only on the public SenaniEngine contract). **This plan therefore also bootstraps the minimal SenaniEngine contract files the agent compiles against** (the `Agent` protocol, `AgentContext`, `AgentTools`), because the full Orchestrator plan has not landed. Those contract files are written to match §3 *exactly* so the Orchestrator plan drops in on top without changing them.

2. **`AgentTools` needs a generator seam — flagged §3 contract addition.** §3's `AgentTools` exposes only pure Action *builders* (`draftReply`, `proposeLabel`, `archive`, `markRead`) and no way to reach the `TextGenerator`. The Triage agent must call `generateJSON`. Per the brief ("prefer adding a `generate`/`generateJSON` accessor on AgentTools and flag it as a SenaniEngine contract addition"), this plan **adds `AgentTools.generateJSON(prompt:schema:)`** (a thin async passthrough to an injected `any TextGenerator`) and records it as the single addition to the pinned §3 `AgentTools` contract. The APP-PLANS-RECONCILIATION §3 entry for `AgentTools` MUST be updated in the same commit (see Self-Review). No other §3 type changes.

**Tech Stack:** Swift 6.2, strict concurrency, `swift-tools-version: 6.0`, Swift Package Manager, Swift Testing (`import Testing`, ships with the toolchain). Target platform macOS 14. Depends only on the frozen `SenaniRules` and `SenaniInference`. No MLX, no Gmail, no UI.

**Working directory:** All `swift` commands run from `Packages/SenaniEngine/` unless stated otherwise.

**Roadmap:** ROADMAP.md Phase 1 → "**Triage** agent (classify + prioritize + label)". This plan delivers the agent + its classification logic. The Orchestrator (routing by the category labels this agent emits), Scheduler, AgentRegistry wiring, and the live `MLXTextGenerator` path are **separate plans** on the same Phase-1 critical path.

**Out of scope (separate plans):** the `Orchestrator`/`Scheduler`/`AgentRegistry` runtime (the orchestrator plan owns those — this plan ships only the minimal `Agent`/`AgentContext`/`AgentTools` contract the agent needs to compile and test); the real Gemma `TextGenerator` (MLX); the Gmail `MailBackend`; the Reply Drafter agent; all UI.

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
    public var actionClass: ActionClass   // .reversible | .outbound
}
public enum ActionClass: Sendable, Equatable { case reversible, outbound }   // .label is .reversible
public enum Autonomy: String, Sendable, Equatable { case ask, prepare, auto }  // new rules default .ask
public struct Rule: Sendable, Equatable, Identifiable { /* id, name, enabled, conditions, actions, autonomy, runOn */ }
```
- **Key facts used here:** `Action.label(String).actionClass == .reversible` (so the Orchestrator can auto-apply Triage's label proposals when the agent's autonomy allows). `Message.senderDomain` is computed. `Autonomy` real cases are `.ask/.prepare/.auto`.

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
    public init(json: String)   // tolerant parse; unknown/invalid -> .object(properties:[:],required:[])
}
public enum InferenceError: Error, Sendable, Equatable { case modelNotLoaded, generationFailed(String), decodingFailed(String) }
```
- **CRITICAL constraint (verified):** `JSONSchema` has **no enum/`oneOf` constraint** — `.string` cannot pin a value to `Lead|Booking|…`. Therefore the schema can only constrain *shape* (an object with `category`, `priority`, `reason` string fields). The category/priority **enums are enforced in the prompt instructions and re-validated when parsing**, with a safe fallback to `Other`/`normal` on any deviation. We do **not** depend on the generator to enforce the enum. This is the honest contract; do not pretend the schema constrains the enum.
- **No upstream fakes (verified):** `SenaniInference` ships only `MLXTextGenerator`. This plan defines its **own** local `FakeTextGenerator` in the test target.

### `SenaniEngine` (NEW — pinned by APP-PLANS-RECONCILIATION §3; partially bootstrapped by THIS plan)
The package does not exist yet. This plan creates it with **only** the contract types the Triage agent needs, written to match §3 exactly. The Orchestrator plan extends the same package (adds `Orchestrator`, `Scheduler`, `AgentRegistry`, `ProcessedOutcome`, `GmailSyncing`) without editing these files.
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
}
public struct AgentTools: Sendable {
    public func draftReply(to message: Message, body: String) -> Action
    public func proposeLabel(_ label: String, on message: Message) -> Action
    public func archive(_ message: Message) -> Action
    public func markRead(_ message: Message) -> Action
    // ⚠ CONTRACT ADDITION (this plan): generator seam so agents can call the LLM.
    public func generateJSON(prompt: String, schema: JSONSchema) async throws -> String
}
```
- **`VectorHit`:** §3 types `AgentContext.retrieve` as returning `[VectorHit]` (a `SenaniStore` type). To keep this plan dependency-light and the agent pure (Triage does **not** use retrieval), this plan defines `retrieve` against `SenaniStore.VectorHit` only if SenaniEngine already depends on SenaniStore. **Since SenaniEngine does not yet exist, this plan pins SenaniEngine's deps as `SenaniRules` + `SenaniInference` + `SenaniStore`** (matching §3, which references `Rule`, `Message`, `VectorHit`, `Embedder`, etc.). `SenaniStore` is frozen and exposes `public struct VectorHit { public let id: String; public let distance: Float; public let metadata: [String:String] }`. If wiring `SenaniStore` into SenaniEngine's manifest fails to resolve, that is a blocking prerequisite — record it; do NOT stub VectorHit.
- **Generator injection:** `AgentTools` holds a stored `private let generator: any TextGenerator` plus the pure builders. The Orchestrator constructs `AgentTools` per agent run, injecting the live (or fake) generator. The pure builders ignore the generator; `generateJSON` forwards to it.

---

## File Structure

```
Packages/SenaniEngine/
  Package.swift
  Sources/SenaniEngine/
    Agent.swift                 # Agent protocol (§3) — bootstrapped here, owned long-term by orchestrator plan
    AgentContext.swift          # AgentContext (§3)
    AgentTools.swift            # AgentTools (§3 + the generateJSON contract addition)
    Agents/
      TriageCategory.swift      # TriageCategory + TriagePriority enums (the label vocabulary)
      TriageClassification.swift# Decoded {category, priority, reason} + safe parse + JSON schema
      TriageAgent.swift         # TriageAgent: Agent — wakesFor + proposals (prompt build, generate, parse, label Actions)
  Tests/SenaniEngineTests/
    TestSupport.swift           # local FakeTextGenerator (canned JSON, records prompts) + msg() helper + tools()
    TriageClassificationTests.swift  # schema shape + safe parse + enum validation + fallback
    TriageAgentTests.swift           # wakesFor + label Actions + malformed-JSON fallback + priority mapping + prompt content
```

One responsibility per file. `TriageAgent` depends only on the SenaniEngine contract (`Agent`/`AgentContext`/`AgentTools`) + `SenaniRules.Action`/`Message` + `SenaniInference.JSONSchema`. Every test runs against a local `FakeTextGenerator`.

---

### Task 1: SenaniEngine package scaffold + path dependencies

**Files:**
- Create: `Packages/SenaniEngine/Package.swift`
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agent.swift` (temporary one-line marker so the target compiles)
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/TriageAgentTests.swift` (placeholder import-only test)

- [ ] **Step 1: Write a failing import test**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/TriageAgentTests.swift`:

```swift
import Testing
@testable import SenaniEngine
import SenaniRules

@Test func packageImportsCompile() {
    // Proves the package builds and links SenaniRules.
    let action: SenaniRules.Action = .label("x")
    #expect(action.actionClass == .reversible)
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniEngine && swift test
```

Expected: failure — no `Package.swift` / no `SenaniEngine` target (`error: no such module` / manifest not found).

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
        .package(path: "../SenaniInference"),
        .package(path: "../SenaniStore"),
    ],
    targets: [
        .target(
            name: "SenaniEngine",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "SenaniInference", package: "SenaniInference"),
                .product(name: "SenaniStore", package: "SenaniStore"),
            ]
        ),
        .testTarget(
            name: "SenaniEngineTests",
            dependencies: ["SenaniEngine"]
        ),
    ]
)
```

Create `Packages/SenaniEngine/Sources/SenaniEngine/Agent.swift` with a single marker line so the target is non-empty (replaced in Task 2):

```swift
// SenaniEngine — the Agent Engine. Agent contract defined in Task 2.
import SenaniRules
```

> **Note for the worker:** if `swift test` fails to *resolve* `../SenaniStore` / `../SenaniInference` (not a code error), that is a blocking external prerequisite — record it and coordinate; do NOT stub the sibling packages. `SenaniStore` is only needed for `VectorHit` in `AgentContext.retrieve`; if `SenaniStore` is genuinely unavailable in this worktree, fall back to dropping the `SenaniStore` dep and typing `retrieve`'s element as a locally-defined `VectorHit` placeholder — but FLAG this deviation loudly, because §3 pins the real type.

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniEngine && swift test
```

Expected: 1 test passes.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: package scaffold with SenaniRules/Inference/Store path deps"
```

Use this commit trailer on EVERY commit in this plan:

```

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

---

### Task 2: SenaniEngine contract — Agent, AgentContext, AgentTools (+ generator seam)

**Files:**
- Edit: `Packages/SenaniEngine/Sources/SenaniEngine/Agent.swift`
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/AgentContext.swift`
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/AgentTools.swift`
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/TestSupport.swift` (doubles + a contract self-test)

This bootstraps the §3 contract types the Triage agent compiles against, plus the flagged `AgentTools.generateJSON` addition.

- [ ] **Step 1: Write a failing contract self-test**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/TestSupport.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniInference
import SenaniStore

// ---- Local fake generator (SenaniInference ships none). Records prompts; dequeues canned JSON FIFO. ----
final class FakeTextGenerator: TextGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String]
    private var _recordedPrompts: [String] = []

    init(responses: [String]) { self.responses = responses }
    init(response: String) { self.responses = [response] }

    var recordedPrompts: [String] { lock.lock(); defer { lock.unlock() }; return _recordedPrompts }
    var lastPrompt: String? { recordedPrompts.last }

    func generate(prompt: String, maxTokens: Int) async throws -> String {
        try await generateJSON(prompt: prompt, schema: .object(properties: [:], required: []))
    }
    func generateJSON(prompt: String, schema: JSONSchema) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        _recordedPrompts.append(prompt)
        if responses.count > 1 { return responses.removeFirst() }
        return responses.first ?? "{}"
    }
}

// ---- Helpers ----
func msg(_ id: String,
         from: String = "stranger@acme.com",
         subject: String = "Quick question",
         body: String = "Can you help?",
         isFromUser: Bool = false,
         labels: [String] = []) -> Message {
    Message(id: id, from: from, to: ["me@x.com"], subject: subject, body: body,
            hasAttachment: false, listUnsubscribeHeader: nil, labels: labels,
            threadId: "t-\(id)", date: Date(), isFromUser: isFromUser)
}

func tools(_ generator: TextGenerator) -> AgentTools { AgentTools(generator: generator) }

func ctx(now: Date = Date()) -> AgentContext {
    AgentContext(account: "me@x.com", thread: [], rules: [],
                 retrieve: { _, _ in [] }, now: now)
}

// ---- self-test ----
@Test func agentToolsBuildsReversibleLabelAndForwardsGeneration() async throws {
    let t = tools(FakeTextGenerator(response: #"{"category":"Other","priority":"normal","reason":"x"}"#))
    let label = t.proposeLabel("Senani/Category/Lead", on: msg("m1"))
    #expect(label == .label("Senani/Category/Lead"))
    #expect(label.actionClass == .reversible)
    let json = try await t.generateJSON(prompt: "hi", schema: .object(properties: [:], required: []))
    #expect(json.contains("Other"))
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniEngine && swift test --filter agentToolsBuildsReversibleLabelAndForwardsGeneration
```

Expected: failure — `AgentContext`/`AgentTools`/`Agent` undefined.

- [ ] **Step 3: Implement the contract**

Replace `Sources/SenaniEngine/Agent.swift`:

```swift
import SenaniRules

/// An agent is a pure function from (message, context, tools) -> proposals.
/// It NEVER touches Gmail directly; it returns reversible/outbound Actions and the
/// Orchestrator routes them via ActionRouter + the agent's autonomy dial.
/// (APP-PLANS-RECONCILIATION §3.)
public protocol Agent: Sendable {
    var id: String { get }                 // stable identity, e.g. "triage"
    var autonomy: Autonomy { get }         // per-agent dial; the Orchestrator enforces it
    func wakesFor(_ message: Message, context: AgentContext) -> Bool
    func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action]
}
```

Create `Sources/SenaniEngine/AgentContext.swift`:

```swift
import Foundation
import SenaniRules
import SenaniStore

/// Read-only world the agent may see, pre-populated by the Orchestrator.
/// Agents never query stores directly. (APP-PLANS-RECONCILIATION §3.)
public struct AgentContext: Sendable {
    public let account: String
    public let thread: [Message]            // the message's thread, date asc
    public let rules: [Rule]
    public let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit]
    public let now: Date

    public init(account: String, thread: [Message], rules: [Rule],
                retrieve: @escaping @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit],
                now: Date) {
        self.account = account
        self.thread = thread
        self.rules = rules
        self.retrieve = retrieve
        self.now = now
    }
}
```

Create `Sources/SenaniEngine/AgentTools.swift`:

```swift
import SenaniRules
import SenaniInference

/// Capabilities an agent may call to BUILD actions (pure builders — they return an
/// Action, they do NOT execute) plus the generator seam for LLM-backed agents.
/// (APP-PLANS-RECONCILIATION §3, with the generateJSON addition flagged by the Triage plan.)
public struct AgentTools: Sendable {
    private let generator: any TextGenerator

    public init(generator: any TextGenerator) {
        self.generator = generator
    }

    // --- pure Action builders ---
    public func draftReply(to message: Message, body: String) -> Action { .draft(body: body) }
    public func proposeLabel(_ label: String, on message: Message) -> Action { .label(label) }
    public func archive(_ message: Message) -> Action { .archive }
    public func markRead(_ message: Message) -> Action { .markRead }

    // --- generator seam (CONTRACT ADDITION) ---
    /// Forwards to the injected TextGenerator. The Orchestrator injects the live
    /// MLXTextGenerator (or a fake in tests). Agents stay pure: this is the ONLY I/O seam.
    public func generateJSON(prompt: String, schema: JSONSchema) async throws -> String {
        try await generator.generateJSON(prompt: prompt, schema: schema)
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniEngine && swift test --filter agentToolsBuildsReversibleLabelAndForwardsGeneration
```

Expected: pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: Agent/AgentContext/AgentTools contract (+ generateJSON seam)"
```

(Append the standard trailer.)

---

### Task 3: Triage vocabulary + classification (schema, safe parse, enum validation, fallback)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/TriageCategory.swift`
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/TriageClassification.swift`
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/TriageClassificationTests.swift`

`TriageCategory`/`TriagePriority` are the closed label vocabulary. `TriageClassification` decodes the model's `{category, priority, reason}` JSON, **validating each field against the enum and falling back to `.other` / `.normal` on any deviation or malformed JSON — it never throws and never crashes.**

- [ ] **Step 1: Write failing classification tests**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/TriageClassificationTests.swift`:

```swift
import Testing
@testable import SenaniEngine
import SenaniInference

@Test func categoryAndPriorityLabelStrings() {
    #expect(TriageCategory.lead.label == "Senani/Category/Lead")
    #expect(TriageCategory.booking.label == "Senani/Category/Booking")
    #expect(TriageCategory.proposal.label == "Senani/Category/Proposal")
    #expect(TriageCategory.newsletter.label == "Senani/Category/Newsletter")
    #expect(TriageCategory.personal.label == "Senani/Category/Personal")
    #expect(TriageCategory.other.label == "Senani/Category/Other")
    #expect(TriagePriority.high.label == "Senani/Priority/High")
    #expect(TriagePriority.normal.label == "Senani/Priority/Normal")
    #expect(TriagePriority.low.label == "Senani/Priority/Low")
}

@Test func schemaConstrainsTheShapeToCategoryPriorityReason() {
    // The schema can only constrain SHAPE (JSONSchema has no enum support), so we
    // assert it is an object requiring the three string fields.
    guard case let .object(properties, required) = TriageClassification.schema else {
        Issue.record("schema must be an object"); return
    }
    #expect(properties["category"] == .string)
    #expect(properties["priority"] == .string)
    #expect(properties["reason"] == .string)
    #expect(Set(required) == ["category", "priority", "reason"])
    // The enum values are NOT in the schema type; they are enforced in the prompt + parse.
    #expect(TriageClassification.schema == JSONSchema(json: TriageClassification.schemaJSON))
}

@Test func parsesWellFormedClassification() {
    let c = TriageClassification.parse(#"{"category":"Lead","priority":"high","reason":"new prospect"}"#)
    #expect(c.category == .lead)
    #expect(c.priority == .high)
    #expect(c.reason == "new prospect")
}

@Test func parseToleratesSurroundingProseAndCasing() {
    // JSON embedded in chatter, mixed case enum values.
    let c = TriageClassification.parse(#"Sure! {"category":"BOOKING","priority":"Low","reason":"reschedule"} done"#)
    #expect(c.category == .booking)
    #expect(c.priority == .low)
}

@Test func unknownCategoryFallsBackToOther() {
    let c = TriageClassification.parse(#"{"category":"Spaceship","priority":"high","reason":"?"}"#)
    #expect(c.category == .other)        // unknown enum -> Other
    #expect(c.priority == .high)         // priority still valid
}

@Test func unknownPriorityFallsBackToNormal() {
    let c = TriageClassification.parse(#"{"category":"Lead","priority":"URGENT-NOW","reason":"?"}"#)
    #expect(c.category == .lead)
    #expect(c.priority == .normal)       // unknown enum -> normal
}

@Test func malformedJsonFallsBackToOtherNormalNeverCrashes() {
    let bad = TriageClassification.parse("{ this is not json")
    #expect(bad.category == .other)
    #expect(bad.priority == .normal)
    let empty = TriageClassification.parse("")
    #expect(empty.category == .other)
    #expect(empty.priority == .normal)
    let missing = TriageClassification.parse(#"{"reason":"only reason"}"#)
    #expect(missing.category == .other)
    #expect(missing.priority == .normal)
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniEngine && swift test --filter TriageClassificationTests
```

Expected: failure — `TriageCategory`/`TriagePriority`/`TriageClassification` undefined.

- [ ] **Step 3: Implement the vocabulary**

Create `Sources/SenaniEngine/Agents/TriageCategory.swift`:

```swift
/// The closed set of triage categories. The Orchestrator routes downstream agents
/// by the category label this agent emits (ARCHITECTURE "The pipeline").
public enum TriageCategory: String, CaseIterable, Sendable, Equatable {
    case lead, booking, proposal, newsletter, personal, other

    /// The reversible Gmail label the agent proposes, e.g. "Senani/Category/Lead".
    public var label: String { "Senani/Category/\(rawValue.capitalized)" }

    /// Case-insensitive lookup; unknown -> .other (safe fallback).
    public static func parse(_ raw: String) -> TriageCategory {
        TriageCategory(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .other
    }
}

/// The closed set of triage priorities.
public enum TriagePriority: String, CaseIterable, Sendable, Equatable {
    case high, normal, low

    public var label: String { "Senani/Priority/\(rawValue.capitalized)" }

    /// Case-insensitive lookup; unknown -> .normal (safe fallback).
    public static func parse(_ raw: String) -> TriagePriority {
        TriagePriority(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .normal
    }
}
```

> `rawValue.capitalized` yields `Lead`, `Booking`, `High`, … from the lowercase cases. `Foundation` is imported transitively via the parse helpers; add `import Foundation` to this file (for `trimmingCharacters`).

Add `import Foundation` at the top of `TriageCategory.swift`.

Create `Sources/SenaniEngine/Agents/TriageClassification.swift`:

```swift
import Foundation
import SenaniInference

/// The decoded result of one triage classification. Construction NEVER fails:
/// `parse` validates every field against the enum and falls back to .other/.normal.
public struct TriageClassification: Sendable, Equatable {
    public let category: TriageCategory
    public let priority: TriagePriority
    public let reason: String

    public init(category: TriageCategory, priority: TriagePriority, reason: String) {
        self.category = category
        self.priority = priority
        self.reason = reason
    }

    /// The shape the generator is asked to emit. NOTE: JSONSchema has no enum support,
    /// so this constrains SHAPE only (object with three string fields). The enum is
    /// enforced in the prompt and re-validated in `parse`.
    public static let schemaJSON = """
    {
      "type": "object",
      "properties": {
        "category": { "type": "string" },
        "priority": { "type": "string" },
        "reason": { "type": "string" }
      },
      "required": ["category", "priority", "reason"]
    }
    """

    public static let schema = JSONSchema(json: schemaJSON)

    /// Safe parse: extracts the first JSON object in `raw`, reads the three fields,
    /// validates each against its enum (unknown -> fallback), never throws/crashes.
    public static func parse(_ raw: String) -> TriageClassification {
        guard
            let data = firstJSONObject(in: raw),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        else {
            return TriageClassification(category: .other, priority: .normal, reason: "")
        }
        let category = TriageCategory.parse((dict["category"] as? String) ?? "")
        let priority = TriagePriority.parse((dict["priority"] as? String) ?? "")
        let reason = (dict["reason"] as? String) ?? ""
        return TriageClassification(category: category, priority: priority, reason: reason)
    }

    /// Returns the bytes of the first balanced {...} object found in `raw`, tolerating
    /// surrounding prose. Mirrors SenaniInference.JSONResultParser's scanner.
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

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniEngine && swift test --filter TriageClassificationTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: TriageCategory/Priority vocab + safe TriageClassification parse"
```

(Append the standard trailer.)

---

### Task 4: TriageAgent — wakesFor + proposals (prompt build, generate, parse, label Actions)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/TriageAgent.swift`
- Test: `Packages/SenaniEngine/Tests/SenaniEngineTests/TriageAgentTests.swift` (replace the placeholder)

The agent: `id == "triage"`, `autonomy == .auto` (its label proposals are reversible, so the Orchestrator may auto-apply them — ARCHITECTURE: reversible internal actions can auto-run). `wakesFor` is true for **every unprocessed inbound message** (not from the user, and not already triaged). `proposals` builds a deterministic prompt from the message + a fixed policy instruction, calls `tools.generateJSON(prompt:schema:)`, parses safely, and returns **two** reversible `proposeLabel` Actions: the category label and the priority label.

- [ ] **Step 1: Replace the placeholder test with real failing tests**

Replace `Packages/SenaniEngine/Tests/SenaniEngineTests/TriageAgentTests.swift`:

```swift
import Testing
@testable import SenaniEngine
import SenaniRules
import Foundation

@Test func packageImportsCompile() {
    let action: SenaniRules.Action = .label("x")
    #expect(action.actionClass == .reversible)
}

@Test func triageIdentityAndAutonomy() {
    let agent = TriageAgent()
    #expect(agent.id == "triage")
    #expect(agent.autonomy == .auto)   // reversible labels -> Orchestrator may auto-apply
}

@Test func wakesForEveryUnprocessedInboundMessage() {
    let agent = TriageAgent()
    #expect(agent.wakesFor(msg("m1"), context: ctx()) == true)
}

@Test func doesNotWakeForMessagesFromTheUser() {
    let agent = TriageAgent()
    #expect(agent.wakesFor(msg("m2", isFromUser: true), context: ctx()) == false)
}

@Test func doesNotWakeForAlreadyTriagedMessages() {
    let agent = TriageAgent()
    let triaged = msg("m3", labels: ["Senani/Category/Lead"])
    #expect(agent.wakesFor(triaged, context: ctx()) == false)
}

@Test func emitsCategoryAndPriorityLabelActions() async throws {
    let gen = FakeTextGenerator(response:
        #"{"category":"Lead","priority":"high","reason":"new prospect asking for a demo"}"#)
    let agent = TriageAgent()
    let actions = try await agent.proposals(for: msg("m1"), context: ctx(), tools: tools(gen))
    #expect(actions == [.label("Senani/Category/Lead"), .label("Senani/Priority/High")])
    #expect(actions.allSatisfy { $0.actionClass == .reversible })
}

@Test func priorityMappingNormalAndLow() async throws {
    let agent = TriageAgent()
    let normal = try await agent.proposals(for: msg("a"), context: ctx(),
        tools: tools(FakeTextGenerator(response:
            #"{"category":"Newsletter","priority":"normal","reason":"weekly digest"}"#)))
    #expect(normal == [.label("Senani/Category/Newsletter"), .label("Senani/Priority/Normal")])

    let low = try await agent.proposals(for: msg("b"), context: ctx(),
        tools: tools(FakeTextGenerator(response:
            #"{"category":"Other","priority":"low","reason":"automated receipt"}"#)))
    #expect(low == [.label("Senani/Category/Other"), .label("Senani/Priority/Low")])
}

@Test func malformedModelOutputFallsBackToOtherNormalLabels() async throws {
    let agent = TriageAgent()
    let actions = try await agent.proposals(for: msg("m1"), context: ctx(),
        tools: tools(FakeTextGenerator(response: "I cannot comply </think>")))
    #expect(actions == [.label("Senani/Category/Other"), .label("Senani/Priority/Normal")])
}

@Test func unknownCategoryFromModelMapsToOtherLabel() async throws {
    let agent = TriageAgent()
    let actions = try await agent.proposals(for: msg("m1"), context: ctx(),
        tools: tools(FakeTextGenerator(response:
            #"{"category":"Invoice","priority":"high","reason":"?"}"#)))
    #expect(actions == [.label("Senani/Category/Other"), .label("Senani/Priority/High")])
}

@Test func promptIncludesMessageSignalsAndPolicy() async throws {
    let gen = FakeTextGenerator(response: #"{"category":"Other","priority":"normal","reason":""}"#)
    let agent = TriageAgent()
    let m = msg("m1", from: "ceo@bigco.com", subject: "Partnership proposal", body: "Let's talk numbers.")
    _ = try await agent.proposals(for: m, context: ctx(), tools: tools(gen))
    let prompt = try #require(gen.lastPrompt)
    #expect(prompt.contains("ceo@bigco.com"))
    #expect(prompt.contains("Partnership proposal"))
    #expect(prompt.contains("Let's talk numbers."))
    // policy lists every category + priority enum value
    for c in TriageCategory.allCases { #expect(prompt.contains(c.rawValue.capitalized)) }
    for p in TriagePriority.allCases { #expect(prompt.contains(p.rawValue)) }
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniEngine && swift test --filter TriageAgentTests
```

Expected: failure — `TriageAgent` undefined.

- [ ] **Step 3: Implement `TriageAgent`**

Create `Sources/SenaniEngine/Agents/TriageAgent.swift`:

```swift
import Foundation
import SenaniRules

/// Phase-1 Triage agent (ROADMAP Phase 1). Classifies every unprocessed inbound
/// message into a category + priority via the injected TextGenerator and emits two
/// reversible `proposeLabel` Actions. Pure: the only I/O is tools.generateJSON.
public struct TriageAgent: Agent {
    public init() {}

    public var id: String { "triage" }

    /// Label proposals are reversible, so the Orchestrator may auto-apply them.
    /// (ARCHITECTURE: reversible, internal actions can auto-run.)
    public var autonomy: Autonomy { .auto }

    private static let categoryLabelPrefix = "Senani/Category/"

    /// Wakes for every unprocessed INBOUND message: not authored by the user, and
    /// not already carrying a Senani category label.
    public func wakesFor(_ message: Message, context: AgentContext) -> Bool {
        if message.isFromUser { return false }
        if message.labels.contains(where: { $0.hasPrefix(Self.categoryLabelPrefix) }) { return false }
        return true
    }

    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        let prompt = Self.buildPrompt(for: message)
        let raw = try await tools.generateJSON(prompt: prompt, schema: TriageClassification.schema)
        let classification = TriageClassification.parse(raw)
        return [
            tools.proposeLabel(classification.category.label, on: message),
            tools.proposeLabel(classification.priority.label, on: message),
        ]
    }

    /// Deterministic prompt: fixed policy/system instruction + the message signals.
    /// Body is truncated to a snippet to keep the prompt small for the on-device model.
    static func buildPrompt(for message: Message) -> String {
        let categories = TriageCategory.allCases.map { $0.rawValue.capitalized }.joined(separator: ", ")
        let priorities = TriagePriority.allCases.map { $0.rawValue }.joined(separator: ", ")
        let snippet = String(message.body.prefix(600))
        return """
        You are Senani's email triage classifier. Classify ONE email.
        Reply with ONLY a JSON object: {"category": <one of: \(categories)>, \
        "priority": <one of: \(priorities)>, "reason": <one short sentence>}.
        Choose exactly one category and one priority from the lists. Do not invent values.

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
cd Packages/SenaniEngine && swift test --filter TriageAgentTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: TriageAgent classifies + emits reversible category/priority labels"
```

(Append the standard trailer.)

---

### Task 5: Full suite green + build clean + record the §3 contract addition

**Files:**
- Edit: `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md` (record the `AgentTools.generateJSON` addition)

- [ ] **Step 1: Run the entire suite**

```
cd Packages/SenaniEngine && swift test
```

Expected: ALL tests pass across `TriageAgentTests`, `TriageClassificationTests`, and the `TestSupport` self-test.

- [ ] **Step 2: Build clean (no warnings under strict concurrency)**

```
cd Packages/SenaniEngine && swift build
```

Expected: builds with no errors and no `Sendable`/concurrency warnings. Resolve any before finishing.

- [ ] **Step 3: Record the §3 contract addition**

In `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md`, in the §3 `AgentTools` struct, add the line documenting the generator seam this plan introduced, so the Orchestrator plan and every later agent plan code to it:

```swift
public struct AgentTools: Sendable {
    public func draftReply(to message: Message, body: String) -> Action
    public func proposeLabel(_ label: String, on message: Message) -> Action
    public func archive(_ message: Message) -> Action
    public func markRead(_ message: Message) -> Action
    // Added by the Triage plan: the generator seam so LLM-backed agents stay pure.
    // AgentTools holds `private let generator: any TextGenerator`; the Orchestrator injects it.
    public func generateJSON(prompt: String, schema: JSONSchema) async throws -> String
    // Phase-2+ tools (proposeCalendarHold, etc.) per their owning plans.
}
```

Also note in §3 that the `SenaniEngine` package is **bootstrapped** with `Agent`/`AgentContext`/`AgentTools` by the Triage plan; the Orchestrator plan extends the same package and must NOT redefine these three types.

- [ ] **Step 4: Final commit**

```
cd Packages/SenaniEngine && git add -A && git commit -m "SenaniEngine: Triage agent green; record AgentTools.generateJSON §3 addition"
```

(Append the standard trailer. The docs edit lives at repo root — `git add -A` from the repo root or stage the doc explicitly: `git add ../../docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md`.)

---

## Self-Review

**Scope coverage (brief):**
- **`TriageAgent: SenaniEngine.Agent`** — conforms to the §3 `Agent` (`id`, `autonomy`, `wakesFor`, `proposals`). ✅ (Task 4)
- **Location decision + justification** — co-located in `Packages/SenaniEngine/Sources/SenaniEngine/Agents/` to avoid a package explosion and the cross-package import of a contract type that only lives in SenaniEngine; the Orchestrator (same package, separate plan) holds the agent as its `triage:` parameter. The plan bootstraps the minimal §3 contract because SenaniEngine doesn't exist yet, written so the Orchestrator plan drops in without edits. ✅
- **Classify category + priority via injected `TextGenerator.generateJSON(prompt:schema:)`** — `proposals` calls `tools.generateJSON` with `TriageClassification.schema`. ✅ (Task 4)
- **Strict schema** — `TriageClassification.schema` is an object requiring `category`/`priority`/`reason` strings. HONEST LIMITATION recorded: `SenaniInference.JSONSchema` has **no enum/oneOf** (verified from source), so the schema constrains *shape* only; the enum is enforced in the prompt and re-validated in `parse` with fallback. ✅ (Task 3)
- **Prompt from message (subject/from/body snippet) + fixed policy** — `TriageAgent.buildPrompt` (body truncated to 600 chars). Asserted by `promptIncludesMessageSignalsAndPolicy`. ✅ (Task 4)
- **Parse JSON safely; never crash; fall back to Other/normal** — `TriageClassification.parse` extracts the first balanced JSON object, validates each enum, falls back; covered by malformed/empty/missing/unknown-enum tests. The agent's `proposals` never throws on bad output (it throws only if the generator itself throws — a real I/O failure). ✅ (Tasks 3, 4)
- **Emit `proposeLabel` Actions `Senani/Category/<Cat>`, `Senani/Priority/<Pri>`; reversible → Orchestrator auto-applies per autonomy** — two `.label(...)` Actions, `actionClass == .reversible`, agent `autonomy == .auto`. ✅ (Tasks 3, 4)
- **Category labels route downstream agents** — the label strings are the routing key the Orchestrator's `AgentRegistry.agents(for:)` consumes (separate plan); vocabulary is the closed `TriageCategory`. ✅
- **`wakesFor` = every unprocessed inbound message** — true unless `isFromUser` or already carries a `Senani/Category/` label. ✅ (Task 4)
- **Generator reached via AgentTools/AgentContext, matching §3; flag the minimal addition** — §3 `AgentTools` had no generator accessor; this plan **adds `AgentTools.generateJSON(prompt:schema:)`** (passthrough to an injected `any TextGenerator`) and records it in §3 (Task 5). This is the single contract addition; flagged explicitly. ✅
- **Pure tests with local FakeTextGenerator; right label Actions; malformed→fallback; schema constrains shape; priority mapping; no MLX** — `TestSupport.FakeTextGenerator` (no upstream fake exists, verified); tests cover canned-JSON→labels, malformed→Other/Normal, schema shape, and high/normal/low mapping. No MLX/Gmail/UI anywhere. ✅ (Tasks 2–4)

**Conventions (APP-PLANS-RECONCILIATION §4):** Agent is pure — no store/Gmail/Keychain access; the only I/O is `tools.generateJSON` (the injected seam). macOS 14, Swift 6.0 tools, strict concurrency, Swift Testing. TDD with bite-sized commits and complete code; no placeholders. One safety path preserved — the agent only *proposes* reversible labels; the Orchestrator (separate plan) routes them via `ActionRouter`.

**Contracts exposed (public API added by this plan):**
- `SenaniEngine.Agent`, `AgentContext`, `AgentTools` (bootstrapped §3 contract; `AgentTools.generateJSON` is the flagged addition)
- `TriageCategory` (`.lead/.booking/.proposal/.newsletter/.personal/.other`, `.label`, `.parse`)
- `TriagePriority` (`.high/.normal/.low`, `.label`, `.parse`)
- `TriageClassification` (`schema`, `schemaJSON`, `parse`)
- `TriageAgent` (`init()`, `id`, `autonomy`, `wakesFor`, `proposals`)

**Risks / assumptions to confirm with the human before/while coding:**
1. **`SenaniEngine` bootstrap collision** — this plan creates `Packages/SenaniEngine` and writes `Agent`/`AgentContext`/`AgentTools`. If the Orchestrator plan runs concurrently in another worktree, the two MUST agree on these three files (coordinate via claim-coordination on the `senani-engine` slug). The Orchestrator plan adds `Orchestrator`/`Scheduler`/`AgentRegistry`/`ProcessedOutcome`/`GmailSyncing` and must NOT redefine the three contract types.
2. **`AgentTools.generateJSON` §3 addition** — must be reflected in APP-PLANS-RECONCILIATION §3 in the same commit (Task 5) so the Orchestrator/Reply-Drafter plans code to the same `AgentTools`.
3. **`JSONSchema` has no enum support (confirmed from source)** — if `SenaniInference` later gains enum/`oneOf` constraints, tighten `TriageClassification.schemaJSON` to pin the category/priority values; the `parse` fallback stays as defense-in-depth.
4. **`SenaniStore` dependency for `VectorHit`** — `AgentContext.retrieve` returns `[SenaniStore.VectorHit]` per §3. SenaniEngine's manifest depends on `SenaniStore`. If `SenaniStore` doesn't resolve in this worktree, see Task 1 Step 3's flagged fallback — do not silently fork `VectorHit`.
5. **`autonomy == .auto` for Triage** — this lets the Orchestrator auto-apply category/priority labels (reversible). If the product wants Triage to start in "Suggest" until the user trusts it, change `autonomy` to `.ask`; the agent code is unaffected (the Orchestrator enforces the dial).
