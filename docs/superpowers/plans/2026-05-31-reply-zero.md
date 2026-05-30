# SenaniReplyZero Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `SenaniReplyZero` Swift package that detects threads needing a reply *from the user* via a pure-Swift structured classifier (with an optional injected AI confirm), persists per-thread flags, exposes a scan service for the "Needs you" view and Daily Digest count, and provides a built-in `SenaniRules.Rule` factory expressing Reply Zero as an editable rule.

**Architecture:** Four focused components. `NeedsReplyClassifier` is pure Swift over a thread's messages (structured signals: user is a recipient, last message not from user, message contains an ask) with an async overload that consults an injected `SenaniRules.PredicateEvaluator` only when the structured signal is positive (and the confirmer can veto to cut false positives). `NeedsReplyStore` wraps a `SenaniStore.SenaniDatabase` to set/clear/list the `needs_reply` flag per thread. `ReplyZeroService` scans threads, classifies, writes flags through the store (the implementation behind the kernel's `flagNeedsReply` action), and answers `needsYou()` / `count()`. `replyZeroRule()` returns a well-formed built-in `SenaniRules.Rule` so Reply Zero is consistent with the engine and editable in plain English.

**Tech Stack:** Swift 6.2, swift-tools 6.0, macOS 14, strict concurrency (complete), Swift Testing (`import Testing`). Path deps on `../SenaniRules` and `../SenaniStore`.

---

## Assumptions (cross-package)

These are stated explicitly because `SenaniStore` is consumed as a sibling path dependency whose source this plan does not touch:

1. **`SenaniStore` exposes a public `SenaniDatabase` type** that:
   - Can be constructed in-memory for tests, e.g. `SenaniDatabase(inMemory: true)` (an initializer that opens a SQLite `:memory:` connection). If the real initializer signature differs, the executing worker adapts the test setup to the actual public initializer and records the deviation; the production `NeedsReplyStore` only ever receives a `SenaniDatabase` by injection, so it is agnostic to how the db was opened.
   - Runs its migrations on init, which already include a **`needs_reply`** table. This plan assumes the schema `needs_reply(thread_id TEXT PRIMARY KEY, flagged INTEGER NOT NULL, updated_at REAL NOT NULL)`. If the real schema differs, the worker maps `NeedsReplyStore`'s queries to the real columns and records the deviation.
   - Provides a way to execute parameterized SQL and read rows. This plan assumes a minimal surface of the shape `func execute(_ sql: String, _ params: [SQLValue]) throws` and `func query(_ sql: String, _ params: [SQLValue]) throws -> [[String: SQLValue]]` (or equivalent). The worker binds `NeedsReplyStore` to whatever the real public query API is. **If `SenaniStore` does not yet exist or does not expose a usable query surface, the worker creates a minimal protocol `NeedsReplyDatabase` inside `SenaniReplyZero` capturing exactly the three operations the store needs (upsert flag, delete flag, list flagged thread ids), conforms an in-memory fake to it in tests, and notes that the production conformance to `SenaniDatabase` is wired up when `SenaniStore` lands.** This keeps `SenaniReplyZero` independently buildable and testable today.

2. **`SenaniRules` is used exactly as-is** (read-only). Targeted types: `Message`, `Action.flagNeedsReply`, `Conditions`, `MatchMode`, `StructuredCondition.to(_:)`, `Autonomy.auto`, `RunOn.incoming`, `Rule`, and `protocol PredicateEvaluator { func evaluate(predicates:[String], against:Message) async -> [Bool] }`.

3. **Account email** is supplied by the caller (the live app knows the single account address; multi-account is a non-goal). The classifier and service take it as a parameter.

> **Decision for first implementation:** To keep `SenaniReplyZero` buildable and fully testable *before* `SenaniStore` exists, `NeedsReplyStore` is written against a small package-internal protocol `NeedsReplyDatabase`. A thin adapter conforming `SenaniStore.SenaniDatabase` to `NeedsReplyDatabase` is added behind the path dependency. Tests use an in-memory fake conforming to `NeedsReplyDatabase`. This honors the brief's "in-memory `SenaniDatabase` for store tests" intent while not blocking on a package that is not yet present in the repo. The `Package.swift` still declares both path deps per the brief.

---

## File Structure

```
Packages/SenaniReplyZero/
├── Package.swift
├── Sources/
│   └── SenaniReplyZero/
│       ├── NeedsReplyClassifier.swift     # pure-Swift signals + optional async AI confirm
│       ├── NeedsReplyDatabase.swift        # minimal db protocol + SenaniDatabase adapter
│       ├── NeedsReplyStore.swift           # set/clear/list needs_reply flags
│       ├── ReplyZeroService.swift          # scan threads → classify → flag; needsYou()/count()
│       └── ReplyZeroRule.swift             # replyZeroRule() built-in Rule factory
└── Tests/
    └── SenaniReplyZeroTests/
        ├── Fixtures.swift                  # message/thread builders + FakePredicateEvaluator
        ├── InMemoryNeedsReplyDatabase.swift# test double conforming to NeedsReplyDatabase
        ├── NeedsReplyClassifierTests.swift
        ├── NeedsReplyStoreTests.swift
        ├── ReplyZeroServiceTests.swift
        └── ReplyZeroRuleTests.swift
```

---

## Task 0 — Scaffold the package

**Files:**
- `Packages/SenaniReplyZero/Package.swift` (new)
- `Packages/SenaniReplyZero/Sources/SenaniReplyZero/Placeholder.swift` (new, temporary)

**Steps:**

- [ ] Create `Packages/SenaniReplyZero/Package.swift` with exactly:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniReplyZero",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniReplyZero", targets: ["SenaniReplyZero"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
        .package(path: "../SenaniStore"),
    ],
    targets: [
        .target(
            name: "SenaniReplyZero",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "SenaniStore", package: "SenaniStore"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "SenaniReplyZeroTests",
            dependencies: ["SenaniReplyZero"]
        ),
    ]
)
```

> **If `../SenaniStore` does not resolve** (package absent from the repo at build time): comment out the `.package(path: "../SenaniStore")` dependency line and the corresponding `.product(name: "SenaniStore", ...)` entry, add a `// TODO: re-add SenaniStore path dep once the package exists` note, and proceed against the package-internal `NeedsReplyDatabase` protocol (Task 3). Record this deviation in the commit body. Do NOT create the `SenaniStore` package yourself.

- [ ] Create a temporary `Sources/SenaniReplyZero/Placeholder.swift`:

```swift
enum SenaniReplyZeroPlaceholder {}
```

- [ ] Run: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniReplyZero && swift build`
  - **Expected:** Builds successfully (empty library). If `SenaniStore` is unresolvable, apply the fallback above, then re-run — must build.

- [ ] Commit:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniReplyZero && git init -q 2>/dev/null; git add -A && git commit -m "$(cat <<'EOF'
Scaffold SenaniReplyZero package

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

> Note: if the repo is not git-initialized at this path, `git init -q` makes the per-package commits self-contained. If a parent repo already tracks this directory, drop `git init` and commit from the repo root with the same message and trailer.

---

## Task 1 — Test fixtures + FakePredicateEvaluator

**Files:**
- `Tests/SenaniReplyZeroTests/Fixtures.swift` (new)

**Steps:**

- [ ] Write `Tests/SenaniReplyZeroTests/Fixtures.swift` with reusable builders and a fake confirmer. This file holds no `@Test`s; it is shared infrastructure.

```swift
import Foundation
@testable import SenaniReplyZero
import SenaniRules

enum Fix {
    static let account = "me@acme.io"
    static let now = Date(timeIntervalSince1970: 1_000_000)

    /// Builds a Message with sensible defaults; override only what a test cares about.
    static func msg(
        id: String = "m",
        from: String = "sarah@vendor.com",
        to: [String] = ["me@acme.io"],
        subject: String = "Re: project",
        body: String = "Could you send the figures?",
        threadId: String = "t1",
        date: Date = Date(timeIntervalSince1970: 1_000_000),
        isFromUser: Bool = false
    ) -> Message {
        Message(
            id: id, from: from, to: to, subject: subject, body: body,
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: threadId, date: date, isFromUser: isFromUser
        )
    }
}

/// Records calls and returns scripted verdicts so tests can assert the confirmer
/// is consulted only when expected, and can veto a structurally-positive result.
actor FakePredicateEvaluator: PredicateEvaluator {
    private let verdict: Bool
    private(set) var calls: [[String]] = []
    init(verdict: Bool) { self.verdict = verdict }
    func evaluate(predicates: [String], against message: Message) async -> [Bool] {
        calls.append(predicates)
        return predicates.map { _ in verdict }
    }
    func recordedCalls() -> [[String]] { calls }
}
```

- [ ] Run: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniReplyZero && swift build --build-tests`
  - **Expected:** Compiles (fixtures reference only existing `SenaniRules` types). No tests run yet.

- [ ] Commit:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniReplyZero && git add -A && git commit -m "$(cat <<'EOF'
Add test fixtures and FakePredicateEvaluator

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 2 — NeedsReplyClassifier (pure-Swift structured signals)

**Files:**
- `Tests/SenaniReplyZeroTests/NeedsReplyClassifierTests.swift` (new)
- `Sources/SenaniReplyZero/NeedsReplyClassifier.swift` (new)

### 2a. Write the failing tests

- [ ] Write `Tests/SenaniReplyZeroTests/NeedsReplyClassifierTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniReplyZero
import SenaniRules

@Suite struct NeedsReplyClassifierTests {
    let sut = NeedsReplyClassifier()

    // MARK: structured signal combinations

    @Test func positiveWhenUserIsRecipientLastNotFromUserAndHasQuestion() {
        let thread = [Fix.msg(body: "Could you send the figures?")]
        #expect(sut.classify(thread: thread, accountEmail: Fix.account) == true)
    }

    @Test func negativeWhenUserIsNotARecipient() {
        let thread = [Fix.msg(to: ["someone@else.com"], body: "Could you reply?")]
        #expect(sut.classify(thread: thread, accountEmail: Fix.account) == false)
    }

    @Test func negativeWhenLastMessageIsFromUser() {
        let thread = [
            Fix.msg(id: "a", from: "sarah@vendor.com", body: "Could you?", date: Date(timeIntervalSince1970: 1), isFromUser: false),
            Fix.msg(id: "b", from: Fix.account, to: ["sarah@vendor.com"], body: "Sure, here you go?", date: Date(timeIntervalSince1970: 2), isFromUser: true),
        ]
        #expect(sut.classify(thread: thread, accountEmail: Fix.account) == false)
    }

    @Test func negativeWhenNoAskOrQuestion() {
        let thread = [Fix.msg(body: "Thanks, received with thanks.")]
        #expect(sut.classify(thread: thread, accountEmail: Fix.account) == false)
    }

    @Test func emptyThreadIsNegative() {
        #expect(sut.classify(thread: [], accountEmail: Fix.account) == false)
    }

    // MARK: ask heuristics

    @Test func questionMarkCountsAsAsk() {
        let t = [Fix.msg(body: "Is this ready")]      // no ?
        #expect(sut.classify(thread: t, accountEmail: Fix.account) == false)
        let t2 = [Fix.msg(body: "Is this ready?")]    // has ?
        #expect(sut.classify(thread: t2, accountEmail: Fix.account) == true)
    }

    @Test func requestPhrasesCountAsAskEvenWithoutQuestionMark() {
        for phrase in ["could you send it.", "Can you confirm.", "Please review the doc.",
                       "let me know your thoughts.", "what's your availability.",
                       "when can we meet."] {
            let t = [Fix.msg(body: phrase)]
            #expect(sut.classify(thread: t, accountEmail: Fix.account) == true, "phrase: \(phrase)")
        }
    }

    @Test func askDetectionIsCaseInsensitive() {
        let t = [Fix.msg(body: "PLEASE advise.")]
        #expect(sut.classify(thread: t, accountEmail: Fix.account) == true)
    }

    @Test func recipientMatchIsCaseInsensitive() {
        let t = [Fix.msg(to: ["Me@Acme.IO"], body: "Could you?")]
        #expect(sut.classify(thread: t, accountEmail: Fix.account) == true)
    }

    @Test func usesChronologicallyLastMessageNotArrayOrder() {
        // Out-of-order array; latest by date is from the user → negative.
        let thread = [
            Fix.msg(id: "b", from: Fix.account, body: "ok?", date: Date(timeIntervalSince1970: 9), isFromUser: true),
            Fix.msg(id: "a", from: "sarah@vendor.com", body: "Could you?", date: Date(timeIntervalSince1970: 1), isFromUser: false),
        ]
        #expect(sut.classify(thread: thread, accountEmail: Fix.account) == false)
    }

    // MARK: async confirm overload

    @Test func confirmerNotConsultedWhenStructuralIsNegative() async {
        let fake = FakePredicateEvaluator(verdict: true)
        let thread = [Fix.msg(body: "Thanks.")]   // structurally negative
        let result = await sut.classify(thread: thread, accountEmail: Fix.account, confirmWith: fake)
        #expect(result == false)
        #expect(await fake.recordedCalls().isEmpty)   // model never asked
    }

    @Test func confirmerConsultedAndCanVetoWhenStructuralIsPositive() async {
        let fake = FakePredicateEvaluator(verdict: false)   // veto
        let thread = [Fix.msg(body: "Could you send the figures?")]
        let result = await sut.classify(thread: thread, accountEmail: Fix.account, confirmWith: fake)
        #expect(result == false)                            // vetoed despite positive structural
        let calls = await fake.recordedCalls()
        #expect(calls.count == 1)
        #expect(calls.first == ["this message needs a reply from me"])
    }

    @Test func confirmerConfirmsPositive() async {
        let fake = FakePredicateEvaluator(verdict: true)
        let thread = [Fix.msg(body: "Could you send the figures?")]
        let result = await sut.classify(thread: thread, accountEmail: Fix.account, confirmWith: fake)
        #expect(result == true)
    }

    @Test func nilConfirmerFallsBackToStructural() async {
        let thread = [Fix.msg(body: "Could you send the figures?")]
        let result = await sut.classify(thread: thread, accountEmail: Fix.account, confirmWith: nil)
        #expect(result == true)
    }
}
```

- [ ] Run-to-fail: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniReplyZero && swift test --filter NeedsReplyClassifierTests`
  - **Expected:** Compile failure — `cannot find 'NeedsReplyClassifier' in scope`.

### 2b. Minimal implementation

- [ ] Write `Sources/SenaniReplyZero/NeedsReplyClassifier.swift`:

```swift
import Foundation
import SenaniRules

/// Pure-Swift detector for "does the latest message in this thread need a reply
/// FROM the user?" Distinct from the Follow-up agent (which watches for THEIR reply).
///
/// Structured signals (all must hold):
///   1. the user is a recipient of the latest message (accountEmail ∈ `to`);
///   2. the latest message is NOT from the user (`isFromUser == false`);
///   3. the latest message contains an ask (a '?' or a request phrase).
public struct NeedsReplyClassifier: Sendable {
    /// Plain-English predicate handed to the optional AI confirmer.
    public static let confirmPredicate = "this message needs a reply from me"

    /// Lowercased request phrases that signal an ask even without a question mark.
    private static let askPhrases = [
        "could you", "can you", "would you", "please", "let me know",
        "what's your", "whats your", "when can", "any chance", "do you",
        "are you able", "advise", "thoughts?", "your thoughts",
    ]

    public init() {}

    /// Structured-only verdict (no model call).
    public func classify(thread: [Message], accountEmail: String) -> Bool {
        guard let latest = thread.max(by: { $0.date < $1.date }) else { return false }
        guard !latest.isFromUser else { return false }
        let userIsRecipient = latest.to.contains {
            $0.caseInsensitiveCompare(accountEmail) == .orderedSame
        }
        guard userIsRecipient else { return false }
        return Self.containsAsk(latest)
    }

    /// Structured verdict, optionally confirmed by an injected evaluator.
    /// The confirmer is consulted ONLY when the structured signal is positive AND
    /// a confirmer is provided; it may veto (returning false) to cut false positives.
    public func classify(
        thread: [Message],
        accountEmail: String,
        confirmWith confirmer: PredicateEvaluator?
    ) async -> Bool {
        guard classify(thread: thread, accountEmail: accountEmail) else { return false }
        guard let confirmer,
              let latest = thread.max(by: { $0.date < $1.date }) else { return true }
        let verdicts = await confirmer.evaluate(
            predicates: [Self.confirmPredicate], against: latest
        )
        return verdicts.first ?? true
    }

    private static func containsAsk(_ m: Message) -> Bool {
        let haystack = (m.subject + " " + m.body).lowercased()
        if haystack.contains("?") { return true }
        return askPhrases.contains { haystack.contains($0) }
    }
}
```

> Implementation notes for the worker:
> - `thoughts?` is included in `askPhrases` but is redundant with the `?` check — harmless; keep the phrase list readable.
> - If the confirmer returns an empty array, fall back to the positive structural verdict (`?? true`) rather than silently dropping the flag.

- [ ] Run-to-pass: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniReplyZero && swift test --filter NeedsReplyClassifierTests`
  - **Expected:** All `NeedsReplyClassifierTests` pass.

- [ ] Commit:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniReplyZero && git add -A && git commit -m "$(cat <<'EOF'
Add NeedsReplyClassifier with structured signals and optional AI confirm

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 3 — NeedsReplyDatabase protocol + in-memory test double + NeedsReplyStore

**Files:**
- `Sources/SenaniReplyZero/NeedsReplyDatabase.swift` (new)
- `Tests/SenaniReplyZeroTests/InMemoryNeedsReplyDatabase.swift` (new)
- `Tests/SenaniReplyZeroTests/NeedsReplyStoreTests.swift` (new)
- `Sources/SenaniReplyZero/NeedsReplyStore.swift` (new)

### 3a. Define the database seam (production source)

- [ ] Write `Sources/SenaniReplyZero/NeedsReplyDatabase.swift`. This is the minimal persistence surface the store needs, decoupled from `SenaniStore` so the package is independently testable. A real adapter for `SenaniStore.SenaniDatabase` lives here too (guarded so it compiles whether or not the dep resolves).

```swift
import Foundation

/// Minimal persistence surface `NeedsReplyStore` requires. Backed in production by
/// `SenaniStore.SenaniDatabase`'s `needs_reply` table; backed in tests by an
/// in-memory fake. Async so a real SQLite-actor-backed db can conform without blocking.
public protocol NeedsReplyDatabase: Sendable {
    /// Upsert the flag for a thread (true = needs reply).
    func setNeedsReply(threadId: String, flagged: Bool, updatedAt: Date) async throws
    /// Remove any flag row for the thread.
    func clearNeedsReply(threadId: String) async throws
    /// Thread ids currently flagged as needing a reply, in stable (e.g. insertion) order.
    func flaggedThreadIds() async throws -> [String]
}
```

> **Wiring `SenaniStore.SenaniDatabase`:** add a separate file `Sources/SenaniReplyZero/SenaniDatabaseAdapter.swift` (only if the `SenaniStore` dep resolves) extending `SenaniStore.SenaniDatabase: NeedsReplyDatabase`, mapping the three methods onto the real `needs_reply` table via the database's public query API (see Assumption 1 for the assumed schema `needs_reply(thread_id, flagged, updated_at)`). If the dep is NOT present, skip that file; the package still builds and tests against the in-memory fake. Record which path was taken in the commit body.

### 3b. In-memory test double

- [ ] Write `Tests/SenaniReplyZeroTests/InMemoryNeedsReplyDatabase.swift`:

```swift
import Foundation
@testable import SenaniReplyZero

/// In-memory stand-in for the `needs_reply` table. Mirrors the assumed
/// `SenaniStore.SenaniDatabase(inMemory: true)` semantics: a single row per thread.
actor InMemoryNeedsReplyDatabase: NeedsReplyDatabase {
    private var order: [String] = []
    private var flags: [String: Bool] = [:]

    func setNeedsReply(threadId: String, flagged: Bool, updatedAt: Date) async throws {
        if flags[threadId] == nil { order.append(threadId) }
        flags[threadId] = flagged
    }

    func clearNeedsReply(threadId: String) async throws {
        flags[threadId] = nil
        order.removeAll { $0 == threadId }
    }

    func flaggedThreadIds() async throws -> [String] {
        order.filter { flags[$0] == true }
    }
}
```

### 3c. Failing store tests

- [ ] Write `Tests/SenaniReplyZeroTests/NeedsReplyStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniReplyZero

@Suite struct NeedsReplyStoreTests {
    @Test func setThenListReturnsThread() async throws {
        let db = InMemoryNeedsReplyDatabase()
        let store = NeedsReplyStore(database: db)
        try await store.set(threadId: "t1")
        #expect(try await store.list() == ["t1"])
    }

    @Test func clearRemovesThread() async throws {
        let db = InMemoryNeedsReplyDatabase()
        let store = NeedsReplyStore(database: db)
        try await store.set(threadId: "t1")
        try await store.set(threadId: "t2")
        try await store.clear(threadId: "t1")
        #expect(try await store.list() == ["t2"])
    }

    @Test func setIsIdempotentAndPreservesOrder() async throws {
        let db = InMemoryNeedsReplyDatabase()
        let store = NeedsReplyStore(database: db)
        try await store.set(threadId: "t1")
        try await store.set(threadId: "t2")
        try await store.set(threadId: "t1")     // re-set existing
        #expect(try await store.list() == ["t1", "t2"])
    }

    @Test func clearOnUnknownThreadIsNoOp() async throws {
        let db = InMemoryNeedsReplyDatabase()
        let store = NeedsReplyStore(database: db)
        try await store.clear(threadId: "nope")
        #expect(try await store.list().isEmpty)
    }
}
```

- [ ] Run-to-fail: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniReplyZero && swift test --filter NeedsReplyStoreTests`
  - **Expected:** Compile failure — `cannot find 'NeedsReplyStore' in scope`.

### 3d. Minimal store implementation

- [ ] Write `Sources/SenaniReplyZero/NeedsReplyStore.swift`:

```swift
import Foundation

/// Persists Reply Zero state per thread via a `NeedsReplyDatabase`
/// (the `needs_reply` table in production). This is the storage implementation
/// behind the kernel's `flagNeedsReply` action.
public struct NeedsReplyStore: Sendable {
    private let database: any NeedsReplyDatabase
    private let clock: @Sendable () -> Date

    public init(database: any NeedsReplyDatabase, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.clock = clock
    }

    /// Flag a thread as needing the user's reply.
    public func set(threadId: String) async throws {
        try await database.setNeedsReply(threadId: threadId, flagged: true, updatedAt: clock())
    }

    /// Clear the needs-reply flag for a thread (e.g. once the user has replied).
    public func clear(threadId: String) async throws {
        try await database.clearNeedsReply(threadId: threadId)
    }

    /// All thread ids currently flagged as needing a reply.
    public func list() async throws -> [String] {
        try await database.flaggedThreadIds()
    }
}
```

- [ ] Run-to-pass: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniReplyZero && swift test --filter NeedsReplyStoreTests`
  - **Expected:** All `NeedsReplyStoreTests` pass.

- [ ] Commit:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniReplyZero && git add -A && git commit -m "$(cat <<'EOF'
Add NeedsReplyDatabase seam and NeedsReplyStore with in-memory round-trip tests

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 4 — ReplyZeroService (scan → classify → flag; needsYou/count)

**Files:**
- `Tests/SenaniReplyZeroTests/ReplyZeroServiceTests.swift` (new)
- `Sources/SenaniReplyZero/ReplyZeroService.swift` (new)

### 4a. Failing service tests

- [ ] Write `Tests/SenaniReplyZeroTests/ReplyZeroServiceTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniReplyZero
import SenaniRules

@Suite struct ReplyZeroServiceTests {
    private func makeService(confirmer: PredicateEvaluator? = nil)
        -> (ReplyZeroService, InMemoryNeedsReplyDatabase) {
        let db = InMemoryNeedsReplyDatabase()
        let store = NeedsReplyStore(database: db)
        let service = ReplyZeroService(
            classifier: NeedsReplyClassifier(),
            store: store,
            accountEmail: Fix.account,
            confirmer: confirmer
        )
        return (service, db)
    }

    @Test func scanFlagsOnlyThreadsThatNeedReply() async throws {
        let (service, _) = makeService()
        let needs = [Fix.msg(id: "n1", threadId: "tA", body: "Could you confirm?")]
        let doesNot = [Fix.msg(id: "d1", threadId: "tB", body: "Thanks, all good.")]
        await service.scan(threads: [needs, doesNot])
        #expect(try await service.needsYou() == ["tA"])
        #expect(try await service.count() == 1)
    }

    @Test func scanClearsThreadThatNoLongerNeedsReply() async throws {
        let (service, _) = makeService()
        // First pass: thread tA needs a reply.
        await service.scan(threads: [[Fix.msg(threadId: "tA", body: "Could you confirm?")]])
        #expect(try await service.needsYou() == ["tA"])
        // Second pass: user has now replied last → no longer needs reply → flag cleared.
        let replied = [
            Fix.msg(id: "a", from: "sarah@vendor.com", threadId: "tA", body: "Could you?", date: Date(timeIntervalSince1970: 1), isFromUser: false),
            Fix.msg(id: "b", from: Fix.account, to: ["sarah@vendor.com"], threadId: "tA", body: "Done.", date: Date(timeIntervalSince1970: 2), isFromUser: true),
        ]
        await service.scan(threads: [replied])
        #expect(try await service.needsYou().isEmpty)
        #expect(try await service.count() == 0)
    }

    @Test func confirmerVetoMeansNoFlag() async throws {
        let (service, _) = makeService(confirmer: FakePredicateEvaluator(verdict: false))
        await service.scan(threads: [[Fix.msg(threadId: "tA", body: "Could you confirm?")]])
        #expect(try await service.needsYou().isEmpty)
    }

    @Test func confirmerConfirmMeansFlag() async throws {
        let (service, _) = makeService(confirmer: FakePredicateEvaluator(verdict: true))
        await service.scan(threads: [[Fix.msg(threadId: "tA", body: "Could you confirm?")]])
        #expect(try await service.needsYou() == ["tA"])
    }

    @Test func emptyThreadsLeaveCountZero() async throws {
        let (service, _) = makeService()
        await service.scan(threads: [])
        #expect(try await service.count() == 0)
    }

    @Test func ignoresEmptyThreadInBatch() async throws {
        let (service, _) = makeService()
        await service.scan(threads: [[], [Fix.msg(threadId: "tA", body: "Could you confirm?")]])
        #expect(try await service.needsYou() == ["tA"])
    }
}
```

- [ ] Run-to-fail: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniReplyZero && swift test --filter ReplyZeroServiceTests`
  - **Expected:** Compile failure — `cannot find 'ReplyZeroService' in scope`.

### 4b. Minimal service implementation

- [ ] Write `Sources/SenaniReplyZero/ReplyZeroService.swift`:

```swift
import Foundation
import SenaniRules

/// Scans threads, runs the classifier, and records `needs_reply` flags via the store.
/// This is the implementation behind the kernel's `flagNeedsReply` action; in the live
/// app the rule engine emits `.flagNeedsReply` and this service performs the write.
/// Exposes `needsYou()` (the "Needs you" view) and `count()` (Daily Digest).
public struct ReplyZeroService: Sendable {
    private let classifier: NeedsReplyClassifier
    private let store: NeedsReplyStore
    private let accountEmail: String
    private let confirmer: (any PredicateEvaluator)?

    public init(
        classifier: NeedsReplyClassifier,
        store: NeedsReplyStore,
        accountEmail: String,
        confirmer: (any PredicateEvaluator)? = nil
    ) {
        self.classifier = classifier
        self.store = store
        self.accountEmail = accountEmail
        self.confirmer = confirmer
    }

    /// Classifies each thread; sets the flag when it needs the user's reply and
    /// clears it otherwise (so a thread the user has since answered drops off the list).
    /// Each element of `threads` is the full message list for one thread.
    public func scan(threads: [[Message]]) async {
        for thread in threads {
            guard let threadId = thread.max(by: { $0.date < $1.date })?.threadId else { continue }
            let needs = await classifier.classify(
                thread: thread, accountEmail: accountEmail, confirmWith: confirmer
            )
            do {
                if needs {
                    try await store.set(threadId: threadId)
                } else {
                    try await store.clear(threadId: threadId)
                }
            } catch {
                // Persistence failure is non-fatal to a scan pass; the next scan retries.
                continue
            }
        }
    }

    /// Thread ids the ball is currently in the user's court on.
    public func needsYou() async throws -> [String] {
        try await store.list()
    }

    /// Count for the Daily Digest.
    public func count() async throws -> Int {
        try await store.list().count
    }
}
```

> Note: the `do/catch` swallows persistence errors per pass (a scan should not abort because one row failed to write). `needsYou()`/`count()` still `throw` so query-time failures surface to the caller.

- [ ] Run-to-pass: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniReplyZero && swift test --filter ReplyZeroServiceTests`
  - **Expected:** All `ReplyZeroServiceTests` pass.

- [ ] Commit:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniReplyZero && git add -A && git commit -m "$(cat <<'EOF'
Add ReplyZeroService scanning threads into needs_reply flags

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 5 — replyZeroRule() built-in Rule factory

**Files:**
- `Tests/SenaniReplyZeroTests/ReplyZeroRuleTests.swift` (new)
- `Sources/SenaniReplyZero/ReplyZeroRule.swift` (new)

### 5a. Failing factory tests

- [ ] Write `Tests/SenaniReplyZeroTests/ReplyZeroRuleTests.swift`:

```swift
import Testing
@testable import SenaniReplyZero
import SenaniRules

@Suite struct ReplyZeroRuleTests {
    @Test func factoryProducesWellFormedRule() {
        let rule = replyZeroRule(accountEmail: Fix.account)
        #expect(rule.enabled == true)
        #expect(rule.actions == [.flagNeedsReply])
        #expect(rule.autonomy == .auto)
        #expect(rule.runOn == .incoming)
        #expect(rule.name.isEmpty == false)
        #expect(rule.id.isEmpty == false)
    }

    @Test func conditionsTargetRecipientAndCarryNeedsReplyPredicate() {
        let rule = replyZeroRule(accountEmail: Fix.account)
        #expect(rule.conditions.mode == .all)
        #expect(rule.conditions.structured.contains(.to(Fix.account)))
        #expect(rule.conditions.aiPredicate == NeedsReplyClassifier.confirmPredicate)
    }

    @Test func ruleIdIsStableAcrossCalls() {
        #expect(replyZeroRule(accountEmail: Fix.account).id
                == replyZeroRule(accountEmail: Fix.account).id)
    }
}
```

- [ ] Run-to-fail: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniReplyZero && swift test --filter ReplyZeroRuleTests`
  - **Expected:** Compile failure — `cannot find 'replyZeroRule' in scope`.

### 5b. Minimal factory implementation

- [ ] Write `Sources/SenaniReplyZero/ReplyZeroRule.swift`:

```swift
import SenaniRules

/// Stable id for the built-in Reply Zero rule, so it can be upserted idempotently.
public let replyZeroRuleID = "builtin.reply-zero"

/// Returns Reply Zero expressed AS a `SenaniRules.Rule`, keeping it consistent with
/// the engine and editable in plain English. Structured part targets incoming mail
/// where the user is a recipient; the `aiPredicate` mirrors the classifier's confirm
/// predicate so sensitivity is tunable. Action is `[.flagNeedsReply]`, `auto`, `incoming`.
public func replyZeroRule(accountEmail: String) -> Rule {
    Rule(
        id: replyZeroRuleID,
        name: "Reply Zero — needs your reply",
        enabled: true,
        conditions: Conditions(
            mode: .all,
            structured: [.to(accountEmail)],
            aiPredicate: NeedsReplyClassifier.confirmPredicate
        ),
        actions: [.flagNeedsReply],
        autonomy: .auto,
        runOn: .incoming
    )
}
```

- [ ] Run-to-pass: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniReplyZero && swift test --filter ReplyZeroRuleTests`
  - **Expected:** All `ReplyZeroRuleTests` pass.

- [ ] Commit:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniReplyZero && git add -A && git commit -m "$(cat <<'EOF'
Add replyZeroRule factory expressing Reply Zero as a built-in rule

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 6 — Cleanup and full-suite green

**Files:**
- `Sources/SenaniReplyZero/Placeholder.swift` (delete)

**Steps:**

- [ ] Delete the temporary placeholder: `rm /Users/vishalkumar/Downloads/qmail/Packages/SenaniReplyZero/Sources/SenaniReplyZero/Placeholder.swift`

- [ ] Run the full suite: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniReplyZero && swift test`
  - **Expected:** All suites pass — `NeedsReplyClassifierTests`, `NeedsReplyStoreTests`, `ReplyZeroServiceTests`, `ReplyZeroRuleTests`. No warnings under strict concurrency.

- [ ] Commit:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniReplyZero && git add -A && git commit -m "$(cat <<'EOF'
Remove placeholder; full SenaniReplyZero suite green

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Self-Review

**Brief coverage:**
- [ ] `NeedsReplyClassifier` is pure Swift, exposes both `classify(thread:accountEmail:) -> Bool` and `async classify(thread:accountEmail:confirmWith:) -> Bool`; structured signals are (1) user is a recipient, (2) latest message not from user, (3) ask heuristics ('?', "could you", "can you", "please", "let me know", "what's your", "when can", etc.). All combinations unit-tested with fixtures.
- [ ] Confirmer consulted ONLY when structured is positive and a confirmer is provided; can veto (tested: `confirmerNotConsultedWhenStructuralIsNegative`, `confirmerConsultedAndCanVetoWhenStructuralIsPositive`).
- [ ] `NeedsReplyStore` takes a database, supports set/clear/list, round-trip tested against an in-memory double.
- [ ] `ReplyZeroService` scans threads, runs the classifier, writes flags via the store (the implementation behind `flagNeedsReply`); exposes `needsYou()` and `count()`; tested with fixtures + in-memory store, including re-scan that clears a since-answered thread.
- [ ] `replyZeroRule()` returns a well-formed `Rule`: `to(accountEmail)` structured condition, `aiPredicate == NeedsReplyClassifier.confirmPredicate`, `actions == [.flagNeedsReply]`, `autonomy == .auto`, `runOn == .incoming`; tested.
- [ ] `Package.swift`: path deps `../SenaniRules` and `../SenaniStore`; macOS 14; swift-tools 6.0; strict concurrency.

**TDD discipline:**
- [ ] Every task: real failing Swift Testing test → `swift test --filter` run-to-fail with expected message → minimal real impl → run-to-pass → real `git commit` with the required trailer.
- [ ] No placeholders in shipped source (temporary placeholder removed in Task 6).

**Constraints honored:**
- [ ] Nothing leaves the Mac — confirmer is an injected `PredicateEvaluator` (Gemma/MLX in prod, fake in tests); no network.
- [ ] Approval-first — Reply Zero only sets a reversible `flagNeedsReply`; no outbound action emitted.
- [ ] Auditable — flags persisted per thread with `updated_at`; the rule expresses Reply Zero through the engine.

**Risks / assumptions to flag to caller:**
- [ ] `SenaniStore` package is not present in the repo yet. The plan keeps `SenaniReplyZero` independently buildable via the internal `NeedsReplyDatabase` seam and an in-memory test double, with a `SenaniDatabase` adapter to be added behind the path dep when `SenaniStore` lands (assumed `needs_reply(thread_id, flagged, updated_at)` schema). Worker records any schema/API deviations in commit bodies.
- [ ] Ask heuristics are intentionally simple; the optional Gemma confirm exists to cut false positives. Sensitivity is editable via the rule's `aiPredicate`.
```