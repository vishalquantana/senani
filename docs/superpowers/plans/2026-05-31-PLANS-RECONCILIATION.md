# Senani — Cross-Package Plans Reconciliation

> **Read this BEFORE building any dependent package.** This is a coordination reference, not a TDD plan. It pins the shared contracts so the dependent plans align, and lists the deviations each dependent must make where its plan guessed an API. Every dependent plan already instructs its executor to record deviations from real upstream contracts — this doc tells you what those real contracts are.

---

## 1. Build order (dependency DAG)

```
SenaniRules  (BUILT — on disk)
   │
SenaniStore
   │
   ├── SenaniInference
   └── (SenaniStore + SenaniInference together gate the leaf layer)
        │
        ├── SenaniVoice
        ├── SenaniDocs
        ├── SenaniReplyZero
        ├── SenaniAnalytics
        └── SenaniAssistant
```

Build top-to-bottom; the four/five leaf packages are independent of each other and may be built in any order or in parallel once both `SenaniStore` and `SenaniInference` are green.

**Ground truth:** `SenaniStore` and `SenaniInference` are authoritative. When a dependent plan's *assumed* API differs from what Store/Inference actually shipped, **the dependent adapts** (each dependent plan already says to record the deviation). This doc enumerates the known mismatches so they are fixed on first build rather than discovered late.

---

## 2. Canonical shared contracts

Pin these exact signatures. Where a dependent plan guessed something else, the **Fix** line says what to change.

### `SenaniStore.SenaniDatabase`
```swift
public final class SenaniDatabase: Sendable {
    public let queue: DatabaseQueue
    public static func inMemory() throws -> SenaniDatabase
    public static func file(at path: String) throws -> SenaniDatabase
}
```
Constructed via the **static factories** `inMemory()` / `file(at:)`. There is **no** `init(inMemory:)` and no `init(path:)`.

- **Fix (SenaniDocs):** the Docs plan uses `try SenaniDatabase(inMemory: true)` in several test helpers — replace with `try SenaniDatabase.inMemory()`.
- **Fix (SenaniAssistant):** the Assistant plan assumed `SenaniDatabase.inMemory()` (correct) with a `SenaniDatabase(path: ":memory:")` fallback — drop the fallback; use `inMemory()`.

### `SenaniStore.MessageStore`
The canonical mirror of synced mail (see SenaniStore plan, Task 14 — `messages` table + `MessageStore`):
```swift
public struct MessageStore: Sendable {
    public init(database: SenaniDatabase)
    public func save(_ message: SenaniRules.Message) throws            // upsert
    public func saveAll(_ messages: [SenaniRules.Message]) throws
    public func fetch(id: String) throws -> SenaniRules.Message?
    public func thread(id: String) throws -> [SenaniRules.Message]      // date asc
    public func query(from: String?, to: String?, isFromUser: Bool?, limit: Int?) throws -> [SenaniRules.Message]  // nil = no filter; date desc
    public func all() throws -> [SenaniRules.Message]                   // date desc
}
```
`messages` columns: `id TEXT PK`, `"from" TEXT`, `senderDomain TEXT` (lowercased), `subject`, `body`, `hasAttachment INTEGER`, `listUnsubscribeHeader TEXT?`, `labels TEXT` (JSON array), `threadId TEXT`, `date DOUBLE` (epoch seconds), `isFromUser INTEGER` (+ an internal `recipients` JSON column for `to`).

- **MUST (SenaniAnalytics, SenaniAssistant):** read messages **through `MessageStore`** (or the canonical `messages` schema above) — do **not** hand-roll a private `messages` table with a different column set. Analytics's assumed `messages` columns (`id, "from", senderDomain, date, isFromUser, threadId`) are a strict subset of the canonical schema, so its read SQL is compatible as-is.

### `SenaniStore.VectorIndex`
```swift
public struct VectorHit { let id: String; let distance: Float; let metadata: [String: String] }

public protocol VectorIndex: Sendable {
    func insert(id: String, vector: [Float], metadata: [String: String]) throws
    func search(vector: [Float], k: Int) throws -> [VectorHit]
}
```
`InMemoryVectorIndex` is the unit-test implementation. It additionally exposes test-introspection accessors for dependents:
```swift
public var count: Int { get }
public var entries: [...]   // inserted items, for assertions
```
(If a dependent needs to read back a single item's metadata, use `search(...).first(where:)` and `.metadata`, or the `entries` accessor — not a bespoke lookup.)

- **Fix (SenaniVoice, SenaniDocs):** both assume `search(...) -> [(id: String, distance: Float)]` tuples. Replace tuple destructuring with `VectorHit` and use `.id` / `.distance` / `.metadata`.
- **Fix (SenaniVoice):** replace `InMemoryVectorIndex.metadata(for: id)` lookups with `VectorHit.metadata` from the search result (or the `entries` accessor). Metadata is `[String: String]`, so `hit.metadata["domain"]`, `hit.metadata["messageId"]`, `hit.metadata["text"]` work directly.
- **Note:** dependents already pass `[String: String]` metadata (`["domain": ..., "messageId": ...]`, `["documentId": ..., "chunk": ...]`), which matches the canonical `insert` signature — this is the authoritative metadata type for `VectorIndex` across the project.

### `SenaniStore.RuleStore`
```swift
public struct RuleStore: Sendable {
    public init(database: SenaniDatabase)
    public func save(_ rule: SenaniRules.Rule) throws        // upsert
    public func fetch(id: String) throws -> SenaniRules.Rule?
    public func all() throws -> [SenaniRules.Rule]
    public func enabled() throws -> [SenaniRules.Rule]
    public func delete(id: String) throws
}
```

### `SenaniStore.PersistentAuditLog`
```swift
public actor PersistentAuditLog: SenaniRules.AuditLog {
    public init(database: SenaniDatabase, now: @escaping @Sendable () -> Double)  // injected clock, epoch seconds
    public func record(_ record: SenaniRules.ActionRecord) async   // AuditLog conformance
    public func records() throws -> [AuditEntry]                    // AuditEntry { record: ActionRecord; loggedAt: Double }
}
```
The reader returns `[AuditEntry]` (each carrying the logged timestamp), **not** raw `[ActionRecord]`.

**`actions_log` schema — canonical (SenaniStore is authoritative):**

| column | type | meaning |
|---|---|---|
| `id` | INTEGER PK AUTOINCREMENT | row id |
| `message_id` | TEXT NOT NULL | message the action targeted |
| `action_json` | TEXT NOT NULL | `ActionDTO` JSON |
| `trigger_json` | TEXT NOT NULL | `TriggerDTO` JSON — this is where the rule id / chat-turn id lives |
| `outcome` | TEXT NOT NULL | `executed` / `prepared` / `queuedForApproval` (`SenaniRules.Outcome` raw values) |
| `logged_at` | DOUBLE NOT NULL | epoch seconds |

> ⚠️ **CONTRADICTION — Analytics vs Store `actions_log` columns.** The **Analytics plan assumes a different schema**: columns `id`, `ruleId TEXT (NULL for chat)`, `outcome`, `messageId`, `date`. The **Store plan (authoritative)** ships `id`, `message_id`, `action_json`, `trigger_json`, `outcome`, `logged_at`. Differences Analytics MUST reconcile against the canonical schema:
> 1. **No top-level `ruleId` column.** The trigger (rule id vs chat turn) is serialized inside `trigger_json` as a `TriggerDTO` (`{ "kind": "rule"|"chat", "identifier": "<id>" }`). Analytics's `ruleActivity(since:)` must derive the rule id from `trigger_json` (e.g. `json_extract(trigger_json, '$.identifier')` filtered on `json_extract(trigger_json, '$.kind') = 'rule'`) instead of `WHERE ruleId IS NOT NULL`. Chat-triggered rows are those with `kind = 'chat'` and remain excluded from per-rule activity.
> 2. **`messageId` → `message_id`** (snake_case).
> 3. **`date` → `logged_at`** (snake_case) for the action timestamp.
>
> `outcome` values match exactly (`executed`/`prepared`/`queuedForApproval`), so the outcome aggregation logic is unchanged. Analytics's public API does not change; only its read SQL / column names do. Alternatively, SenaniStore could add a generated/derived `ruleId` read-view, but the **canonical resolution is: Analytics adapts to `trigger_json` + snake_case columns**, since Store owns the schema.

### `SenaniInference.TextGenerator`
```swift
public protocol TextGenerator: Sendable {
    func generate(prompt: String, maxTokens: Int) async throws -> String
    func generateJSON(prompt: String, schema: JSONSchema) async throws -> String
}
```

`JSONSchema` is an **enum**, not a struct with a string initializer:
```swift
public indirect enum JSONSchema: Sendable, Equatable {
    case boolean
    case string
    case number
    case array(element: JSONSchema)
    case object(properties: [String: JSONSchema], required: [String])
}
```

- **Resolution (chosen):** add a tiny convenience initializer **to SenaniInference** so dependents that hold a raw JSON-schema string keep working:
  ```swift
  public extension JSONSchema { init(json: String) { /* parse/wrap the raw schema string */ } }
  ```
  Treat this as a small addition to the Inference package (a one-line convenience init + a round-trip test). With it present, the Docs and Assistant plans that assumed `JSONSchema(json:)` compile unchanged. Dependents may alternatively build the enum value directly (e.g. `JSONSchema.object(properties: [...], required: [...])`); either is acceptable, but the `JSONSchema(json:)` convenience init is the pinned resolution so existing dependent code is not rewritten.
- **Fix (SenaniDocs, SenaniAssistant):** keep `JSONSchema(json:)` call sites; they resolve against the added convenience init.

### `SenaniInference` test fakes
`FakeTextGenerator` (settable canned text / `jsonResponse`, records `lastPrompt`) and `FakeEmbedder` (deterministic, distance-meaningful vectors, records `embeddedTexts`) live in the **Inference package's test support** and conform to `TextGenerator` / `Embedder`.

- **MUST (all dependents):** define your **own local fakes** conforming to `SenaniInference.TextGenerator` / `Embedder` in your own test target. Do **not** import another package's test target — that creates cross-test-target coupling. The Inference fakes are a reference shape, not a shared dependency. (The Assistant plan's `PromptRecordingGenerator` and the Voice/Docs local `FakeEmbedder` patterns are the correct approach.)

### `SenaniRules.ActionExecutor` + chat-triggered actions
`SenaniRules.ActionExecutor.execute(match:)` **hardcodes `Trigger.rule(id:)`** — it cannot carry a `.chat(turnId:)` trigger. (Confirmed by reading the built source.)

- **Canonical approach:** chat-triggered writes go through the Assistant plan's **`ChatActionDispatcher`**, which reuses the pure `ActionRouter.route` plus the same `MailBackend` / `ApprovalQueue` / `AuditLog` seams, tagging actions with `Trigger.chat(turnId:)`. This is intentional reuse of the *routing*, not a second safety path.
- **Do NOT modify `ActionExecutor`** (SenaniRules is built and frozen). If SenaniRules later gains a chat-trigger executor, `ChatActionDispatcher` can delegate to it.

---

## 3. Open items for the human (verify at build time)

These are external pins / native symbols the plans assume but cannot fully verify on paper. Confirm each before/at first build of the relevant package:

- **GRDB + sqlite-vec (SenaniStore):** confirm the GRDB SPM version (floor `6.29.0`), and the **`sqlite-vec` SPM product/module name** and the extension init symbol (`sqlite3_vec_init_auto_extension` vs the installed `0.1.6`+ binding) — the unit-tested core uses `InMemoryVectorIndex` and does not depend on this; only the gated `SqliteVecIndex` integration test does.
- **MLX (SenaniInference):** confirm the **mlx-swift / mlx-swift-examples** package pins and the exact MLX generation symbol names used by `MLXTextGenerator` (gated, host-dependent on Apple Silicon).
- **Google OAuth (SenaniGmail):** a provisioned **Google OAuth desktop client ID** for the on-device sync path.
- **Document parsing (SenaniDocs):** the vendored **liteparse** Rust crate, plus the **PDFium** and **Tesseract** build/link setup for the real parse path (unit tests use fakes).
