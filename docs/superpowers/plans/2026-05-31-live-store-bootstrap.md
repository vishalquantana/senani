# Live Store Bootstrap (Phase 0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the app-tier `StoreBootstrap` that, on launch, resolves the app's Application Support directory, opens a **file-backed** `SenaniDatabase` there (which runs every migration), and constructs the **live persistent store seams** the composition root consumes — `MessageStore`, `RuleStore`, `ApprovalStore`, `RuleRunStore`, `PersistentAuditLog`, and the real `SqliteVecIndex` — all sharing **one** `SenaniDatabase`. This is the Phase-0 "Local store schema + vector search" foundation (ROADMAP Phase 0). It produces the bootstrap function the app shell's composition root (`AppEnvironment.live()`, owned by the app-shell plan) calls; it does NOT build `AppEnvironment`, Gmail, MLX, or any UI.

**Architecture:** A single value type `StoreBootstrap` living in the existing `SenaniApp` executable package (the app tier). It owns exactly two responsibilities: (1) **path resolution** — compute the on-disk SQLite file URL under `~/Library/Application Support/<bundle>/`, creating the directory if missing; (2) **graph construction** — open `SenaniDatabase.file(at:)` once and hand back a small `LiveStore` bundle holding the six store seams over that one database. Because `SenaniDatabase.file(at:)` runs `SenaniMigrations.migrator().migrate(queue)` inside the static factory, opening the file IS running the migrations — there is no separate migrate step to call. The `SqliteVecIndex` is wired to the **same** `SenaniDatabase` instance (not a second connection), so vectors persist in the same file as mail/rules/audit. Everything is injectable: the directory resolver and the audit clock are closures so tests use a temp directory and a deterministic clock, never the real Application Support dir.

**Tech Stack:** Swift 6.2 (toolchain `swift-tools-version: 5.9` as the existing `SenaniApp/Package.swift` declares; strict concurrency as the engine packages use), Swift Package Manager, Swift Testing (`import Testing`, ships with the toolchain). macOS 14+. Depends only on the already-built-and-frozen `SenaniStore` (and transitively `SenaniRules`). No MLX, no Gmail, no SwiftUI in the bootstrap or its tests.

**Working directory:** All `swift` commands run from `/Users/vishalkumar/Downloads/qmail/SenaniApp/` unless stated otherwise. (The bootstrap ships **inside** the `SenaniApp` executable package, which already path-depends on `SenaniStore`; see §"Cross-package assumptions".)

**Design references:** `docs/ARCHITECTURE.md` ("Local store (SQLite + vectors)"), `docs/ROADMAP.md` Phase 0, and `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md` §2 (real `SenaniStore` signatures), §3 (composition root — this plan provides what `AppEnvironment.live()` calls), §4 (conventions), §5 (sqlite-vec open pin — **resolved below**).

**Out of scope (separate plans):** `AppEnvironment` itself and the full live object graph (app-shell plan, §3); the `any TextGenerator`/`any Embedder` (MLX picker plan); `GmailAuth`/`KeychainTokenStore` (onboarding plan); the `Orchestrator`/`Scheduler` (`SenaniEngine` plan); all SwiftUI screens. This plan delivers only the **store bootstrap function** those plans compose.

---

## Cross-package assumptions (state these to the human before coding)

This plan codes against the **actual built `SenaniStore` source** (read from `Packages/SenaniStore/Sources/SenaniStore/**`), which is authoritative over the prose in the reconciliation doc. Where the built API differs from APP-PLANS-RECONCILIATION §2, the **built API wins** and the deviation is recorded here.

- **`SenaniStore` (built + frozen, do NOT edit):**
  - `public final class SenaniDatabase: @unchecked Sendable`
    - `public let queue: DatabaseQueue`
    - `public static func inMemory() throws -> SenaniDatabase`
    - `public static func file(at path: String) throws -> SenaniDatabase` — **takes a `String` path, not a `URL`.** Both factories run `SenaniMigrations.migrator().migrate(queue)` internally, so **opening = migrating**. Re-opening the same file is idempotent (GRDB `DatabaseMigrator` tracks applied versions).
  - Migrations create these 11 canonical tables (v1–v4): `rules`, `rule_runs`, `actions_log`, `approvals`, `documents`, `document_fields`, `voice_profile`, `needs_reply`, `chat_sessions`, `vec_items`, `messages`.
  - `public struct MessageStore: Sendable` — `init(database:)`; `save(_:) throws`, `saveAll(_:) throws`, `fetch(id:) throws -> Message?`, `thread(id:) throws -> [Message]` (date asc), `query(from:to:isFromUser:limit:) throws -> [Message]` (date desc), `all() throws -> [Message]`. **Note:** `public let database: SenaniDatabase` is exposed.
  - `public struct RuleStore: Sendable` — `init(database:)`; `save(_:) throws`, `fetch(id:) throws -> Rule?`, `all() throws -> [Rule]`, `enabled() throws -> [Rule]`, `delete(id:) throws`.
  - `public struct ApprovalStore: Sendable` — **`init(database:, now: @escaping @Sendable () -> Double)`** (the reconciliation doc omitted the `now:` clock — the built initializer **requires** it); `enqueue(id: String, _ proposal: Proposal) throws` (caller supplies the id), `pending() throws -> [StoredProposal]`, `approve(id:) throws`, `reject(id:) throws`. `public struct StoredProposal { let id; let proposal }`.
  - `public struct RuleRunStore: Sendable` — `init(database:)`; `record(_ run: RuleRun) throws`, `runs(ruleId:) throws -> [RuleRun]`, `all() throws -> [RuleRun]`. `public struct RuleRun { ruleId; kind(.simulation/.live); ranAt; messageId; matched; outcomes }`.
  - `public actor PersistentAuditLog: SenaniRules.AuditLog` — `init(database:, now: @escaping @Sendable () -> Double)`; `record(_:) async`, `records() throws -> [AuditEntry]`. `public struct AuditEntry { record; loggedAt }`.
  - `public protocol VectorIndex: Sendable` — `insert(id:vector:metadata:) throws`, `search(vector:k:) throws -> [VectorHit]`. `public struct VectorHit { id; distance; metadata }`.
  - `public final class InMemoryVectorIndex: VectorIndex` (tests) and **`public final class SqliteVecIndex: VectorIndex, @unchecked Sendable`** — `init(database: SenaniDatabase, namespace: String = "default")` and `static func inMemory(namespace: String = "default") throws -> SqliteVecIndex`. **(Reconciliation §2 hinted a `dimension:` arg — the built API uses `namespace:`, not `dimension:`.)**

- **`SenaniRules` (built + frozen):** `public struct Message: Sendable, Equatable, Identifiable` with `init(id:from:to:subject:body:hasAttachment:listUnsubscribeHeader:labels:threadId:date:isFromUser:)` and computed `senderDomain`. Used only to construct round-trip fixtures in tests.

- **The sqlite-vec open pin — RESOLVED (read from built source):** The built `SqliteVecIndex` does **NOT** load any native sqlite-vec C extension and `SenaniStore/Package.swift` has **no `sqlite-vec` dependency at all** (its only external dep is `GRDB.swift`). `SqliteVecIndex` stores each vector as a little-endian `Float32` blob in the plain `vec_items` table (created by migration `v3_vectors`) and computes cosine distance in pure Swift at query time (reusing `InMemoryVectorIndex.cosine`), returning the `k` nearest as `VectorHit`s sorted by `(distance, id)`. **There is therefore no native-extension load path, no init symbol, and no "did the extension load?" branch to detect** — the persisted-rows brute-force path is the one and only implementation. The frozen test `sqliteVecIndexFallbackUsesPersistedRows` (in `Packages/SenaniStore/Tests/SenaniStoreTests/StoreContractTests.swift`) pins exactly this behavior: insert two vectors, search, get the nearest by id. **Consequence for this plan:** the live app constructs `SqliteVecIndex(database:namespace:)` against the same file db and gets durable, dependency-free vector search; no `SENANI_RUN_VEC_INTEGRATION` gating, no Hugging Face / C-library prerequisite, no fallback flag. The "open pin" is closed: the live index needs nothing beyond the existing GRDB-backed `SenaniDatabase`.

- **`SenaniApp` (the executable package this bootstrap lives in):** already declares `.executableTarget(name: "SenaniApp", …)` depending on `SenaniStore` (and the other engine packages). It currently has **no test target.** This plan adds a `.testTarget(name: "SenaniAppTests", dependencies: ["SenaniApp"])` so the bootstrap is unit-tested. The existing `SenaniApp.swift` composition root (which today opens `SenaniDatabase.inMemory()` with a TODO to go file-backed) is updated in the final task to call `StoreBootstrap`.

---

## File Structure

```
SenaniApp/
  Package.swift                                  # add test target (Task 1)
  Sources/SenaniApp/
    Store/
      StoreBootstrap.swift                       # path resolution + LiveStore construction (Tasks 2–4)
    SenaniApp.swift                              # composition root: call StoreBootstrap (Task 5)
  Tests/SenaniAppTests/
    StoreBootstrapTests.swift                    # all bootstrap tests (Tasks 2–4)
```

`StoreBootstrap.swift` has one responsibility: turn "an Application Support directory + a clock" into "a `LiveStore` over one file-backed `SenaniDatabase`." Path resolution and graph construction change together, so they live together. The composition root (`AppEnvironment.live()`, owned by the app-shell plan) consumes `LiveStore`; the only edit this plan makes outside `Store/` is replacing the placeholder in-memory wiring in `SenaniApp.swift`.

---

## Task 1: Add a test target to the SenaniApp package

**Files:**
- Edit: `/Users/vishalkumar/Downloads/qmail/SenaniApp/Package.swift`
- Create: `/Users/vishalkumar/Downloads/qmail/SenaniApp/Tests/SenaniAppTests/StoreBootstrapTests.swift` (placeholder import-only test)

The `SenaniApp` package has no test target. Add one so the bootstrap can be TDD'd.

- [ ] **Step 1: Write a failing import test**

Create `/Users/vishalkumar/Downloads/qmail/SenaniApp/Tests/SenaniAppTests/StoreBootstrapTests.swift`:

```swift
import Testing
@testable import SenaniApp
import SenaniStore
import SenaniRules

@Suite struct StoreBootstrapTests {
    @Test func packageAndStoreDepsLink() throws {
        // Proves the test target builds and links SenaniStore + SenaniRules.
        let db = try SenaniDatabase.inMemory()
        let count = try db.queue.read { conn in
            try Int.fetchOne(conn, sql: "SELECT count(*) FROM messages")
        }
        #expect(count == 0)
    }
}
```

> **Note:** `Int.fetchOne(_:sql:)` is GRDB API; `@testable import SenaniApp` transitively exposes `GRDB` symbols used on `db.queue`. If the bare `db.queue.read { ... }` closure cannot resolve `Int.fetchOne` because `GRDB` is not importable from the test target, add `import GRDB` to the test file (GRDB is a transitive product of `SenaniStore`). Prefer NOT importing GRDB if it resolves without it.

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test
```

Expected: failure — no `SenaniAppTests` target exists, so SwiftPM reports it cannot find the test target / "no tests found" (manifest has no testTarget). If the manifest already built once, the error is that the `Tests/SenaniAppTests` directory is not part of any declared target.

- [ ] **Step 3: Add the test target to the manifest**

Edit `/Users/vishalkumar/Downloads/qmail/SenaniApp/Package.swift`, replacing the `targets:` array so it includes a test target (keep the existing `executableTarget` exactly as-is):

```swift
    targets: [
        .executableTarget(
            name: "SenaniApp",
            dependencies: [
                "SenaniRules",
                "SenaniStore",
                "SenaniInference",
                "SenaniGmail",
                "SenaniVoice",
                "SenaniDocs",
                "SenaniReplyZero",
                "SenaniAnalytics",
                "SenaniAssistant",
            ]
        ),
        .testTarget(
            name: "SenaniAppTests",
            dependencies: ["SenaniApp"]
        ),
    ]
```

> **Note on testing an executable target:** SwiftPM can test an `executableTarget` by depending on it from a `testTarget` and using `@testable import SenaniApp`. The `@main`-annotated `SenaniApp` struct still compiles into the module; the test target links the module, it does not run `main`. No change to `SenaniApp.swift` is needed for this task.

- [ ] **Step 4: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test
```

Expected: 1 test passes (`packageAndStoreDepsLink`). SwiftPM resolves all path deps and the in-memory migrator creates the `messages` table, so the count query returns 0.

- [ ] **Step 5: Commit**

```
git add /Users/vishalkumar/Downloads/qmail/SenaniApp/Package.swift /Users/vishalkumar/Downloads/qmail/SenaniApp/Tests && git commit -m "$(cat <<'EOF'
SenaniApp: add test target for store bootstrap

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Application Support path resolution

**Files:**
- Create: `/Users/vishalkumar/Downloads/qmail/SenaniApp/Sources/SenaniApp/Store/StoreBootstrap.swift`
- Edit: `/Users/vishalkumar/Downloads/qmail/SenaniApp/Tests/SenaniAppTests/StoreBootstrapTests.swift`

Resolve the on-disk SQLite file location under Application Support, creating the directory if needed. The directory is injectable so tests pass a temp directory and never touch the real `~/Library/Application Support`.

- [ ] **Step 1: Write failing path tests**

Add to `StoreBootstrapTests.swift` (keep the existing `packageAndStoreDepsLink` test):

```swift
import Foundation

@Suite struct StoreBootstrapPathTests {
    @Test func resolvesDatabaseFileUnderProvidedSupportDirectory() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("senani-bootstrap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let url = try StoreBootstrap.databaseURL(
            applicationSupport: temp,
            fileName: "senani.sqlite"
        )

        // The app subdirectory and the file path are nested under the support dir.
        #expect(url.lastPathComponent == "senani.sqlite")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Senani")
        // The containing directory is created as a side effect.
        var isDir: ObjCBool = false
        let dirExists = FileManager.default.fileExists(
            atPath: url.deletingLastPathComponent().path, isDirectory: &isDir
        )
        #expect(dirExists)
        #expect(isDir.boolValue)
    }

    @Test func resolvingTwiceIsIdempotent() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("senani-bootstrap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let first = try StoreBootstrap.databaseURL(applicationSupport: temp, fileName: "senani.sqlite")
        let second = try StoreBootstrap.databaseURL(applicationSupport: temp, fileName: "senani.sqlite")
        #expect(first == second)
    }

    @Test func defaultApplicationSupportDirectoryIsUnderLibrary() throws {
        // The production resolver points inside the user's Application Support; we only
        // assert the shape, never create the real directory in tests.
        let dir = StoreBootstrap.defaultApplicationSupportDirectory()
        #expect(dir.path.contains("Application Support"))
    }
}
```

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter StoreBootstrapPathTests
```

Expected: failure — `cannot find 'StoreBootstrap' in scope`.

- [ ] **Step 3: Implement path resolution**

Create `/Users/vishalkumar/Downloads/qmail/SenaniApp/Sources/SenaniApp/Store/StoreBootstrap.swift`:

```swift
import Foundation
import SenaniStore

/// App-tier bootstrap for the live, file-backed persistence layer.
///
/// Resolves the on-disk SQLite file under Application Support, opens a single
/// `SenaniDatabase` there (which runs all migrations), and constructs the live
/// store seams the composition root consumes. Everything is injectable so tests
/// use a temp directory and a deterministic clock — never the real
/// `~/Library/Application Support`.
public enum StoreBootstrap {
    /// The app-specific subdirectory name inside Application Support.
    public static let appDirectoryName = "Senani"

    /// The default SQLite file name inside the app directory.
    public static let defaultFileName = "senani.sqlite"

    /// The user's Application Support directory. NOT created here; callers pass
    /// it (or a temp dir in tests) to `databaseURL(applicationSupport:fileName:)`.
    public static func defaultApplicationSupportDirectory() -> URL {
        // .applicationSupportDirectory in the user domain. If the lookup fails
        // (sandbox edge cases), fall back to a deterministic Library path so the
        // app always has a writable home.
        if let url = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            return url
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// Resolves the SQLite file URL under `applicationSupport/<appDirectoryName>/`,
    /// creating the app directory (with intermediates) if it does not exist.
    public static func databaseURL(
        applicationSupport: URL,
        fileName: String = defaultFileName
    ) throws -> URL {
        let appDirectory = applicationSupport
            .appendingPathComponent(appDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: appDirectory, withIntermediateDirectories: true
        )
        return appDirectory.appendingPathComponent(fileName, isDirectory: false)
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter StoreBootstrapPathTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```
git add /Users/vishalkumar/Downloads/qmail/SenaniApp/Sources/SenaniApp/Store /Users/vishalkumar/Downloads/qmail/SenaniApp/Tests && git commit -m "$(cat <<'EOF'
SenaniApp: StoreBootstrap resolves Application Support DB path

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Open the file-backed database + build the LiveStore seams

**Files:**
- Edit: `/Users/vishalkumar/Downloads/qmail/SenaniApp/Sources/SenaniApp/Store/StoreBootstrap.swift`
- Edit: `/Users/vishalkumar/Downloads/qmail/SenaniApp/Tests/SenaniAppTests/StoreBootstrapTests.swift`

Open `SenaniDatabase.file(at:)` once (which runs migrations) and assemble a `LiveStore` value holding the six seams over that one database. The audit clock is injected.

- [ ] **Step 1: Write failing bootstrap tests**

Add to `StoreBootstrapTests.swift`:

```swift
import SenaniRules

@Suite struct StoreBootstrapLiveStoreTests {
    private func tempSupport() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("senani-bootstrap-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func openCreatesFileAndCanonicalTables() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }

        let store = try StoreBootstrap.open(applicationSupport: support, now: { 0 })

        // The file exists on disk after opening.
        #expect(FileManager.default.fileExists(atPath: store.databaseURL.path))

        // Migrations ran: every canonical table is present.
        let tables = try store.database.queue.read { db -> Set<String> in
            let names = try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            )
            return Set(names)
        }
        let expected: Set<String> = [
            "rules", "rule_runs", "actions_log", "documents", "document_fields",
            "voice_profile", "needs_reply", "chat_sessions", "approvals", "vec_items",
            "messages",
        ]
        #expect(expected.isSubset(of: tables), "missing: \(expected.subtracting(tables))")
    }

    @Test func allSeamsShareTheSameDatabase() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }

        let store = try StoreBootstrap.open(applicationSupport: support, now: { 0 })

        // MessageStore exposes its database; it must be the same instance the
        // bootstrap opened (one connection for the whole graph).
        #expect(store.messages.database === store.database)
    }

    @Test func auditClockIsInjected() async throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }

        let store = try StoreBootstrap.open(applicationSupport: support, now: { 1234 })
        await store.audit.record(ActionRecord(
            action: .archive, messageId: "m1", trigger: .rule(id: "r1"), outcome: .executed
        ))
        let entries = try await store.audit.records()
        #expect(entries.count == 1)
        #expect(entries[0].loggedAt == 1234)
    }
}
```

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter StoreBootstrapLiveStoreTests
```

Expected: failure — `StoreBootstrap.open` and `LiveStore` are undefined (`type 'StoreBootstrap' has no member 'open'`).

- [ ] **Step 3: Implement `LiveStore` + `StoreBootstrap.open`**

Add to `/Users/vishalkumar/Downloads/qmail/SenaniApp/Sources/SenaniApp/Store/StoreBootstrap.swift` (append below the existing `StoreBootstrap` enum; add no new imports — `Foundation` and `SenaniStore` are already imported):

```swift
/// The live, file-backed persistence seams, all sharing ONE `SenaniDatabase`.
/// The composition root (`AppEnvironment.live()`, owned by the app-shell plan)
/// consumes this; no screen or agent constructs a store itself (RECONCILIATION §4).
public struct LiveStore: Sendable {
    public let databaseURL: URL
    public let database: SenaniDatabase
    public let messages: MessageStore
    public let rules: RuleStore
    public let approvals: ApprovalStore
    public let ruleRuns: RuleRunStore
    public let audit: PersistentAuditLog
    public let index: SqliteVecIndex

    init(
        databaseURL: URL,
        database: SenaniDatabase,
        messages: MessageStore,
        rules: RuleStore,
        approvals: ApprovalStore,
        ruleRuns: RuleRunStore,
        audit: PersistentAuditLog,
        index: SqliteVecIndex
    ) {
        self.databaseURL = databaseURL
        self.database = database
        self.messages = messages
        self.rules = rules
        self.approvals = approvals
        self.ruleRuns = ruleRuns
        self.audit = audit
        self.index = index
    }
}

public extension StoreBootstrap {
    /// Opens (creating if needed) the file-backed live store under `applicationSupport`.
    ///
    /// `SenaniDatabase.file(at:)` runs every migration as it opens, so this single
    /// call also creates the canonical schema. All six seams share the one
    /// `SenaniDatabase` instance, and the `SqliteVecIndex` is wired to the SAME
    /// database/file (durable, dependency-free cosine search over `vec_items`).
    ///
    /// - Parameters:
    ///   - applicationSupport: the Application Support directory (a temp dir in tests).
    ///   - fileName: the SQLite file name inside the app directory.
    ///   - vectorNamespace: the namespace for the live vector index.
    ///   - now: epoch-seconds clock injected into the audit log and approval store
    ///          (production passes `{ Date().timeIntervalSince1970 }`).
    static func open(
        applicationSupport: URL,
        fileName: String = defaultFileName,
        vectorNamespace: String = "default",
        now: @escaping @Sendable () -> Double
    ) throws -> LiveStore {
        let url = try databaseURL(applicationSupport: applicationSupport, fileName: fileName)
        let database = try SenaniDatabase.file(at: url.path)
        return LiveStore(
            databaseURL: url,
            database: database,
            messages: MessageStore(database: database),
            rules: RuleStore(database: database),
            approvals: ApprovalStore(database: database, now: now),
            ruleRuns: RuleRunStore(database: database),
            audit: PersistentAuditLog(database: database, now: now),
            index: SqliteVecIndex(database: database, namespace: vectorNamespace)
        )
    }

    /// Production convenience: open under the real Application Support directory
    /// with the wall-clock. The composition root calls this; tests call `open(...)`
    /// with a temp dir.
    static func live(
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) throws -> LiveStore {
        try open(applicationSupport: defaultApplicationSupportDirectory(), now: now)
    }
}
```

> **Note on `===`:** the test `allSeamsShareTheSameDatabase` compares `store.messages.database === store.database`. `MessageStore` exposes `public let database: SenaniDatabase` and `SenaniDatabase` is a `final class`, so identity comparison is valid and proves one shared connection.

- [ ] **Step 4: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter StoreBootstrapLiveStoreTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```
git add /Users/vishalkumar/Downloads/qmail/SenaniApp/Sources/SenaniApp/Store /Users/vishalkumar/Downloads/qmail/SenaniApp/Tests && git commit -m "$(cat <<'EOF'
SenaniApp: StoreBootstrap.open builds live seams over one file-backed db

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Round-trip + persistence-across-reopen + live vector search

**Files:**
- Edit: `/Users/vishalkumar/Downloads/qmail/SenaniApp/Tests/SenaniAppTests/StoreBootstrapTests.swift`

No new production code — these tests verify the bootstrap delivers a *working* durable store: data saved through a seam survives reopening the same file path, and the live `SqliteVecIndex` does an insert+search round-trip over the file.

- [ ] **Step 1: Write the durability + vector tests**

Add to `StoreBootstrapTests.swift`:

```swift
@Suite struct StoreBootstrapDurabilityTests {
    private func tempSupport() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("senani-bootstrap-\(UUID().uuidString)", isDirectory: true)
    }

    private func message(_ id: String, threadId: String = "t1") -> Message {
        Message(
            id: id, from: "sender@example.com", to: ["me@example.com"],
            subject: "Subject \(id)", body: "Body \(id)", hasAttachment: false,
            listUnsubscribeHeader: nil, labels: ["Inbox"], threadId: threadId,
            date: Date(timeIntervalSince1970: 100), isFromUser: false
        )
    }

    @Test func messageRoundTripsThroughMessageStore() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }

        let store = try StoreBootstrap.open(applicationSupport: support, now: { 0 })
        try store.messages.save(message("m1"))
        let fetched = try store.messages.fetch(id: "m1")
        #expect(fetched?.id == "m1")
        #expect(fetched?.subject == "Subject m1")
        #expect(fetched?.senderDomain == "example.com")
    }

    @Test func dataSurvivesReopeningTheSameFilePath() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }

        // First session: write a message, then drop the handle.
        do {
            let store = try StoreBootstrap.open(applicationSupport: support, now: { 0 })
            try store.messages.save(message("persist-1"))
        }

        // Second session: reopen the SAME support dir / file path and read it back.
        let reopened = try StoreBootstrap.open(applicationSupport: support, now: { 0 })
        let fetched = try reopened.messages.fetch(id: "persist-1")
        #expect(fetched?.id == "persist-1")
        #expect(try reopened.messages.all().map(\.id) == ["persist-1"])
    }

    @Test func liveVectorIndexInsertAndSearchRoundTrips() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }

        let store = try StoreBootstrap.open(applicationSupport: support, now: { 0 })
        try store.index.insert(id: "x", vector: [1, 0, 0], metadata: ["kind": "exact"])
        try store.index.insert(id: "y", vector: [0, 1, 0], metadata: [:])
        try store.index.insert(id: "z", vector: [0.9, 0.1, 0], metadata: ["kind": "near"])

        let hits = try store.index.search(vector: [1, 0, 0], k: 2)
        #expect(hits.map(\.id) == ["x", "z"])
        #expect(hits[0].metadata["kind"] == "exact")
    }

    @Test func vectorsSurviveReopeningTheSameFilePath() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }

        do {
            let store = try StoreBootstrap.open(applicationSupport: support, now: { 0 })
            try store.index.insert(id: "v1", vector: [1, 0], metadata: ["m": "v1"])
        }
        let reopened = try StoreBootstrap.open(applicationSupport: support, now: { 0 })
        let hits = try reopened.index.search(vector: [1, 0], k: 1)
        #expect(hits.first?.id == "v1")
        #expect(hits.first?.metadata["m"] == "v1")
    }
}
```

> **Why no `SENANI_RUN_VEC_INTEGRATION` gate:** the live `SqliteVecIndex` is pure-Swift cosine over persisted `vec_items` rows (see Cross-package assumptions). It needs no native extension, so the vector tests run unconditionally — they exercise exactly the production live path against a real file db.

- [ ] **Step 2: Run to fail (then pass)**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter StoreBootstrapDurabilityTests
```

Expected: with the Task-3 production code already in place, these compile and **pass** immediately (4 tests). If `messageRoundTripsThroughMessageStore` or the reopen tests fail, that is a real defect in how `open` shares the database or resolves the path — debug before proceeding (do not weaken the assertions).

- [ ] **Step 3: Run the full suite**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test
```

Expected: all suites green — `StoreBootstrapTests` (1), `StoreBootstrapPathTests` (3), `StoreBootstrapLiveStoreTests` (3), `StoreBootstrapDurabilityTests` (4) = 11 tests, 0 failures.

- [ ] **Step 4: Commit**

```
git add /Users/vishalkumar/Downloads/qmail/SenaniApp/Tests && git commit -m "$(cat <<'EOF'
SenaniApp: durability + live vector round-trip tests for StoreBootstrap

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Wire the live bootstrap into the composition root

**Files:**
- Edit: `/Users/vishalkumar/Downloads/qmail/SenaniApp/Sources/SenaniApp/SenaniApp.swift`

Replace the placeholder in-memory database in the app's composition root with the live, file-backed `StoreBootstrap`, falling back to in-memory only if the disk open fails (so the app still launches). This is the seam `AppEnvironment.live()` (app-shell plan) will eventually own; until that lands, `SenaniApp`'s `init` is the composition root.

- [ ] **Step 1: Replace the in-memory bootstrap with the live one**

In `/Users/vishalkumar/Downloads/qmail/SenaniApp/Sources/SenaniApp/SenaniApp.swift`, replace the `init()` body of `struct SenaniApp` (the lines that today construct `SenaniDatabase.inMemory()` with the TODO comment):

```swift
    init() {
        // Composition Root: open the live, file-backed store under Application
        // Support (runs migrations + wires the SqliteVecIndex to the same file).
        // If the disk open fails, fall back to in-memory so the app still launches.
        let state: AppState
        do {
            let live = try StoreBootstrap.live()
            state = AppState(live: live)
        } catch {
            let database = (try? SenaniDatabase.inMemory()) ?? (try! SenaniDatabase.inMemory())
            state = AppState(database: database)
        }
        _appState = State(initialValue: state)
    }
```

- [ ] **Step 2: Add a `LiveStore` initializer to `AppState`**

In the same file, extend `AppState` so it can be built from a `LiveStore` while keeping the existing in-memory `init(database:)` for the fallback and for previews. Replace the `AppState` initializer region:

```swift
@Observable
final class AppState {
    let database: SenaniDatabase
    let messageStore: MessageStore
    let ruleStore: RuleStore

    var selectedSidebarItem: NavigationItem? = .inbox

    /// Live path: reuse the seams the bootstrap already constructed over the
    /// shared file-backed database.
    init(live: LiveStore) {
        self.database = live.database
        self.messageStore = live.messages
        self.ruleStore = live.rules
    }

    /// Fallback / preview path: in-memory database.
    init(database: SenaniDatabase) {
        self.database = database
        self.messageStore = MessageStore(database: database)
        self.ruleStore = RuleStore(database: database)
    }
}
```

> **Note:** `AppState` currently only holds `messageStore`/`ruleStore`; the additional live seams (`approvals`, `ruleRuns`, `audit`, `index`) are carried by `LiveStore` and will be surfaced through `AppEnvironment` by the app-shell plan. This task only proves the live bootstrap is the launch path; it does not expand `AppState`'s public surface beyond what already exists.

- [ ] **Step 3: Build the executable**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift build
```

Expected: the `SenaniApp` executable target builds with no errors. (Launching the GUI is out of scope for this headless plan; a successful build proves the composition root compiles against the live bootstrap.)

- [ ] **Step 4: Run the full test suite again**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test
```

Expected: 11 tests still green (the composition-root edit does not touch tested code paths).

- [ ] **Step 5: Commit**

```
git add /Users/vishalkumar/Downloads/qmail/SenaniApp/Sources/SenaniApp/SenaniApp.swift && git commit -m "$(cat <<'EOF'
SenaniApp: composition root opens live file-backed store via StoreBootstrap

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

### Scope coverage (against the brief)
- **App-tier `StoreBootstrap` on launch** — `StoreBootstrap.open(applicationSupport:fileName:vectorNamespace:now:)` resolves the Application Support directory, opens `SenaniDatabase.file(at:)` (which runs migrations as it opens — verified in built `SenaniDatabase.swift`: both factories call `SenaniMigrations.migrator().migrate(queue)`), and constructs the **real** `SqliteVecIndex` wired to the same db. `StoreBootstrap.live()` is the production convenience the composition root calls (Task 5). ✓
- **sqlite-vec open pin RESOLVED** — documented in Cross-package assumptions: the built `SqliteVecIndex` loads **no** native extension, `SenaniStore/Package.swift` has **no sqlite-vec dependency**, and the index does pure-Swift cosine over Float32 blobs in `vec_items`. There is no init symbol and no "did the extension load" detection because there is no extension; the frozen `sqliteVecIndexFallbackUsesPersistedRows` test pins exactly this persisted-rows path, and this plan's live vector tests exercise it directly. ✓
- **Live store seams the composition root consumes** — `LiveStore` carries `MessageStore`, `RuleStore`, `ApprovalStore`, `RuleRunStore`, `PersistentAuditLog`, and `SqliteVecIndex`, all sharing one `SenaniDatabase` (proved by `allSeamsShareTheSameDatabase` via `===` on the exposed `MessageStore.database`). ✓
- **Tests** — migrations create the 11 canonical tables on a fresh file db (`openCreatesFileAndCanonicalTables`); MessageStore save/fetch round-trip on a temp file db (`messageRoundTripsThroughMessageStore`); `SqliteVecIndex` insert+search round-trip ungated (`liveVectorIndexInsertAndSearchRoundTrips`); data survives reopening the same file path (`dataSurvivesReopeningTheSameFilePath`, `vectorsSurviveReopeningTheSameFilePath`); audit clock injected (`auditClockIsInjected`). Every test uses a temp directory under `FileManager.default.temporaryDirectory` with a `defer` cleanup — **never the real Application Support dir.** ✓
- **Honors §4** — the composition root (Task 5) constructs these; this plan provides the `StoreBootstrap.live()`/`open(...)` function `AppEnvironment.live()` will call. No screen or agent constructs a store; everything flows through the single bootstrap. ✓

### Deviations from APP-PLANS-RECONCILIATION (built API wins, recorded)
- `ApprovalStore` requires `init(database:, now:)` and `enqueue(id:_:)` — §2 listed it without the clock and with a bare `save(_:)`; the plan codes to the built signature and injects `now`.
- `SqliteVecIndex` uses `init(database:namespace:)` / `inMemory(namespace:)` — §2 hinted `dimension:`; the plan uses the real `namespace:`.
- `SenaniDatabase.file(at:)` takes a `String` path, so the plan converts the resolved `URL` via `url.path`.
- `PersistentAuditLog.records()` is `throws` (sync) returning `[AuditEntry]` and `record(_:)` is `async` — matched exactly in `auditClockIsInjected`.
- No sqlite-vec SPM product/module/init-symbol exists to confirm; the §5 "open pin" is closed because the built index is extension-free (documented above), not deferred to a human.

### Placeholder scan
No "TBD / TODO / handle edge cases / similar to Task N." Every code block is complete, compilable Swift; every command is exact with the full `SenaniApp` path; every commit carries the required `Co-Authored-By: Claude Opus 4.8` trailer. The one production fallback (in-memory if disk open fails, Task 5) is real, intentional launch-resilience code, not a stub.

### Type/identity consistency
- `Message(id:from:to:subject:body:hasAttachment:listUnsubscribeHeader:labels:threadId:date:isFromUser:)` — matched exactly from built `SenaniRules.Message`.
- `ActionRecord(action:messageId:trigger:outcome:)`, `Action.archive`, `Trigger.rule(id:)`, `Outcome.executed` — used as in built `SenaniRules`.
- `LiveStore` is a `Sendable` value type holding the seams; `SenaniDatabase` is `@unchecked Sendable final class`, so `===` identity checks and the shared-connection guarantee hold.
- `MessageStore.database` is `public let`, enabling the shared-database assertion without reflection.

### Assumptions for the implementer to confirm at build time
- The `SenaniApp` package builds an executable that a `testTarget` can `@testable import`; if SwiftPM rejects testing the executable module on the installed toolchain, factor `StoreBootstrap`/`LiveStore` into a tiny internal library target the executable and tests both depend on (no API change — only target topology).
- GRDB symbols (`String.fetchAll`, `Int.fetchOne`) are reachable from the test target transitively through `SenaniStore`; if not, add `import GRDB` to the test file (GRDB is `SenaniStore`'s public dependency).
- The real `~/Library/Application Support/Senani/senani.sqlite` is created on first live launch; no entitlement beyond standard user-domain Application Support access is required for a non-sandboxed dev build. App sandbox/entitlements for a signed build are a Deferred-plan concern.
```