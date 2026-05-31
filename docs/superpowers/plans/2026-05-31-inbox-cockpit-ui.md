# Inbox Cockpit UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Phase-1 **Inbox Cockpit** — the main screen of the Senani SwiftUI app — as an `InboxCockpitView` that replaces the scaffold's placeholder `ContentView` inbox destination. It lists messages from the injected `AppEnvironment.messages` (the real `MessageStore`), grouped and sorted by the triage category + priority labels the Triage agent writes (`Senani/Category/*`, `Senani/Priority/*`), renders each row with sender / subject / snippet / a `CategoryChip` / the latest agent action status (drafted / queued / none) derived from the audit log + approval queue, offers a "Process inbox" button that calls `AppEnvironment.scheduler.tick()`, and shows the selected message's thread by reusing/extending `DetailView`. All read/group/sort/status-derivation logic lives in a **pure, `@MainActor`-free, testable `InboxCockpitViewModel`** that owns no SwiftUI; the view is a thin renderer. Every behavior is proven by Swift Testing tests over `AppEnvironment.preview()` with an in-memory `MessageStore` seeded with labelled messages and a spy scheduler — **no MLX, no Gmail, no network, no Keychain.**

**Architecture:** A new UI feature folder `SenaniApp/Sources/SenaniApp/UI/Inbox/` inside the existing `SenaniApp` executable package. The feature is three pure value/reference types plus one SwiftUI view:

- `InboxRow` (pure struct) — the fully-derived view-model row: id, sender, subject, snippet, `Category`, `Priority`, `AgentStatus`, date. Equatable so tests assert on it directly.
- `InboxSection` (pure struct) — a category header plus its `[InboxRow]`, already sorted by priority then date.
- `InboxCockpitViewModel` (`@MainActor @Observable` reference type) — owns the read logic. It is constructed with the *seams it needs* (a `MessageReading` closure-port, an `ApprovalReading` port, an `AuditReading` port, and an async `process` closure) so it never imports SwiftUI and is driven in tests with in-memory fakes **or** with the real `AppEnvironment.preview()` graph. A convenience `init(environment:)` wires it to the live composition root, satisfying reconciliation §4.1 (the view reads `MessageStore` THROUGH the injected `AppEnvironment`, never constructing a store itself).
- `InboxCockpitView` (SwiftUI) — `@EnvironmentObject var env: AppEnvironment`, builds the view model from `env`, renders sections of rows inside `GlassPanel`s with `CategoryChip`s, a "Process inbox" toolbar button bound to the view model's `processInbox()`, and a selection binding that drives the existing `DetailView`.

The grouping/sorting/status derivation are **pure functions** (`InboxGrouping`) so the same code path the UI uses is the one the tests assert — no UI runloop required.

**Tech Stack:** Swift 6.2 (strict concurrency), Swift Package Manager (the existing `SenaniApp` executable package — this plan raises its `swift-tools-version` to `6.0` and adds a test target, both also done by the app-shell plan; if already done, skip those sub-steps), Swift Testing (`import Testing`). Target platform macOS 14. Depends on `SenaniRules` (`Message`, `Action`, `ActionClass`, `Outcome`, `Trigger`), `SenaniStore` (`MessageStore`, `ApprovalStore`, `StoredProposal`, `PersistentAuditLog`, `AuditEntry`), and `SenaniDesign` (`Category`, `CategoryChip`, `GlassPanel`). No MLX, no Gmail network, no Keychain in this plan or its tests.

**Working directory:** All `swift` commands run from `SenaniApp/` unless stated otherwise. (The package manifest lives at `SenaniApp/Package.swift`; sources at `SenaniApp/Sources/SenaniApp/`; tests at `SenaniApp/Tests/SenaniAppTests/`.)

**Design spec:** `docs/ARCHITECTURE.md` (Inbox cockpit — "renders state, captures approvals"; the pipeline `Triage → Orchestrator → agents → Approval Queue → Activity Log`; the "Process inbox" manual trigger) and `docs/ROADMAP.md` Phase 1 (the demoable MVP slice: mail in → triaged → reply drafted → approved → draft in Gmail). The authoritative app-tier contracts are `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md` §3 (AppEnvironment composition root + DesignSystem symbols), §2 (MessageStore / ApprovalStore / PersistentAuditLog signatures), and §4 (conventions: composition-root-only, live/preview parity).

**Out of scope (separate plans):** the `AppEnvironment` composition root itself (owned by `2026-05-31-app-shell-and-composition-root.md`); the `GlassPanel` / `CategoryChip` / `Category` design symbols (owned by `2026-05-31-gold-glass-design-system.md` — we IMPORT them, never redefine); the Triage agent that *writes* the `Senani/Category/*` labels (owned by the Triage plan — here we only READ them); the Reply Drafter; the Approval queue screen and Activity log screen (sibling Phase-1 UI); the Assistant ⌘K panel; onboarding/OAuth; the MLX model picker. This plan is the inbox list + thread-detail wiring only.

---

## Cross-package assumptions (state these to the human before coding)

This screen compiles only against contracts the upstream plans must expose. The plan codes to these EXACT signatures; if an upstream differs, adjust the thin adapter (`InboxCockpitViewModel.init(environment:)` or the ports), never the pure grouping logic, and record the deviation in the reconciliation doc in the same commit.

### From `SenaniRules` (frozen, verified from source — do NOT edit)
```swift
public struct Message: Sendable, Equatable, Identifiable {
    public let id: String
    public let from: String          // e.g. "Mark <mark@acme.com>" or "mark@acme.com"
    public let to: [String]
    public let subject: String
    public let body: String
    public let hasAttachment: Bool
    public let listUnsubscribeHeader: String?
    public let labels: [String]      // Triage writes "Senani/Category/Lead", "Senani/Priority/High", etc.
    public let threadId: String
    public let date: Date
    public let isFromUser: Bool
    public var senderDomain: String  // lowercased host after last "@"
}
public enum Action: Sendable, Equatable {                       // cases incl. .draft(body:), .reply(body:), .label(_), ...
    public var actionClass: ActionClass { get }                 // .reversible | .outbound
}
public enum ActionClass: Sendable, Equatable { case reversible; case outbound }
public enum Outcome { case executed, prepared, queuedForApproval }   // ⚠ confirm exact spelling in source
public enum Trigger { case rule(id: String); case chat(turnId: String) }
public struct ActionRecord { public let action: Action; public let messageId: String
                             public let trigger: Trigger; public let outcome: Outcome }
public struct Proposal { public let action: Action; public let message: Message; public let trigger: Trigger }
```

### From `SenaniStore` (frozen, verified from source — do NOT edit)
```swift
public struct MessageStore: Sendable {
    public init(database: SenaniDatabase)
    public func all() throws -> [Message]                              // ⚠ SYNCHRONOUS + throwing (NOT async)
    public func query(from: String?, to: String?, isFromUser: Bool?, limit: Int?) throws -> [Message]
    public func thread(id: String) throws -> [Message]                 // date asc
    public func fetch(id: String) throws -> Message?
}
public struct ApprovalStore: Sendable {
    public func pending() throws -> [StoredProposal]                   // ⚠ SYNCHRONOUS + throwing
}
public struct StoredProposal: Sendable, Equatable { public let id: String; public let proposal: Proposal }
public actor PersistentAuditLog: SenaniRules.AuditLog {
    public func records() throws -> [AuditEntry]                       // nonisolated? NO — actor; call with await
}
public struct AuditEntry: Sendable, Equatable { public let record: ActionRecord; public let loggedAt: Double }
```
> **Concurrency note (load-bearing):** `MessageStore.all()` and `ApprovalStore.pending()` are **synchronous throwing struct methods**; `PersistentAuditLog.records()` is a **throwing method on an `actor`**, so reading it requires `await`. The view model's `refresh()` is therefore `async` (it must `await audit.records()`), and the synchronous store reads happen inside that async method. The ports below model exactly this: message/approval ports are `@Sendable () throws -> [...]`, the audit port is `@Sendable () async throws -> [...]`.

### From `SenaniDesign` (owned by the design-system plan — IMPORT, never redefine)
```swift
public enum Category: Sendable, Equatable { case lead; case booking; case proposal; case other(String)
    public var title: String { get } }
public struct CategoryChip: View { public init(_ category: Category) }
public struct GlassPanel<Content: View>: View { public init(@ViewBuilder content: () -> Content)
    public init(style: GlassPanelStyle, @ViewBuilder content: () -> Content) }
```
> **`Category` mapping is OURS to define** (the design system ships the four chip cases; the *string-label → Category* mapping is inbox logic). We map the Triage label suffix to a `Category`: `"Senani/Category/Lead" → .lead`, `"…/Booking" → .booking`, `"…/Proposal" → .proposal`, anything else → `.other(suffix)`. Messages with no `Senani/Category/*` label fall into a synthetic `.other("Uncategorized")` section that sorts last.

### From `SenaniApp` composition root (owned by the app-shell plan — IMPORT, never construct a store)
```swift
@MainActor public final class AppEnvironment: ObservableObject {
    public let messages: MessageStore
    public let approvals: ApprovalStore
    public let audit: PersistentAuditLog
    public let scheduler: Scheduler        // SenaniEngine; has `func tick() async throws`
    public var selectedItem: NavigationItem?    // published; the inbox is one destination
    public static func preview(now: @escaping @Sendable () -> Date = Date.init) -> AppEnvironment
}
```
> **Build-order dependency:** this plan depends on the app-shell plan (`AppEnvironment` + the navigation skeleton) and the design-system plan (`SenaniDesign` package + `Package.swift` dependency line). Both are listed in reconciliation §1 ABOVE Phase-1 UI. If `AppEnvironment.preview()` is not yet green, this plan is blocked on it — record it and coordinate; do NOT stub `AppEnvironment` inside this feature. The view model's port-based design means **Tasks 2–4 (the pure logic + tests) can proceed against in-memory fakes even before `AppEnvironment` lands**; only Task 5 (`init(environment:)`) and Task 7 (the `#Preview` / UI test over `preview()`) require it.
>
> **Scheduler tick seam:** if `SenaniEngine.Scheduler` exposes `processInbox()` instead of (or in addition to) `tick()`, wire `init(environment:)`'s `process` closure to whichever the built API offers — the view model only knows an `async throws` closure, so no logic changes. The reconciliation §3 pins `Scheduler.tick()`; prefer it.

---

## File Structure

```
SenaniApp/
  Package.swift                                  # MODIFY: add SenaniDesign dep (if app-shell hasn't); ensure test target + tools 6.0
  Sources/SenaniApp/UI/Inbox/
    InboxModels.swift                            # CREATE: Priority enum, AgentStatus enum, InboxRow, InboxSection (pure, Equatable)
    InboxGrouping.swift                          # CREATE: pure free functions — label parsing, category/priority mapping,
                                                 #         status derivation, row building, section grouping+sorting
    InboxCockpitViewModel.swift                  # CREATE: @MainActor @Observable VM; ports + init(environment:); refresh()/processInbox()
    InboxCockpitView.swift                       # CREATE: SwiftUI screen (rows in GlassPanel + CategoryChip + Process button + selection)
  Sources/SenaniApp/UI/DetailView.swift          # MODIFY: accept an optional Message (thread header) — keep the no-arg preview path
  Tests/SenaniAppTests/
    InboxGroupingTests.swift                     # CREATE: pure logic — label parse, category/priority order, status derivation
    InboxCockpitViewModelTests.swift             # CREATE: VM over in-memory fakes — sections, sort, status, process spy
    InboxCockpitPreviewGraphTests.swift          # CREATE: VM over AppEnvironment.preview() seeded with labelled messages
```

Each file has one responsibility. `InboxGrouping.swift` is dependency-free pure logic (only `SenaniRules` + `SenaniDesign` types); the view model orchestrates ports; the view renders. Tests for the pure logic never touch a store; tests for the view model use either hand-rolled in-memory fakes (fast, isolated) or the real `preview()` graph (parity).

---

### Task 1: Package wiring — SenaniDesign dependency + test target

**Files:**
- Modify: `SenaniApp/Package.swift`

The inbox feature imports `SenaniDesign` (for `Category`/`CategoryChip`/`GlassPanel`) and needs a test target. The app-shell plan may already raise tools to `6.0` and add the test target; this task is idempotent — only add what's missing.

- [ ] **Step 1: Inspect the current manifest**

```
cd SenaniApp && cat Package.swift
```

Note whether `SenaniDesign` is already a dependency and whether a `.testTarget(name: "SenaniAppTests", ...)` exists.

- [ ] **Step 2: Add the SenaniDesign package dependency + product**

Edit `SenaniApp/Package.swift`. In the top-level `dependencies:` array add (if absent):

```swift
        .package(path: "../Packages/SenaniDesign"),
```

In the `SenaniApp` target's `dependencies:` add (if absent):

```swift
                "SenaniDesign",
```

If the design-system plan named the package directory differently, match it; the reconciliation §3 calls the module `DesignSystem` but the design plan's file structure (verified) creates `Packages/SenaniDesign` with product/module `SenaniDesign`. Use the path/product the design plan actually ships.

- [ ] **Step 3: Ensure a test target exists**

If `SenaniApp/Package.swift` has no test target, add one (and raise `// swift-tools-version: 6.0` at the top, replacing `5.9`, so `import Testing` resolves):

```swift
        .testTarget(
            name: "SenaniAppTests",
            dependencies: ["SenaniApp"]
        ),
```

> If the app-shell plan already added this target and raised the tools version, leave it — do not duplicate. A target already named `SenaniAppTests` is shared across UI plans.

- [ ] **Step 4: Resolve + verify the package still builds**

```
cd SenaniApp && swift build
```

Expected: build succeeds (no code added yet). If `../Packages/SenaniDesign` cannot be resolved, the design-system plan has not landed — this is a blocking external prerequisite; record it and coordinate. Do NOT vendor a copy of `SenaniDesign`.

- [ ] **Step 5: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: add SenaniDesign dependency + test target for Inbox cockpit"
```

Use this commit trailer on EVERY commit in this plan:

```

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

---

### Task 2: Inbox models (Priority, AgentStatus, InboxRow, InboxSection)

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/UI/Inbox/InboxModels.swift`
- Test: `SenaniApp/Tests/SenaniAppTests/InboxGroupingTests.swift` (starts here with a construction test)

Pure, `Sendable`, `Equatable` value types. No SwiftUI, no store. `InboxRow` is the fully-derived thing the view renders and the tests assert on.

- [ ] **Step 1: Write a failing construction test**

Create `SenaniApp/Tests/SenaniAppTests/InboxGroupingTests.swift`:

```swift
import Testing
@testable import SenaniApp
import SenaniDesign
import SenaniRules
import Foundation

@Test func inboxRowHoldsTheDerivedRowFields() {
    let row = InboxRow(
        id: "m1",
        senderName: "Acme Corp",
        subject: "Pricing Inquiry",
        snippet: "I was looking at your enterprise pricing…",
        category: .lead,
        priority: .high,
        status: .drafted,
        date: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(row.id == "m1")
    #expect(row.category == .lead)
    #expect(row.priority == .high)
    #expect(row.status == .drafted)
}

@Test func sectionGroupsRowsUnderACategory() {
    let row = InboxRow(id: "m1", senderName: "A", subject: "S", snippet: "x",
                       category: .lead, priority: .normal, status: .none,
                       date: Date(timeIntervalSince1970: 0))
    let section = InboxSection(category: .lead, rows: [row])
    #expect(section.category == .lead)
    #expect(section.rows.count == 1)
}

@Test func priorityIsOrderedHighFirst() {
    #expect(Priority.high.rank < Priority.normal.rank)
    #expect(Priority.normal.rank < Priority.low.rank)
}
```

- [ ] **Step 2: Run to fail**

```
cd SenaniApp && swift test --filter InboxGroupingTests
```

Expected: failure — `InboxRow` / `InboxSection` / `Priority` / `AgentStatus` undefined (`no such module SenaniApp` won't happen since it's the app target; failure is "cannot find type").

- [ ] **Step 3: Implement the models**

Create `SenaniApp/Sources/SenaniApp/UI/Inbox/InboxModels.swift`:

```swift
import Foundation
import SenaniDesign   // Category

/// Triage priority parsed from the "Senani/Priority/*" label. `rank` orders sections
/// and rows: lower rank sorts first (High before Normal before Low).
public enum Priority: Sendable, Equatable {
    case high
    case normal
    case low

    /// Sort key — High = 0 sorts to the top.
    public var rank: Int {
        switch self {
        case .high: return 0
        case .normal: return 1
        case .low: return 2
        }
    }

    public var title: String {
        switch self {
        case .high: return "High"
        case .normal: return "Normal"
        case .low: return "Low"
        }
    }
}

/// The latest agent action status for a message, derived from the audit log +
/// pending approvals. Drives the row's trailing badge.
public enum AgentStatus: Sendable, Equatable {
    case none        // no agent has acted on this message
    case drafted     // a reversible/prepared draft was produced (audit: .draft executed/prepared)
    case queued      // an outbound action is awaiting approval (in ApprovalStore.pending)

    public var label: String {
        switch self {
        case .none: return ""
        case .drafted: return "Drafted"
        case .queued: return "Queued"
        }
    }
}

/// One fully-derived inbox row. Pure value type so tests assert on it directly.
public struct InboxRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let senderName: String
    public let subject: String
    public let snippet: String
    public let category: Category
    public let priority: Priority
    public let status: AgentStatus
    public let date: Date

    public init(id: String, senderName: String, subject: String, snippet: String,
                category: Category, priority: Priority, status: AgentStatus, date: Date) {
        self.id = id
        self.senderName = senderName
        self.subject = subject
        self.snippet = snippet
        self.category = category
        self.priority = priority
        self.status = status
        self.date = date
    }
}

/// A category header and its rows, already sorted by priority then date.
public struct InboxSection: Identifiable, Sendable, Equatable {
    public var id: String { category.title }
    public let category: Category
    public let rows: [InboxRow]

    public init(category: Category, rows: [InboxRow]) {
        self.category = category
        self.rows = rows
    }
}
```

> **Note on `Category: Equatable`:** the design system pins `Category` as `Sendable, Equatable` (verified), so `InboxRow`/`InboxSection` synthesize `Equatable` for free. If the built `Category` is NOT `Equatable`, drop `Equatable` from these two types and assert field-by-field in tests instead — but the design plan source shows it is.

- [ ] **Step 4: Run to pass**

```
cd SenaniApp && swift test --filter InboxGroupingTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: Inbox cockpit pure models (Priority, AgentStatus, InboxRow, InboxSection)"
```

(Append the standard trailer.)

---

### Task 3: InboxGrouping — pure label parsing, mapping, status derivation, grouping

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/UI/Inbox/InboxGrouping.swift`
- Test: `SenaniApp/Tests/SenaniAppTests/InboxGroupingTests.swift` (append)

The heart of the feature: deterministic, store-free functions that turn `[Message]` + audit + approvals into `[InboxSection]`. This is what the tests pin and the UI reuses verbatim.

Rules:
- **Sender name:** strip the `<addr>` portion of `from` if present (`"Acme <pricing@acme.com>"` → `"Acme"`); else use the local part before `@`; else the raw string.
- **Snippet:** first ~120 chars of `body`, whitespace-collapsed, single line.
- **Category label:** first label with prefix `"Senani/Category/"`; suffix maps to `Category` (`Lead`/`Booking`/`Proposal` → the typed cases, anything else → `.other(suffix)`); no such label → `.other("Uncategorized")`.
- **Priority label:** first label with prefix `"Senani/Priority/"`; suffix `High`/`Low` map; anything else (incl. absent) → `.normal`.
- **Status:** if any pending approval references the message id → `.queued`; else if the audit log's most-recent record for the message id is a `.draft(...)` (or any reversible action that produced a draft) with outcome `.executed`/`.prepared` → `.drafted`; else `.none`. Approval (queued) beats drafted beats none.
- **Section grouping:** group rows by `Category` (using `Category.title` as the grouping key so `.other(x)` with the same x coalesce). Within a section, sort rows by `priority.rank` then `date` descending. Order sections by the **highest-priority row** they contain (a section whose best row is High sorts above one whose best is Normal); ties broken by a stable category order: lead, booking, proposal, then other-categories alphabetically, with `"Uncategorized"` always last.

- [ ] **Step 1: Append failing logic tests**

Append to `SenaniApp/Tests/SenaniAppTests/InboxGroupingTests.swift`:

```swift
// MARK: - InboxGrouping pure-logic tests

private func labelled(_ id: String, category: String?, priority: String?,
                      from: String = "Mark <mark@acme.com>", subject: String = "S",
                      body: String = "Body text here.", threadId: String = "t",
                      date: Date = Date(timeIntervalSince1970: 1000)) -> Message {
    var labels: [String] = []
    if let category { labels.append("Senani/Category/\(category)") }
    if let priority { labels.append("Senani/Priority/\(priority)") }
    return Message(id: id, from: from, to: ["me@x.com"], subject: subject, body: body,
                   hasAttachment: false, listUnsubscribeHeader: nil, labels: labels,
                   threadId: threadId, date: date, isFromUser: false)
}

@Test func parsesCategoryAndPriorityFromLabels() {
    let m = labelled("m1", category: "Lead", priority: "High")
    #expect(InboxGrouping.category(of: m) == .lead)
    #expect(InboxGrouping.priority(of: m) == .high)
}

@Test func unknownCategoryBecomesOtherUncategorized() {
    let m = labelled("m1", category: nil, priority: nil)
    #expect(InboxGrouping.category(of: m) == .other("Uncategorized"))
    #expect(InboxGrouping.priority(of: m) == .normal)   // missing priority defaults Normal
}

@Test func customCategoryLabelBecomesOtherWithSuffix() {
    let m = labelled("m1", category: "Invoice", priority: "Low")
    #expect(InboxGrouping.category(of: m) == .other("Invoice"))
    #expect(InboxGrouping.priority(of: m) == .low)
}

@Test func senderNameStripsAngleAddressAndSnippetCollapses() {
    let m = labelled("m1", category: "Lead", priority: "High",
                     from: "Acme Corp <pricing@acme.com>",
                     body: "  Hi there,\n\n  I had a few   questions.  ")
    let row = InboxGrouping.row(for: m, status: .none)
    #expect(row.senderName == "Acme Corp")
    #expect(row.snippet == "Hi there, I had a few questions.")
}

@Test func statusQueuedBeatsDraftedBeatsNone() {
    // queued: id in pending approvals
    let queued = InboxGrouping.status(messageId: "m1", pendingIds: ["m1"], lastDraftedIds: ["m1"])
    #expect(queued == .queued)
    // drafted: not pending, but in drafted set
    let drafted = InboxGrouping.status(messageId: "m2", pendingIds: [], lastDraftedIds: ["m2"])
    #expect(drafted == .drafted)
    // none
    let none = InboxGrouping.status(messageId: "m3", pendingIds: [], lastDraftedIds: [])
    #expect(none == .none)
}

@Test func sectionsSortByPriorityWithinAndBestPriorityAcross() {
    let messages = [
        labelled("a", category: "Booking", priority: "Normal", date: Date(timeIntervalSince1970: 10)),
        labelled("b", category: "Lead",    priority: "Low",    date: Date(timeIntervalSince1970: 20)),
        labelled("c", category: "Lead",    priority: "High",   date: Date(timeIntervalSince1970: 30)),
        labelled("d", category: "Lead",    priority: "High",   date: Date(timeIntervalSince1970: 40)),
    ]
    let sections = InboxGrouping.sections(
        from: messages, pendingIds: [], lastDraftedIds: [])
    // Lead section first (it holds a High row); Booking after (best = Normal).
    #expect(sections.map(\.category) == [.lead, .booking])
    // Within Lead: both High rows first, newest-first by date, then the Low row.
    #expect(sections[0].rows.map(\.id) == ["d", "c", "b"])
}

@Test func uncategorizedSectionSortsLast() {
    let messages = [
        labelled("u", category: nil, priority: "High"),     // Uncategorized but High
        labelled("l", category: "Lead", priority: "Low"),
    ]
    let sections = InboxGrouping.sections(from: messages, pendingIds: [], lastDraftedIds: [])
    #expect(sections.last?.category == .other("Uncategorized"))
}
```

- [ ] **Step 2: Run to fail**

```
cd SenaniApp && swift test --filter InboxGroupingTests
```

Expected: failure — `InboxGrouping` undefined.

- [ ] **Step 3: Implement `InboxGrouping`**

Create `SenaniApp/Sources/SenaniApp/UI/Inbox/InboxGrouping.swift`:

```swift
import Foundation
import SenaniDesign   // Category
import SenaniRules    // Message

/// Pure, store-free transforms from raw messages (+ derived id sets) to inbox sections.
/// The view model computes the id sets from the audit log / approvals; everything here
/// is deterministic and unit-tested without a store or UI.
public enum InboxGrouping {

    static let categoryPrefix = "Senani/Category/"
    static let priorityPrefix = "Senani/Priority/"
    static let uncategorized = "Uncategorized"

    // MARK: - Field derivation

    /// Triage category from the first "Senani/Category/*" label, else .other("Uncategorized").
    public static func category(of message: Message) -> Category {
        guard let suffix = labelSuffix(message.labels, prefix: categoryPrefix) else {
            return .other(uncategorized)
        }
        switch suffix.lowercased() {
        case "lead": return .lead
        case "booking": return .booking
        case "proposal": return .proposal
        default: return .other(suffix)
        }
    }

    /// Triage priority from the first "Senani/Priority/*" label, else .normal.
    public static func priority(of message: Message) -> Priority {
        guard let suffix = labelSuffix(message.labels, prefix: priorityPrefix) else {
            return .normal
        }
        switch suffix.lowercased() {
        case "high": return .high
        case "low": return .low
        default: return .normal
        }
    }

    private static func labelSuffix(_ labels: [String], prefix: String) -> String? {
        for label in labels where label.hasPrefix(prefix) {
            return String(label.dropFirst(prefix.count))
        }
        return nil
    }

    /// Display name: text before "<", else local-part before "@", else the raw string.
    public static func senderName(from: String) -> String {
        if let lt = from.firstIndex(of: "<") {
            let name = from[..<lt].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        if let at = from.firstIndex(of: "@"), from.firstIndex(of: "<") == nil {
            return String(from[..<at])
        }
        return from.trimmingCharacters(in: .whitespaces)
    }

    /// First ~120 chars of the body, whitespace-collapsed onto one line.
    public static func snippet(from body: String) -> String {
        let collapsed = body.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return String(collapsed.prefix(120))
    }

    /// Status precedence: queued (pending approval) > drafted > none.
    public static func status(messageId: String, pendingIds: Set<String>,
                              lastDraftedIds: Set<String>) -> AgentStatus {
        if pendingIds.contains(messageId) { return .queued }
        if lastDraftedIds.contains(messageId) { return .drafted }
        return .none
    }

    // MARK: - Row + section assembly

    public static func row(for message: Message, status: AgentStatus) -> InboxRow {
        InboxRow(
            id: message.id,
            senderName: senderName(from: message.from),
            subject: message.subject,
            snippet: snippet(from: message.body),
            category: category(of: message),
            priority: priority(of: message),
            status: status,
            date: message.date)
    }

    /// Builds sorted sections. `pendingIds` = message ids with a pending approval;
    /// `lastDraftedIds` = message ids whose latest agent action was a draft.
    public static func sections(from messages: [Message], pendingIds: Set<String>,
                                lastDraftedIds: Set<String>) -> [InboxSection] {
        // 1. Build rows.
        let rows = messages.map { message in
            row(for: message,
                status: status(messageId: message.id, pendingIds: pendingIds,
                               lastDraftedIds: lastDraftedIds))
        }
        // 2. Group by category title (so identical .other(x) coalesce).
        var byKey: [String: (category: Category, rows: [InboxRow])] = [:]
        var keyOrderSeen: [String] = []
        for row in rows {
            let key = row.category.title
            if byKey[key] == nil {
                byKey[key] = (row.category, [])
                keyOrderSeen.append(key)
            }
            byKey[key]?.rows.append(row)
        }
        // 3. Sort rows within each section: priority rank asc, then date desc.
        var sections = keyOrderSeen.map { key -> InboxSection in
            let group = byKey[key]!
            let sorted = group.rows.sorted { a, b in
                if a.priority.rank != b.priority.rank { return a.priority.rank < b.priority.rank }
                return a.date > b.date
            }
            return InboxSection(category: group.category, rows: sorted)
        }
        // 4. Order sections: best (lowest) priority rank first; ties by category order.
        sections.sort { lhs, rhs in
            let lBest = lhs.rows.map(\.priority.rank).min() ?? Int.max
            let rBest = rhs.rows.map(\.priority.rank).min() ?? Int.max
            if lBest != rBest { return lBest < rBest }
            return categoryOrder(lhs.category) < categoryOrder(rhs.category)
        }
        return sections
    }

    /// Stable tie-break order: lead, booking, proposal, then other categories
    /// alphabetically, with "Uncategorized" always last.
    static func categoryOrder(_ category: Category) -> (Int, String) {
        switch category {
        case .lead: return (0, "")
        case .booking: return (1, "")
        case .proposal: return (2, "")
        case .other(let name):
            return name == uncategorized ? (4, "") : (3, name.lowercased())
        }
    }
}

// Make the tuple comparable for the sort above.
private func < (lhs: (Int, String), rhs: (Int, String)) -> Bool {
    if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
    return lhs.1 < rhs.1
}
```

- [ ] **Step 4: Run to pass**

```
cd SenaniApp && swift test --filter InboxGroupingTests
```

Expected: all pass (the 3 model tests + the 7 grouping tests).

- [ ] **Step 5: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: InboxGrouping pure label-parse/category/priority/status/section logic"
```

(Append the standard trailer.)

---

### Task 4: InboxCockpitViewModel — ports, refresh, process (over in-memory fakes)

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/UI/Inbox/InboxCockpitViewModel.swift`
- Test: `SenaniApp/Tests/SenaniAppTests/InboxCockpitViewModelTests.swift`

The view model owns the read logic via injected closure-ports so it is testable with hand-rolled fakes and decoupled from `AppEnvironment`'s exact concrete types. It derives `pendingIds` (from approvals) and `lastDraftedIds` (from the audit log: the most-recent record per message whose action is `.draft(...)`), calls `InboxGrouping.sections`, and exposes `processInbox()` which invokes the injected `process` closure then refreshes.

The audit-derived "last drafted" set: walk `audit.records()` (oldest→newest, the store returns them `ORDER BY id`), keep a `[messageId: AgentStatusSeed]` of the latest agent action per message; a message is "drafted" if its latest agent action is a `.draft(...)` with outcome `.executed` or `.prepared`. (Queued is taken from the live approval queue, not the audit log, so a later approval/rejection is reflected immediately.)

- [ ] **Step 1: Write failing view-model tests**

Create `SenaniApp/Tests/SenaniAppTests/InboxCockpitViewModelTests.swift`:

```swift
import Testing
@testable import SenaniApp
import SenaniDesign
import SenaniRules
import Foundation

// MARK: - Hand-rolled in-memory fakes (closure ports)

private func msg(_ id: String, category: String, priority: String,
                 date: Date = Date(timeIntervalSince1970: 1000)) -> Message {
    Message(id: id, from: "Mark <mark@acme.com>", to: ["me@x.com"],
            subject: "Subj \(id)", body: "Body \(id)", hasAttachment: false,
            listUnsubscribeHeader: nil,
            labels: ["Senani/Category/\(category)", "Senani/Priority/\(priority)"],
            threadId: "t-\(id)", date: date, isFromUser: false)
}

@MainActor
private func makeVM(
    messages: [Message],
    pending: [String] = [],            // message ids with a pending approval
    drafted: [String] = [],            // message ids whose latest agent action is a draft
    process: @escaping @Sendable () async throws -> Void = {}
) -> InboxCockpitViewModel {
    InboxCockpitViewModel(
        readMessages: { messages },
        readPendingMessageIds: { Set(pending) },
        readDraftedMessageIds: { Set(drafted) },
        process: process)
}

@Test @MainActor func refreshBuildsSortedSections() async throws {
    let vm = makeVM(messages: [
        msg("a", category: "Booking", priority: "Normal"),
        msg("b", category: "Lead", priority: "High"),
    ])
    await vm.refresh()
    #expect(vm.sections.map(\.category) == [.lead, .booking])
    #expect(vm.errorMessage == nil)
}

@Test @MainActor func refreshDerivesStatusFromPortsQueuedAndDrafted() async throws {
    let vm = makeVM(
        messages: [msg("a", category: "Lead", priority: "High"),
                   msg("b", category: "Lead", priority: "High")],
        pending: ["a"], drafted: ["b"])
    await vm.refresh()
    let rows = vm.sections.first(where: { $0.category == .lead })!.rows
    #expect(rows.first(where: { $0.id == "a" })?.status == .queued)
    #expect(rows.first(where: { $0.id == "b" })?.status == .drafted)
}

@Test @MainActor func processInboxInvokesProcessThenRefreshes() async throws {
    let counter = Counter()
    let vm = makeVM(messages: [msg("a", category: "Lead", priority: "High")],
                    process: { await counter.bump() })
    await vm.processInbox()
    #expect(await counter.value == 1)               // scheduler.tick spy called exactly once
    #expect(vm.isProcessing == false)               // flag reset after completion
    #expect(vm.sections.count == 1)                 // refreshed after processing
}

@Test @MainActor func refreshSurfacesReadErrors() async throws {
    let vm = InboxCockpitViewModel(
        readMessages: { throw TestError.boom },
        readPendingMessageIds: { [] },
        readDraftedMessageIds: { [] },
        process: {})
    await vm.refresh()
    #expect(vm.errorMessage != nil)
    #expect(vm.sections.isEmpty)
}

private enum TestError: Error { case boom }

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
```

- [ ] **Step 2: Run to fail**

```
cd SenaniApp && swift test --filter InboxCockpitViewModelTests
```

Expected: failure — `InboxCockpitViewModel` undefined.

- [ ] **Step 3: Implement the view model**

Create `SenaniApp/Sources/SenaniApp/UI/Inbox/InboxCockpitViewModel.swift`:

```swift
import Foundation
import Observation
import SenaniRules

/// Owns the inbox read/derive logic. Constructed from closure-ports so it is fully
/// testable with in-memory fakes AND wired to the live AppEnvironment via init(environment:)
/// (see Task 5). The view holds one of these and renders `sections`; it never reads a store.
@MainActor
@Observable
public final class InboxCockpitViewModel {
    public private(set) var sections: [InboxSection] = []
    public private(set) var isProcessing = false
    public private(set) var errorMessage: String?

    private let readMessages: @Sendable () throws -> [Message]
    private let readPendingMessageIds: @Sendable () throws -> Set<String>
    private let readDraftedMessageIds: @Sendable () async throws -> Set<String>
    private let process: @Sendable () async throws -> Void

    /// Designated initializer (port-based). Tests pass in-memory closures; Task 5
    /// adds the `init(environment:)` convenience that builds these from AppEnvironment.
    public init(
        readMessages: @escaping @Sendable () throws -> [Message],
        readPendingMessageIds: @escaping @Sendable () throws -> Set<String>,
        readDraftedMessageIds: @escaping @Sendable () async throws -> Set<String>,
        process: @escaping @Sendable () async throws -> Void
    ) {
        self.readMessages = readMessages
        self.readPendingMessageIds = readPendingMessageIds
        self.readDraftedMessageIds = readDraftedMessageIds
        self.process = process
    }

    /// Re-reads the stores and rebuilds the grouped/sorted sections. Never throws —
    /// failures land in `errorMessage` so the UI can surface them without crashing.
    public func refresh() async {
        do {
            let messages = try readMessages()
            let pending = try readPendingMessageIds()
            let drafted = try await readDraftedMessageIds()
            sections = InboxGrouping.sections(
                from: messages, pendingIds: pending, lastDraftedIds: drafted)
            errorMessage = nil
        } catch {
            sections = []
            errorMessage = String(describing: error)
        }
    }

    /// Runs one process cycle (scheduler.tick) then refreshes. Re-entrant-safe via
    /// `isProcessing`; the button binds `disabled(isProcessing)`.
    public func processInbox() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        do {
            try await process()
        } catch {
            errorMessage = String(describing: error)
        }
        await refresh()
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd SenaniApp && swift test --filter InboxCockpitViewModelTests
```

Expected: all 4 pass.

- [ ] **Step 5: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: InboxCockpitViewModel (port-based refresh + processInbox over in-memory fakes)"
```

(Append the standard trailer.)

---

### Task 5: Wire the view model to AppEnvironment (composition-root convenience init)

**Files:**
- Edit: `SenaniApp/Sources/SenaniApp/UI/Inbox/InboxCockpitViewModel.swift`
- Test: `SenaniApp/Tests/SenaniAppTests/InboxCockpitPreviewGraphTests.swift`

This is the §4.1 seam: the view model reads `MessageStore`/`ApprovalStore`/`PersistentAuditLog` **through the injected `AppEnvironment`** — no store is constructed here. The convenience init closes over `environment.messages`, `environment.approvals`, `environment.audit`, and `environment.scheduler.tick`. The audit-derived "drafted" set is computed here (the only place that knows the concrete `AuditEntry`/`Action` types).

- [ ] **Step 1: Write a failing preview-graph test**

Create `SenaniApp/Tests/SenaniAppTests/InboxCockpitPreviewGraphTests.swift`:

```swift
import Testing
@testable import SenaniApp
import SenaniDesign
import SenaniRules
import SenaniStore
import Foundation

@MainActor
@Test func viewModelOverPreviewGraphGroupsSeededLabelledMessages() async throws {
    let env = AppEnvironment.preview()
    // Seed the in-memory MessageStore with labelled messages (Triage output shape).
    try env.messages.saveAll([
        Message(id: "lead-hi", from: "Acme <pricing@acme.com>", to: ["me@x.com"],
                subject: "Pricing", body: "We want enterprise pricing.", hasAttachment: false,
                listUnsubscribeHeader: nil,
                labels: ["Senani/Category/Lead", "Senani/Priority/High"],
                threadId: "t1", date: Date(timeIntervalSince1970: 2000), isFromUser: false),
        Message(id: "book-norm", from: "Sam <sam@cal.com>", to: ["me@x.com"],
                subject: "Meeting", body: "Can we meet Tuesday?", hasAttachment: false,
                listUnsubscribeHeader: nil,
                labels: ["Senani/Category/Booking", "Senani/Priority/Normal"],
                threadId: "t2", date: Date(timeIntervalSince1970: 1000), isFromUser: false),
    ])

    let vm = InboxCockpitViewModel(environment: env)
    await vm.refresh()

    #expect(vm.sections.map(\.category) == [.lead, .booking])
    #expect(vm.sections.first?.rows.first?.id == "lead-hi")
    #expect(vm.sections.first?.rows.first?.senderName == "Acme")
}

@MainActor
@Test func processInboxOverPreviewGraphTicksTheSchedulerWithoutNetwork() async throws {
    // preview() builds an empty AgentRegistry + GmailSync against a preview token store;
    // tick() must not throw a *test* failure in our control flow — we assert the VM
    // completes its process cycle and clears isProcessing. (A network/no-token error
    // is captured into errorMessage, not crashed.)
    let env = AppEnvironment.preview()
    let vm = InboxCockpitViewModel(environment: env)
    await vm.processInbox()
    #expect(vm.isProcessing == false)
}
```

> **Scheduler note:** `preview()`'s `Scheduler` wraps a `GmailSync` pointed at an in-memory token store with no real credentials, so `tick()` may throw when it attempts a sync. `processInbox()` captures that into `errorMessage` (never crashes), and the test only asserts the cycle completes and `isProcessing` resets. If you want a network-free assertion that `tick` is *invoked*, prefer the Task-4 spy test (`processInboxInvokesProcessThenRefreshes`), which uses a pure closure and is the authoritative "Process button calls the scheduler" proof. This test proves the *live wiring* path runs end-to-end over the real graph.

- [ ] **Step 2: Run to fail**

```
cd SenaniApp && swift test --filter InboxCockpitPreviewGraphTests
```

Expected: failure — `InboxCockpitViewModel(environment:)` undefined.

- [ ] **Step 3: Add the convenience init**

Append to `SenaniApp/Sources/SenaniApp/UI/Inbox/InboxCockpitViewModel.swift`:

```swift
import SenaniStore   // MessageStore, ApprovalStore, PersistentAuditLog, StoredProposal, AuditEntry

extension InboxCockpitViewModel {
    /// Composition-root wiring (reconciliation §4.1): reads MessageStore / ApprovalStore /
    /// PersistentAuditLog THROUGH the injected AppEnvironment and ticks its Scheduler.
    /// No store/backend is constructed here.
    public convenience init(environment env: AppEnvironment) {
        let messages = env.messages
        let approvals = env.approvals
        let audit = env.audit
        let scheduler = env.scheduler

        self.init(
            readMessages: { try messages.all() },
            readPendingMessageIds: {
                Set(try approvals.pending().map { $0.proposal.message.id })
            },
            readDraftedMessageIds: {
                let entries = try await audit.records()
                return Self.draftedMessageIds(from: entries)
            },
            process: { try await scheduler.tick() })
    }

    /// A message id is "drafted" when its MOST RECENT agent action in the audit log is a
    /// `.draft(...)` that executed or was prepared. Entries arrive oldest→newest, so the
    /// last write per id wins.
    static func draftedMessageIds(from entries: [AuditEntry]) -> Set<String> {
        var latestIsDraft: [String: Bool] = [:]
        for entry in entries {
            let r = entry.record
            let isDraft: Bool
            if case .draft = r.action { isDraft = isPositive(r.outcome) } else { isDraft = false }
            latestIsDraft[r.messageId] = isDraft   // later entry overwrites earlier
        }
        return Set(latestIsDraft.filter { $0.value }.keys)
    }

    /// Outcome counts as "the action happened" (drafted/prepared) vs queued-only.
    private static func isPositive(_ outcome: Outcome) -> Bool {
        switch outcome {
        case .executed, .prepared: return true
        case .queuedForApproval: return false
        }
    }
}
```

> **Verify against source before running:** confirm `Outcome`'s exact cases (`executed` / `prepared` / `queuedForApproval`) in `SenaniRules/Routing.swift` and that `StoredProposal.proposal.message.id` is reachable (`Proposal.message: Message`, verified). If `Outcome` has different/extra cases, adjust `isPositive`. If `PersistentAuditLog.records()` is `nonisolated`/non-`async` in the built source, drop the `await` (the port type stays `async throws` and simply doesn't suspend — harmless).

- [ ] **Step 4: Run to pass**

```
cd SenaniApp && swift test --filter InboxCockpitPreviewGraphTests
```

Expected: both pass. If the design-system or app-shell package has not landed, this is the first task that will fail to *resolve/compile* against them — that is the documented build-order prerequisite (Tasks 2–4 stand alone; Task 5 needs `AppEnvironment`).

- [ ] **Step 5: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: wire InboxCockpitViewModel to AppEnvironment (composition-root reads + scheduler.tick)"
```

(Append the standard trailer.)

---

### Task 6: Extend DetailView to render a selected thread

**Files:**
- Edit: `SenaniApp/Sources/SenaniApp/UI/DetailView.swift`

The scaffold's `DetailView` is a hardcoded mock. Extend it to accept an optional `Message` (the thread's latest/selected message) and render its real sender/subject/body, while keeping the existing zero-arg path working for the app-shell's placeholder/previews. We keep the gold-glass look by reusing the scaffold's `GlassCard`, `StatusBadge`, `WordmarkHeader`, `GoldButton` (Theme/DesignSystem in `UI/`).

- [ ] **Step 1: Read the current DetailView**

```
cd SenaniApp && cat Sources/SenaniApp/UI/DetailView.swift
```

(Verified shape: `struct DetailView: View` with a hardcoded body, using `StatusBadge`, `GlassCard`, `WordmarkHeader`, `GoldButton`, `Color.senaniObsidian`.)

- [ ] **Step 2: Make it message-driven (backward compatible)**

Edit `SenaniApp/Sources/SenaniApp/UI/DetailView.swift`. Add a stored optional message and a memberwise init defaulting to `nil`, then render real fields when present and the existing mock when `nil`:

```swift
import SwiftUI
import SenaniRules

struct DetailView: View {
    let message: Message?

    init(message: Message? = nil) {
        self.message = message
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                Divider()
                Text(message?.body ?? Self.placeholderBody)
                    .font(.system(size: 15))
                    .lineSpacing(6)
                Spacer(minLength: 20)
                agentInsight
            }
            .padding(40)
            .frame(maxWidth: 800)
        }
        .background(Color.senaniObsidian)
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatusBadge(text: "Lead", color: .senaniGold)
                StatusBadge(text: "Priority", color: .red)
                Spacer()
                Text(message.map { Self.time.string(from: $0.date) } ?? "06:58 AM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(message?.subject ?? "Pricing Inquiry")
                .font(.system(size: 32, weight: .bold))
            HStack {
                Image(systemName: "person.circle.fill").font(.title2)
                VStack(alignment: .leading) {
                    Text(message.map { InboxGrouping.senderName(from: $0.from) } ?? "Acme Corp")
                        .fontWeight(.semibold)
                    Text(message?.from ?? "pricing@acme.com")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var agentInsight: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "sparkles")
                    WordmarkHeader(title: "Agent Insight")
                }
                Text("Lead scored 87. Drafted a reply based on your recent 'Enterprise' voice exemplars.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    GoldButton(title: "Approve Draft") {}.frame(width: 140)
                    Button("Edit") {}.buttonStyle(.bordered).controlSize(.large)
                }
            }
        }
    }

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()

    private static let placeholderBody =
        "Hi there,\n\nI was looking at your enterprise pricing and had a few questions regarding the volume discounts for teams larger than 50.\n\nBest,\nMark from Acme"
}
```

> **Backward compatibility:** the app-shell's `MainNavigationView`/`RootScene` calls `DetailView()` with no args — the defaulted `message: nil` preserves that. We do not change call sites in this task; Task 7 passes the selected message from the inbox.

- [ ] **Step 3: Build**

```
cd SenaniApp && swift build
```

Expected: builds. (No new test — DetailView is a pure renderer; its message-driven fields are exercised via the inbox `#Preview` in Task 7. If a unit assertion is desired, the only logic added is `InboxGrouping.senderName`, already covered in Task 3.)

- [ ] **Step 4: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: DetailView renders an optional selected Message (backward-compatible)"
```

(Append the standard trailer.)

---

### Task 7: InboxCockpitView — the SwiftUI screen + #Preview, wired into navigation

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/UI/Inbox/InboxCockpitView.swift`
- Edit: `SenaniApp/Sources/SenaniApp/UI/MainNavigationView.swift` (route the Inbox destination to `InboxCockpitView`)

The screen: `@EnvironmentObject var env: AppEnvironment`, a `@State` view model built from `env`, a `@State` selected message id, a list of `InboxSection`s rendered as `GlassPanel`s with `CategoryChip`, a trailing-toolbar "Process inbox" button bound to `processInbox()` and disabled while `isProcessing`, a `.task { await vm.refresh() }` initial load, and a selection that resolves to a `Message` and feeds `DetailView`.

- [ ] **Step 1: Implement the view + #Preview**

Create `SenaniApp/Sources/SenaniApp/UI/Inbox/InboxCockpitView.swift`:

```swift
import SwiftUI
import SenaniDesign
import SenaniRules

/// The Phase-1 Inbox Cockpit: triaged, grouped, status-annotated message list with a
/// "Process inbox" action. Reads everything through the injected AppEnvironment.
struct InboxCockpitView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var viewModel: InboxCockpitViewModel?
    @Binding var selectedMessageID: String?

    init(selectedMessageID: Binding<String?>) {
        self._selectedMessageID = selectedMessageID
    }

    var body: some View {
        Group {
            if let vm = viewModel {
                content(vm)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .background(Color.senaniObsidian)
        .task {
            if viewModel == nil { viewModel = InboxCockpitViewModel(environment: env) }
            await viewModel?.refresh()
        }
    }

    @ViewBuilder private func content(_ vm: InboxCockpitViewModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let error = vm.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
                ForEach(vm.sections) { section in
                    sectionView(section)
                }
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await vm.processInbox() }
                } label: {
                    Label("Process inbox", systemImage: "sparkles")
                }
                .disabled(vm.isProcessing)
            }
        }
    }

    @ViewBuilder private func sectionView(_ section: InboxSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CategoryChip(section.category)
                Text("\(section.rows.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            ForEach(section.rows) { row in
                Button { selectedMessageID = row.id } label: {
                    GlassPanel { rowView(row) }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func rowView(_ row: InboxRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.senderName).font(.system(size: 14, weight: .semibold))
                Spacer()
                if row.priority == .high {
                    StatusBadge(text: "High", color: .red)
                }
                if !row.status.label.isEmpty {
                    StatusBadge(text: row.status.label, color: .senaniGold)
                }
            }
            Text(row.subject).font(.system(size: 14))
            Text(row.snippet).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Inbox Cockpit") {
    let env = AppEnvironment.preview()
    try? env.messages.saveAll([
        Message(id: "lead-hi", from: "Acme Corp <pricing@acme.com>", to: ["me@x.com"],
                subject: "Pricing Inquiry", body: "We were looking at enterprise pricing for 50+ seats.",
                hasAttachment: false, listUnsubscribeHeader: nil,
                labels: ["Senani/Category/Lead", "Senani/Priority/High"],
                threadId: "t1", date: Date(), isFromUser: false),
        Message(id: "book-norm", from: "Sam <sam@cal.com>", to: ["me@x.com"],
                subject: "Quick sync?", body: "Could we grab 30 minutes on Tuesday?",
                hasAttachment: false, listUnsubscribeHeader: nil,
                labels: ["Senani/Category/Booking", "Senani/Priority/Normal"],
                threadId: "t2", date: Date(), isFromUser: false),
        Message(id: "prop-low", from: "Jo <jo@vendor.io>", to: ["me@x.com"],
                subject: "Proposal v2", body: "Attached is the revised proposal.",
                hasAttachment: true, listUnsubscribeHeader: nil,
                labels: ["Senani/Category/Proposal", "Senani/Priority/Low"],
                threadId: "t3", date: Date(), isFromUser: false),
    ])
    return InboxCockpitView(selectedMessageID: .constant(nil))
        .environmentObject(env)
        .frame(width: 420, height: 600)
}
```

> **`@State` view model + `@EnvironmentObject`:** `@EnvironmentObject` is only available in `body`, so the view model is built lazily in `.task` (where `env` is in scope), not in `init`. This is the standard SwiftUI pattern for an `@Observable` VM that depends on an injected environment object.

- [ ] **Step 2: Route the Inbox destination to the cockpit**

Edit `SenaniApp/Sources/SenaniApp/UI/MainNavigationView.swift`. The scaffold's `ContentView` shows a placeholder for the selected sidebar item, and `DetailView()` is the detail column. Replace the inbox branch of `ContentView` so that when `selection == .inbox` it shows `InboxCockpitView`, threading a selected message id, and pass the resolved `Message` to `DetailView`.

Concretely, add a selection state on the navigation view and adapt `ContentView`:

```swift
struct MainNavigationView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var selectedMessageID: String?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: Binding(
                get: { env.selectedItem },
                set: { env.selectedItem = $0 }))
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            ContentView(selection: env.selectedItem, selectedMessageID: $selectedMessageID)
                .navigationSplitViewColumnWidth(min: 300, ideal: 350)
        } detail: {
            DetailView(message: selectedMessageID.flatMap { try? env.messages.fetch(id: $0) } ?? nil)
        }
    }
}

struct ContentView: View {
    let selection: NavigationItem?
    @Binding var selectedMessageID: String?

    var body: some View {
        switch selection {
        case .inbox:
            InboxCockpitView(selectedMessageID: $selectedMessageID)
        case .some(let item):
            VStack { Text(item.rawValue).font(.headline); Spacer(); Text("Coming soon").foregroundStyle(.secondary); Spacer() }
        case .none:
            Text("Select a category")
        }
    }
}
```

> **Adapt to whatever the app-shell shipped.** The reconciliation/app-shell plan replaces the scaffold's `@Observable AppState` (injected with `.environment`) with `AppEnvironment: ObservableObject` (injected with `@EnvironmentObject`) and adds `selectedItem` + a navigation skeleton (possibly named `RootScene`, not `MainNavigationView`). **Route the inbox into whatever the shipped navigation container is** — the load-bearing change is "the Inbox destination renders `InboxCockpitView(selectedMessageID:)` and the detail column renders `DetailView(message:)`." If the app-shell still uses `@Observable AppState` injected via `.environment(...)`, swap `@EnvironmentObject` for `@Environment(AppEnvironment.self)` accordingly. Verify the actual symbols with `grep -rn "AppEnvironment\|AppState\|RootScene\|MainNavigationView" SenaniApp/Sources` before editing, and match them.

- [ ] **Step 3: Build the app target**

```
cd SenaniApp && swift build
```

Expected: builds. SwiftUI `#Preview`s are compiled but not executed by `swift build`; the build proves the view + navigation wiring type-checks against `AppEnvironment` and `SenaniDesign`.

- [ ] **Step 4: Run the full test suite**

```
cd SenaniApp && swift test
```

Expected: every test across `InboxGroupingTests`, `InboxCockpitViewModelTests`, `InboxCockpitPreviewGraphTests` (plus any app-shell tests already present) passes.

- [ ] **Step 5: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: InboxCockpitView (GlassPanel rows + CategoryChip + Process button) routed into navigation"
```

(Append the standard trailer.)

---

## Self-Review

**Scope coverage (against the SCOPE brief):**
- ✅ `InboxCockpitView` lists `AppEnvironment.messages` (`MessageStore.all()`), grouped/sorted by triage category + priority (`Senani/Category/*`, `Senani/Priority/*`) — Tasks 3 + 7.
- ✅ Each row: sender, subject, snippet, `CategoryChip`, latest agent action status (drafted/queued/none) derived from audit log + approvals — Tasks 2/3/5/7.
- ✅ "Process inbox" button calls `AppEnvironment.scheduler.tick()` and refreshes — Tasks 4/5/7.
- ✅ `@Observable` view model owns the read logic, pure and testable, separated from the view — Task 4.
- ✅ Selecting a message shows the thread by reusing/extending `DetailView` — Tasks 6/7.
- ✅ Tests over `AppEnvironment.preview()` with in-memory `MessageStore` seeded with labelled messages: grouping/sort by category+priority, status derivation, and a Process spy — Tasks 4 (spy) + 5 (preview graph).
- ✅ `#Preview` provided (Task 7) and `.preview()`-backed UI/logic test provided (Task 5). No MLX/Gmail/network/Keychain in any test.

**Reconciliation §4 conventions honored:**
- §4.1 composition-root-only: the view model reads `MessageStore`/`ApprovalStore`/`PersistentAuditLog` THROUGH `AppEnvironment` (`init(environment:)`); no screen or VM constructs a store/backend. ✅
- §4.2 one safety path: this is read-only UI plus `scheduler.tick()`; it never sends mail or writes actions directly. ✅
- §4.3 read through canonical stores: uses `MessageStore`/`ApprovalStore`/`PersistentAuditLog` — no hand-rolled SQL. ✅
- §4.4 live/preview parity: `#Preview` + a `preview()`-backed test; no MLX/Gmail/Keychain. ✅
- §4.5/§4.6: macOS 14, Swift 6.2 strict concurrency, Swift Testing, TDD with complete code, frequent commits. ✅
- Design symbols imported from `SenaniDesign` (`GlassPanel`, `CategoryChip`, `Category`), never redefined. ✅ Built on the existing scaffold (`MainNavigationView`, `DetailView`, `Theme`/`DesignSystem` in `UI/`) rather than ignoring it. ✅

**Risks / pins flagged for the worker:**
1. **Build-order dependency** on the app-shell plan (`AppEnvironment` + navigation skeleton) and the design-system plan (`SenaniDesign`). Tasks 2–4 stand alone (pure logic over fakes); Tasks 1, 5, 6, 7 require those packages. If absent, this plan is blocked — coordinate, do not stub them. Documented in Cross-package assumptions.
2. **`AppState` vs `AppEnvironment`:** the current scaffold still uses `@Observable AppState` injected via `.environment(...)`. The app-shell plan replaces it with `ObservableObject AppEnvironment` injected via `@EnvironmentObject`. Task 7 instructs the worker to `grep` the actual shipped symbols and match the injection style — the inbox logic is injection-agnostic.
3. **`Outcome` cases + `PersistentAuditLog.records()` isolation:** verify exact `Outcome` spelling and whether `records()` needs `await` (Task 5 note). The port type is `async throws` either way, so only `isPositive`/the `await` keyword may need a one-line tweak.
4. **`Scheduler.tick()` vs `processInbox()`:** the `process` closure binds to whichever the built `SenaniEngine.Scheduler` exposes; reconciliation §3 pins `tick()`. No logic change if it differs.
5. **`Category: Equatable`** is assumed (verified in the design plan source) so `InboxRow`/`InboxSection` synthesize equality; fallback documented in Task 2 if it isn't.

**TDD discipline:** every task writes a failing test first (or, for the pure-renderer DetailView and the view, a `swift build` gate plus coverage of the only added logic via `InboxGrouping` tests and the `#Preview`), then minimal code, then green, then commit. No placeholders; all code is complete and copy-pasteable.
