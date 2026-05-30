# SenaniAssistant Chat Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure-Swift, fully unit-tested **logic core** of Senani's conversational Assistant — turn → grammar-constrained tool-call decode → typed `ToolCall` parse → dispatch over the real Action Kernel (reads return store data, reversible writes execute with an Undo token, outbound writes queue for approval, rule authoring returns a draft + inline simulation, saved only on a follow-up confirm) — driven entirely by a `FakeTextGenerator` so it compiles and passes tests with no MLX, Gmail, or SwiftUI.

**Architecture:** A standalone Swift Package (`SenaniAssistant`) that depends on the already-built-and-tested `SenaniRules` (Action Kernel, `ActionRouter`, `ActionExecutor`, `RuleEngine`, `Simulator`, `ApprovalQueue`, `AuditLog`) and on the assumed sibling packages `SenaniStore` (`MessageStore`/`RuleStore`/`SenaniDatabase`) and `SenaniInference` (`TextGenerator.generateJSON(prompt:schema:)`, `JSONSchema`, `FakeTextGenerator`). The Assistant never invents a second safety path: it reuses the kernel's `ActionRouter` so a chat-triggered action obeys the exact same routing as a rule-triggered one — but because the built `ActionExecutor.execute(match:)` only accepts a `RuleMatch` (hard-coding `Trigger.rule`), chat writes go through a thin `ChatActionDispatcher` that calls `ActionRouter.route` and the same `MailBackend`/`ApprovalQueue`/`AuditLog` seams with `Trigger.chat(turnId:)`. Rule authoring produces an unsaved draft `Rule`, runs the real `Simulator` over `context.recentMessages`, and defers `RuleStore.save` to an explicit `confirmRule` turn.

**Tech Stack:** Swift 6.2 (strict concurrency, `swift-tools-version: 6.0`), Swift Package Manager, Swift Testing (`import Testing`, ships with the toolchain). Target platform macOS 14. No MLX, no Gmail, no UI in this package.

**Working directory:** All `swift` commands run from `Packages/SenaniAssistant/` unless stated otherwise.

**Design spec:** `docs/superpowers/specs/2026-05-31-rules-engine-and-chat-assistant-design.md` — this plan implements **§5 The Assistant** (conversational control surface). The SwiftUI Assistant panel (⌘K right-side chat) and the cockpit Approval/Activity UI are explicitly a **SEPARATE later plan** (the foundation app-shell track); this package is the headless logic core only.

**Out of scope (separate plans):** SwiftUI Assistant panel + Approval queue UI; the real Gemma `TextGenerator`/`PredicateEvaluator` (MLX); the real Gmail `MailBackend`; scoped vector retrieval (here `AssistantContext` is pre-populated by the caller). Document pipeline, Voice Profile, Reply Zero, and Analytics are their own specs/plans.

---

## Cross-package assumptions (state these to the human before coding)

This package compiles only against contracts the sibling packages must expose. The plan codes to these exact signatures; if a sibling differs, adjust the adapter, not the dispatch logic.

- **`SenaniRules` (built + tested, do NOT edit):** `Message`, `Action`, `ActionClass`, `Rule`, `Conditions`, `MatchMode`, `StructuredCondition`, `Autonomy`, `RunOn`, `Outcome`, `Trigger` (`.rule(id:)` / `.chat(turnId:)`), `ActionRouter.route(_:autonomy:) -> Outcome`, `MailBackend`, `ApprovalQueue` (actor: `enqueue(_:)`, `pending()`), `Proposal(action:message:trigger:)`, `ActionRecord(action:messageId:trigger:outcome:)`, `AuditLog.record(_:) async`, `InMemoryAuditLog`, `ActionExecutor`, `RuleMatch(rule:message:)`, `RuleEngine(evaluator:)`, `Simulator(engine:)`, `SimulationResult` (`items`, `count(of:)`), `PredicateEvaluator`.
  - **Key consequence:** `ActionExecutor.execute(match:)` hard-codes `Trigger.rule(id:)`, so it **cannot** carry a `.chat(turnId:)` trigger. The Assistant therefore dispatches chat writes through its own `ChatActionDispatcher` reusing `ActionRouter` + the same seams. This is intentional reuse of the *routing*, not a second safety path.
- **`SenaniInference` (assumed):**
  - `protocol TextGenerator: Sendable { func generateJSON(prompt: String, schema: JSONSchema) async throws -> String }`
  - `struct JSONSchema` constructible from a JSON-schema string/value (we only need to *hold and pass* it; we do not parse it). Assumed initializer: `JSONSchema(json: String)`.
  - `struct FakeTextGenerator: TextGenerator` returning canned JSON. **Assumed API:** `FakeTextGenerator(responses: [String])` dequeuing one response per `generateJSON` call (FIFO), and/or `FakeTextGenerator(response: String)` for a single fixed reply, plus a way to record the last prompt it was asked: `var lastPrompt: String?` (or `recordedPrompts: [String]`). The memory test depends on inspecting the prompt the generator received. **If `FakeTextGenerator` cannot expose the received prompt, wrap it in a local `PromptRecordingGenerator` test double** (Task 9 fallback) — do not edit `SenaniInference`.
- **`SenaniStore` (assumed):**
  - `final class SenaniDatabase` (or actor) with migrations including a `chat_sessions` table; constructible in-memory for tests. **Assumed API:** `SenaniDatabase.inMemory()` (or `SenaniDatabase(path: ":memory:")`).
  - `RuleStore`: CRUD over `Rule` — `save(_:) async throws`, `fetch(id:) async throws -> Rule?`, `all() async throws -> [Rule]`, `enabled() async throws -> [Rule]`, `delete(id:) async throws`.
  - **`MessageStore` (the read API we assume — flag this explicitly to the human):** a query surface over the messages table returning `SenaniRules.Message`. We assume:
    ```swift
    protocol MessageStore: Sendable {
        func query(_ filter: MessageFilter) async throws -> [Message]
        func thread(id: String) async throws -> [Message]
        func needsReply() async throws -> [Message]
    }
    ```
    where `MessageFilter` is a lightweight struct (e.g. `from`, `domain`, `subjectContains`, `hasAttachment`, `unreadOnly`, `limit`). **If `SenaniStore` exposes a differently-named read API, write a thin adapter conforming to a local `MessageReading` protocol** (defined in this package, Task 5) so the controller depends on our protocol and the adapter bridges to the store. This keeps the Assistant testable with an in-memory fake and insulated from the store's exact shape.
  - To avoid a hard compile dependency on `MessageStore`'s exact name, **this package defines its own minimal `MessageReading` and `RuleWriting` protocols** (Task 5) and ships in-memory fakes for tests; production wiring (a separate plan) provides adapters from `SenaniStore` to these protocols.

---

## File Structure

```
Packages/SenaniAssistant/
  Package.swift
  Sources/SenaniAssistant/
    AssistantTool.swift        # AssistantTool enum (the 7 callable tools) + ToolSchema (JSONSchema for constrained decoding)
    ToolCall.swift             # typed ToolCall + ToolCallParseError + parse(json:) -> [ToolCall] (safe, never crashes)
    AssistantContext.swift     # AssistantContext input struct (selection/thread, visible inbox, rules, recentMessages, accountEmail)
    AssistantResponse.swift    # AssistantResponse + payload types (ReadResult, UndoToken, draftRule+simulation, pendingApprovals)
    StorePorts.swift           # MessageReading + RuleWriting protocols (this package's seams) + in-memory fakes (test target reuses)
    ChatActionDispatcher.swift # routes [Action] for a chat turn via ActionRouter + MailBackend/ApprovalQueue/AuditLog (Trigger.chat)
    ChatSessionStore.swift     # persists/loads turns + rolling summary to chat_sessions (SenaniDatabase)
    PromptBuilder.swift        # builds the Gemma prompt from turn + context + prior-summary (memory threading)
    AssistantController.swift  # handle(turn:context:) -> AssistantResponse : generate -> parse -> dispatch
  Tests/SenaniAssistantTests/
    ToolSchemaTests.swift
    ToolCallParsingTests.swift
    ChatActionDispatcherTests.swift
    AssistantControllerReadTests.swift
    AssistantControllerWriteTests.swift
    AssistantControllerRuleTests.swift
    ChatSessionStoreTests.swift
    PromptMemoryTests.swift
    TestSupport.swift          # SpyMailBackend, in-memory store fakes, canned-JSON helpers, PromptRecordingGenerator
```

Each file has one responsibility; collaborators that change together live together. The controller depends only on protocols (`TextGenerator`, `MessageReading`, `RuleWriting`, `MailBackend`, `AuditLog`) plus the concrete `ApprovalQueue` actor and the pure `Simulator`/`RuleEngine`/`ActionRouter` from `SenaniRules`.

---

### Task 1: Package scaffold + path dependencies

**Files:**
- Create: `Packages/SenaniAssistant/Package.swift`
- Create: `Packages/SenaniAssistant/Sources/SenaniAssistant/AssistantTool.swift` (temporary one-line marker so the target compiles)
- Test: `Packages/SenaniAssistant/Tests/SenaniAssistantTests/ToolSchemaTests.swift` (placeholder import-only test)

- [ ] **Step 1: Write a failing import test**

Create `Packages/SenaniAssistant/Tests/SenaniAssistantTests/ToolSchemaTests.swift`:

```swift
import Testing
@testable import SenaniAssistant
import SenaniRules

@Test func packageImportsCompile() {
    // Proves the package builds and links SenaniRules.
    let action: SenaniRules.Action = .archive
    #expect(action.actionClass == .reversible)
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniAssistant && swift test
```

Expected: failure — no `Package.swift` / no `SenaniAssistant` target (`error: no such module` / manifest not found).

- [ ] **Step 3: Create the manifest with path deps**

Create `Packages/SenaniAssistant/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniAssistant",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniAssistant", targets: ["SenaniAssistant"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
        .package(path: "../SenaniStore"),
        .package(path: "../SenaniInference"),
    ],
    targets: [
        .target(
            name: "SenaniAssistant",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "SenaniStore", package: "SenaniStore"),
                .product(name: "SenaniInference", package: "SenaniInference"),
            ]
        ),
        .testTarget(
            name: "SenaniAssistantTests",
            dependencies: ["SenaniAssistant"]
        ),
    ]
)
```

Create `Packages/SenaniAssistant/Sources/SenaniAssistant/AssistantTool.swift` with a single line so the target is non-empty:

```swift
// SenaniAssistant — conversational logic core. Tools defined in Task 2.
import SenaniRules
```

> **Note for the worker:** sibling packages `../SenaniStore` and `../SenaniInference` may not exist yet in this worktree. If `swift test` fails to *resolve* those path dependencies (not a code error), this is a blocking external prerequisite — record it and coordinate; do NOT stub the sibling packages inside this repo. The remaining tasks assume resolution succeeds.

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniAssistant && swift test
```

Expected: 1 test passes.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniAssistant && git add -A && git commit -m "SenaniAssistant: package scaffold with SenaniRules/Store/Inference path deps"
```

Use this commit trailer on EVERY commit in this plan:

```

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
```

---

### Task 2: AssistantTool enum + ToolSchema

**Files:**
- Edit: `Packages/SenaniAssistant/Sources/SenaniAssistant/AssistantTool.swift`
- Test: `Packages/SenaniAssistant/Tests/SenaniAssistantTests/ToolSchemaTests.swift`

The seven tools (spec §5.1): READ (no approval) — `queryInbox`, `summarizeThread`, `listNeedsReply`; WRITE (Action Kernel) — `applyActions`; RULE — `authorRule`, `editRule`, `simulateRule`. (A follow-up `confirmRule` save is handled as a WRITE-class control turn, see Task 8 — it is NOT a generator-emitted tool; it is an explicit user/UI confirmation carrying the previously-returned draft.)

- [ ] **Step 1: Replace the placeholder test with a real failing test**

Replace `ToolSchemaTests.swift`:

```swift
import Testing
@testable import SenaniAssistant
import SenaniRules

@Test func toolNamesAreStableWireStrings() {
    #expect(AssistantTool.queryInbox.wireName == "queryInbox")
    #expect(AssistantTool.summarizeThread.wireName == "summarizeThread")
    #expect(AssistantTool.listNeedsReply.wireName == "listNeedsReply")
    #expect(AssistantTool.applyActions.wireName == "applyActions")
    #expect(AssistantTool.authorRule.wireName == "authorRule")
    #expect(AssistantTool.editRule.wireName == "editRule")
    #expect(AssistantTool.simulateRule.wireName == "simulateRule")
}

@Test func readToolsRequireNoApproval() {
    #expect(AssistantTool.queryInbox.isReadOnly == true)
    #expect(AssistantTool.applyActions.isReadOnly == false)
}

@Test func toolSchemaListsEveryToolName() {
    let schema = ToolSchema.json   // the raw JSON-schema string for constrained decoding
    for tool in AssistantTool.allCases {
        #expect(schema.contains("\"\(tool.wireName)\""))
    }
    #expect(ToolSchema.schema is JSONSchema)   // wrapped JSONSchema is constructible
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniAssistant && swift test --filter ToolSchemaTests
```

Expected: failure — `AssistantTool`/`ToolSchema` not defined.

- [ ] **Step 3: Implement `AssistantTool` + `ToolSchema`**

Replace `Sources/SenaniAssistant/AssistantTool.swift`:

```swift
import SenaniRules
import SenaniInference

/// The fixed set of tools the Assistant can call. Grammar-constrained decoding
/// guarantees the model can only emit one of these (spec §5.3).
public enum AssistantTool: String, CaseIterable, Sendable {
    // READ — no approval, returns data only.
    case queryInbox
    case summarizeThread
    case listNeedsReply
    // WRITE — Action Kernel; routed via ChatActionDispatcher.
    case applyActions
    // RULE — author/edit produce a DRAFT + simulation; simulate is read-only dry-run.
    case authorRule
    case editRule
    case simulateRule

    public var wireName: String { rawValue }

    public var isReadOnly: Bool {
        switch self {
        case .queryInbox, .summarizeThread, .listNeedsReply, .simulateRule:
            return true
        case .applyActions, .authorRule, .editRule:
            return false
        }
    }
}

/// The JSON schema describing the tool-call envelope for constrained decoding.
/// We hold the schema string and wrap it as a SenaniInference.JSONSchema; we do
/// not parse it here — the generator enforces it.
public enum ToolSchema {
    /// Top-level shape the generator must emit:
    /// { "tool_calls": [ { "tool": <enum>, "arguments": { ... } } ] }
    public static let json: String = """
    {
      "type": "object",
      "properties": {
        "tool_calls": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "tool": { "type": "string", "enum": ["queryInbox","summarizeThread","listNeedsReply","applyActions","authorRule","editRule","simulateRule"] },
              "arguments": { "type": "object" }
            },
            "required": ["tool","arguments"]
          }
        },
        "reply": { "type": "string" }
      },
      "required": ["tool_calls"]
    }
    """

    public static let schema = JSONSchema(json: json)
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniAssistant && swift test --filter ToolSchemaTests
```

Expected: all pass. (If `JSONSchema` has a different initializer than `JSONSchema(json:)`, adjust `ToolSchema.schema` to match the real `SenaniInference` API — this is the only line coupled to it.)

- [ ] **Step 5: Commit**

```
cd Packages/SenaniAssistant && git add -A && git commit -m "SenaniAssistant: AssistantTool enum + ToolSchema JSON for constrained decoding"
```

(Append the standard trailer.)

---

### Task 3: ToolCall parsing (typed + safe-on-malformed)

**Files:**
- Create: `Packages/SenaniAssistant/Sources/SenaniAssistant/ToolCall.swift`
- Test: `Packages/SenaniAssistant/Tests/SenaniAssistantTests/ToolCallParsingTests.swift`

`ToolCall` is a typed representation of one decoded call with the arguments each tool needs. Parsing must NEVER crash on malformed JSON — it returns a `ToolCallParseError`.

Argument shapes (the worker codes exactly these):
- `queryInbox(filter: InboxFilter)` — `InboxFilter { from:String?, domain:String?, subjectContains:String?, hasAttachment:Bool?, unreadOnly:Bool?, limit:Int? }`
- `summarizeThread(threadId: String)`
- `listNeedsReply` — no args
- `applyActions(messageIds: [String], actions: [Action])` — actions decoded from a small JSON form (see below)
- `authorRule(spec: RuleSpec)` — `RuleSpec` is the plain-English/structured intent the model emits (name, mode, structured conditions, optional aiPredicate, actions, autonomy, runOn)
- `editRule(id: String, changes: RuleChanges)`
- `simulateRule(rule: RuleSpec)`

Action wire form (maps to `SenaniRules.Action`): `{ "type": "label", "value": "Invoices" }`, `{ "type": "archive" }`, `{ "type": "reply", "body": "..." }`, `{ "type": "forward", "to": "x@y", "body": "..." }`, `{ "type": "draft", "body": "..." }`, `{ "type": "send", "body": "..." }`, `{ "type": "markRead" }`, `{ "type": "markSpam" }`, `{ "type": "flagNeedsReply" }`, etc. — cover all `Action` cases.

- [ ] **Step 1: Write failing parse tests**

Create `Packages/SenaniAssistant/Tests/SenaniAssistantTests/ToolCallParsingTests.swift`:

```swift
import Testing
@testable import SenaniAssistant
import SenaniRules

@Test func parsesQueryInbox() throws {
    let json = #"{ "tool_calls": [ { "tool": "queryInbox", "arguments": { "domain": "notion.so", "limit": 20 } } ] }"#
    let calls = try ToolCall.parse(json: json)
    #expect(calls.count == 1)
    guard case let .queryInbox(filter) = calls[0] else { Issue.record("wrong case"); return }
    #expect(filter.domain == "notion.so")
    #expect(filter.limit == 20)
}

@Test func parsesSummarizeThreadAndNeedsReply() throws {
    let json = #"{ "tool_calls": [ { "tool": "summarizeThread", "arguments": { "threadId": "t1" } }, { "tool": "listNeedsReply", "arguments": {} } ] }"#
    let calls = try ToolCall.parse(json: json)
    #expect(calls.count == 2)
    guard case let .summarizeThread(threadId) = calls[0] else { Issue.record("wrong"); return }
    #expect(threadId == "t1")
    guard case .listNeedsReply = calls[1] else { Issue.record("wrong"); return }
}

@Test func parsesApplyActionsWithKernelActions() throws {
    let json = #"""
    { "tool_calls": [ { "tool": "applyActions", "arguments": {
        "messageIds": ["m1","m2"],
        "actions": [ { "type": "label", "value": "Invoices" }, { "type": "reply", "body": "Thanks!" } ]
    } } ] }
    """#
    let calls = try ToolCall.parse(json: json)
    guard case let .applyActions(messageIds, actions) = calls[0] else { Issue.record("wrong"); return }
    #expect(messageIds == ["m1","m2"])
    #expect(actions == [.label("Invoices"), .reply(body: "Thanks!")])
}

@Test func parsesAuthorRuleSpec() throws {
    let json = #"""
    { "tool_calls": [ { "tool": "authorRule", "arguments": { "spec": {
        "name": "Invoices",
        "mode": "all",
        "structured": [ { "type": "subjectContains", "value": "invoice" }, { "type": "hasAttachment" } ],
        "aiPredicate": "is an overdue invoice",
        "actions": [ { "type": "label", "value": "Invoices" }, { "type": "flagNeedsReply" } ],
        "autonomy": "ask",
        "runOn": "both"
    } } } ] }
    """#
    let calls = try ToolCall.parse(json: json)
    guard case let .authorRule(spec) = calls[0] else { Issue.record("wrong"); return }
    #expect(spec.name == "Invoices")
    #expect(spec.aiPredicate == "is an overdue invoice")
    #expect(spec.autonomy == .ask)
}

@Test func malformedJsonReturnsErrorNeverCrashes() {
    #expect(throws: ToolCallParseError.self) {
        _ = try ToolCall.parse(json: "{ this is not json")
    }
    #expect(throws: ToolCallParseError.self) {
        _ = try ToolCall.parse(json: #"{ "tool_calls": [ { "tool": "noSuchTool", "arguments": {} } ] }"#)
    }
    #expect(throws: ToolCallParseError.self) {
        _ = try ToolCall.parse(json: #"{ "tool_calls": [ { "tool": "summarizeThread", "arguments": {} } ] }"#) // missing threadId
    }
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniAssistant && swift test --filter ToolCallParsingTests
```

Expected: failure — `ToolCall`/`ToolCallParseError` undefined.

- [ ] **Step 3: Implement `ToolCall` + decoders**

Create `Packages/SenaniAssistant/Sources/SenaniAssistant/ToolCall.swift`. Implement:
- `public struct InboxFilter: Sendable, Equatable, Codable` (all optional fields above).
- `public struct RuleSpec: Sendable, Equatable` and `public struct RuleChanges: Sendable, Equatable` (fields the model can set: name, enabled, mode, structured, aiPredicate, actions, autonomy, runOn — all optional in `RuleChanges`).
- `public enum ToolCall: Sendable, Equatable` with the seven cases above carrying typed payloads.
- `public enum ToolCallParseError: Error, Equatable { case invalidJSON, unknownTool(String), missingArgument(tool: String, name: String), invalidAction(String), invalidEnum(field: String, value: String) }`.
- `public static func parse(json: String) throws -> [ToolCall]` — decode the envelope with `Foundation.JSONSerialization` (or a `Decodable` envelope), iterate `tool_calls`, map each `tool` string to `AssistantTool` (unknown → `.unknownTool`), then decode arguments per tool. Use a private `decodeAction(_:) throws -> Action` and `decodeStructured(_:) throws -> StructuredCondition` mapping every wire `"type"` to its kernel case; unknown type → `.invalidAction`. Map autonomy/mode/runOn strings to the `SenaniRules` enums (`Autonomy(rawValue:)`, `MatchMode`, `RunOn`); unknown → `.invalidEnum`. Wrap any JSON failure as `.invalidJSON`. **Never force-unwrap; never `try!`.**

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniAssistant && swift test --filter ToolCallParsingTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniAssistant && git add -A && git commit -m "SenaniAssistant: typed ToolCall parsing with safe-on-malformed errors"
```

(Append the standard trailer.)

---

### Task 4: AssistantContext + AssistantResponse

**Files:**
- Create: `Packages/SenaniAssistant/Sources/SenaniAssistant/AssistantContext.swift`
- Create: `Packages/SenaniAssistant/Sources/SenaniAssistant/AssistantResponse.swift`
- Test: `Packages/SenaniAssistant/Tests/SenaniAssistantTests/ToolSchemaTests.swift` (add a small construction test) — or a new `ResponseTypesTests.swift`

- [ ] **Step 1: Write a failing construction test**

Create `Packages/SenaniAssistant/Tests/SenaniAssistantTests/ResponseTypesTests.swift`:

```swift
import Testing
@testable import SenaniAssistant
import SenaniRules
import Foundation

@Test func contextHoldsTheAssistantsViewOfTheWorld() {
    let msg = Message(id: "m1", from: "a@b.com", to: ["me@x.com"], subject: "Hi", body: "?",
                      hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
                      threadId: "t1", date: Date(), isFromUser: false)
    let ctx = AssistantContext(currentThread: [msg], visibleMessages: [msg], rules: [],
                               recentMessages: [msg], accountEmail: "me@x.com",
                               priorSummary: "earlier we labeled invoices")
    #expect(ctx.visibleMessages.count == 1)
    #expect(ctx.priorSummary == "earlier we labeled invoices")
}

@Test func responsePayloadCarriesUndoTokensAndPendingApprovals() {
    let resp = AssistantResponse(
        reply: "Archived 2, queued 1 reply.",
        reads: [],
        undoTokens: [UndoToken(action: .archive, messageId: "m1")],
        pendingApprovals: [PendingApproval(action: .reply(body: "Hi"), messageId: "m2")],
        ruleProposal: nil,
        simulation: nil)
    #expect(resp.undoTokens.count == 1)
    #expect(resp.pendingApprovals.first?.messageId == "m2")
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniAssistant && swift test --filter ResponseTypesTests
```

Expected: failure — types undefined.

- [ ] **Step 3: Implement the context + response types**

Create `Sources/SenaniAssistant/AssistantContext.swift`:

```swift
import SenaniRules

/// Everything the Assistant is allowed to see for one turn (spec §5.2).
/// The caller (UI / orchestrator) pre-populates this via scoped retrieval —
/// the Assistant never reads the whole mailbox blindly.
public struct AssistantContext: Sendable {
    public var currentThread: [Message]?
    public var visibleMessages: [Message]
    public var rules: [Rule]
    public var recentMessages: [Message]   // corpus the Simulator dry-runs over
    public var accountEmail: String
    public var priorSummary: String?       // rolling conversation memory (Task 7/9)

    public init(currentThread: [Message]?, visibleMessages: [Message], rules: [Rule],
                recentMessages: [Message], accountEmail: String, priorSummary: String? = nil) {
        self.currentThread = currentThread
        self.visibleMessages = visibleMessages
        self.rules = rules
        self.recentMessages = recentMessages
        self.accountEmail = accountEmail
        self.priorSummary = priorSummary
    }
}
```

Create `Sources/SenaniAssistant/AssistantResponse.swift`:

```swift
import SenaniRules

/// Data returned by a read tool (no approval). One per executed read call.
public struct ReadResult: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case inbox, thread, needsReply }
    public let kind: Kind
    public let messages: [Message]
    public init(kind: Kind, messages: [Message]) { self.kind = kind; self.messages = messages }
}

/// A reversible chat action that executed immediately; the UI can offer inline Undo.
public struct UndoToken: Sendable, Equatable {
    public let action: Action
    public let messageId: String
    public init(action: Action, messageId: String) { self.action = action; self.messageId = messageId }
}

/// An outbound/irreversible chat action routed to the Approval queue (not applied).
public struct PendingApproval: Sendable, Equatable {
    public let action: Action
    public let messageId: String
    public init(action: Action, messageId: String) { self.action = action; self.messageId = messageId }
}

/// A draft rule the user must approve before it is saved (spec §5.1 job 3).
public struct RuleProposal: Sendable, Equatable {
    public let draft: Rule
    public init(draft: Rule) { self.draft = draft }
}

/// The structured result of one Assistant turn.
public struct AssistantResponse: Sendable {
    public var reply: String
    public var reads: [ReadResult]
    public var undoTokens: [UndoToken]
    public var pendingApprovals: [PendingApproval]
    public var ruleProposal: RuleProposal?
    public var simulation: SimulationResult?

    public init(reply: String, reads: [ReadResult] = [], undoTokens: [UndoToken] = [],
                pendingApprovals: [PendingApproval] = [], ruleProposal: RuleProposal? = nil,
                simulation: SimulationResult? = nil) {
        self.reply = reply
        self.reads = reads
        self.undoTokens = undoTokens
        self.pendingApprovals = pendingApprovals
        self.ruleProposal = ruleProposal
        self.simulation = simulation
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniAssistant && swift test --filter ResponseTypesTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniAssistant && git add -A && git commit -m "SenaniAssistant: AssistantContext + AssistantResponse payload types"
```

(Append the standard trailer.)

---

### Task 5: Store ports + in-memory fakes (test support)

**Files:**
- Create: `Packages/SenaniAssistant/Sources/SenaniAssistant/StorePorts.swift`
- Create: `Packages/SenaniAssistant/Tests/SenaniAssistantTests/TestSupport.swift`

Define the package's own seams so the controller never hard-depends on the store's exact API; production adapters (separate plan) bridge `SenaniStore` to these.

- [ ] **Step 1: Write a failing fakes test**

Add to a new `Packages/SenaniAssistant/Tests/SenaniAssistantTests/TestSupport.swift` BOTH the doubles and a self-test:

```swift
import Testing
import Foundation
@testable import SenaniAssistant
import SenaniRules

// ---- Test doubles ----

final class FakeMessageStore: MessageReading, @unchecked Sendable {
    var inbox: [Message] = []
    var threads: [String: [Message]] = [:]
    var needs: [Message] = []
    func query(_ filter: InboxFilter) async throws -> [Message] { inbox }
    func thread(id: String) async throws -> [Message] { threads[id] ?? [] }
    func needsReply() async throws -> [Message] { needs }
}

actor FakeRuleStore: RuleWriting {
    private(set) var saved: [Rule] = []
    var byId: [String: Rule] = [:]
    func save(_ rule: Rule) async throws { saved.append(rule); byId[rule.id] = rule }
    func fetch(id: String) async throws -> Rule? { byId[id] }
    func savedCount() -> Int { saved.count }
}

final class SpyMailBackend: MailBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _applied: [(Action, String)] = []
    func apply(_ action: Action, to message: Message) async throws {
        lock.lock(); _applied.append((action, message.id)); lock.unlock()
    }
    var applied: [(Action, String)] { lock.lock(); defer { lock.unlock() }; return _applied }
}

func msg(_ id: String, from: String = "a@b.com", threadId: String = "t1") -> Message {
    Message(id: id, from: from, to: ["me@x.com"], subject: "S", body: "B",
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: threadId, date: Date(), isFromUser: false)
}

// ---- self-test ----

@Test func fakeStoresRoundTrip() async throws {
    let ms = FakeMessageStore(); ms.inbox = [msg("m1")]
    #expect(try await ms.query(InboxFilter()).count == 1)
    let rs = FakeRuleStore()
    try await rs.save(Rule(id: "r1", name: "n", enabled: true,
        conditions: Conditions(mode: .all, structured: [], aiPredicate: nil),
        actions: [.archive], autonomy: .ask, runOn: .both))
    #expect(await rs.savedCount() == 1)
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniAssistant && swift test --filter fakeStoresRoundTrip
```

Expected: failure — `MessageReading`/`RuleWriting`/`InboxFilter` (already from Task 3) ports undefined.

- [ ] **Step 3: Implement the ports**

Create `Sources/SenaniAssistant/StorePorts.swift`:

```swift
import SenaniRules

/// Read seam the Assistant uses for inbox Q&A. A production adapter bridges
/// SenaniStore's MessageStore to this protocol (assumption documented in the plan header).
public protocol MessageReading: Sendable {
    func query(_ filter: InboxFilter) async throws -> [Message]
    func thread(id: String) async throws -> [Message]
    func needsReply() async throws -> [Message]
}

/// Write seam for rule authoring. A production adapter bridges SenaniStore's RuleStore.
/// The Assistant saves ONLY on an explicit confirm (spec §5.1 job 3).
public protocol RuleWriting: Sendable {
    func save(_ rule: Rule) async throws
    func fetch(id: String) async throws -> Rule?
}
```

(`InboxFilter` already lives in `ToolCall.swift` from Task 3; reuse it.)

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniAssistant && swift test --filter fakeStoresRoundTrip
```

Expected: pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniAssistant && git add -A && git commit -m "SenaniAssistant: MessageReading/RuleWriting ports + in-memory test doubles"
```

(Append the standard trailer.)

---

### Task 6: ChatActionDispatcher (reuse ActionRouter for chat-triggered writes)

**Files:**
- Create: `Packages/SenaniAssistant/Sources/SenaniAssistant/ChatActionDispatcher.swift`
- Test: `Packages/SenaniAssistant/Tests/SenaniAssistantTests/ChatActionDispatcherTests.swift`

`ActionExecutor.execute(match:)` always tags `Trigger.rule`; chat needs `Trigger.chat(turnId:)`. The dispatcher reuses the kernel's `ActionRouter.route` and the same `MailBackend`/`ApprovalQueue`/`AuditLog` seams — reversible → `backend.apply` + an `UndoToken`; outbound → `approvals.enqueue(Proposal(...))` + a `PendingApproval`; every action audited via `ActionRecord`. Chat writes are treated as autonomy `.auto` (reversible runs now with inline Undo, spec §5.1 job 2), but the kernel still forces outbound to the queue.

- [ ] **Step 1: Write failing dispatch tests**

Create `Packages/SenaniAssistant/Tests/SenaniAssistantTests/ChatActionDispatcherTests.swift`:

```swift
import Testing
@testable import SenaniAssistant
import SenaniRules

@Test func reversibleActionExecutesAndYieldsUndoToken() async throws {
    let backend = SpyMailBackend()
    let approvals = ApprovalQueue()
    let audit = InMemoryAuditLog()
    let dispatcher = ChatActionDispatcher(backend: backend, approvals: approvals, audit: audit)

    let result = try await dispatcher.dispatch(
        actions: [.archive, .label("Invoices")],
        to: [msg("m1")],
        turnId: "turn-1")

    #expect(backend.applied.map(\.0) == [.archive, .label("Invoices")])
    #expect(result.undoTokens.count == 2)
    #expect(await approvals.pending().isEmpty)
}

@Test func outboundActionQueuesAndIsNotApplied() async throws {
    let backend = SpyMailBackend()
    let approvals = ApprovalQueue()
    let audit = InMemoryAuditLog()
    let dispatcher = ChatActionDispatcher(backend: backend, approvals: approvals, audit: audit)

    let result = try await dispatcher.dispatch(
        actions: [.reply(body: "Hi"), .markSpam],
        to: [msg("m2")],
        turnId: "turn-2")

    #expect(backend.applied.isEmpty)                 // outbound never applied
    #expect(result.pendingApprovals.count == 2)
    let pending = await approvals.pending()
    #expect(pending.count == 2)
    #expect(pending.allSatisfy { $0.trigger == .chat(turnId: "turn-2") })
}

@Test func mixedActionsSplitCorrectly() async throws {
    let backend = SpyMailBackend()
    let approvals = ApprovalQueue()
    let audit = InMemoryAuditLog()
    let dispatcher = ChatActionDispatcher(backend: backend, approvals: approvals, audit: audit)
    let result = try await dispatcher.dispatch(
        actions: [.markRead, .send(body: "Done")], to: [msg("m3")], turnId: "t3")
    #expect(result.undoTokens.count == 1)
    #expect(result.pendingApprovals.count == 1)
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniAssistant && swift test --filter ChatActionDispatcherTests
```

Expected: failure — `ChatActionDispatcher` undefined.

- [ ] **Step 3: Implement the dispatcher**

Create `Sources/SenaniAssistant/ChatActionDispatcher.swift`:

```swift
import SenaniRules

/// Routes chat-triggered actions through the SAME kernel routing as rules,
/// but tagged with Trigger.chat(turnId:). Reversible → apply now + Undo token;
/// outbound → Approval queue (kernel safety wins). Every action is audited.
public struct ChatActionDispatcher: Sendable {
    public struct Result: Sendable, Equatable {
        public var undoTokens: [UndoToken]
        public var pendingApprovals: [PendingApproval]
    }

    private let backend: MailBackend
    private let approvals: ApprovalQueue
    private let audit: AuditLog

    public init(backend: MailBackend, approvals: ApprovalQueue, audit: AuditLog) {
        self.backend = backend
        self.approvals = approvals
        self.audit = audit
    }

    /// Applies `actions` to every message in `messages`. Chat uses `.auto`
    /// autonomy so reversible actions run immediately; ActionRouter still forces
    /// outbound/irreversible actions to the approval queue.
    public func dispatch(actions: [Action], to messages: [Message], turnId: String) async throws -> Result {
        let trigger = Trigger.chat(turnId: turnId)
        var undo: [UndoToken] = []
        var pending: [PendingApproval] = []
        for message in messages {
            for action in actions {
                let outcome = ActionRouter.route(action, autonomy: .auto)
                switch outcome {
                case .executed, .prepared:
                    try await backend.apply(action, to: message)
                    undo.append(UndoToken(action: action, messageId: message.id))
                case .queuedForApproval:
                    await approvals.enqueue(Proposal(action: action, message: message, trigger: trigger))
                    pending.append(PendingApproval(action: action, messageId: message.id))
                }
                await audit.record(ActionRecord(
                    action: action, messageId: message.id, trigger: trigger, outcome: outcome))
            }
        }
        return Result(undoTokens: undo, pendingApprovals: pending)
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniAssistant && swift test --filter ChatActionDispatcherTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniAssistant && git add -A && git commit -m "SenaniAssistant: ChatActionDispatcher routes chat writes via ActionRouter with Trigger.chat"
```

(Append the standard trailer.)

---

### Task 7: ChatSessionStore (persist turns + rolling summary)

**Files:**
- Create: `Packages/SenaniAssistant/Sources/SenaniAssistant/ChatSessionStore.swift`
- Test: `Packages/SenaniAssistant/Tests/SenaniAssistantTests/ChatSessionStoreTests.swift`

Persists conversation turns and a rolling summary to the `chat_sessions` table via `SenaniDatabase`. Round-trip test with an in-memory db.

- [ ] **Step 1: Write a failing round-trip test**

Create `Packages/SenaniAssistant/Tests/SenaniAssistantTests/ChatSessionStoreTests.swift`:

```swift
import Testing
@testable import SenaniAssistant
import SenaniStore

@Test func sessionTurnsAndSummaryRoundTrip() async throws {
    let db = try SenaniDatabase.inMemory()
    let store = ChatSessionStore(database: db)
    let sid = "session-1"

    try await store.appendTurn(sessionId: sid, role: .user, text: "what needs me today?")
    try await store.appendTurn(sessionId: sid, role: .assistant, text: "3 threads need a reply.")
    try await store.updateSummary(sessionId: sid, summary: "User asked about needs-reply; 3 pending.")

    let turns = try await store.loadTurns(sessionId: sid)
    #expect(turns.count == 2)
    #expect(turns.first?.role == .user)
    #expect(turns.first?.text == "what needs me today?")

    let summary = try await store.loadSummary(sessionId: sid)
    #expect(summary == "User asked about needs-reply; 3 pending.")
}

@Test func unknownSessionHasNoSummary() async throws {
    let db = try SenaniDatabase.inMemory()
    let store = ChatSessionStore(database: db)
    #expect(try await store.loadSummary(sessionId: "missing") == nil)
    #expect(try await store.loadTurns(sessionId: "missing").isEmpty)
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniAssistant && swift test --filter ChatSessionStoreTests
```

Expected: failure — `ChatSessionStore` undefined. (If `SenaniDatabase.inMemory()` differs, adjust the constructor to the real API and note it.)

- [ ] **Step 3: Implement `ChatSessionStore`**

Create `Sources/SenaniAssistant/ChatSessionStore.swift`. Implement:
- `public enum ChatRole: String, Sendable, Equatable, Codable { case user, assistant }`
- `public struct ChatTurn: Sendable, Equatable { public let role: ChatRole; public let text: String; public let at: Date }`
- `public struct ChatSessionStore: Sendable` taking `init(database: SenaniDatabase)`.
- Methods (all `async throws`): `appendTurn(sessionId:role:text:)`, `loadTurns(sessionId:) -> [ChatTurn]` (chronological), `updateSummary(sessionId:summary:)` (upsert one summary row per session), `loadSummary(sessionId:) -> String?`.
- Persist via `SenaniDatabase`'s query API against the `chat_sessions` table from migrations. **Assumed shape:** a turns row `(session_id, seq, role, text, created_at)` and a summary either as a dedicated `chat_session_summaries(session_id, summary)` row or a `summary` column keyed by session. If the migration's columns differ, adapt the SQL to the existing schema — do NOT add a migration here (that belongs to `SenaniStore`); if a needed column is missing, flag it as a `SenaniStore` prerequisite.

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniAssistant && swift test --filter ChatSessionStoreTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniAssistant && git add -A && git commit -m "SenaniAssistant: ChatSessionStore persists turns + rolling summary to chat_sessions"
```

(Append the standard trailer.)

---

### Task 8: AssistantController — generate → parse → dispatch (reads, writes, rules)

**Files:**
- Create: `Packages/SenaniAssistant/Sources/SenaniAssistant/PromptBuilder.swift`
- Create: `Packages/SenaniAssistant/Sources/SenaniAssistant/AssistantController.swift`
- Tests: `AssistantControllerReadTests.swift`, `AssistantControllerWriteTests.swift`, `AssistantControllerRuleTests.swift`

The controller wires it all together: build the prompt (`PromptBuilder`), call `TextGenerator.generateJSON(prompt:schema: ToolSchema.schema)`, `ToolCall.parse`, then dispatch per tool. `authorRule`/`editRule` build a draft `Rule`, run `Simulator.run` over `context.recentMessages`, and return `RuleProposal` + `SimulationResult` WITHOUT saving. A separate `confirm(rule:)` method (or a `confirmRule` control turn) performs `RuleWriting.save`. `simulateRule` only simulates.

For predicate-bearing draft rules, the `RuleEngine`/`Simulator` need a `PredicateEvaluator`; the controller holds one (injected — in tests a fake returning canned booleans). The real one is Gemma (separate plan).

- [ ] **Step 1: Write failing READ test**

Create `Packages/SenaniAssistant/Tests/SenaniAssistantTests/AssistantControllerReadTests.swift`:

```swift
import Testing
@testable import SenaniAssistant
import SenaniRules
import SenaniInference
import Foundation

private func makeController(
    generator: TextGenerator,
    messages: FakeMessageStore = FakeMessageStore(),
    rules: FakeRuleStore = FakeRuleStore(),
    backend: SpyMailBackend = SpyMailBackend(),
    approvals: ApprovalQueue = ApprovalQueue(),
    audit: InMemoryAuditLog = InMemoryAuditLog(),
    predicates: PredicateEvaluator = AlwaysTrueEvaluator()
) -> AssistantController {
    AssistantController(generator: generator, messages: messages, rules: rules,
                        backend: backend, approvals: approvals, audit: audit,
                        predicateEvaluator: predicates)
}

struct AlwaysTrueEvaluator: PredicateEvaluator {
    func evaluate(predicates: [String], against message: Message) async -> [Bool] {
        predicates.map { _ in true }
    }
}

private func ctx(rules: [Rule] = [], recent: [Message] = []) -> AssistantContext {
    AssistantContext(currentThread: nil, visibleMessages: [], rules: rules,
                     recentMessages: recent, accountEmail: "me@x.com")
}

@Test func readToolReturnsStoreDataNoApproval() async throws {
    let ms = FakeMessageStore(); ms.inbox = [msg("m1"), msg("m2")]
    let gen = FakeTextGenerator(response:
        #"{ "tool_calls": [ { "tool": "queryInbox", "arguments": { "limit": 10 } } ], "reply": "Here are 2." }"#)
    let controller = makeController(generator: gen, messages: ms)
    let resp = try await controller.handle(turn: "show my inbox", context: ctx())
    #expect(resp.reads.count == 1)
    #expect(resp.reads[0].kind == .inbox)
    #expect(resp.reads[0].messages.count == 2)
    #expect(resp.undoTokens.isEmpty)
    #expect(resp.pendingApprovals.isEmpty)
}

@Test func listNeedsReplyReadsNeedsReply() async throws {
    let ms = FakeMessageStore(); ms.needs = [msg("n1")]
    let gen = FakeTextGenerator(response:
        #"{ "tool_calls": [ { "tool": "listNeedsReply", "arguments": {} } ] }"#)
    let controller = makeController(generator: gen, messages: ms)
    let resp = try await controller.handle(turn: "what am I behind on?", context: ctx())
    #expect(resp.reads.first?.kind == .needsReply)
    #expect(resp.reads.first?.messages.count == 1)
}
```

- [ ] **Step 2: Write failing WRITE test**

Create `Packages/SenaniAssistant/Tests/SenaniAssistantTests/AssistantControllerWriteTests.swift`:

```swift
import Testing
@testable import SenaniAssistant
import SenaniRules
import SenaniInference

@Test func reversibleWriteExecutesAndReturnsUndo() async throws {
    let backend = SpyMailBackend()
    let approvals = ApprovalQueue()
    let ms = FakeMessageStore(); ms.inbox = [msg("m1")]
    let gen = FakeTextGenerator(response: #"""
    { "tool_calls": [ { "tool": "applyActions", "arguments": {
        "messageIds": ["m1"], "actions": [ { "type": "archive" } ] } } ] }
    """#)
    let controller = AssistantController(generator: gen, messages: ms, rules: FakeRuleStore(),
        backend: backend, approvals: approvals, audit: InMemoryAuditLog(),
        predicateEvaluator: AlwaysTrueEvaluator())
    let resp = try await controller.handle(turn: "archive m1",
        context: AssistantContext(currentThread: nil, visibleMessages: [msg("m1")], rules: [],
                                  recentMessages: [], accountEmail: "me@x.com"))
    #expect(backend.applied.map(\.0) == [.archive])
    #expect(resp.undoTokens.count == 1)
    #expect(await approvals.pending().isEmpty)
}

@Test func outboundWriteLandsInApprovalQueueNotApplied() async throws {
    let backend = SpyMailBackend()
    let approvals = ApprovalQueue()
    let gen = FakeTextGenerator(response: #"""
    { "tool_calls": [ { "tool": "applyActions", "arguments": {
        "messageIds": ["m2"], "actions": [ { "type": "reply", "body": "Thanks" } ] } } ] }
    """#)
    let controller = AssistantController(generator: gen, messages: FakeMessageStore(), rules: FakeRuleStore(),
        backend: backend, approvals: approvals, audit: InMemoryAuditLog(),
        predicateEvaluator: AlwaysTrueEvaluator())
    let resp = try await controller.handle(turn: "reply to m2",
        context: AssistantContext(currentThread: nil, visibleMessages: [msg("m2")], rules: [],
                                  recentMessages: [], accountEmail: "me@x.com"))
    #expect(backend.applied.isEmpty)
    #expect(resp.pendingApprovals.count == 1)
    #expect(await approvals.pending().count == 1)
}
```

> **Note on message resolution:** `applyActions` carries `messageIds`. The controller resolves each id to a `Message` by looking in `context.visibleMessages` first, then `context.currentThread`, then `MessageReading.query`/`thread`. The WRITE tests above place the target in `visibleMessages`. Implement resolution to prefer context, and skip (or collect into `resp.reply`) ids that cannot be resolved — never crash.

- [ ] **Step 3: Write failing RULE test**

Create `Packages/SenaniAssistant/Tests/SenaniAssistantTests/AssistantControllerRuleTests.swift`:

```swift
import Testing
@testable import SenaniAssistant
import SenaniRules
import SenaniInference

private func recentInvoices() -> [Message] {
    [msg("a", from: "billing@acme.com"), msg("b", from: "noreply@acme.com")]
}

@Test func authorRuleReturnsDraftPlusSimulationAndDoesNotSave() async throws {
    let rs = FakeRuleStore()
    let gen = FakeTextGenerator(response: #"""
    { "tool_calls": [ { "tool": "authorRule", "arguments": { "spec": {
        "name": "Invoices", "mode": "any",
        "structured": [ { "type": "subjectContains", "value": "S" } ],
        "actions": [ { "type": "label", "value": "Invoices" } ],
        "autonomy": "ask", "runOn": "both" } } } ] }
    """#)
    let controller = AssistantController(generator: gen, messages: FakeMessageStore(), rules: rs,
        backend: SpyMailBackend(), approvals: ApprovalQueue(), audit: InMemoryAuditLog(),
        predicateEvaluator: AlwaysTrueEvaluator())
    let resp = try await controller.handle(turn: "make a rule to label invoices",
        context: AssistantContext(currentThread: nil, visibleMessages: [], rules: [],
                                  recentMessages: recentInvoices(), accountEmail: "me@x.com"))
    #expect(resp.ruleProposal != nil)
    #expect(resp.ruleProposal?.draft.name == "Invoices")
    #expect(resp.simulation != nil)
    // structured subjectContains "S" matches both recent msgs -> 2 label outcomes
    #expect(resp.simulation?.items.count == 2)
    #expect(await rs.savedCount() == 0)            // NOT saved until confirm
}

@Test func confirmRulePersistsTheDraft() async throws {
    let rs = FakeRuleStore()
    let controller = AssistantController(generator: FakeTextGenerator(response: "{}"),
        messages: FakeMessageStore(), rules: rs, backend: SpyMailBackend(),
        approvals: ApprovalQueue(), audit: InMemoryAuditLog(),
        predicateEvaluator: AlwaysTrueEvaluator())
    let draft = Rule(id: "r1", name: "Invoices", enabled: true,
        conditions: Conditions(mode: .any, structured: [.subjectContains("S")], aiPredicate: nil),
        actions: [.label("Invoices")], autonomy: .ask, runOn: .both)
    try await controller.confirm(rule: draft)
    #expect(await rs.savedCount() == 1)
}

@Test func simulateRuleReturnsSimulationOnly() async throws {
    let gen = FakeTextGenerator(response: #"""
    { "tool_calls": [ { "tool": "simulateRule", "arguments": { "rule": {
        "name": "All", "mode": "any",
        "structured": [ { "type": "subjectContains", "value": "S" } ],
        "actions": [ { "type": "markRead" } ], "autonomy": "ask", "runOn": "both" } } } ] }
    """#)
    let controller = AssistantController(generator: gen, messages: FakeMessageStore(), rules: FakeRuleStore(),
        backend: SpyMailBackend(), approvals: ApprovalQueue(), audit: InMemoryAuditLog(),
        predicateEvaluator: AlwaysTrueEvaluator())
    let resp = try await controller.handle(turn: "simulate marking read",
        context: AssistantContext(currentThread: nil, visibleMessages: [], rules: [],
                                  recentMessages: recentInvoices(), accountEmail: "me@x.com"))
    #expect(resp.simulation?.count(of: .executed) == 0)   // .ask -> queuedForApproval, not executed
    #expect(resp.simulation?.items.count == 2)
    #expect(resp.ruleProposal == nil)                     // simulate does not propose a save
}
```

- [ ] **Step 4: Run all three to fail**

```
cd Packages/SenaniAssistant && swift test --filter AssistantController
```

Expected: failure — `AssistantController`/`PromptBuilder` undefined.

- [ ] **Step 5: Implement `PromptBuilder`**

Create `Sources/SenaniAssistant/PromptBuilder.swift`:

```swift
import SenaniRules

/// Builds the constrained-decoding prompt from the turn + context, threading in
/// prior-turn memory (spec §5.2). Kept deterministic + inspectable for tests.
public enum PromptBuilder {
    public static func build(turn: String, context: AssistantContext) -> String {
        var parts: [String] = []
        parts.append("You are Senani's on-device assistant. Emit ONLY tool calls per the schema.")
        if let summary = context.priorSummary, !summary.isEmpty {
            parts.append("CONVERSATION SO FAR: \(summary)")
        }
        parts.append("ACCOUNT: \(context.accountEmail)")
        if let thread = context.currentThread, !thread.isEmpty {
            parts.append("CURRENT THREAD: " + thread.map { "\($0.id):\($0.subject)" }.joined(separator: ", "))
        }
        if !context.visibleMessages.isEmpty {
            parts.append("VISIBLE INBOX: " + context.visibleMessages.map { "\($0.id) from \($0.from): \($0.subject)" }.joined(separator: " | "))
        }
        if !context.rules.isEmpty {
            parts.append("YOUR RULES: " + context.rules.map { "\($0.id):\($0.name)" }.joined(separator: ", "))
        }
        parts.append("USER: \(turn)")
        return parts.joined(separator: "\n")
    }
}
```

- [ ] **Step 6: Implement `AssistantController`**

Create `Sources/SenaniAssistant/AssistantController.swift`. Implement:
- `public struct AssistantController: Sendable` with `init(generator: TextGenerator, messages: MessageReading, rules: RuleWriting, backend: MailBackend, approvals: ApprovalQueue, audit: AuditLog, predicateEvaluator: PredicateEvaluator)`.
- It builds a `ChatActionDispatcher`, a `RuleEngine(evaluator: predicateEvaluator)`, and a `Simulator(engine:)` internally.
- `public func handle(turn: String, context: AssistantContext) async throws -> AssistantResponse`:
  1. `let prompt = PromptBuilder.build(turn: turn, context: context)`
  2. `let json = try await generator.generateJSON(prompt: prompt, schema: ToolSchema.schema)`
  3. `let calls = (try? ToolCall.parse(json: json)) ?? []` — a parse failure becomes an empty-call response with an apologetic `reply` (never throw on bad model output).
  4. Accumulate into `AssistantResponse`, dispatching each call:
     - `.queryInbox(filter)` → `reads.append(ReadResult(kind: .inbox, messages: try await messages.query(filter)))`
     - `.summarizeThread(threadId)` → prefer `context.currentThread` if its `threadId` matches, else `messages.thread(id:)`; `reads.append(.init(kind: .thread, messages: ...))`
     - `.listNeedsReply` → `reads.append(.init(kind: .needsReply, messages: try await messages.needsReply()))`
     - `.applyActions(ids, actions)` → resolve ids to `[Message]` (context-first), call `dispatcher.dispatch(actions:to:turnId:)` with a fresh `turnId` (UUID string), merge `undoTokens`/`pendingApprovals`.
     - `.authorRule(spec)` → `let draft = try buildRule(from: spec)` (deterministic id, e.g. UUID; default `autonomy = .ask` if absent — spec §4.2); `let sim = await simulator.run(rules: [draft], over: context.recentMessages, now: Date())`; set `ruleProposal = RuleProposal(draft: draft)` and `simulation = sim`. Do NOT save.
     - `.editRule(id, changes)` → `let base = try await rules.fetch(id: id)` (error/skip if nil); apply `changes` to produce an edited draft; simulate; return proposal + sim; do NOT save.
     - `.simulateRule(rule)` → build a draft `Rule`, simulate over `recentMessages`, set `simulation` only (no `ruleProposal`).
  5. Set `reply` from the model's `reply` field if present, else a short synthesized summary.
- `public func confirm(rule: Rule) async throws { try await rules.save(rule) }` — the explicit save step (spec §5.1 job 3: "saved on a follow-up confirmRule call").
- Private `buildRule(from: RuleSpec) throws -> Rule` and `apply(_ changes: RuleChanges, to: Rule) -> Rule` mapping specs → `SenaniRules.Rule`/`Conditions`.

Note: `handle` is non-`@MainActor`, `Sendable`-clean under strict concurrency (all collaborators are `Sendable`; `ApprovalQueue` is an actor).

- [ ] **Step 7: Run to pass**

```
cd Packages/SenaniAssistant && swift test --filter AssistantController
```

Expected: all read/write/rule tests pass.

- [ ] **Step 8: Commit**

```
cd Packages/SenaniAssistant && git add -A && git commit -m "SenaniAssistant: AssistantController generate->parse->dispatch for reads/writes/rules"
```

(Append the standard trailer.)

---

### Task 9: Conversation memory threaded into the prompt

**Files:**
- Edit (if needed): `Packages/SenaniAssistant/Sources/SenaniAssistant/PromptBuilder.swift` (already supports `priorSummary`)
- Test: `Packages/SenaniAssistant/Tests/SenaniAssistantTests/PromptMemoryTests.swift`
- Test support: add `PromptRecordingGenerator` to `TestSupport.swift` if `FakeTextGenerator` cannot expose the received prompt.

Prove the rolling summary is included in the prompt the generator receives (spec §5.2 memory continuity).

- [ ] **Step 1: Write failing memory test**

Create `Packages/SenaniAssistant/Tests/SenaniAssistantTests/PromptMemoryTests.swift`:

```swift
import Testing
@testable import SenaniAssistant
import SenaniRules
import SenaniInference

/// Records the prompt it was asked, then returns a no-op tool-call list.
final class PromptRecordingGenerator: TextGenerator, @unchecked Sendable {
    private(set) var lastPrompt: String?
    func generateJSON(prompt: String, schema: JSONSchema) async throws -> String {
        lastPrompt = prompt
        return #"{ "tool_calls": [] , "reply": "ok" }"#
    }
}

@Test func priorSummaryIsThreadedIntoPrompt() async throws {
    let gen = PromptRecordingGenerator()
    let controller = AssistantController(generator: gen, messages: FakeMessageStore(), rules: FakeRuleStore(),
        backend: SpyMailBackend(), approvals: ApprovalQueue(), audit: InMemoryAuditLog(),
        predicateEvaluator: AlwaysTrueEvaluator())
    let context = AssistantContext(currentThread: nil, visibleMessages: [], rules: [],
        recentMessages: [], accountEmail: "me@x.com",
        priorSummary: "Earlier: user archived Notion mail.")
    _ = try await controller.handle(turn: "and the Acme thread?", context: context)
    #expect(gen.lastPrompt?.contains("Earlier: user archived Notion mail.") == true)
    #expect(gen.lastPrompt?.contains("and the Acme thread?") == true)
}

@Test func builderUnitIncludesSummary() {
    let ctx = AssistantContext(currentThread: nil, visibleMessages: [], rules: [],
        recentMessages: [], accountEmail: "me@x.com", priorSummary: "S-U-M-M-A-R-Y")
    let prompt = PromptBuilder.build(turn: "hi", context: ctx)
    #expect(prompt.contains("S-U-M-M-A-R-Y"))
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniAssistant && swift test --filter PromptMemoryTests
```

Expected: failure only if memory is not threaded (or `PromptRecordingGenerator` not defined). Since `PromptBuilder` already includes `priorSummary` (Task 8), the unit test should pass; the integration test fails until `handle` passes the built prompt to the generator — confirm it does. If both pass immediately, that is acceptable (the test locks in the behavior); ensure the test exists and runs green.

- [ ] **Step 3: Make it pass**

If `handle` does not yet route `PromptBuilder.build(...)`'s output into `generator.generateJSON`, fix it. No new production type should be needed.

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniAssistant && swift test --filter PromptMemoryTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniAssistant && git add -A && git commit -m "SenaniAssistant: thread rolling conversation summary into the prompt + memory tests"
```

(Append the standard trailer.)

---

### Task 10: Full suite green + final commit

**Files:** none (verification).

- [ ] **Step 1: Run the entire suite**

```
cd Packages/SenaniAssistant && swift test
```

Expected: ALL tests pass across `ToolSchemaTests`, `ToolCallParsingTests`, `ResponseTypesTests`, `ChatActionDispatcherTests`, `ChatSessionStoreTests`, `AssistantControllerReadTests`, `AssistantControllerWriteTests`, `AssistantControllerRuleTests`, `PromptMemoryTests`, and the `TestSupport` self-test.

- [ ] **Step 2: Build clean (no warnings under strict concurrency)**

```
cd Packages/SenaniAssistant && swift build
```

Expected: builds with no errors. Resolve any `Sendable`/concurrency warnings before finishing.

- [ ] **Step 3: Final commit (if anything changed)**

```
cd Packages/SenaniAssistant && git add -A && git commit -m "SenaniAssistant: full conversational logic core green"
```

(Append the standard trailer.)

---

## Self-Review

**Spec §5 coverage:**
- §5.1 job 1 (Inbox Q&A, read-only) — `queryInbox`/`summarizeThread`/`listNeedsReply` return `ReadResult` with store data, no approval. ✅ (Task 8 read tests)
- §5.1 job 2 (Commands) — `applyActions` → `ChatActionDispatcher`: reversible runs now with `UndoToken`, outbound lands in `ApprovalQueue` not applied. ✅ (Tasks 6 + 8 write tests)
- §5.1 job 3 (Rule authoring/editing) — `authorRule`/`editRule` return a DRAFT `Rule` + inline `Simulator` result and do NOT save; `confirm(rule:)` is the explicit follow-up save. ✅ (Task 8 rule tests)
- §5.2 (Context & memory) — `AssistantContext` holds selection/thread/visible inbox/rules/recent corpus/accountEmail; rolling `priorSummary` threaded into the prompt; `ChatSessionStore` persists turns + summary to `chat_sessions`. ✅ (Tasks 4, 7, 9)
- §5.3 (Reliability on small model) — `ToolSchema` is a `JSONSchema` for grammar-constrained decoding; `ToolCall.parse` is safe-on-malformed (never crashes). ✅ (Tasks 2, 3)

**Kernel safety reuse:** chat writes route through `ActionRouter.route` (the same pure function rules use); outbound/irreversible can never auto-execute even though chat uses `.auto` autonomy — verified by the outbound write test and the dispatcher mixed-actions test. The Assistant adds NO second safety path; it only adds a chat `Trigger`.

**Testability rule honored:** no real model — every controller test is driven by `FakeTextGenerator` (or `PromptRecordingGenerator`) emitting canned tool-call JSON; the real `Simulator`/`RuleEngine`/`ApprovalQueue`/`InMemoryAuditLog` from `SenaniRules` are reused with a `SpyMailBackend` and in-memory store fakes. All logic is unit-tested.

**Contracts exposed (public API of this package):**
- `AssistantTool` (enum, `CaseIterable`; `wireName`, `isReadOnly`)
- `ToolSchema` (`json: String`, `schema: JSONSchema`)
- `ToolCall` (enum + `parse(json:) throws -> [ToolCall]`), `ToolCallParseError`, `InboxFilter`, `RuleSpec`, `RuleChanges`
- `AssistantContext`
- `AssistantResponse` + `ReadResult`, `UndoToken`, `PendingApproval`, `RuleProposal`
- `MessageReading`, `RuleWriting` (store ports)
- `ChatActionDispatcher` (+ `Result`)
- `ChatSessionStore` (+ `ChatRole`, `ChatTurn`)
- `PromptBuilder`
- `AssistantController` (`handle(turn:context:)`, `confirm(rule:)`)

**Explicitly deferred to separate plans:** the SwiftUI Assistant panel (⌘K right-side chat) and the cockpit Approval/Activity-log UI (foundation app-shell track); the real Gemma `TextGenerator`/`PredicateEvaluator` (MLX); the real Gmail `MailBackend`; production `SenaniStore` adapters to `MessageReading`/`RuleWriting`; scoped vector retrieval that populates `AssistantContext`.

**Risks / assumptions to confirm with the human before/while coding:**
1. **`SenaniStore.MessageStore` read API** — assumed `query(_:)/thread(id:)/needsReply()`. This package defines its own `MessageReading` port and ships fakes; a production adapter (separate plan) bridges the real store. If the store's read surface differs, only the adapter changes.
2. **`SenaniDatabase.inMemory()`** and the **`chat_sessions`** column layout — `ChatSessionStore` codes to an assumed `(session_id, seq, role, text, created_at)` + summary shape; adapt SQL to the real migration. A missing summary column is a `SenaniStore` prerequisite, not a migration to add here.
3. **`SenaniInference.FakeTextGenerator`** must expose the received prompt for the memory test; if it cannot, the included `PromptRecordingGenerator` test double covers it. `JSONSchema(json:)` initializer is assumed; adjust `ToolSchema.schema` if the real initializer differs.
4. **`ActionExecutor` cannot carry a chat trigger** — confirmed by reading the built source (`execute(match:)` hard-codes `Trigger.rule`). Hence `ChatActionDispatcher`. If `SenaniRules` later gains a chat-trigger executor, the dispatcher can delegate to it.
