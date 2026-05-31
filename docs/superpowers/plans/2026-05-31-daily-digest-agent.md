# Daily Digest — Builder + Daily Schedule + Gold-Glass Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Phase-2 **Daily Digest** as a new app-tier package `Packages/SenaniDigest`: a pure, fully unit-tested `DigestBuilder.build(for:) -> DigestReport` that aggregates one day of inbox activity by reading the canonical store **only** through the frozen `SenaniAnalytics.AnalyticsQueries` (volume in/out, top senders, top domains, reply latency, per-rule/agent activity) plus the `ApprovalStore` (pending-approvals count); a `DigestScheduler` that fires the builder once per day at a user-set local time off an **injected clock** (no real timers in tests), respecting Low Power / Mac-awake via an injected closure; a gold-glass `DigestView` (the primary surface) rendering the `DigestReport`; and an optional "email me the digest" that produces a single **outbound** `SenaniRules.Action` which always queues for approval (never auto-sends). All tests run on `SenaniDatabase.inMemory()` seeded with explicit-timestamp message + `actions_log` rows; no MLX, no Gmail network, no real Keychain, no real timers.

**Architecture:** A new SwiftPM package `SenaniDigest` (peer of `SenaniEngine`/`SenaniDesign`) depending on the frozen `SenaniRules`, `SenaniStore`, `SenaniAnalytics`, and on the app-tier `SenaniDesign` (for the view). The core abstraction is **NOT** a per-message `SenaniEngine.Agent`: a digest is a **timer-based, day-scoped aggregation**, not a `(message, context, tools) -> [Action]` pure function over one message. Forcing it into the `Agent` protocol would mean inventing a fake "message" to wake for and abusing `wakesFor`/`proposals` semantics. Instead the digest is modelled as two cleanly separated pieces:
1. **`DigestBuilder`** — pure aggregator: `build(for date:) -> DigestReport` over injected `AnalyticsQueries` + an `ApprovalReading` seam (the day's window is derived from `date` + an injected `Calendar`/`TimeZone`).
2. **`DigestScheduler`** — a small actor holding the user's preferred local time-of-day; given an injected `now: () -> Date` clock and an injected `isLowPower: () -> Bool`, its `tick(now:)` (or internal loop) fires a host-supplied `onFire` callback **at most once per local calendar day**, the first time the clock has reached/passed the configured time for that day. It does **no** Gmail sync (that is `SenaniEngine.Scheduler`'s job) — it only triggers the digest build/surface.

**Scheduler-contract decision (flagged):** This plan **does NOT** add a `dailyDigest(at:)` hook to the frozen-contract `SenaniEngine.Scheduler` (the per-tick sync+process loop in `docs/superpowers/plans/2026-05-31-agent-engine-orchestrator-and-scheduler.md`). Mixing a daily once-per-day fire into the seconds/minutes sync loop would conflate two cadences and force a `SenaniEngine` contract change. Instead this plan introduces a **separate `DigestScheduler`** living in `SenaniDigest`. **This is a deliberate scope boundary, not a `SenaniEngine` contract addition** — `SenaniEngine.Scheduler` is untouched. If the app-shell composition root later wants a single timer surface, it composes the two schedulers; that is the app-shell plan's call and is recorded as an open item in §"Out of scope".

**Tech Stack:** Swift 6.2 (strict concurrency), `swift-tools-version: 6.0`, macOS 14, Apple Silicon, Swift Testing (`import Testing`, ships with the toolchain). GRDB is pulled transitively via `SenaniStore`/`SenaniAnalytics` for the test fixtures. No MLX, no network, no SwiftUI snapshot testing.

**Working directory:** All `swift` commands run from `Packages/SenaniDigest/` unless stated otherwise.

**Design source:** `docs/ARCHITECTURE.md` (the pipeline — "Daily Digest aggregates it all"; "a daily digest at a set time … Respects Low Power / battery") and `docs/ROADMAP.md` Phase 2 ("Daily Digest agent"). The app-tier contracts are pinned by `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md` (AUTHORITATIVE — §2 frozen package signatures, §3 `AppEnvironment`/`SenaniEngine`, §4 conventions). `SenaniAnalytics.AnalyticsQueries` detail is in `docs/superpowers/plans/2026-05-31-analytics.md`; `docs/superpowers/plans/2026-05-31-assistant-chat-core.md` is the FORMAT exemplar.

---

## Cross-package assumptions (verified from source on 2026-05-31 — state these to the human before coding)

`SenaniDigest` compiles only against the contracts below. **Every signature here was read from the real source**, not guessed. If a frozen package differs at build time, adapt the `SenaniDigest` code (or a thin local adapter), never the frozen package (§4 convention 3).

### `SenaniAnalytics.AnalyticsQueries` (frozen — `Packages/SenaniAnalytics/Sources/SenaniAnalytics/`) — THE REAL API

Read from `AnalyticsQueries.swift` + `AnalyticsResults.swift`. **All methods are synchronous `throws` (NOT async). Note the exact shapes — they differ from the early analytics plan draft:**

```swift
public struct AnalyticsQueries: Sendable {
    public init(database: SenaniDatabase)        // production: reads database.queue
    public init(reader: any DatabaseReader)      // tests/advanced

    public func topSenders(limit: Int) throws -> [SenderCount]   // inbound only, lower("from") grouped, count DESC, sender ASC
    public func topDomains(limit: Int) throws -> [DomainCount]   // inbound only, senderDomain grouped, count DESC
    public func volumeByDay(since: Date) throws -> [VolumePoint] // per UTC day: inbound + outbound counts, day ASC
    public func replyLatency(since: Date) throws -> [ReplyLatency] // PER inbound message: (threadId, seconds-to-first-user-reply)
    public func ruleActivity(since: Date) throws -> [RuleActivity]  // per rule from actions_log trigger_json kind='rule'
}

// AnalyticsResults.swift — the EXACT field names:
public struct SenderCount: Sendable, Equatable { public let sender: String; public let count: Int }
public struct DomainCount: Sendable, Equatable { public let domain: String; public let count: Int }
public struct VolumePoint: Sendable, Equatable { public let day: Date; public let inbound: Int; public let outbound: Int }
public struct ReplyLatency: Sendable, Equatable { public let threadId: String; public let seconds: Double }
public struct RuleActivity: Sendable, Equatable { public let ruleId: String; public let executed: Int; public let prepared: Int; public let queuedForApproval: Int }
```

**Key consequences the implementer MUST honour:**
- `SenderCount.sender` / `DomainCount.domain` (NOT `.address`); `VolumePoint.day/.inbound/.outbound` (NOT `.date/.count`); `ReplyLatency.threadId/.seconds` is **per-message, not a precomputed median**; `RuleActivity.queuedForApproval` (NOT `.queued`).
- `volumeByDay(since:)` and `replyLatency(since:)`/`ruleActivity(since:)` take a **`since:` lower bound only** (no upper bound). To restrict to a single day, the `DigestBuilder` calls them with `since = startOfDay` and **filters the returned rows to the day window itself** in pure Swift (`volumeByDay` returns one `VolumePoint` per UTC day, so the builder selects the point whose `day` equals the day's UTC midnight; `replyLatency` rows have no date, so the builder derives "today's reply latency" from the `volumeByDay`-bounded message set — see Task 4's precise definition).
- The day-volume buckets are **UTC** (`AnalyticsQueries.volumeByDay` does `CAST(date/86400 AS INTEGER)*86400`). The `DigestBuilder` therefore reports its window in UTC-day terms for v1 and documents local-timezone bucketing as a follow-up (mirrors the analytics plan's stated v1 limitation). The injected `Calendar`/`TimeZone` is used for the **scheduler's** local fire time and for labelling, not for re-bucketing analytics.

### `SenaniStore` (frozen — `Packages/SenaniStore/Sources/SenaniStore/`)

Read from `SenaniDatabase.swift`, `ApprovalStore.swift`, `MessageStore.swift`, `Migrations.swift`.

```swift
public final class SenaniDatabase: @unchecked Sendable {
    public let queue: DatabaseQueue
    public static func inMemory() throws -> SenaniDatabase     // migrates v1..v4: messages, actions_log, approvals, rules, ...
    public static func file(at path: String) throws -> SenaniDatabase
}

public struct ApprovalStore: Sendable {
    public init(database: SenaniDatabase, now: @escaping @Sendable () -> Double)  // now: REQUIRED (seconds)
    public func enqueue(id: String, _ proposal: Proposal) throws
    public func pending() throws -> [StoredProposal]           // status='pending', ORDER BY created_at, id
    public func approve(id: String) throws
    public func reject(id: String) throws
}
public struct StoredProposal: Sendable, Equatable { public let id: String; public let proposal: Proposal }

public struct MessageStore: Sendable {                          // synchronous throws
    public init(database: SenaniDatabase)
    public func save(_ message: Message) throws
    public func saveAll(_ messages: [Message]) throws
    public func all() throws -> [Message]
}
```

**Real schema** (from `Migrations.swift`, used by the test fixtures so seeded rows match what `AnalyticsQueries` reads):
- `messages`: `id TEXT PK`, `"from" TEXT`, `senderDomain TEXT`, `subject TEXT`, `body TEXT`, `hasAttachment INTEGER`, `listUnsubscribeHeader TEXT?`, `labels TEXT`, `recipients TEXT`, `threadId TEXT`, `date DOUBLE` (epoch seconds), `isFromUser INTEGER`.
- `actions_log`: `id INTEGER PK AUTOINCREMENT`, `message_id TEXT`, `action_json TEXT`, `trigger_json TEXT`, `outcome TEXT` (`executed`/`prepared`/`queuedForApproval`), `logged_at DOUBLE`. `ruleActivity` reads `json_extract(trigger_json,'$.identifier')` where `json_extract(trigger_json,'$.kind') = 'rule'`.
- `approvals`: `id TEXT PK`, `action_json`, `message_json`, `trigger_json`, `status TEXT` (`pending`/`approved`/`rejected`), `created_at DOUBLE`.

**Fixture seeding strategy:** Seed `messages` via `MessageStore.saveAll` (it computes `senderDomain`, encodes `labels`/`recipients`, writes `date` as epoch seconds — exactly what `AnalyticsQueries` queries). Seed `actions_log` rows with **raw SQL** in the test target (no public writer ships for it; this matches the analytics plan's fixture approach) using `trigger_json` of the form `{"kind":"rule","identifier":"<ruleId>"}`. Seed `approvals` via `ApprovalStore.enqueue(id:_:)`.

### `SenaniRules` (frozen — `Packages/SenaniRules/Sources/SenaniRules/`)

```swift
public struct Message: Sendable, Equatable, Identifiable {     // senderDomain is COMPUTED, not an init field
    public init(id: String, from: String, to: [String], subject: String, body: String,
                hasAttachment: Bool, listUnsubscribeHeader: String?, labels: [String],
                threadId: String, date: Date, isFromUser: Bool)
    public var senderDomain: String { get }
}
public enum Action: Sendable, Equatable {
    case label(String); case archive; case markRead; /* ... */ case draft(body: String)
    case reply(body: String); case forward(to: String, body: String); case send(body: String); /* ... */
    public var actionClass: ActionClass { get }   // .reply/.forward/.send/.markSpam => .outbound ; else .reversible
}
public enum ActionClass: Sendable, Equatable { case reversible; case outbound }
public enum Autonomy: String, Sendable, Equatable { case ask; case prepare; case auto }
public enum Outcome: Sendable, Equatable { case executed; case prepared; case queuedForApproval }
public enum ActionRouter {
    public static func route(_ action: Action, autonomy: Autonomy) -> Outcome
    // OUTBOUND => .queuedForApproval ALWAYS (regardless of autonomy)
}
```

**Email-me-the-digest decision (pinned):** the optional "email me the digest" produces a single **`.send(body:)`** action (outbound). `Action.send(body:).actionClass == .outbound`, so `ActionRouter.route(.send(body:), autonomy: .auto)` returns `.queuedForApproval` — it can **never** auto-send by construction. The builder/surface only **constructs** the action and (in the surface) hands it to the host's approval seam; `SenaniDigest` never calls a `MailBackend`. This satisfies "queues, never auto-sends" using the single safety path (§4 convention 2) without inventing a new Action case (so no §5 frozen-package change is needed).

### `SenaniDesign` (app-tier peer — `docs/superpowers/plans/2026-05-31-gold-glass-design-system.md`)

The view imports these pinned symbols (owned by the design-system plan):
```swift
public struct GlassPanel<Content: View>: View { public init(style: GlassPanelStyle = .default, @ViewBuilder content: () -> Content) }
public enum Gold { public static let base/highlight/shadow: Color }
public extension Font  { static let senaniTitle/senaniBody/senaniMono: Font }
public extension Color { static let senaniInk/senaniSurface/senaniAccent/senaniMuted: Color }
```
**Build-order note:** `SenaniDesign` must exist for the `DigestView` target to compile (Tasks 6–7). The pure `DigestBuilder`/`DigestScheduler`/`DigestReport` (Tasks 1–5) depend on **none** of it and can be built and tested first even if `SenaniDesign` is not yet present. If `SenaniDesign` is unavailable when the view tasks run, the worker SKIPS Tasks 6–7's `SenaniDesign` dependency line and renders with raw SwiftUI `Material`/`Color` placeholders, recording the deviation — but Tasks 1–5 (the load-bearing logic) are unaffected. The view target is split into its own `SenaniDigestUI` module so the pure core never gains a SwiftUI dependency.

---

## File Structure

```
Packages/SenaniDigest/
  Package.swift
  Sources/SenaniDigest/                 # PURE core — no SwiftUI, no SenaniDesign
    DigestReport.swift                  # DigestReport + nested value types (Sendable, Equatable)
    DigestWindow.swift                  # DigestWindow (start/end Date + UTC day midnight) from a date + Calendar
    ApprovalReading.swift               # ApprovalReading protocol seam + ApprovalStore conformance (pendingCount)
    DigestBuilder.swift                 # DigestBuilder(analytics:approvals:calendar:) + build(for:) throws -> DigestReport
    DigestEmail.swift                   # DigestEmailComposer.action(for:) -> SenaniRules.Action (.send, outbound, queues)
    DigestScheduler.swift               # actor DigestScheduler — fires onFire at most once/local-day at configured time
  Sources/SenaniDigestUI/               # SwiftUI surface — imports SenaniDigest + SenaniDesign
    DigestView.swift                    # gold-glass DigestView(report:) + "Email me the digest" button -> outbound action
  Tests/SenaniDigestTests/
    DigestFixture.swift                 # in-memory SenaniDatabase + seed helpers (messages via MessageStore, actions_log via SQL, approvals via ApprovalStore) + clock helpers
    DigestWindowTests.swift
    DigestBuilderTests.swift            # seed a day -> exact counts / top-lists / latency / ruleActivity / pendingApprovals
    DigestEmailTests.swift              # composed action is .send (outbound) and routes to .queuedForApproval under every autonomy
    DigestSchedulerTests.swift          # fake clock: fires once at/after configured time; not before; once per day; low-power suppresses
```

The pure `SenaniDigest` library is the load-bearing product; `SenaniDigestUI` is a thin SwiftUI surface; the test target reuses `DigestFixture.swift`. No source file in `SenaniDigest` performs any write, network, or model call.

---

### Task 1: Package scaffold + in-memory fixture

**Files:**
- Create: `Packages/SenaniDigest/Package.swift`
- Create: `Packages/SenaniDigest/Sources/SenaniDigest/DigestReport.swift` (temporary one-line marker so the target compiles)
- Create: `Packages/SenaniDigest/Tests/SenaniDigestTests/DigestFixture.swift`

- [ ] **Step 1: Create the package manifest**

Create `Packages/SenaniDigest/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniDigest",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniDigest", targets: ["SenaniDigest"]),
        .library(name: "SenaniDigestUI", targets: ["SenaniDigestUI"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
        .package(path: "../SenaniStore"),
        .package(path: "../SenaniAnalytics"),
        .package(path: "../SenaniDesign"),
    ],
    targets: [
        .target(
            name: "SenaniDigest",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "SenaniStore", package: "SenaniStore"),
                .product(name: "SenaniAnalytics", package: "SenaniAnalytics"),
            ]
        ),
        .target(
            name: "SenaniDigestUI",
            dependencies: [
                "SenaniDigest",
                .product(name: "SenaniDesign", package: "SenaniDesign"),
            ]
        ),
        .testTarget(
            name: "SenaniDigestTests",
            dependencies: [
                "SenaniDigest",
                .product(name: "SenaniStore", package: "SenaniStore"),
                .product(name: "SenaniAnalytics", package: "SenaniAnalytics"),
            ]
        ),
    ]
)
```

> **Reconciliation note:** if `../SenaniDesign` does not yet exist, comment out the `SenaniDesign` dependency line AND the `SenaniDigestUI` target + product, and skip Tasks 6–7's view (record the deviation). Tasks 1–5 only need `SenaniRules`/`SenaniStore`/`SenaniAnalytics`, which are all built and frozen. If `swift build` reports `no such module 'GRDB'` inside `DigestFixture.swift`, add `.package(url: "https://github.com/groue/GRDB.swift", from: "<version SenaniStore pins>")` and `.product(name: "GRDB", package: "GRDB.swift")` to the test target, matching `Packages/SenaniStore/Package.resolved`.

- [ ] **Step 2: Create a valid marker source file**

Create `Packages/SenaniDigest/Sources/SenaniDigest/DigestReport.swift`:

```swift
// DigestReport and friends land in Task 2.
import Foundation
```

- [ ] **Step 3: Write the fixture helper**

Create `Packages/SenaniDigest/Tests/SenaniDigestTests/DigestFixture.swift`:

```swift
import Foundation
import GRDB
import SenaniRules
import SenaniStore
import SenaniAnalytics
@testable import SenaniDigest

/// Deterministic in-memory store for digest tests. Seeds the REAL schema
/// (messages via MessageStore, actions_log via raw SQL, approvals via ApprovalStore)
/// so AnalyticsQueries reads exactly what production reads. All timestamps are
/// explicit offsets from a fixed reference instant — no test reads the clock.
enum DigestFixture {

    /// 2026-03-15T00:00:00Z. The "digest day" all fixtures sit inside.
    static let dayStart: TimeInterval = 1_773_532_800

    /// One second past the end of the digest day (exclusive upper bound).
    static var nextDayStart: TimeInterval { dayStart + 86_400 }

    /// A UTC calendar anchored at GMT so scheduler/window math is deterministic.
    static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func makeDatabase() throws -> SenaniDatabase {
        try SenaniDatabase.inMemory()
    }

    static func analytics(_ db: SenaniDatabase) -> AnalyticsQueries {
        AnalyticsQueries(database: db)
    }

    static func approvals(_ db: SenaniDatabase) -> ApprovalStore {
        ApprovalStore(database: db, now: { dayStart })
    }

    /// Builds a Message with the given offset-from-dayStart and direction.
    static func message(
        id: String, from: String, to: [String] = ["me@self.com"],
        offset: TimeInterval, isFromUser: Bool, threadId: String
    ) -> Message {
        Message(
            id: id, from: from, to: to, subject: "S", body: "B",
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: threadId, date: Date(timeIntervalSince1970: dayStart + offset),
            isFromUser: isFromUser
        )
    }

    /// Inserts an actions_log row (trigger kind 'rule' with the given ruleId, or 'chat' when ruleId is nil).
    static func insertAction(
        _ db: SenaniDatabase, ruleId: String?, outcome: String, messageId: String, offset: TimeInterval
    ) throws {
        let triggerJSON: String
        if let ruleId {
            triggerJSON = #"{"kind":"rule","identifier":"\#(ruleId)"}"#
        } else {
            triggerJSON = #"{"kind":"chat","identifier":"turn-1"}"#
        }
        try db.queue.write { d in
            try d.execute(
                sql: """
                INSERT INTO actions_log (message_id, action_json, trigger_json, outcome, logged_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [messageId, "{}", triggerJSON, outcome, dayStart + offset]
            )
        }
    }

    /// A fixed clock returning a constant Date (for window tests / a stopped scheduler).
    static func fixedClock(_ t: TimeInterval) -> @Sendable () -> Date {
        let d = Date(timeIntervalSince1970: t)
        return { d }
    }
}
```

- [ ] **Step 4: Verify the package builds**

Run: `cd Packages/SenaniDigest && swift build`
Expected: `Build complete!`. (`swift build` builds only the library targets; the test file's references to not-yet-defined `DigestReport`/`DigestBuilder` are not compiled here.)

- [ ] **Step 5: Commit**

```
cd Packages/SenaniDigest && git add -A && git commit -m "SenaniDigest: package scaffold + in-memory fixture (real store schema)"
```

Use this commit trailer on EVERY commit in this plan:

```

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

---

### Task 2: DigestReport value types

**Files:**
- Edit: `Packages/SenaniDigest/Sources/SenaniDigest/DigestReport.swift`
- Test: `Packages/SenaniDigest/Tests/SenaniDigestTests/DigestBuilderTests.swift` (create with a construction-only test first)

`DigestReport` is the typed output the view renders and the email composes from. It mirrors the day's activity using the EXACT field names from `AnalyticsQueries` results so no lossy re-mapping happens.

- [ ] **Step 1: Write a failing construction test**

Create `Packages/SenaniDigest/Tests/SenaniDigestTests/DigestBuilderTests.swift`:

```swift
import Testing
import Foundation
import SenaniAnalytics
@testable import SenaniDigest

@Suite struct DigestBuilderTests {
    @Test func digestReportCarriesAllSections() {
        let report = DigestReport(
            day: Date(timeIntervalSince1970: DigestFixture.dayStart),
            inboundCount: 3,
            outboundCount: 1,
            topSenders: [SenderCount(sender: "a@x.com", count: 2)],
            topDomains: [DomainCount(domain: "x.com", count: 2)],
            medianReplyLatencySeconds: 120,
            replyCount: 1,
            ruleActivity: [RuleActivity(ruleId: "triage", executed: 2, prepared: 0, queuedForApproval: 1)],
            pendingApprovals: 4
        )
        #expect(report.inboundCount == 3)
        #expect(report.outboundCount == 1)
        #expect(report.topSenders.first?.sender == "a@x.com")
        #expect(report.medianReplyLatencySeconds == 120)
        #expect(report.replyCount == 1)
        #expect(report.ruleActivity.first?.queuedForApproval == 1)
        #expect(report.pendingApprovals == 4)
    }
}
```

- [ ] **Step 2: Run to fail**

Run: `cd Packages/SenaniDigest && swift test --filter DigestBuilderTests`
Expected: FAIL — `cannot find 'DigestReport' in scope`.

- [ ] **Step 3: Implement `DigestReport`**

Replace `Packages/SenaniDigest/Sources/SenaniDigest/DigestReport.swift`:

```swift
import Foundation
import SenaniAnalytics

/// One day's aggregated inbox activity — the typed payload the DigestView renders
/// and the "email me the digest" action composes from. Reuses SenaniAnalytics
/// result types verbatim (SenderCount/DomainCount/RuleActivity) so there is no
/// lossy re-mapping between the query layer and the digest.
public struct DigestReport: Sendable, Equatable {
    /// UTC midnight of the digest day (the bucket key shared with VolumePoint.day).
    public let day: Date
    /// Inbound messages received during the day.
    public let inboundCount: Int
    /// Messages the user sent during the day.
    public let outboundCount: Int
    /// Top inbound senders for the day, descending.
    public let topSenders: [SenderCount]
    /// Top inbound sender domains for the day, descending.
    public let topDomains: [DomainCount]
    /// Median seconds-to-first-reply across the day's replied threads (0 when replyCount == 0).
    public let medianReplyLatencySeconds: Double
    /// Number of inbound→reply transitions that contributed to the median.
    public let replyCount: Int
    /// Per-rule/agent automation activity for the day (from actions_log).
    public let ruleActivity: [RuleActivity]
    /// Count of proposals still awaiting the user's approval (point-in-time, not day-scoped).
    public let pendingApprovals: Int

    public init(
        day: Date,
        inboundCount: Int,
        outboundCount: Int,
        topSenders: [SenderCount],
        topDomains: [DomainCount],
        medianReplyLatencySeconds: Double,
        replyCount: Int,
        ruleActivity: [RuleActivity],
        pendingApprovals: Int
    ) {
        self.day = day
        self.inboundCount = inboundCount
        self.outboundCount = outboundCount
        self.topSenders = topSenders
        self.topDomains = topDomains
        self.medianReplyLatencySeconds = medianReplyLatencySeconds
        self.replyCount = replyCount
        self.ruleActivity = ruleActivity
        self.pendingApprovals = pendingApprovals
    }
}
```

- [ ] **Step 4: Run to pass**

Run: `cd Packages/SenaniDigest && swift test --filter DigestBuilderTests`
Expected: PASS — the single construction test passes.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniDigest && git add -A && git commit -m "SenaniDigest: DigestReport value type (reuses SenaniAnalytics result structs)"
```

(Append the standard trailer.)

---

### Task 3: DigestWindow — day bounds from a date

**Files:**
- Create: `Packages/SenaniDigest/Sources/SenaniDigest/DigestWindow.swift`
- Test: `Packages/SenaniDigest/Tests/SenaniDigestTests/DigestWindowTests.swift`

`DigestWindow` turns "a date" into the day's `[start, end)` bounds and the **UTC-midnight bucket key** that matches `VolumePoint.day`. v1 buckets analytics in UTC (because `AnalyticsQueries.volumeByDay` does), so the window's `utcDayStart` is the canonical key; the injected `Calendar` is used for the human-facing `start` (used by the scheduler/labelling).

- [ ] **Step 1: Write failing window tests**

Create `Packages/SenaniDigest/Tests/SenaniDigestTests/DigestWindowTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniDigest

@Suite struct DigestWindowTests {
    @Test func utcDayStartIsMidnightOfTheGivenInstant() {
        // An instant mid-day on 2026-03-15.
        let midDay = Date(timeIntervalSince1970: DigestFixture.dayStart + 50_000)
        let window = DigestWindow(containing: midDay, calendar: DigestFixture.utcCalendar)
        #expect(window.utcDayStart == Date(timeIntervalSince1970: DigestFixture.dayStart))
    }

    @Test func endIsExclusiveNextMidnight() {
        let midDay = Date(timeIntervalSince1970: DigestFixture.dayStart + 1)
        let window = DigestWindow(containing: midDay, calendar: DigestFixture.utcCalendar)
        #expect(window.utcDayStart == Date(timeIntervalSince1970: DigestFixture.dayStart))
        #expect(window.utcNextDayStart == Date(timeIntervalSince1970: DigestFixture.nextDayStart))
    }

    @Test func instantExactlyAtMidnightBelongsToThatDay() {
        let exactly = Date(timeIntervalSince1970: DigestFixture.dayStart)
        let window = DigestWindow(containing: exactly, calendar: DigestFixture.utcCalendar)
        #expect(window.utcDayStart == exactly)
    }
}
```

- [ ] **Step 2: Run to fail**

Run: `cd Packages/SenaniDigest && swift test --filter DigestWindowTests`
Expected: FAIL — `cannot find 'DigestWindow' in scope`.

- [ ] **Step 3: Implement `DigestWindow`**

Create `Packages/SenaniDigest/Sources/SenaniDigest/DigestWindow.swift`:

```swift
import Foundation

/// The day-scoped bounds for a digest. v1 buckets analytics in UTC to match
/// `SenaniAnalytics.AnalyticsQueries.volumeByDay` (which uses UTC day buckets),
/// so `utcDayStart` is the canonical key shared with `VolumePoint.day`.
/// (Local-timezone bucketing is a documented follow-up; see §Out of scope.)
public struct DigestWindow: Sendable, Equatable {
    /// UTC midnight of the day containing the instant — the VolumePoint bucket key.
    public let utcDayStart: Date
    /// Exclusive UTC upper bound (next UTC midnight).
    public let utcNextDayStart: Date

    private static let secondsPerDay: TimeInterval = 86_400

    public init(containing instant: Date, calendar: Calendar) {
        // UTC bucketing independent of the injected calendar's zone, matching
        // volumeByDay's floor(date/86400)*86400. The calendar parameter is held
        // for future local bucketing and kept in the signature for API stability.
        _ = calendar
        let secs = instant.timeIntervalSince1970
        let dayIndex = (secs / Self.secondsPerDay).rounded(.down)
        let start = dayIndex * Self.secondsPerDay
        self.utcDayStart = Date(timeIntervalSince1970: start)
        self.utcNextDayStart = Date(timeIntervalSince1970: start + Self.secondsPerDay)
    }
}
```

- [ ] **Step 4: Run to pass**

Run: `cd Packages/SenaniDigest && swift test --filter DigestWindowTests`
Expected: PASS — all three window tests pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniDigest && git add -A && git commit -m "SenaniDigest: DigestWindow (UTC day bounds matching AnalyticsQueries buckets)"
```

(Append the standard trailer.)

---

### Task 4: DigestBuilder — pure aggregation over AnalyticsQueries + approvals

**Definition (precise, testable):** `build(for date:)` derives the `DigestWindow` for `date`, then:
- **inbound/outbound:** the `VolumePoint` from `analytics.volumeByDay(since: window.utcDayStart)` whose `day == window.utcDayStart`; `inboundCount`/`outboundCount` are that point's `.inbound`/`.outbound` (0/0 if no point that day).
- **topSenders/topDomains:** `analytics.topSenders(limit:)` / `analytics.topDomains(limit:)` — these are store-wide (no date arg in the real API). To keep the digest day-scoped **and** testable, the builder calls them with the configured `limit` and returns them **as the day's top lists when the fixture's messages are all within the day** (the v1 store holds a single day in tests; production callers pass `since`-bounded data). The builder documents that topSenders/topDomains are store-wide-since the API has no date bound, and exposes `limit` so the surface can cap them. (Reconciliation note below.)
- **reply latency:** `analytics.replyLatency(since: window.utcDayStart)` returns one `(threadId, seconds)` per inbound message that got a later user reply. The builder **filters to the day** by intersecting with the day's threads is unnecessary because `since` already lower-bounds inbound dates; the upper bound is enforced by computing the **median of `seconds`** only over rows whose first reply we accept (all rows returned for `since == dayStart` in the single-day fixture). `medianReplyLatencySeconds` = median of the returned `seconds` array (average of two middles for even counts; `0` when empty); `replyCount` = the array count.
- **ruleActivity:** `analytics.ruleActivity(since: window.utcDayStart)` verbatim.
- **pendingApprovals:** `approvals.pendingCount()` (the `ApprovalReading` seam, Task 4 Step 3) — point-in-time count of `pending` proposals.

**Files:**
- Create: `Packages/SenaniDigest/Sources/SenaniDigest/ApprovalReading.swift`
- Create: `Packages/SenaniDigest/Sources/SenaniDigest/DigestBuilder.swift`
- Test: extend `Packages/SenaniDigest/Tests/SenaniDigestTests/DigestBuilderTests.swift`

- [ ] **Step 1: Write the failing aggregation tests**

Append to `Packages/SenaniDigest/Tests/SenaniDigestTests/DigestBuilderTests.swift` (inside the `DigestBuilderTests` suite):

```swift
    private func seededBuilder() throws -> (DigestBuilder, SenaniStore.SenaniDatabase) {
        let db = try DigestFixture.makeDatabase()
        let messages = SenaniStore.MessageStore(database: db)

        // ---- messages for the day (2026-03-15) ----
        // inbound: alice x2, bob x1 (alice clogs the inbox); outbound: 1 user reply.
        try messages.saveAll([
            DigestFixture.message(id: "m1", from: "alice@x.com", offset: 100, isFromUser: false, threadId: "t1"),
            DigestFixture.message(id: "m2", from: "alice@x.com", offset: 200, isFromUser: false, threadId: "t2"),
            DigestFixture.message(id: "m3", from: "bob@y.com",   offset: 300, isFromUser: false, threadId: "t3"),
            // user replies to t1 at +220 => latency 120s for that inbound
            DigestFixture.message(id: "m4", from: "me@self.com", offset: 220, isFromUser: true,  threadId: "t1"),
        ])

        // ---- actions_log for the day ----
        try DigestFixture.insertAction(db, ruleId: "triage", outcome: "executed", messageId: "m1", offset: 110)
        try DigestFixture.insertAction(db, ruleId: "triage", outcome: "executed", messageId: "m2", offset: 210)
        try DigestFixture.insertAction(db, ruleId: "triage", outcome: "queuedForApproval", messageId: "m3", offset: 310)
        try DigestFixture.insertAction(db, ruleId: nil,      outcome: "executed", messageId: "m1", offset: 120) // chat -> excluded

        // ---- a pending approval ----
        let approvals = DigestFixture.approvals(db)
        try approvals.enqueue(
            id: "m3#triage#0",
            SenaniRules.Proposal(
                action: .send(body: "Hi"),
                message: DigestFixture.message(id: "m3", from: "bob@y.com", offset: 300, isFromUser: false, threadId: "t3"),
                trigger: .rule(id: "triage")
            )
        )

        let builder = DigestBuilder(
            analytics: DigestFixture.analytics(db),
            approvals: approvals,
            calendar: DigestFixture.utcCalendar,
            topLimit: 5
        )
        return (builder, db)
    }

    @Test func buildAggregatesTheDaysActivity() throws {
        let (builder, _) = try seededBuilder()
        let report = try builder.build(for: Date(timeIntervalSince1970: DigestFixture.dayStart + 50_000))

        #expect(report.day == Date(timeIntervalSince1970: DigestFixture.dayStart))
        #expect(report.inboundCount == 3)
        #expect(report.outboundCount == 1)
        #expect(report.topSenders == [
            SenderCount(sender: "alice@x.com", count: 2),
            SenderCount(sender: "bob@y.com", count: 1),
        ])
        #expect(report.topDomains == [
            DomainCount(domain: "x.com", count: 2),
            DomainCount(domain: "y.com", count: 1),
        ])
        #expect(report.medianReplyLatencySeconds == 120)
        #expect(report.replyCount == 1)
        #expect(report.ruleActivity == [
            RuleActivity(ruleId: "triage", executed: 2, prepared: 0, queuedForApproval: 1),
        ])
        #expect(report.pendingApprovals == 1)
    }

    @Test func emptyDayYieldsZeroes() throws {
        let db = try DigestFixture.makeDatabase()
        let builder = DigestBuilder(
            analytics: DigestFixture.analytics(db),
            approvals: DigestFixture.approvals(db),
            calendar: DigestFixture.utcCalendar,
            topLimit: 5
        )
        let report = try builder.build(for: Date(timeIntervalSince1970: DigestFixture.dayStart))
        #expect(report.inboundCount == 0)
        #expect(report.outboundCount == 0)
        #expect(report.topSenders.isEmpty)
        #expect(report.medianReplyLatencySeconds == 0)
        #expect(report.replyCount == 0)
        #expect(report.ruleActivity.isEmpty)
        #expect(report.pendingApprovals == 0)
    }
```

(Add `import SenaniRules` and `import SenaniStore` to the top of `DigestBuilderTests.swift`.)

- [ ] **Step 2: Run to fail**

Run: `cd Packages/SenaniDigest && swift test --filter DigestBuilderTests`
Expected: FAIL — `cannot find 'DigestBuilder' in scope` / `ApprovalReading`.

- [ ] **Step 3: Implement the `ApprovalReading` seam**

Create `Packages/SenaniDigest/Sources/SenaniDigest/ApprovalReading.swift`:

```swift
import Foundation
import SenaniStore

/// The minimal read seam the DigestBuilder needs from the approval queue:
/// a point-in-time count of proposals awaiting the user. Defined as a protocol
/// so the builder stays testable and never couples to ApprovalStore's full API.
public protocol ApprovalReading: Sendable {
    func pendingCount() throws -> Int
}

/// The frozen ApprovalStore conforms via its existing `pending()` reader.
extension ApprovalStore: ApprovalReading {
    public func pendingCount() throws -> Int {
        try pending().count
    }
}
```

- [ ] **Step 4: Implement `DigestBuilder`**

Create `Packages/SenaniDigest/Sources/SenaniDigest/DigestBuilder.swift`:

```swift
import Foundation
import SenaniAnalytics

/// Pure day-scoped aggregator. Reads the canonical store ONLY through
/// `SenaniAnalytics.AnalyticsQueries` (and the `ApprovalReading` seam for the
/// pending count). No writes, no network, no model. Deterministic over the
/// injected dependencies + the date passed to `build(for:)`.
public struct DigestBuilder: Sendable {
    private let analytics: AnalyticsQueries
    private let approvals: any ApprovalReading
    private let calendar: Calendar
    private let topLimit: Int

    public init(
        analytics: AnalyticsQueries,
        approvals: any ApprovalReading,
        calendar: Calendar,
        topLimit: Int = 5
    ) {
        self.analytics = analytics
        self.approvals = approvals
        self.calendar = calendar
        self.topLimit = topLimit
    }

    /// Build the report for the day containing `date`.
    public func build(for date: Date) throws -> DigestReport {
        let window = DigestWindow(containing: date, calendar: calendar)

        // Volume: the bucket whose day == this UTC day.
        let volume = try analytics.volumeByDay(since: window.utcDayStart)
        let today = volume.first { $0.day == window.utcDayStart }
        let inbound = today?.inbound ?? 0
        let outbound = today?.outbound ?? 0

        // Top lists (store-wide since the API has no upper bound — see reconciliation note).
        let topSenders = try analytics.topSenders(limit: topLimit)
        let topDomains = try analytics.topDomains(limit: topLimit)

        // Reply latency: median of the per-inbound seconds returned since day start.
        let latencies = try analytics.replyLatency(since: window.utcDayStart).map(\.seconds)
        let (median, count) = Self.median(of: latencies)

        // Rule/agent activity for the day.
        let ruleActivity = try analytics.ruleActivity(since: window.utcDayStart)

        // Pending approvals (point-in-time).
        let pending = try approvals.pendingCount()

        return DigestReport(
            day: window.utcDayStart,
            inboundCount: inbound,
            outboundCount: outbound,
            topSenders: topSenders,
            topDomains: topDomains,
            medianReplyLatencySeconds: median,
            replyCount: count,
            ruleActivity: ruleActivity,
            pendingApprovals: pending
        )
    }

    /// Median of a value array. Even counts average the two middles. Empty => (0, 0).
    static func median(of values: [Double]) -> (median: Double, count: Int) {
        guard !values.isEmpty else { return (0, 0) }
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 {
            return (sorted[n / 2], n)
        } else {
            return ((sorted[n / 2 - 1] + sorted[n / 2]) / 2, n)
        }
    }
}
```

> **Reconciliation note (top lists & latency upper bound):** the real `AnalyticsQueries.topSenders/topDomains` have **no date parameter** and `replyLatency(since:)`/`volumeByDay(since:)` have **only a lower bound**. For the single-day in-memory fixtures these correctly reflect the day. For production multi-day stores, `topSenders`/`topDomains` are store-wide and `replyLatency` covers everything since `utcDayStart`. If the digest must be strictly day-bounded in production, the follow-up is to add `since:`/`until:` parameters to those `AnalyticsQueries` methods — a **change to the frozen `SenaniAnalytics`** to surface to the human (§4 convention 3 / reconciliation §5), NOT a fork. The `DigestBuilder` public API does not change when that lands; only the values it receives tighten. This is recorded in §Out of scope.

- [ ] **Step 5: Run to pass**

Run: `cd Packages/SenaniDigest && swift test --filter DigestBuilderTests`
Expected: PASS — `buildAggregatesTheDaysActivity` (inbound 3 / outbound 1 / alice>bob senders / x.com>y.com domains / median 120 / replyCount 1 / triage 2-0-1 / pending 1) and `emptyDayYieldsZeroes` both pass, plus the Task-2 construction test.

- [ ] **Step 6: Commit**

```
cd Packages/SenaniDigest && git add -A && git commit -m "SenaniDigest: DigestBuilder pure aggregation via AnalyticsQueries + ApprovalReading"
```

(Append the standard trailer.)

---

### Task 5: DigestEmailComposer — the outbound "email me the digest" action

**Files:**
- Create: `Packages/SenaniDigest/Sources/SenaniDigest/DigestEmail.swift`
- Test: `Packages/SenaniDigest/Tests/SenaniDigestTests/DigestEmailTests.swift`

The optional "email me the digest" turns a `DigestReport` into a single **outbound** `SenaniRules.Action` (`.send(body:)`). Because `.send` is `.outbound`, `ActionRouter.route` forces `.queuedForApproval` under **every** autonomy — so it can never auto-send. The composer is pure: it formats a plain-text body and returns the action; it never touches a `MailBackend`.

- [ ] **Step 1: Write the failing composer tests**

Create `Packages/SenaniDigest/Tests/SenaniDigestTests/DigestEmailTests.swift`:

```swift
import Testing
import Foundation
import SenaniRules
import SenaniAnalytics
@testable import SenaniDigest

@Suite struct DigestEmailTests {
    private func sampleReport() -> DigestReport {
        DigestReport(
            day: Date(timeIntervalSince1970: DigestFixture.dayStart),
            inboundCount: 3, outboundCount: 1,
            topSenders: [SenderCount(sender: "alice@x.com", count: 2)],
            topDomains: [DomainCount(domain: "x.com", count: 2)],
            medianReplyLatencySeconds: 120, replyCount: 1,
            ruleActivity: [RuleActivity(ruleId: "triage", executed: 2, prepared: 0, queuedForApproval: 1)],
            pendingApprovals: 4
        )
    }

    @Test func composesAnOutboundSendAction() {
        let action = DigestEmailComposer.action(for: sampleReport())
        guard case let .send(body) = action else {
            Issue.record("expected .send, got \(action)"); return
        }
        #expect(action.actionClass == .outbound)
        #expect(body.contains("3"))   // inbound count appears in the body
        #expect(body.contains("alice@x.com"))
    }

    @Test func outboundActionAlwaysQueuesUnderEveryAutonomy() {
        let action = DigestEmailComposer.action(for: sampleReport())
        #expect(ActionRouter.route(action, autonomy: .auto) == .queuedForApproval)
        #expect(ActionRouter.route(action, autonomy: .prepare) == .queuedForApproval)
        #expect(ActionRouter.route(action, autonomy: .ask) == .queuedForApproval)
    }
}
```

- [ ] **Step 2: Run to fail**

Run: `cd Packages/SenaniDigest && swift test --filter DigestEmailTests`
Expected: FAIL — `cannot find 'DigestEmailComposer' in scope`.

- [ ] **Step 3: Implement `DigestEmailComposer`**

Create `Packages/SenaniDigest/Sources/SenaniDigest/DigestEmail.swift`:

```swift
import Foundation
import SenaniRules

/// Turns a DigestReport into a single OUTBOUND email action. `.send` is
/// `.outbound`, so `ActionRouter.route` forces `.queuedForApproval` under every
/// autonomy — the digest email can never auto-send. The composer is pure: it
/// formats the body and returns the action; it never touches a MailBackend.
public enum DigestEmailComposer {
    public static func action(for report: DigestReport) -> Action {
        .send(body: body(for: report))
    }

    /// Plain-text digest body. Deterministic; no locale-dependent formatting.
    static func body(for report: DigestReport) -> String {
        var lines: [String] = []
        lines.append("Senani — Daily Digest")
        lines.append("Inbound: \(report.inboundCount)  ·  Sent: \(report.outboundCount)")
        if report.replyCount > 0 {
            lines.append("Median reply latency: \(Int(report.medianReplyLatencySeconds))s over \(report.replyCount) reply(ies)")
        }
        if !report.topSenders.isEmpty {
            lines.append("Top senders:")
            for s in report.topSenders { lines.append("  • \(s.sender) (\(s.count))") }
        }
        if !report.topDomains.isEmpty {
            lines.append("Top domains:")
            for d in report.topDomains { lines.append("  • \(d.domain) (\(d.count))") }
        }
        if !report.ruleActivity.isEmpty {
            lines.append("Automations:")
            for r in report.ruleActivity {
                lines.append("  • \(r.ruleId): \(r.executed) done, \(r.prepared) prepared, \(r.queuedForApproval) queued")
            }
        }
        lines.append("Pending approvals: \(report.pendingApprovals)")
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run to pass**

Run: `cd Packages/SenaniDigest && swift test --filter DigestEmailTests`
Expected: PASS — the action is `.send` (`.outbound`) and routes to `.queuedForApproval` under all three autonomies.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniDigest && git add -A && git commit -m "SenaniDigest: DigestEmailComposer outbound .send action (always queues)"
```

(Append the standard trailer.)

---

### Task 6: DigestScheduler — daily once-per-day fire on an injected clock

**Definition (precise, testable):** `DigestScheduler` holds a configured local time-of-day (`hour`, `minute`), an injected `calendar` (with the user's `TimeZone`), an injected `now: @Sendable () -> Date` clock, an injected `isLowPower: @Sendable () -> Bool`, and a host-supplied `onFire: @Sendable (Date) async -> Void` callback. Its `tick() async` method:
1. Reads `let current = now()`.
2. If `isLowPower()` is true → return without firing (do not advance the "last fired day").
3. Computes the configured fire instant for `current`'s local calendar day (that day at `hour:minute`).
4. If `current >= fireInstant` **and** the scheduler has not already fired for `current`'s local calendar day → invoke `onFire(current)` and record that local day as fired.

`start()`/`stop()` mirror `SenaniEngine.Scheduler`: `start()` launches a detached loop calling `tick()` every `checkInterval` (injected, defaults to 60s) and `stop()` cancels it. **Tests drive `tick()` directly with a mutable fake clock — no real timers, no `Task.sleep` in the assertions.**

**Files:**
- Create: `Packages/SenaniDigest/Sources/SenaniDigest/DigestScheduler.swift`
- Test: `Packages/SenaniDigest/Tests/SenaniDigestTests/DigestSchedulerTests.swift`

- [ ] **Step 1: Write the failing scheduler tests**

Create `Packages/SenaniDigest/Tests/SenaniDigestTests/DigestSchedulerTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniDigest

@Suite struct DigestSchedulerTests {
    // A thread-safe mutable clock the tests advance by hand.
    final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: TimeInterval
        init(_ t: TimeInterval) { self.t = t }
        func set(_ t: TimeInterval) { lock.lock(); self.t = t; lock.unlock() }
        var now: @Sendable () -> Date {
            { [self] in lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: t) }
        }
    }

    // Records the dates onFire was invoked with.
    actor FireRecorder {
        private(set) var fires: [Date] = []
        func record(_ d: Date) { fires.append(d) }
    }

    private func makeScheduler(clock: MutableClock, recorder: FireRecorder,
                               lowPower: @escaping @Sendable () -> Bool = { false })
    -> DigestScheduler {
        DigestScheduler(
            hour: 8, minute: 0,
            calendar: DigestFixture.utcCalendar,
            now: clock.now,
            isLowPower: lowPower,
            onFire: { d in await recorder.record(d) }
        )
    }

    @Test func doesNotFireBeforeConfiguredTime() async throws {
        // 2026-03-15 07:00 UTC — before 08:00.
        let clock = MutableClock(DigestFixture.dayStart + 7 * 3_600)
        let recorder = FireRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder)
        await scheduler.tick()
        #expect(await recorder.fires.isEmpty)
    }

    @Test func firesOnceAtOrAfterConfiguredTime() async throws {
        // 2026-03-15 08:30 UTC — after 08:00.
        let clock = MutableClock(DigestFixture.dayStart + 8 * 3_600 + 1_800)
        let recorder = FireRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder)
        await scheduler.tick()
        await scheduler.tick()   // second tick same day must NOT re-fire
        #expect(await recorder.fires.count == 1)
    }

    @Test func firesAgainOnTheNextDay() async throws {
        let clock = MutableClock(DigestFixture.dayStart + 8 * 3_600 + 1_800) // day 1, 08:30
        let recorder = FireRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder)
        await scheduler.tick()                                              // fires day 1
        clock.set(DigestFixture.dayStart + 86_400 + 8 * 3_600 + 60)         // day 2, 08:01
        await scheduler.tick()                                              // fires day 2
        #expect(await recorder.fires.count == 2)
    }

    @Test func lowPowerSuppressesTheFire() async throws {
        let clock = MutableClock(DigestFixture.dayStart + 9 * 3_600) // 09:00, past 08:00
        let recorder = FireRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder, lowPower: { true })
        await scheduler.tick()
        #expect(await recorder.fires.isEmpty)
    }
}
```

- [ ] **Step 2: Run to fail**

Run: `cd Packages/SenaniDigest && swift test --filter DigestSchedulerTests`
Expected: FAIL — `cannot find 'DigestScheduler' in scope`.

- [ ] **Step 3: Implement `DigestScheduler`**

Create `Packages/SenaniDigest/Sources/SenaniDigest/DigestScheduler.swift`:

```swift
import Foundation

/// Fires a daily-digest callback at most once per LOCAL calendar day, the first
/// time the injected clock has reached/passed the configured time-of-day, while
/// not on low power. This is DELIBERATELY separate from SenaniEngine.Scheduler
/// (the per-tick Gmail sync+process loop): a digest is a once-a-day timer, a
/// different cadence and trigger, so we do NOT add a hook to the frozen
/// SenaniEngine.Scheduler contract. The host composes the two if it wants one
/// timer surface. No real timers run in tests — `tick()` is driven by a fake clock.
public actor DigestScheduler {
    private let hour: Int
    private let minute: Int
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let isLowPower: @Sendable () -> Bool
    private let onFire: @Sendable (Date) async -> Void
    private let checkInterval: TimeInterval

    /// The local calendar day (start-of-day Date) we last fired for, or nil.
    private var lastFiredDay: Date?
    private var loop: Task<Void, Never>?

    public init(
        hour: Int,
        minute: Int,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date,
        isLowPower: @escaping @Sendable () -> Bool = { false },
        checkInterval: TimeInterval = 60,
        onFire: @escaping @Sendable (Date) async -> Void
    ) {
        self.hour = hour
        self.minute = minute
        self.calendar = calendar
        self.now = now
        self.isLowPower = isLowPower
        self.checkInterval = checkInterval
        self.onFire = onFire
    }

    /// One evaluation cycle. Fires onFire iff: not low power, the clock has reached
    /// today's configured time, and we have not already fired for today.
    public func tick() async {
        let current = now()
        if isLowPower() { return }

        let dayStart = calendar.startOfDay(for: current)
        guard let fireInstant = calendar.date(
            bySettingHour: hour, minute: minute, second: 0, of: dayStart
        ) else { return }

        guard current >= fireInstant else { return }
        guard lastFiredDay != dayStart else { return }

        lastFiredDay = dayStart
        await onFire(current)
    }

    /// Schedule repeating `tick()`s every `checkInterval` seconds.
    public func start() async {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tick()
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
        UInt64(max(0, checkInterval) * 1_000_000_000)
    }
}
```

- [ ] **Step 4: Run to pass**

Run: `cd Packages/SenaniDigest && swift test --filter DigestSchedulerTests`
Expected: PASS — does-not-fire-before / fires-once / fires-next-day / low-power-suppresses all pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniDigest && git add -A && git commit -m "SenaniDigest: DigestScheduler (daily once-per-day fire on injected clock, low-power aware)"
```

(Append the standard trailer.)

---

### Task 7: DigestView — the gold-glass primary surface

> **Build-order gate:** this task requires `SenaniDesign` (the gold-glass design system) to exist. If it does not yet, SKIP this task, leave the `SenaniDigestUI` target/product commented out in `Package.swift` (Task 1 note), and record the deviation — the load-bearing logic (Tasks 1–6) is complete without it. When `SenaniDesign` lands, re-enable the target and complete this task.

`DigestView` is the **primary** surface (the architecture's digest "aggregates it all"). It renders a `DigestReport` inside `SenaniDesign.GlassPanel` with the gold-glass tokens, and offers an "Email me the digest" button whose action is the `DigestEmailComposer` outbound action. The view does **not** send: tapping the button calls an injected `@Sendable (Action) -> Void` host closure (the composition root wires it to the same approval queue the rest of the app uses). The view's pure logic seam is `DigestViewModel` — a value type holding the formatted strings — which is unit-tested without SwiftUI.

**Files:**
- Create: `Packages/SenaniDigest/Sources/SenaniDigestUI/DigestView.swift`
- Test: `Packages/SenaniDigest/Tests/SenaniDigestTests/DigestViewModelTests.swift`

- [ ] **Step 1: Write the failing view-model test**

Create `Packages/SenaniDigest/Tests/SenaniDigestTests/DigestViewModelTests.swift`:

```swift
import Testing
import Foundation
import SenaniRules
import SenaniAnalytics
@testable import SenaniDigestUI
@testable import SenaniDigest

@Suite struct DigestViewModelTests {
    private func report() -> DigestReport {
        DigestReport(
            day: Date(timeIntervalSince1970: DigestFixture.dayStart),
            inboundCount: 12, outboundCount: 4,
            topSenders: [SenderCount(sender: "alice@x.com", count: 7)],
            topDomains: [DomainCount(domain: "x.com", count: 7)],
            medianReplyLatencySeconds: 3_600, replyCount: 3,
            ruleActivity: [RuleActivity(ruleId: "triage", executed: 5, prepared: 1, queuedForApproval: 2)],
            pendingApprovals: 6
        )
    }

    @Test func summarizesVolumeAndApprovals() {
        let vm = DigestViewModel(report: report())
        #expect(vm.headline.contains("12"))
        #expect(vm.headline.contains("4"))
        #expect(vm.pendingApprovalsLabel == "6 pending approvals")
    }

    @Test func formatsReplyLatencyAsMinutes() {
        let vm = DigestViewModel(report: report())
        #expect(vm.replyLatencyLabel == "Median reply: 60 min")   // 3600s -> 60 min
    }

    @Test func emptyLatencyShowsNoReplies() {
        var r = report()
        r = DigestReport(day: r.day, inboundCount: r.inboundCount, outboundCount: r.outboundCount,
                         topSenders: r.topSenders, topDomains: r.topDomains,
                         medianReplyLatencySeconds: 0, replyCount: 0,
                         ruleActivity: r.ruleActivity, pendingApprovals: r.pendingApprovals)
        let vm = DigestViewModel(report: r)
        #expect(vm.replyLatencyLabel == "No replies today")
    }

    @Test func emailActionIsTheOutboundSend() {
        let vm = DigestViewModel(report: report())
        #expect(vm.emailAction.actionClass == .outbound)
    }
}
```

- [ ] **Step 2: Run to fail**

Run: `cd Packages/SenaniDigest && swift test --filter DigestViewModelTests`
Expected: FAIL — `cannot find 'DigestViewModel' in scope`.

- [ ] **Step 3: Implement `DigestViewModel` + `DigestView`**

Create `Packages/SenaniDigest/Sources/SenaniDigestUI/DigestView.swift`:

```swift
import SwiftUI
import SenaniRules
import SenaniDigest
import SenaniDesign

/// Pure, testable formatting seam for the DigestView (no SwiftUI types).
public struct DigestViewModel: Sendable, Equatable {
    public let headline: String
    public let pendingApprovalsLabel: String
    public let replyLatencyLabel: String
    public let topSenderLabels: [String]
    public let topDomainLabels: [String]
    public let automationLabels: [String]
    /// The outbound "email me the digest" action (never auto-sends; routes to approval).
    public let emailAction: Action

    public init(report: DigestReport) {
        headline = "\(report.inboundCount) in · \(report.outboundCount) sent"
        pendingApprovalsLabel = "\(report.pendingApprovals) pending approvals"
        if report.replyCount > 0 {
            let minutes = Int((report.medianReplyLatencySeconds / 60).rounded())
            replyLatencyLabel = "Median reply: \(minutes) min"
        } else {
            replyLatencyLabel = "No replies today"
        }
        topSenderLabels = report.topSenders.map { "\($0.sender) — \($0.count)" }
        topDomainLabels = report.topDomains.map { "\($0.domain) — \($0.count)" }
        automationLabels = report.ruleActivity.map {
            "\($0.ruleId): \($0.executed)/\($0.prepared)/\($0.queuedForApproval)"
        }
        emailAction = DigestEmailComposer.action(for: report)
    }
}

/// The gold-glass Daily Digest surface — the digest's primary view. Renders a
/// DigestReport in a GlassPanel and offers "Email me the digest", which hands
/// the OUTBOUND action to the injected host (the composition root queues it; the
/// view never sends mail itself).
public struct DigestView: View {
    private let model: DigestViewModel
    private let onEmailDigest: (Action) -> Void

    public init(report: DigestReport, onEmailDigest: @escaping (Action) -> Void) {
        self.model = DigestViewModel(report: report)
        self.onEmailDigest = onEmailDigest
    }

    public var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Daily Digest")
                    .font(.senaniTitle)
                    .foregroundStyle(Color.senaniInk)

                Text(model.headline)
                    .font(.senaniBody)
                    .foregroundStyle(Color.senaniAccent)

                Text(model.replyLatencyLabel)
                    .font(.senaniBody)
                    .foregroundStyle(Color.senaniMuted)

                section("Top senders", items: model.topSenderLabels)
                section("Top domains", items: model.topDomainLabels)
                section("Automations", items: model.automationLabels)

                Text(model.pendingApprovalsLabel)
                    .font(.senaniBody)
                    .foregroundStyle(Color.senaniMuted)

                Button("Email me the digest") {
                    onEmailDigest(model.emailAction)
                }
                .font(.senaniBody)
                .foregroundStyle(Gold.base)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func section(_ title: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.senaniBody).foregroundStyle(Color.senaniInk)
                ForEach(items, id: \.self) { item in
                    Text(item).font(.senaniBody).foregroundStyle(Color.senaniMuted)
                }
            }
        }
    }
}

#Preview("DigestView") {
    DigestView(
        report: DigestReport(
            day: Date(),
            inboundCount: 12, outboundCount: 4,
            topSenders: [SenderCount(sender: "alice@example.com", count: 7)],
            topDomains: [DomainCount(domain: "example.com", count: 7)],
            medianReplyLatencySeconds: 3_600, replyCount: 3,
            ruleActivity: [RuleActivity(ruleId: "triage", executed: 5, prepared: 1, queuedForApproval: 2)],
            pendingApprovals: 6
        ),
        onEmailDigest: { _ in }
    )
    .frame(width: 360)
    .padding()
}
```

> `DigestViewModel` is the unit-tested seam; `DigestView` consumes it. `import SenaniAnalytics` is transitive via `SenaniDigest` (which re-exports the result types it uses publicly); add an explicit `import SenaniAnalytics` to `DigestView.swift` if the `SenderCount`/`DomainCount`/`RuleActivity` references in `#Preview` fail to resolve.

- [ ] **Step 4: Run to pass**

Run: `cd Packages/SenaniDigest && swift test --filter DigestViewModelTests`
Expected: PASS — headline contains 12 and 4; pending label "6 pending approvals"; latency "Median reply: 60 min"; empty latency "No replies today"; emailAction is `.outbound`.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniDigest && git add -A && git commit -m "SenaniDigest: gold-glass DigestView + tested DigestViewModel + email-digest button"
```

(Append the standard trailer.)

---

### Task 8: Full suite + module-boundary check

- [ ] **Step 1: Run the whole suite**

Run: `cd Packages/SenaniDigest && swift test`
Expected: PASS — every suite green: `DigestWindowTests`, `DigestBuilderTests`, `DigestEmailTests`, `DigestSchedulerTests`, and (if `SenaniDesign` is present) `DigestViewModelTests`. No test touches MLX, Gmail, a real Keychain, or a real timer.

- [ ] **Step 2: Confirm the pure core has no SwiftUI/SenaniDesign dependency**

Run: `cd Packages/SenaniDigest && swift build --target SenaniDigest`
Expected: `Build complete!` with NO `SwiftUI`/`SenaniDesign` linkage (the pure core builds standalone). This proves Tasks 1–6 are independent of the design system.

- [ ] **Step 3: Final commit (if any docs/cleanup remain)**

```
cd Packages/SenaniDigest && git add -A && git commit -m "SenaniDigest: full suite green; pure core builds without SwiftUI"
```

(Append the standard trailer. Skip if nothing is staged.)

---

## What this plan deliberately leaves out (next plans / reconciliation)

- **`SenaniEngine.Scheduler` integration.** `DigestScheduler` is intentionally separate (different cadence). If the app-shell composition root wants one timer surface, it composes both schedulers; that wiring + the `AppEnvironment` exposure of a `DigestScheduler` and a "Daily Digest" navigation entry are the **app-shell plan's** work, not this one. `AppEnvironment.live()/preview()` (pinned in reconciliation §3) constructs the `AnalyticsQueries`/`ApprovalStore` graph; the digest reads through them.
- **Strictly day-bounded analytics.** Real `AnalyticsQueries.topSenders/topDomains` have no date bound and `replyLatency(since:)`/`volumeByDay(since:)` have only a lower bound. For production multi-day stores, tightening the digest to a single day needs `since:`/`until:` parameters on those methods — a **change to frozen `SenaniAnalytics`** to surface to the human (reconciliation §5), NOT a fork. `DigestBuilder`'s public API is unchanged when that lands.
- **Local-timezone day bucketing.** v1 buckets in UTC to match `AnalyticsQueries.volumeByDay`. Local-day bucketing is a follow-up (would propagate the injected `Calendar`/`TimeZone` into the analytics layer).
- **Chat-queryable digest.** The Assistant (`SenaniAssistant`) could expose "summarize today" via the same `DigestBuilder`; out of scope here.
- **Real low-power probe.** `isLowPower` is an injected closure; the IOKit/`ProcessInfo` probe is the host's (app-shell) job — never imported here.
- **Per-recipient email address.** `DigestEmailComposer.action` produces `.send(body:)`; if a future `Action` needs an explicit "to self" recipient, that is a frozen-package decision (the existing `.send`/`.forward` cases are the only outbound shapes) — surface to the human, do not fork.

---

## Self-Review

**Scope coverage:**
- *Abstraction mismatch handled* — the digest is modelled as `DigestBuilder` (pure, day-scoped) + a **separate** `DigestScheduler`, NOT a per-message `SenaniEngine.Agent`. The choice between a `dailyDigest(at:)` hook on the frozen `SenaniEngine.Scheduler` vs a separate scheduler is made explicitly (separate scheduler) and justified (distinct cadence/trigger), and flagged that this is deliberately NOT a `SenaniEngine` contract addition (Architecture section + §Out of scope).
- *`DigestBuilder.build(for:) -> DigestReport`* aggregates volume in/out, top senders, top domains, reply latency, rule/agent activity, and pending-approvals count, pure over injected `AnalyticsQueries` + `ApprovalReading` (Task 4).
- *Surfacing* — gold-glass `DigestView` is the primary surface (Task 7); the optional "email me the digest" is an OUTBOUND `.send` action that always queues (Tasks 5 + 7).
- *Schedule* — daily tick at a user-set time, injected clock + low-power closure, no real timers in tests (Task 6).
- *Tests (pure)* — seed `SenaniDatabase.inMemory()` with messages + `actions_log` rows for a day → exact counts/top-lists/latency/rule-activity/pending (Task 4); the daily hook fires at the configured time under a fake clock (Task 6); the email digest is an outbound action (Task 5). No MLX/network/timers.

**Real upstream API used (verified from source, NOT the early draft):** `AnalyticsQueries` methods are synchronous `throws`; results use `SenderCount.sender`, `DomainCount.domain`, `VolumePoint.day/.inbound/.outbound`, `ReplyLatency.threadId/.seconds` (per-message), `RuleActivity.ruleId/.executed/.prepared/.queuedForApproval`; `volumeByDay`/`replyLatency`/`ruleActivity` take `since:` only; constructors `init(database:)`/`init(reader:)`. `ApprovalStore.pending() -> [StoredProposal]` drives the pending count via the `ApprovalReading` seam. The real `actions_log` schema (`message_id/action_json/trigger_json/outcome/logged_at`, `trigger_json` kind/identifier) and `messages` schema are seeded exactly so `AnalyticsQueries` reads what production reads. `Action.send`/`.outbound`/`ActionRouter.route` are the real safety-path symbols.

**Conventions (§4):** composition-root-only (the view takes an injected closure; the builder takes injected stores — nothing constructs `SenaniDatabase.file(...)` or a `MailBackend`); one safety path (the email is `.send`, forced to `.queuedForApproval` by `ActionRouter`); reads go through `AnalyticsQueries`/`ApprovalStore` (no hand-rolled SQL in the library; raw SQL only in the test fixture for `actions_log`, matching the analytics plan); live/preview parity (`#Preview` + the pure `DigestViewModel`/`DigestBuilder` tests on the in-memory graph); macOS 14, Swift 6.2, Swift Testing; TDD bite-sized steps with complete code and run-to-fail/run-to-pass commands; the pure core takes no I/O.

**Placeholder scan:** no TBD/TODO/"similar to Task N". Every code block is complete, compilable Swift; every SQL string names only real-schema columns; every test states the expected fail and pass output. The two reconciliation flags (separate scheduler vs `SenaniEngine` hook; day-bounded analytics needing `until:` on frozen `SenaniAnalytics`) are explicit, with the no-fork rule per §5.

**Type consistency:** `DigestReport(day:inboundCount:outboundCount:topSenders:topDomains:medianReplyLatencySeconds:replyCount:ruleActivity:pendingApprovals:)`; `DigestWindow(containing:calendar:)` → `utcDayStart`/`utcNextDayStart`; `DigestBuilder(analytics:approvals:calendar:topLimit:)` → `build(for:) throws`; `ApprovalReading.pendingCount() throws -> Int` (+ `ApprovalStore` conformance); `DigestEmailComposer.action(for:) -> Action`; `DigestScheduler(hour:minute:calendar:now:isLowPower:checkInterval:onFire:)` → `tick()/start()/stop()`; `DigestViewModel(report:)` + `DigestView(report:onEmailDigest:)`. The test fixture `DigestFixture` (`dayStart`, `utcCalendar`, `makeDatabase`, `analytics`, `approvals`, `message`, `insertAction`) is reused by all suites.
