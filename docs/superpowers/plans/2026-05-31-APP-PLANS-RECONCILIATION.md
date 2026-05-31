# Senani — App-Layer Plans Reconciliation

> **Read this BEFORE building any app-layer package or screen.** This is the coordination reference for the *application* tier (the SwiftUI app + Agent Engine + connectors + agents + UI), the same role [`2026-05-31-PLANS-RECONCILIATION.md`](2026-05-31-PLANS-RECONCILIATION.md) played for the nine engine packages. It pins the shared app-layer contracts so the ~20 dependent plans align, and records the real upstream package APIs the app codes against.
>
> The nine engine packages (`SenaniRules`, `SenaniStore`, `SenaniInference`, `SenaniGmail`, `SenaniVoice`, `SenaniDocs`, `SenaniReplyZero`, `SenaniAnalytics`, `SenaniAssistant`) are **BUILT, tested green, and frozen**. The app layer adapts to them — never edit a frozen package to make an app plan compile; write an adapter in the app tier instead.
>
> **The app already exists as a scaffold.** `SenaniApp/Package.swift` is a SwiftPM **executable** package (swift-tools 5.9, macOS 14) that already depends on all nine engine packages via local `path:` references, with starter files under `SenaniApp/Sources/SenaniApp/` (`SenaniApp.swift`, `UI/MainNavigationView.swift`, `UI/DetailView.swift`, `UI/Theme.swift`). The app-shell plan **builds on this scaffold** (replacing/extending those files) — it is NOT greenfield. New app-tier packages (`SenaniEngine`, `SenaniDesign`) are added under `Packages/` and referenced from `SenaniApp/Package.swift`.
>
> **No upstream fakes.** `SenaniInference` ships **no** `FakeTextGenerator`/`FakeEmbedder` (verified). Every app/test target defines its **own** local fakes conforming to `SenaniInference.TextGenerator`/`Embedder`. (`SenaniInference` is also under active concurrent development — an embedding-Gemma path is in flight — so pin only the protocols, not internal types.)

---

## 1. Build order (app-tier dependency DAG)

```
[ENGINE PACKAGES — built & frozen]
        │
SenaniEngine          (NEW package: Agent protocol, Orchestrator, Scheduler, AgentTools)   ← unblocks everything
        │
SenaniApp shell        (Xcode project + SwiftUI App target + composition root)
   ├── DesignSystem     (gold-glass tokens + components — peer of the shell, no engine dep)
   ├── Live store bootstrap        (file-backed SenaniDatabase + SqliteVecIndex on launch)
   ├── Gmail OAuth + onboarding    (GmailAuth + Keychain + connect UI)
   └── MLX model picker + downloader (MLXTextGenerator live path + catalog UI)
        │
   [Phase-1 agents]  Triage · Reply Drafter        → emit Proposals via SenaniEngine
        │
   [Phase-1 UI]      Inbox cockpit · Approval queue + Activity log
        │
   [Phase-2 agents]  Booking (+Calendar connector) · Daily Digest · Inbox Hygiene
   [Phase-3 agents]  Lead Qualifier · Proposal Tracker · Follow-up · Outreach · Invoice/Finance
   [Phase-3 UI]      Pipeline / CRM view
        │
   [Phase-4]         Landing + pricing page  (web, independent)
   [Deferred]        Code signing/notarization · License keys · Auto-update
```

**Critical path to the demoable MVP** (mail in → triaged → reply drafted → approved → draft in Gmail): `SenaniEngine` → app shell + design system + store bootstrap + Gmail OAuth + MLX picker → Triage agent + Reply Drafter agent → Inbox cockpit + Approval/Activity UI. Everything below that is post-MVP.

**Ground truth:** `SenaniEngine` is authoritative for the *runtime* contracts (Agent, AgentContext, AgentTools, Orchestrator, Scheduler). All agent and UI plans code to the §3 signatures below. If `SenaniEngine`'s built API differs, the dependent adapts and records the deviation — same discipline as the package tier.

---

## 2. Real upstream package contracts (authoritative, verified from source)

These are the **actual** public signatures the app tier wires. Pin them; do not re-guess.

### `SenaniRules` (frozen)
```swift
public struct Message: Sendable, Codable, Identifiable  // id, from, to, senderDomain, subject, body,
                                                         // hasAttachment, listUnsubscribeHeader, labels, threadId, date, isFromUser
public enum Action: Sendable {          // ⚠ VERIFIED real cases (there is NO `draftReply`, NO compose-new, NO calendar/unsubscribe):
    case label(String), archive, markRead, markUnread, star, unstar, move(String)   // reversible
    case flagNeedsReply, fileAttachment(folder: String), parseDoc, runAgent(id: String), localWebhook(name: String)  // reversible/internal
    case draft(body: String)            // reversible (a saved draft, not sent)
    case reply(body: String), forward(to: String, body: String), send(body: String), markSpam   // OUTBOUND → always queues
    public var actionClass: ActionClass { /* reply/forward/send/markSpam → .outbound; rest → .reversible */ } }
public enum ActionClass { case reversible, outbound, readonly }   // outbound ALWAYS queues
// AgentTools.reply(to:body:) → Action.reply (outbound). A "compose new message to a new recipient",
// a "calendar hold", and an "https one-click unsubscribe" have NO Action case → each is a §5 blocking
// item (Outreach, Booking, Inbox-Hygiene flagged them). Until added, those agents queue an outbound
// reply/send draft and never auto-act.
public enum Outcome { case executed, prepared, queuedForApproval }
public enum Autonomy: String { case ask, prepare, auto }   // ⚠ REAL cases are ask/prepare/auto — the
// ARCHITECTURE "Suggest → Draft → Auto" ladder maps to ask → prepare → auto. UI may render those labels,
// but bind the real .ask/.prepare/.auto cases.
public enum Trigger { case rule(id: String), chat(turnId: String) }
public struct Rule: Sendable, Codable   // id, name, enabled, conditions, actions, autonomy, runOn, aiPredicate, mode
public struct RuleMatch { public let rule: Rule; public let message: Message }
public struct RuleEngine { public init(evaluator: any PredicateEvaluator)
    public func match(message: Message, rules: [Rule], now: Date) async -> [RuleMatch] }
public enum ActionRouter { public static func route(_ action: Action, autonomy: Autonomy) -> Outcome }
public struct ActionExecutor                       // hard-codes Trigger.rule — do NOT use for chat
public protocol MailBackend: Sendable { func apply(_ action: Action, to message: Message) async throws }
public actor ApprovalQueue { func enqueue(_ p: Proposal); func pending() -> [Proposal] }   // in-memory
public struct Proposal { public init(action: Action, message: Message, trigger: Trigger) }
public protocol AuditLog: Sendable { func record(_ r: ActionRecord) async }
public struct ActionRecord { public init(action: Action, messageId: String, trigger: Trigger, outcome: Outcome) }
public protocol PredicateEvaluator: Sendable
public struct Simulator                            // dry-run, no side effects
```

### `SenaniStore` (frozen) — the persistent seams
```swift
public final class SenaniDatabase: Sendable {
    public let queue: DatabaseQueue
    public static func inMemory() throws -> SenaniDatabase
    public static func file(at path: String) throws -> SenaniDatabase     // ← live app uses this
}
public struct MessageStore { init(database:); save / saveAll / fetch(id:) / thread(id:) / query(from:to:isFromUser:limit:) / all() }
public struct RuleStore   { init(database:); save / fetch(id:) / all() / enabled() / delete(id:) }
public struct ApprovalStore {                                  // ⚠ VERIFIED — NOT `save`
    init(database: SenaniDatabase, now: @escaping @Sendable () -> Double)
    func enqueue(id: String, _ proposal: Proposal) throws      // caller supplies the id
    func pending() throws -> [StoredProposal]
    func approve(id: String) throws
    func reject(id: String) throws }
public struct StoredProposal { init(id: String, proposal: Proposal); let id: String; let proposal: Proposal }
public struct RuleRunStore  { init(database:); save / runs(...) }
public actor  PersistentAuditLog: SenaniRules.AuditLog {
    init(database: SenaniDatabase, now: @escaping @Sendable () -> Double)   // ⚠ now: is REQUIRED
    func record(_:) async; func records() throws -> [AuditEntry] }
public protocol VectorIndex: Sendable { func insert(id:vector:metadata:) throws; func search(vector:k:) throws -> [VectorHit] }
public struct VectorHit { public let id: String; public let distance: Float; public let metadata: [String:String] }
public final class InMemoryVectorIndex: VectorIndex      // tests
public final class SqliteVecIndex: VectorIndex {         // ← live app uses this
    init(database: SenaniDatabase, namespace: String = "default") }
// ⚠ sqlite-vec PIN IS CLOSED: SqliteVecIndex has NO native sqlite-vec dependency — it does pure-Swift
// cosine over Float32 blobs in a `vec_items` table. No extension symbol to confirm; it always works.
```

### `SenaniInference` (frozen)
```swift
public protocol TextGenerator: Sendable {
    func generate(prompt: String, maxTokens: Int) async throws -> String
    func generateJSON(prompt: String, schema: JSONSchema) async throws -> String }
public protocol Embedder: Sendable { func embed(_ text: String) async throws -> [Float] }
public final class MLXTextGenerator: TextGenerator       // ← live inference path (Apple Silicon)
public final class MLXEmbedder: Embedder
public indirect enum JSONSchema: Sendable, Equatable     // .object(properties:required:) etc; has init(json:) convenience
public struct GemmaPredicateEvaluator: SenaniRules.PredicateEvaluator   // bridges Inference → Rules
```
> **Model picker note:** the catalog/RAM-tier picker + Hugging Face downloader is NOT in the package — `MLXTextGenerator` assumes weights already on disk. The downloader/catalog is app-tier work (the MLX picker plan owns it).

### `SenaniGmail` (frozen) — the connector
```swift
public actor GmailAuth {                                 // tokens in store; refreshes automatically
    init(clientID: String, http: any HTTPClient, store: any TokenStore, now: @escaping @Sendable () -> Date)
    func authenticate(code: String, redirectURI: String, verifier: String) async throws
    func validAccessToken() async throws -> String }     // conforms to AccessTokenProviding
public struct PKCE { public let verifier: String; public let challenge: String; static func random() -> PKCE }
public enum GmailEndpoints { static func authorizationURL(...) -> URL ; … }     // build the consent URL
public protocol TokenStore: Sendable { func save(_:) async throws; func load() async throws -> OAuthToken?; func clear() async throws }
public struct KeychainTokenStore: TokenStore             // ← live token storage (macOS Keychain)
public actor  InMemoryTokenStore: TokenStore             // tests
public struct OAuthToken { accessToken; refreshToken; expiresAt }
public struct GmailSync: Sendable { func fetchMessages(query: String, maxResults: Int) async throws -> [Message] }
public struct GmailMailBackend: SenaniRules.MailBackend { func apply(_ action: Action, to message: Message) async throws }
public protocol HTTPClient: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }
public struct URLSessionHTTPClient: HTTPClient           // ← live HTTP
```
> **OAuth open pin:** a provisioned Google OAuth **desktop** client ID is required for the live consent flow (the onboarding plan owns wiring it; the human supplies the ID). Calendar scope is added by the Booking plan.

### Other frozen leaf packages
```swift
SenaniVoice:      VoiceProfileBuilder.build(...) -> VoiceProfile ; VoiceConditioner.promptPrefix ; VoiceProfileStore ; VoiceExemplarIndexer
SenaniReplyZero:  ReplyZeroService.scan(...) ; NeedsReplyClassifier ; NeedsReplyStore (pending/needsYou/clear)
SenaniDocs:       DocumentPipeline.process(...) ; DocumentExtractor.fields ; DocumentSearch.semantic ; LiteParseDocumentParser
SenaniAnalytics:  AnalyticsQueries { volumeByDay / topSenders / topDomains / replyLatency / ruleActivity }  (reads canonical Store schema)
SenaniAssistant:  AssistantController.handle(turn:context:) async -> AssistantResponse ; ChatActionDispatcher (Trigger.chat) ; AssistantTool ; ToolCall.parse
```

---

## 3. NEW app-layer contracts to PIN (authoritative for dependents)

These types do **not** exist yet. The plans that own them MUST ship exactly these signatures so dependent plans compile. If an owner changes a signature, update this doc in the same commit.

### `SenaniEngine` — the Agent Engine (owned by the orchestrator plan)
The runtime brain. A new Swift package `Packages/SenaniEngine`, pure/testable with fakes, depending only on the frozen engine packages.

```swift
// An agent is a pure function from (message, context, tools) → proposals. It NEVER touches Gmail directly.
public protocol Agent: Sendable {
    var id: String { get }                  // stable identity, e.g. "triage", "reply-drafter"
    var autonomy: Autonomy { get }          // per-agent dial; the Orchestrator (not the agent) enforces it
    func wakesFor(_ message: Message, context: AgentContext) -> Bool      // trigger predicate (pure)
    func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action]
}

// Read-only world the agent may see. Pre-populated by the Orchestrator; agents never query stores directly.
public struct AgentContext: Sendable {
    public let account: String
    public let thread: [Message]            // the message's thread, date asc
    public let rules: [Rule]
    public let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit]   // semantic search seam
    public let now: Date
    // Additive fields agreed across the agent plans (the orchestrator pre-populates them):
    public let needsReply: Bool             // ReplyZero signal (Reply-Drafter / Follow-up)
    public let documentFields: [String: String]   // SenaniDocs extraction for the message's attachment (Proposal-Tracker)
    public let pipeline: (any PipelineStore)?      // CRM seam (Lead-Qualifier / Proposal-Tracker / Follow-up); nil pre-Phase-3
}
// ⚠ PipelineStore/Deal/DealStage are pinned by the pipeline-crm-view plan (Phase 3) — see that plan; agents
// reach the CRM through `context.pipeline` (a store write), NOT through AgentTools (which only build routed Actions).

// Capabilities an agent may call to BUILD actions (pure builders — return Action, do NOT execute) + the
// injected inference seam (agents reach the model ONLY through tools, so they stay testable with a fake).
public struct AgentTools: Sendable {
    public func draftReply(to message: Message, body: String) -> Action      // ⚠ maps to SenaniRules.Action.draft(body:)
                                                                         //   it is REVERSIBLE.
    public func proposeLabel(_ label: String, on message: Message) -> Action   // reversible
    public func archive(_ message: Message) -> Action                          // reversible
    public func markRead(_ message: Message) -> Action                         // reversible
    // Added by the Triage plan: the generator seam so LLM-backed agents stay pure.
    // AgentTools holds `private let generator: any TextGenerator`; the Orchestrator injects it.
    public func generateJSON(prompt: String, schema: JSONSchema) async throws -> String
}

// Maps a triaged category → the agents subscribed to it.
public struct AgentRegistry: Sendable {
    public init(agents: [any Agent])
    public func agents(for category: String) -> [any Agent]
}

// The orchestrator: one synced message → triage → route → agents → route each Action via
// ActionRouter.route(action, autonomy: agent.autonomy), then ACT ON THE OUTCOME the same way the frozen
// SenaniRules.ActionExecutor does: `.executed` AND `.prepared` → MailBackend.apply (reversible writes apply);
// `.queuedForApproval` → ApprovalStore.enqueue(id:_:) with a generated id (outbound, or a low autonomy dial);
// every outcome recorded to PersistentAuditLog with Trigger.rule(id: agent.id).
// ⚠ NOTE: SenaniEngine is bootstrapped with Agent/AgentContext/AgentTools by the Triage plan.
public actor Orchestrator {
    public init(registry: AgentRegistry,
                triage: any Agent,                 // the Triage agent runs first and tags category via a label Action
                mailBackend: any MailBackend,
                approvals: ApprovalStore,
                audit: any AuditLog,
                messages: MessageStore,
                index: any VectorIndex,
                embedder: any Embedder,
                rules: RuleStore,
                now: @escaping @Sendable () -> Date)
    public func process(_ message: Message) async throws -> [ProcessedOutcome]
    public func processInbox() async throws -> [ProcessedOutcome]      // batch over MessageStore.all()
}
public struct ProcessedOutcome: Sendable { public let agentId: String; public let action: Action; public let outcome: Outcome }

// Drives processing: on a timer while awake, on the manual "Process inbox" button, and after a sync.
public actor Scheduler {
    public init(sync: GmailSyncing, store: MessageStore, orchestrator: Orchestrator,
                interval: TimeInterval, now: @escaping @Sendable () -> Date)
    public func tick() async throws            // one sync+process cycle; UI/timer calls this
    public func start() async                  // schedules ticks; respects low-power (host checks injected)
    public func stop() async
}
public protocol GmailSyncing: Sendable { func fetchMessages(query: String, maxResults: Int) async throws -> [Message] }
// GmailSync conforms to GmailSyncing via a one-line app-tier extension (do not edit SenaniGmail).
```

> **Trigger for agent-originated actions:** agents run through the rule path, so the Orchestrator tags their actions `Trigger.rule(id: agent.id)` and may persist a synthetic `Rule` per agent (or pass agent.id directly). Chat-originated actions still go through `SenaniAssistant.ChatActionDispatcher` with `Trigger.chat`. There is exactly one routing path (`ActionRouter.route`) and one safety model — never a second one.

### `DesignSystem` — gold-glass tokens (owned by the design-system plan)
A peer Swift package or app-internal module. Pin these symbol names; every screen imports them.
```swift
public enum Gold { static let base/highlight/shadow: Color }           // the gold gradient stops
public struct GlassPanel<Content: View>: View { init(@ViewBuilder content:) }   // frosted gold-glass container
public struct AutonomyDial: View { init(_ binding: Binding<Autonomy>) }
public extension Font  { static let senaniTitle/senaniBody/senaniMono: Font }
public extension Color { static let senaniInk/senaniSurface/senaniAccent: Color }
```

### Composition root (owned by the app-shell plan)
```swift
// Single place that constructs the live object graph and injects it into SwiftUI via @Environment / @Observable.
@MainActor public final class AppEnvironment: ObservableObject {
    public let database: SenaniDatabase           // .file(at: appSupportURL)
    public let messages: MessageStore
    public let rules: RuleStore
    public let approvals: ApprovalStore
    public let audit: PersistentAuditLog
    public let index: SqliteVecIndex
    public let generator: any TextGenerator       // MLXTextGenerator once a model is chosen, else a NotReady stub
    public let embedder: any Embedder
    public let gmail: GmailAuth
    public let mailBackend: any MailBackend   // exposed for on-approve execution (Approval-UI plan); GmailMailBackend live, fake in preview
    public let orchestrator: Orchestrator
    public let scheduler: Scheduler
    public let autonomySettings: AutonomySettingsStore   // per-agent dial persistence (Settings UI ↔ Orchestrator); UserDefaults-backed
    public static func live() throws -> AppEnvironment        // production graph
    public static func preview() -> AppEnvironment            // in-memory graph for SwiftUI previews + UI tests
}
```
> Every UI plan injects `AppEnvironment` and reads stores through it — **no screen constructs a store or backend itself.** `preview()` uses `SenaniDatabase.inMemory()`, `InMemoryVectorIndex`, a locally-defined `FakeTextGenerator`, and `InMemoryTokenStore` so previews and UI tests need no Keychain/MLX/network.
>
> ⚠ **Scaffold uses `AppState` today.** The existing `SenaniApp/Sources/SenaniApp/` scaffold currently injects an `@Observable AppState`, not this `AppEnvironment`. The **app-shell plan migrates the scaffold to `AppEnvironment`** (the pinned contract). Until that lands, UI plans should **match whatever injection type the app-shell plan actually shipped** — code to `AppEnvironment` as pinned, and if the worker finds `AppState` still in place, follow the app-shell plan's migration. Do not introduce a third injection type.

---

## 4. Conventions every app plan MUST follow

1. **Composition root only.** Screens and agents receive dependencies; they never call `SenaniDatabase.file(...)`, build a `GmailMailBackend`, or read the Keychain directly.
2. **One safety path.** All writes flow through `ActionRouter.route` + the `MailBackend`/`ApprovalStore`/`AuditLog` seams. Outbound always queues. No agent or screen sends mail directly.
3. **Read through the canonical stores.** Use `MessageStore`, `RuleStore`, `ApprovalStore`, `PersistentAuditLog`, `AnalyticsQueries` — never hand-roll SQL against the frozen schema.
4. **Live vs preview parity.** Every UI plan provides a `.preview()`-backed `#Preview` and a UI test that drives the in-memory graph. No test may require MLX, Gmail network, or a real Keychain.
5. **macOS 14+, Swift 6.2, strict concurrency, Swift Testing** (`import Testing`) — match the engine packages' toolchain exactly.
6. **TDD + bite-sized steps + frequent commits**, per the writing-plans skill. Every code step shows complete code; no placeholders.
7. **Agents are pure.** An `Agent.proposals(...)` returns `[Action]` from `(message, context, tools)` and performs no I/O except the injected `context.retrieve`/generator the tool exposes. This keeps every agent unit-testable with a `FakeTextGenerator`.

---

## 5. Open items for the human (verify at build time)

- **Google OAuth desktop client ID** — required for the live Gmail consent flow (onboarding plan). Calendar scope added by the Booking plan; may require re-consent.
- **MLX / Gemma pins** — confirm `mlx-swift` / `mlx-swift-examples` package versions and that `MLXTextGenerator` loads the chosen `mlx-community/gemma-*-4bit` weights on the target Apple Silicon tier.
- ~~**sqlite-vec** — confirm the SPM product/module + extension init symbol.~~ **CLOSED:** `SqliteVecIndex` has no native dependency (pure-Swift cosine over `vec_items` blobs); nothing to confirm.
- **New `Action` cases** — if a Phase-2+ agent needs an action `SenaniRules.Action` doesn't have (e.g. a calendar hold), that is a **blocking change to a frozen package**: surface it to the human to decide (extend `SenaniRules.Action` and re-freeze, or model it app-side). Do NOT silently fork the action model.
- **Code signing identity, notarization profile, license-key keypair, update feed URL** — required by the Deferred plans; supplied by the human.

---

## 6. Cross-plan reconciliation log (decisions the dependent plans converged on)

Recorded as the ~20 plans were authored against this doc, so executors don't re-litigate:

- **`SenaniEngine` is bootstrapped by the Triage plan** and extended additively by every later agent plan (each task is "skip-if-exists"). It is being implemented concurrently — coordinate via the skip-if-exists branches; do not re-create `Agent`/`AgentContext`/`AgentTools`.
- **`AgentContext` additive fields** (all pre-populated by the Orchestrator, defaulted so older callers compile): `needsReply: Bool`, `documentFields: [String:String]`, `pipeline: (any PipelineStore)?`, `invoices: (any InvoiceStore)?`. Reached for **store reads/writes**, never for building Actions.
- **`PipelineStore`/`Deal`/`DealStage`** — the **pipeline-crm-view plan is authoritative**. Lead-Qualifier, Proposal-Tracker, Follow-up, Outreach all conform to it; the Follow-up draft's divergent shape must reconcile to the pipeline-crm-view contract. `Deal.id == contactEmail` for idempotent upsert.
- **Additive app-tier tables** (`deals`, `invoices`) are created with `CREATE TABLE IF NOT EXISTS` on the shared `SenaniDatabase.queue` — the frozen `SenaniStore` migrator is `internal` and cannot be extended; do NOT edit it.
- **Daily Digest** uses a **separate `DigestScheduler`** (fake-clock), NOT an addition to `SenaniEngine.Scheduler`.
- **`AppEnvironment` additions** beyond §3: `mailBackend: any MailBackend` (exposed for on-approve execution, owned by the Approval-UI plan) and `autonomySettings: AutonomySettingsStore` (UserDefaults-backed, Settings UI ↔ Orchestrator).
- **Scaffold migration:** the live `SenaniApp/` still injects `@Observable AppState`; the **app-shell plan migrates it to `AppEnvironment`**. Until then, UI plans add a minimal shim and defer full wiring to the app-shell plan — no third injection type.
- **`Action` blocking gaps** (each a §5 human decision before the agent can fully act): compose-new-outbound (Outreach), calendar tentative hold (Booking), https one-click unsubscribe (Inbox-Hygiene). Stopgap until resolved: queue an outbound `reply`/`send` draft, always approval-gated.

## §5.1 Outreach Agent Additions

- **NEW `Action` case — compose-new-outbound-message (Outreach agent, BLOCKING — human sign-off required).**
  `SenaniRules.Action` (frozen) has NO "compose a brand-new outbound message to a new recipient"
  case. Its outbound cases are `.reply(body:)` (reply in an existing thread), `.forward(to:body:)`,
  and `.send(body:)` (body only — no first-class recipient/subject). The Outreach agent
  (`2026-05-31-outreach-agent.md`) needs to originate a NEW conversation with a contact who is not
  already in a thread. **Decision deferred to the human:** either (a) extend `SenaniRules.Action`
  with `case compose(to: String, subject: String, body: String)` (`actionClass == .outbound`) and
  re-freeze the package — the clean long-term model; or (b) keep the current STOPGAP: the Outreach
  agent emits `Action.send(body:)` (outbound → always queues) and carries the recipient + subject on
  the synthesized `Proposal.message` (`from = account`, `to = [contact]`, `isFromUser = true`,
  subject/body set), which the Approval-queue UI / `GmailMailBackend` reads at execution time.
- **Outreach is list-driven, not inbound-triggered.** The Outreach agent's `Agent.wakesFor` is
  always `false` and its inbound `proposals` returns `[]`; the work is `OutreachAgent.outreach(to:
  context:tools:)` over a user-supplied target list, plus `dormantTargets(in:now:)` for the
  Scheduler's daily dormant-deal reactivation hook.
- **`Deal` shape divergence (Outreach/Lead-Qualifier vs Follow-up).** The Outreach + Lead-Qualifier
  plans pin the richer `Deal`; the Follow-up plan pins a leaner one. These MUST reconcile to ONE
  definition (owned by `pipeline-crm-view`) before any Phase-3 agent persists.
