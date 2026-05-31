# Approval Queue · Activity Log · Autonomy Settings UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the three Phase-1 cockpit screens that close the trust loop (ARCHITECTURE.md "Agents propose; you approve · Everything is logged · per-agent autonomy dial"):

1. **`ApprovalQueueView`** — lists `AppEnvironment.approvals.pending()` (`[StoredProposal]`) as gold-glass cards. Each card shows the action summary, the target message (sender / subject / snippet), and the proposing agent derived from the proposal's `Trigger`. **Approve** calls `approvals.approve(id:)` THEN executes the proposal via `mailBackend.apply(action, to: message)` — **this plan OWNS the on-approve execution boundary the Reply-Drafter plan deferred** (an outbound `.reply`/`.send`/`.forward` only reaches Gmail when the human approves here). **Reject** calls `approvals.reject(id:)` and does NOT execute. Both refresh the list.
2. **`ActivityLogView`** — a reverse-chronological timeline from `AppEnvironment.audit.records()` (`[AuditEntry]` = `ActionRecord` + `loggedAt`). Each entry shows the action, the message id, the trigger (rule/agent vs chat), and the outcome (executed / prepared / queued).
3. **`SettingsView` autonomy section** — a per-agent `AutonomyDial` (imported from `SenaniDesign`) bound to `.ask`/`.prepare`/`.auto`, persisted via a small **autonomy-settings store** keyed by agent id and read back by the Orchestrator.

All read / approve / reject / execute / persist logic lives in **pure, `@MainActor`-free, testable view models** (`ApprovalQueueViewModel`, `ActivityLogViewModel`, `AutonomySettingsViewModel`) that own no SwiftUI; the views are thin renderers. Every behavior is proven by Swift Testing tests over `AppEnvironment.preview()` (in-memory) with seeded approvals + audit and a **spy `MailBackend`** — approve invokes `approve(id:)` AND `mailBackend.apply`; reject invokes `reject(id:)` and does NOT apply; the timeline orders newest-first and maps every field; an autonomy setting round-trips. **No MLX, no Gmail network, no Keychain.** Every screen ships a `#Preview` over `preview()`.

**Architecture:** A new UI feature folder set inside the existing `SenaniApp` executable package: `SenaniApp/Sources/SenaniApp/UI/Approvals/`, `.../UI/Activity/`, `.../UI/Settings/`, plus one persistence file `SenaniApp/Sources/SenaniApp/AutonomySettingsStore.swift`. Each screen follows the same shape the Inbox Cockpit plan established (and which this plan mirrors exactly):

- A **pure presentation model** (`ApprovalCard`, `ActivityEntry`, `AgentAutonomy`) — fully-derived, `Equatable` value structs the tests assert on directly.
- **Pure free functions** (`ApprovalMapping`, `ActivityMapping`) — map `StoredProposal`/`AuditEntry` into the presentation model (action summary text, proposing-agent label from `Trigger`, outcome label, sort). Dependency-free (only `SenaniRules`/`SenaniStore` types), unit-tested without any store.
- A **`@MainActor @Observable` view model** constructed from the *seams it needs* (closure ports), with a convenience `init(environment:)` that wires the live `AppEnvironment` graph — satisfying reconciliation §4.1 (read/write THROUGH the injected `AppEnvironment`; no screen constructs a store or backend). The ports model the real concurrency shape: `ApprovalStore.pending()/approve()/reject()` are **synchronous throwing struct methods**; `PersistentAuditLog.records()` is a **throwing method on an actor** (needs `await`); `MailBackend.apply` is `async throws`.
- A **thin SwiftUI view** — `@EnvironmentObject var env: AppEnvironment`, builds the view model from `env`, renders cards/rows inside `GlassPanel`s (from `SenaniDesign`), and binds buttons/dials to the view model's async methods.

The **autonomy-settings store** persists per-agent `Autonomy` to **`UserDefaults`** (justification in Cross-package assumptions: it is a tiny, sparse, app-local key→enum map with no relational/query needs and no migration story; adding a GRDB table to the frozen `SenaniStore` schema would be a blocking change to a frozen package — reconciliation §5 — whereas `UserDefaults` is zero-schema, instantly testable with an injected in-memory suite, and is exactly the kind of small app preference it is designed for). The Orchestrator reads it via a `@Sendable (agentId) -> Autonomy` closure the composition root supplies.

**Tech Stack:** Swift 6.2 (strict concurrency), Swift Package Manager (the existing `SenaniApp` executable package; the app-shell plan already raised `swift-tools-version` to `6.0` and added the `SenaniAppTests` target — this plan only adds the `SenaniDesign` dependency line if the inbox plan has not), Swift Testing (`import Testing`, ships with the toolchain). Target platform macOS 14, Apple Silicon. Depends on `SenaniRules` (`Message`, `Action`, `ActionClass`, `Outcome`, `Trigger`, `Proposal`, `ActionRecord`, `Autonomy`, `MailBackend`), `SenaniStore` (`ApprovalStore`, `StoredProposal`, `PersistentAuditLog`, `AuditEntry`), and `SenaniDesign` (`AutonomyDial`, `GlassPanel`, `PrimaryButton`, `Color`/`Font` tokens). No MLX, no Gmail network, no Keychain in this plan or its tests.

**Working directory:** All `swift` commands run from `SenaniApp/` unless stated otherwise. (The package manifest lives at `SenaniApp/Package.swift`; sources at `SenaniApp/Sources/SenaniApp/`; tests at `SenaniApp/Tests/SenaniAppTests/`.)

**Design spec:** `docs/ARCHITECTURE.md` — the trust model spine (agents propose → you approve → connector executes → activity log records; reversible internal actions may auto-run under the per-agent autonomy dial; everything logged). `docs/ROADMAP.md` Phase 1 — "Agent Engine: orchestrator, approval queue, activity log, autonomy dials" and the demoable MVP (mail in → triaged → reply drafted → **you approve → draft in Gmail**). The authoritative app-tier contracts are `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md` §2 (`ApprovalStore` / `PersistentAuditLog` / `MailBackend`), §3 (`AppEnvironment` composition root + `DesignSystem.AutonomyDial`), and §4 (conventions: composition-root-only, live/preview parity, pure view models separate from views).

**Out of scope (separate plans):** the `AppEnvironment` composition root itself (owned by `2026-05-31-app-shell-and-composition-root.md` — we IMPORT it, never construct a store); the `AutonomyDial` / `GlassPanel` / `PrimaryButton` / tokens (owned by `2026-05-31-gold-glass-design-system.md` — we IMPORT them, never redefine); the Inbox Cockpit screen (sibling Phase-1 UI); the Triage / Reply-Drafter agents that *enqueue* proposals (here we only READ + approve/reject/execute them); the Orchestrator/Scheduler internals (`SenaniEngine`); the Assistant ⌘K panel; onboarding/OAuth; the MLX model picker. The non-autonomy parts of `SettingsView` (account, model) are placeholders here — this plan owns only the **autonomy section**.

---

## Cross-package assumptions (state these to the human before coding)

These screens compile only against contracts the upstream plans expose. The plan codes to these EXACT, **source-verified** signatures (read from `Packages/Senani*/Sources`, not just the reconciliation doc). If an upstream differs, adjust the thin adapter (`init(environment:)` or the ports), never the pure mapping logic, and record the deviation in the reconciliation doc in the same commit.

### From `SenaniRules` (frozen — verified from source, do NOT edit)
```swift
public struct Message: Sendable, Equatable, Identifiable {
    public let id: String
    public let from: String          // e.g. "Mark <mark@acme.com>" or "mark@acme.com"
    public let to: [String]
    public let subject: String
    public let body: String
    public let hasAttachment: Bool
    public let listUnsubscribeHeader: String?
    public let labels: [String]
    public let threadId: String
    public let date: Date
    public let isFromUser: Bool
    public var senderDomain: String  // lowercased host after last "@"
}
public enum Action: Sendable, Equatable {
    case label(String); case archive; case markRead; case markUnread; case star; case unstar
    case move(String); case flagNeedsReply; case fileAttachment(folder: String); case parseDoc
    case runAgent(id: String); case draft(body: String); case reply(body: String)
    case forward(to: String, body: String); case send(body: String); case markSpam
    case localWebhook(name: String)
    public var actionClass: ActionClass { get }                 // .reversible | .outbound
}
public enum ActionClass: Sendable, Equatable { case reversible; case outbound }
public enum Outcome: Sendable, Equatable { case executed; case prepared; case queuedForApproval }
public enum Trigger: Sendable, Equatable { case rule(id: String); case chat(turnId: String) }
public struct Proposal: Sendable, Equatable { public let action: Action; public let message: Message; public let trigger: Trigger
    public init(action: Action, message: Message, trigger: Trigger) }
public struct ActionRecord: Sendable, Equatable {
    public let action: Action; public let messageId: String; public let trigger: Trigger; public let outcome: Outcome
    public init(action: Action, messageId: String, trigger: Trigger, outcome: Outcome) }
public protocol MailBackend: Sendable { func apply(_ action: Action, to message: Message) async throws }
public enum Autonomy: String, Sendable, Equatable { case ask; case prepare; case auto }   // REAL cases: ask/prepare/auto
```
> **Trigger → proposing-agent label (OURS to define).** The Orchestrator tags agent-originated actions `Trigger.rule(id: agent.id)` (reconciliation §3 "Trigger for agent-originated actions"), and the chat assistant tags `Trigger.chat(turnId:)`. So the proposing-agent label is: `.rule(let id)` → that `id` (e.g. `"reply-drafter"` → display "Reply Drafter" via a humanizer), `.chat` → "Assistant (chat)". This mapping is pure inbox/approval logic, asserted in `ApprovalMapping` tests.

### From `SenaniStore` (frozen — verified from source, do NOT edit)
```swift
public struct StoredProposal: Sendable, Equatable {
    public let id: String                     // caller-supplied id used to approve/reject
    public let proposal: Proposal             // .action / .message / .trigger
    public init(id: String, proposal: Proposal)
}
public struct ApprovalStore: Sendable {
    public init(database: SenaniDatabase, now: @escaping @Sendable () -> Double)   // now: REQUIRED
    public func enqueue(id: String, _ proposal: Proposal) throws        // SYNCHRONOUS throwing
    public func pending() throws -> [StoredProposal]                    // SYNCHRONOUS throwing; ordered by created_at, id
    public func approve(id: String) throws                              // SYNCHRONOUS throwing; sets status='approved'
    public func reject(id: String) throws                               // SYNCHRONOUS throwing; sets status='rejected'
}
public struct AuditEntry: Sendable, Equatable {
    public let record: ActionRecord           // .action / .messageId / .trigger / .outcome
    public let loggedAt: Double               // unix seconds, from the store's now()
    public init(record: ActionRecord, loggedAt: Double)
}
public actor PersistentAuditLog: SenaniRules.AuditLog {
    public init(database: SenaniDatabase, now: @escaping @Sendable () -> Double)
    public func record(_ record: ActionRecord) async                    // protocol conformance
    public func records() throws -> [AuditEntry]                        // throwing method ON AN ACTOR → call with await; ordered by row id (insertion = chronological)
}
```
> **Concurrency note (load-bearing).** `ApprovalStore.pending()/approve()/reject()` are **synchronous throwing struct methods**. `PersistentAuditLog.records()` is a **throwing method on an `actor`**, so reading it requires `await`. Therefore: the approval view model's `refresh()` can be synchronous-bodied but its **`approve(id:)` is `async`** (it must `await mailBackend.apply(...)`); the activity view model's `refresh()` is **`async`** (it must `await audit.records()`). The ports model exactly this — approval ports are `@Sendable () throws -> ...` / `@Sendable (String) throws -> Void`, the apply port is `@Sendable (Action, Message) async throws -> Void`, the audit port is `@Sendable () async throws -> [AuditEntry]`.
>
> **`approve(id:)` is idempotent on status only.** `ApprovalStore.approve(id:)` flips the row to `'approved'` and `pending()` then excludes it; it does NOT execute the action. Execution is THIS plan's responsibility (the on-approve boundary) — so the view model's `approve` must: (1) `approve(id:)`, (2) `await mailBackend.apply(action, to: message)`, (3) `refresh()`. If `apply` throws, surface the error and still refresh (the row remains approved-but-unexecuted; a retry/error-surface UI is a later concern — record the failure in the VM's `lastError`).

### From `SenaniDesign` (owned by the design-system plan — IMPORT, never redefine)
```swift
public struct AutonomyDial: View { public init(_ binding: Binding<Autonomy>) }    // segmented Suggest/Draft/Auto over .ask/.prepare/.auto
public struct GlassPanel<Content: View>: View {
    public init(@ViewBuilder content: () -> Content)
    public init(style: GlassPanelStyle, @ViewBuilder content: () -> Content) }
public struct PrimaryButton: View { public init(_ title: String, action: @escaping () -> Void) }
public extension Color { static let senaniInk, senaniSurface, senaniAccent, senaniMuted: Color }
public extension Font  { static let senaniTitle, senaniBody, senaniMono: Font }
```
> The package/module is `SenaniDesign` (verified from the design-system plan's `Package.swift`). The reconciliation §3 calls the module "DesignSystem" but the shipped module name is `SenaniDesign`; import that.

### From `SenaniApp` composition root (owned by the app-shell plan — IMPORT, never construct a store)
```swift
@MainActor public final class AppEnvironment: ObservableObject {
    public let approvals: ApprovalStore
    public let audit: PersistentAuditLog
    public let orchestrator: Orchestrator      // SenaniEngine; constructed in live()/preview()
    @Published public var selectedItem: NavigationItem    // .approvals / .activity / .settings are destinations
    public static func live(base: URL?, ...) throws -> AppEnvironment
    public static func preview(now: @escaping @Sendable () -> Date = Date.init) -> AppEnvironment
}
```
> **The composition root has NO `mailBackend` property today.** The app-shell plan constructs a `GmailMailBackend` *inside* `live()`/`preview()` and hands it to the `Orchestrator`, but does not expose it on `AppEnvironment`. **This plan needs the approved-proposal executor**, so Task 6 adds a `public let mailBackend: any MailBackend` property to `AppEnvironment` (a one-line, additive change wiring the already-constructed backend out to the property — it does NOT change the pinned member set's intent, it surfaces the backend the §3 contract already builds). This is recorded as a reconciliation §3 addition in the same commit. In `preview()` the backend is a **spy** so tests observe `apply`; in `live()` it is the real `GmailMailBackend`. If the app-shell plan already exposes `mailBackend`, skip the property addition and just consume it.
>
> **Build-order dependency:** this plan depends on the app-shell plan (`AppEnvironment` + navigation skeleton) and the design-system plan (`SenaniDesign` package + dependency line). Both are reconciliation §1 ABOVE Phase-1 UI. The port-based view models mean **Tasks 2–5 (pure logic + VM tests over in-memory fakes) proceed even before `AppEnvironment` lands**; only the `init(environment:)` adapters (Tasks 3/5/8) and the `#Preview`/preview-graph tests (Tasks 4/5/9) require it. If `AppEnvironment.preview()` is not green yet, coordinate — do NOT stub `AppEnvironment` inside this feature.
>
> **Orchestrator reads autonomy:** the Orchestrator currently takes per-agent autonomy from `agent.autonomy`. To honor the trust model's *user-set* dials, the composition root supplies the Orchestrator an autonomy override closure `@Sendable (String) -> Autonomy?` sourced from `AutonomySettingsStore`. Wiring that into `Orchestrator.init` is a `SenaniEngine` concern (not editable here); **this plan ships the store + the closure and exposes the closure on `AppEnvironment` as `autonomyForAgent`** so the engine plan can consume it. If `Orchestrator.init` cannot yet accept the override, the store + Settings UI still round-trip (Tasks 7–9) and the engine consumes it when ready — record the seam in the reconciliation doc.

---

## File Structure

```
SenaniApp/
  Package.swift                                  # MODIFY (idempotent): ensure SenaniDesign dep + test target + tools 6.0
  Sources/SenaniApp/
    AppEnvironment.swift                         # MODIFY: expose `mailBackend` + `autonomyForAgent` (Task 6); spy backend in preview()
    AutonomySettingsStore.swift                  # CREATE: UserDefaults-backed per-agent Autonomy store (injectable suite) + AgentCatalog
    UI/Approvals/
      ApprovalModels.swift                       # CREATE: ApprovalCard (pure, Equatable) + ApprovalActionKind
      ApprovalMapping.swift                       # CREATE: pure — StoredProposal -> ApprovalCard, action summary, agent label from Trigger
      ApprovalQueueViewModel.swift                # CREATE: @MainActor @Observable; ports + init(environment:); refresh()/approve(id:)/reject(id:)
      ApprovalQueueView.swift                     # CREATE: SwiftUI screen — gold-glass cards + Approve/Reject + #Preview
    UI/Activity/
      ActivityModels.swift                        # CREATE: ActivityEntry (pure, Equatable) + TriggerLabel + OutcomeLabel
      ActivityMapping.swift                       # CREATE: pure — AuditEntry -> ActivityEntry, newest-first sort, field maps
      ActivityLogViewModel.swift                  # CREATE: @MainActor @Observable; audit port + init(environment:); async refresh()
      ActivityLogView.swift                       # CREATE: SwiftUI timeline + #Preview
    UI/Settings/
      AgentAutonomyModels.swift                   # CREATE: AgentAutonomy (pure, Equatable; agentId, displayName, Autonomy)
      AutonomySettingsViewModel.swift             # CREATE: @MainActor @Observable; store ports + init(environment:); rows + binding(for:)
      SettingsView.swift                          # CREATE: SwiftUI Settings screen w/ autonomy section (AutonomyDial per agent) + #Preview
  Tests/SenaniAppTests/
    ApprovalMappingTests.swift                    # CREATE: pure — action summary, agent label, card fields
    ApprovalQueueViewModelTests.swift             # CREATE: VM over fakes + preview() — approve applies, reject does not, refresh
    ActivityMappingTests.swift                    # CREATE: pure — newest-first, trigger/outcome maps
    ActivityLogViewModelTests.swift               # CREATE: VM over preview() seeded audit — order + field mapping
    AutonomySettingsStoreTests.swift              # CREATE: round-trip persist/read, default .ask, in-memory suite
    AutonomySettingsViewModelTests.swift          # CREATE: VM round-trip via binding(for:) over the store
```

Each file has one responsibility; collaborators that change together live together. The `*Mapping` files are dependency-free pure logic; the view models orchestrate ports; the views render. Pure-logic tests never touch a store; view-model tests use hand-rolled in-memory fakes (fast, isolated) AND the real `preview()` graph (parity), exactly as the Inbox Cockpit plan does.

---

### Task 1: Package wiring — SenaniDesign dependency (idempotent)

**Files:**
- Modify: `SenaniApp/Package.swift`

This feature imports `SenaniDesign` (for `AutonomyDial`/`GlassPanel`/`PrimaryButton`/tokens). The app-shell plan already raised tools to `6.0` and added the `SenaniAppTests` target; the inbox-cockpit plan may already have added `SenaniDesign`. This task is idempotent — add only what is missing.

- [ ] **Step 1: Inspect the current manifest**

```
cd SenaniApp && swift package describe --type json
```

Note whether `SenaniDesign` is already a dependency and whether `.testTarget(name: "SenaniAppTests", ...)` exists. (Avoid `cat`; `swift package describe` is the dedicated tool and confirms resolution.)

- [ ] **Step 2: Add the SenaniDesign package dependency + product (if absent)**

Edit `SenaniApp/Package.swift`. In the top-level `dependencies:` array add (if absent):

```swift
        .package(path: "../Packages/SenaniDesign"),
```

In the `SenaniApp` executable target's `dependencies:` add (if absent):

```swift
                "SenaniDesign",
```

If a `SenaniAppTests` target does not yet exist (app-shell not landed), add one mirroring the app-shell manifest (tools `6.0`, `.swiftLanguageMode(.v6)`):

```swift
        .testTarget(
            name: "SenaniAppTests",
            dependencies: ["SenaniApp"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
```

- [ ] **Step 3: Resolve + build to confirm wiring**

```
cd SenaniApp && swift build
```

Expected: builds (the existing app-shell sources compile). If `../Packages/SenaniDesign` fails to *resolve* (not a code error), the design-system plan has not landed — STOP and coordinate (build-order dependency per Cross-package assumptions). Do NOT stub `SenaniDesign`.

- [ ] **Step 4: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: add SenaniDesign dependency for Approval/Activity/Settings UI"
```

Use this commit trailer on EVERY commit in this plan:

```

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

---

### Task 2: Approval presentation model + pure mapping

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/UI/Approvals/ApprovalModels.swift`
- Create: `SenaniApp/Sources/SenaniApp/UI/Approvals/ApprovalMapping.swift`
- Test: `SenaniApp/Tests/SenaniAppTests/ApprovalMappingTests.swift`

The pure seam: map a `StoredProposal` to an `ApprovalCard` (id, action summary, action kind, sender, subject, snippet, proposing-agent label). No SwiftUI, no store — fully unit-testable.

- [ ] **Step 1: Write failing mapping tests**

Create `SenaniApp/Tests/SenaniAppTests/ApprovalMappingTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniApp
import SenaniRules
import SenaniStore

private func sampleMessage(id: String = "m1", from: String = "Mark <mark@acme.com>",
                           subject: String = "Pricing enquiry",
                           body: String = "Hi, what does the Pro tier cost? Thanks, Mark") -> Message {
    Message(id: id, from: from, to: ["me@x.com"], subject: subject, body: body,
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: "t1", date: Date(timeIntervalSince1970: 1_700_000_000), isFromUser: false)
}

@Test func summarizesEachActionKind() {
    #expect(ApprovalMapping.actionSummary(.reply(body: "Sure!")) == "Send reply")
    #expect(ApprovalMapping.actionSummary(.send(body: "Done")) == "Send email")
    #expect(ApprovalMapping.actionSummary(.forward(to: "x@y.com", body: "fyi")) == "Forward to x@y.com")
    #expect(ApprovalMapping.actionSummary(.label("Invoices")) == "Apply label “Invoices”")
    #expect(ApprovalMapping.actionSummary(.archive) == "Archive")
    #expect(ApprovalMapping.actionSummary(.markSpam) == "Mark as spam")
}

@Test func proposingAgentLabelComesFromTrigger() {
    #expect(ApprovalMapping.proposingAgent(.rule(id: "reply-drafter")) == "Reply Drafter")
    #expect(ApprovalMapping.proposingAgent(.rule(id: "triage")) == "Triage")
    #expect(ApprovalMapping.proposingAgent(.rule(id: "custom-agent")) == "Custom Agent")
    #expect(ApprovalMapping.proposingAgent(.chat(turnId: "t-9")) == "Assistant (chat)")
}

@Test func snippetIsTrimmedAndTruncated() {
    let long = String(repeating: "word ", count: 60)
    let snip = ApprovalMapping.snippet(from: long)
    #expect(snip.count <= 140)
    #expect(snip.hasSuffix("…"))
}

@Test func buildsACardFromAStoredProposal() {
    let proposal = Proposal(action: .reply(body: "Our Pro tier is $199/yr."),
                            message: sampleMessage(),
                            trigger: .rule(id: "reply-drafter"))
    let card = ApprovalMapping.card(from: StoredProposal(id: "ap-1", proposal: proposal))
    #expect(card.id == "ap-1")
    #expect(card.actionSummary == "Send reply")
    #expect(card.kind == .outbound)
    #expect(card.sender == "Mark <mark@acme.com>")
    #expect(card.subject == "Pricing enquiry")
    #expect(card.proposingAgent == "Reply Drafter")
    #expect(card.messageId == "m1")
}

@Test func cardsPreservePendingOrder() {
    let p1 = StoredProposal(id: "a", proposal: Proposal(action: .archive, message: sampleMessage(id: "m1"), trigger: .rule(id: "triage")))
    let p2 = StoredProposal(id: "b", proposal: Proposal(action: .reply(body: "hi"), message: sampleMessage(id: "m2"), trigger: .rule(id: "reply-drafter")))
    let cards = ApprovalMapping.cards(from: [p1, p2])
    #expect(cards.map(\.id) == ["a", "b"])   // pending() already orders by created_at,id — mapping must not reorder
}
```

- [ ] **Step 2: Run to fail**

```
cd SenaniApp && swift test --filter ApprovalMappingTests
```

Expected: failure — `ApprovalCard` / `ApprovalMapping` undefined.

- [ ] **Step 3: Implement the model + mapping**

Create `SenaniApp/Sources/SenaniApp/UI/Approvals/ApprovalModels.swift`:

```swift
import SenaniRules

/// The fully-derived presentation row for one pending proposal. Equatable so
/// tests assert on it directly; carries the message so the view model can
/// execute it on approve without re-reading the store.
public struct ApprovalCard: Sendable, Equatable, Identifiable {
    public let id: String                 // StoredProposal.id (used to approve/reject)
    public let actionSummary: String      // human action text, e.g. "Send reply"
    public let kind: ActionClass          // .reversible | .outbound (drives the badge)
    public let sender: String             // raw `from`
    public let subject: String
    public let snippet: String            // trimmed/truncated body preview
    public let proposingAgent: String     // derived from Trigger
    public let messageId: String

    // The full action + message, kept for on-approve execution. Excluded from
    // Equatable identity concerns by virtue of being derived from id/messageId,
    // but included so `apply` needs no store round-trip.
    public let action: Action
    public let message: Message

    public init(id: String, actionSummary: String, kind: ActionClass, sender: String,
                subject: String, snippet: String, proposingAgent: String, messageId: String,
                action: Action, message: Message) {
        self.id = id
        self.actionSummary = actionSummary
        self.kind = kind
        self.sender = sender
        self.subject = subject
        self.snippet = snippet
        self.proposingAgent = proposingAgent
        self.messageId = messageId
        self.action = action
        self.message = message
    }
}
```

Create `SenaniApp/Sources/SenaniApp/UI/Approvals/ApprovalMapping.swift`:

```swift
import SenaniRules
import SenaniStore

/// Pure, dependency-free mapping from store types to the approval presentation
/// model. No SwiftUI, no I/O — the seam the view model and tests share.
public enum ApprovalMapping {

    /// Human-readable one-line summary of an action.
    public static func actionSummary(_ action: Action) -> String {
        switch action {
        case .reply: return "Send reply"
        case .send: return "Send email"
        case .forward(let to, _): return "Forward to \(to)"
        case .draft: return "Save draft"
        case .label(let name): return "Apply label “\(name)”"
        case .move(let folder): return "Move to “\(folder)”"
        case .archive: return "Archive"
        case .markRead: return "Mark as read"
        case .markUnread: return "Mark as unread"
        case .star: return "Star"
        case .unstar: return "Unstar"
        case .markSpam: return "Mark as spam"
        case .flagNeedsReply: return "Flag as needs reply"
        case .fileAttachment(let folder): return "File attachment to “\(folder)”"
        case .parseDoc: return "Parse document"
        case .runAgent(let id): return "Run agent “\(humanize(id))”"
        case .localWebhook(let name): return "Run webhook “\(name)”"
        }
    }

    /// The proposing-agent display label, derived from the proposal's Trigger.
    /// Agent-originated actions are tagged `.rule(id: agent.id)`; chat is `.chat`.
    public static func proposingAgent(_ trigger: Trigger) -> String {
        switch trigger {
        case .rule(let id): return humanize(id)
        case .chat: return "Assistant (chat)"
        }
    }

    /// Trim and truncate a body to a card-sized snippet (never crashes).
    public static func snippet(from body: String, limit: Int = 140) -> String {
        let collapsed = body
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= limit { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: limit - 1)
        return String(collapsed[..<end]) + "…"
    }

    /// Build one card from a stored proposal.
    public static func card(from stored: StoredProposal) -> ApprovalCard {
        let p = stored.proposal
        return ApprovalCard(
            id: stored.id,
            actionSummary: actionSummary(p.action),
            kind: p.action.actionClass,
            sender: p.message.from,
            subject: p.message.subject,
            snippet: snippet(from: p.message.body),
            proposingAgent: proposingAgent(p.trigger),
            messageId: p.message.id,
            action: p.action,
            message: p.message)
    }

    /// Map preserving the store's ordering (pending() already sorts by created_at,id).
    public static func cards(from stored: [StoredProposal]) -> [ApprovalCard] {
        stored.map(card(from:))
    }

    /// "reply-drafter" -> "Reply Drafter"; "triage" -> "Triage".
    private static func humanize(_ id: String) -> String {
        id.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd SenaniApp && swift test --filter ApprovalMappingTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: ApprovalCard model + pure ApprovalMapping (action summary, agent label, snippet)"
```

(Append the standard trailer.)

---

### Task 3: ApprovalQueueViewModel — approve executes, reject does not

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/UI/Approvals/ApprovalQueueViewModel.swift`
- Test: `SenaniApp/Tests/SenaniAppTests/ApprovalQueueViewModelTests.swift`

The `@MainActor @Observable` view model. Ports: a synchronous `pending` reader, synchronous `approve`/`reject` writers, and an async `apply` executor. `approve(id:)` MUST `approve(id:)` THEN `apply(action, to: message)` THEN `refresh()`. `reject(id:)` MUST `reject(id:)` then `refresh()` and MUST NOT call `apply`. A convenience `init(environment:)` wires the live `AppEnvironment` (uses `env.approvals` + `env.mailBackend`, added in Task 6).

- [ ] **Step 1: Write failing view-model tests**

Create `SenaniApp/Tests/SenaniAppTests/ApprovalQueueViewModelTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniApp
import SenaniRules
import SenaniStore

// A spy MailBackend recording every applied (action, messageId).
private final class SpyMailBackend: MailBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _applied: [(Action, String)] = []
    func apply(_ action: Action, to message: Message) async throws {
        lock.lock(); _applied.append((action, message.id)); lock.unlock()
    }
    var applied: [(Action, String)] { lock.lock(); defer { lock.unlock() }; return _applied }
}

private func msg(_ id: String) -> Message {
    Message(id: id, from: "a@b.com", to: ["me@x.com"], subject: "S", body: "B",
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: "t", date: Date(), isFromUser: false)
}

/// Builds a VM over an in-memory ApprovalStore seeded with two proposals.
@MainActor
private func seededVM(backend: SpyMailBackend) throws -> (ApprovalQueueViewModel, ApprovalStore) {
    let db = try SenaniDatabase.inMemory()
    let store = ApprovalStore(database: db, now: { 0 })
    try store.enqueue(id: "ap-reply",
        Proposal(action: .reply(body: "Our Pro tier is $199/yr."), message: msg("m1"), trigger: .rule(id: "reply-drafter")))
    try store.enqueue(id: "ap-label",
        Proposal(action: .label("Invoices"), message: msg("m2"), trigger: .rule(id: "triage")))
    let vm = ApprovalQueueViewModel(
        pending: { try store.pending() },
        approve: { try store.approve(id: $0) },
        reject: { try store.reject(id: $0) },
        apply: { try await backend.apply($0, to: $1) })
    return (vm, store)
}

@MainActor
@Test func refreshLoadsPendingCards() throws {
    let backend = SpyMailBackend()
    let (vm, _) = try seededVM(backend: backend)
    vm.refresh()
    #expect(vm.cards.count == 2)
    #expect(vm.cards.map(\.id) == ["ap-reply", "ap-label"])
    #expect(vm.cards[0].actionSummary == "Send reply")
}

@MainActor
@Test func approveCallsApproveThenAppliesThenRefreshes() async throws {
    let backend = SpyMailBackend()
    let (vm, store) = try seededVM(backend: backend)
    vm.refresh()
    await vm.approve(id: "ap-reply")
    // Executed via the backend.
    #expect(backend.applied.count == 1)
    #expect(backend.applied.first?.1 == "m1")
    if case .reply = backend.applied.first?.0 {} else { Issue.record("expected a reply action") }
    // Approved row no longer pending.
    #expect(try store.pending().map(\.id) == ["ap-label"])
    #expect(vm.cards.map(\.id) == ["ap-label"])
    #expect(vm.lastError == nil)
}

@MainActor
@Test func rejectCallsRejectAndDoesNotApply() async throws {
    let backend = SpyMailBackend()
    let (vm, store) = try seededVM(backend: backend)
    vm.refresh()
    await vm.reject(id: "ap-reply")
    #expect(backend.applied.isEmpty)                       // NEVER executed
    #expect(try store.pending().map(\.id) == ["ap-label"]) // rejected row gone from pending
    #expect(vm.cards.map(\.id) == ["ap-label"])
}

@MainActor
@Test func approvingAReversibleLabelAlsoApplies() async throws {
    let backend = SpyMailBackend()
    let (vm, _) = try seededVM(backend: backend)
    vm.refresh()
    await vm.approve(id: "ap-label")
    #expect(backend.applied.count == 1)
    if case .label("Invoices") = backend.applied.first?.0 {} else { Issue.record("expected label action") }
}

@MainActor
@Test func applyFailureIsCapturedAndListStillRefreshes() async throws {
    struct FailingBackend: MailBackend {
        func apply(_ action: Action, to message: Message) async throws { throw CancellationError() }
    }
    let db = try SenaniDatabase.inMemory()
    let store = ApprovalStore(database: db, now: { 0 })
    try store.enqueue(id: "ap-x", Proposal(action: .reply(body: "hi"), message: msg("m1"), trigger: .rule(id: "reply-drafter")))
    let vm = ApprovalQueueViewModel(
        pending: { try store.pending() },
        approve: { try store.approve(id: $0) },
        reject: { try store.reject(id: $0) },
        apply: { try await FailingBackend().apply($0, to: $1) })
    vm.refresh()
    await vm.approve(id: "ap-x")
    #expect(vm.lastError != nil)                           // surfaced
    #expect(try store.pending().isEmpty)                   // still approved (removed from pending)
    #expect(vm.cards.isEmpty)
}

@MainActor
@Test func initFromPreviewEnvironmentBuilds() {
    let env = AppEnvironment.preview()
    let vm = ApprovalQueueViewModel(environment: env)
    vm.refresh()
    #expect(vm.cards.isEmpty)   // preview seeds nothing here; the preview-graph test seeds explicitly
}
```

- [ ] **Step 2: Run to fail**

```
cd SenaniApp && swift test --filter ApprovalQueueViewModelTests
```

Expected: failure — `ApprovalQueueViewModel` undefined (and `AppEnvironment.mailBackend` not yet present — that lands in Task 6; the `init(environment:)` test will compile once Task 6 is done, so if Task 6 is not yet complete, expect a compile error pointing at `env.mailBackend` — that is the build-order signal. Implement Step 3 first; the `init(environment:)` test goes green after Task 6).

- [ ] **Step 3: Implement the view model**

Create `SenaniApp/Sources/SenaniApp/UI/Approvals/ApprovalQueueViewModel.swift`:

```swift
import Foundation
import Observation
import SenaniRules
import SenaniStore

/// Owns the Approval Queue's read/approve/reject/execute logic. Pure of SwiftUI;
/// constructed from closure ports so it is testable with in-memory fakes OR the
/// live AppEnvironment graph. On approve it executes the proposal through the
/// MailBackend — THIS is the on-approve execution boundary (outbound mail only
/// reaches Gmail when the human approves here).
@MainActor
@Observable
public final class ApprovalQueueViewModel {
    public private(set) var cards: [ApprovalCard] = []
    public private(set) var lastError: String?

    private let pendingPort: @Sendable () throws -> [StoredProposal]
    private let approvePort: @Sendable (String) throws -> Void
    private let rejectPort: @Sendable (String) throws -> Void
    private let applyPort: @Sendable (Action, Message) async throws -> Void

    public init(
        pending: @escaping @Sendable () throws -> [StoredProposal],
        approve: @escaping @Sendable (String) throws -> Void,
        reject: @escaping @Sendable (String) throws -> Void,
        apply: @escaping @Sendable (Action, Message) async throws -> Void
    ) {
        self.pendingPort = pending
        self.approvePort = approve
        self.rejectPort = reject
        self.applyPort = apply
    }

    /// Live wiring: reads/writes THROUGH the injected composition root (reconciliation §4.1).
    public convenience init(environment env: AppEnvironment) {
        let approvals = env.approvals
        let backend = env.mailBackend
        self.init(
            pending: { try approvals.pending() },
            approve: { try approvals.approve(id: $0) },
            reject: { try approvals.reject(id: $0) },
            apply: { try await backend.apply($0, to: $1) })
    }

    /// Reload the pending cards (synchronous store read).
    public func refresh() {
        do {
            cards = ApprovalMapping.cards(from: try pendingPort())
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Approve → mark approved → EXECUTE via the backend → refresh.
    /// If execution fails, capture the error but still refresh (row stays approved).
    public func approve(id: String) async {
        lastError = nil
        guard let card = cards.first(where: { $0.id == id }) else { return }
        do {
            try approvePort(id)
            try await applyPort(card.action, card.message)
        } catch {
            lastError = String(describing: error)
        }
        refresh()
    }

    /// Reject → mark rejected → refresh. NEVER executes.
    public func reject(id: String) async {
        lastError = nil
        do {
            try rejectPort(id)
        } catch {
            lastError = String(describing: error)
        }
        refresh()
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd SenaniApp && swift test --filter ApprovalQueueViewModelTests
```

Expected: the fake-driven tests pass now; `initFromPreviewEnvironmentBuilds` passes once Task 6 exposes `env.mailBackend`. If Task 6 is not yet done, temporarily `// TODO(Task6)`-comment the `init(environment:)` + its test, land Tasks 4 & 6, then re-enable. (Prefer ordering: do Task 6 before re-running the full suite.)

- [ ] **Step 5: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: ApprovalQueueViewModel — approve executes via MailBackend, reject does not"
```

(Append the standard trailer.)

---

### Task 4: ApprovalQueueView — gold-glass cards + #Preview + preview-graph test

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/UI/Approvals/ApprovalQueueView.swift`
- Test: append a preview-graph case to `SenaniApp/Tests/SenaniAppTests/ApprovalQueueViewModelTests.swift`

The thin SwiftUI screen: `@EnvironmentObject var env`, build the VM from `env`, render each `ApprovalCard` inside a `GlassPanel` with Approve/Reject buttons. Plus a parity test that seeds `AppEnvironment.preview().approvals` and proves approve executes through the preview spy backend.

- [ ] **Step 1: Write the failing preview-graph parity test**

Append to `SenaniApp/Tests/SenaniAppTests/ApprovalQueueViewModelTests.swift`:

```swift
@MainActor
@Test func approveExecutesThroughThePreviewSpyBackend() async throws {
    let env = AppEnvironment.preview()
    // Seed a pending outbound proposal directly into the preview ApprovalStore.
    try env.approvals.enqueue(id: "ap-seed",
        Proposal(action: .reply(body: "Thanks for reaching out!"),
                 message: msg("seed-1"), trigger: .rule(id: "reply-drafter")))
    let vm = ApprovalQueueViewModel(environment: env)
    vm.refresh()
    #expect(vm.cards.map(\.id) == ["ap-seed"])
    await vm.approve(id: "ap-seed")
    // The preview spy backend recorded the apply.
    #expect(env.spyBackend.applied.map(\.1) == ["seed-1"])
    #expect(try env.approvals.pending().isEmpty)
    #expect(vm.cards.isEmpty)
}
```

> This depends on `AppEnvironment.preview()` exposing a `spyBackend` accessor over its in-memory `MailBackend` (added in Task 6). If Task 6 is not yet done, this test fails to compile against `env.spyBackend` — that is the build-order signal; land Task 6 first.

- [ ] **Step 2: Run to fail**

```
cd SenaniApp && swift test --filter approveExecutesThroughThePreviewSpyBackend
```

Expected: failure — `ApprovalQueueView` undefined and/or `env.spyBackend` not present (Task 6).

- [ ] **Step 3: Implement the view**

Create `SenaniApp/Sources/SenaniApp/UI/Approvals/ApprovalQueueView.swift`:

```swift
import SwiftUI
import SenaniRules
import SenaniDesign

/// The Approval Queue screen. Lists pending proposals as gold-glass cards;
/// Approve executes through the MailBackend, Reject discards. A thin renderer
/// over ApprovalQueueViewModel — all logic lives there.
struct ApprovalQueueView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var model: ApprovalQueueViewModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Approvals")
                    .font(.senaniTitle).foregroundStyle(Color.senaniInk)

                if let model, model.cards.isEmpty {
                    Text("Nothing waiting. Proposals your agents create will appear here for your approval.")
                        .font(.senaniBody).foregroundStyle(Color.senaniMuted)
                        .padding(.vertical, 24)
                }

                ForEach(model?.cards ?? []) { card in
                    cardView(card)
                }

                if let err = model?.lastError {
                    Text("Couldn’t complete the last action: \(err)")
                        .font(.senaniBody).foregroundStyle(.red)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.senaniSurface)
        .task {
            if model == nil { model = ApprovalQueueViewModel(environment: env) }
            model?.refresh()
        }
    }

    @ViewBuilder
    private func cardView(_ card: ApprovalCard) -> some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(card.actionSummary)
                        .font(.senaniBody.weight(.semibold)).foregroundStyle(Color.senaniInk)
                    Spacer()
                    Text(card.kind == .outbound ? "Outbound" : "Reversible")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.senaniAccent)
                }
                Text(card.subject).font(.senaniBody).foregroundStyle(Color.senaniInk)
                Text(card.sender).font(.senaniBody).foregroundStyle(Color.senaniMuted)
                if !card.snippet.isEmpty {
                    Text(card.snippet).font(.senaniBody).foregroundStyle(Color.senaniMuted).lineLimit(3)
                }
                HStack {
                    Text("Proposed by \(card.proposingAgent)")
                        .font(.system(size: 11)).foregroundStyle(Color.senaniMuted)
                    Spacer()
                    Button("Reject") { Task { await model?.reject(id: card.id) } }
                        .buttonStyle(.plain).foregroundStyle(Color.senaniMuted)
                    PrimaryButton("Approve") { Task { await model?.approve(id: card.id) } }
                }
            }
            .padding(20)
        }
    }
}

#Preview {
    let env = AppEnvironment.preview()
    try? env.approvals.enqueue(id: "preview-ap",
        Proposal(action: .reply(body: "Our Pro tier is $199/yr — happy to set up a call."),
                 message: Message(id: "pm1", from: "Mark <mark@acme.com>", to: ["me@x.com"],
                                  subject: "Pricing enquiry", body: "Hi, what does the Pro tier cost?",
                                  hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
                                  threadId: "t1", date: .now, isFromUser: false),
                 trigger: .rule(id: "reply-drafter")))
    return ApprovalQueueView().environmentObject(env)
}
```

- [ ] **Step 4: Run to pass**

```
cd SenaniApp && swift test --filter ApprovalQueueViewModelTests
```

Expected: all approval tests pass (after Task 6). If running before Task 6, complete Task 6 then re-run.

- [ ] **Step 5: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: ApprovalQueueView gold-glass cards + preview-graph parity test"
```

(Append the standard trailer.)

---

### Task 5: Activity model + pure mapping + ActivityLogViewModel + view

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/UI/Activity/ActivityModels.swift`
- Create: `SenaniApp/Sources/SenaniApp/UI/Activity/ActivityMapping.swift`
- Create: `SenaniApp/Sources/SenaniApp/UI/Activity/ActivityLogViewModel.swift`
- Create: `SenaniApp/Sources/SenaniApp/UI/Activity/ActivityLogView.swift`
- Test: `SenaniApp/Tests/SenaniAppTests/ActivityMappingTests.swift`, `SenaniApp/Tests/SenaniAppTests/ActivityLogViewModelTests.swift`

Reverse-chronological timeline from `audit.records()`. The pure seam maps each `AuditEntry` to an `ActivityEntry` (action summary, message id, trigger label, outcome label, loggedAt) and sorts newest-first. The VM's `refresh()` is `async` (it `await`s the actor's `records()`).

- [ ] **Step 1: Write failing mapping tests**

Create `SenaniApp/Tests/SenaniAppTests/ActivityMappingTests.swift`:

```swift
import Testing
@testable import SenaniApp
import SenaniRules
import SenaniStore

private func entry(_ action: Action, _ msgId: String, _ trigger: Trigger,
                   _ outcome: Outcome, at: Double) -> AuditEntry {
    AuditEntry(record: ActionRecord(action: action, messageId: msgId, trigger: trigger, outcome: outcome),
               loggedAt: at)
}

@Test func mapsOutcomeToLabel() {
    #expect(ActivityMapping.outcomeLabel(.executed) == "Executed")
    #expect(ActivityMapping.outcomeLabel(.prepared) == "Prepared")
    #expect(ActivityMapping.outcomeLabel(.queuedForApproval) == "Queued for approval")
}

@Test func mapsTriggerToLabel() {
    #expect(ActivityMapping.triggerLabel(.rule(id: "reply-drafter")) == "Reply Drafter")
    #expect(ActivityMapping.triggerLabel(.chat(turnId: "t1")) == "Assistant (chat)")
}

@Test func mapsAuditEntryToActivityEntry() {
    let e = entry(.label("Invoices"), "m1", .rule(id: "triage"), .executed, at: 100)
    let a = ActivityMapping.activity(from: e)
    #expect(a.actionSummary == "Apply label “Invoices”")
    #expect(a.messageId == "m1")
    #expect(a.triggerLabel == "Triage")
    #expect(a.outcomeLabel == "Executed")
    #expect(a.loggedAt == 100)
}

@Test func timelineIsNewestFirst() {
    let entries = [
        entry(.archive, "m1", .rule(id: "triage"), .executed, at: 100),
        entry(.reply(body: "hi"), "m2", .rule(id: "reply-drafter"), .queuedForApproval, at: 300),
        entry(.markRead, "m3", .rule(id: "triage"), .executed, at: 200),
    ]
    let timeline = ActivityMapping.timeline(from: entries)
    #expect(timeline.map(\.loggedAt) == [300, 200, 100])  // newest first
    #expect(timeline.first?.messageId == "m2")
}
```

- [ ] **Step 2: Run to fail**

```
cd SenaniApp && swift test --filter ActivityMappingTests
```

Expected: failure — `ActivityEntry` / `ActivityMapping` undefined.

- [ ] **Step 3: Implement model + mapping**

Create `SenaniApp/Sources/SenaniApp/UI/Activity/ActivityModels.swift`:

```swift
/// One fully-derived row of the activity timeline. Equatable; `id` is synthetic
/// (messageId + loggedAt) since AuditEntry has no stable identity of its own.
public struct ActivityEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let actionSummary: String
    public let messageId: String
    public let triggerLabel: String
    public let outcomeLabel: String
    public let loggedAt: Double

    public init(actionSummary: String, messageId: String, triggerLabel: String,
                outcomeLabel: String, loggedAt: Double) {
        self.id = "\(messageId)#\(loggedAt)"
        self.actionSummary = actionSummary
        self.messageId = messageId
        self.triggerLabel = triggerLabel
        self.outcomeLabel = outcomeLabel
        self.loggedAt = loggedAt
    }
}
```

Create `SenaniApp/Sources/SenaniApp/UI/Activity/ActivityMapping.swift`:

```swift
import SenaniRules
import SenaniStore

/// Pure, dependency-free mapping from audit entries to the activity timeline.
/// Reuses ApprovalMapping for the shared action-summary + agent-label vocabulary
/// so the queue and the log describe actions identically.
public enum ActivityMapping {

    public static func outcomeLabel(_ outcome: Outcome) -> String {
        switch outcome {
        case .executed: return "Executed"
        case .prepared: return "Prepared"
        case .queuedForApproval: return "Queued for approval"
        }
    }

    public static func triggerLabel(_ trigger: Trigger) -> String {
        ApprovalMapping.proposingAgent(trigger)
    }

    public static func activity(from entry: AuditEntry) -> ActivityEntry {
        let r = entry.record
        return ActivityEntry(
            actionSummary: ApprovalMapping.actionSummary(r.action),
            messageId: r.messageId,
            triggerLabel: triggerLabel(r.trigger),
            outcomeLabel: outcomeLabel(r.outcome),
            loggedAt: entry.loggedAt)
    }

    /// Newest-first timeline. `records()` returns chronological (insertion) order;
    /// we sort descending by loggedAt (stable for equal timestamps via reversal of
    /// the already-chronological input).
    public static func timeline(from entries: [AuditEntry]) -> [ActivityEntry] {
        entries
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.loggedAt != rhs.element.loggedAt {
                    return lhs.element.loggedAt > rhs.element.loggedAt
                }
                return lhs.offset > rhs.offset   // later insertion first when timestamps tie
            }
            .map { activity(from: $0.element) }
    }
}
```

- [ ] **Step 4: Run mapping tests to pass**

```
cd SenaniApp && swift test --filter ActivityMappingTests
```

Expected: all pass.

- [ ] **Step 5: Write failing view-model tests**

Create `SenaniApp/Tests/SenaniAppTests/ActivityLogViewModelTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniApp
import SenaniRules
import SenaniStore

private func msg(_ id: String) -> Message {
    Message(id: id, from: "a@b.com", to: ["me@x.com"], subject: "S", body: "B",
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: "t", date: Date(), isFromUser: false)
}

@MainActor
@Test func refreshLoadsNewestFirstFromPreviewAudit() async throws {
    let env = AppEnvironment.preview()
    // PersistentAuditLog uses an injected now(); preview() should advance it, but
    // to control ordering deterministically we record three entries and rely on
    // insertion order for ties — assert newest-first by the store's logged_at.
    await env.audit.record(ActionRecord(action: .archive, messageId: "m1", trigger: .rule(id: "triage"), outcome: .executed))
    await env.audit.record(ActionRecord(action: .reply(body: "hi"), messageId: "m2", trigger: .rule(id: "reply-drafter"), outcome: .queuedForApproval))
    await env.audit.record(ActionRecord(action: .markRead, messageId: "m3", trigger: .chat(turnId: "c1"), outcome: .executed))

    let vm = ActivityLogViewModel(environment: env)
    await vm.refresh()
    #expect(vm.entries.count == 3)
    // Newest first: m3 was recorded last.
    #expect(vm.entries.first?.messageId == "m3")
    #expect(vm.entries.first?.triggerLabel == "Assistant (chat)")
    #expect(vm.entries.first?.outcomeLabel == "Executed")
    #expect(vm.entries.map(\.messageId) == ["m3", "m2", "m1"])
    #expect(vm.entries[1].actionSummary == "Send reply")
}

@MainActor
@Test func refreshOverFakePortMapsAndSorts() async {
    let entries = [
        AuditEntry(record: ActionRecord(action: .archive, messageId: "a", trigger: .rule(id: "triage"), outcome: .executed), loggedAt: 10),
        AuditEntry(record: ActionRecord(action: .send(body: "x"), messageId: "b", trigger: .chat(turnId: "t"), outcome: .queuedForApproval), loggedAt: 30),
    ]
    let vm = ActivityLogViewModel(records: { entries })
    await vm.refresh()
    #expect(vm.entries.map(\.messageId) == ["b", "a"])
    #expect(vm.entries.first?.outcomeLabel == "Queued for approval")
}
```

> The preview `now()` defaults to `Date.init`, so three sequential `record` calls get monotonically increasing `loggedAt`; if two ties occur, the insertion-order tiebreak keeps m3 first. The assertion `["m3","m2","m1"]` is the load-bearing newest-first proof.

- [ ] **Step 6: Run to fail**

```
cd SenaniApp && swift test --filter ActivityLogViewModelTests
```

Expected: failure — `ActivityLogViewModel` undefined.

- [ ] **Step 7: Implement the view model + view**

Create `SenaniApp/Sources/SenaniApp/UI/Activity/ActivityLogViewModel.swift`:

```swift
import Observation
import SenaniRules
import SenaniStore

/// Owns the Activity Log's read logic. Pure of SwiftUI; the audit port is async
/// because PersistentAuditLog.records() is a throwing method on an actor.
@MainActor
@Observable
public final class ActivityLogViewModel {
    public private(set) var entries: [ActivityEntry] = []
    public private(set) var lastError: String?

    private let recordsPort: @Sendable () async throws -> [AuditEntry]

    public init(records: @escaping @Sendable () async throws -> [AuditEntry]) {
        self.recordsPort = records
    }

    /// Live wiring: reads THROUGH the injected composition root's audit log.
    public convenience init(environment env: AppEnvironment) {
        let audit = env.audit
        self.init(records: { try await audit.records() })
    }

    public func refresh() async {
        do {
            entries = ActivityMapping.timeline(from: try await recordsPort())
        } catch {
            lastError = String(describing: error)
        }
    }
}
```

Create `SenaniApp/Sources/SenaniApp/UI/Activity/ActivityLogView.swift`:

```swift
import SwiftUI
import Foundation
import SenaniDesign

/// The Activity Log screen: a reverse-chronological timeline of every action the
/// engine took or queued. A thin renderer over ActivityLogViewModel.
struct ActivityLogView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var model: ActivityLogViewModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Activity")
                    .font(.senaniTitle).foregroundStyle(Color.senaniInk)

                if let model, model.entries.isEmpty {
                    Text("No activity yet. Every action your agents take will be logged here.")
                        .font(.senaniBody).foregroundStyle(Color.senaniMuted).padding(.vertical, 24)
                }

                ForEach(model?.entries ?? []) { entry in
                    GlassPanel(style: .compact) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.actionSummary)
                                    .font(.senaniBody.weight(.semibold)).foregroundStyle(Color.senaniInk)
                                Spacer()
                                Text(entry.outcomeLabel)
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.senaniAccent)
                            }
                            Text("\(entry.triggerLabel) · message \(entry.messageId) · \(timestamp(entry.loggedAt))")
                                .font(.system(size: 11)).foregroundStyle(Color.senaniMuted)
                        }
                        .padding(14)
                    }
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.senaniSurface)
        .task {
            if model == nil { model = ActivityLogViewModel(environment: env) }
            await model?.refresh()
        }
    }

    private func timestamp(_ seconds: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: seconds))
    }
}

#Preview {
    let env = AppEnvironment.preview()
    Task {
        await env.audit.record(.init(action: .reply(body: "Sounds good!"), messageId: "pm1",
                                     trigger: .rule(id: "reply-drafter"), outcome: .queuedForApproval))
        await env.audit.record(.init(action: .label("Lead"), messageId: "pm2",
                                     trigger: .rule(id: "triage"), outcome: .executed))
    }
    return ActivityLogView().environmentObject(env)
}
```

- [ ] **Step 8: Run to pass**

```
cd SenaniApp && swift test --filter ActivityLogViewModelTests
```

Expected: all pass.

- [ ] **Step 9: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: ActivityLog model + mapping + view model (newest-first) + timeline view"
```

(Append the standard trailer.)

---

### Task 6: Expose mailBackend + autonomyForAgent on AppEnvironment (preview uses a spy)

**Files:**
- Modify: `SenaniApp/Sources/SenaniApp/AppEnvironment.swift`
- Test: covered by `ApprovalQueueViewModelTests` (`initFromPreviewEnvironmentBuilds`, `approveExecutesThroughThePreviewSpyBackend`)

The Approval Queue needs the approved-proposal executor, and the Settings autonomy section needs to surface a per-agent autonomy closure to the Orchestrator. Add two additive properties to the composition root: `mailBackend` (the already-constructed backend) and `autonomyForAgent`. In `preview()` the backend is an app-local spy so tests observe `apply`; expose it via `spyBackend` for assertions.

> This is an **additive** change to the §3-pinned `AppEnvironment`. Record it in the reconciliation doc in the same commit (the §3 member list gains `mailBackend: any MailBackend` and `autonomyForAgent: @Sendable (String) -> Autonomy`; `live()` wires the real `GmailMailBackend` + the `AutonomySettingsStore`-backed closure, `preview()` wires the spy + an in-memory store). If the app-shell plan already exposes `mailBackend`, only add `autonomyForAgent` + the preview `spyBackend`.

- [ ] **Step 1: Confirm the tests that exercise this already fail**

```
cd SenaniApp && swift test --filter approveExecutesThroughThePreviewSpyBackend
```

Expected: failure — `env.mailBackend` / `env.spyBackend` undefined.

- [ ] **Step 2: Add a spy backend type (preview only)**

Add to `SenaniApp/Sources/SenaniApp/AppEnvironment.swift` (top level, near the other stubs/fakes), an app-local spy:

```swift
import SenaniRules

/// Records applied actions so preview-graph UI tests can assert execution
/// happened without a real Gmail backend. Used only by AppEnvironment.preview().
public final class SpyMailBackend: MailBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _applied: [(Action, Message)] = []
    public init() {}
    public func apply(_ action: Action, to message: Message) async throws {
        lock.lock(); _applied.append((action, message)); lock.unlock()
    }
    public var applied: [(action: Action, message: Message)] {
        lock.lock(); defer { lock.unlock() }
        return _applied.map { (action: $0.0, message: $0.1) }
    }
}
```

(Ensure `import Foundation` is present for `NSLock`.)

- [ ] **Step 3: Add the properties to AppEnvironment**

In `AppEnvironment`, add stored properties alongside the pinned members:

```swift
    public let mailBackend: any MailBackend
    public let autonomyForAgent: @Sendable (String) -> Autonomy
    /// Non-nil only in preview(): the in-memory spy backing `mailBackend`, for test assertions.
    public let spyBackend: SpyMailBackend
```

Thread them through `private init(...)` (add the three parameters and assignments).

In `live()`: after constructing `mailBackend = GmailMailBackend(...)`, build the autonomy closure from the live `AutonomySettingsStore` (Task 7) and pass a throwaway `SpyMailBackend()` for `spyBackend` (unused live):

```swift
        let settings = AutonomySettingsStore.live()
        let autonomyForAgent: @Sendable (String) -> Autonomy = { settings.autonomy(forAgent: $0) }
        let spy = SpyMailBackend()   // unused in live; present to keep the property non-optional
```

…and pass `mailBackend: mailBackend, autonomyForAgent: autonomyForAgent, spyBackend: spy` into the initializer. The `Orchestrator` continues to receive `mailBackend` exactly as before — this only also surfaces it on the property.

In `preview()`: replace the `GmailMailBackend` handed to the Orchestrator with the spy so both the Orchestrator AND the property observe it:

```swift
        let spy = SpyMailBackend()
        let mailBackend: any MailBackend = spy
        let settings = AutonomySettingsStore.inMemory()
        let autonomyForAgent: @Sendable (String) -> Autonomy = { settings.autonomy(forAgent: $0) }
```

…use `mailBackend` where `preview()` previously built `GmailMailBackend`, and pass `mailBackend: mailBackend, autonomyForAgent: autonomyForAgent, spyBackend: spy` into the initializer.

> `AutonomySettingsStore.live()/inMemory()` are defined in Task 7. If executing Task 6 before Task 7, temporarily inline `let autonomyForAgent: @Sendable (String) -> Autonomy = { _ in .ask }` and a `// TODO(Task7)` and wire the store in Task 7. Prefer ordering Task 7 first.

- [ ] **Step 4: Run to pass**

```
cd SenaniApp && swift test --filter ApprovalQueueViewModelTests
```

Expected: `initFromPreviewEnvironmentBuilds` and `approveExecutesThroughThePreviewSpyBackend` now pass.

- [ ] **Step 5: Update the reconciliation doc + commit**

Edit `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md` §3 `AppEnvironment` to add `mailBackend` + `autonomyForAgent` (note: `spyBackend` is preview-only test scaffolding, not part of the public contract — mention it as such).

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: expose mailBackend + autonomyForAgent on AppEnvironment (preview spy backend)"
```

(Append the standard trailer.)

---

### Task 7: AutonomySettingsStore — UserDefaults-backed per-agent Autonomy

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/AutonomySettingsStore.swift`
- Test: `SenaniApp/Tests/SenaniAppTests/AutonomySettingsStoreTests.swift`

A tiny persistence layer keyed by agent id. **UserDefaults justification:** the data is a sparse `agentId → Autonomy` map (≤ ~10 keys), app-local, no relational/query/migration needs; adding a table to the frozen `SenaniStore` schema would be a blocking change to a frozen package (reconciliation §5). `UserDefaults` is zero-schema, instantly testable with an injected suite, and the right tool for a small app preference. Default for an unset agent is `.ask` (the trust model's safe default — "new rules default to `.ask`").

- [ ] **Step 1: Write failing round-trip tests**

Create `SenaniApp/Tests/SenaniAppTests/AutonomySettingsStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniApp
import SenaniRules

private func freshSuite() -> UserDefaults {
    let name = "senani.autonomy.test.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@Test func unsetAgentDefaultsToAsk() {
    let store = AutonomySettingsStore(defaults: freshSuite())
    #expect(store.autonomy(forAgent: "reply-drafter") == .ask)
}

@Test func setThenGetRoundTrips() {
    let d = freshSuite()
    let store = AutonomySettingsStore(defaults: d)
    store.setAutonomy(.auto, forAgent: "triage")
    store.setAutonomy(.prepare, forAgent: "reply-drafter")
    #expect(store.autonomy(forAgent: "triage") == .auto)
    #expect(store.autonomy(forAgent: "reply-drafter") == .prepare)
    // Persists across a fresh store over the SAME suite.
    let reopened = AutonomySettingsStore(defaults: d)
    #expect(reopened.autonomy(forAgent: "triage") == .auto)
}

@Test func corruptOrUnknownRawValueFallsBackToAsk() {
    let d = freshSuite()
    d.set("nonsense", forKey: "senani.autonomy.triage")
    let store = AutonomySettingsStore(defaults: d)
    #expect(store.autonomy(forAgent: "triage") == .ask)
}

@Test func inMemoryFactoryIsIsolated() {
    let a = AutonomySettingsStore.inMemory()
    let b = AutonomySettingsStore.inMemory()
    a.setAutonomy(.auto, forAgent: "triage")
    #expect(b.autonomy(forAgent: "triage") == .ask)   // separate suites
}
```

- [ ] **Step 2: Run to fail**

```
cd SenaniApp && swift test --filter AutonomySettingsStoreTests
```

Expected: failure — `AutonomySettingsStore` undefined.

- [ ] **Step 3: Implement the store**

Create `SenaniApp/Sources/SenaniApp/AutonomySettingsStore.swift`:

```swift
import Foundation
import SenaniRules

/// Persists each agent's user-chosen Autonomy dial. Backed by UserDefaults: a
/// sparse app-local agentId→enum map with no relational/migration needs, so it
/// stays out of the frozen SenaniStore schema (reconciliation §5). Unset agents
/// default to `.ask` — the trust model's safe default.
public struct AutonomySettingsStore: Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Production store over the standard suite.
    public static func live() -> AutonomySettingsStore {
        AutonomySettingsStore(defaults: .standard)
    }

    /// Isolated in-memory store for previews/tests.
    public static func inMemory() -> AutonomySettingsStore {
        let name = "senani.autonomy.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name) ?? .standard
        d.removePersistentDomain(forName: name)
        return AutonomySettingsStore(defaults: d)
    }

    private func key(_ agentId: String) -> String { "senani.autonomy.\(agentId)" }

    /// The agent's chosen Autonomy, or `.ask` if unset/corrupt.
    public func autonomy(forAgent agentId: String) -> Autonomy {
        guard let raw = defaults.string(forKey: key(agentId)),
              let value = Autonomy(rawValue: raw) else { return .ask }
        return value
    }

    public func setAutonomy(_ autonomy: Autonomy, forAgent agentId: String) {
        defaults.set(autonomy.rawValue, forKey: key(agentId))
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd SenaniApp && swift test --filter AutonomySettingsStoreTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: AutonomySettingsStore (UserDefaults, per-agent Autonomy, .ask default)"
```

(Append the standard trailer.)

---

### Task 8: AutonomySettingsViewModel — per-agent dial round-trips through the store

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/UI/Settings/AgentAutonomyModels.swift`
- Create: `SenaniApp/Sources/SenaniApp/UI/Settings/AutonomySettingsViewModel.swift`
- Test: `SenaniApp/Tests/SenaniAppTests/AutonomySettingsViewModelTests.swift`

The Settings autonomy section lists the Phase-1 agents (Triage, Reply Drafter) with a dial each. The VM exposes a `Binding<Autonomy>` per agent that reads/writes the store; the test drives the binding and asserts the round-trip. A small `AgentCatalog` (in `AutonomySettingsStore.swift` or here) names the known agents.

- [ ] **Step 1: Write failing view-model tests**

Create `SenaniApp/Tests/SenaniAppTests/AutonomySettingsViewModelTests.swift`:

```swift
import Testing
import SwiftUI
@testable import SenaniApp
import SenaniRules

@MainActor
@Test func listsKnownAgentsWithCurrentAutonomy() {
    let store = AutonomySettingsStore.inMemory()
    store.setAutonomy(.auto, forAgent: "triage")
    let vm = AutonomySettingsViewModel(store: store)
    vm.refresh()
    let triage = vm.rows.first { $0.agentId == "triage" }
    #expect(triage != nil)
    #expect(triage?.displayName == "Triage")
    #expect(triage?.autonomy == .auto)
    #expect(vm.rows.contains { $0.agentId == "reply-drafter" })
}

@MainActor
@Test func bindingWritesThroughToTheStoreAndRefreshes() {
    let store = AutonomySettingsStore.inMemory()
    let vm = AutonomySettingsViewModel(store: store)
    vm.refresh()
    let binding = vm.binding(forAgent: "reply-drafter")
    #expect(binding.wrappedValue == .ask)        // default
    binding.wrappedValue = .prepare
    #expect(store.autonomy(forAgent: "reply-drafter") == .prepare)   // persisted
    #expect(vm.rows.first { $0.agentId == "reply-drafter" }?.autonomy == .prepare)  // VM refreshed
}

@MainActor
@Test func initFromPreviewEnvironmentBuilds() {
    let env = AppEnvironment.preview()
    let vm = AutonomySettingsViewModel(environment: env)
    vm.refresh()
    #expect(vm.rows.isEmpty == false)
}
```

- [ ] **Step 2: Run to fail**

```
cd SenaniApp && swift test --filter AutonomySettingsViewModelTests
```

Expected: failure — `AutonomySettingsViewModel` / `AgentAutonomy` / `AgentCatalog` undefined. (`init(environment:)` needs `env` to expose the store — see note below.)

- [ ] **Step 3: Implement the catalog, model, and view model**

Add an `AgentCatalog` to `SenaniApp/Sources/SenaniApp/AutonomySettingsStore.swift` (it names the agents the Settings UI lists; Phase 1 = Triage + Reply Drafter, extendable as agents land):

```swift
/// The agents the Settings autonomy section lists. Phase 1 ships Triage + Reply
/// Drafter; later agent plans append their ids here.
public enum AgentCatalog {
    public static let phase1: [(id: String, displayName: String)] = [
        ("triage", "Triage"),
        ("reply-drafter", "Reply Drafter"),
    ]
}
```

Create `SenaniApp/Sources/SenaniApp/UI/Settings/AgentAutonomyModels.swift`:

```swift
import SenaniRules

/// One agent's autonomy row in Settings. Equatable for direct test assertions.
public struct AgentAutonomy: Sendable, Equatable, Identifiable {
    public let agentId: String
    public let displayName: String
    public let autonomy: Autonomy
    public var id: String { agentId }

    public init(agentId: String, displayName: String, autonomy: Autonomy) {
        self.agentId = agentId
        self.displayName = displayName
        self.autonomy = autonomy
    }
}
```

Create `SenaniApp/Sources/SenaniApp/UI/Settings/AutonomySettingsViewModel.swift`:

```swift
import SwiftUI
import Observation
import SenaniRules

/// Owns the Settings autonomy section. Reads/writes per-agent Autonomy through
/// the AutonomySettingsStore and exposes a Binding<Autonomy> per agent that the
/// AutonomyDial drives. Pure of any store construction — wired from the store.
@MainActor
@Observable
public final class AutonomySettingsViewModel {
    public private(set) var rows: [AgentAutonomy] = []

    private let store: AutonomySettingsStore

    public init(store: AutonomySettingsStore) {
        self.store = store
    }

    /// Live wiring: uses the composition root's autonomy store via the
    /// `autonomyForAgent` closure's backing store. AppEnvironment exposes the
    /// store directly for the Settings screen (Task 6 wires `autonomySettings`).
    public convenience init(environment env: AppEnvironment) {
        self.init(store: env.autonomySettings)
    }

    public func refresh() {
        rows = AgentCatalog.phase1.map { agent in
            AgentAutonomy(agentId: agent.id, displayName: agent.displayName,
                          autonomy: store.autonomy(forAgent: agent.id))
        }
    }

    /// A binding the AutonomyDial consumes; writes persist immediately and refresh the rows.
    public func binding(forAgent agentId: String) -> Binding<Autonomy> {
        Binding<Autonomy>(
            get: { [store] in store.autonomy(forAgent: agentId) },
            set: { [weak self] newValue in
                guard let self else { return }
                self.store.setAutonomy(newValue, forAgent: agentId)
                self.refresh()
            })
    }
}
```

> **`env.autonomySettings`:** Task 6 exposes `autonomyForAgent` as a closure for the engine. The Settings VM also needs the *store itself* to write. Add one more property to `AppEnvironment` in Task 6 (or here, as a tiny follow-up): `public let autonomySettings: AutonomySettingsStore` (live = `.live()`, preview = the same `.inMemory()` instance whose closure is `autonomyForAgent`). Wire `autonomyForAgent` from THAT same store instance so the dial and the engine see one source of truth. Adjust Task 6's `settings` local to be stored on the env as `autonomySettings` and build `autonomyForAgent` from it.

- [ ] **Step 4: Run to pass**

```
cd SenaniApp && swift test --filter AutonomySettingsViewModelTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: AutonomySettingsViewModel — per-agent dial round-trips through the store"
```

(Append the standard trailer.)

---

### Task 9: SettingsView autonomy section + wire all three screens into RootScene destinations

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/UI/Settings/SettingsView.swift`
- Modify: `SenaniApp/Sources/SenaniApp/UI/RootScene.swift` (swap the three placeholders for the real screens)
- Test: covered by existing VM tests + a RootScene smoke assertion in `RootSceneSmokeTests.swift`

The Settings screen renders an `AutonomyDial` per agent row. Then replace the app-shell placeholders (`ApprovalsPlaceholder`/`ActivityPlaceholder`/`SettingsPlaceholder`) in `RootScene` with `ApprovalQueueView`/`ActivityLogView`/`SettingsView`.

- [ ] **Step 1: Write a failing RootScene smoke assertion**

Append to `SenaniApp/Tests/SenaniAppTests/RootSceneSmokeTests.swift`:

```swift
@MainActor
@Test func rootSceneRendersRealApprovalActivitySettingsDestinations() {
    let env = AppEnvironment.preview()
    for item in [NavigationItem.approvals, .activity, .settings] {
        env.selectedItem = item
        let root = RootScene().environmentObject(env)
        _ = root.body            // forcing the body with each real destination must not crash
    }
    #expect(env.selectedItem == .settings)
}
```

- [ ] **Step 2: Run to fail**

```
cd SenaniApp && swift test --filter rootSceneRendersRealApprovalActivitySettingsDestinations
```

Expected: failure — `SettingsView` undefined (and `RootScene` still routes to placeholders).

- [ ] **Step 3: Implement `SettingsView`**

Create `SenaniApp/Sources/SenaniApp/UI/Settings/SettingsView.swift`:

```swift
import SwiftUI
import SenaniRules
import SenaniDesign

/// Settings screen. This plan owns the AUTONOMY section (a dial per agent);
/// account/model sections are placeholders owned by onboarding/MLX-picker plans.
struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var model: AutonomySettingsViewModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings")
                    .font(.senaniTitle).foregroundStyle(Color.senaniInk)

                GlassPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Agent autonomy")
                            .font(.senaniBody.weight(.semibold)).foregroundStyle(Color.senaniInk)
                        Text("Suggest holds everything for approval · Draft prepares reversible actions · Auto runs them. Outbound mail always waits for you.")
                            .font(.system(size: 12)).foregroundStyle(Color.senaniMuted)

                        ForEach(model?.rows ?? []) { row in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(row.displayName).font(.senaniBody).foregroundStyle(Color.senaniInk)
                                if let model {
                                    AutonomyDial(model.binding(forAgent: row.agentId))
                                }
                            }
                        }
                    }
                    .padding(20)
                }

                GlassPanel(style: .compact) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Account & model").font(.senaniBody.weight(.semibold)).foregroundStyle(Color.senaniInk)
                        Text("Connect Gmail and choose a model — configured in onboarding.")
                            .font(.system(size: 12)).foregroundStyle(Color.senaniMuted)
                    }
                    .padding(20)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.senaniSurface)
        .task {
            if model == nil { model = AutonomySettingsViewModel(environment: env) }
            model?.refresh()
        }
    }
}

#Preview {
    SettingsView().environmentObject(AppEnvironment.preview())
}
```

- [ ] **Step 4: Swap the placeholders in RootScene**

In `SenaniApp/Sources/SenaniApp/UI/RootScene.swift`, update the `destination(for:)` switch:

```swift
        case .approvals: ApprovalQueueView()
        case .activity: ActivityLogView()
        case .settings: SettingsView()
```

(Leave `.inbox` as-is — the Inbox Cockpit plan owns it. If that plan has landed it routes to `InboxCockpitView`; otherwise it stays `InboxPlaceholder`.) The now-unused `ApprovalsPlaceholder`/`ActivityPlaceholder`/`SettingsPlaceholder` may be deleted from `Placeholders.swift` if nothing else references them; verify with a `Grep` for each name before removing.

- [ ] **Step 5: Run to pass**

```
cd SenaniApp && swift test --filter rootSceneRendersRealApprovalActivitySettingsDestinations
```

Expected: pass.

- [ ] **Step 6: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: SettingsView autonomy section + route Approvals/Activity/Settings to real screens"
```

(Append the standard trailer.)

---

### Task 10: Full suite green + headless build + final commit

**Files:** none (verification task)

- [ ] **Step 1: Run the ENTIRE test suite**

```
cd SenaniApp && swift test
```

Expected: ALL tests pass across `ApprovalMappingTests`, `ApprovalQueueViewModelTests`, `ActivityMappingTests`, `ActivityLogViewModelTests`, `AutonomySettingsStoreTests`, `AutonomySettingsViewModelTests`, `RootSceneSmokeTests`, plus all pre-existing app-shell/inbox suites (no regressions).

- [ ] **Step 2: Headless build of the app target**

```
cd SenaniApp && swift build --product SenaniApp
```

Expected: builds with no errors and no strict-concurrency warnings. Resolve any `Sendable`/actor-isolation warnings (the view models are `@MainActor`; the ports are `@Sendable`; the spy uses `NSLock` + `@unchecked Sendable`).

- [ ] **Step 3: Final commit (if anything was adjusted)**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: Approval/Activity/Settings UI — full suite green + headless build"
```

(Append the standard trailer. Skip if Step 1/2 required no changes.)

---

## Self-Review

Run this checklist before declaring the plan complete.

**Goal requirement → task mapping:**

- **`ApprovalQueueView` lists `approvals.pending()` (StoredProposal) as gold-glass cards** (action summary, target message, proposing agent from Trigger) → Task 2 (`ApprovalCard` + `ApprovalMapping`: action summary, agent label from `Trigger`, snippet), Task 4 (`GlassPanel` cards). ✅
- **Approve → `approvals.approve(id:)` THEN `mailBackend.apply(action, to: message)`** (the on-approve execution boundary the Reply-Drafter plan deferred) → Task 3 `approve(id:)` does approve→apply→refresh; tests `approveCallsApproveThenAppliesThenRefreshes`, `approvingAReversibleLabelAlsoApplies`, `approveExecutesThroughThePreviewSpyBackend`. ✅
- **Reject → `approvals.reject(id:)` (NO execution); both refresh** → Task 3 `reject(id:)` does reject→refresh and asserts `backend.applied.isEmpty` (`rejectCallsRejectAndDoesNotApply`). ✅
- **`ActivityLogView` reverse-chronological from `audit.records()`** (action, message, trigger rule/agent vs chat, outcome) → Task 5 (`ActivityMapping.timeline` newest-first; `ActivityEntry` maps action/messageId/triggerLabel/outcomeLabel; `triggerLabel` distinguishes `.rule`→agent vs `.chat`→"Assistant (chat)"; `outcomeLabel` covers executed/prepared/queued). Tests `timelineIsNewestFirst`, `refreshLoadsNewestFirstFromPreviewAudit`. ✅
- **`SettingsView` autonomy section: per-agent `AutonomyDial` binding `.ask/.prepare/.auto`, persisted, read by the Orchestrator** → Task 7 (`AutonomySettingsStore`, UserDefaults, default `.ask`), Task 8 (`AutonomySettingsViewModel.binding(forAgent:)` round-trips), Task 9 (`SettingsView` renders `AutonomyDial` per agent), Task 6 (`autonomyForAgent` closure surfaced to the Orchestrator). The dial binds the REAL `.ask/.prepare/.auto` cases via the imported `SenaniDesign.AutonomyDial` (Suggest/Draft/Auto labels) — never redefined. ✅
- **UserDefaults vs DB table — justified** → Cross-package assumptions + Task 7 header: sparse app-local key→enum map, no relational/migration needs, avoids a blocking edit to the frozen `SenaniStore` schema (reconciliation §5), injectable suite for tests. ✅
- **Tests over `AppEnvironment.preview()` with seeded approvals + audit (in-memory), spy backend; approve applies, reject does not; timeline newest-first + field maps; autonomy round-trips; no MLX/Gmail/network** → Task 4 (`approveExecutesThroughThePreviewSpyBackend` over `preview()` + spy), Task 5 (`refreshLoadsNewestFirstFromPreviewAudit` over `preview().audit`), Tasks 7/8 (round-trip). All fakes are in-memory; no MLX/Gmail/Keychain anywhere. ✅
- **#Previews** → Task 4 (`ApprovalQueueView`), Task 5 (`ActivityLogView`), Task 9 (`SettingsView`), each over `AppEnvironment.preview()`. ✅

**§4 conventions honored:**
1. **Composition root only** — every screen reads/writes THROUGH the injected `AppEnvironment` (`init(environment:)` adapters); no view constructs a store/backend. Task 6 surfaces `mailBackend`/`autonomyForAgent`/`autonomySettings` on the root (the single construction site). ✅
2. **One safety path** — approve routes through the existing `ApprovalStore` + `MailBackend` seams; outbound only executes on human approval here; no second send path invented. ✅
3. **Read through canonical stores** — `ApprovalStore`, `PersistentAuditLog`; no hand-rolled SQL. ✅
4. **Live vs preview parity** — every screen has a `#Preview` over `preview()` and a VM/preview-graph test driving the in-memory graph. ✅
5. **macOS 14, Swift 6.2 strict concurrency, Swift Testing** — manifest unchanged from app-shell (tools 6.0, `.swiftLanguageMode(.v6)`). ✅
6. **TDD + bite-sized + frequent commits, complete code, no placeholders** — every task: failing test (full code) → run+expect FAIL → minimal impl (full code) → run+expect PASS → commit. ✅
7. **Pure view models separate from views** — `*Mapping` (pure), `*ViewModel` (`@MainActor @Observable`, no SwiftUI imports beyond `SwiftUI.Binding` in the settings VM), `*View` (thin). ✅

**Source-verified contracts (read from `Packages/Senani*/Sources`):**
- `ApprovalStore.pending()/approve(id:)/reject(id:)` are **synchronous throwing** struct methods; `enqueue(id:_:)` takes the caller id — verified in `ApprovalStore.swift`. The ports + tests use exactly these.
- `PersistentAuditLog.records()` is a **throwing actor method** (needs `await`); `record(_:)` is `async`; `AuditEntry = (record: ActionRecord, loggedAt: Double)` — verified in `PersistentAuditLog.swift`. The activity VM `refresh()` is `async`.
- `Action` cases + `actionClass` (.reversible/.outbound) — verified in `Action.swift`; `actionSummary` covers every case; outbound→queues is enforced upstream by `ActionRouter`, so the queue only ever needs to *execute* an approved action via `apply`.
- `Outcome` = executed/prepared/queuedForApproval, `Trigger` = .rule(id:)/.chat(turnId:), `Autonomy` = ask/prepare/auto — verified in `Routing.swift`/`Rule.swift`.
- `AutonomyDial.init(_ binding: Binding<Autonomy>)`, `GlassPanel`, `PrimaryButton`, tokens — verified in the design-system plan; imported from module `SenaniDesign`.
- `AppEnvironment` (`approvals`, `audit`, `orchestrator`, `@Published selectedItem`, `preview()`) — verified in the app-shell plan; consumed, not reconstructed.

**Recorded deviations / additive contract changes (flagged in the reconciliation doc, Task 6 commit):**
1. **`AppEnvironment` gains `mailBackend: any MailBackend`** — the §3 contract constructs a backend for the Orchestrator but did not expose it; this plan needs the approved-proposal executor, so it surfaces the already-built backend (preview = spy, live = `GmailMailBackend`). Additive, recorded in §3.
2. **`AppEnvironment` gains `autonomyForAgent: @Sendable (String) -> Autonomy` + `autonomySettings: AutonomySettingsStore`** — surfaces the user-set per-agent dials to the Orchestrator and the Settings UI from one `AutonomySettingsStore` instance. Additive; the Orchestrator consumes the closure when `SenaniEngine` is ready (recorded as a seam).
3. **`spyBackend` on `preview()`** — preview-only test scaffolding (not part of the public contract); noted as such in §3.

**Build-order dependencies (coordinate, do not stub):** the app-shell plan (`AppEnvironment` + navigation skeleton) and the design-system plan (`SenaniDesign` package). Pure logic + fake-driven VM tests (Tasks 2, 3 fakes, 5 fakes, 7, 8 store) proceed before they land; `init(environment:)`/`#Preview`/preview-graph tests (Tasks 4, 6, 8, 9) require both.

**Did I add anything not asked for?** `lastError` on the approval/activity VMs (needed to satisfy "if `apply` throws, surface and still refresh" from the goal's execution boundary), `AgentCatalog` (the Settings list needs a known-agent source), and the `mailBackend`/`autonomyForAgent` exposure (load-bearing for the on-approve boundary and the Orchestrator-reads-autonomy requirement). Each traces to an explicit requirement — no speculative API.
