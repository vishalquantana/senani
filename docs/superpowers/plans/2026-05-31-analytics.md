# SenaniAnalytics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `SenaniAnalytics`, a read-only, fully unit-tested Swift package that aggregates the user's local SQLite store (synced messages + the `actions_log`) into typed dashboard metrics — top senders, top domains, daily volume, reply latency, and per-rule activity — with no writes, no network, and no model.

**Architecture:** A standalone Swift Package Manager library that depends (via path) on `../SenaniRules` and `../SenaniStore`. A single value type `AnalyticsQueries` wraps a `SenaniDatabase` (the GRDB-backed store from SenaniStore) and exposes five pure read queries returning small typed result structs. All aggregation is expressed as GRDB SQL executed through the database's read access; the package never opens a network connection, never writes, and never calls a model. Tests run against an **in-memory** `SenaniDatabase` seeded with deterministic fixture rows (explicit timestamps — never the current date) and assert exact aggregate outputs.

**Tech Stack:** Swift 6.2 (strict concurrency), swift-tools 6.0, macOS 14, Swift Testing (`import Testing`, ships with the toolchain), GRDB (transitively via SenaniStore). All `swift` commands run from `Packages/SenaniAnalytics/`.

**Design spec:** `docs/superpowers/specs/2026-05-31-rules-engine-and-chat-assistant-design.md` — this plan implements **§10 Analytics** (read-only dashboard over the local store; independent of the engine).

---

## Cross-package assumptions (READ FIRST — reconcile before implementing)

This package reads from `SenaniStore`'s `SenaniDatabase`. The following are **assumed** contracts. If the real `SenaniStore` differs, reconcile by adjusting only the SQL strings and the seeding helper — the public API of `AnalyticsQueries` and the result structs do not change.

1. **`SenaniDatabase` is GRDB-backed and exposes a read seam.** We assume it surfaces its underlying GRDB `DatabaseQueue`/`DatabasePool` reader, or a `read { db in ... }` method, via a public property `reader` of type `GRDB.DatabaseReader`. All queries in this package go through `database.reader`.
   - **If SenaniStore does not expose `reader`:** add a tiny public extension/accessor in SenaniStore (one-line, returns the existing queue) — this is the only SenaniStore change permitted and must be flagged to that package's owner. Do **not** open a second connection to the same file.

2. **In-memory construction + seeding.** We assume `SenaniDatabase` has a public initializer that creates an **in-memory** database with the schema migrated, e.g. `SenaniDatabase.inMemory()` (throws). If no such constructor exists, this plan defines a **test-only seeding helper** (`AnalyticsFixture`, Task 1) that creates an in-memory `DatabaseQueue`, runs `CREATE TABLE` statements matching the assumed schema below, and wraps it so `AnalyticsQueries` can read it. The helper lives in the **test target** so it never ships in the library.

3. **Assumed `messages` table schema** (the table of synced mail to aggregate over). Columns and the exact names the SQL below depends on:

   | Column         | SQL type | Meaning                                                                 |
   |----------------|----------|-------------------------------------------------------------------------|
   | `id`           | TEXT PK  | message id                                                              |
   | `from`         | TEXT     | full sender address, e.g. `Alice@Example.com` (raw, as synced)          |
   | `senderDomain` | TEXT     | lowercased host after `@`, e.g. `example.com` (precomputed at sync)     |
   | `date`         | DOUBLE   | message timestamp as **Unix epoch seconds** (`Date.timeIntervalSince1970`) |
   | `isFromUser`   | INTEGER  | 1 if the user sent it (a "Sent" message), 0 if inbound                  |
   | `threadId`     | TEXT     | conversation/thread id                                                  |

   These mirror the `Message` domain model in `SenaniRules` (`id, from, senderDomain, date, isFromUser, threadId`). `from` is matched/grouped case-insensitively for `topSenders`; `senderDomain` is assumed already-normalized (lowercased) at sync time. Storing `date` as epoch-seconds DOUBLE is the GRDB-idiomatic representation of `Date` and lets us bind `Date` values directly.

4. **Assumed `actions_log` schema** (every Action Kernel execution; spec §11 / SenaniRules `ActionRecord`). Columns the SQL below depends on:

   | Column      | SQL type | Meaning                                                                            |
   |-------------|----------|------------------------------------------------------------------------------------|
   | `id`        | INTEGER PK| autoincrement row id                                                              |
   | `ruleId`    | TEXT     | trigger rule id; NULL when the trigger was a chat turn rather than a rule          |
   | `outcome`   | TEXT     | one of `executed`, `prepared`, `queuedForApproval` (matches `SenaniRules.Outcome`) |
   | `messageId` | TEXT     | message the action targeted                                                        |
   | `date`      | DOUBLE   | when the action was logged, Unix epoch seconds                                     |

   `ruleActivity(since:)` aggregates this table grouped by `ruleId`, counting each outcome. Rows with NULL `ruleId` (chat-triggered) are **excluded** from rule activity (a rule's activity is per-rule). The three outcome strings are exactly the raw values of `SenaniRules.Outcome` (`executed` / `prepared` / `queuedForApproval`) so the spec's "executed/prepared/queuedForApproval per rule" maps 1:1.

5. **`rule_runs`** exists (spec §11, simulation/eval records) but **§10 analytics for rule activity is sourced from `actions_log`** per the spec line ("sourced from `actions_log` / `rule_runs`"). This plan aggregates `actions_log` only; `rule_runs`-based simulation analytics is out of scope here and noted at the end.

6. **No timezone math in v1.** `volumeByDay` buckets by UTC calendar day derived from epoch seconds (`floor(date / 86400)` → day index → midnight-UTC `Date`). This is deterministic and testable; local-timezone bucketing is a documented follow-up.

7. **GRDB import.** SenaniStore re-exports or depends on GRDB; this package adds GRDB to its own `Package.swift` only if SenaniStore does not transitively expose it. The plan assumes `import GRDB` is available transitively via the SenaniStore product. If a direct dependency is required, add the same GRDB version SenaniStore pins (reconcile with that package's `Package.resolved`).

---

## File Structure

```
Packages/SenaniAnalytics/
  Package.swift
  Sources/SenaniAnalytics/
    AnalyticsResults.swift   # SenderCount, DomainCount, VolumePoint, ReplyLatency, RuleActivity
    AnalyticsQueries.swift   # AnalyticsQueries(database:) + the five read queries
  Tests/SenaniAnalyticsTests/
    AnalyticsFixture.swift   # test-only in-memory SenaniDatabase + seeding helpers
    TopSendersTests.swift
    TopDomainsTests.swift
    VolumeByDayTests.swift
    ReplyLatencyTests.swift
    RuleActivityTests.swift
```

One result-struct file (all five POD structs change together), one queries file (the single public service), and one fixture file shared by every test suite. No source file performs any write or network operation.

---

### Task 1: Package scaffold + in-memory fixture seeding helper

**Files:**
- Create: `Packages/SenaniAnalytics/Package.swift`
- Create: `Packages/SenaniAnalytics/Tests/SenaniAnalyticsTests/AnalyticsFixture.swift`
- Create (placeholder so the target compiles): `Packages/SenaniAnalytics/Sources/SenaniAnalytics/AnalyticsResults.swift` (real content lands in Task 2; here it is an empty-but-valid file)

- [ ] **Step 1: Create the package manifest**

Create `Packages/SenaniAnalytics/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniAnalytics",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniAnalytics", targets: ["SenaniAnalytics"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
        .package(path: "../SenaniStore"),
    ],
    targets: [
        .target(
            name: "SenaniAnalytics",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "SenaniStore", package: "SenaniStore"),
            ]
        ),
        .testTarget(
            name: "SenaniAnalyticsTests",
            dependencies: ["SenaniAnalytics"]
        ),
    ]
)
```

> **Reconciliation note:** if `swift build` later fails with `no such module 'GRDB'` inside `AnalyticsQueries.swift`, add `.package(url: "https://github.com/groue/GRDB.swift", from: "<version SenaniStore pins>")` to `dependencies` and `.product(name: "GRDB", package: "GRDB.swift")` to the `SenaniAnalytics` target, matching SenaniStore's `Package.resolved`.

- [ ] **Step 2: Create a valid empty source file so the library target builds**

Create `Packages/SenaniAnalytics/Sources/SenaniAnalytics/AnalyticsResults.swift`:

```swift
// Result structs land in Task 2.
import Foundation
```

- [ ] **Step 3: Write the fixture helper (the seam tests depend on)**

Create `Packages/SenaniAnalytics/Tests/SenaniAnalyticsTests/AnalyticsFixture.swift`:

```swift
import Foundation
import GRDB
@testable import SenaniAnalytics

/// Builds a deterministic in-memory database for analytics tests.
///
/// ASSUMPTION: SenaniStore's `SenaniDatabase` either (a) offers an in-memory
/// constructor + seeding, or (b) exposes a public `reader: DatabaseReader`.
/// Until that is reconciled, this helper owns its own in-memory `DatabaseQueue`
/// with a schema matching the assumed `messages` / `actions_log` tables, and
/// `AnalyticsQueries` reads through a `DatabaseReader`. If `SenaniDatabase`
/// exposes `reader`, swap `makeQueries(_:)` to wrap a real `SenaniDatabase`.
enum AnalyticsFixture {

    /// Epoch seconds for a fixed reference instant: 2026-01-01T00:00:00Z.
    /// All fixtures are expressed relative to this so tests never read the clock.
    static let epoch2026: TimeInterval = 1_767_225_600

    /// Creates an in-memory queue with the analytics schema migrated.
    static func makeReader() throws -> DatabaseQueue {
        let queue = try DatabaseQueue() // ":memory:" by default
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE messages (
                    id           TEXT PRIMARY KEY,
                    "from"       TEXT NOT NULL,
                    senderDomain TEXT NOT NULL,
                    date         DOUBLE NOT NULL,
                    isFromUser   INTEGER NOT NULL,
                    threadId     TEXT NOT NULL
                );
                """)
            try db.execute(sql: """
                CREATE TABLE actions_log (
                    id        INTEGER PRIMARY KEY AUTOINCREMENT,
                    ruleId    TEXT,
                    outcome   TEXT NOT NULL,
                    messageId TEXT NOT NULL,
                    date      DOUBLE NOT NULL
                );
                """)
        }
        return queue
    }

    /// Builds an `AnalyticsQueries` over the given reader.
    static func makeQueries(_ reader: DatabaseQueue) -> AnalyticsQueries {
        AnalyticsQueries(reader: reader)
    }

    /// Inserts a message row.
    static func insertMessage(
        _ db: Database, id: String, from: String, senderDomain: String,
        date: TimeInterval, isFromUser: Bool, threadId: String
    ) throws {
        try db.execute(
            sql: #"INSERT INTO messages (id, "from", senderDomain, date, isFromUser, threadId) VALUES (?, ?, ?, ?, ?, ?)"#,
            arguments: [id, from, senderDomain, date, isFromUser, threadId]
        )
    }

    /// Inserts an actions_log row. `ruleId` nil => chat-triggered (excluded from rule activity).
    static func insertAction(
        _ db: Database, ruleId: String?, outcome: String, messageId: String, date: TimeInterval
    ) throws {
        try db.execute(
            sql: "INSERT INTO actions_log (ruleId, outcome, messageId, date) VALUES (?, ?, ?, ?)",
            arguments: [ruleId, outcome, messageId, date]
        )
    }
}
```

> **Reconciliation note:** `AnalyticsQueries(reader:)` is the seam used throughout tests. Task 2 defines `AnalyticsQueries` with both a `reader:` initializer (used here) and a `database:` initializer (the public production API that pulls `database.reader`). If SenaniStore exposes a real in-memory `SenaniDatabase`, replace `makeReader()`/`makeQueries(_:)` to construct that and call `AnalyticsQueries(database:)` — no test assertions change.

- [ ] **Step 4: Verify the package builds (no tests yet)**

Run: `cd Packages/SenaniAnalytics && swift build`
Expected: `Build complete!`. (The test file references `AnalyticsQueries`, which does not yet exist, but `swift build` only builds the library target, so this passes.)

- [ ] **Step 5: Commit**

```bash
git add Packages/SenaniAnalytics/Package.swift Packages/SenaniAnalytics/Sources/SenaniAnalytics/AnalyticsResults.swift Packages/SenaniAnalytics/Tests/SenaniAnalyticsTests/AnalyticsFixture.swift
git commit -m "feat(analytics): scaffold SenaniAnalytics package + in-memory fixture helper" -m "$(cat <<'EOF'

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

### Task 2: Result structs + AnalyticsQueries skeleton + `topSenders`

**Files:**
- Edit: `Packages/SenaniAnalytics/Sources/SenaniAnalytics/AnalyticsResults.swift`
- Create: `Packages/SenaniAnalytics/Sources/SenaniAnalytics/AnalyticsQueries.swift`
- Create: `Packages/SenaniAnalytics/Tests/SenaniAnalyticsTests/TopSendersTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniAnalytics/Tests/SenaniAnalyticsTests/TopSendersTests.swift`:

```swift
import Testing
import Foundation
import GRDB
@testable import SenaniAnalytics

@Suite struct TopSendersTests {
    private func seeded() throws -> AnalyticsQueries {
        let q = try AnalyticsFixture.makeReader()
        try q.write { db in
            // alice: 3, bob: 2, carol: 1
            try AnalyticsFixture.insertMessage(db, id: "1", from: "alice@x.com", senderDomain: "x.com", date: 0, isFromUser: false, threadId: "t1")
            try AnalyticsFixture.insertMessage(db, id: "2", from: "alice@x.com", senderDomain: "x.com", date: 0, isFromUser: false, threadId: "t2")
            try AnalyticsFixture.insertMessage(db, id: "3", from: "ALICE@x.com", senderDomain: "x.com", date: 0, isFromUser: false, threadId: "t3") // case-insensitive
            try AnalyticsFixture.insertMessage(db, id: "4", from: "bob@y.com", senderDomain: "y.com", date: 0, isFromUser: false, threadId: "t4")
            try AnalyticsFixture.insertMessage(db, id: "5", from: "bob@y.com", senderDomain: "y.com", date: 0, isFromUser: false, threadId: "t5")
            try AnalyticsFixture.insertMessage(db, id: "6", from: "carol@z.com", senderDomain: "z.com", date: 0, isFromUser: false, threadId: "t6")
            // a sent message must NOT be counted as an incoming sender
            try AnalyticsFixture.insertMessage(db, id: "7", from: "me@self.com", senderDomain: "self.com", date: 0, isFromUser: true, threadId: "t7")
        }
        return AnalyticsFixture.makeQueries(q)
    }

    @Test func ranksSendersByCountDescendingCaseInsensitive() async throws {
        let result = try await seeded().topSenders(limit: 10)
        #expect(result == [
            SenderCount(address: "alice@x.com", count: 3),
            SenderCount(address: "bob@y.com", count: 2),
            SenderCount(address: "carol@z.com", count: 1),
        ])
    }

    @Test func honorsLimit() async throws {
        let result = try await seeded().topSenders(limit: 2)
        #expect(result == [
            SenderCount(address: "alice@x.com", count: 3),
            SenderCount(address: "bob@y.com", count: 2),
        ])
    }

    @Test func excludesUserSentMessages() async throws {
        let result = try await seeded().topSenders(limit: 10)
        #expect(!result.contains { $0.address == "me@self.com" })
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/SenaniAnalytics && swift test`
Expected: FAIL — compile error, `cannot find 'SenderCount' in scope` / `cannot find 'AnalyticsQueries' in scope`.

- [ ] **Step 3: Write the result structs**

Replace the contents of `Packages/SenaniAnalytics/Sources/SenaniAnalytics/AnalyticsResults.swift`:

```swift
import Foundation

/// One sender and how many inbound messages they sent.
public struct SenderCount: Sendable, Equatable {
    public let address: String
    public let count: Int
    public init(address: String, count: Int) {
        self.address = address
        self.count = count
    }
}

/// One sender domain and how many inbound messages came from it
/// ("what's clogging your inbox").
public struct DomainCount: Sendable, Equatable {
    public let domain: String
    public let count: Int
    public init(domain: String, count: Int) {
        self.domain = domain
        self.count = count
    }
}

/// Message volume for a single calendar day (midnight UTC).
public struct VolumePoint: Sendable, Equatable {
    public let date: Date
    public let count: Int
    public init(date: Date, count: Int) {
        self.date = date
        self.count = count
    }
}

/// Median reply latency across qualifying inbound→user-reply transitions.
public struct ReplyLatency: Sendable, Equatable {
    /// Median seconds between a qualifying inbound message and the user's next reply
    /// in the same thread. Zero when `count == 0`.
    public let medianSeconds: Double
    /// Number of inbound→reply transitions that contributed to the median.
    public let count: Int
    public init(medianSeconds: Double, count: Int) {
        self.medianSeconds = medianSeconds
        self.count = count
    }
}

/// What one rule's automations did, aggregated from `actions_log`.
public struct RuleActivity: Sendable, Equatable {
    public let ruleId: String
    public let executed: Int
    public let prepared: Int
    public let queued: Int
    public init(ruleId: String, executed: Int, prepared: Int, queued: Int) {
        self.ruleId = ruleId
        self.executed = executed
        self.prepared = prepared
        self.queued = queued
    }
}
```

- [ ] **Step 4: Write the AnalyticsQueries skeleton + `topSenders`**

Create `Packages/SenaniAnalytics/Sources/SenaniAnalytics/AnalyticsQueries.swift`:

```swift
import Foundation
import GRDB

/// Read-only analytics over the local store (spec §10). Never writes, never
/// reaches the network, never calls a model. All aggregation is GRDB SQL run
/// through a `DatabaseReader`.
public struct AnalyticsQueries: Sendable {
    private let reader: DatabaseReader

    /// Production entry point: read through SenaniStore's database.
    ///
    /// ASSUMPTION: `SenaniDatabase` exposes a public `reader: DatabaseReader`.
    /// If it does not, add a one-line accessor in SenaniStore (the only change
    /// permitted there) — do not open a second connection to the same file.
    public init(database: SenaniDatabaseReadable) {
        self.reader = database.reader
    }

    /// Test/advanced entry point: read through any GRDB `DatabaseReader`.
    public init(reader: DatabaseReader) {
        self.reader = reader
    }

    /// Top inbound senders by message count, descending; ties broken by address
    /// ascending for determinism. Excludes messages the user sent (`isFromUser = 1`).
    /// Grouping is case-insensitive on the address.
    public func topSenders(limit: Int) -> [SenderCount] {
        (try? reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT "from" AS address, COUNT(*) AS cnt
                FROM messages
                WHERE isFromUser = 0
                GROUP BY LOWER("from")
                ORDER BY cnt DESC, LOWER("from") ASC
                LIMIT ?
                """, arguments: [limit])
                .map { SenderCount(address: $0["address"], count: $0["cnt"]) }
        }) ?? []
    }
}

/// Minimal seam so `AnalyticsQueries` can read SenaniStore's database without a
/// hard compile-time coupling to its concrete type. SenaniStore's `SenaniDatabase`
/// is expected to conform (or be made to conform via a one-line extension there).
public protocol SenaniDatabaseReadable {
    var reader: DatabaseReader { get }
}
```

> **Reconciliation note:** the tests use `AnalyticsQueries(reader:)` directly, so they do not require `SenaniDatabaseReadable`. The `database:` initializer + `SenaniDatabaseReadable` protocol document the production wiring. When reconciling with SenaniStore, make `SenaniDatabase` conform to `SenaniDatabaseReadable` (one extension in this package or in SenaniStore) and callers use `AnalyticsQueries(database: senaniDatabase)`.

> **Async note:** the queries are synchronous GRDB reads. Tests `await` them harmlessly only because helper functions are `async`; the methods themselves are non-`async`. The tests below call e.g. `try await seeded().topSenders(...)` — `seeded()` is sync, `topSenders` is sync, so drop `await` if the compiler warns "no async operations occur within await expression." (Adjust the test call sites to remove `await` if warned — it is a warning, not an error, but keep it clean.)

> **Correction applied below:** to keep call sites clean, the test helper `seeded()` is **not** async and the query methods are **not** async. The `@Test func` bodies use `try` only (no `await`). The TopSendersTests above show `await` — remove it. Use the de-async'd form shown in Task 3 onward as the canonical style.

- [ ] **Step 5: De-async the TopSendersTests call sites**

Edit `TopSendersTests.swift`: change the three `@Test` bodies from `try await seeded()` to `try seeded()` (the methods are synchronous). Final form of each test, e.g.:

```swift
    @Test func ranksSendersByCountDescendingCaseInsensitive() throws {
        let result = try seeded().topSenders(limit: 10)
        #expect(result == [
            SenderCount(address: "alice@x.com", count: 3),
            SenderCount(address: "bob@y.com", count: 2),
            SenderCount(address: "carol@z.com", count: 1),
        ])
    }
```

(Apply the same `async`/`await` removal to `honorsLimit` and `excludesUserSentMessages`.)

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd Packages/SenaniAnalytics && swift test`
Expected: PASS — all three `TopSendersTests` pass; `me@self.com` (a sent message) is absent.

- [ ] **Step 7: Commit**

```bash
git add Packages/SenaniAnalytics/Sources/SenaniAnalytics/AnalyticsResults.swift Packages/SenaniAnalytics/Sources/SenaniAnalytics/AnalyticsQueries.swift Packages/SenaniAnalytics/Tests/SenaniAnalyticsTests/TopSendersTests.swift
git commit -m "feat(analytics): result structs + AnalyticsQueries.topSenders" -m "$(cat <<'EOF'

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

### Task 3: `topDomains`

**Files:**
- Edit: `Packages/SenaniAnalytics/Sources/SenaniAnalytics/AnalyticsQueries.swift`
- Create: `Packages/SenaniAnalytics/Tests/SenaniAnalyticsTests/TopDomainsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniAnalytics/Tests/SenaniAnalyticsTests/TopDomainsTests.swift`:

```swift
import Testing
import Foundation
import GRDB
@testable import SenaniAnalytics

@Suite struct TopDomainsTests {
    private func seeded() throws -> AnalyticsQueries {
        let q = try AnalyticsFixture.makeReader()
        try q.write { db in
            // x.com: 3 (two senders), y.com: 2, z.com: 1
            try AnalyticsFixture.insertMessage(db, id: "1", from: "alice@x.com", senderDomain: "x.com", date: 0, isFromUser: false, threadId: "t1")
            try AnalyticsFixture.insertMessage(db, id: "2", from: "ann@x.com", senderDomain: "x.com", date: 0, isFromUser: false, threadId: "t2")
            try AnalyticsFixture.insertMessage(db, id: "3", from: "amy@x.com", senderDomain: "x.com", date: 0, isFromUser: false, threadId: "t3")
            try AnalyticsFixture.insertMessage(db, id: "4", from: "bob@y.com", senderDomain: "y.com", date: 0, isFromUser: false, threadId: "t4")
            try AnalyticsFixture.insertMessage(db, id: "5", from: "ben@y.com", senderDomain: "y.com", date: 0, isFromUser: false, threadId: "t5")
            try AnalyticsFixture.insertMessage(db, id: "6", from: "carol@z.com", senderDomain: "z.com", date: 0, isFromUser: false, threadId: "t6")
            // sent message excluded
            try AnalyticsFixture.insertMessage(db, id: "7", from: "me@self.com", senderDomain: "self.com", date: 0, isFromUser: true, threadId: "t7")
        }
        return AnalyticsFixture.makeQueries(q)
    }

    @Test func ranksDomainsByCountDescending() throws {
        let result = try seeded().topDomains(limit: 10)
        #expect(result == [
            DomainCount(domain: "x.com", count: 3),
            DomainCount(domain: "y.com", count: 2),
            DomainCount(domain: "z.com", count: 1),
        ])
    }

    @Test func honorsLimitAndExcludesSent() throws {
        let result = try seeded().topDomains(limit: 1)
        #expect(result == [DomainCount(domain: "x.com", count: 3)])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/SenaniAnalytics && swift test`
Expected: FAIL — `value of type 'AnalyticsQueries' has no member 'topDomains'`.

- [ ] **Step 3: Write the minimal implementation**

Add to `AnalyticsQueries` in `AnalyticsQueries.swift`, after `topSenders`:

```swift
    /// Top sender domains by inbound message count, descending; ties broken by
    /// domain ascending. Excludes user-sent messages. "What's clogging your inbox."
    public func topDomains(limit: Int) -> [DomainCount] {
        (try? reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT senderDomain AS domain, COUNT(*) AS cnt
                FROM messages
                WHERE isFromUser = 0
                GROUP BY senderDomain
                ORDER BY cnt DESC, senderDomain ASC
                LIMIT ?
                """, arguments: [limit])
                .map { DomainCount(domain: $0["domain"], count: $0["cnt"]) }
        }) ?? []
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/SenaniAnalytics && swift test`
Expected: PASS — `TopDomainsTests` green; existing suites still pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/SenaniAnalytics/Sources/SenaniAnalytics/AnalyticsQueries.swift Packages/SenaniAnalytics/Tests/SenaniAnalyticsTests/TopDomainsTests.swift
git commit -m "feat(analytics): topDomains (group by senderDomain)" -m "$(cat <<'EOF'

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

### Task 4: `volumeByDay`

**Files:**
- Edit: `Packages/SenaniAnalytics/Sources/SenaniAnalytics/AnalyticsQueries.swift`
- Create: `Packages/SenaniAnalytics/Tests/SenaniAnalyticsTests/VolumeByDayTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniAnalytics/Tests/SenaniAnalyticsTests/VolumeByDayTests.swift`:

```swift
import Testing
import Foundation
import GRDB
@testable import SenaniAnalytics

@Suite struct VolumeByDayTests {
    // Fixed UTC days. day0 = 2026-01-01T00:00:00Z (epoch2026).
    private let day0 = AnalyticsFixture.epoch2026                 // 2026-01-01
    private var day1: TimeInterval { day0 + 86_400 }              // 2026-01-02
    private var day2: TimeInterval { day0 + 2 * 86_400 }          // 2026-01-03

    private func seeded() throws -> AnalyticsQueries {
        let q = try AnalyticsFixture.makeReader()
        try q.write { db in
            // day0: 2 inbound (one mid-day), day1: 0, day2: 1 inbound + 1 sent (sent excluded)
            try AnalyticsFixture.insertMessage(db, id: "1", from: "a@x.com", senderDomain: "x.com", date: day0 + 100, isFromUser: false, threadId: "t1")
            try AnalyticsFixture.insertMessage(db, id: "2", from: "b@x.com", senderDomain: "x.com", date: day0 + 50_000, isFromUser: false, threadId: "t2")
            try AnalyticsFixture.insertMessage(db, id: "3", from: "c@x.com", senderDomain: "x.com", date: day2 + 10, isFromUser: false, threadId: "t3")
            try AnalyticsFixture.insertMessage(db, id: "4", from: "me@s.com", senderDomain: "s.com", date: day2 + 20, isFromUser: true, threadId: "t4")
            // out-of-range message must be excluded
            try AnalyticsFixture.insertMessage(db, id: "5", from: "d@x.com", senderDomain: "x.com", date: day0 - 86_400 + 10, isFromUser: false, threadId: "t5")
        }
        return AnalyticsFixture.makeQueries(q)
    }

    @Test func bucketsInboundByUtcDayAndFillsGapsWithZero() throws {
        // Range covers day0..day2 inclusive.
        let from = Date(timeIntervalSince1970: day0)
        let to   = Date(timeIntervalSince1970: day2 + 86_399)
        let result = try seeded().volumeByDay(from: from, to: to)
        #expect(result == [
            VolumePoint(date: Date(timeIntervalSince1970: day0), count: 2),
            VolumePoint(date: Date(timeIntervalSince1970: day1), count: 0),
            VolumePoint(date: Date(timeIntervalSince1970: day2), count: 1),
        ])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/SenaniAnalytics && swift test`
Expected: FAIL — `value of type 'AnalyticsQueries' has no member 'volumeByDay'`.

- [ ] **Step 3: Write the minimal implementation**

Add to `AnalyticsQueries` in `AnalyticsQueries.swift`:

```swift
    private static let secondsPerDay: TimeInterval = 86_400

    /// Inbound message volume per UTC calendar day, inclusive of `from`/`to`'s days.
    /// Days with no messages are returned with count 0 so charts have no gaps.
    /// Excludes user-sent messages. Buckets by `floor(date / 86400)` (UTC midnight).
    public func volumeByDay(from: Date, to: Date) -> [VolumePoint] {
        let fromDay = (from.timeIntervalSince1970 / Self.secondsPerDay).rounded(.down)
        let toDay = (to.timeIntervalSince1970 / Self.secondsPerDay).rounded(.down)
        guard toDay >= fromDay else { return [] }
        let fromStart = fromDay * Self.secondsPerDay
        let toEnd = (toDay + 1) * Self.secondsPerDay // exclusive upper bound

        let counts: [Int: Int] = (try? reader.read { db -> [Int: Int] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT CAST(date / 86400 AS INTEGER) AS dayIndex, COUNT(*) AS cnt
                FROM messages
                WHERE isFromUser = 0 AND date >= ? AND date < ?
                GROUP BY dayIndex
                """, arguments: [fromStart, toEnd])
            var map: [Int: Int] = [:]
            for row in rows { map[row["dayIndex"]] = row["cnt"] }
            return map
        }) ?? [:]

        var points: [VolumePoint] = []
        var day = Int(fromDay)
        let lastDay = Int(toDay)
        while day <= lastDay {
            let midnight = Date(timeIntervalSince1970: TimeInterval(day) * Self.secondsPerDay)
            points.append(VolumePoint(date: midnight, count: counts[day] ?? 0))
            day += 1
        }
        return points
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/SenaniAnalytics && swift test`
Expected: PASS — day0=2, day1=0 (gap filled), day2=1; the sent message and the out-of-range message are excluded.

- [ ] **Step 5: Commit**

```bash
git add Packages/SenaniAnalytics/Sources/SenaniAnalytics/AnalyticsQueries.swift Packages/SenaniAnalytics/Tests/SenaniAnalyticsTests/VolumeByDayTests.swift
git commit -m "feat(analytics): volumeByDay (UTC daily buckets, zero-filled)" -m "$(cat <<'EOF'

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

### Task 5: `replyLatency`

**Definition (precise, testable):** For each thread, walk its messages in ascending `date` order. A **qualifying transition** is an inbound message (`isFromUser = 0`) immediately followed — in that thread's time order — by a user message (`isFromUser = 1`). The transition's latency is `replyDate - inboundDate`. Multiple inbound messages with no reply between them only "arm" the latest inbound before the reply (latency measured from the **most recent unanswered inbound** preceding the reply). `replyLatency()` returns the **median** of all qualifying transition latencies across all threads, plus the `count` of transitions. Median of an even count is the average of the two middle values. Empty input → `ReplyLatency(medianSeconds: 0, count: 0)`.

**Files:**
- Edit: `Packages/SenaniAnalytics/Sources/SenaniAnalytics/AnalyticsQueries.swift`
- Create: `Packages/SenaniAnalytics/Tests/SenaniAnalyticsTests/ReplyLatencyTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniAnalytics/Tests/SenaniAnalyticsTests/ReplyLatencyTests.swift`:

```swift
import Testing
import Foundation
import GRDB
@testable import SenaniAnalytics

@Suite struct ReplyLatencyTests {
    private let base = AnalyticsFixture.epoch2026

    @Test func emptyStoreYieldsZeroLatencyAndZeroCount() throws {
        let q = try AnalyticsFixture.makeReader()
        let result = try AnalyticsFixture.makeQueries(q).replyLatency()
        #expect(result == ReplyLatency(medianSeconds: 0, count: 0))
    }

    @Test func medianOfOddNumberOfTransitions() throws {
        let q = try AnalyticsFixture.makeReader()
        try q.write { db in
            // t1: inbound@0 -> reply@+100  => 100
            try AnalyticsFixture.insertMessage(db, id: "a1", from: "x@a.com", senderDomain: "a.com", date: base + 0, isFromUser: false, threadId: "t1")
            try AnalyticsFixture.insertMessage(db, id: "a2", from: "me@s.com", senderDomain: "s.com", date: base + 100, isFromUser: true, threadId: "t1")
            // t2: inbound@0 -> reply@+300 => 300
            try AnalyticsFixture.insertMessage(db, id: "b1", from: "y@b.com", senderDomain: "b.com", date: base + 0, isFromUser: false, threadId: "t2")
            try AnalyticsFixture.insertMessage(db, id: "b2", from: "me@s.com", senderDomain: "s.com", date: base + 300, isFromUser: true, threadId: "t2")
            // t3: inbound@0 -> reply@+200 => 200
            try AnalyticsFixture.insertMessage(db, id: "c1", from: "z@c.com", senderDomain: "c.com", date: base + 0, isFromUser: false, threadId: "t3")
            try AnalyticsFixture.insertMessage(db, id: "c2", from: "me@s.com", senderDomain: "s.com", date: base + 200, isFromUser: true, threadId: "t3")
        }
        let result = try AnalyticsFixture.makeQueries(q).replyLatency()
        // latencies sorted: [100, 200, 300] -> median 200, count 3
        #expect(result == ReplyLatency(medianSeconds: 200, count: 3))
    }

    @Test func medianOfEvenCountAveragesTwoMiddleValues() throws {
        let q = try AnalyticsFixture.makeReader()
        try q.write { db in
            try AnalyticsFixture.insertMessage(db, id: "a1", from: "x@a.com", senderDomain: "a.com", date: base + 0, isFromUser: false, threadId: "t1")
            try AnalyticsFixture.insertMessage(db, id: "a2", from: "me@s.com", senderDomain: "s.com", date: base + 100, isFromUser: true, threadId: "t1")
            try AnalyticsFixture.insertMessage(db, id: "b1", from: "y@b.com", senderDomain: "b.com", date: base + 0, isFromUser: false, threadId: "t2")
            try AnalyticsFixture.insertMessage(db, id: "b2", from: "me@s.com", senderDomain: "s.com", date: base + 300, isFromUser: true, threadId: "t2")
        }
        let result = try AnalyticsFixture.makeQueries(q).replyLatency()
        // [100, 300] -> median (100+300)/2 = 200, count 2
        #expect(result == ReplyLatency(medianSeconds: 200, count: 2))
    }

    @Test func multipleUnansweredInboundsMeasureFromMostRecentBeforeReply() throws {
        let q = try AnalyticsFixture.makeReader()
        try q.write { db in
            // inbound@0, inbound@+50, then reply@+120 => latency 120-50 = 70 (one transition)
            try AnalyticsFixture.insertMessage(db, id: "i1", from: "x@a.com", senderDomain: "a.com", date: base + 0, isFromUser: false, threadId: "t1")
            try AnalyticsFixture.insertMessage(db, id: "i2", from: "x@a.com", senderDomain: "a.com", date: base + 50, isFromUser: false, threadId: "t1")
            try AnalyticsFixture.insertMessage(db, id: "r1", from: "me@s.com", senderDomain: "s.com", date: base + 120, isFromUser: true, threadId: "t1")
        }
        let result = try AnalyticsFixture.makeQueries(q).replyLatency()
        #expect(result == ReplyLatency(medianSeconds: 70, count: 1))
    }

    @Test func threadWithNoUserReplyContributesNothing() throws {
        let q = try AnalyticsFixture.makeReader()
        try q.write { db in
            try AnalyticsFixture.insertMessage(db, id: "i1", from: "x@a.com", senderDomain: "a.com", date: base + 0, isFromUser: false, threadId: "t1")
            try AnalyticsFixture.insertMessage(db, id: "i2", from: "x@a.com", senderDomain: "a.com", date: base + 50, isFromUser: false, threadId: "t1")
        }
        let result = try AnalyticsFixture.makeQueries(q).replyLatency()
        #expect(result == ReplyLatency(medianSeconds: 0, count: 0))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/SenaniAnalytics && swift test`
Expected: FAIL — `value of type 'AnalyticsQueries' has no member 'replyLatency'`.

- [ ] **Step 3: Write the minimal implementation**

Add to `AnalyticsQueries` in `AnalyticsQueries.swift`:

```swift
    /// Median latency (seconds) between a qualifying inbound message and the user's
    /// next reply in the same thread. See plan §Task 5 for the precise definition.
    /// Empty input yields `.init(medianSeconds: 0, count: 0)`.
    public func replyLatency() -> ReplyLatency {
        struct Row2 { let threadId: String; let date: Double; let isFromUser: Bool }

        let rows: [Row2] = (try? reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT threadId, date, isFromUser
                FROM messages
                ORDER BY threadId ASC, date ASC, id ASC
                """).map {
                    Row2(threadId: $0["threadId"], date: $0["date"],
                         isFromUser: ($0["isFromUser"] as Int) != 0)
                }
        }) ?? []

        var latencies: [Double] = []
        var currentThread: String? = nil
        var pendingInbound: Double? = nil // most recent unanswered inbound in this thread

        for row in rows {
            if row.threadId != currentThread {
                currentThread = row.threadId
                pendingInbound = nil
            }
            if row.isFromUser {
                if let inbound = pendingInbound {
                    latencies.append(row.date - inbound)
                    pendingInbound = nil
                }
            } else {
                pendingInbound = row.date // arm/refresh with the latest inbound
            }
        }

        guard !latencies.isEmpty else { return ReplyLatency(medianSeconds: 0, count: 0) }
        let sorted = latencies.sorted()
        let n = sorted.count
        let median: Double
        if n % 2 == 1 {
            median = sorted[n / 2]
        } else {
            median = (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        }
        return ReplyLatency(medianSeconds: median, count: n)
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/SenaniAnalytics && swift test`
Expected: PASS — odd-median=200/count3, even-median=200/count2, most-recent-inbound=70/count1, no-reply=0/count0, empty=0/count0.

- [ ] **Step 5: Commit**

```bash
git add Packages/SenaniAnalytics/Sources/SenaniAnalytics/AnalyticsQueries.swift Packages/SenaniAnalytics/Tests/SenaniAnalyticsTests/ReplyLatencyTests.swift
git commit -m "feat(analytics): replyLatency (median inbound->reply per thread)" -m "$(cat <<'EOF'

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

### Task 6: `ruleActivity`

**Files:**
- Edit: `Packages/SenaniAnalytics/Sources/SenaniAnalytics/AnalyticsQueries.swift`
- Create: `Packages/SenaniAnalytics/Tests/SenaniAnalyticsTests/RuleActivityTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniAnalytics/Tests/SenaniAnalyticsTests/RuleActivityTests.swift`:

```swift
import Testing
import Foundation
import GRDB
@testable import SenaniAnalytics

@Suite struct RuleActivityTests {
    private let base = AnalyticsFixture.epoch2026

    private func seeded() throws -> AnalyticsQueries {
        let q = try AnalyticsFixture.makeReader()
        try q.write { db in
            // rule "r1": 2 executed, 1 prepared, 1 queued  (all after `since`)
            try AnalyticsFixture.insertAction(db, ruleId: "r1", outcome: "executed", messageId: "m1", date: base + 10)
            try AnalyticsFixture.insertAction(db, ruleId: "r1", outcome: "executed", messageId: "m2", date: base + 20)
            try AnalyticsFixture.insertAction(db, ruleId: "r1", outcome: "prepared", messageId: "m3", date: base + 30)
            try AnalyticsFixture.insertAction(db, ruleId: "r1", outcome: "queuedForApproval", messageId: "m4", date: base + 40)
            // rule "r2": 1 queued
            try AnalyticsFixture.insertAction(db, ruleId: "r2", outcome: "queuedForApproval", messageId: "m5", date: base + 50)
            // chat-triggered (ruleId NULL) must be excluded
            try AnalyticsFixture.insertAction(db, ruleId: nil, outcome: "executed", messageId: "m6", date: base + 60)
            // a row BEFORE `since` must be excluded
            try AnalyticsFixture.insertAction(db, ruleId: "r1", outcome: "executed", messageId: "m0", date: base - 100)
        }
        return AnalyticsFixture.makeQueries(q)
    }

    @Test func aggregatesPerRuleByOutcomeSinceCutoff() throws {
        let result = try seeded().ruleActivity(since: Date(timeIntervalSince1970: base))
        #expect(result == [
            RuleActivity(ruleId: "r1", executed: 2, prepared: 1, queued: 1),
            RuleActivity(ruleId: "r2", executed: 0, prepared: 0, queued: 1),
        ])
    }

    @Test func excludesChatTriggeredAndPreCutoffRows() throws {
        let result = try seeded().ruleActivity(since: Date(timeIntervalSince1970: base))
        // r1.executed is 2, not 3 (the base-100 row is excluded); no NULL-rule entry exists.
        let r1 = result.first { $0.ruleId == "r1" }
        #expect(r1?.executed == 2)
        #expect(!result.contains { $0.ruleId == "" })
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/SenaniAnalytics && swift test`
Expected: FAIL — `value of type 'AnalyticsQueries' has no member 'ruleActivity'`.

- [ ] **Step 3: Write the minimal implementation**

Add to `AnalyticsQueries` in `AnalyticsQueries.swift`:

```swift
    /// Per-rule automation activity from `actions_log` at or after `since`,
    /// counting `executed` / `prepared` / `queuedForApproval` outcomes.
    /// Chat-triggered rows (NULL `ruleId`) are excluded. Ordered by ruleId ascending.
    public func ruleActivity(since: Date) -> [RuleActivity] {
        let cutoff = since.timeIntervalSince1970
        return (try? reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT
                    ruleId,
                    SUM(CASE WHEN outcome = 'executed' THEN 1 ELSE 0 END) AS executed,
                    SUM(CASE WHEN outcome = 'prepared' THEN 1 ELSE 0 END) AS prepared,
                    SUM(CASE WHEN outcome = 'queuedForApproval' THEN 1 ELSE 0 END) AS queued
                FROM actions_log
                WHERE ruleId IS NOT NULL AND date >= ?
                GROUP BY ruleId
                ORDER BY ruleId ASC
                """, arguments: [cutoff])
                .map {
                    RuleActivity(
                        ruleId: $0["ruleId"],
                        executed: $0["executed"],
                        prepared: $0["prepared"],
                        queued: $0["queued"]
                    )
                }
        }) ?? []
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/SenaniAnalytics && swift test`
Expected: PASS — r1=(2,1,1), r2=(0,0,1); the NULL-rule row and the pre-cutoff row are excluded.

- [ ] **Step 5: Run the full suite once more and commit**

Run: `cd Packages/SenaniAnalytics && swift test`
Expected: PASS — entire `SenaniAnalyticsTests` suite green across all five queries.

```bash
git add Packages/SenaniAnalytics/Sources/SenaniAnalytics/AnalyticsQueries.swift Packages/SenaniAnalytics/Tests/SenaniAnalyticsTests/RuleActivityTests.swift
git commit -m "feat(analytics): ruleActivity (aggregate actions_log by rule/outcome)" -m "$(cat <<'EOF'

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## What this plan deliberately leaves out (next plans / reconciliation)

- **Real `SenaniDatabase` wiring.** This package codes against an assumed `reader: DatabaseReader` seam and a `messages`/`actions_log` schema (see "Cross-package assumptions"). Reconcile with SenaniStore: make `SenaniDatabase` conform to `SenaniDatabaseReadable`, or adjust the SQL/column names if they differ. No public API of this package changes.
- **`rule_runs` analytics** (simulation throughput, per-rule match rates). Spec §10 sources rule activity from `actions_log`; `rule_runs`-derived metrics are a follow-up.
- **Timezone-aware day bucketing.** `volumeByDay` uses UTC days; user-local-day bucketing is a documented follow-up (would take a `TimeZone`/`Calendar` parameter).
- **Chat-queryable surface.** Spec §10 notes "the same data is chat-queryable" — the Assistant layer consumes these typed structs; not in this package.
- **SwiftUI dashboard.** The cockpit dashboard renders these structs; out of scope here (read-only query layer only).

---

## Self-Review

**Spec coverage (§10):** "Who emails you most / top senders" → `topSenders` (Task 2). "Top domains clogging the inbox" → `topDomains` (Task 3). "Volume over time" → `volumeByDay` (Task 4). "Reply-latency" → `replyLatency` (Task 5, precisely defined + median for odd/even/most-recent-inbound/no-reply). "Rule/agent activity sourced from actions_log" → `ruleActivity` (Task 6). Read-only, no new action types, independent of the engine — the package has no write path, no network, no model dependency. Deferred §10 items (chat surface, dashboard UI) are listed as out of scope.

**Testability rule:** every query is its own TDD task with a real failing Swift Testing test → run-to-fail `cd Packages/SenaniAnalytics && swift test` with expected failure → minimal real Swift impl → run-to-pass → real git commit (with the required trailer). All fixtures pass **explicit epoch timestamps** (`AnalyticsFixture.epoch2026` and offsets) — no test reads the current date. The in-memory database + `AnalyticsFixture` seeding helper is defined in Task 1 (test target only), satisfying "in-memory SenaniDatabase, seed fixtures, assert aggregates." No external deps, no network, no model.

**Cross-package assumptions stated up front:** the assumed `messages` schema (id, from, senderDomain, date, isFromUser, threadId), the assumed `actions_log` schema (id, ruleId, outcome, messageId, date), the `Outcome` string mapping (`executed`/`prepared`/`queuedForApproval` = `SenaniRules.Outcome` raw values), the `reader: DatabaseReader` seam, in-memory construction, NULL-ruleId exclusion, and UTC day bucketing — each with a reconciliation note for when real SenaniStore contracts land.

**Placeholder scan:** no TBD/TODO/"similar to Task N"/"handle edge cases". Every code step is complete, compilable Swift; every SQL string names only assumed-schema columns. The one async/await subtlety (sync query methods) is called out and the canonical sync test style is fixed in Task 2 Step 5 and used from Task 3 onward.

**Type consistency:** result structs `SenderCount(address:count:)`, `DomainCount(domain:count:)`, `VolumePoint(date:count:)`, `ReplyLatency(medianSeconds:count:)`, `RuleActivity(ruleId:executed:prepared:queued:)`; service `AnalyticsQueries` with `init(database:)` (production, via `SenaniDatabaseReadable.reader`) and `init(reader:)` (tests), plus `topSenders(limit:)`, `topDomains(limit:)`, `volumeByDay(from:to:)`, `replyLatency()`, `ruleActivity(since:)`. Test helper `AnalyticsFixture` (`makeReader`, `makeQueries`, `insertMessage`, `insertAction`, `epoch2026`) is reused by all five suites in the same test target.
