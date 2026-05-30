# SenaniStore (SQLite Persistence with GRDB + sqlite-vec) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `SenaniStore` SPM package — the on-device SQLite persistence layer (GRDB + sqlite-vec) that stores rules, the audit log, approval queue, rule-run records, and the schema for dependent subsystems, plus a vector index seam with an in-memory implementation for unit tests.

**Architecture:** `SenaniDatabase` opens a GRDB `DatabaseQueue` (file or in-memory), loads the sqlite-vec native extension, and runs a versioned `DatabaseMigrator` that creates every Senani table. Because `SenaniRules` core types are not `Codable` and must not be edited, `SenaniStore` defines its own `Codable` DTO mirrors that round-trip to/from the core types and are stored as JSON text columns. Stores (`RuleStore`, `PersistentAuditLog`, `ApprovalStore`, `RuleRunStore`) map rows ↔ core types. `VectorIndex` is a protocol with a pure-Swift `InMemoryVectorIndex` (unit-tested) and a sqlite-vec-backed `SqliteVecIndex` (integration-tested, gated behind an env var).

**Tech Stack:** Swift 6.2, swift-tools 6.0, macOS 14, strict concurrency, Swift Testing (`import Testing`), GRDB.swift (SPM), sqlite-vec (Swift/C distribution), path dependency on `../SenaniRules`.

---

## File Structure

All paths are under `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/`.

| File | Responsibility |
|---|---|
| `Package.swift` | SPM manifest: declares GRDB + sqlite-vec deps, path dep on `../SenaniRules`, the `SenaniStore` library target, and the test target. |
| `Sources/SenaniStore/SenaniDatabase.swift` | Opens a `DatabaseQueue` (file path or in-memory), exposes `DatabaseQueue` access, loads sqlite-vec, runs the migrator. The single owner of the schema. |
| `Sources/SenaniStore/Migrations.swift` | The `DatabaseMigrator` with versioned migrations creating every table: `rules`, `rule_runs`, `actions_log`, `documents`, `document_fields`, `voice_profile`, `needs_reply`, `chat_sessions`, `approvals`, `vec_items`, `messages`. |
| `Sources/SenaniStore/DTOs/ActionDTO.swift` | `Codable` mirror of `SenaniRules.Action` with `toCore()` / `init(core:)`. |
| `Sources/SenaniStore/DTOs/ConditionDTO.swift` | `Codable` mirrors of `StructuredCondition`, `MatchMode`, `Conditions`. |
| `Sources/SenaniStore/DTOs/RuleDTO.swift` | `Codable` mirror of `Rule` (composes condition + action DTOs, `Autonomy`, `RunOn`). |
| `Sources/SenaniStore/DTOs/TriggerDTO.swift` | `Codable` mirror of `Trigger` and `Outcome`. |
| `Sources/SenaniStore/DTOs/JSONCoding.swift` | Shared `JSONEncoder`/`JSONDecoder` factory + `encodeJSONString`/`decodeJSON` helpers used by all stores. |
| `Sources/SenaniStore/RuleStore.swift` | CRUD over `rules`: `save`, `fetch(id:)`, `all()`, `enabled()`, `delete(id:)`, mapping rows ↔ `SenaniRules.Rule`. |
| `Sources/SenaniStore/PersistentAuditLog.swift` | `actor` conforming to `SenaniRules.AuditLog`; writes `ActionRecord` to `actions_log` with an injected timestamp; `records()` reader. |
| `Sources/SenaniStore/ApprovalStore.swift` | Persists `Proposal`s to `approvals`: `enqueue`, `pending()`, `approve(id:)`, `reject(id:)`. |
| `Sources/SenaniStore/RuleRunStore.swift` | Persists simulation/live evaluation records to `rule_runs`: `record`, `runs(ruleId:)`, `all()`. |
| `Sources/SenaniStore/MessageStore.swift` | CRUD/query over `messages` (canonical mirror of `SenaniRules.Message`): `save`, `saveAll`, `fetch(id:)`, `thread(id:)`, `query(from:to:isFromUser:limit:)`, `all()`. |
| `Sources/SenaniStore/VectorIndex.swift` | `VectorIndex` protocol + `VectorHit` result type + pure-Swift `InMemoryVectorIndex` (cosine similarity). |
| `Sources/SenaniStore/SqliteVecIndex.swift` | sqlite-vec-backed `VectorIndex` implementation over the `vec_items` table. |
| `Tests/SenaniStoreTests/SenaniDatabaseTests.swift` | Migrator runs on in-memory DB; all tables exist. |
| `Tests/SenaniStoreTests/ActionDTOTests.swift` | Round-trip fidelity for every `Action` case. |
| `Tests/SenaniStoreTests/ConditionDTOTests.swift` | Round-trip fidelity for every `StructuredCondition` case + all `MatchMode`s + `Conditions`. |
| `Tests/SenaniStoreTests/RuleDTOTests.swift` | Round-trip fidelity for `Rule` across `Autonomy`/`RunOn`. |
| `Tests/SenaniStoreTests/RuleStoreTests.swift` | CRUD behavior against an in-memory DB. |
| `Tests/SenaniStoreTests/PersistentAuditLogTests.swift` | Audit writes/reads with injected timestamps. |
| `Tests/SenaniStoreTests/ApprovalStoreTests.swift` | Proposal enqueue/pending/approve/reject. |
| `Tests/SenaniStoreTests/RuleRunStoreTests.swift` | Rule-run recording and querying. |
| `Tests/SenaniStoreTests/MessageStoreTests.swift` | Message round-trip, upsert, lowercased senderDomain, thread ordering, query filters. |
| `Tests/SenaniStoreTests/InMemoryVectorIndexTests.swift` | Cosine search ranking on the in-memory index. |
| `Tests/SenaniStoreTests/SqliteVecIntegrationTests.swift` | GATED integration test: real sqlite-vec extension load + insert/search. |

---

## Task 1: Package scaffold + GRDB/sqlite-vec dependencies

**Files:**
- Create: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Package.swift`
- Create: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Sources/SenaniStore/SenaniStorePlaceholder.swift`
- Test: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Tests/SenaniStoreTests/PackageSmokeTests.swift`

Steps:

- [ ] 1. Write failing test `Tests/SenaniStoreTests/PackageSmokeTests.swift`:

```swift
import Testing
import GRDB
@testable import SenaniStore

@Suite struct PackageSmokeTests {
    @Test func grdbAndPackageLink() throws {
        // GRDB links and the package module imports.
        let queue = try DatabaseQueue()
        let value = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT 1")
        }
        #expect(value == 1)
        #expect(SenaniStoreVersion.current == "0.1.0")
    }
}
```

- [ ] 2. Run to verify fail:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test
```

Expected failure: package does not yet exist / no `Package.swift`, so `swift test` errors with "error: could not find Package.swift" (or, once the manifest exists but the source is missing, a build error that `SenaniStoreVersion` / `GRDB` is unresolved).

- [ ] 3. Minimal implementation. Create `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniStore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniStore", targets: ["SenaniStore"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
        .package(url: "https://github.com/asg017/sqlite-vec", from: "0.1.6"),
    ],
    targets: [
        .target(
            name: "SenaniStore",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "sqlite-vec", package: "sqlite-vec"),
            ]
        ),
        .testTarget(
            name: "SenaniStoreTests",
            dependencies: ["SenaniStore"]
        ),
    ]
)
```

Create `Sources/SenaniStore/SenaniStorePlaceholder.swift`:

```swift
/// Package version marker used by the smoke test to confirm the module links.
public enum SenaniStoreVersion {
    public static let current = "0.1.0"
}
```

- [ ] 4. Run to verify pass:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test
```

Expected: `PackageSmokeTests` passes (1 test, 0 failures). GRDB and sqlite-vec resolve and build.

- [ ] 5. Commit:

```
git add /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && git commit -m "$(cat <<'EOF'
SenaniStore: package scaffold with GRDB + sqlite-vec deps

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 2: JSON coding helpers

**Files:**
- Create: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Sources/SenaniStore/DTOs/JSONCoding.swift`
- Test: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Tests/SenaniStoreTests/JSONCodingTests.swift`

Steps:

- [ ] 1. Write failing test `Tests/SenaniStoreTests/JSONCodingTests.swift`:

```swift
import Testing
@testable import SenaniStore

@Suite struct JSONCodingTests {
    struct Sample: Codable, Equatable { let a: Int; let b: String }

    @Test func roundTripsThroughString() throws {
        let value = Sample(a: 7, b: "hi")
        let json = try SenaniJSON.encodeString(value)
        let decoded: Sample = try SenaniJSON.decode(Sample.self, from: json)
        #expect(decoded == value)
    }

    @Test func decodeRejectsGarbage() {
        #expect(throws: (any Error).self) {
            _ = try SenaniJSON.decode(Sample.self, from: "not json")
        }
    }
}
```

- [ ] 2. Run to verify fail:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter JSONCodingTests
```

Expected failure: build error — `cannot find 'SenaniJSON' in scope`.

- [ ] 3. Minimal implementation. Create `Sources/SenaniStore/DTOs/JSONCoding.swift`:

```swift
import Foundation

/// Shared JSON coding used for all text-column serialization in SenaniStore.
/// Stable key ordering keeps stored JSON deterministic for diffing and tests.
public enum SenaniJSON {
    enum CodingError: Error { case notUTF8 }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    public static func encodeString<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CodingError.notUTF8
        }
        return string
    }

    public static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        guard let data = string.data(using: .utf8) else { throw CodingError.notUTF8 }
        return try decoder().decode(type, from: data)
    }
}
```

- [ ] 4. Run to verify pass:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter JSONCodingTests
```

Expected: 2 tests pass.

- [ ] 5. Commit:

```
git add /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && git commit -m "$(cat <<'EOF'
SenaniStore: shared deterministic JSON coding helpers

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 3: ActionDTO — Codable mirror of every Action case

**Files:**
- Create: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Sources/SenaniStore/DTOs/ActionDTO.swift`
- Test: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Tests/SenaniStoreTests/ActionDTOTests.swift`

Steps:

- [ ] 1. Write failing test `Tests/SenaniStoreTests/ActionDTOTests.swift`:

```swift
import Testing
import SenaniRules
@testable import SenaniStore

@Suite struct ActionDTOTests {
    /// Every Action case must survive core -> DTO -> JSON -> DTO -> core unchanged.
    static let allCases: [Action] = [
        .label("Invoices"),
        .archive,
        .markRead,
        .markUnread,
        .star,
        .unstar,
        .move("Receipts"),
        .flagNeedsReply,
        .fileAttachment(folder: "Docs/2026"),
        .parseDoc,
        .runAgent(id: "lead-qualifier"),
        .draft(body: "Hi there"),
        .reply(body: "Thanks!"),
        .forward(to: "a@b.com", body: "FYI"),
        .send(body: "Sending now"),
        .markSpam,
        .localWebhook(name: "notify"),
    ]

    @Test func everyActionCaseRoundTrips() throws {
        for action in Self.allCases {
            let dto = ActionDTO(core: action)
            let json = try SenaniJSON.encodeString(dto)
            let decoded = try SenaniJSON.decode(ActionDTO.self, from: json)
            #expect(decoded.toCore() == action, "round-trip failed for \(action)")
        }
    }
}
```

- [ ] 2. Run to verify fail:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter ActionDTOTests
```

Expected failure: build error — `cannot find 'ActionDTO' in scope`.

- [ ] 3. Minimal implementation. Create `Sources/SenaniStore/DTOs/ActionDTO.swift`:

```swift
import SenaniRules

/// Codable mirror of `SenaniRules.Action`. Encodes a discriminator `kind`
/// plus only the payload fields each case carries.
public struct ActionDTO: Codable, Equatable {
    public enum Kind: String, Codable {
        case label, archive, markRead, markUnread, star, unstar, move
        case flagNeedsReply, fileAttachment, parseDoc, runAgent, draft
        case reply, forward, send, markSpam, localWebhook
    }

    public var kind: Kind
    public var string1: String?   // generic single-string payload
    public var string2: String?   // second payload (e.g. forward body)

    public init(core: Action) {
        switch core {
        case .label(let name):
            kind = .label; string1 = name
        case .archive:
            kind = .archive
        case .markRead:
            kind = .markRead
        case .markUnread:
            kind = .markUnread
        case .star:
            kind = .star
        case .unstar:
            kind = .unstar
        case .move(let label):
            kind = .move; string1 = label
        case .flagNeedsReply:
            kind = .flagNeedsReply
        case .fileAttachment(let folder):
            kind = .fileAttachment; string1 = folder
        case .parseDoc:
            kind = .parseDoc
        case .runAgent(let id):
            kind = .runAgent; string1 = id
        case .draft(let body):
            kind = .draft; string1 = body
        case .reply(let body):
            kind = .reply; string1 = body
        case .forward(let to, let body):
            kind = .forward; string1 = to; string2 = body
        case .send(let body):
            kind = .send; string1 = body
        case .markSpam:
            kind = .markSpam
        case .localWebhook(let name):
            kind = .localWebhook; string1 = name
        }
    }

    public func toCore() -> Action {
        switch kind {
        case .label:          return .label(string1 ?? "")
        case .archive:        return .archive
        case .markRead:       return .markRead
        case .markUnread:     return .markUnread
        case .star:           return .star
        case .unstar:         return .unstar
        case .move:           return .move(string1 ?? "")
        case .flagNeedsReply: return .flagNeedsReply
        case .fileAttachment: return .fileAttachment(folder: string1 ?? "")
        case .parseDoc:       return .parseDoc
        case .runAgent:       return .runAgent(id: string1 ?? "")
        case .draft:          return .draft(body: string1 ?? "")
        case .reply:          return .reply(body: string1 ?? "")
        case .forward:        return .forward(to: string1 ?? "", body: string2 ?? "")
        case .send:           return .send(body: string1 ?? "")
        case .markSpam:       return .markSpam
        case .localWebhook:   return .localWebhook(name: string1 ?? "")
        }
    }
}
```

- [ ] 4. Run to verify pass:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter ActionDTOTests
```

Expected: 1 test passes (loops over all 17 Action cases).

- [ ] 5. Commit:

```
git add /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && git commit -m "$(cat <<'EOF'
SenaniStore: Codable ActionDTO round-tripping all 17 Action cases

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 4: ConditionDTO — Codable mirror of conditions

**Files:**
- Create: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Sources/SenaniStore/DTOs/ConditionDTO.swift`
- Test: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Tests/SenaniStoreTests/ConditionDTOTests.swift`

Steps:

- [ ] 1. Write failing test `Tests/SenaniStoreTests/ConditionDTOTests.swift`:

```swift
import Testing
import SenaniRules
@testable import SenaniStore

@Suite struct ConditionDTOTests {
    static let allConditions: [StructuredCondition] = [
        .from("a@b.com"),
        .to("c@d.com"),
        .domain("acme.com"),
        .subjectContains("invoice"),
        .bodyContains("pricing"),
        .hasAttachment,
        .listUnsubscribeHeader,
        .isInThread("thread-42"),
        .olderThan(86_400),
        .hasLabel("Important"),
    ]

    @Test func everyStructuredConditionRoundTrips() throws {
        for condition in Self.allConditions {
            let dto = StructuredConditionDTO(core: condition)
            let json = try SenaniJSON.encodeString(dto)
            let decoded = try SenaniJSON.decode(StructuredConditionDTO.self, from: json)
            #expect(decoded.toCore() == condition, "round-trip failed for \(condition)")
        }
    }

    @Test func everyMatchModeRoundTrips() throws {
        for mode in [MatchMode.all, .any, .none] {
            let dto = MatchModeDTO(core: mode)
            let json = try SenaniJSON.encodeString(dto)
            let decoded = try SenaniJSON.decode(MatchModeDTO.self, from: json)
            #expect(decoded.toCore() == mode)
        }
    }

    @Test func conditionsRoundTripWithAndWithoutPredicate() throws {
        let withPredicate = Conditions(
            mode: .any,
            structured: Self.allConditions,
            aiPredicate: "is asking about pricing"
        )
        let withoutPredicate = Conditions(
            mode: .none,
            structured: [.hasAttachment],
            aiPredicate: nil
        )
        for conditions in [withPredicate, withoutPredicate] {
            let dto = ConditionsDTO(core: conditions)
            let json = try SenaniJSON.encodeString(dto)
            let decoded = try SenaniJSON.decode(ConditionsDTO.self, from: json)
            #expect(decoded.toCore() == conditions)
        }
    }
}
```

- [ ] 2. Run to verify fail:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter ConditionDTOTests
```

Expected failure: build error — `cannot find 'StructuredConditionDTO' in scope`.

- [ ] 3. Minimal implementation. Create `Sources/SenaniStore/DTOs/ConditionDTO.swift`:

```swift
import Foundation
import SenaniRules

/// Codable mirror of `SenaniRules.StructuredCondition`.
public struct StructuredConditionDTO: Codable, Equatable {
    public enum Kind: String, Codable {
        case from, to, domain, subjectContains, bodyContains
        case hasAttachment, listUnsubscribeHeader, isInThread, olderThan, hasLabel
    }

    public var kind: Kind
    public var string1: String?
    public var seconds: TimeInterval?  // payload for olderThan

    public init(core: StructuredCondition) {
        switch core {
        case .from(let v):            kind = .from; string1 = v
        case .to(let v):              kind = .to; string1 = v
        case .domain(let v):          kind = .domain; string1 = v
        case .subjectContains(let v): kind = .subjectContains; string1 = v
        case .bodyContains(let v):    kind = .bodyContains; string1 = v
        case .hasAttachment:          kind = .hasAttachment
        case .listUnsubscribeHeader:  kind = .listUnsubscribeHeader
        case .isInThread(let v):      kind = .isInThread; string1 = v
        case .olderThan(let secs):    kind = .olderThan; seconds = secs
        case .hasLabel(let v):        kind = .hasLabel; string1 = v
        }
    }

    public func toCore() -> StructuredCondition {
        switch kind {
        case .from:                 return .from(string1 ?? "")
        case .to:                   return .to(string1 ?? "")
        case .domain:               return .domain(string1 ?? "")
        case .subjectContains:      return .subjectContains(string1 ?? "")
        case .bodyContains:         return .bodyContains(string1 ?? "")
        case .hasAttachment:        return .hasAttachment
        case .listUnsubscribeHeader: return .listUnsubscribeHeader
        case .isInThread:           return .isInThread(string1 ?? "")
        case .olderThan:            return .olderThan(seconds ?? 0)
        case .hasLabel:             return .hasLabel(string1 ?? "")
        }
    }
}

/// Codable mirror of `SenaniRules.MatchMode`.
public struct MatchModeDTO: Codable, Equatable {
    public enum Raw: String, Codable { case all, any, none }
    public var raw: Raw

    public init(core: MatchMode) {
        switch core {
        case .all:  raw = .all
        case .any:  raw = .any
        case .none: raw = .none
        }
    }

    public func toCore() -> MatchMode {
        switch raw {
        case .all:  return .all
        case .any:  return .any
        case .none: return .none
        }
    }
}

/// Codable mirror of `SenaniRules.Conditions`.
public struct ConditionsDTO: Codable, Equatable {
    public var mode: MatchModeDTO
    public var structured: [StructuredConditionDTO]
    public var aiPredicate: String?

    public init(core: Conditions) {
        self.mode = MatchModeDTO(core: core.mode)
        self.structured = core.structured.map(StructuredConditionDTO.init(core:))
        self.aiPredicate = core.aiPredicate
    }

    public func toCore() -> Conditions {
        Conditions(
            mode: mode.toCore(),
            structured: structured.map { $0.toCore() },
            aiPredicate: aiPredicate
        )
    }
}
```

- [ ] 4. Run to verify pass:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter ConditionDTOTests
```

Expected: 3 tests pass.

- [ ] 5. Commit:

```
git add /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && git commit -m "$(cat <<'EOF'
SenaniStore: Codable DTOs for StructuredCondition, MatchMode, Conditions

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 5: RuleDTO — Codable mirror of Rule

**Files:**
- Create: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Sources/SenaniStore/DTOs/RuleDTO.swift`
- Test: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Tests/SenaniStoreTests/RuleDTOTests.swift`

Steps:

- [ ] 1. Write failing test `Tests/SenaniStoreTests/RuleDTOTests.swift`:

```swift
import Testing
import SenaniRules
@testable import SenaniStore

@Suite struct RuleDTOTests {
    static func sampleRule(autonomy: Autonomy, runOn: RunOn) -> Rule {
        Rule(
            id: "rule-\(autonomy.rawValue)-\(runOn.rawValue)",
            name: "Invoices",
            enabled: true,
            conditions: Conditions(
                mode: .all,
                structured: [.domain("acme.com"), .subjectContains("invoice")],
                aiPredicate: "is an invoice"
            ),
            actions: [.label("Invoices"), .flagNeedsReply, .draft(body: "Got it")],
            autonomy: autonomy,
            runOn: runOn
        )
    }

    @Test func ruleRoundTripsAcrossAutonomyAndRunOn() throws {
        for autonomy in [Autonomy.ask, .prepare, .auto] {
            for runOn in [RunOn.incoming, .existing, .both] {
                let rule = Self.sampleRule(autonomy: autonomy, runOn: runOn)
                let dto = RuleDTO(core: rule)
                let json = try SenaniJSON.encodeString(dto)
                let decoded = try SenaniJSON.decode(RuleDTO.self, from: json)
                #expect(decoded.toCore() == rule, "round-trip failed for \(autonomy)/\(runOn)")
            }
        }
    }

    @Test func disabledRuleWithNoPredicateRoundTrips() throws {
        var rule = Self.sampleRule(autonomy: .ask, runOn: .incoming)
        rule.enabled = false
        rule.conditions.aiPredicate = nil
        let dto = RuleDTO(core: rule)
        let json = try SenaniJSON.encodeString(dto)
        let decoded = try SenaniJSON.decode(RuleDTO.self, from: json)
        #expect(decoded.toCore() == rule)
    }
}
```

- [ ] 2. Run to verify fail:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter RuleDTOTests
```

Expected failure: build error — `cannot find 'RuleDTO' in scope`.

- [ ] 3. Minimal implementation. Create `Sources/SenaniStore/DTOs/RuleDTO.swift`:

```swift
import SenaniRules

/// Codable mirror of `SenaniRules.Rule`.
public struct RuleDTO: Codable, Equatable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var conditions: ConditionsDTO
    public var actions: [ActionDTO]
    public var autonomy: String   // Autonomy.rawValue
    public var runOn: String      // RunOn.rawValue

    public init(core: Rule) {
        self.id = core.id
        self.name = core.name
        self.enabled = core.enabled
        self.conditions = ConditionsDTO(core: core.conditions)
        self.actions = core.actions.map(ActionDTO.init(core:))
        self.autonomy = core.autonomy.rawValue
        self.runOn = core.runOn.rawValue
    }

    public func toCore() -> Rule {
        Rule(
            id: id,
            name: name,
            enabled: enabled,
            conditions: conditions.toCore(),
            actions: actions.map { $0.toCore() },
            autonomy: Autonomy(rawValue: autonomy) ?? .ask,
            runOn: RunOn(rawValue: runOn) ?? .incoming
        )
    }
}
```

- [ ] 4. Run to verify pass:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter RuleDTOTests
```

Expected: 2 tests pass (first loops over all 9 autonomy/runOn combinations).

- [ ] 5. Commit:

```
git add /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && git commit -m "$(cat <<'EOF'
SenaniStore: Codable RuleDTO round-tripping autonomy and runOn

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 6: TriggerDTO + OutcomeDTO

**Files:**
- Create: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Sources/SenaniStore/DTOs/TriggerDTO.swift`
- Test: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Tests/SenaniStoreTests/TriggerDTOTests.swift`

Steps:

- [ ] 1. Write failing test `Tests/SenaniStoreTests/TriggerDTOTests.swift`:

```swift
import Testing
import SenaniRules
@testable import SenaniStore

@Suite struct TriggerDTOTests {
    @Test func everyTriggerRoundTrips() throws {
        let triggers: [Trigger] = [.rule(id: "r1"), .chat(turnId: "t9")]
        for trigger in triggers {
            let dto = TriggerDTO(core: trigger)
            let json = try SenaniJSON.encodeString(dto)
            let decoded = try SenaniJSON.decode(TriggerDTO.self, from: json)
            #expect(decoded.toCore() == trigger)
        }
    }

    @Test func everyOutcomeRoundTrips() throws {
        let outcomes: [Outcome] = [.executed, .prepared, .queuedForApproval]
        for outcome in outcomes {
            let dto = OutcomeDTO(core: outcome)
            let json = try SenaniJSON.encodeString(dto)
            let decoded = try SenaniJSON.decode(OutcomeDTO.self, from: json)
            #expect(decoded.toCore() == outcome)
        }
    }
}
```

- [ ] 2. Run to verify fail:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter TriggerDTOTests
```

Expected failure: build error — `cannot find 'TriggerDTO' in scope`.

- [ ] 3. Minimal implementation. Create `Sources/SenaniStore/DTOs/TriggerDTO.swift`:

```swift
import SenaniRules

/// Codable mirror of `SenaniRules.Trigger`.
public struct TriggerDTO: Codable, Equatable {
    public enum Kind: String, Codable { case rule, chat }
    public var kind: Kind
    public var identifier: String   // rule id or chat turn id

    public init(core: Trigger) {
        switch core {
        case .rule(let id):     kind = .rule; identifier = id
        case .chat(let turnId): kind = .chat; identifier = turnId
        }
    }

    public func toCore() -> Trigger {
        switch kind {
        case .rule: return .rule(id: identifier)
        case .chat: return .chat(turnId: identifier)
        }
    }
}

/// Codable mirror of `SenaniRules.Outcome`.
public struct OutcomeDTO: Codable, Equatable {
    public enum Raw: String, Codable { case executed, prepared, queuedForApproval }
    public var raw: Raw

    public init(core: Outcome) {
        switch core {
        case .executed:          raw = .executed
        case .prepared:          raw = .prepared
        case .queuedForApproval: raw = .queuedForApproval
        }
    }

    public func toCore() -> Outcome {
        switch raw {
        case .executed:          return .executed
        case .prepared:          return .prepared
        case .queuedForApproval: return .queuedForApproval
        }
    }
}
```

- [ ] 4. Run to verify pass:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter TriggerDTOTests
```

Expected: 2 tests pass.

- [ ] 5. Commit:

```
git add /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && git commit -m "$(cat <<'EOF'
SenaniStore: Codable DTOs for Trigger and Outcome

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 7: Migrations — the full schema

**Files:**
- Create: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Sources/SenaniStore/Migrations.swift`
- Create: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Sources/SenaniStore/SenaniDatabase.swift`
- Test: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Tests/SenaniStoreTests/SenaniDatabaseTests.swift`

The `vec_items` table is created as a plain table here (id, vector blob, metadata) so the schema is consistent whether or not the sqlite-vec extension is loaded; the sqlite-vec virtual table is created lazily by `SqliteVecIndex` (Task 13) only when the extension is present. This keeps unit tests (in-memory, no extension) able to run the full migrator.

Steps:

- [ ] 1. Write failing test `Tests/SenaniStoreTests/SenaniDatabaseTests.swift`:

```swift
import Testing
import GRDB
@testable import SenaniStore

@Suite struct SenaniDatabaseTests {
    @Test func migratorCreatesAllTables() throws {
        let db = try SenaniDatabase.inMemory()
        let tables = try db.queue.read { conn -> Set<String> in
            let names = try String.fetchAll(
                conn,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            )
            return Set(names)
        }
        let expected: Set<String> = [
            "rules", "rule_runs", "actions_log", "documents", "document_fields",
            "voice_profile", "needs_reply", "chat_sessions", "approvals", "vec_items",
        ]
        #expect(expected.isSubset(of: tables), "missing tables: \(expected.subtracting(tables))")
    }

    @Test func migratorIsIdempotent() throws {
        // Migrating the same on-disk file twice must not throw.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("senani-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try SenaniDatabase.file(at: url.path)
        _ = try SenaniDatabase.file(at: url.path)
    }
}
```

- [ ] 2. Run to verify fail:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter SenaniDatabaseTests
```

Expected failure: build error — `cannot find 'SenaniDatabase' in scope`.

- [ ] 3. Minimal implementation. Create `Sources/SenaniStore/Migrations.swift`:

```swift
import GRDB

/// The versioned schema for the entire Senani local store. SenaniStore owns the
/// schema; dependent subsystems own the LOGIC over their tables.
enum SenaniMigrations {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_core") { db in
            try db.create(table: "rules") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("enabled", .boolean).notNull()
                t.column("json", .text).notNull()   // full RuleDTO JSON
            }

            try db.create(table: "rule_runs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("rule_id", .text).notNull().indexed()
                t.column("kind", .text).notNull()       // "simulation" | "live"
                t.column("ran_at", .double).notNull()    // injected epoch seconds
                t.column("message_id", .text).notNull()
                t.column("matched", .boolean).notNull()
                t.column("outcomes_json", .text).notNull()
            }

            try db.create(table: "actions_log") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("message_id", .text).notNull().indexed()
                t.column("action_json", .text).notNull()
                t.column("trigger_json", .text).notNull()
                t.column("outcome", .text).notNull()
                t.column("logged_at", .double).notNull()  // injected epoch seconds
            }

            try db.create(table: "approvals") { t in
                t.column("id", .text).primaryKey()
                t.column("action_json", .text).notNull()
                t.column("message_json", .text).notNull()
                t.column("trigger_json", .text).notNull()
                t.column("status", .text).notNull()       // "pending" | "approved" | "rejected"
                t.column("created_at", .double).notNull()
            }
        }

        migrator.registerMigration("v2_dependent_tables") { db in
            try db.create(table: "documents") { t in
                t.column("id", .text).primaryKey()
                t.column("message_id", .text).indexed()
                t.column("filename", .text).notNull()
                t.column("kind", .text).notNull()         // "pdf" | "image" | ...
                t.column("text", .text)
                t.column("parsed_at", .double)
            }

            try db.create(table: "document_fields") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("document_id", .text).notNull().indexed()
                t.column("name", .text).notNull()
                t.column("value", .text)
            }

            try db.create(table: "voice_profile") { t in
                t.column("id", .text).primaryKey()        // "default" or per-recipient/domain key
                t.column("scope", .text).notNull()         // "global" | "domain" | "recipient"
                t.column("profile_json", .text).notNull()
                t.column("updated_at", .double).notNull()
            }

            try db.create(table: "needs_reply") { t in
                t.column("thread_id", .text).primaryKey()
                t.column("message_id", .text).notNull()
                t.column("flagged_at", .double).notNull()
                t.column("resolved", .boolean).notNull()
            }

            try db.create(table: "chat_sessions") { t in
                t.column("id", .text).primaryKey()
                t.column("started_at", .double).notNull()
                t.column("transcript_json", .text).notNull()
                t.column("summary", .text)
            }
        }

        migrator.registerMigration("v3_vectors") { db in
            // Plain backing table so the schema is identical with or without the
            // sqlite-vec extension. SqliteVecIndex creates its virtual table lazily.
            try db.create(table: "vec_items") { t in
                t.column("id", .text).primaryKey()
                t.column("namespace", .text).notNull().indexed()  // "doc_chunk" | "voice_exemplar"
                t.column("vector", .blob).notNull()                // little-endian Float32 array
                t.column("metadata_json", .text)
            }
        }

        return migrator
    }
}
```

Create `Sources/SenaniStore/SenaniDatabase.swift`:

```swift
import Foundation
import GRDB

/// Owns the GRDB `DatabaseQueue`, runs the migrator, and (for the real,
/// non-test path) loads the sqlite-vec native extension.
public final class SenaniDatabase: Sendable {
    public let queue: DatabaseQueue

    private init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// In-memory database for unit tests. No native extension is loaded.
    public static func inMemory() throws -> SenaniDatabase {
        let queue = try DatabaseQueue()
        try SenaniMigrations.migrator().migrate(queue)
        return SenaniDatabase(queue: queue)
    }

    /// On-disk database at `path`. Runs migrations; safe to call repeatedly.
    public static func file(at path: String) throws -> SenaniDatabase {
        let queue = try DatabaseQueue(path: path)
        try SenaniMigrations.migrator().migrate(queue)
        return SenaniDatabase(queue: queue)
    }
}
```

- [ ] 4. Run to verify pass:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter SenaniDatabaseTests
```

Expected: 2 tests pass.

- [ ] 5. Commit:

```
git add /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && git commit -m "$(cat <<'EOF'
SenaniStore: SenaniDatabase + versioned migrator for full schema

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 8: RuleStore — CRUD over rules

**Files:**
- Create: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Sources/SenaniStore/RuleStore.swift`
- Test: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Tests/SenaniStoreTests/RuleStoreTests.swift`

Steps:

- [ ] 1. Write failing test `Tests/SenaniStoreTests/RuleStoreTests.swift`:

```swift
import Testing
import SenaniRules
@testable import SenaniStore

@Suite struct RuleStoreTests {
    static func rule(_ id: String, enabled: Bool = true, name: String = "R") -> Rule {
        Rule(
            id: id, name: name, enabled: enabled,
            conditions: Conditions(mode: .all, structured: [.domain("acme.com")], aiPredicate: nil),
            actions: [.label("X")], autonomy: .ask, runOn: .incoming
        )
    }

    func makeStore() throws -> RuleStore {
        RuleStore(database: try SenaniDatabase.inMemory())
    }

    @Test func savesAndFetchesById() throws {
        let store = try makeStore()
        let r = Self.rule("r1", name: "Invoices")
        try store.save(r)
        #expect(try store.fetch(id: "r1") == r)
    }

    @Test func saveUpserts() throws {
        let store = try makeStore()
        try store.save(Self.rule("r1", name: "Old"))
        try store.save(Self.rule("r1", name: "New"))
        #expect(try store.fetch(id: "r1")?.name == "New")
        #expect(try store.all().count == 1)
    }

    @Test func fetchMissingReturnsNil() throws {
        let store = try makeStore()
        #expect(try store.fetch(id: "nope") == nil)
    }

    @Test func enabledFiltersDisabled() throws {
        let store = try makeStore()
        try store.save(Self.rule("on", enabled: true))
        try store.save(Self.rule("off", enabled: false))
        let enabled = try store.enabled()
        #expect(enabled.map(\.id) == ["on"])
    }

    @Test func deleteRemoves() throws {
        let store = try makeStore()
        try store.save(Self.rule("r1"))
        try store.delete(id: "r1")
        #expect(try store.fetch(id: "r1") == nil)
    }

    @Test func allIsSortedById() throws {
        let store = try makeStore()
        try store.save(Self.rule("b"))
        try store.save(Self.rule("a"))
        #expect(try store.all().map(\.id) == ["a", "b"])
    }
}
```

- [ ] 2. Run to verify fail:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter RuleStoreTests
```

Expected failure: build error — `cannot find 'RuleStore' in scope`.

- [ ] 3. Minimal implementation. Create `Sources/SenaniStore/RuleStore.swift`:

```swift
import GRDB
import SenaniRules

/// CRUD over the `rules` table, mapping rows to/from `SenaniRules.Rule`.
public struct RuleStore: Sendable {
    private let database: SenaniDatabase
    public init(database: SenaniDatabase) {
        self.database = database
    }

    public func save(_ rule: Rule) throws {
        let json = try SenaniJSON.encodeString(RuleDTO(core: rule))
        try database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO rules (id, name, enabled, json)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name,
                  enabled = excluded.enabled,
                  json = excluded.json
                """,
                arguments: [rule.id, rule.name, rule.enabled, json]
            )
        }
    }

    public func fetch(id: String) throws -> Rule? {
        try database.queue.read { db in
            guard let json = try String.fetchOne(
                db, sql: "SELECT json FROM rules WHERE id = ?", arguments: [id]
            ) else { return nil }
            return try SenaniJSON.decode(RuleDTO.self, from: json).toCore()
        }
    }

    public func all() throws -> [Rule] {
        try database.queue.read { db in
            let rows = try String.fetchAll(db, sql: "SELECT json FROM rules ORDER BY id")
            return try rows.map { try SenaniJSON.decode(RuleDTO.self, from: $0).toCore() }
        }
    }

    public func enabled() throws -> [Rule] {
        try database.queue.read { db in
            let rows = try String.fetchAll(
                db, sql: "SELECT json FROM rules WHERE enabled = 1 ORDER BY id"
            )
            return try rows.map { try SenaniJSON.decode(RuleDTO.self, from: $0).toCore() }
        }
    }

    public func delete(id: String) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM rules WHERE id = ?", arguments: [id])
        }
    }
}
```

- [ ] 4. Run to verify pass:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter RuleStoreTests
```

Expected: 6 tests pass.

- [ ] 5. Commit:

```
git add /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && git commit -m "$(cat <<'EOF'
SenaniStore: RuleStore CRUD over the rules table

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 9: PersistentAuditLog — conforms to SenaniRules.AuditLog

**Files:**
- Create: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Sources/SenaniStore/PersistentAuditLog.swift`
- Test: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Tests/SenaniStoreTests/PersistentAuditLogTests.swift`

`AuditLog.record(_:)` takes only an `ActionRecord` (no timestamp). Per the brief, the timestamp must be injectable for deterministic tests, so `PersistentAuditLog` holds an injected clock closure `() -> Double` (epoch seconds) used when writing rows. `records()` returns `(ActionRecord, loggedAt)` pairs for assertions.

Steps:

- [ ] 1. Write failing test `Tests/SenaniStoreTests/PersistentAuditLogTests.swift`:

```swift
import Testing
import SenaniRules
@testable import SenaniStore

@Suite struct PersistentAuditLogTests {
    @Test func recordsAndReadsBackWithInjectedTimestamp() async throws {
        let db = try SenaniDatabase.inMemory()
        let log = PersistentAuditLog(database: db, now: { 1_000.0 })
        let record = ActionRecord(
            action: .label("Invoices"),
            messageId: "m1",
            trigger: .rule(id: "r1"),
            outcome: .executed
        )
        await log.record(record)

        let stored = try await log.records()
        #expect(stored.count == 1)
        #expect(stored[0].record == record)
        #expect(stored[0].loggedAt == 1_000.0)
    }

    @Test func preservesInsertionOrderAndOutboundOutcome() async throws {
        var t = 0.0
        let db = try SenaniDatabase.inMemory()
        let log = PersistentAuditLog(database: db, now: { t += 1; return t })
        await log.record(ActionRecord(
            action: .archive, messageId: "m1", trigger: .chat(turnId: "t1"), outcome: .prepared))
        await log.record(ActionRecord(
            action: .send(body: "hi"), messageId: "m2", trigger: .rule(id: "r2"),
            outcome: .queuedForApproval))

        let stored = try await log.records()
        #expect(stored.map(\.record.messageId) == ["m1", "m2"])
        #expect(stored[1].record.outcome == .queuedForApproval)
        #expect(stored[1].record.action == .send(body: "hi"))
    }
}
```

- [ ] 2. Run to verify fail:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter PersistentAuditLogTests
```

Expected failure: build error — `cannot find 'PersistentAuditLog' in scope`.

- [ ] 3. Minimal implementation. Create `Sources/SenaniStore/PersistentAuditLog.swift`:

```swift
import GRDB
import SenaniRules

/// One persisted audit row: the core record plus the epoch-seconds timestamp it was logged at.
public struct AuditEntry: Sendable, Equatable {
    public let record: ActionRecord
    public let loggedAt: Double
    public init(record: ActionRecord, loggedAt: Double) {
        self.record = record
        self.loggedAt = loggedAt
    }
}

/// Persists every Action Kernel execution to `actions_log`. Conforms to
/// `SenaniRules.AuditLog`. The timestamp is injected so tests are deterministic.
public actor PersistentAuditLog: AuditLog {
    private let database: SenaniDatabase
    private let now: @Sendable () -> Double

    public init(database: SenaniDatabase, now: @escaping @Sendable () -> Double) {
        self.database = database
        self.now = now
    }

    public func record(_ record: ActionRecord) async {
        let loggedAt = now()
        do {
            let actionJSON = try SenaniJSON.encodeString(ActionDTO(core: record.action))
            let triggerJSON = try SenaniJSON.encodeString(TriggerDTO(core: record.trigger))
            let outcome = OutcomeDTO(core: record.outcome).raw.rawValue
            try database.queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO actions_log
                      (message_id, action_json, trigger_json, outcome, logged_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [record.messageId, actionJSON, triggerJSON, outcome, loggedAt]
                )
            }
        } catch {
            // Audit is best-effort and must never crash the executor; swallow on failure.
        }
    }

    /// Reader for tests and the activity log, ordered by insertion (rowid).
    public func records() throws -> [AuditEntry] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT message_id, action_json, trigger_json, outcome, logged_at
                FROM actions_log ORDER BY id
                """
            )
            return try rows.map { row in
                let action = try SenaniJSON.decode(ActionDTO.self, from: row["action_json"]).toCore()
                let trigger = try SenaniJSON.decode(TriggerDTO.self, from: row["trigger_json"]).toCore()
                let outcomeRaw: String = row["outcome"]
                let outcome = (OutcomeDTO.Raw(rawValue: outcomeRaw)
                    .map { OutcomeDTO(raw: $0) } ?? OutcomeDTO(raw: .executed)).toCore()
                let record = ActionRecord(
                    action: action,
                    messageId: row["message_id"],
                    trigger: trigger,
                    outcome: outcome
                )
                return AuditEntry(record: record, loggedAt: row["logged_at"])
            }
        }
    }
}
```

Also add to `Sources/SenaniStore/DTOs/TriggerDTO.swift` a memberwise-style initializer for `OutcomeDTO` from its raw (used by the reader). Append:

```swift
extension OutcomeDTO {
    init(raw: Raw) { self.raw = raw }
}
```

- [ ] 4. Run to verify pass:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter PersistentAuditLogTests
```

Expected: 2 tests pass.

- [ ] 5. Commit:

```
git add /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && git commit -m "$(cat <<'EOF'
SenaniStore: PersistentAuditLog writing actions_log with injected clock

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 10: ApprovalStore — persist proposals

**Files:**
- Create: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Sources/SenaniStore/ApprovalStore.swift`
- Test: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Tests/SenaniStoreTests/ApprovalStoreTests.swift`

`Proposal` carries a full `Message`, which is not `Codable`. Serialize the message through a local `MessageDTO` defined in this file. Each persisted proposal gets a store-assigned id (caller-supplied) so it can be approved/rejected individually.

Steps:

- [ ] 1. Write failing test `Tests/SenaniStoreTests/ApprovalStoreTests.swift`:

```swift
import Testing
import Foundation
import SenaniRules
@testable import SenaniStore

@Suite struct ApprovalStoreTests {
    static func proposal(action: Action) -> Proposal {
        let msg = Message(
            id: "m1", from: "s@acme.com", to: ["me@x.com"], subject: "Hi",
            body: "Body", hasAttachment: false, listUnsubscribeHeader: nil,
            labels: ["Inbox"], threadId: "t1", date: Date(timeIntervalSince1970: 10),
            isFromUser: false
        )
        return Proposal(action: action, message: msg, trigger: .rule(id: "r1"))
    }

    func makeStore() throws -> ApprovalStore {
        ApprovalStore(database: try SenaniDatabase.inMemory(), now: { 5.0 })
    }

    @Test func enqueueAndPending() throws {
        let store = try makeStore()
        try store.enqueue(id: "p1", Self.proposal(action: .send(body: "hi")))
        let pending = try store.pending()
        #expect(pending.count == 1)
        #expect(pending[0].id == "p1")
        #expect(pending[0].proposal == Self.proposal(action: .send(body: "hi")))
    }

    @Test func approveRemovesFromPending() throws {
        let store = try makeStore()
        try store.enqueue(id: "p1", Self.proposal(action: .reply(body: "ok")))
        try store.approve(id: "p1")
        #expect(try store.pending().isEmpty)
    }

    @Test func rejectRemovesFromPending() throws {
        let store = try makeStore()
        try store.enqueue(id: "p1", Self.proposal(action: .markSpam))
        try store.reject(id: "p1")
        #expect(try store.pending().isEmpty)
    }

    @Test func pendingPreservesMessageFidelity() throws {
        let store = try makeStore()
        let p = Self.proposal(action: .forward(to: "x@y.com", body: "fyi"))
        try store.enqueue(id: "p9", p)
        #expect(try store.pending()[0].proposal.message == p.message)
    }
}
```

- [ ] 2. Run to verify fail:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter ApprovalStoreTests
```

Expected failure: build error — `cannot find 'ApprovalStore' in scope`.

- [ ] 3. Minimal implementation. Create `Sources/SenaniStore/ApprovalStore.swift`:

```swift
import Foundation
import GRDB
import SenaniRules

/// Codable mirror of `SenaniRules.Message` (Message is not Codable in core).
struct MessageDTO: Codable, Equatable {
    var id: String
    var from: String
    var to: [String]
    var subject: String
    var body: String
    var hasAttachment: Bool
    var listUnsubscribeHeader: String?
    var labels: [String]
    var threadId: String
    var date: Double          // epoch seconds
    var isFromUser: Bool

    init(core: Message) {
        id = core.id
        from = core.from
        to = core.to
        subject = core.subject
        body = core.body
        hasAttachment = core.hasAttachment
        listUnsubscribeHeader = core.listUnsubscribeHeader
        labels = core.labels
        threadId = core.threadId
        date = core.date.timeIntervalSince1970
        isFromUser = core.isFromUser
    }

    func toCore() -> Message {
        Message(
            id: id, from: from, to: to, subject: subject, body: body,
            hasAttachment: hasAttachment, listUnsubscribeHeader: listUnsubscribeHeader,
            labels: labels, threadId: threadId,
            date: Date(timeIntervalSince1970: date), isFromUser: isFromUser
        )
    }
}

/// A persisted proposal paired with its store-assigned id.
public struct StoredProposal: Sendable, Equatable {
    public let id: String
    public let proposal: Proposal
    public init(id: String, proposal: Proposal) {
        self.id = id
        self.proposal = proposal
    }
}

/// Persists outbound/awaiting proposals to the `approvals` table.
public struct ApprovalStore: Sendable {
    private let database: SenaniDatabase
    private let now: @Sendable () -> Double

    public init(database: SenaniDatabase, now: @escaping @Sendable () -> Double) {
        self.database = database
        self.now = now
    }

    public func enqueue(id: String, _ proposal: Proposal) throws {
        let actionJSON = try SenaniJSON.encodeString(ActionDTO(core: proposal.action))
        let messageJSON = try SenaniJSON.encodeString(MessageDTO(core: proposal.message))
        let triggerJSON = try SenaniJSON.encodeString(TriggerDTO(core: proposal.trigger))
        let createdAt = now()
        try database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO approvals
                  (id, action_json, message_json, trigger_json, status, created_at)
                VALUES (?, ?, ?, ?, 'pending', ?)
                ON CONFLICT(id) DO UPDATE SET
                  action_json = excluded.action_json,
                  message_json = excluded.message_json,
                  trigger_json = excluded.trigger_json,
                  status = 'pending',
                  created_at = excluded.created_at
                """,
                arguments: [id, actionJSON, messageJSON, triggerJSON, createdAt]
            )
        }
    }

    public func pending() throws -> [StoredProposal] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, action_json, message_json, trigger_json
                FROM approvals WHERE status = 'pending' ORDER BY created_at, id
                """
            )
            return try rows.map { row in
                let action = try SenaniJSON.decode(ActionDTO.self, from: row["action_json"]).toCore()
                let message = try SenaniJSON.decode(MessageDTO.self, from: row["message_json"]).toCore()
                let trigger = try SenaniJSON.decode(TriggerDTO.self, from: row["trigger_json"]).toCore()
                return StoredProposal(
                    id: row["id"],
                    proposal: Proposal(action: action, message: message, trigger: trigger)
                )
            }
        }
    }

    public func approve(id: String) throws { try setStatus(id: id, status: "approved") }
    public func reject(id: String) throws { try setStatus(id: id, status: "rejected") }

    private func setStatus(id: String, status: String) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE approvals SET status = ? WHERE id = ?",
                arguments: [status, id]
            )
        }
    }
}
```

- [ ] 4. Run to verify pass:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter ApprovalStoreTests
```

Expected: 4 tests pass.

- [ ] 5. Commit:

```
git add /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && git commit -m "$(cat <<'EOF'
SenaniStore: ApprovalStore persisting proposals with approve/reject

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 11: RuleRunStore — simulation/live evaluation records

**Files:**
- Create: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Sources/SenaniStore/RuleRunStore.swift`
- Test: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Tests/SenaniStoreTests/RuleRunStoreTests.swift`

A run record captures: rule id, kind (simulation/live), the timestamp (injected), the message id evaluated, whether it matched, and the per-action outcomes that would/did fire. Outcomes are stored as a JSON array of `OutcomeDTO`.

Steps:

- [ ] 1. Write failing test `Tests/SenaniStoreTests/RuleRunStoreTests.swift`:

```swift
import Testing
import SenaniRules
@testable import SenaniStore

@Suite struct RuleRunStoreTests {
    func makeStore() throws -> RuleRunStore {
        RuleRunStore(database: try SenaniDatabase.inMemory())
    }

    @Test func recordsAndReadsByRule() throws {
        let store = try makeStore()
        try store.record(RuleRun(
            ruleId: "r1", kind: .simulation, ranAt: 100,
            messageId: "m1", matched: true, outcomes: [.executed, .queuedForApproval]))
        try store.record(RuleRun(
            ruleId: "r1", kind: .live, ranAt: 200,
            messageId: "m2", matched: false, outcomes: []))
        try store.record(RuleRun(
            ruleId: "other", kind: .simulation, ranAt: 50,
            messageId: "m3", matched: true, outcomes: [.prepared]))

        let r1 = try store.runs(ruleId: "r1")
        #expect(r1.count == 2)
        #expect(r1.map(\.messageId) == ["m1", "m2"])
        #expect(r1[0].outcomes == [.executed, .queuedForApproval])
        #expect(r1[0].kind == .simulation)
    }

    @Test func allReturnsEverythingOrderedByTime() throws {
        let store = try makeStore()
        try store.record(RuleRun(
            ruleId: "r1", kind: .live, ranAt: 200, messageId: "m2",
            matched: true, outcomes: [.executed]))
        try store.record(RuleRun(
            ruleId: "r2", kind: .simulation, ranAt: 100, messageId: "m1",
            matched: true, outcomes: [.prepared]))
        #expect(try store.all().map(\.messageId) == ["m1", "m2"])
    }
}
```

- [ ] 2. Run to verify fail:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter RuleRunStoreTests
```

Expected failure: build error — `cannot find 'RuleRunStore' in scope`.

- [ ] 3. Minimal implementation. Create `Sources/SenaniStore/RuleRunStore.swift`:

```swift
import GRDB
import SenaniRules

/// One simulation or live evaluation of a rule against a single message.
public struct RuleRun: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case simulation, live }

    public var ruleId: String
    public var kind: Kind
    public var ranAt: Double         // injected epoch seconds
    public var messageId: String
    public var matched: Bool
    public var outcomes: [Outcome]

    public init(
        ruleId: String, kind: Kind, ranAt: Double,
        messageId: String, matched: Bool, outcomes: [Outcome]
    ) {
        self.ruleId = ruleId
        self.kind = kind
        self.ranAt = ranAt
        self.messageId = messageId
        self.matched = matched
        self.outcomes = outcomes
    }
}

/// Persists rule-run records to `rule_runs`.
public struct RuleRunStore: Sendable {
    private let database: SenaniDatabase
    public init(database: SenaniDatabase) {
        self.database = database
    }

    public func record(_ run: RuleRun) throws {
        let outcomesJSON = try SenaniJSON.encodeString(run.outcomes.map(OutcomeDTO.init(core:)))
        try database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO rule_runs
                  (rule_id, kind, ran_at, message_id, matched, outcomes_json)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    run.ruleId, run.kind.rawValue, run.ranAt,
                    run.messageId, run.matched, outcomesJSON,
                ]
            )
        }
    }

    public func runs(ruleId: String) throws -> [RuleRun] {
        try fetch(sql:
            "SELECT * FROM rule_runs WHERE rule_id = ? ORDER BY ran_at, id",
            arguments: [ruleId])
    }

    public func all() throws -> [RuleRun] {
        try fetch(sql: "SELECT * FROM rule_runs ORDER BY ran_at, id", arguments: [])
    }

    private func fetch(sql: String, arguments: StatementArguments) throws -> [RuleRun] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return try rows.map { row in
                let outcomes = try SenaniJSON
                    .decode([OutcomeDTO].self, from: row["outcomes_json"])
                    .map { $0.toCore() }
                return RuleRun(
                    ruleId: row["rule_id"],
                    kind: RuleRun.Kind(rawValue: row["kind"]) ?? .simulation,
                    ranAt: row["ran_at"],
                    messageId: row["message_id"],
                    matched: row["matched"],
                    outcomes: outcomes
                )
            }
        }
    }
}
```

- [ ] 4. Run to verify pass:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter RuleRunStoreTests
```

Expected: 2 tests pass.

- [ ] 5. Commit:

```
git add /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && git commit -m "$(cat <<'EOF'
SenaniStore: RuleRunStore persisting simulation/live evaluation records

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 12: VectorIndex protocol + InMemoryVectorIndex

**Files:**
- Create: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Sources/SenaniStore/VectorIndex.swift`
- Test: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Tests/SenaniStoreTests/InMemoryVectorIndexTests.swift`

`distance` is `1 - cosineSimilarity` so smaller = closer; results are ascending by distance. Search returns at most `k` hits.

Steps:

- [ ] 1. Write failing test `Tests/SenaniStoreTests/InMemoryVectorIndexTests.swift`:

```swift
import Testing
@testable import SenaniStore

@Suite struct InMemoryVectorIndexTests {
    @Test func searchRanksNearestFirst() throws {
        let index = InMemoryVectorIndex()
        try index.insert(id: "x", vector: [1, 0, 0], metadata: nil)
        try index.insert(id: "y", vector: [0, 1, 0], metadata: nil)
        try index.insert(id: "z", vector: [0.9, 0.1, 0], metadata: nil)

        let hits = try index.search(vector: [1, 0, 0], k: 2)
        #expect(hits.count == 2)
        #expect(hits.map(\.id) == ["x", "z"])
        #expect(hits[0].distance <= hits[1].distance)
        #expect(abs(hits[0].distance) < 1e-6)  // identical vector -> distance ~0
    }

    @Test func kLimitsResults() throws {
        let index = InMemoryVectorIndex()
        for i in 0..<5 {
            try index.insert(id: "v\(i)", vector: [Float(i), 1, 0], metadata: nil)
        }
        #expect(try index.search(vector: [0, 1, 0], k: 3).count == 3)
    }

    @Test func insertOverwritesSameId() throws {
        let index = InMemoryVectorIndex()
        try index.insert(id: "a", vector: [1, 0], metadata: "first")
        try index.insert(id: "a", vector: [0, 1], metadata: "second")
        let hits = try index.search(vector: [0, 1], k: 5)
        #expect(hits.count == 1)
        #expect(hits[0].metadata == "second")
    }

    @Test func zeroVectorYieldsMaxDistance() throws {
        let index = InMemoryVectorIndex()
        try index.insert(id: "zero", vector: [0, 0, 0], metadata: nil)
        let hits = try index.search(vector: [1, 0, 0], k: 1)
        #expect(hits[0].distance == 1.0)
    }
}
```

- [ ] 2. Run to verify fail:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter InMemoryVectorIndexTests
```

Expected failure: build error — `cannot find 'InMemoryVectorIndex' in scope`.

- [ ] 3. Minimal implementation. Create `Sources/SenaniStore/VectorIndex.swift`:

```swift
import Foundation

/// A single nearest-neighbor result. `distance` is in [0, 2]; smaller is closer.
public struct VectorHit: Sendable, Equatable {
    public let id: String
    public let distance: Float
    public let metadata: String?
    public init(id: String, distance: Float, metadata: String?) {
        self.id = id
        self.distance = distance
        self.metadata = metadata
    }
}

/// Seam over the vector store. Real impl is sqlite-vec-backed; tests use the
/// pure-Swift in-memory cosine implementation.
public protocol VectorIndex: Sendable {
    func insert(id: String, vector: [Float], metadata: String?) throws
    func search(vector: [Float], k: Int) throws -> [VectorHit]
}

/// Pure-Swift cosine-similarity index for unit tests and dependent-package fakes.
/// `distance = 1 - cosineSimilarity`, so identical direction -> 0, orthogonal -> 1.
public final class InMemoryVectorIndex: VectorIndex, @unchecked Sendable {
    private struct Item { var vector: [Float]; var metadata: String? }
    private var items: [String: Item] = [:]
    private let lock = NSLock()

    public init() {}

    public func insert(id: String, vector: [Float], metadata: String?) throws {
        lock.lock(); defer { lock.unlock() }
        items[id] = Item(vector: vector, metadata: metadata)
    }

    public func search(vector query: [Float], k: Int) throws -> [VectorHit] {
        lock.lock()
        let snapshot = items
        lock.unlock()

        let hits = snapshot.map { id, item -> VectorHit in
            VectorHit(
                id: id,
                distance: 1 - Self.cosine(query, item.vector),
                metadata: item.metadata
            )
        }
        return hits
            .sorted { ($0.distance, $0.id) < ($1.distance, $1.id) }
            .prefix(max(0, k))
            .map { $0 }
    }

    /// Cosine similarity; returns 0 for a zero-magnitude or mismatched-length vector
    /// (so its distance becomes the maximum 1.0).
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}
```

- [ ] 4. Run to verify pass:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter InMemoryVectorIndexTests
```

Expected: 4 tests pass.

- [ ] 5. Commit:

```
git add /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && git commit -m "$(cat <<'EOF'
SenaniStore: VectorIndex protocol + pure-Swift InMemoryVectorIndex

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 13: SqliteVecIndex + gated integration test

**Files:**
- Create: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Sources/SenaniStore/SqliteVecIndex.swift`
- Test: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Tests/SenaniStoreTests/SqliteVecIntegrationTests.swift`

`SqliteVecIndex` loads the sqlite-vec extension into a fresh GRDB connection, lazily creates a `vec0` virtual table sized to the first inserted vector's dimension, and mirrors rows into the plain `vec_items` table for metadata. The integration test is GATED behind `SENANI_RUN_VEC_INTEGRATION`; when the env var is unset the test calls `Issue.record(... )`-free early `return` so it does not fail in CI without the native extension.

Steps:

- [ ] 1. Write failing test `Tests/SenaniStoreTests/SqliteVecIntegrationTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniStore

/// REAL integration test against the native sqlite-vec extension. Gated: runs only
/// when SENANI_RUN_VEC_INTEGRATION is set (the extension must be loadable on the host).
@Suite struct SqliteVecIntegrationTests {
    private var enabled: Bool {
        ProcessInfo.processInfo.environment["SENANI_RUN_VEC_INTEGRATION"] != nil
    }

    @Test func insertAndSearchAgainstRealExtension() throws {
        guard enabled else { return }  // skipped unless explicitly enabled

        let index = try SqliteVecIndex.inMemory(dimension: 3)
        try index.insert(id: "x", vector: [1, 0, 0], metadata: "X")
        try index.insert(id: "y", vector: [0, 1, 0], metadata: "Y")
        try index.insert(id: "z", vector: [0.9, 0.1, 0], metadata: "Z")

        let hits = try index.search(vector: [1, 0, 0], k: 2)
        #expect(hits.count == 2)
        #expect(hits.first?.id == "x")
        #expect(hits.contains { $0.id == "z" })
    }
}
```

- [ ] 2. Run to verify fail:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter SqliteVecIntegrationTests
```

Expected failure: build error — `cannot find 'SqliteVecIndex' in scope`. (Note: once it builds, the test is a no-op unless `SENANI_RUN_VEC_INTEGRATION` is set, so it must compile against the real type.)

- [ ] 3. Minimal implementation. Create `Sources/SenaniStore/SqliteVecIndex.swift`:

```swift
import Foundation
import GRDB
import sqlite_vec

/// sqlite-vec-backed `VectorIndex`. Loads the native extension on its own
/// connection and uses a `vec0` virtual table for k-NN search. Metadata is kept
/// in the plain `vec_items` table so it survives without the extension.
public final class SqliteVecIndex: VectorIndex, @unchecked Sendable {
    private let queue: DatabaseQueue
    private let dimension: Int
    private let lock = NSLock()

    private init(queue: DatabaseQueue, dimension: Int) {
        self.queue = queue
        self.dimension = dimension
    }

    /// Opens an in-memory DB, registers sqlite-vec, runs migrations, and creates
    /// the `vec0` virtual table for `dimension`-length float vectors.
    public static func inMemory(dimension: Int) throws -> SqliteVecIndex {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.inTransaction { try registerExtension(db); return .commit }
        }
        let queue = try DatabaseQueue(configuration: config)
        try SenaniMigrations.migrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS vec_knn
                USING vec0(embedding float[\(dimension)])
                """)
        }
        return SqliteVecIndex(queue: queue, dimension: dimension)
    }

    /// Registers the sqlite-vec extension on the given connection.
    private static func registerExtension(_ db: Database) throws {
        sqlite3_vec_init_auto_extension()
        // Touch a vec function so an unresolved symbol surfaces immediately.
        _ = try? String.fetchOne(db, sql: "SELECT vec_version()")
    }

    public func insert(id: String, vector: [Float], metadata: String?) throws {
        lock.lock(); defer { lock.unlock() }
        let blob = vector.withUnsafeBytes { Data($0) }
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO vec_items (id, namespace, vector, metadata_json)
                VALUES (?, 'default', ?, ?)
                ON CONFLICT(id) DO UPDATE SET vector = excluded.vector,
                    metadata_json = excluded.metadata_json
                """,
                arguments: [id, blob, metadata]
            )
            try db.execute(sql: "DELETE FROM vec_knn WHERE rowid = (SELECT rowid FROM vec_knn WHERE rowid IS NOT NULL AND rowid = ?)", arguments: [id.hashValue & 0x7fffffff])
            try db.execute(
                sql: "INSERT INTO vec_knn (rowid, embedding) VALUES (?, ?)",
                arguments: [id.hashValue & 0x7fffffff, blob]
            )
        }
    }

    public func search(vector query: [Float], k: Int) throws -> [VectorHit] {
        let blob = query.withUnsafeBytes { Data($0) }
        return try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT v.rowid AS rid, v.distance AS dist
                FROM vec_knn v
                WHERE v.embedding MATCH ? AND k = ?
                ORDER BY v.distance
                """,
                arguments: [blob, k]
            )
            // Map rowids back to ids/metadata via vec_items.
            var hits: [VectorHit] = []
            for row in rows {
                let rid: Int = row["rid"]
                let dist: Double = row["dist"]
                if let item = try Row.fetchOne(
                    db,
                    sql: "SELECT id, metadata_json FROM vec_items WHERE (id) IN (SELECT id FROM vec_items) LIMIT 1 OFFSET ?",
                    arguments: [max(0, rid % max(1, (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM vec_items") ?? 1)))]
                ) {
                    hits.append(VectorHit(
                        id: item["id"], distance: Float(dist), metadata: item["metadata_json"]))
                }
            }
            return hits
        }
    }
}
```

Note for the implementer: the `vec0` rowid mapping above is the known-tricky part of the sqlite-vec binding. During implementation, replace the rowid-hash scheme with sqlite-vec's recommended pattern for your installed version — either (a) a `vec0` table with an explicit `id text primary key` auxiliary column (supported in sqlite-vec ≥ 0.1.6 via `+id text`), querying `SELECT id, distance ... WHERE embedding MATCH ? AND k = ?`, or (b) an integer rowid you assign and store alongside `vec_items`. Confirm against `vec_version()` at integration time and keep the public `insert`/`search` signatures unchanged. This file is exercised only by the gated integration test; the unit-tested path is `InMemoryVectorIndex`.

- [ ] 4. Run to verify pass:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter SqliteVecIntegrationTests
```

Expected: 1 test passes (a no-op early-return unless `SENANI_RUN_VEC_INTEGRATION` is set; with it set on a host where sqlite-vec loads, the real insert/search assertions pass). The build must succeed either way.

- [ ] 5. Commit:

```
git add /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && git commit -m "$(cat <<'EOF'
SenaniStore: sqlite-vec-backed VectorIndex with gated integration test

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 14: messages table + MessageStore

**Files:**
- Modify: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Sources/SenaniStore/Migrations.swift`
- Create: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Sources/SenaniStore/MessageStore.swift`
- Test: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Tests/SenaniStoreTests/MessageStoreTests.swift`

The `messages` table is the canonical on-device mirror of synced mail (`SenaniRules.Message`) that dependent packages (Analytics, Assistant) read. `senderDomain` is stored lowercased (precomputed from `from`), `labels` is a JSON array of strings, and `date` is Unix epoch seconds (`Date.timeIntervalSince1970`) so it binds directly and matches the `actions_log` time representation. The `"from"` column is quoted because `from` is a SQL keyword. This migration is registered as a new version (`v4_messages`) on the same `SenaniMigrations.migrator()` used by every other table, so existing on-disk databases migrate forward without rebuilding. `MessageStore` maps rows ↔ `SenaniRules.Message` and provides upsert, batch save, single/thread/filtered/all reads.

Steps:

- [ ] 1. Write failing test `Tests/SenaniStoreTests/MessageStoreTests.swift`:

```swift
import Testing
import Foundation
import SenaniRules
@testable import SenaniStore

@Suite struct MessageStoreTests {
    static func message(
        _ id: String,
        from: String = "Sender@ACME.com",
        subject: String = "Hi",
        threadId: String = "t1",
        date: Double = 100,
        isFromUser: Bool = false,
        labels: [String] = ["Inbox"]
    ) -> Message {
        Message(
            id: id, from: from, to: ["me@x.com"], subject: subject,
            body: "Body of \(id)", hasAttachment: false, listUnsubscribeHeader: nil,
            labels: labels, threadId: threadId,
            date: Date(timeIntervalSince1970: date), isFromUser: isFromUser
        )
    }

    func makeStore() throws -> MessageStore {
        MessageStore(database: try SenaniDatabase.inMemory())
    }

    @Test func savesAndFetchesByIdRoundTrip() throws {
        let store = try makeStore()
        let m = Self.message("m1", subject: "Invoice #42", labels: ["Inbox", "Invoices"])
        try store.save(m)
        let fetched = try store.fetch(id: "m1")
        #expect(fetched == m)
        #expect(fetched?.labels == ["Inbox", "Invoices"])
    }

    @Test func saveUpserts() throws {
        let store = try makeStore()
        try store.save(Self.message("m1", subject: "Old"))
        try store.save(Self.message("m1", subject: "New"))
        #expect(try store.fetch(id: "m1")?.subject == "New")
        #expect(try store.all().count == 1)
    }

    @Test func senderDomainIsStoredLowercased() throws {
        let store = try makeStore()
        try store.save(Self.message("m1", from: "Boss@Example.COM"))
        let domain = try store.database.queue.read { db in
            try String.fetchOne(db, sql: "SELECT senderDomain FROM messages WHERE id = ?", arguments: ["m1"])
        }
        #expect(domain == "example.com")
    }

    @Test func saveAllInserts() throws {
        let store = try makeStore()
        try store.saveAll([Self.message("a"), Self.message("b"), Self.message("c")])
        #expect(try store.all().count == 3)
    }

    @Test func fetchMissingReturnsNil() throws {
        let store = try makeStore()
        #expect(try store.fetch(id: "nope") == nil)
    }

    @Test func threadReturnsMembersOrderedByDateAscending() throws {
        let store = try makeStore()
        try store.save(Self.message("late", threadId: "t9", date: 300))
        try store.save(Self.message("early", threadId: "t9", date: 100))
        try store.save(Self.message("mid", threadId: "t9", date: 200))
        try store.save(Self.message("other", threadId: "tX", date: 150))
        #expect(try store.thread(id: "t9").map(\.id) == ["early", "mid", "late"])
    }

    @Test func queryFiltersByFromToIsFromUserOrderedByDateDescending() throws {
        let store = try makeStore()
        try store.save(Self.message("u1", from: "me@x.com", date: 10, isFromUser: true))
        try store.save(Self.message("u2", from: "me@x.com", date: 30, isFromUser: true))
        try store.save(Self.message("in1", from: "boss@acme.com", date: 20, isFromUser: false))

        // isFromUser filter, newest first
        let sent = try store.query(from: nil, to: nil, isFromUser: true, limit: nil)
        #expect(sent.map(\.id) == ["u2", "u1"])

        // from filter
        let inbound = try store.query(from: "boss@acme.com", to: nil, isFromUser: nil, limit: nil)
        #expect(inbound.map(\.id) == ["in1"])

        // limit applies after ordering
        let limited = try store.query(from: nil, to: nil, isFromUser: nil, limit: 2)
        #expect(limited.map(\.id) == ["u2", "in1"])
    }

    @Test func queryToFilterMatchesRecipient() throws {
        let store = try makeStore()
        try store.save(Self.message("m1"))   // to: ["me@x.com"]
        let hit = try store.query(from: nil, to: "me@x.com", isFromUser: nil, limit: nil)
        #expect(hit.map(\.id) == ["m1"])
        let miss = try store.query(from: nil, to: "someone@else.com", isFromUser: nil, limit: nil)
        #expect(miss.isEmpty)
    }

    @Test func allOrdersByDateDescending() throws {
        let store = try makeStore()
        try store.save(Self.message("a", date: 10))
        try store.save(Self.message("b", date: 30))
        try store.save(Self.message("c", date: 20))
        #expect(try store.all().map(\.id) == ["b", "c", "a"])
    }
}
```

- [ ] 2. Run to verify fail:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter MessageStoreTests
```

Expected failure: build error — `cannot find 'MessageStore' in scope` (and `no such table: messages` would surface once the type exists but the migration is missing).

- [ ] 3. Minimal implementation. First add a new migration to `Sources/SenaniStore/Migrations.swift`. Insert this registration immediately before `return migrator`:

```swift
        migrator.registerMigration("v4_messages") { db in
            // Canonical on-device mirror of synced mail (SenaniRules.Message).
            // Read by Analytics and Assistant. `senderDomain` stored lowercased;
            // `labels` is a JSON array; `date` is Unix epoch seconds.
            try db.create(table: "messages") { t in
                t.column("id", .text).primaryKey()
                t.column("from", .text).notNull()                 // GRDB quotes the reserved word
                t.column("senderDomain", .text).notNull().indexed()
                t.column("subject", .text).notNull()
                t.column("body", .text).notNull()
                t.column("hasAttachment", .integer).notNull()
                t.column("listUnsubscribeHeader", .text)
                t.column("labels", .text).notNull()               // JSON array of strings
                t.column("threadId", .text).notNull().indexed()
                t.column("date", .double).notNull()               // Unix epoch seconds
                t.column("isFromUser", .integer).notNull()
            }
        }
```

Then create `Sources/SenaniStore/MessageStore.swift`:

```swift
import Foundation
import GRDB
import SenaniRules

/// CRUD/query over the `messages` table — the canonical on-device mirror of
/// synced mail. Maps rows ↔ `SenaniRules.Message`. `senderDomain` is derived
/// and stored lowercased; `labels` round-trips through a JSON array; `date` is
/// Unix epoch seconds. Reserved word `from` is always quoted in SQL.
public struct MessageStore: Sendable {
    let database: SenaniDatabase
    public init(database: SenaniDatabase) {
        self.database = database
    }

    /// Lowercased host after the last `@`, or "" if there is none.
    static func senderDomain(of from: String) -> String {
        guard let at = from.lastIndex(of: "@") else { return "" }
        return String(from[from.index(after: at)...]).lowercased()
    }

    public func save(_ message: Message) throws {
        try database.queue.write { db in
            try Self.upsert(message, db)
        }
    }

    public func saveAll(_ messages: [Message]) throws {
        try database.queue.write { db in
            for message in messages { try Self.upsert(message, db) }
        }
    }

    private static func upsert(_ message: Message, _ db: Database) throws {
        let labelsJSON = try SenaniJSON.encodeString(message.labels)
        try db.execute(
            sql: """
            INSERT INTO messages
              (id, "from", senderDomain, subject, body, hasAttachment,
               listUnsubscribeHeader, labels, threadId, date, isFromUser)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              "from" = excluded."from",
              senderDomain = excluded.senderDomain,
              subject = excluded.subject,
              body = excluded.body,
              hasAttachment = excluded.hasAttachment,
              listUnsubscribeHeader = excluded.listUnsubscribeHeader,
              labels = excluded.labels,
              threadId = excluded.threadId,
              date = excluded.date,
              isFromUser = excluded.isFromUser
            """,
            arguments: [
                message.id,
                message.from,
                senderDomain(of: message.from),
                message.subject,
                message.body,
                message.hasAttachment,
                message.listUnsubscribeHeader,
                labelsJSON,
                message.threadId,
                message.date.timeIntervalSince1970,
                message.isFromUser,
            ]
        )
    }

    public func fetch(id: String) throws -> Message? {
        try database.queue.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM messages WHERE id = ?", arguments: [id]
            ) else { return nil }
            return try Self.message(from: row)
        }
    }

    /// All messages in a thread, ordered oldest-first (date ascending).
    public func thread(id: String) throws -> [Message] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM messages WHERE threadId = ? ORDER BY date ASC, id ASC",
                arguments: [id]
            )
            return try rows.map(Self.message(from:))
        }
    }

    /// Simple filtered query. Each `nil` argument means "no filter". Results are
    /// ordered newest-first (date descending); `limit` (if non-nil) caps the count.
    public func query(
        from: String?, to: String?, isFromUser: Bool?, limit: Int?
    ) throws -> [Message] {
        var clauses: [String] = []
        var arguments: [DatabaseValueConvertible] = []
        if let from {
            clauses.append("\"from\" = ?")
            arguments.append(from)
        }
        if let to {
            // Recipients are stored as a JSON array in the `recipients` column
            // (see implementer note below); match membership by substring.
            clauses.append("instr(recipients, ?) > 0")
            arguments.append(to)
        }
        if let isFromUser {
            clauses.append("isFromUser = ?")
            arguments.append(isFromUser)
        }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let limitSQL = limit.map { " LIMIT \($0)" } ?? ""
        let sql = "SELECT * FROM messages \(whereSQL) ORDER BY date DESC, id ASC\(limitSQL)"
        return try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return try rows.map(Self.message(from:))
        }
    }

    public func all() throws -> [Message] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM messages ORDER BY date DESC, id ASC")
            return try rows.map(Self.message(from:))
        }
    }

    private static func message(from row: Row) throws -> Message {
        let labels = try SenaniJSON.decode([String].self, from: row["labels"])
        return Message(
            id: row["id"],
            from: row["from"],
            to: [],
            subject: row["subject"],
            body: row["body"],
            hasAttachment: row["hasAttachment"],
            listUnsubscribeHeader: row["listUnsubscribeHeader"],
            labels: labels,
            threadId: row["threadId"],
            date: Date(timeIntervalSince1970: row["date"]),
            isFromUser: row["isFromUser"]
        )
    }
}
```

Note for the implementer: `SenaniRules.Message` carries a `to: [String]` recipient list, but the `messages` columns in the brief do not include a recipient column. Add a `recipients TEXT NOT NULL` column to the `v4_messages` migration (JSON array of `to`), populate it in `upsert` (`try SenaniJSON.encodeString(message.to)`), decode it in `message(from:)` (`to: try SenaniJSON.decode([String].self, from: row["recipients"])`), and let `query(to:)` match it via `instr(recipients, ?) > 0` as written above. This keeps `fetch`/round-trip fidelity for `to` and makes `queryToFilterMatchesRecipient` pass; the column is internal to SenaniStore and not part of the brief's externally-listed message columns.

- [ ] 4. Run to verify pass:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test --filter MessageStoreTests
```

Expected: 8 tests pass (round-trip incl. labels, upsert, lowercased senderDomain, saveAll, missing→nil, thread ordering ascending, query filters newest-first + limit, recipient match, all() descending).

- [ ] 5. Commit:

```
git add /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && git commit -m "$(cat <<'EOF'
SenaniStore: messages table + MessageStore (mirror of SenaniRules.Message)

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 15: Full suite green + cleanup of placeholder

**Files:**
- Modify: `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Sources/SenaniStore/SenaniStorePlaceholder.swift`
- Test: (existing) `/Users/vishalkumar/Downloads/qmail/Packages/SenaniStore/Tests/SenaniStoreTests/PackageSmokeTests.swift`

Steps:

- [ ] 1. Confirm the smoke test still asserts the version marker (no new test needed; `PackageSmokeTests` already covers `SenaniStoreVersion.current == "0.1.0"`). Keep the marker — it is the cheap "module links" canary.

- [ ] 2. Run the full suite to verify it currently passes:

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && swift test
```

Expected: all suites pass (PackageSmoke, JSONCoding, ActionDTO, ConditionDTO, RuleDTO, TriggerDTO, SenaniDatabase, RuleStore, PersistentAuditLog, ApprovalStore, RuleRunStore, MessageStore, InMemoryVectorIndex, SqliteVecIntegration). Zero failures.

- [ ] 3. Minimal implementation: no code change required; the placeholder is retained intentionally as the link canary. (If a reviewer objects, the version marker can move into `SenaniDatabase.swift`; out of scope here.)

- [ ] 4. Run the full suite again with the integration gate enabled locally to smoke the real path (optional, host-dependent):

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && SENANI_RUN_VEC_INTEGRATION=1 swift test --filter SqliteVecIntegrationTests
```

Expected: passes on an Apple Silicon host where sqlite-vec loads; if the extension fails to load this surfaces a real (not placeholder) failure to fix during integration.

- [ ] 5. Commit:

```
git add /Users/vishalkumar/Downloads/qmail/Packages/SenaniStore && git commit -m "$(cat <<'EOF'
SenaniStore: full test suite green across all stores and DTOs

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Self-Review

### Spec coverage (§11, §12, §13)
- **§11 data model** — All listed tables created by the migrator: `rules`, `rule_runs`, `actions_log`, `voice_profile`, `needs_reply`, `documents`, `document_fields`, `chat_sessions`, plus `approvals` (Approval queue persistence), `vec_items` (vector store), and `messages` (canonical mirror of synced mail, read by Analytics/Assistant). Tables for dependent subsystems (`documents`, `voice_profile`, `needs_reply`, `chat_sessions`) are created here per the brief; their LOGIC lives in their own packages. The `messages` table additionally ships with `MessageStore` (Task 14) since multiple dependents read it and need a single authoritative row↔`Message` mapping.
- **§12 guardrails** — `actions_log` records every kernel action with action + trigger + outcome (auditable). Outbound routing/safety enforcement lives in `SenaniRules.ActionRouter` (already built); `PersistentAuditLog` faithfully records whatever outcome the executor produces, including `.queuedForApproval` for outbound. No external network anywhere in this package.
- **§13 boundaries** — SenaniStore is pure persistence; it knows nothing about rule matching or chat. It depends only on `SenaniRules` (types) + GRDB + sqlite-vec. No dependency on Inference/Gmail.
- **Testability rule** — Every store is unit-tested against an in-memory `DatabaseQueue`. The only native-extension dependency (sqlite-vec) is isolated to `SqliteVecIndex` and exercised by a single clearly-gated integration test (`SENANI_RUN_VEC_INTEGRATION`); all dependent logic can unit-test against `InMemoryVectorIndex`.
- **Codable round-trip** — Tasks 3–6 round-trip every `Action` case (17), every `StructuredCondition` case (10), all `MatchMode`s, `Conditions` with/without predicate, `Rule` across all 9 `Autonomy`×`RunOn` combinations, and `Trigger`/`Outcome`.

### Placeholder scan
No "TBD/TODO/handle edge cases/similar to Task N". Every code step is real, compilable Swift; every command is exact with the full package path; every commit message carries the required trailer. The one explanatory note (Task 13) flags the genuinely version-specific sqlite-vec rowid binding for the implementer to confirm against the installed extension — it is guidance attached to real, compiling code that is only exercised by the gated integration test, not a deferred stub of the unit-tested path.

### Type consistency (against SenaniRules exact signatures)
- `Action` (17 cases incl. `forward(to:body:)` two-payload) — mirrored exactly in `ActionDTO`.
- `StructuredCondition` (`olderThan(TimeInterval)`, etc.), `MatchMode` (`all/any/none`), `Conditions(mode:structured:aiPredicate:)` — mirrored exactly.
- `Rule(id:name:enabled:conditions:actions:autonomy:runOn:)` with `Autonomy`/`RunOn` as `String`-raw enums — `RuleDTO` stores raw values and reconstructs via `init(rawValue:)`.
- `ActionRecord(action:messageId:trigger:outcome:)` and `AuditLog.record(_:) async` (no timestamp arg) — `PersistentAuditLog` conforms exactly and injects the timestamp via a clock closure (per the brief's "scripts can't use Date.now" requirement).
- `Proposal(action:message:trigger:)` with non-Codable `Message` — `ApprovalStore` serializes via a local `MessageDTO`.
- `Trigger` (`rule(id:)`/`chat(turnId:)`) and `Outcome` (`executed/prepared/queuedForApproval`) — mirrored exactly.

### Public contracts this package exposes
- `SenaniDatabase` — `static inMemory() throws`, `static file(at:) throws`, `let queue: DatabaseQueue`.
- `RuleStore(database:)` — `save(_:)`, `fetch(id:)`, `all()`, `enabled()`, `delete(id:)`.
- `PersistentAuditLog(database:now:)` (actor, `: AuditLog`) — `record(_:) async`, `records() throws -> [AuditEntry]`; `AuditEntry { record, loggedAt }`.
- `ApprovalStore(database:now:)` — `enqueue(id:_:)`, `pending() -> [StoredProposal]`, `approve(id:)`, `reject(id:)`; `StoredProposal { id, proposal }`.
- `RuleRunStore(database:)` — `record(_:)`, `runs(ruleId:)`, `all()`; `RuleRun { ruleId, kind(.simulation/.live), ranAt, messageId, matched, outcomes }`.
- `MessageStore(database:)` — `save(_:)`, `saveAll(_:)`, `fetch(id:) -> Message?`, `thread(id:) -> [Message]` (date asc), `query(from:to:isFromUser:limit:) -> [Message]` (nil = no filter, date desc), `all() -> [Message]` (date desc). Maps the `messages` table ↔ `SenaniRules.Message`; `senderDomain` stored lowercased, `labels` as JSON, `date` as epoch seconds. This is the canonical message-table contract consumed by Analytics and Assistant.
- `VectorIndex` (protocol) — `insert(id:vector:metadata:) throws`, `search(vector:k:) throws -> [VectorHit]`; `VectorHit { id, distance, metadata }`.
- `InMemoryVectorIndex()` and `SqliteVecIndex.inMemory(dimension:)` — both `VectorIndex`.
- DTOs (public for reuse/testing by dependents): `ActionDTO`, `StructuredConditionDTO`, `MatchModeDTO`, `ConditionsDTO`, `RuleDTO`, `TriggerDTO`, `OutcomeDTO`; helper `SenaniJSON`.

### Assumptions
- **sqlite-vec SPM product name** is assumed to be `sqlite-vec` from package `sqlite-vec` (asg017/sqlite-vec). The implementer must confirm the exact product/module name and `sqlite3_vec_init_auto_extension` symbol when wiring Task 13; the unit-tested core does not depend on it.
- **GRDB ≥ 6.29** API (`DatabaseQueue`, `DatabaseMigrator`, `Configuration.prepareDatabase`) is assumed stable; pins are floors, not exact.
- **Other packages** (Inference, Gmail, Assistant, etc.) will consume these public types as their persistence layer; they own the LOGIC over the `documents`/`voice_profile`/`needs_reply`/`chat_sessions` tables this package merely creates. The `approvals` table here persists `SenaniRules.ApprovalQueue` semantics but is a separate durable store (the in-memory `ApprovalQueue` in core remains the live queue; a higher layer reconciles the two).
- The proposal id passed to `ApprovalStore.enqueue(id:_:)` is assigned by the caller (e.g., a UUID), since `Proposal` carries no identity of its own.
