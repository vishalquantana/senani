# Rules Engine Core (Swift Package) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure-Swift, fully unit-tested core of Senani's rules engine — the Action Kernel, Rule model, hybrid (filter + AI-predicate) matching, action routing safety, the executor, and the dry-run simulator — with injectable seams for the LLM and the mail backend, so it compiles and passes tests today with no MLX, Gmail, or UI.

**Architecture:** A standalone Swift Package Manager library (`SenaniRules`) implementing the "Action Kernel (Approach A)" from the design spec. Structured conditions evaluate instantly in pure Swift; AI predicates are evaluated through a `PredicateEvaluator` protocol (stubbed in tests, Gemma later). All side-effecting actions route through a single pure `ActionRouter` whose safety rule — *outbound actions always go to the approval queue regardless of autonomy* — is enforced once and shared by both the executor and the simulator. The executor performs actions via a `MailBackend` protocol; the simulator reuses the same routing but suppresses side effects.

**Tech Stack:** Swift 6.2 (strict concurrency), Swift Package Manager, Swift Testing (`import Testing`, ships with the toolchain — no external dependency). Target platform macOS 14.

**Working directory:** All `swift` commands run from `Packages/SenaniRules/` unless stated otherwise.

**Design spec:** `docs/superpowers/specs/2026-05-31-rules-engine-and-chat-assistant-design.md`

---

## File Structure

```
Packages/SenaniRules/
  Package.swift
  Sources/SenaniRules/
    Message.swift            # email domain model (test-friendly; no Gmail dependency)
    Action.swift             # Action enum + ActionClass (reversible/outbound) classification
    Condition.swift          # StructuredCondition, MatchMode, Conditions + structured matching
    PredicateEvaluator.swift # protocol seam for the local LLM (batched)
    Rule.swift               # Autonomy, RunOn, Rule
    RuleEngine.swift         # RuleMatch + hybrid matching pipeline
    Routing.swift            # Outcome, Trigger, ActionRouter (pure safety routing)
    Execution.swift          # MailBackend, AuditLog, ApprovalQueue, ActionRecord, Proposal, ActionExecutor
    Simulator.swift          # SimulationResult + Simulator (dry-run diff)
  Tests/SenaniRulesTests/
    MessageTests.swift
    ActionTests.swift
    ConditionTests.swift
    RuleEngineTests.swift
    RoutingTests.swift
    ExecutionTests.swift
    SimulatorTests.swift
```

Each file has one responsibility. Files that change together live together (e.g. all execution collaborators in `Execution.swift`). Later phases (Gemma `PredicateEvaluator`, a Gmail `MailBackend`, SQLite persistence, the Assistant, the SwiftUI app) depend on this package but are out of scope here.

---

### Task 1: Package scaffold + Message model

**Files:**
- Create: `Packages/SenaniRules/Package.swift`
- Create: `Packages/SenaniRules/Sources/SenaniRules/Message.swift`
- Test: `Packages/SenaniRules/Tests/SenaniRulesTests/MessageTests.swift`

- [ ] **Step 1: Create the package manifest**

Create `Packages/SenaniRules/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniRules",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniRules", targets: ["SenaniRules"]),
    ],
    targets: [
        .target(name: "SenaniRules"),
        .testTarget(name: "SenaniRulesTests", dependencies: ["SenaniRules"]),
    ]
)
```

- [ ] **Step 2: Write the failing test**

Create `Packages/SenaniRules/Tests/SenaniRulesTests/MessageTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniRules

@Suite struct MessageTests {
    @Test func senderDomainIsLowercasedHostAfterAt() {
        let m = Message(
            id: "1", from: "Alice@Example.COM", to: ["me@acme.io"],
            subject: "Hi", body: "hello", hasAttachment: false,
            listUnsubscribeHeader: nil, labels: [], threadId: "t1",
            date: Date(timeIntervalSince1970: 0), isFromUser: false
        )
        #expect(m.senderDomain == "example.com")
    }

    @Test func senderDomainEmptyWhenNoAt() {
        let m = Message(
            id: "2", from: "garbage", to: [], subject: "", body: "",
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: "t", date: Date(timeIntervalSince1970: 0), isFromUser: false
        )
        #expect(m.senderDomain == "")
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd Packages/SenaniRules && swift test`
Expected: FAIL — compile error, `cannot find 'Message' in scope`.

- [ ] **Step 4: Write the minimal implementation**

Create `Packages/SenaniRules/Sources/SenaniRules/Message.swift`:

```swift
import Foundation

/// An email message, modeled with exactly the fields the rules engine needs.
/// Decoupled from Gmail so it is trivially constructible in tests.
public struct Message: Sendable, Equatable, Identifiable {
    public let id: String
    public let from: String
    public let to: [String]
    public let subject: String
    public let body: String
    public let hasAttachment: Bool
    public let listUnsubscribeHeader: String?
    public let labels: [String]
    public let threadId: String
    public let date: Date
    public let isFromUser: Bool

    public init(
        id: String, from: String, to: [String], subject: String, body: String,
        hasAttachment: Bool, listUnsubscribeHeader: String?, labels: [String],
        threadId: String, date: Date, isFromUser: Bool
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.subject = subject
        self.body = body
        self.hasAttachment = hasAttachment
        self.listUnsubscribeHeader = listUnsubscribeHeader
        self.labels = labels
        self.threadId = threadId
        self.date = date
        self.isFromUser = isFromUser
    }

    /// Lowercased host portion after the last "@", or "" if there is no "@".
    public var senderDomain: String {
        guard let at = from.lastIndex(of: "@") else { return "" }
        return String(from[from.index(after: at)...]).lowercased()
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd Packages/SenaniRules && swift test`
Expected: PASS — both `MessageTests` tests pass.

- [ ] **Step 6: Commit**

```bash
git add Packages/SenaniRules/Package.swift Packages/SenaniRules/Sources/SenaniRules/Message.swift Packages/SenaniRules/Tests/SenaniRulesTests/MessageTests.swift
git commit -m "feat(rules): scaffold SenaniRules package + Message model"
```

---

### Task 2: Action + ActionClass classification

**Files:**
- Create: `Packages/SenaniRules/Sources/SenaniRules/Action.swift`
- Test: `Packages/SenaniRules/Tests/SenaniRulesTests/ActionTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniRules/Tests/SenaniRulesTests/ActionTests.swift`:

```swift
import Testing
@testable import SenaniRules

@Suite struct ActionTests {
    @Test func reversibleActionsAreClassifiedReversible() {
        let reversible: [Action] = [
            .label("x"), .archive, .markRead, .markUnread, .star, .unstar,
            .move("Y"), .flagNeedsReply, .fileAttachment(folder: "Invoices"),
            .parseDoc, .runAgent(id: "lead"), .draft(body: "hi"),
            .localWebhook(name: "notify")
        ]
        for action in reversible {
            #expect(action.actionClass == .reversible, "\(action) should be reversible")
        }
    }

    @Test func outboundActionsAreClassifiedOutbound() {
        let outbound: [Action] = [
            .reply(body: "ok"), .forward(to: "a@b.com", body: "fyi"),
            .send(body: "hello"), .markSpam
        ]
        for action in outbound {
            #expect(action.actionClass == .outbound, "\(action) should be outbound")
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/SenaniRules && swift test`
Expected: FAIL — `cannot find 'Action' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Packages/SenaniRules/Sources/SenaniRules/Action.swift`:

```swift
/// The Action Kernel vocabulary: every side-effecting operation both the rule
/// engine and (later) the chat assistant can request.
public enum Action: Sendable, Equatable {
    case label(String)
    case archive
    case markRead
    case markUnread
    case star
    case unstar
    case move(String)
    case flagNeedsReply
    case fileAttachment(folder: String)
    case parseDoc
    case runAgent(id: String)
    case draft(body: String)
    case reply(body: String)
    case forward(to: String, body: String)
    case send(body: String)
    case markSpam
    case localWebhook(name: String)
}

/// Safety class of an action. The kernel guarantees outbound actions never
/// execute silently — they always route to the approval queue.
public enum ActionClass: Sendable, Equatable {
    case reversible
    case outbound
}

extension Action {
    public var actionClass: ActionClass {
        switch self {
        case .reply, .forward, .send, .markSpam:
            return .outbound
        case .label, .archive, .markRead, .markUnread, .star, .unstar, .move,
             .flagNeedsReply, .fileAttachment, .parseDoc, .runAgent, .draft,
             .localWebhook:
            return .reversible
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/SenaniRules && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/SenaniRules/Sources/SenaniRules/Action.swift Packages/SenaniRules/Tests/SenaniRulesTests/ActionTests.swift
git commit -m "feat(rules): Action Kernel vocabulary + reversible/outbound classification"
```

---

### Task 3: StructuredCondition + Conditions structured matching

**Files:**
- Create: `Packages/SenaniRules/Sources/SenaniRules/Condition.swift`
- Test: `Packages/SenaniRules/Tests/SenaniRulesTests/ConditionTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniRules/Tests/SenaniRulesTests/ConditionTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniRules

@Suite struct ConditionTests {
    private func msg(
        from: String = "bob@vendor.com", subject: String = "Invoice 42",
        body: String = "Payment due", hasAttachment: Bool = true,
        unsub: String? = nil, labels: [String] = [], thread: String = "t1",
        ageSeconds: TimeInterval = 0
    ) -> Message {
        Message(
            id: "m", from: from, to: ["me@acme.io"], subject: subject, body: body,
            hasAttachment: hasAttachment, listUnsubscribeHeader: unsub, labels: labels,
            threadId: thread, date: Date(timeIntervalSince1970: 1000 - ageSeconds),
            isFromUser: false
        )
    }
    private let now = Date(timeIntervalSince1970: 1000)

    @Test func structuredConditionsEvaluateIndividually() {
        let m = msg()
        #expect(StructuredCondition.from("bob@vendor.com").matches(m, now: now))
        #expect(StructuredCondition.domain("vendor.com").matches(m, now: now))
        #expect(StructuredCondition.subjectContains("invoice").matches(m, now: now)) // case-insensitive
        #expect(StructuredCondition.bodyContains("due").matches(m, now: now))
        #expect(StructuredCondition.hasAttachment.matches(m, now: now))
        #expect(StructuredCondition.isInThread("t1").matches(m, now: now))
        #expect(!StructuredCondition.hasLabel("Finance").matches(m, now: now))
        #expect(StructuredCondition.hasLabel("Finance").matches(msg(labels: ["Finance"]), now: now))
        #expect(StructuredCondition.listUnsubscribeHeader.matches(msg(unsub: "<mailto:x>"), now: now))
        #expect(!StructuredCondition.listUnsubscribeHeader.matches(m, now: now))
    }

    @Test func olderThanComparesAgainstNow() {
        #expect(StructuredCondition.olderThan(60).matches(msg(ageSeconds: 120), now: now))
        #expect(!StructuredCondition.olderThan(60).matches(msg(ageSeconds: 30), now: now))
    }

    @Test func matchModeAllRequiresEveryCondition() {
        let c = Conditions(mode: .all,
            structured: [.domain("vendor.com"), .hasAttachment], aiPredicate: nil)
        #expect(c.matchesStructured(msg(), now: now))
        #expect(!c.matchesStructured(msg(hasAttachment: false), now: now))
    }

    @Test func matchModeAnyRequiresAtLeastOne() {
        let c = Conditions(mode: .any,
            structured: [.domain("nope.com"), .hasAttachment], aiPredicate: nil)
        #expect(c.matchesStructured(msg(), now: now)) // hasAttachment true -> at least one matches
        #expect(!c.matchesStructured(msg(from: "x@other.com", hasAttachment: false), now: now)) // none match
    }

    @Test func matchModeNoneRequiresNoConditionTrue() {
        let c = Conditions(mode: .none,
            structured: [.domain("spam.com")], aiPredicate: nil)
        #expect(c.matchesStructured(msg(), now: now))
        #expect(!c.matchesStructured(msg(from: "x@spam.com"), now: now))
    }

    @Test func emptyStructuredIsVacuouslyTrueUnderAll() {
        let c = Conditions(mode: .all, structured: [], aiPredicate: "is about pricing")
        #expect(c.matchesStructured(msg(), now: now)) // lets a pure-AI rule reach its predicate
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/SenaniRules && swift test`
Expected: FAIL — `cannot find 'StructuredCondition' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Packages/SenaniRules/Sources/SenaniRules/Condition.swift`:

```swift
import Foundation

/// A condition that is evaluated instantly in pure Swift, with no model call.
public enum StructuredCondition: Sendable, Equatable {
    case from(String)
    case to(String)
    case domain(String)
    case subjectContains(String)
    case bodyContains(String)
    case hasAttachment
    case listUnsubscribeHeader
    case isInThread(String)
    case olderThan(TimeInterval)
    case hasLabel(String)

    public func matches(_ m: Message, now: Date) -> Bool {
        switch self {
        case .from(let a):            return m.from.caseInsensitiveCompare(a) == .orderedSame
        case .to(let a):              return m.to.contains { $0.caseInsensitiveCompare(a) == .orderedSame }
        case .domain(let d):          return m.senderDomain == d.lowercased()
        case .subjectContains(let s): return m.subject.range(of: s, options: .caseInsensitive) != nil
        case .bodyContains(let s):    return m.body.range(of: s, options: .caseInsensitive) != nil
        case .hasAttachment:          return m.hasAttachment
        case .listUnsubscribeHeader:  return m.listUnsubscribeHeader != nil
        case .isInThread(let t):      return m.threadId == t
        case .olderThan(let secs):    return now.timeIntervalSince(m.date) > secs
        case .hasLabel(let l):        return m.labels.contains(l)
        }
    }
}

/// How the structured conditions combine.
public enum MatchMode: Sendable, Equatable {
    case all
    case any
    case none
}

/// A rule's conditions: a structured set (instant) plus an optional plain-English
/// AI predicate (evaluated separately by the engine, only when the structured set matches).
public struct Conditions: Sendable, Equatable {
    public var mode: MatchMode
    public var structured: [StructuredCondition]
    public var aiPredicate: String?

    public init(mode: MatchMode, structured: [StructuredCondition], aiPredicate: String?) {
        self.mode = mode
        self.structured = structured
        self.aiPredicate = aiPredicate
    }

    /// Evaluates ONLY the structured conditions. The AI predicate is handled by the engine.
    /// Empty structured + `.all` is vacuously true so pure-AI rules can reach their predicate.
    public func matchesStructured(_ m: Message, now: Date) -> Bool {
        switch mode {
        case .all:  return structured.allSatisfy { $0.matches(m, now: now) }
        case .any:  return structured.contains { $0.matches(m, now: now) }
        case .none: return !structured.contains { $0.matches(m, now: now) }
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/SenaniRules && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/SenaniRules/Sources/SenaniRules/Condition.swift Packages/SenaniRules/Tests/SenaniRulesTests/ConditionTests.swift
git commit -m "feat(rules): structured conditions + match modes (instant, no model)"
```

---

### Task 4: PredicateEvaluator protocol + Rule model

**Files:**
- Create: `Packages/SenaniRules/Sources/SenaniRules/PredicateEvaluator.swift`
- Create: `Packages/SenaniRules/Sources/SenaniRules/Rule.swift`
- Test: covered by `RuleEngineTests.swift` in Task 5 (no standalone test needed — these are plain data/protocol definitions exercised there).

- [ ] **Step 1: Write the PredicateEvaluator protocol**

Create `Packages/SenaniRules/Sources/SenaniRules/PredicateEvaluator.swift`:

```swift
/// The seam for the local LLM. The engine calls this AT MOST ONCE per message,
/// passing every pending predicate at once (batching), and gets one Bool per predicate.
/// The real implementation calls Gemma via MLX with grammar-constrained decoding; tests stub it.
public protocol PredicateEvaluator: Sendable {
    func evaluate(predicates: [String], against message: Message) async -> [Bool]
}
```

- [ ] **Step 2: Write the Rule model**

Create `Packages/SenaniRules/Sources/SenaniRules/Rule.swift`:

```swift
/// Per-rule autonomy ladder. New rules default to `.ask`.
/// `prepare` stages reversible actions for one-click commit; `auto` fires them silently.
/// (Named `prepare` rather than `draft` to avoid colliding with the `draft(...)` action.)
public enum Autonomy: String, Sendable, Equatable {
    case ask
    case prepare
    case auto
}

/// Which messages a rule runs against.
public enum RunOn: String, Sendable, Equatable {
    case incoming
    case existing
    case both
}

/// A user-authored automation: WHEN <conditions> DO <actions> @ <autonomy>.
public struct Rule: Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var enabled: Bool
    public var conditions: Conditions
    public var actions: [Action]
    public var autonomy: Autonomy
    public var runOn: RunOn

    public init(
        id: String, name: String, enabled: Bool, conditions: Conditions,
        actions: [Action], autonomy: Autonomy, runOn: RunOn
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.conditions = conditions
        self.actions = actions
        self.autonomy = autonomy
        self.runOn = runOn
    }
}
```

- [ ] **Step 3: Verify the package still builds**

Run: `cd Packages/SenaniRules && swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 4: Commit**

```bash
git add Packages/SenaniRules/Sources/SenaniRules/PredicateEvaluator.swift Packages/SenaniRules/Sources/SenaniRules/Rule.swift
git commit -m "feat(rules): PredicateEvaluator seam + Rule model (autonomy ladder)"
```

---

### Task 5: RuleEngine hybrid matching pipeline

**Files:**
- Create: `Packages/SenaniRules/Sources/SenaniRules/RuleEngine.swift`
- Test: `Packages/SenaniRules/Tests/SenaniRulesTests/RuleEngineTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniRules/Tests/SenaniRulesTests/RuleEngineTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniRules

/// Records every batch call and returns scripted answers keyed by predicate text.
final class SpyEvaluator: PredicateEvaluator, @unchecked Sendable {
    let answers: [String: Bool]
    private(set) var calls: [[String]] = []
    init(answers: [String: Bool]) { self.answers = answers }
    func evaluate(predicates: [String], against message: Message) async -> [Bool] {
        calls.append(predicates)
        return predicates.map { answers[$0] ?? false }
    }
}

@Suite struct RuleEngineTests {
    private let now = Date(timeIntervalSince1970: 1000)
    private func msg(from: String = "bob@vendor.com", attach: Bool = true) -> Message {
        Message(id: "m", from: from, to: ["me@acme.io"], subject: "Invoice",
                body: "due", hasAttachment: attach, listUnsubscribeHeader: nil,
                labels: [], threadId: "t1", date: Date(timeIntervalSince1970: 1000),
                isFromUser: false)
    }
    private func rule(_ id: String, _ c: Conditions, enabled: Bool = true) -> Rule {
        Rule(id: id, name: id, enabled: enabled, conditions: c,
             actions: [.label(id)], autonomy: .auto, runOn: .incoming)
    }

    @Test func purelyStructuralMatchNeedsNoModelCall() async {
        let spy = SpyEvaluator(answers: [:])
        let engine = RuleEngine(evaluator: spy)
        let r = rule("a", Conditions(mode: .all, structured: [.domain("vendor.com")], aiPredicate: nil))
        let matches = await engine.match(message: msg(), rules: [r], now: now)
        #expect(matches.map(\.rule.id) == ["a"])
        #expect(spy.calls.isEmpty) // model never called
    }

    @Test func disabledRulesAreSkipped() async {
        let spy = SpyEvaluator(answers: [:])
        let engine = RuleEngine(evaluator: spy)
        let r = rule("a", Conditions(mode: .all, structured: [.domain("vendor.com")], aiPredicate: nil), enabled: false)
        let matches = await engine.match(message: msg(), rules: [r], now: now)
        #expect(matches.isEmpty)
    }

    @Test func predicateOnlyEvaluatedWhenStructuralPasses() async {
        let spy = SpyEvaluator(answers: ["is about pricing": true])
        let engine = RuleEngine(evaluator: spy)
        // r1 structural FAILS -> its predicate must NOT be evaluated.
        let r1 = rule("fails", Conditions(mode: .all, structured: [.domain("other.com")], aiPredicate: "skip me"))
        // r2 structural PASSES and has a predicate -> evaluated.
        let r2 = rule("ai", Conditions(mode: .all, structured: [.domain("vendor.com")], aiPredicate: "is about pricing"))
        let matches = await engine.match(message: msg(), rules: [r1, r2], now: now)
        #expect(matches.map(\.rule.id) == ["ai"])
        #expect(spy.calls.count == 1)                 // exactly one batched call
        #expect(spy.calls.first == ["is about pricing"]) // failed rule's predicate excluded
    }

    @Test func predicateFalseRejectsRuleEvenIfStructuralPasses() async {
        let spy = SpyEvaluator(answers: ["is about pricing": false])
        let engine = RuleEngine(evaluator: spy)
        let r = rule("ai", Conditions(mode: .all, structured: [.domain("vendor.com")], aiPredicate: "is about pricing"))
        let matches = await engine.match(message: msg(), rules: [r], now: now)
        #expect(matches.isEmpty)
    }

    @Test func noModelCallWhenNoStructuralMatchHasPredicate() async {
        let spy = SpyEvaluator(answers: [:])
        let engine = RuleEngine(evaluator: spy)
        let r = rule("a", Conditions(mode: .all, structured: [.hasAttachment], aiPredicate: nil))
        _ = await engine.match(message: msg(attach: false), rules: [r], now: now)
        #expect(spy.calls.isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/SenaniRules && swift test`
Expected: FAIL — `cannot find 'RuleEngine' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Packages/SenaniRules/Sources/SenaniRules/RuleEngine.swift`:

```swift
import Foundation

/// A rule that matched a message.
public struct RuleMatch: Sendable, Equatable {
    public let rule: Rule
    public let message: Message
    public init(rule: Rule, message: Message) {
        self.rule = rule
        self.message = message
    }
}

/// The hybrid matching pipeline: instant structured filtering, then at most one
/// batched predicate evaluation per message.
public struct RuleEngine: Sendable {
    private let evaluator: PredicateEvaluator
    public init(evaluator: PredicateEvaluator) { self.evaluator = evaluator }

    public func match(message: Message, rules: [Rule], now: Date) async -> [RuleMatch] {
        // 1. Structured pass (pure Swift) over enabled rules.
        let structurallyMatched = rules.filter {
            $0.enabled && $0.conditions.matchesStructured(message, now: now)
        }

        // 2. Collect predicates only for rules that passed structurally AND carry one.
        let pending = structurallyMatched.compactMap { rule -> (Rule, String)? in
            guard let p = rule.conditions.aiPredicate else { return nil }
            return (rule, p)
        }

        // 3. At most one batched model call for this message.
        var verdicts: [String: Bool] = [:]
        if !pending.isEmpty {
            let predicates = pending.map(\.1)
            let results = await evaluator.evaluate(predicates: predicates, against: message)
            for (i, predicate) in predicates.enumerated() where i < results.count {
                verdicts[predicate] = results[i]
            }
        }

        // 4. Final match: structural pass AND (no predicate OR predicate true).
        return structurallyMatched.compactMap { rule in
            if let p = rule.conditions.aiPredicate, verdicts[p] != true { return nil }
            return RuleMatch(rule: rule, message: message)
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/SenaniRules && swift test`
Expected: PASS — all `RuleEngineTests` pass; the spy confirms the model is called at most once and only for structurally-matched predicates.

- [ ] **Step 5: Commit**

```bash
git add Packages/SenaniRules/Sources/SenaniRules/RuleEngine.swift Packages/SenaniRules/Tests/SenaniRulesTests/RuleEngineTests.swift
git commit -m "feat(rules): hybrid matching engine (filters first, one batched AI call)"
```

---

### Task 6: ActionRouter (pure safety routing)

**Files:**
- Create: `Packages/SenaniRules/Sources/SenaniRules/Routing.swift`
- Test: `Packages/SenaniRules/Tests/SenaniRulesTests/RoutingTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniRules/Tests/SenaniRulesTests/RoutingTests.swift`:

```swift
import Testing
@testable import SenaniRules

@Suite struct RoutingTests {
    @Test func outboundAlwaysQueuesRegardlessOfAutonomy() {
        for autonomy in [Autonomy.ask, .prepare, .auto] {
            #expect(ActionRouter.route(.reply(body: "x"), autonomy: autonomy) == .queuedForApproval)
            #expect(ActionRouter.route(.markSpam, autonomy: autonomy) == .queuedForApproval)
        }
    }

    @Test func reversibleUnderAutoExecutes() {
        #expect(ActionRouter.route(.label("x"), autonomy: .auto) == .executed)
    }

    @Test func reversibleUnderPrepareIsPrepared() {
        #expect(ActionRouter.route(.draft(body: "hi"), autonomy: .prepare) == .prepared)
    }

    @Test func reversibleUnderAskQueues() {
        #expect(ActionRouter.route(.archive, autonomy: .ask) == .queuedForApproval)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/SenaniRules && swift test`
Expected: FAIL — `cannot find 'ActionRouter' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Packages/SenaniRules/Sources/SenaniRules/Routing.swift`:

```swift
/// What happened (executor) or would happen (simulator) to a single action.
public enum Outcome: Sendable, Equatable {
    case executed          // reversible action applied automatically
    case prepared          // reversible action staged for one-click commit (prepare autonomy)
    case queuedForApproval // sent to the approval queue (all outbound, or reversible under ask)
}

/// What caused an action — recorded in the audit log.
public enum Trigger: Sendable, Equatable {
    case rule(id: String)
    case chat(turnId: String)
}

/// The single source of truth for the kernel's safety guarantee.
/// Shared by the executor (which performs) and the simulator (which only records).
public enum ActionRouter {
    public static func route(_ action: Action, autonomy: Autonomy) -> Outcome {
        if action.actionClass == .outbound { return .queuedForApproval }
        switch autonomy {
        case .auto:    return .executed
        case .prepare: return .prepared
        case .ask:     return .queuedForApproval
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/SenaniRules && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/SenaniRules/Sources/SenaniRules/Routing.swift Packages/SenaniRules/Tests/SenaniRulesTests/RoutingTests.swift
git commit -m "feat(rules): ActionRouter — outbound always queues (kernel safety rule)"
```

---

### Task 7: Execution collaborators + ActionExecutor

**Files:**
- Create: `Packages/SenaniRules/Sources/SenaniRules/Execution.swift`
- Test: `Packages/SenaniRules/Tests/SenaniRulesTests/ExecutionTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniRules/Tests/SenaniRulesTests/ExecutionTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniRules

/// Records actions the executor actually applied to the backend.
actor SpyBackend: MailBackend {
    private(set) var applied: [(Action, String)] = []
    func apply(_ action: Action, to message: Message) async throws {
        applied.append((action, message.id))
    }
    func appliedActions() -> [Action] { applied.map(\.0) }
}

@Suite struct ExecutionTests {
    private func msg() -> Message {
        Message(id: "m1", from: "bob@vendor.com", to: ["me@acme.io"], subject: "s",
                body: "b", hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
                threadId: "t", date: Date(timeIntervalSince1970: 0), isFromUser: false)
    }
    private func matchWith(actions: [Action], autonomy: Autonomy) -> RuleMatch {
        let r = Rule(id: "r1", name: "r1", enabled: true,
                     conditions: Conditions(mode: .all, structured: [], aiPredicate: nil),
                     actions: actions, autonomy: autonomy, runOn: .incoming)
        return RuleMatch(rule: r, message: msg())
    }

    @Test func autoExecutesReversibleAndAuditsExecuted() async throws {
        let backend = SpyBackend(); let queue = ApprovalQueue(); let audit = InMemoryAuditLog()
        let exec = ActionExecutor(backend: backend, approvals: queue, audit: audit)
        try await exec.execute(match: matchWith(actions: [.label("Finance")], autonomy: .auto))

        #expect(await backend.appliedActions() == [.label("Finance")])
        #expect(await queue.pending().isEmpty)
        let records = await audit.records()
        #expect(records.count == 1)
        #expect(records[0].outcome == .executed)
        #expect(records[0].trigger == .rule(id: "r1"))
    }

    @Test func outboundNeverExecutesEvenUnderAuto() async throws {
        let backend = SpyBackend(); let queue = ApprovalQueue(); let audit = InMemoryAuditLog()
        let exec = ActionExecutor(backend: backend, approvals: queue, audit: audit)
        try await exec.execute(match: matchWith(actions: [.reply(body: "hi")], autonomy: .auto))

        #expect(await backend.appliedActions().isEmpty)        // never sent
        let pending = await queue.pending()
        #expect(pending.count == 1)
        #expect(pending[0].action == .reply(body: "hi"))
        #expect(await audit.records()[0].outcome == .queuedForApproval)
    }

    @Test func askQueuesEverythingIncludingReversible() async throws {
        let backend = SpyBackend(); let queue = ApprovalQueue(); let audit = InMemoryAuditLog()
        let exec = ActionExecutor(backend: backend, approvals: queue, audit: audit)
        try await exec.execute(match: matchWith(actions: [.archive], autonomy: .ask))

        #expect(await backend.appliedActions().isEmpty)
        #expect(await queue.pending().count == 1)
    }

    @Test func prepareAppliesReversibleAndAuditsPrepared() async throws {
        let backend = SpyBackend(); let queue = ApprovalQueue(); let audit = InMemoryAuditLog()
        let exec = ActionExecutor(backend: backend, approvals: queue, audit: audit)
        try await exec.execute(match: matchWith(actions: [.draft(body: "hi")], autonomy: .prepare))

        #expect(await backend.appliedActions() == [.draft(body: "hi")])
        #expect(await audit.records()[0].outcome == .prepared)
    }

    @Test func mixedActionSetRoutesEachActionIndependently() async throws {
        let backend = SpyBackend(); let queue = ApprovalQueue(); let audit = InMemoryAuditLog()
        let exec = ActionExecutor(backend: backend, approvals: queue, audit: audit)
        try await exec.execute(match: matchWith(actions: [.label("X"), .reply(body: "hi")], autonomy: .auto))

        #expect(await backend.appliedActions() == [.label("X")]) // reversible applied
        #expect(await queue.pending().map(\.action) == [.reply(body: "hi")]) // outbound queued
        #expect(await audit.records().count == 2)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/SenaniRules && swift test`
Expected: FAIL — `cannot find 'MailBackend' / 'ApprovalQueue' / 'InMemoryAuditLog' / 'ActionExecutor' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Packages/SenaniRules/Sources/SenaniRules/Execution.swift`:

```swift
import Foundation

/// The seam to the world that performs reversible actions (labels, archive, drafts…).
/// The real implementation talks to Gmail; tests use a spy.
public protocol MailBackend: Sendable {
    func apply(_ action: Action, to message: Message) async throws
}

/// An outbound or to-be-approved action awaiting the user's decision.
public struct Proposal: Sendable, Equatable {
    public let action: Action
    public let message: Message
    public let trigger: Trigger
    public init(action: Action, message: Message, trigger: Trigger) {
        self.action = action
        self.message = message
        self.trigger = trigger
    }
}

/// Collects proposals for the SwiftUI Approval queue (later).
public actor ApprovalQueue {
    private var items: [Proposal] = []
    public init() {}
    public func enqueue(_ p: Proposal) { items.append(p) }
    public func pending() -> [Proposal] { items }
}

/// One executed/queued action, with what caused it — the auditable trail.
public struct ActionRecord: Sendable, Equatable {
    public let action: Action
    public let messageId: String
    public let trigger: Trigger
    public let outcome: Outcome
    public init(action: Action, messageId: String, trigger: Trigger, outcome: Outcome) {
        self.action = action
        self.messageId = messageId
        self.trigger = trigger
        self.outcome = outcome
    }
}

public protocol AuditLog: Sendable {
    func record(_ record: ActionRecord) async
}

/// In-memory audit log for tests and early development.
public actor InMemoryAuditLog: AuditLog {
    private var items: [ActionRecord] = []
    public init() {}
    public func record(_ record: ActionRecord) { items.append(record) }
    public func records() -> [ActionRecord] { items }
}

/// Executes a matched rule's actions, enforcing the kernel safety rule via ActionRouter.
public struct ActionExecutor: Sendable {
    private let backend: MailBackend
    private let approvals: ApprovalQueue
    private let audit: AuditLog
    public init(backend: MailBackend, approvals: ApprovalQueue, audit: AuditLog) {
        self.backend = backend
        self.approvals = approvals
        self.audit = audit
    }

    public func execute(match: RuleMatch) async throws {
        let trigger = Trigger.rule(id: match.rule.id)
        for action in match.rule.actions {
            let outcome = ActionRouter.route(action, autonomy: match.rule.autonomy)
            switch outcome {
            case .executed, .prepared:
                try await backend.apply(action, to: match.message)
            case .queuedForApproval:
                await approvals.enqueue(
                    Proposal(action: action, message: match.message, trigger: trigger))
            }
            await audit.record(ActionRecord(
                action: action, messageId: match.message.id, trigger: trigger, outcome: outcome))
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/SenaniRules && swift test`
Expected: PASS — all `ExecutionTests` pass; outbound actions are never applied to the backend.

- [ ] **Step 5: Commit**

```bash
git add Packages/SenaniRules/Sources/SenaniRules/Execution.swift Packages/SenaniRules/Tests/SenaniRulesTests/ExecutionTests.swift
git commit -m "feat(rules): action executor + approval queue + audit log"
```

---

### Task 8: Simulator (dry-run diff)

**Files:**
- Create: `Packages/SenaniRules/Sources/SenaniRules/Simulator.swift`
- Test: `Packages/SenaniRules/Tests/SenaniRulesTests/SimulatorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniRules/Tests/SenaniRulesTests/SimulatorTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniRules

@Suite struct SimulatorTests {
    private let now = Date(timeIntervalSince1970: 1000)
    private func msg(_ id: String, from: String) -> Message {
        Message(id: id, from: from, to: ["me@acme.io"], subject: "s", body: "b",
                hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
                threadId: "t-\(id)", date: Date(timeIntervalSince1970: 1000), isFromUser: false)
    }

    @Test func simulationReportsWhatWouldHappenWithoutSideEffects() async {
        let backend = SpyBackend()
        let engine = RuleEngine(evaluator: SpyEvaluator(answers: [:]))
        let sim = Simulator(engine: engine)
        let rule = Rule(id: "vendor", name: "vendor", enabled: true,
            conditions: Conditions(mode: .all, structured: [.domain("vendor.com")], aiPredicate: nil),
            actions: [.label("Vendors"), .reply(body: "thanks")], autonomy: .auto, runOn: .incoming)
        let messages = [msg("1", from: "a@vendor.com"), msg("2", from: "b@other.com")]

        let result = await sim.run(rules: [rule], over: messages, now: now)

        // Only message 1 matches; two actions each routed independently.
        #expect(result.items.count == 2)
        #expect(result.items.allSatisfy { $0.messageId == "1" })
        #expect(result.items.contains { $0.action == .label("Vendors") && $0.outcome == .executed })
        #expect(result.items.contains { $0.action == .reply(body: "thanks") && $0.outcome == .queuedForApproval })
        // The simulator must not touch the backend.
        #expect(await backend.appliedActions().isEmpty)
    }

    @Test func countByOutcomeSummarizesTheDiff() async {
        let engine = RuleEngine(evaluator: SpyEvaluator(answers: [:]))
        let sim = Simulator(engine: engine)
        let rule = Rule(id: "all", name: "all", enabled: true,
            conditions: Conditions(mode: .all, structured: [], aiPredicate: nil),
            actions: [.archive], autonomy: .auto, runOn: .incoming)
        let messages = [msg("1", from: "x@a.com"), msg("2", from: "y@b.com"), msg("3", from: "z@c.com")]

        let result = await sim.run(rules: [rule], over: messages, now: now)
        #expect(result.count(of: .executed) == 3)
        #expect(result.count(of: .queuedForApproval) == 0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/SenaniRules && swift test`
Expected: FAIL — `cannot find 'Simulator' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Packages/SenaniRules/Sources/SenaniRules/Simulator.swift`:

```swift
import Foundation

/// The faithful dry-run: same engine + same routing as live execution, side effects suppressed.
public struct SimulationResult: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let messageId: String
        public let ruleId: String
        public let action: Action
        public let outcome: Outcome
        public init(messageId: String, ruleId: String, action: Action, outcome: Outcome) {
            self.messageId = messageId
            self.ruleId = ruleId
            self.action = action
            self.outcome = outcome
        }
    }
    public var items: [Item]
    public init(items: [Item]) { self.items = items }

    public func count(of outcome: Outcome) -> Int {
        items.filter { $0.outcome == outcome }.count
    }
}

/// Runs rules against a set of messages and reports what WOULD happen.
public struct Simulator: Sendable {
    private let engine: RuleEngine
    public init(engine: RuleEngine) { self.engine = engine }

    public func run(rules: [Rule], over messages: [Message], now: Date) async -> SimulationResult {
        var items: [SimulationResult.Item] = []
        for message in messages {
            let matches = await engine.match(message: message, rules: rules, now: now)
            for match in matches {
                for action in match.rule.actions {
                    let outcome = ActionRouter.route(action, autonomy: match.rule.autonomy)
                    items.append(.init(
                        messageId: message.id, ruleId: match.rule.id,
                        action: action, outcome: outcome))
                }
            }
        }
        return SimulationResult(items: items)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/SenaniRules && swift test`
Expected: PASS — all tests across all suites pass.

- [ ] **Step 5: Run the full suite once more and commit**

Run: `cd Packages/SenaniRules && swift test`
Expected: PASS — entire `SenaniRulesTests` suite green.

```bash
git add Packages/SenaniRules/Sources/SenaniRules/Simulator.swift Packages/SenaniRules/Tests/SenaniRulesTests/SimulatorTests.swift
git commit -m "feat(rules): dry-run simulator (faithful diff, no side effects)"
```

---

## What this plan deliberately leaves out (next plans)

- **Gemma `PredicateEvaluator`** — MLX/grammar-constrained implementation of the seam defined in Task 4.
- **Gmail `MailBackend`** — the real implementation of the seam defined in Task 7.
- **SQLite persistence** — `rules`, `rule_runs`, `actions_log` tables (the spec's data model); the in-memory `ApprovalQueue`/`InMemoryAuditLog` are the seams these will replace.
- **The Assistant** — chat front-end that emits Actions and draft Rules over this same core.
- **Voice profile, document pipeline (liteparse), analytics, Reply Zero classifier** — each its own spec + plan.
- **The SwiftUI app shell + Approval queue UI** — consumes this package.

These are intentionally out of scope: this plan delivers a self-contained, fully tested engine core that those layers plug into.

---

## Self-Review

**Spec coverage (core slice):** Action Kernel + reversible/outbound tagging → Tasks 2, 6. Rule model + autonomy ladder (default ask handled at UI/persistence layer; enum present) → Task 4. Hybrid filter-then-AI matching with bounded model calls → Tasks 3, 5. Approval-first safety guarantee → Tasks 6, 7. Audit log with trigger → Task 7. Faithful simulation → Task 8. Deferred spec sections (voice, docs, analytics, Reply Zero, Assistant, persistence, UI) are explicitly listed as out of scope above. No in-scope requirement is unaddressed.

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N". Every code step contains complete, compilable code.

**Type consistency:** `Message`, `Action`/`ActionClass`, `StructuredCondition`/`MatchMode`/`Conditions`, `PredicateEvaluator.evaluate(predicates:against:)`, `Autonomy`(`ask`/`prepare`/`auto`)/`RunOn`/`Rule`, `RuleEngine.match(message:rules:now:)`/`RuleMatch`, `Outcome`(`executed`/`prepared`/`queuedForApproval`)/`Trigger`/`ActionRouter.route(_:autonomy:)`, `MailBackend.apply(_:to:)`/`Proposal`/`ApprovalQueue`/`ActionRecord`/`AuditLog`/`InMemoryAuditLog`/`ActionExecutor.execute(match:)`, `Simulator.run(rules:over:now:)`/`SimulationResult`. Names referenced in later tasks match their definitions. Test helpers `SpyEvaluator` (Task 5) and `SpyBackend` (Task 7) are reused by `SimulatorTests` (Task 8) — both live in the same test target and are visible.
